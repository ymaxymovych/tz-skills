---
name: tz-draft
description: Take the user's rough TZ draft (or raw idea), open by stating the Job-to-be-Done as you read it, then interrogate the BUSINESS logic gaps — one question at a time, each question ALREADY ANSWERED by you with the recommended option and why it's right, so the user only confirms or corrects. Every message ends with the code word «ФІНІШ» — typing it accepts all your remaining recommended answers and immediately produces the STRENGTHENED version of the user's own TZ (their text preserved, gaps filled, changes listed), ready for /tz-review. Technical choices (OS, server, DB, framework) are NEVER asked — the agent decides them and records them as vetoable defaults. Invoke when the user brings a draft TZ, a raw idea, or says "прожени ТЗ" / "напиши ТЗ".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# TZ Draft — answer-first business elicitation over a rough spec

Upstream companion to `/tz-review` and `/tz-verify`. The pipeline is:

```
чернетка ТЗ (або ідея) → /tz-draft (JTBD → питання-з-відповідями → ПІДСИЛЕНЕ твоє ТЗ)
                       → /tz-review (3 критики аудитують ТЗ)
                       → реалізація
                       → /tz-verify (3 критики перевіряють виконання)
```

**Attribution.** The core concept of this skill — strengthen an EXISTING draft rather than
write from scratch; answer-first questioning (agent proposes the best answer with each
question); the «ФІНІШ» code-word exit — is by this pack's author. Only the low-level
question mechanics (one question at a time, multiple-choice preferred, YAGNI,
validate-before-writing) are adapted from the Superpowers `brainstorming` skill
(obra/superpowers, MIT). The narrowing to **business logic only** and the **answer-first**
protocol — the agent never asks a bare question; it asks AND proposes the single best
answer with reasoning, so the user's minimum viable participation is «так» — are this
pack's design, not Superpowers'.

## The two hard rules

**Rule 1 — business only.** You may ask the user ONLY about business logic. Never about technology.

| ✅ ASK about (business) | ❌ NEVER ASK (technical — decide yourself) |
|---|---|
| Who uses this? What job does it do for them? | OS, hosting, server, cloud |
| What does "success" look like, in numbers? | Database, schema, ORM |
| What happens when X pays / cancels / fails? | Language, framework, library |
| Who may see/do what? (roles, business terms) | Architecture, API shape |
| What is explicitly OUT of scope for v1? | Auth mechanism, tokens |
| What existing flows must this not break? | Deployment, CI, testing strategy |
| Business edge cases ("клієнт має два контракти?") | Rate limits, caching, queues |
| Priorities: which half ships first if we cut? | Any "which tool" question |

Every technical decision you would have asked — make it yourself (boring/standard option
for this codebase) and record it in the TZ under **«Технічні рішення за замовчуванням»**
with one line of reasoning. Vetoable by reading, never asked live.

**Rule 2 — answer-first.** Every question you ask must arrive WITH your recommended answer
and the reason it is the most correct one. A bare question mark is a protocol violation.
The user's job is to confirm, correct, or type the code word — not to think from zero.

## Interview protocol

### Step 0 — Ingest what was brought

The normal input is a **draft TZ the user already wrote somewhere** (file path or pasted
text). Also accepted: a raw idea in a few sentences.

1. Read the draft carefully. Read the codebase around the feature area (grep models,
   routes, existing flows) — a question the draft or the code already answers is spam.
2. Locate `{TZ_DIR}` per the `/tz-review` convention (`.ai-context/` → else `docs/specs/`
   or `docs/tz/` → else create `docs/tz/`).
3. Build the gap list: which business questions the draft leaves unanswered, ordered by
   the cost of guessing wrong (money flows and permissions first, cosmetics never).
   Budget: **~7 questions, hard cap 10.**

### Step 1 — Open with the Job-to-be-Done (always first, before any question)

Your first message states, in 3-5 lines, the JTBD as you read it from the draft:

```
📋 Як я зрозумів задачу (JTBD):
Коли [ситуація], [хто] хоче [що зробити], щоб [бізнес-результат/прогрес].
Успіх виглядає так: [метрика/спостережуваний наслідок].

Це правильне прочитання? («так» / поправ мене / «ФІНІШ»)
```

This is question #0 and the cheapest place to catch a wrong direction. If the user
corrects it — the correction reorders your gap list before you continue.

### Step 2 — Questions, answer-first, one at a time

**One question per message. Never a list.** Each message has this exact shape:

```
Питання {N}/{budget}: {питання}

Чому питаю: {1-2 речення — що зламається в бізнесі, якщо вгадати неправильно}

Варіанти:
  a) {варіант}
  b) {варіант}
  c) {варіант}

✅ Моя відповідь: {літера}) — {чому саме вона найправильніша: 1-3 речення,
   з опорою на драфт/кодову базу/здоровий глузд}

— «так» = приймаємо мою відповідь, іду далі
— або дай свою відповідь / поправку
— «ФІНІШ» = приймаєш мої відповіді на ВСІ питання, що лишились, і я одразу пишу ТЗ
```

Mechanics:
- User says «так» (or anything affirmative) → lock the answer, next question.
- User gives a different answer → lock THEIR answer, next question. Never argue twice:
  you may push back ONCE if their answer creates a concrete business risk, then accept.
- If an answer reveals the request is really two projects → say so, propose which is v1,
  scope to it (YAGNI).
- The **last question of every interview is a pre-mortem** (counts inside the budget):
  *"Уяви: місяць після запуску, фіча провалилась. Найімовірніша причина?"* — with your
  proposed answer. Whatever the user confirms lands in «Відкриті ризики».

### The code word — «ФІНІШ»

The interrupt contract, printed at the end of EVERY message of this skill (JTBD opening,
every question, every clarification):

> Напишіть **«ФІНІШ»** — я прийму власні запропоновані відповіді на всі питання, що
> лишились, одразу напишу повне ТЗ і дам команду для наступного кроку (`/tz-review`).

Semantics of «ФІНІШ»:
- Stop asking immediately. Zero further questions.
- All remaining gap-list questions are auto-resolved with YOUR recommended answers.
- Immediately produce the **strengthened version of the user's own TZ** (Step 4 — this is
  an edit of their document, not a new document).
- In the TZ, human-confirmed rules are written plainly; auto-accepted ones are marked
  **«✅ авто-прийнято (ФІНІШ)»** — so the user can later scan exactly what they delegated.
- Anything you genuinely could not answer even yourself → **«⚠️ ПРИПУЩЕННЯ»** in
  «Відкриті ризики».

Also treat as ФІНІШ: "досить", "далі сам", "just draft it", "переходь до рев'ю" — any
clear stop signal. The explicit footer exists so the user never has to wonder HOW to
stop you; but you must recognize informal stops too.

### Step 3 — Summary gate, then the edits

After the interview (completed or ФІНІШed), post a **5-10 line summary**: goal, user,
core flow, non-goals, the 2-3 riskiest confirmed business rules. One question only:
**«Так — вношу правки у твоє ТЗ?»** (with the ФІНІШ footer; ФІНІШ here means "yes, do it").
A wrong summary costs one message; a wrong 300-line rewrite costs an evening.

### Step 4 — Strengthen the user's draft (EDIT, don't rewrite)

**The output is the user's own document, improved — not a new document written by you.**
The user already invested thought into their draft; your job is to fill the gaps the
interview surfaced, not to replace their text with yours.

Rules:
- If the draft is a file in the repo → edit THAT file (bump version in its title:
  «v2 — підсилено /tz-draft, {date}»). If it was pasted text → write it to
  `{TZ_DIR}/TZ_{slug}.md` preserving their structure and wording.
- **Preserve the user's structure, headings, and phrasing wherever they are sound.**
  Insert, don't overwrite. Rewrite a passage only when the interview contradicted it —
  and then note it in the changelog.
- At the top, insert a short changelog block:

  ```markdown
  > **Що підсилено відносно чернетки ({date}):**
  > - додано: {розділ/правило} — з відповіді на питання N
  > - додано: {…} — ✅ авто-прийнято (ФІНІШ)
  > - змінено: {було → стало} — бо {відповідь користувача}
  ```

- **Coverage checklist** — after your edits the document must answer all of these; add a
  missing section only if the draft truly lacks it (match the draft's heading style):
  1. Мета і JTBD (+ метрика успіху) — з підтвердженого Step 1
  2. Користувачі та ролі
  3. Основний сценарій (очима користувача)
  4. Бізнес-правила — нумеровані; кожне: підтверджено / ✅ авто-прийнято (ФІНІШ)
  5. Крайні випадки (бізнес)
  6. Поза scope v1 (явні відмови + YAGNI-зрізання)
  7. Порядок реалізації — 2-4 фази, кожна закінчується чимось ПРАЦЮЮЧИМ; фаза 1 =
     найтонший наскрізний зріз (walking skeleton)
  8. Acceptance Criteria — AC-1..N; один критерій = одне перевірне твердження без "and";
     формат, який `/tz-verify` зможе розібрати
  9. Технічні рішення за замовчуванням — все, про що ти НЕ питав: рішення + 1 речення чому
  10. Відкриті ризики — pre-mortem результат + ⚠️ ПРИПУЩЕННЯ

Item 8 is the contract with `/tz-verify`. Item 9 is where your technical autonomy becomes
visible and vetoable instead of silent. Item 7 keeps implementation honest — phases end in
something demonstrable, not "60% of everything".

### Step 5 — Hand off

Close with exactly this shape:

```
✅ ТЗ підсилено: {path}
Що змінилось — у changelog-блоці вгорі документа.
{якщо були авто-прийняті: N правил прийнято автоматично — позначені ✅}
{якщо були припущення: ⚠️ перевір розділ «Відкриті ризики»}

Наступний крок — технічний аудит трьома незалежними моделями:
/tz-review {path}
```

Do NOT auto-run `/tz-review` — it is expensive; the user triggers it.

## Anti-patterns

- A question without your proposed answer and reasoning. (The core protocol violation.)
- Two questions in one message.
- Asking anything from the ❌ column — catch yourself, decide it, section 9.
- Asking what the draft or the codebase already answers.
- Arguing with the user's answer more than once.
- A message without the «ФІНІШ» footer — the user must always see the exit.
- Ignoring an informal stop signal because it wasn't the literal code word.
- Editing the user's TZ before the Step 3 summary is approved.
- Rewriting the user's sound text with your own phrasing — insert and augment; their
  draft is the backbone, you are the reinforcement.
- Inventing business rules that trace to no answer — everything in section 4 is either
  confirmed, ✅ авто-прийнято, or it doesn't exist.
- Dragging past the budget. `/tz-review` exists to catch what the interview missed.

## When NOT to invoke

- The TZ is already complete and confirmed → straight to `/tz-review`.
- Bugfix or trivial change → just do it, no interview.
- The input already answers your whole gap list → skip to Step 3 summary, note
  "інтерв'ю пропущено — чернетка була повна", still open with the JTBD statement.
