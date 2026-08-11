#!/usr/bin/env bash
# tz-skills-update.sh — оновити комплект і чесно перевірити, чи він свіжий.
#
# ЧОМУ ЦЕЙ СКРИПТ ІСНУЄ (важливо для тих, хто його правитиме).
#
# Встановлення скілів — це КОПІЮВАННЯ з клону в ~/.claude/skills/. Тому питання
# «чи в мене свіжа версія» насправді ДВА різні питання:
#
#     GitHub  ←(1)→  твій клон ~/tz-skills  ←(2)→  інсталяція ~/.claude/skills
#
#   (1) клон відстав від GitHub          — `git pull` не робили місяцями
#   (2) інсталяція відстала від клону    — `git pull` зробили, а скопіювати забули
#
# Перевірка, яка дивиться ЛИШЕ на (2), зелена НАЗАВЖДИ: клон роками стоїть на
# старому коміті, інсталяція йому відповідає — «все свіже», а людина сидить на
# торішній версії. Це петля, замкнена сама на себе. Тому `--check` ЗАВЖДИ
# ходить у мережу до origin і, якщо не зміг туди достукатись, повертає помилку,
# а НЕ «все добре». Перевірка, яка не змогла зробити свою роботу, мусить
# падати — інакше вона гірша за відсутню.
#
# Використання:
#   bash lib/tz-skills-update.sh            # оновити: pull + перевстановити скіли
#   bash lib/tz-skills-update.sh --check    # тільки перевірити, нічого не міняти
#   bash lib/tz-skills-update.sh --version  # показати встановлену версію
#
# Коди виходу: 0 — усе свіже / оновлено; 3 — є відставання; 2 — перевірити не вдалося.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
SKILLS="tz-draft tz-review tz-verify tz-go"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Хеш теки: імена файлів + вміст. Порівнюємо інсталяцію з клоном побайтово,
# щоб зловити і «забув скопіювати», і «випадково відредагував інсталяцію».
dir_hash() {
  local d="$1"
  [ -d "$d" ] || { printf 'MISSING'; return 0; }
  ( cd "$d" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      openssl dgst -sha256 "$f" | awk '{print $NF}'
    done | openssl dgst -sha256 | awk '{print $NF}' )
}

is_git_clone() { git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; }

current_branch() {
  git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || echo master
}

# --- (1) клон ↔ GitHub -------------------------------------------------------
# Повертає: fresh | behind | diverged; або падає з кодом 2, якщо не зміг перевірити.
check_remote() {
  if ! is_git_clone; then
    warn "❌ Не можу перевірити свіжість: $REPO — не git-клон (схоже, комплект"
    warn "   завантажено як ZIP). Онови вручну — перезавантаж ZIP зі сторінки"
    warn "   https://github.com/ymaxymovych/tz-skills і перевстанови скіли,"
    warn "   або постав через 'git clone', і оновлення стане однією командою."
    return 2
  fi
  local br; br="$(current_branch)"
  if ! git -C "$REPO" fetch --quiet origin "$br" 2>/dev/null; then
    warn "❌ Не можу перевірити свіжість: не достукався до GitHub (немає мережі"
    warn "   чи origin недоступний). Це НЕ означає «все свіже» — просто спробуй"
    warn "   пізніше."
    return 2
  fi
  # Рахуємо ОБИДВА напрямки. Інакше «клон попереду» (студент зробив власні
  # коміти) не відрізнити від «клон розійшовся» — а це різні стани: у першому
  # з GitHub нічого не бракує, у другому оновлення впаде.
  local counts ahead behind
  counts="$(git -C "$REPO" rev-list --left-right --count HEAD...FETCH_HEAD 2>/dev/null || echo '')"
  [ -n "$counts" ] || { warn "❌ Не можу порівняти клон із GitHub (git rev-list не відпрацював)."; return 2; }
  ahead="$(printf '%s' "$counts"  | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  if   [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then printf 'fresh'
  elif [ "$behind" -gt 0 ] && [ "$ahead" -eq 0 ]; then printf 'behind %s' "$behind"
  elif [ "$behind" -eq 0 ] && [ "$ahead" -gt 0 ]; then printf 'ahead %s'  "$ahead"
  else printf 'diverged %s %s' "$ahead" "$behind"; fi
}

# --- (2) інсталяція ↔ клон ---------------------------------------------------
stale_installs() {
  local out=""
  for s in $SKILLS; do
    local src="$REPO/skills/$s" dst="$DEST/$s"
    [ -d "$src" ] || continue
    if [ "$(dir_hash "$src")" != "$(dir_hash "$dst")" ]; then out="$out $s"; fi
  done
  printf '%s' "${out# }"
}

installed_version() {
  if is_git_clone; then
    git -C "$REPO" log -1 --format='%h — %ad — %s' --date=short 2>/dev/null || echo "невідома"
  else
    echo "невідома (не git-клон)"
  fi
}

reinstall() {
  mkdir -p "$DEST"
  for s in $SKILLS; do
    [ -d "$REPO/skills/$s" ] || continue
    rm -rf "$DEST/$s.tmp-update"
    cp -r "$REPO/skills/$s" "$DEST/$s.tmp-update"
    rm -rf "$DEST/$s"
    mv "$DEST/$s.tmp-update" "$DEST/$s"
    say "   ✓ $s"
  done
}

case "${1:-}" in
  --version)
    say "Версія комплекту: $(installed_version)"
    stale="$(stale_installs)"
    [ -z "$stale" ] || say "⚠️  Але інсталяція відстала від клону:$stale (запусти оновлення)"
    ;;

  --check)
    rc=0
    say "Перевіряю дві речі: чи свіжий клон і чи свіжа інсталяція."
    say ""
    remote_state="$(check_remote)" || { exit 2; }
    # shellcheck disable=SC2086
    set -- $remote_state
    case "$1" in
      fresh)  say "1/2 ✅ Клон збігається з GitHub." ;;
      behind) say "1/2 ⚠️  Клон ВІДСТАВ від GitHub на $2 коміт(и) — є новіша версія."; rc=3 ;;
      ahead)  say "1/2 ℹ️  Клон ПОПЕРЕДУ GitHub на $2 коміт(и) — власні локальні зміни."
              say "        З GitHub нічого не бракує; це не застарілість." ;;
      diverged) say "1/2 ⚠️  Клон РОЗІЙШОВСЯ з GitHub: $2 своїх коміт(и), $3 чужих."
                say "        Оновлення в такому стані не пройде — розберись із клоном."; rc=3 ;;
    esac
    stale="$(stale_installs)"
    if [ -z "$stale" ]; then
      say "2/2 ✅ Скіли в $DEST збігаються з клоном."
    else
      say "2/2 ⚠️  Інсталяція ВІДСТАЛА від клону:$stale"
      say "        (клон оновили, а скопіювати в ~/.claude/skills забули)"
      rc=3
    fi
    say ""
    if [ "$rc" -eq 0 ]; then
      say "Все свіже. Версія: $(installed_version)"
    else
      say "Онови однією командою:  bash $REPO/lib/tz-skills-update.sh"
    fi
    exit "$rc"
    ;;

  ""|--apply)
    say "Оновлюю комплект…"
    if is_git_clone; then
      br="$(current_branch)"
      before="$(git -C "$REPO" rev-parse HEAD)"
      if git -C "$REPO" pull --ff-only --quiet origin "$br" 2>/dev/null; then
        after="$(git -C "$REPO" rev-parse HEAD)"
        if [ "$before" = "$after" ]; then
          say "1/2 Клон уже був свіжий."
        else
          say "1/2 Клон оновлено. Що змінилось:"
          git -C "$REPO" log --oneline "$before..$after" | sed 's/^/      /'
        fi
      else
        warn "❌ git pull не пройшов (немає мережі, або в клоні є локальні зміни,"
        warn "   які заважають ff-only). Скіли НЕ оновлено — розберись із клоном"
        warn "   у $REPO і запусти ще раз."
        exit 2
      fi
    else
      warn "⚠️  $REPO — не git-клон, оновити автоматично не можу."
      warn "   Перевстанови зі свіжого ZIP і запусти цю команду знову."
      exit 2
    fi
    say "2/2 Перевстановлюю скіли в $DEST:"
    reinstall
    say ""
    say "Готово. Версія: $(installed_version)"
    say "Перевір критиків:  bash $REPO/lib/llm-critic.sh --smoke-all"
    ;;

  *)
    warn "Невідомий аргумент: $1"
    warn "Використання: tz-skills-update.sh [--check | --version | --apply]"
    exit 64
    ;;
esac
