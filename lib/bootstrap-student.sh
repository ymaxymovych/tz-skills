#!/usr/bin/env bash
# bootstrap-student.sh — «одна команда» / "one command": розгортає ВЕСЬ студентський комплект.
#
#   cd /path/to/your/project
#   bash ~/tz-skills/lib/bootstrap-student.sh              # Ukrainian output (default)
#   KIT_LANG=en bash ~/tz-skills/lib/bootstrap-student.sh  # English output + English IMMUNE block
#
# Що ставить / What it installs (ідемпотентно — можна запускати повторно, нічого твого не перезаписує):
#   1. parallel-ai-dev (project memory)          → clone into $KIT_HOME (default ~), init-memory in the project
#   2. tz-skills (/tz-draft /tz-review /tz-verify /tz-go) → copy into $CLAUDE_SKILLS_DIR (default ~/.claude/skills)
#   3. providers.json for the critics              → profile "Claude only + 2 free NVIDIA NIM models"
#   4. IMMUNE — 7 rules against code rot           → appended to the project's CLAUDE.md (once)
#   5. Checks: memory self-check + critics smoke test → honest table AS IS
#
# Exit code: 0 — all green; 1 — red rows exist (the "what to do" list is printed).
# Red does NOT mean broken — it is the checklist of what a human / Claude still has to do.
#
# Overrides (tests and non-standard folders):
#   KIT_LANG=uk|en        language of this script's output and of the IMMUNE block (default uk)
#   KIT_HOME=…            where to clone parallel-ai-dev            (default $HOME)
#   CLAUDE_SKILLS_DIR=…   where to install the skills                (default $HOME/.claude/skills)
#   TZ_PROVIDERS_CONFIG=… where providers.json lives                 (default $HOME/.claude/tz-providers.json)

set -u
set -o pipefail

TZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_LANG="${KIT_LANG:-uk}"
KIT_HOME="${KIT_HOME:-$HOME}"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
PROVIDERS="${TZ_PROVIDERS_CONFIG:-$HOME/.claude/tz-providers.json}"
PROJECT_DIR="$(pwd)"
PAD_REPO="https://github.com/ymaxymovych/parallel-ai-dev.git"

# L "ukrainian" "english" → prints the string for the active language.
L() { if [ "$KIT_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say()  { printf '%s\n' "$*"; }
hr()   { say "────────────────────────────────────────────────────────"; }

ROWS=()
TODO=()
RED=0
ok()   { ROWS+=("✅ $1"); }
bad()  { ROWS+=("🔴 $1"); TODO+=("$2"); RED=1; }
info() { ROWS+=("ℹ️  $1"); }

hr; say "$(L 'Студентський комплект — встановлення одним заходом' 'Student kit — one-shot installation')"
say "$(L 'Проєкт' 'Project'): $PROJECT_DIR"; hr

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
say "1/7 $(L 'Передумови' 'Prerequisites')"
have() { command -v "$1" >/dev/null 2>&1; }
for t in git curl; do
  if have "$t"; then say "   ✓ $t"; else
    say "   ✗ $t $(L 'НЕ знайдено' 'NOT found')"
    bad "$t $(L 'відсутній' 'is missing')" "$(L "Постав $t і запусти скрипт знову" "Install $t and run the script again")"; fi
done
if have python3 || have python || have jq; then say "   ✓ python $(L 'або' 'or') jq"; else
  say "   ✗ $(L 'ні python, ні jq' 'neither python nor jq')"
  bad "$(L 'python/jq відсутні' 'python/jq missing')" "$(L 'Постав python3 (python.org) або jq — потрібен для критиків через API' 'Install python3 (python.org) or jq — needed for the API-based critics')"; fi
if have claude; then say "   ✓ claude (Claude Code CLI)"; else
  say "   ⚠ claude $(L 'не в PATH' 'not on PATH')"
  bad "$(L 'Claude Code CLI не в PATH' 'Claude Code CLI not on PATH')" "$(L 'Скіли ставляться, але критик claude-cli не запуститься: перевір, що Claude Code встановлено і команда claude працює в цьому терміналі' 'Skills will install, but the claude-cli critic cannot run: make sure Claude Code is installed and the claude command works in this terminal')"; fi

# ── 2. Project = git repo, run from its root ──────────────────────────────────
say "2/7 $(L 'Git-репозиторій проєкту' 'Project git repository')"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q && say "   ✓ $(L 'створено новий git-репозиторій (тут його не було)' 'created a new git repository (there was none here)')" \
    || bad "$(L 'git init не вдався' 'git init failed')" "$(L "Розберись із текою проєкту: $PROJECT_DIR" "Check the project folder: $PROJECT_DIR")"
fi
if [ -n "$(git rev-parse --show-prefix 2>/dev/null)" ]; then
  say "   ✗ $(L 'це ПІДТЕКА репозиторію, а не корінь' 'this is a SUBFOLDER of the repository, not its root'): $(git rev-parse --show-toplevel)"
  bad "$(L 'Скрипт запущено не з кореня репозиторію' 'Script was run outside the repository root')" "cd $(git rev-parse --show-toplevel) && bash $TZ_ROOT/lib/bootstrap-student.sh"
  say ""; say "$(L "Зупиняюсь: пам'ять у підтеці жоден чат не знайде." 'Stopping: memory placed in a subfolder is invisible to every chat.')"; exit 1
fi
if [ -z "$(git config user.email 2>/dev/null)" ]; then
  bad "$(L 'git не знає твого email' 'git does not know your email')" "$(L 'git config --global user.email "твій@email" (і user.name) — без цього коміти не працюють' 'git config --global user.email "you@example.com" (and user.name) — commits do not work without it')"
else
  say "   ✓ git user.email: $(git config user.email)"
fi

# ── 3. parallel-ai-dev (project memory) ───────────────────────────────────────
say "3/7 $(L 'Комплект «пам'\''ять проєкту» (parallel-ai-dev)' 'Project-memory kit (parallel-ai-dev)')"
PAD_DIR=""
for d in "$KIT_HOME/parallel-ai-dev" "$PROJECT_DIR/../parallel-ai-dev" "$PROJECT_DIR/../../parallel-ai-dev"; do
  if [ -d "$d/.git" ]; then PAD_DIR="$(cd "$d" && pwd)"; break; fi
done
if [ -n "$PAD_DIR" ]; then
  say "   • $(L 'знайдено' 'found'): $PAD_DIR — $(L 'оновлюю (другу копію НЕ ставлю)' 'updating (NOT installing a second copy)')"
  git -C "$PAD_DIR" pull --ff-only -q origin main 2>/dev/null && say "   ✓ $(L 'свіжий' 'up to date')" \
    || say "   ⚠ $(L 'git pull не пройшов (немає мережі або локальні зміни) — працюю з тим, що є' 'git pull failed (no network or local changes) — continuing with what is there')"
else
  PAD_DIR="$KIT_HOME/parallel-ai-dev"
  if git clone -q "$PAD_REPO" "$PAD_DIR" 2>/dev/null; then say "   ✓ $(L 'склоновано у' 'cloned into') $PAD_DIR"; else
    bad "$(L 'Не вдалося склонувати parallel-ai-dev' 'Could not clone parallel-ai-dev')" "$(L "Перевір мережу і запусти: git clone $PAD_REPO $PAD_DIR" "Check the network and run: git clone $PAD_REPO $PAD_DIR")"; PAD_DIR=""; fi
fi
if [ -n "$PAD_DIR" ]; then
  say "   • init-memory $(L 'у проєкті' 'in the project') $(L '' '(the kit prints in Ukrainian — Claude translates for you)'):"
  if (cd "$PROJECT_DIR" && bash "$PAD_DIR/scripts/init-memory.sh" 2>&1 | sed 's/^/     /'); then
    ok "$(L "Пам'ять проєкту розгорнута" 'Project memory deployed') ($PAD_DIR)"
  else
    bad "$(L 'init-memory.sh повернув помилку' 'init-memory.sh returned an error')" "$(L "Прочитай вивід вище і запусти: cd $PROJECT_DIR && bash $PAD_DIR/scripts/init-memory.sh" "Read the output above and run: cd $PROJECT_DIR && bash $PAD_DIR/scripts/init-memory.sh")"
  fi
fi

# ── 4. Skills /tz-* ──────────────────────────────────────────────────────────
say "4/7 $(L 'Скіли Claude Code' 'Claude Code skills') → $SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
INSTALLED=0
for s in tz-draft tz-review tz-verify tz-go; do
  src="$TZ_ROOT/skills/$s"; dst="$SKILLS_DIR/$s"
  [ -d "$src" ] || continue
  rm -rf "$dst.tmp-bootstrap" && cp -r "$src" "$dst.tmp-bootstrap" && rm -rf "$dst" && mv "$dst.tmp-bootstrap" "$dst" \
    && { say "   ✓ /$s"; INSTALLED=$((INSTALLED+1)); } || say "   ✗ /$s $(L 'не скопіювався' 'failed to copy')"
done
if [ "$INSTALLED" -eq 4 ]; then ok "$(L '4 команди /tz-draft /tz-review /tz-verify /tz-go встановлено' '4 commands /tz-draft /tz-review /tz-verify /tz-go installed')"; else
  bad "$(L "Встановлено $INSTALLED/4 скілів" "Installed $INSTALLED/4 skills")" "$(L "Перевір права на $SKILLS_DIR і запусти: bash $TZ_ROOT/lib/tz-skills-update.sh" "Check permissions on $SKILLS_DIR and run: bash $TZ_ROOT/lib/tz-skills-update.sh")"; fi

# ── 5. Critics: providers.json + NVIDIA key ──────────────────────────────────
say "5/7 $(L 'Критики' 'Critics') (providers.json → $PROVIDERS)"
mkdir -p "$(dirname "$PROVIDERS")"

# NVIDIA retires free models without notice (deepseek-r1 → 404, qwen2.5-coder → EOL 2026-05-12,
# gpt-oss-120b → EOL 2026-09-03). So the NIM slots are NOT hard-coded: each slot has an ordered
# candidate list "vendor:model", and — when a key is available — the first candidate that answers
# a live PONG within 40 s wins. The two slots must end up with DIFFERENT vendors.
NIM_CANDIDATES_B="minimaxai:minimaxai/minimax-m3 nvidia:nvidia/nemotron-3.5-lightning-30b-a3b openai:openai/gpt-oss-20b nvidia:nvidia/nemotron-3-super-120b-a12b meta:meta/llama-3.2-90b-vision-instruct moonshotai:moonshotai/kimi-k3"
NIM_CANDIDATES_C="nvidia:nvidia/nemotron-3.5-lightning-30b-a3b minimaxai:minimaxai/minimax-m3 openai:openai/gpt-oss-20b nvidia:nvidia/nemotron-3-super-120b-a12b meta:meta/llama-3.2-90b-vision-instruct moonshotai:moonshotai/kimi-k3"
NIM_DEFAULT_B="minimaxai/minimax-m3"
NIM_DEFAULT_C="nvidia/nemotron-3.5-lightning-30b-a3b"

nim_alive() { # $1 = model id → 0 if HTTP 200 within 40 s
  [ -n "${NVIDIA_API_KEY:-}" ] || return 1
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 https://integrate.api.nvidia.com/v1/chat/completions \
    -H "Authorization: Bearer $NVIDIA_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}],\"max_tokens\":8}" 2>/dev/null)"
  [ "$code" = "200" ]
}
pick_nim() { # $1 = candidate list, $2 = vendor to avoid → prints model id (first alive), or "" if none
  local c vendor model
  for c in $1; do
    vendor="${c%%:*}"; model="${c#*:}"
    [ "$vendor" = "$2" ] && continue
    if nim_alive "$model"; then printf '%s' "$model"; return 0; fi
  done
  return 1
}
write_providers() { # $1 = model b, $2 = model c
  cat > "$PROVIDERS" <<JSON
{
  "_comment": "Profile 'Claude only': claude-cli + two FREE NVIDIA NIM models from different vendors. NVIDIA_API_KEY comes from build.nvidia.com (free, no card). NVIDIA retires models without notice: if a slot returns 404/410, rerun bootstrap-student.sh — it re-probes live candidates and rewrites only the NIM slots (a .bak copy is kept).",
  "critics": {
    "critic_a": { "backend": "claude-cli" },
    "critic_b": { "backend": "nim", "model": "$1", "api_key_env": "NVIDIA_API_KEY" },
    "critic_c": { "backend": "nim", "model": "$2", "api_key_env": "NVIDIA_API_KEY" }
  }
}
JSON
}
nim_model_of() { # $1 = slot → prints the model id configured for that slot (nim backend only)
  if have python3 || have python; then
    "$(have python3 && echo python3 || echo python)" - "$PROVIDERS" "$1" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
s=d.get('critics',{}).get(sys.argv[2],{})
print(s.get('model','') if s.get('backend')=='nim' else '')
PY
  elif have jq; then
    jq -r --arg s "$1" '.critics[$s] | if .backend=="nim" then .model else "" end' "$PROVIDERS" 2>/dev/null
  fi
}

if [ ! -f "$PROVIDERS" ]; then
  MB="$NIM_DEFAULT_B"; MC="$NIM_DEFAULT_C"
  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    say "   • $(L 'шукаю живі безкоштовні моделі NIM (до хвилини)…' 'probing live free NIM models (up to a minute)…')"
    PB="$(pick_nim "$NIM_CANDIDATES_B" "")" && MB="$PB"
    PC="$(pick_nim "$NIM_CANDIDATES_C" "${MB%%/*}")" && MC="$PC"
  fi
  write_providers "$MB" "$MC"
  say "   ✓ $(L 'створено профіль «лише Claude + 2 безкоштовні NIM»' 'created profile "Claude only + 2 free NIM models"'): $MB + $MC"
  ok "$(L 'providers.json створено' 'providers.json created') ($MB, $MC)"
else
  say "   • $(L 'вже є' 'already exists')"
  CB="$(nim_model_of critic_b)"; CC="$(nim_model_of critic_c)"
  if [ -n "${NVIDIA_API_KEY:-}" ] && { [ -n "$CB" ] || [ -n "$CC" ]; }; then
    DEAD=""
    [ -n "$CB" ] && ! nim_alive "$CB" && DEAD="$DEAD critic_b($CB)"
    [ -n "$CC" ] && ! nim_alive "$CC" && DEAD="$DEAD critic_c($CC)"
    if [ -n "$DEAD" ]; then
      say "   ⚠ $(L 'мертві NIM-моделі' 'retired NIM models'):$DEAD — $(L 'підбираю живі заміни' 'picking live replacements')"
      cp "$PROVIDERS" "$PROVIDERS.bak"
      NB="$CB"; NC="$CC"
      [ -n "$CB" ] && ! nim_alive "$CB" && { NB="$(pick_nim "$NIM_CANDIDATES_B" "")" || NB="$NIM_DEFAULT_B"; }
      [ -n "$CC" ] && ! nim_alive "$CC" && { NC="$(pick_nim "$NIM_CANDIDATES_C" "${NB%%/*}")" || NC="$NIM_DEFAULT_C"; }
      if [ -n "$NB" ] && [ -n "$NC" ]; then
        write_providers "$NB" "$NC"
        say "   ✓ $(L 'оновлено NIM-слоти' 'NIM slots updated'): $NB + $NC ($(L 'копія' 'backup'): $PROVIDERS.bak)"
        ok "$(L 'providers.json: мертві моделі замінено' 'providers.json: retired models replaced') ($NB, $NC)"
      else
        bad "$(L 'Не вдалося підібрати живі NIM-моделі' 'Could not find live NIM models')" "$(L "Перевір ключ і мережу, потім підбери моделі на build.nvidia.com і впиши в $PROVIDERS" "Check the key and network, then pick models on build.nvidia.com and put them into $PROVIDERS")"
      fi
    else
      ok "$(L 'providers.json уже був — моделі живі, залишено твій' 'providers.json already existed — models alive, kept yours')"
    fi
  elif grep -qE 'deepseek-ai/deepseek-r1|qwen/qwen2.5-coder-32b-instruct|openai/gpt-oss-120b' "$PROVIDERS"; then
    bad "$(L 'У providers.json моделі, які NVIDIA зняла (deepseek-r1 / qwen2.5-coder / gpt-oss-120b)' 'providers.json names models NVIDIA retired (deepseek-r1 / qwen2.5-coder / gpt-oss-120b)')" "$(L "Задай NVIDIA_API_KEY і запусти цей скрипт ще раз — він сам підбере живі заміни (або впиши $NIM_DEFAULT_B і $NIM_DEFAULT_C у $PROVIDERS)" "Set NVIDIA_API_KEY and rerun this script — it picks live replacements itself (or put $NIM_DEFAULT_B and $NIM_DEFAULT_C into $PROVIDERS)")"
  else
    ok "$(L 'providers.json уже був — залишено твій' 'providers.json already existed — kept yours')"
  fi
fi
if [ -z "${NVIDIA_API_KEY:-}" ]; then
  if grep -qs 'NVIDIA_API_KEY' "$HOME/.bashrc" 2>/dev/null; then
    info "$(L 'NVIDIA_API_KEY є в ~/.bashrc, але не в цьому терміналі — після перезапуску терміналу підхопиться' 'NVIDIA_API_KEY is in ~/.bashrc but not in this terminal — it will be picked up after a terminal restart')"
  fi
  bad "$(L 'Немає ключа NVIDIA_API_KEY — два критики з трьох не працюватимуть' 'No NVIDIA_API_KEY — two of the three critics cannot run')" "$(L 'ЛЮДИНА: зайти на https://build.nvidia.com (вхід через Google, картка не потрібна) → https://build.nvidia.com/settings/api-keys → Generate API Key (nvapi-…). Потім: echo '\''export NVIDIA_API_KEY="nvapi-…"'\'' >> ~/.bashrc && source ~/.bashrc' 'HUMAN: open https://build.nvidia.com (sign in with Google, no card needed) → https://build.nvidia.com/settings/api-keys → Generate API Key (nvapi-…). Then: echo '\''export NVIDIA_API_KEY="nvapi-…"'\'' >> ~/.bashrc && source ~/.bashrc')"
else
  say "   ✓ NVIDIA_API_KEY $(L 'є в оточенні' 'present in the environment')"
fi

# ── 6. IMMUNE in the project's CLAUDE.md ──────────────────────────────────────
say "6/7 IMMUNE — $(L 'правила проти гниття коду' 'rules against code rot') → CLAUDE.md"
if [ "$KIT_LANG" = "en" ]; then BLOCK="$TZ_ROOT/docs/IMMUNE_CLAUDE_BLOCK.en.md"; else BLOCK="$TZ_ROOT/docs/IMMUNE_CLAUDE_BLOCK.md"; fi
if [ ! -f "$BLOCK" ]; then
  bad "$(L "Файл $BLOCK не знайдено" "File $BLOCK not found")" "$(L "Онови tz-skills: git -C $TZ_ROOT pull --ff-only" "Update tz-skills: git -C $TZ_ROOT pull --ff-only")"
elif [ -f "$PROJECT_DIR/CLAUDE.md" ] && grep -qE 'Правила проти гниття коду \(IMMUNE\)|Rules against code rot \(IMMUNE\)' "$PROJECT_DIR/CLAUDE.md"; then
  say "   • $(L 'блок уже є — не дублюю' 'block already present — not duplicating')"; ok "$(L 'IMMUNE уже в CLAUDE.md' 'IMMUNE already in CLAUDE.md')"
else
  { printf '\n'; cat "$BLOCK"; } >> "$PROJECT_DIR/CLAUDE.md" && { say "   ✓ $(L 'дописано в кінець CLAUDE.md' 'appended to the end of CLAUDE.md')"; ok "$(L 'IMMUNE дописано в CLAUDE.md' 'IMMUNE appended to CLAUDE.md')"; } \
    || bad "$(L 'Не вдалося дописати IMMUNE' 'Could not append IMMUNE')" "$(L "Скопіюй вміст $BLOCK у кінець $PROJECT_DIR/CLAUDE.md руками" "Copy the contents of $BLOCK to the end of $PROJECT_DIR/CLAUDE.md by hand")"
fi

# ── 7. Commit + checks ────────────────────────────────────────────────────────
say "7/7 $(L 'Коміт і перевірки' 'Commit and checks')"
if [ -n "$(git config user.email 2>/dev/null)" ]; then
  git add CLAUDE.md CLAUDE.parallel-ai-dev.md coordination 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -q -m "$(L "kit: пам'ять проєкту (parallel-ai-dev) + правила IMMUNE" 'kit: project memory (parallel-ai-dev) + IMMUNE rules')" && say "   ✓ $(L 'закомічено файли комплекту' 'kit files committed')" \
      || bad "$(L 'git commit не пройшов' 'git commit failed')" "$(L "Подивись, що каже git у $PROJECT_DIR, і закоміть CLAUDE.md + coordination/ руками" "See what git says in $PROJECT_DIR and commit CLAUDE.md + coordination/ by hand")"
  else
    say "   • $(L 'нічого нового комітити' 'nothing new to commit')"
  fi
fi

say "   • $(L "self-check пам'яті" 'memory self-check') $(L '' '(Ukrainian output — Claude translates)'):"
if [ -n "$PAD_DIR" ]; then
  if (cd "$PROJECT_DIR" && bash "$PAD_DIR/scripts/self-check.sh" 2>&1 | sed 's/^/     /'); then
    ok "self-check: ✅ $(L 'СИСТЕМА ГОТОВА' 'SYSTEM READY')"
  else
    bad "$(L "self-check пам'яті має червоні рядки (це очікувано на свіжій системі)" 'memory self-check has red rows (expected on a fresh system)')" "$(L "CLAUDE: заповни coordination/SETUP.md (visibility, mode), coordination/PROJECT_MAP.md (що в проєкті вже є), coordination/DECISIONS.md (3-5 рішень з полем «Чому»), секцію «Зони цього проєкту» в CLAUDE.md; закоміть і запуш; повтори bash $PAD_DIR/scripts/self-check.sh" "CLAUDE: fill in coordination/SETUP.md (visibility, mode), coordination/PROJECT_MAP.md (what already exists in the project), coordination/DECISIONS.md (3-5 decisions with a 'Why' field), the project-zones section of CLAUDE.md; commit and push; rerun bash $PAD_DIR/scripts/self-check.sh")"
  fi
fi

say "   • $(L 'smoke-тест критиків' 'critics smoke test'):"
if TZ_PROVIDERS_CONFIG="$PROVIDERS" bash "$TZ_ROOT/lib/llm-critic.sh" --smoke-all 2>&1 | sed 's/^/     /'; then
  ok "$(L 'Критики: усі 3 слоти відповідають' 'Critics: all 3 slots respond')"
else
  bad "$(L 'Критики: не всі 3 слоти живі — /tz-review і /tz-go зупиняться або працюватимуть ослаблено' 'Critics: not all 3 slots alive — /tz-review and /tz-go will stop or run degraded')" "$(L "Полагодь червоний слот (найчастіше — немає NVIDIA_API_KEY або claude не в PATH) і повтори: TZ_PROVIDERS_CONFIG=$PROVIDERS bash $TZ_ROOT/lib/llm-critic.sh --smoke-all" "Fix the red slot (usually a missing NVIDIA_API_KEY or claude not on PATH) and rerun: TZ_PROVIDERS_CONFIG=$PROVIDERS bash $TZ_ROOT/lib/llm-critic.sh --smoke-all")"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hr; say "$(L 'ПІДСУМОК' 'SUMMARY')"; hr
for r in "${ROWS[@]}"; do say "$r"; done
if [ "$RED" -eq 1 ]; then
  hr; say "$(L 'ЩО ЗРОБИТИ (по одному пункту, зверху вниз):' 'WHAT TO DO (one item at a time, top to bottom):')"
  i=1; for t in "${TODO[@]}"; do say "$i. $t"; i=$((i+1)); done
  hr; say "$(L 'Червоне — не поломка, а чек-лист. Коли все зроблено — запусти скрипт ще раз: він нічого не перезапише.' 'Red is not a failure — it is a checklist. When everything is done, run the script again: it overwrites nothing.')"
  exit 1
fi
hr; say "✅ $(L 'Усе зелене. Команди' 'All green. Commands'): /tz-go ($(L 'усе сам' 'everything on its own')) · /tz-draft · /tz-review · /tz-verify"
exit 0
