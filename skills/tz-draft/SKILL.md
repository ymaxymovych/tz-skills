---
name: tz-draft
description: Interview the user about BUSINESS logic only (one question at a time, max ~7 questions, multiple-choice preferred) and turn the answers into a complete TZ draft with acceptance criteria, ready for /tz-review. Technical choices (OS, server, DB, framework, libraries, architecture) are NEVER asked — the agent decides them itself and records them in the draft as overridable defaults. Invoke when the user brings a raw idea, a vague feature request, or says "напиши ТЗ" / "draft a spec" before any TZ exists.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# TZ Draft — business-logic elicitation before the spec exists

Upstream companion to `/tz-review` and `/tz-verify`. The pipeline is:

```
raw idea → /tz-draft (this skill: interview → TZ draft)
         → /tz-review (3 critics audit the TZ)
         → implementation
         → /tz-verify (3 critics verify it was built)
```

Methodology adapted from the Superpowers `brainstorming` skill (obra/superpowers, MIT):
one question at a time, multiple-choice when possible, ruthless YAGNI, design validated
in sections. Narrowed here to **business logic only** — the single biggest failure mode
this skill prevents is an agent that either (a) interrogates a non-technical founder
about servers and databases, or (b) silently invents business rules nobody asked for.

## The one hard rule

**You may ask the user ONLY about business logic. You may NEVER ask about technology.**

| ✅ ASK about (business) | ❌ NEVER ASK about (technical — decide yourself) |
|---|---|
| Who uses this? What job does it do for them? | OS, hosting, server, cloud provider |
| What does "success" look like, in numbers if possible? | Database, schema, ORM |
| What must happen when X pays / cancels / fails? | Language, framework, library choice |
| Who is allowed to see/do what? (roles, in business terms) | Architecture, API shape, file naming |
| What is explicitly OUT of scope for v1? | Auth mechanism, token format |
| What already exists that this must not break? | Deployment, CI, testing strategy |
| Edge cases in business terms ("what if the client has two contracts?") | Rate limits, caching, queues |
| Priorities: which half ships first if we must cut? | Any "which tool" question |

Every technical decision you would have asked about — make it yourself, pick the
boring/standard option for this codebase, and record it in the draft under
**"Технічні рішення за замовчуванням"** with one line of reasoning each. The user can
veto any of them by reading the draft; they should never have to answer them live.

## Interview protocol

### Step 0 — Look before asking

Before the first question, spend 2-3 minutes grounding yourself so you don't ask what
you can answer:
- Read the codebase enough to know what already exists (grep for the feature area,
  read the relevant models/routes). A question the code already answers is spam.
- Locate `{TZ_DIR}` per the `/tz-review` convention (`.ai-context/` → else `docs/specs/`
  or `docs/tz/` → else create `docs/tz/`).
- If the user's opening message already answers something — never re-ask it.

### Step 1 — Ask, one at a time

- **One question per message. Never a numbered list of questions.** (Superpowers rule —
  batched questions get half-answered and the gaps go unnoticed.)
- **Multiple-choice whenever the option space is guessable**, with your recommended
  option first and marked. Open-ended only when you genuinely can't enumerate.
- **Budget: ~7 questions, hard cap 10.** This is an interview, not an interrogation.
  Order questions by how much a wrong guess would cost — money flows and permissions
  first, cosmetics never.
- **The user can stop anytime** ("досить", "далі сам", "just draft it") → immediately
  stop asking, fill remaining gaps with clearly-marked assumptions, and proceed to Step 2.
- If an answer reveals the request is actually two projects → say so, ask which one is v1,
  and scope the draft to that one (YAGNI).

Good first question is almost always some form of: *"Хто цим користуватиметься і яку
проблему це для нього закриває?"* — unless the opening message already answered it.

### Step 2 — Propose the shape, get one approval

Before writing the full TZ, present a **5-10 line summary**: goal, user, core flow,
explicit non-goals, the 2-3 riskiest business rules as you understood them. If there were
2-3 genuinely different ways to fulfil the request, present them here with trade-offs and
your recommendation (Superpowers pattern) — but only if the difference is visible to the
BUSINESS, not merely architectural.

Ask exactly one thing: **"Так — пишу повне ТЗ? Чи щось із цього не так?"**
Iterate on the summary until approved. Do not write the full document before approval —
a wrong summary costs one message to fix; a wrong 300-line TZ costs an evening.

### Step 3 — Write the draft

Write `{TZ_DIR}/TZ_{slug}.md`:

```markdown
# TZ: {назва} (draft v1 — /tz-draft, {date})

## 1. Мета і бізнес-контекст
{чию проблему вирішуємо, чому зараз, як міряємо успіх}

## 2. Користувачі та ролі
{хто, що кому дозволено — бізнес-термінами}

## 3. Основний сценарій
{крок за кроком очима користувача}

## 4. Бізнес-правила
{гроші, доступи, ліміти, дедлайни — все, що випитано; нумеровані, по одному правилу на пункт}

## 5. Крайні випадки (бізнес)
{що робимо коли: подвійна оплата, скасування, порожні дані, конфлікт...}

## 6. Поза scope v1
{явний список того, що НЕ робимо — з відповідей і YAGNI-зрізань}

## 7. Acceptance Criteria
{AC-1..AC-N — кожен перевірний, у форматі, який /tz-verify зможе розібрати;
 один критерій = одне твердження, без "and"}

## 8. Технічні рішення за замовчуванням (прийняв агент — можна ветувати)
{кожен рядок: рішення + 1 речення чому; сюди йде ВСЕ, про що ти НЕ питав}

## 9. Відкриті ризики
{що лишилось невідомим; припущення, зроблені після "досить"— позначені ⚠️ ПРИПУЩЕННЯ}
```

Section 7 is the contract with `/tz-verify` — write each AC so it can be judged
done/missing against a diff. Section 8 is the contract with the no-tech-questions rule —
it's where your technical autonomy becomes visible and vetoable instead of silent.

### Step 4 — Hand off

Tell the user in 2-3 lines: draft is at `{path}`, what the ⚠️ assumptions are (if any),
and that the next step is `/tz-review {path}` when they're ready. Do NOT auto-run
`/tz-review` — it is expensive; the user triggers it.

## Anti-patterns

- Asking two questions in one message. One. Always one.
- Asking anything from the ❌ column — if you catch yourself typing "яку базу даних…", stop,
  decide it yourself, put it in section 8.
- Asking questions whose answer is already in the user's first message or in the codebase.
- Writing the full TZ before the Step 2 summary is approved.
- Inventing business rules that were neither asked about nor answered — every rule in
  section 4 must trace to an answer or be flagged ⚠️ ПРИПУЩЕННЯ in section 9.
- Dragging past the question budget because "one more would make it perfect". Ship the
  draft; `/tz-review` exists precisely to catch what the interview missed.
- Turning this into architecture brainstorming. Business shape only; architecture is
  implementation's job.

## When NOT to invoke

- A TZ already exists → go straight to `/tz-review`.
- The request is a bugfix or trivial change → just do it, no interview.
- The user gave an already-complete spec in the message → write it up (Step 3) and skip
  the interview entirely, noting "інтерв'ю пропущено — вхід був повний".
