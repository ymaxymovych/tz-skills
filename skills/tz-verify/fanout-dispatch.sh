#!/usr/bin/env bash
# fanout-dispatch.sh — Queen→Workers parallelization for /tz-verify Step 4.
#
# Splits an AC manifest into N round-robin chunks and spawns N parallel
# `claude -p` worker subprocesses, each handling 3-critic dispatch for its
# slice of ACs. Workers write the same per-AC files the legacy sequential
# orchestrator would write: {run_dir}/critics/{ac_id}_{critic}.md
# and {run_dir}/critics/{ac_id}_{critic}.cache_key.json.
#
# This script is invoked by the Queen (orchestrator Claude session) during
# the new Step 3.5. Read-only against source. Writes only inside {run_dir}.
#
# Usage:
#   fanout-dispatch.sh <run_dir> <workers> <ac_manifest_json> [worker_timeout_sec]
#
# ac_manifest.json schema (built by Queen at end of Step 3):
#   [
#     { "ac_id": "AC-1", "evidence_bundle_path": "{run_dir}/bundles/AC-1.md" },
#     { "ac_id": "AC-2", "evidence_bundle_path": "{run_dir}/bundles/AC-2.md" },
#     ...
#   ]
#
# Exit codes:
#   0 — all workers exited cleanly (does NOT mean all critic files written;
#       Queen still scans critics/ and applies Step 4 resilience rules).
#   1 — argument or environment error.
#   2 — all workers failed (no critic files at all; Queen should halt or
#       suggest --fanout=off legacy fallback).
#
# Environment:
#   TZ_VERIFY_WORKER_CMD — override worker command (default: claude -p
#     --no-session-persistence --output-format text). Used by mock-mode tests.
#   TZ_VERIFY_FANOUT_DEBUG=1 — verbose tracing.

set -u
set -o pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <run_dir> <workers> <ac_manifest_json> [worker_timeout_sec]" >&2
  exit 1
fi

RUN_DIR="$1"
WORKERS="$2"
MANIFEST="$3"
WORKER_TIMEOUT="${4:-1800}"   # 30 min default per worker

if [ ! -d "$RUN_DIR" ]; then
  echo "run_dir does not exist: $RUN_DIR" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 1
fi
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [ "$WORKERS" -lt 1 ]; then
  echo "workers must be positive integer, got: $WORKERS" >&2
  exit 1
fi

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SKILL_DIR/worker-prompt-template.md"
if [ ! -f "$TEMPLATE" ]; then
  echo "worker-prompt-template.md missing next to fanout-dispatch.sh" >&2
  exit 1
fi

# Resolve the universal critic dispatcher (pack layout: skills/tz-verify/ -> ../../lib/llm-critic.sh).
# Override with TZ_LLM_CRITIC if the pack is laid out differently.
LLM_CRITIC="${TZ_LLM_CRITIC:-$SKILL_DIR/../../lib/llm-critic.sh}"
if [ -f "$LLM_CRITIC" ]; then
  LLM_CRITIC="$(cd "$(dirname "$LLM_CRITIC")" && pwd)/$(basename "$LLM_CRITIC")"
else
  echo "llm-critic.sh not found at $LLM_CRITIC (set TZ_LLM_CRITIC to its path)" >&2
  exit 1
fi

WORKER_CMD="${TZ_VERIFY_WORKER_CMD:-claude -p --no-session-persistence --output-format text}"
WORKERS_LOG_DIR="$RUN_DIR/workers"
CRITICS_DIR="$RUN_DIR/critics"
mkdir -p "$WORKERS_LOG_DIR" "$CRITICS_DIR"

dbg() { [ "${TZ_VERIFY_FANOUT_DEBUG:-0}" = "1" ] && echo "[fanout] $*" >&2 || true; }

# Count ACs in manifest. Tolerate jq absence — manifest is small, regex is fine.
# We count `"ac_id"` occurrences which works for both pretty-printed and
# single-line JSON since each AC entry has exactly one ac_id key.
if command -v jq >/dev/null 2>&1; then
  N_ACS=$(jq 'length' "$MANIFEST")
else
  N_ACS=$(grep -oE '"ac_id"' "$MANIFEST" | wc -l | tr -d ' ')
fi
if [ "$N_ACS" -lt 1 ]; then
  echo "manifest contains zero ACs" >&2
  exit 1
fi

# Cap workers at N_ACS — no point spawning idle workers.
if [ "$WORKERS" -gt "$N_ACS" ]; then
  WORKERS="$N_ACS"
fi

dbg "run_dir=$RUN_DIR workers=$WORKERS n_acs=$N_ACS timeout=${WORKER_TIMEOUT}s"

# Split manifest into $WORKERS round-robin chunks.
# Round-robin (vs sequential block split) balances slow ACs across workers
# better than chunked split when ACs vary in evidence size.
CHUNK_DIR="$WORKERS_LOG_DIR/chunks"
mkdir -p "$CHUNK_DIR"

if command -v jq >/dev/null 2>&1; then
  for ((i=0; i<WORKERS; i++)); do
    jq --argjson w "$WORKERS" --argjson i "$i" \
       '[.[range(0; length) | select(. % $w == $i) as $idx | .[$idx]]' \
       "$MANIFEST" > "$CHUNK_DIR/chunk_$i.json" 2>/dev/null || \
    jq --argjson w "$WORKERS" --argjson i "$i" \
       '[to_entries[] | select(.key % $w == $i) | .value]' \
       "$MANIFEST" > "$CHUNK_DIR/chunk_$i.json"
  done
else
  # jq-less fallback. The manifest is a flat JSON array of objects with no
  # nested objects (per documented schema). Tokenize on top-level objects by
  # splitting on `},{` after normalising braces. Works for both pretty and
  # single-line JSON.
  # 1) read the manifest as one string
  # 2) strip outer `[` `]`
  # 3) split records on `},{` -> awk array
  # 4) distribute round-robin into chunk files
  awk -v w="$WORKERS" -v dir="$CHUNK_DIR" '
    BEGIN { RS="\0" }
    {
      body = $0
      # Strip leading whitespace + [
      sub(/^[[:space:]]*\[[[:space:]]*/, "", body)
      # Strip trailing ] + whitespace
      sub(/[[:space:]]*\][[:space:]]*$/, "", body)
      # If empty manifest, nothing to do
      if (length(body) == 0) exit
      # Split on `},{` — preserve braces by surgical substitution
      gsub(/\}[[:space:]]*,[[:space:]]*\{/, "}\x01{", body)
      n = split(body, records, "\x01")
      for (i = 1; i <= n; i++) {
        rec = records[i]
        # Ensure record is wrapped in braces (split kept them)
        idx = (i - 1) % w
        file = dir "/chunk_" idx ".json"
        if (!(idx in started)) { printf "[" > file; started[idx] = 1; sep[idx] = "" }
        printf "%s%s", sep[idx], rec >> file
        sep[idx] = ","
      }
      for (idx in started) { printf "]" >> (dir "/chunk_" idx ".json") }
    }
  ' "$MANIFEST"
fi

# Spawn workers. Each gets a constructed prompt (template + chunk JSON +
# run_dir context) on stdin. Each runs in background with a wall-clock cap
# via `timeout` builtin.
declare -a WORKER_PIDS
declare -a WORKER_LOGS
for ((i=0; i<WORKERS; i++)); do
  CHUNK_FILE="$CHUNK_DIR/chunk_$i.json"
  WORKER_LOG="$WORKERS_LOG_DIR/worker_$i.log"
  WORKER_PROMPT="$WORKERS_LOG_DIR/worker_${i}_prompt.txt"

  # Compose worker prompt: template body + injected context vars + chunk.
  # Keep it simple — concatenation, no jq for template substitution.
  {
    sed -e "s|{{RUN_DIR}}|$RUN_DIR|g" \
        -e "s|{{WORKER_INDEX}}|$i|g" \
        -e "s|{{TOTAL_WORKERS}}|$WORKERS|g" \
        -e "s|{{LLM_CRITIC}}|$LLM_CRITIC|g" \
        "$TEMPLATE"
    echo ""
    echo "=== CHUNK MANIFEST (your ACs) ==="
    cat "$CHUNK_FILE"
    echo ""
    echo "=== END CHUNK ==="
  } > "$WORKER_PROMPT"

  dbg "spawning worker $i — chunk=$CHUNK_FILE log=$WORKER_LOG"

  # The `timeout` ensures runaway workers can't blow past the skill's overall
  # wall-clock budget. SIGTERM first, SIGKILL after grace if still alive.
  # Subshell exit code MUST reflect the worker's actual exit so `wait`
  # downstream can attribute failures correctly — hence the trailing `exit $rc`.
  (
    timeout --kill-after=30s "${WORKER_TIMEOUT}s" \
      bash -c "cat '$WORKER_PROMPT' | $WORKER_CMD" \
      > "$WORKER_LOG" 2>&1
    rc=$?
    echo "WORKER_EXIT_CODE=$rc" >> "$WORKER_LOG"
    exit "$rc"
  ) &

  WORKER_PIDS[$i]=$!
  WORKER_LOGS[$i]="$WORKER_LOG"
done

# Wait for all workers. We collect exit status individually rather than
# `wait` with no args so we can attribute failures to specific workers.
declare -a WORKER_RC
ANY_OK=0
for ((i=0; i<WORKERS; i++)); do
  if wait "${WORKER_PIDS[$i]}"; then
    WORKER_RC[$i]=0
    ANY_OK=1
    dbg "worker $i exited 0"
  else
    WORKER_RC[$i]=$?
    dbg "worker $i exited ${WORKER_RC[$i]}"
  fi
done

# Summary report — Queen parses this to populate report metadata.
# Stable format: one line per worker.
echo "=== FANOUT_SUMMARY ==="
echo "workers=$WORKERS n_acs=$N_ACS timeout=${WORKER_TIMEOUT}s"
for ((i=0; i<WORKERS; i++)); do
  echo "worker_${i}_rc=${WORKER_RC[$i]} log=${WORKER_LOGS[$i]}"
done

# Count critic files actually produced. Queen uses this as a sanity check
# but the final per-AC resilience decisions still belong to Step 4 rules.
N_CRITIC_FILES=$(find "$CRITICS_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
EXPECTED=$((N_ACS * 3))
echo "critic_files_produced=$N_CRITIC_FILES expected=$EXPECTED"

if [ "$ANY_OK" -eq 0 ] && [ "$N_CRITIC_FILES" -eq 0 ]; then
  echo "=== FANOUT_FAIL: no workers succeeded and no critic files written ==="
  exit 2
fi

exit 0
