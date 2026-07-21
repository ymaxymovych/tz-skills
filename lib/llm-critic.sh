#!/usr/bin/env bash
# llm-critic.sh — universal LLM dispatcher for the tz-review / tz-verify skills.
#
# PURPOSE
#   The skills need N INDEPENDENT LLM "critics". Historically they hard-coded three
#   local CLIs (claude / codex / gemini). This wrapper decouples the skill from the
#   backend: each critic "slot" is mapped in providers.json to ONE of:
#     - a local CLI    (claude-cli | codex-cli | gemini-cli)
#     - OpenRouter API (backend: openrouter) — any model OpenRouter hosts
#     - NVIDIA NIM API (backend: nim)        — free hosted models (DeepSeek, Qwen, etc.)
#   So a student who has only Claude installed can still run 3 cross-vendor critics
#   by pointing two slots at free NIM models + an OpenRouter model. Independence is
#   preserved as long as the three slots use DIFFERENT model vendors.
#
# USAGE
#   llm-critic.sh <slot> <prompt-file>     # run the slot's model on the prompt, print reply to stdout
#   cat prompt.txt | llm-critic.sh <slot>  # prompt on stdin instead of a file
#   llm-critic.sh --smoke <slot>           # PONG smoke-test one slot (exit 0 = healthy)
#   llm-critic.sh --smoke-all              # smoke-test every configured slot
#   llm-critic.sh --list                   # print configured slots + backends
#   llm-critic.sh --resolve                # print resolved config path and exit
#
# CONFIG DISCOVERY (first hit wins)
#   1. $TZ_PROVIDERS_CONFIG (explicit path)
#   2. ./providers.json  (walking up from $PWD to the filesystem root)
#   3. $HOME/.claude/tz-providers.json
#   See providers.example.json for the schema.
#
# REQUIREMENTS
#   - CLI backends: the corresponding CLI on PATH. No python/jq needed.
#   - API backends (openrouter / nim): `curl` + EITHER python3 OR jq. Nothing else.
#
# EXIT CODES
#   0 ok | 1 usage/config error | 2 backend/CLI failure | 3 empty response
#
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
err() { printf '[llm-critic] %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# locate config
# ---------------------------------------------------------------------------
resolve_config() {
  if [ -n "${TZ_PROVIDERS_CONFIG:-}" ]; then
    [ -f "$TZ_PROVIDERS_CONFIG" ] || die "TZ_PROVIDERS_CONFIG set but not a file: $TZ_PROVIDERS_CONFIG"
    printf '%s\n' "$TZ_PROVIDERS_CONFIG"; return 0
  fi
  local d; d="$PWD"
  while :; do
    if [ -f "$d/providers.json" ]; then printf '%s\n' "$d/providers.json"; return 0; fi
    [ "$d" = "/" ] && break
    local parent; parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && break   # windows drive root (C:/) guard
    d="$parent"
  done
  if [ -f "$HOME/.claude/tz-providers.json" ]; then
    printf '%s\n' "$HOME/.claude/tz-providers.json"; return 0
  fi
  die "no providers.json found. Set TZ_PROVIDERS_CONFIG, or place providers.json in your repo root, or at ~/.claude/tz-providers.json. Copy providers.example.json to start."
}

# ---------------------------------------------------------------------------
# JSON read helper — python3 preferred, jq fallback.
# cfg_get <config> <slot> <field>  → prints value or empty string
# ---------------------------------------------------------------------------
# Resolve a working python once (prefer python3; both are fine — we force binary
# stdout below so Windows text-mode CRLF translation can't corrupt values).
PYBIN=""
if have python3; then PYBIN="python3"; elif have python; then PYBIN="python"; fi

cfg_get() {
  local cfg="$1" slot="$2" field="$3" out
  # strip any stray CR the caller may have picked up from a CRLF stream
  slot="${slot%$'\r'}"; field="${field%$'\r'}"
  if [ -n "$PYBIN" ]; then
    "$PYBIN" - "$cfg" "$slot" "$field" <<'PY'
import json,sys
cfg,slot,field=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(cfg,encoding="utf-8"))
c=d.get("critics",{}).get(slot,{})
v=c.get(field,"")
sys.stdout.buffer.write(("" if v is None else str(v)).encode("utf-8"))  # binary → no CRLF
PY
  elif have jq; then
    jq -r --arg s "$slot" --arg f "$field" '.critics[$s][$f] // ""' "$cfg" | tr -d '\r'
  else
    die "need python3 or jq to read providers.json"
  fi
}

cfg_slots() {
  local cfg="$1"
  if [ -n "$PYBIN" ]; then
    "$PYBIN" - "$cfg" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
keys=list((d.get("critics") or {}).keys())
sys.stdout.buffer.write((("\n".join(keys)+"\n") if keys else "").encode("utf-8"))  # binary → no CRLF; trailing \n so `read` gets last line
PY
  elif have jq; then
    jq -r '.critics | keys[]' "$cfg" | tr -d '\r'
  else
    die "need python3 or jq to read providers.json"
  fi
}

# ---------------------------------------------------------------------------
# API call (OpenRouter / NIM — both OpenAI-compatible /chat/completions).
# api_call <base_url> <api_key> <model> <prompt-file>  → prints message content
# ---------------------------------------------------------------------------
api_call() {
  local base="$1" key="$2" model="$3" pf="$4"
  local url="${base%/}/chat/completions"
  if [ -n "$PYBIN" ]; then
    "$PYBIN" - "$url" "$key" "$model" "$pf" <<'PY'
import json,sys,urllib.request,urllib.error
url,key,model,pf=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
prompt=open(pf,encoding="utf-8").read()
body=json.dumps({"model":model,"messages":[{"role":"user","content":prompt}],
                 "temperature":0.2}).encode("utf-8")
req=urllib.request.Request(url,data=body,method="POST",headers={
    "Content-Type":"application/json","Authorization":"Bearer "+key,
    # OpenRouter likes these; harmless for NIM:
    "HTTP-Referer":"https://localhost/tz-skills","X-Title":"tz-skills"})
try:
    with urllib.request.urlopen(req,timeout=600) as r:
        data=json.load(r)
except urllib.error.HTTPError as e:
    sys.stderr.write("HTTP %s: %s\n"%(e.code,e.read().decode("utf-8","replace")[:500])); sys.exit(2)
except Exception as e:
    sys.stderr.write("request failed: %s\n"%e); sys.exit(2)
try:
    txt=data["choices"][0]["message"]["content"]
except Exception:
    sys.stderr.write("unexpected response: %s\n"%json.dumps(data)[:500]); sys.exit(2)
sys.stdout.buffer.write((txt or "").encode("utf-8"))   # binary → no CRLF translation on Windows
PY
    return $?
  elif have jq && have curl; then
    local body resp
    body="$(jq -n --arg m "$model" --rawfile p "$pf" \
      '{model:$m,temperature:0.2,messages:[{role:"user",content:$p}]}')"
    resp="$(curl -sS --max-time 600 "$url" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $key" \
      -H "HTTP-Referer: https://localhost/tz-skills" -H "X-Title: tz-skills" \
      -d "$body")" || { err "curl failed"; return 2; }
    printf '%s' "$resp" | jq -e -r '.choices[0].message.content' 2>/dev/null && return 0
    err "unexpected API response: $(printf '%s' "$resp" | head -c 400)"; return 2
  else
    die "API backends need curl + (python3 or jq)"
  fi
}

# ---------------------------------------------------------------------------
# run one slot against a prompt file → stdout
# ---------------------------------------------------------------------------
run_slot() {
  local cfg="$1" slot="$2" pf="$3"
  local backend model base key_env key
  backend="$(cfg_get "$cfg" "$slot" backend)"
  [ -n "$backend" ] || die "slot '$slot' not found in $cfg (or missing 'backend')"
  model="$(cfg_get "$cfg" "$slot" model)"

  case "$backend" in
    claude-cli)
      have claude || die "slot '$slot' backend claude-cli but 'claude' not on PATH"
      # --output-format text keeps it plain; global ~/.claude/CLAUDE.md still loads (see skill notes)
      cat "$pf" | claude -p --output-format text ${model:+--model "$model"} ;;
    codex-cli)
      have codex  || die "slot '$slot' backend codex-cli but 'codex' not on PATH"
      cat "$pf" | codex exec --skip-git-repo-check - ;;
    gemini-cli)
      have gemini || die "slot '$slot' backend gemini-cli but 'gemini' not on PATH"
      cat "$pf" | gemini -p "" ${model:+-m "$model"} ;;
    openrouter)
      [ -n "$model" ] || die "slot '$slot' backend openrouter requires 'model'"
      key_env="$(cfg_get "$cfg" "$slot" api_key_env)"; key_env="${key_env:-OPENROUTER_API_KEY}"
      key="${!key_env:-}"; [ -n "$key" ] || die "env \$$key_env is empty (needed by slot '$slot')"
      base="$(cfg_get "$cfg" "$slot" base_url)"; base="${base:-https://openrouter.ai/api/v1}"
      api_call "$base" "$key" "$model" "$pf" ;;
    nim)
      [ -n "$model" ] || die "slot '$slot' backend nim requires 'model'"
      key_env="$(cfg_get "$cfg" "$slot" api_key_env)"; key_env="${key_env:-NVIDIA_API_KEY}"
      key="${!key_env:-}"; [ -n "$key" ] || die "env \$$key_env is empty (needed by slot '$slot')"
      base="$(cfg_get "$cfg" "$slot" base_url)"; base="${base:-https://integrate.api.nvidia.com/v1}"
      api_call "$base" "$key" "$model" "$pf" ;;
    *)
      die "slot '$slot' has unknown backend '$backend' (use claude-cli|codex-cli|gemini-cli|openrouter|nim)" ;;
  esac
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
CFG="$(resolve_config)" || exit 1

case "${1:---help}" in
  --resolve) printf '%s\n' "$CFG"; exit 0 ;;
  --list)
    printf 'config: %s\n' "$CFG"
    while IFS= read -r s; do
      s="${s%$'\r'}"; [ -n "$s" ] || continue
      printf '  %-10s backend=%-11s model=%s\n' "$s" "$(cfg_get "$CFG" "$s" backend)" "$(cfg_get "$CFG" "$s" model)"
    done < <(cfg_slots "$CFG")
    exit 0 ;;
  --smoke)
    slot="${2:-}"; [ -n "$slot" ] || die "usage: llm-critic.sh --smoke <slot>"
    tmp="$(mktemp)"; printf 'Reply with the single word PONG and nothing else.' > "$tmp"
    out="$(run_slot "$CFG" "$slot" "$tmp")"; rc=$?; rm -f "$tmp"
    [ $rc -eq 0 ] || { err "slot '$slot' FAILED (backend error)"; exit 2; }
    if printf '%s' "$out" | grep -qi 'PONG'; then echo "slot '$slot' OK"; exit 0
    else err "slot '$slot' replied without PONG: $(printf '%s' "$out" | head -c 120)"; exit 3; fi ;;
  --smoke-all)
    fail=0
    while IFS= read -r s; do
      s="${s%$'\r'}"; [ -n "$s" ] || continue
      if "$0" --smoke "$s"; then :; else fail=1; fi
    done < <(cfg_slots "$CFG")
    exit $fail ;;
  --help|-h)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)
    slot="$1"; shift || true
    if [ "${1:-}" = "-" ] || [ $# -eq 0 ]; then
      tmp="$(mktemp)"; cat > "$tmp"; run_slot "$CFG" "$slot" "$tmp"; rc=$?; rm -f "$tmp"; exit $rc
    else
      pf="$1"; [ -f "$pf" ] || die "prompt file not found: $pf"
      run_slot "$CFG" "$slot" "$pf"; exit $?
    fi ;;
esac
