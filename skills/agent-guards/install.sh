#!/usr/bin/env bash
# install.sh — «одна команда» / "one command": ставить запобіжники агентів Claude Code.
#
#   bash ~/tz-skills/skills/agent-guards/install.sh              # Ukrainian output (default)
#   KIT_LANG=en bash ~/tz-skills/skills/agent-guards/install.sh  # English output and English hook messages
#
# Що робить / What it does (ідемпотентно — повторний запуск нічого не дублює):
#   1. копіює hooks/*.py у ~/.claude/hooks/
#   2. реєструє їх у ~/.claude/settings.json (копія .bak перед правкою, чужі хуки не чіпає)
#   3. перевіряє кожен хук живим викликом (битий вхід → код 0, `python x` → виправлено)
#
# Вимкнути / switch off: змінна AGENT_GUARDS_OFF=1 (див. README).
# Exit code: 0 — все зелене; 1 — є червоні рядки (список «що зробити» надруковано).

set -u
set -o pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_LANG="${KIT_LANG:-uk}"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
FILES="shell_guard.py loop_breaker.py tool_hints.py"

L() { if [ "$KIT_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────"; }

ROWS=(); TODO=(); RED=0
ok()  { ROWS+=("✅ $1"); }
bad() { ROWS+=("🔴 $1"); TODO+=("$2"); RED=1; }

hr; say "$(L 'Запобіжники агентів — встановлення' 'Agent guards — installation')"; hr

# ── 1. Python ────────────────────────────────────────────────────────────────
say "1/3 $(L 'Python' 'Python')"
PY=()
for cand in python3 python "py -3"; do
  # shellcheck disable=SC2086
  if $cand -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then read -r -a PY <<< "$cand"; break; fi
done
if [ "${#PY[@]}" -eq 0 ]; then
  bad "$(L 'Python 3.8+ не знайдено' 'Python 3.8+ not found')" "$(L 'Постав Python 3 (python.org, на macOS: brew install python) і запусти скрипт знову' 'Install Python 3 (python.org; on macOS: brew install python) and run the script again')"
  hr; say "🔴 ${ROWS[0]#* }"; say "1. ${TODO[0]}"; exit 1
fi
say "   ✓ ${PY[*]} ($("${PY[@]}" --version 2>&1))"

# ── 2. Hook files ────────────────────────────────────────────────────────────
say "2/3 $(L 'Файли хуків' 'Hook files') → $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"
COPIED=0
for f in $FILES; do
  if cp "$SRC/hooks/$f" "$HOOKS_DIR/$f"; then say "   ✓ $f"; COPIED=$((COPIED+1)); else say "   ✗ $f"; fi
done
printf '%s\n' "$KIT_LANG" > "$HOOKS_DIR/agent_guards.lang"
if [ "$COPIED" -eq 3 ]; then ok "$(L '3 хуки скопійовано' '3 hooks copied') ($HOOKS_DIR)"; else
  bad "$(L "Скопійовано $COPIED/3 хуків" "Copied $COPIED/3 hooks")" "$(L "Перевір права на $HOOKS_DIR і запусти скрипт знову" "Check permissions on $HOOKS_DIR and run the script again")"; fi

# ── 3. Register in settings.json ─────────────────────────────────────────────
say "3/3 $(L 'Реєстрація в settings.json' 'Registration in settings.json')"
OUT="$("${PY[@]}" -X utf8 - "$CLAUDE_DIR" "$KIT_LANG" <<'PY' 2>&1
import datetime, json, shutil, sys
from pathlib import Path

claude, lang = Path(sys.argv[1]), sys.argv[2]
uk = lang != "en"
hooks_dir = claude / "hooks"
settings_path = claude / "settings.json"
interpreter = sys.executable.replace("\\", "/")
CHROME = "mcp__claude-in-chrome__computer|mcp__Claude_Browser__computer"
# (event, matcher or None, hook file)
WANTED = [
    ("PreToolUse", "Bash|PowerShell", "shell_guard.py"),
    ("PreToolUse", None, "loop_breaker.py"),
    ("PreToolUse", CHROME, "tool_hints.py"),
    ("PostToolUseFailure", None, "loop_breaker.py"),
    ("PostToolUseFailure", None, "tool_hints.py"),
]

raw = settings_path.read_text(encoding="utf-8") if settings_path.exists() else ""
try:
    settings = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError as err:
    sys.exit(("settings.json — не валідний JSON (%s). Нічого не змінено." if uk else "settings.json is not valid JSON (%s). Nothing changed.") % err)
if not isinstance(settings, dict):
    sys.exit("settings.json — не об'єкт JSON." if uk else "settings.json is not a JSON object.")

added = 0
for event, matcher, name in WANTED:
    groups = settings.setdefault("hooks", {}).setdefault(event, [])
    present = any(name in str(h.get("command", ""))
                  for g in groups if isinstance(g, dict) and g.get("matcher") == matcher
                  for h in g.get("hooks", []) if isinstance(h, dict))
    if present:
        continue
    group = {"hooks": [{"type": "command", "command": '"%s" "%s"' % (interpreter, (hooks_dir / name).as_posix()), "timeout": 15}]}
    if matcher:
        group = {"matcher": matcher, **group}
    groups.append(group)
    added += 1

if added:
    if settings_path.exists():
        backup = settings_path.with_name("settings.json.bak-agent-guards-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copyfile(settings_path, backup)
        print(("✓ Копія старих налаштувань: " if uk else "✓ Backup of the old settings: ") + str(backup))
    tmp = settings_path.with_name("settings.json.tmp-agent-guards")
    tmp.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    json.loads(tmp.read_text(encoding="utf-8"))
    tmp.replace(settings_path)
print(("✓ Додано записів: %d з %d" if uk else "✓ Entries added: %d of %d") % (added, len(WANTED)) if added
      else ("· Усі 5 записів уже в settings.json — нічого не додано" if uk else "· All 5 entries already in settings.json — nothing added"))
PY
)"
RC=$?
say "$OUT" | sed 's/^/   /'
if [ "$RC" -eq 0 ]; then ok "$(L 'Хуки зареєстровано в settings.json (5 записів)' 'Hooks registered in settings.json (5 entries)')"; else
  bad "$(L 'Не вдалося записати settings.json' 'Could not write settings.json')" "$(L "Прочитай повідомлення вище, виправ $CLAUDE_DIR/settings.json і запусти скрипт знову" "Read the message above, fix $CLAUDE_DIR/settings.json and run the script again")"; fi

# ── Self-check: live calls ───────────────────────────────────────────────────
say "   • $(L 'перевірка живим викликом' 'live check')"
H="$HOOKS_DIR"
PROBE='{"tool_name":"Bash","tool_input":{"command":"python x.py"}}'
PROBE_HOME="$(mktemp -d)"  # keep the probe's log line out of the real ~/.claude/logs
GOT="$(printf '%s' "$PROBE" | HOME="$PROBE_HOME" USERPROFILE="$PROBE_HOME" "${PY[@]}" -X utf8 "$H/shell_guard.py" 2>&1)"
case "$GOT" in *'"updatedInput"'*'-X utf8 x.py'*) CHECK1=1 ;; *) CHECK1=0 ;; esac
CHECK2=1
for f in $FILES; do
  printf '%s' '{broken' | HOME="$PROBE_HOME" USERPROFILE="$PROBE_HOME" "${PY[@]}" -X utf8 "$H/$f" >/dev/null 2>&1 || CHECK2=0
done
rm -rf "$PROBE_HOME"
if [ "$CHECK1" -eq 1 ] && [ "$CHECK2" -eq 1 ]; then ok "$(L 'Перевірка: shell_guard виправляє команду, усі хуки переживають битий вхід (код 0)' 'Check: shell_guard fixes a command, every hook survives broken input (exit 0)')"; else
  bad "$(L 'Живий виклик хука не пройшов' 'Live hook call failed')" "$(L "Запусти вручну: echo '$PROBE' | ${PY[*]} -X utf8 $H/shell_guard.py і покажи вивід Claude" "Run by hand: echo '$PROBE' | ${PY[*]} -X utf8 $H/shell_guard.py and show the output to Claude")"; fi

# ── Summary ──────────────────────────────────────────────────────────────────
hr; say "$(L 'ПІДСУМОК' 'SUMMARY')"; hr
for r in "${ROWS[@]}"; do say "$r"; done
if [ "$RED" -eq 1 ]; then
  hr; say "$(L 'ЩО ЗРОБИТИ (по одному пункту, зверху вниз):' 'WHAT TO DO (one item at a time, top to bottom):')"
  i=1; for t in "${TODO[@]}"; do say "$i. $t"; i=$((i+1)); done
  exit 1
fi
hr; say "✅ $(L 'Готово. Хуки діють у НОВИХ сесіях Claude Code. Вимкнути: AGENT_GUARDS_OFF=1. Замір: python measure.py' 'Done. The hooks apply to NEW Claude Code sessions. Switch off: AGENT_GUARDS_OFF=1. Measure: python measure.py')"
exit 0
