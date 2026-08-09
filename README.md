# TZ Skills — крос-перевірка технічних завдань для Claude Code

> **EN (short):** A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill pipeline from rough spec to verified implementation: `/tz-draft` strengthens YOUR draft spec via answer-first business questions (type «ФІНІШ» to accept its answers and finish anytime); `/tz-review` audits the spec with **three independent LLMs of different vendors**; `/worktree-start` isolates the work; `/tz-verify` checks it was truly implemented; `/worktree-finish` lands the branch. Each critic slot is pluggable: local **Claude / Codex / Gemini CLI**, **OpenRouter**, or **free NVIDIA NIM** models. Start with [docs/SETUP.md](docs/SETUP.md).

Конвеєр скілів для Claude Code, який прибирає головну проблему AI-розробки:
**Claude каже «зробив», а насправді відхилився від задачі або пропустив половину.**

```
чернетка ТЗ → /tz-draft → /tz-review → /worktree-start → реалізація → /tz-verify → /worktree-finish
              (підсилення) (аудит ТЗ)   (ізоляція)                     (перевірка)   (здача + прибирання)
```

- **`/tz-draft`** — приносиш **свою чернетку ТЗ** (або сиру ідею), скіл спершу каже, як він
  зрозумів **Job-to-be-Done** задачі, а далі закриває прогалини бізнес-логіки питаннями
  **у форматі «питання + моя рекомендована відповідь + чому вона правильна»** — тобі
  досить казати «так». По одному питанню за раз (бюджет ~7), **тільки про бізнес**;
  технічне (ОС, сервер, база, фреймворк) агент вирішує сам і записує у ТЗ секцією
  «рішення за замовчуванням», яку можна ветувати. У кінці кожного повідомлення — кодове
  слово **«ФІНІШ»**: пишеш його — скіл приймає власні відповіді на все, що лишилось, і
  одразу видає **підсилену версію ТВОГО ТЗ** (твій текст зберігається, прогалини
  заповнюються, зміни перелічені у changelog вгорі документа) + команду для `/tz-review`.
  Концепція — авторська; механіка питань адаптована з
  [Superpowers brainstorming](https://github.com/obra/superpowers) (MIT).

- **`/tz-review`** — перевіряє **технічне завдання (ТЗ) ПЕРЕД** тим, як віддати його в роботу.
  Три незалежні LLM читають ТЗ за фіксованим чек-листом з 11 категорій (безпека, дані,
  приховані припущення, крайні випадки, UX/UI…), 3 ітерації, з перевіркою фактів у вебі.
  Результат — знайдені діри у ТЗ і покращена версія.

- **`/tz-verify`** — перевіряє, що **ТЗ реально виконано ПІСЛЯ** роботи, перед мерджем/деплоєм.
  Розбиває ТЗ на критерії приймання, і три незалежні LLM звіряють кожен критерій із реальним
  git-diff. Результат — вердикт з 5 рівнів
  (`BLOCK` / `FIX-FIRST` / `SAFE-TO-COMMIT` / `SAFE-TO-DEPLOY-AFTER-CHECK` / `INSUFFICIENT-EVIDENCE`)
  і чесний список: що зроблено, а що ні.

- **`/worktree-start`** — перед реалізацією ізолює роботу у власному git worktree, щоб
  паралельні Claude-сесії не затирали незакомічену роботу одна одної. Перевіряє, чи ти вже
  не в worktree, ставить гілку `feat/{назва-ТЗ}`, ганяє baseline-перевірку до першої правки.

- **`/worktree-finish`** — здача: спершу зелений гейт (тести/типи/лінт + вердикт
  `/tz-verify`), потім меню «merge локально / push + PR / лишити», потім прибирання
  worktree і гілки. Викинути незамерджену роботу можна ЛИШЕ написавши буквально слово
  «discard». Обидва worktree-скіли адаптовані зі
  [Superpowers](https://github.com/obra/superpowers) (`using-git-worktrees`,
  `finishing-a-development-branch`, MIT).

## Чому це працює

Одна модель, яка сама пише і сама себе перевіряє — це «машина самопохвали». Тому обидва скіли
використовують **три РІЗНІ моделі різних вендорів** як незалежних критиків, які не бачать
відповідей одне одного. Розбіжність між ними — і є сигнал «дивись сюди уважно». Плюс жорсткі
запобіжники: кожна знахідка мусить цитувати конкретне місце (інакше відкидається як
галюцинація), захист від prompt-injection, перевірка фактів.

## Універсальність провайдерів

Три критики — це **абстрактні слоти** `critic_a` / `critic_b` / `critic_c`. Кожен через
`providers.json` підключається до будь-чого:

| Бекенд | Що це | Вартість |
|---|---|---|
| `claude-cli` | локальний Claude Code CLI | твоя підписка |
| `codex-cli` | локальний OpenAI Codex CLI | твоя підписка |
| `gemini-cli` | локальний Google Gemini CLI | безкоштовно/підписка |
| `openrouter` | будь-яка модель через OpenRouter API | платно per-token |
| `nim` | безкоштовні моделі NVIDIA NIM (DeepSeek, Qwen…) | **безкоштовно** |

Маєш **лише Claude**? Достатньо: `claude-cli` + дві різні **безкоштовні** NVIDIA NIM моделі.
Єдине жорстке правило — **три слоти = різні вендори** (два однакових = ехо, а не перевірка).
Усе маршрутизує один скрипт [`lib/llm-critic.sh`](lib/llm-critic.sh).

## Швидке встановлення

```bash
# 1. Клонувати
git clone https://github.com/ymaxymovych/tz-skills.git ~/tz-skills
cd ~/tz-skills
chmod +x lib/llm-critic.sh skills/tz-verify/fanout-dispatch.sh

# 2. Поставити скіли у Claude Code
mkdir -p ~/.claude/skills
cp -r skills/tz-draft skills/tz-review skills/tz-verify skills/worktree-start skills/worktree-finish ~/.claude/skills/

# 3. Налаштувати провайдерів
cp providers.example.json ~/.claude/tz-providers.json
#   → відредагуй, обери профіль, встав ключі в ENV (див. docs/GET_FREE_TOKENS.md)

# 4. Перевірити
bash lib/llm-critic.sh --smoke-all      # усі три слоти → OK

# 5. Користуватись у Claude Code:
#    /tz-draft  опиши ідею       (ще немає ТЗ — інтерв'ю і драфт)
#    /tz-review шлях/до/ТЗ.md    (перед роботою)
#    /tz-verify шлях/до/ТЗ.md    (після роботи)
```

## Документація

- 📦 **[docs/SETUP.md](docs/SETUP.md)** — покрокове встановлення за 10 хвилин.
- 🔑 **[docs/GET_FREE_TOKENS.md](docs/GET_FREE_TOKENS.md)** — прямі лінки на реєстрацію
  NVIDIA NIM (безкоштовно) та OpenRouter, як поповнити перші $5, найдешевші моделі.
- ⚙️ **[providers.example.json](providers.example.json)** — конфіг + 4 готові профілі.

## Вимоги

- **bash** (Windows → Git Bash), **python3** *або* **jq**, **curl**, **openssl**.
- Хоча б один робочий LLM-бекенд (Claude CLI у складі Claude Code — вже є).

## Мінімальний `providers.json` ($0, тільки Claude + безкоштовний NIM)

```json
{
  "critics": {
    "critic_a": { "backend": "claude-cli" },
    "critic_b": { "backend": "nim", "model": "deepseek-ai/deepseek-r1" },
    "critic_c": { "backend": "nim", "model": "qwen/qwen2.5-coder-32b-instruct" }
  }
}
```

---

> ⚠️ Це «інструмент мислення», а не CI-гейт. Скіли ловлять типові провали (галюцинації,
> пропущені критерії, prompt-injection, самопідтвердження), але фінальне рішення
> «мерджити чи ні» — за людиною.

## Ліцензія

[MIT](LICENSE). Дизайн скілів заґрунтований на дослідженнях мультиагентних систем 2025–2026
(checklist-driven prompting, parallel-independent critique, Microsoft Spotlighting проти
prompt-injection). Деталі — всередині кожного `SKILL.md`.
