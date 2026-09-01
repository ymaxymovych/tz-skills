#!/usr/bin/env bash
# bootstrap-student.sh — «одна команда»: розгортає ВЕСЬ студентський комплект.
#
#   cd /тека/твого/проєкту
#   bash ~/tz-skills/lib/bootstrap-student.sh
#
# Що ставить (ідемпотентно — можна запускати повторно, нічого твого не перезаписує):
#   1. parallel-ai-dev («пам'ять проєкту»)      → клон у $KIT_HOME (типово ~), init-memory у проєкті
#   2. tz-skills (/tz-draft /tz-review /tz-verify /tz-go) → копія у $CLAUDE_SKILLS_DIR (типово ~/.claude/skills)
#   3. providers.json для критиків                → профіль «лише Claude + 2 безкоштовні NIM»
#   4. IMMUNE — 7 правил проти гниття коду        → допис у CLAUDE.md проєкту (один раз)
#   5. Перевірки: self-check пам'яті + smoke-тест критиків → таблиця ЯК Є
#
# Код виходу: 0 — усе зелене; 1 — є червоні рядки (список «що зробити» надруковано).
# Червоне НЕ означає «зламалось» — це чек-лист того, що ще треба зробити людині/Claude.
#
# Перевизначення (для тестів і нестандартних тек):
#   KIT_HOME=…            куди клонувати parallel-ai-dev (типово $HOME)
#   CLAUDE_SKILLS_DIR=…   куди ставити скіли        (типово $HOME/.claude/skills)
#   TZ_PROVIDERS_CONFIG=… де лежить providers.json   (типово $HOME/.claude/tz-providers.json)

set -u
set -o pipefail

TZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_HOME="${KIT_HOME:-$HOME}"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
PROVIDERS="${TZ_PROVIDERS_CONFIG:-$HOME/.claude/tz-providers.json}"
PROJECT_DIR="$(pwd)"
PAD_REPO="https://github.com/ymaxymovych/parallel-ai-dev.git"

say()  { printf '%s\n' "$*"; }
hr()   { say "────────────────────────────────────────────────────────"; }

# Підсумкова таблиця: рядки додаються по ходу; 🔴 = є що робити.
ROWS=()
TODO=()
RED=0
ok()   { ROWS+=("✅ $1"); }
bad()  { ROWS+=("🔴 $1"); TODO+=("$2"); RED=1; }
info() { ROWS+=("ℹ️  $1"); }

hr; say "Студентський комплект — встановлення одним заходом"; say "Проєкт: $PROJECT_DIR"; hr

# ── 1. Передумови ─────────────────────────────────────────────────────────────
say "1/7 Передумови"
have() { command -v "$1" >/dev/null 2>&1; }
for t in git curl; do
  if have "$t"; then say "   ✓ $t"; else say "   ✗ $t НЕ знайдено"; bad "$t відсутній" "Постав $t і запусти скрипт знову"; fi
done
if have python3 || have python || have jq; then say "   ✓ python або jq"; else
  say "   ✗ ні python, ні jq"; bad "python/jq відсутні" "Постав python3 (python.org) або jq — потрібен для критиків через API"; fi
if have claude; then say "   ✓ claude (Claude Code CLI)"; else
  say "   ⚠ claude не в PATH"; bad "Claude Code CLI не в PATH" "Скіли ставляться, але критик claude-cli не запуститься: перевір, що Claude Code встановлено і команда claude працює в цьому терміналі"; fi

# ── 2. Проєкт = git-репозиторій у корені ──────────────────────────────────────
say "2/7 Git-репозиторій проєкту"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q && say "   ✓ створено новий git-репозиторій (тут його не було)" \
    || { bad "git init не вдався" "Розберись із текою проєкту: $PROJECT_DIR"; }
fi
if [ -n "$(git rev-parse --show-prefix 2>/dev/null)" ]; then
  say "   ✗ це ПІДТЕКА репозиторію, а не корінь: $(git rev-parse --show-toplevel)"
  bad "Скрипт запущено не з кореня репозиторію" "cd $(git rev-parse --show-toplevel) && bash $TZ_ROOT/lib/bootstrap-student.sh"
  say ""; say "Зупиняюсь: пам'ять у підтеці жоден чат не знайде."; exit 1
fi
if [ -z "$(git config user.email 2>/dev/null)" ]; then
  bad "git не знає твого email" "git config --global user.email \"твій@email\" (і user.name) — без цього коміти не працюють"
else
  say "   ✓ git user.email: $(git config user.email)"
fi

# ── 3. Комплект parallel-ai-dev (пам'ять) ─────────────────────────────────────
say "3/7 Комплект «пам'ять проєкту» (parallel-ai-dev)"
PAD_DIR=""
for d in "$KIT_HOME/parallel-ai-dev" "$PROJECT_DIR/../parallel-ai-dev" "$PROJECT_DIR/../../parallel-ai-dev"; do
  if [ -d "$d/.git" ]; then PAD_DIR="$(cd "$d" && pwd)"; break; fi
done
if [ -n "$PAD_DIR" ]; then
  say "   • знайдено: $PAD_DIR — оновлюю (другу копію НЕ ставлю)"
  git -C "$PAD_DIR" pull --ff-only -q origin main 2>/dev/null && say "   ✓ свіжий" \
    || say "   ⚠ git pull не пройшов (немає мережі або локальні зміни) — працюю з тим, що є"
else
  PAD_DIR="$KIT_HOME/parallel-ai-dev"
  if git clone -q "$PAD_REPO" "$PAD_DIR" 2>/dev/null; then say "   ✓ склоновано у $PAD_DIR"; else
    bad "Не вдалося склонувати parallel-ai-dev" "Перевір мережу і запусти: git clone $PAD_REPO $PAD_DIR"; PAD_DIR=""; fi
fi
if [ -n "$PAD_DIR" ]; then
  say "   • init-memory у проєкті:"
  if (cd "$PROJECT_DIR" && bash "$PAD_DIR/scripts/init-memory.sh" 2>&1 | sed 's/^/     /'); then
    ok "Пам'ять проєкту розгорнута ($PAD_DIR)"
  else
    bad "init-memory.sh повернув помилку" "Прочитай вивід вище і запусти: cd $PROJECT_DIR && bash $PAD_DIR/scripts/init-memory.sh"
  fi
fi

# ── 4. Скіли /tz-* ───────────────────────────────────────────────────────────
say "4/7 Скіли Claude Code → $SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
INSTALLED=0
for s in tz-draft tz-review tz-verify tz-go; do
  src="$TZ_ROOT/skills/$s"; dst="$SKILLS_DIR/$s"
  [ -d "$src" ] || continue
  rm -rf "$dst.tmp-bootstrap" && cp -r "$src" "$dst.tmp-bootstrap" && rm -rf "$dst" && mv "$dst.tmp-bootstrap" "$dst" \
    && { say "   ✓ /$s"; INSTALLED=$((INSTALLED+1)); } || say "   ✗ /$s не скопіювався"
done
if [ "$INSTALLED" -eq 4 ]; then ok "4 команди /tz-draft /tz-review /tz-verify /tz-go встановлено"; else
  bad "Встановлено $INSTALLED/4 скілів" "Перевір права на $SKILLS_DIR і запусти: bash $TZ_ROOT/lib/tz-skills-update.sh"; fi

# ── 5. Критики: providers.json + ключ NVIDIA ─────────────────────────────────
say "5/7 Критики (providers.json → $PROVIDERS)"
mkdir -p "$(dirname "$PROVIDERS")"
if [ ! -f "$PROVIDERS" ]; then
  cat > "$PROVIDERS" <<'JSON'
{
  "_comment": "Профіль «маю лише Claude»: claude-cli + два БЕЗКОШТОВНІ NVIDIA NIM різних вендорів. Ключ NVIDIA_API_KEY — з build.nvidia.com (безкоштовно, без картки). Моделі перевірені 01.09.2026; якщо якась дає 404/410 — NVIDIA її зняла: візьми іншого вендора з каталогу і прожени llm-critic.sh --smoke-all.",
  "critics": {
    "critic_a": { "backend": "claude-cli" },
    "critic_b": { "backend": "nim", "model": "openai/gpt-oss-120b", "api_key_env": "NVIDIA_API_KEY" },
    "critic_c": { "backend": "nim", "model": "minimaxai/minimax-m3", "api_key_env": "NVIDIA_API_KEY" }
  }
}
JSON
  say "   ✓ створено профіль «лише Claude + 2 безкоштовні NIM»"
  ok "providers.json створено"
else
  say "   • вже є — не чіпаю"
  if grep -qE 'deepseek-ai/deepseek-r1|qwen/qwen2.5-coder-32b-instruct' "$PROVIDERS"; then
    bad "У providers.json мертві моделі NIM (deepseek-r1 / qwen2.5-coder — зняті NVIDIA)" "Заміни в $PROVIDERS на openai/gpt-oss-120b і minimaxai/minimax-m3, потім llm-critic.sh --smoke-all"
  else
    ok "providers.json уже був — залишено твій"
  fi
fi
if [ -z "${NVIDIA_API_KEY:-}" ]; then
  if grep -qs 'NVIDIA_API_KEY' "$HOME/.bashrc" 2>/dev/null; then
    info "NVIDIA_API_KEY є в ~/.bashrc, але не в цьому терміналі — після перезапуску терміналу підхопиться"
  fi
  bad "Немає ключа NVIDIA_API_KEY — два критики з трьох не працюватимуть" "ЛЮДИНА: зайти на https://build.nvidia.com (вхід через Google, картка не потрібна) → https://build.nvidia.com/settings/api-keys → Generate API Key (nvapi-…). Потім: echo 'export NVIDIA_API_KEY=\"nvapi-…\"' >> ~/.bashrc && source ~/.bashrc"
else
  say "   ✓ NVIDIA_API_KEY є в оточенні"
fi

# ── 6. IMMUNE у CLAUDE.md проєкту ─────────────────────────────────────────────
say "6/7 IMMUNE — правила проти гниття коду → CLAUDE.md"
BLOCK="$TZ_ROOT/docs/IMMUNE_CLAUDE_BLOCK.md"
if [ ! -f "$BLOCK" ]; then
  bad "Файл $BLOCK не знайдено" "Онови tz-skills: git -C $TZ_ROOT pull --ff-only"
elif [ -f "$PROJECT_DIR/CLAUDE.md" ] && grep -q 'Правила проти гниття коду (IMMUNE)' "$PROJECT_DIR/CLAUDE.md"; then
  say "   • блок уже є — не дублюю"; ok "IMMUNE уже в CLAUDE.md"
else
  { printf '\n'; cat "$BLOCK"; } >> "$PROJECT_DIR/CLAUDE.md" && { say "   ✓ дописано в кінець CLAUDE.md"; ok "IMMUNE дописано в CLAUDE.md"; } \
    || bad "Не вдалося дописати IMMUNE" "Скопіюй вміст $BLOCK у кінець $PROJECT_DIR/CLAUDE.md руками"
fi

# ── 7. Коміт створеного + перевірки ───────────────────────────────────────────
say "7/7 Коміт і перевірки"
if [ -n "$(git config user.email 2>/dev/null)" ]; then
  git add CLAUDE.md CLAUDE.parallel-ai-dev.md coordination 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -q -m "kit: пам'ять проєкту (parallel-ai-dev) + правила IMMUNE" && say "   ✓ закомічено файли комплекту" \
      || bad "git commit не пройшов" "Подивись, що каже git у $PROJECT_DIR, і закоміть CLAUDE.md + coordination/ руками"
  else
    say "   • нічого нового комітити"
  fi
fi

say "   • self-check пам'яті:"
if [ -n "$PAD_DIR" ]; then
  if (cd "$PROJECT_DIR" && bash "$PAD_DIR/scripts/self-check.sh" 2>&1 | sed 's/^/     /'); then
    ok "self-check: ✅ СИСТЕМА ГОТОВА"
  else
    bad "self-check пам'яті має червоні рядки (це очікувано на свіжій системі)" "CLAUDE: заповни coordination/SETUP.md (visibility, mode), coordination/PROJECT_MAP.md (що в проєкті вже є), coordination/DECISIONS.md (3-5 рішень з полем «Чому»), секцію «Зони цього проєкту» в CLAUDE.md; закоміть і запуш; повтори bash $PAD_DIR/scripts/self-check.sh"
  fi
fi

say "   • smoke-тест критиків:"
if TZ_PROVIDERS_CONFIG="$PROVIDERS" bash "$TZ_ROOT/lib/llm-critic.sh" --smoke-all 2>&1 | sed 's/^/     /'; then
  ok "Критики: усі 3 слоти відповідають"
else
  bad "Критики: не всі 3 слоти живі — /tz-review і /tz-go зупиняться або працюватимуть ослаблено" "Полагодь червоний слот (найчастіше — немає NVIDIA_API_KEY або claude не в PATH) і повтори: TZ_PROVIDERS_CONFIG=$PROVIDERS bash $TZ_ROOT/lib/llm-critic.sh --smoke-all"
fi

# ── Підсумок ──────────────────────────────────────────────────────────────────
hr; say "ПІДСУМОК"; hr
for r in "${ROWS[@]}"; do say "$r"; done
if [ "$RED" -eq 1 ]; then
  hr; say "ЩО ЗРОБИТИ (по одному пункту, зверху вниз):"
  i=1; for t in "${TODO[@]}"; do say "$i. $t"; i=$((i+1)); done
  hr; say "Червоне — не поломка, а чек-лист. Коли все зроблено — запусти скрипт ще раз: він нічого не перезапише."
  exit 1
fi
hr; say "✅ Усе зелене. Команди: /tz-go (усе сам) · /tz-draft · /tz-review · /tz-verify"
exit 0
