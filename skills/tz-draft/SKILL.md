---
name: tz-draft
description: Turn the user's free-flow spoken monologue (10-15 min of dictated thoughts) or rough TZ draft into a complete, structured TZ — WITHOUT interrogating them. The skill structures what was said first, then sends ONE message containing the Job-to-be-Done readback plus ALL its questions as a single batch (typically 0-3, hard cap 7) — each question arriving WITH the recommended answer and why it's right. The user answers everything in one reply («1а, 2 так, 3 своя відповідь…»); skipped questions automatically take the recommendation. «ФІНІШ» at any moment accepts all recommended answers and produces the strengthened TZ immediately. Batching is deliberate token economy: every extra Q-A round forces a re-read of the whole chat history. Technical choices are never asked; the TZ always embeds the instruction for the implementing agent to work in an isolated git worktree. Invoke when the user dictates an idea, brings a draft TZ, or says "допоможи зробити ТЗ" / "прожени ТЗ". Works in whatever language the user writes in (Ukrainian, English, any other).
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# TZ Draft — structure the flow, ask only the leftovers

## Language

Work in the language the user writes or dictates in. Detect it from the dictation, the
draft, or the first message; if it is mixed or unclear, do not ask — use English.
Everything user-facing follows that language: the TZ document, the questions and their
recommended answers, the review journal, progress lines, the final report, and any commit
messages you write on the user's behalf. Keep verbatim: command names (`/tz-go`), file
names, code, config keys, and the code words — «ФІНІШ», "FINISH" and "DONE" are the SAME
code word in any language. The Ukrainian text blocks inside this skill are templates of
MEANING, not strings to paste: render them faithfully in the user's language. Prompts sent
to critic models may stay in English (models handle it best), but every finding you quote
back to the user is translated. Never switch language mid-run because a source file or a
kit template happens to be in another language.

Upstream companion to `/tz-review` and `/tz-verify`. The pipeline is:

```
надиктовка / чернетка → /tz-draft (структурує → JTBD → 0-3 залишкові питання → ПІДСИЛЕНЕ ТЗ)
                      → /tz-review (3 критики аудитують ТЗ)
                      → реалізація (в ізольованому worktree — інструкція вшита у ТЗ)
                      → /tz-verify (3 критики перевіряють виконання)
```

**Attribution.** The core concept — flow-dictation first, structure second, questions last
and only for genuine unknowns; answer-first questioning; the «ФІНІШ» code-word exit;
strengthening an EXISTING draft rather than writing from scratch — is by this pack's
author. Only low-level question mechanics (options offered, YAGNI,
validate-before-writing) are adapted from the Superpowers `brainstorming` skill
(obra/superpowers, MIT). Superpowers' one-question-at-a-time rule is deliberately
REPLACED here by single-batch questioning — see Step 1 for why that is safe in this
design and cheaper in tokens.

## The philosophy: dictation beats interrogation

The user's best input is a **10-15 minute free-flow monologue** — spoken or typed without
structure. A person in flow gives deeper, broader context than a person answering
questions that arrive in jerks. Therefore this skill NEVER leads with questions. It leads
with LISTENING and STRUCTURING, and asks only what remains genuinely unknowable after that.

**The confidence gate (the central rule of questioning).** A question may be asked ONLY if
BOTH conditions hold:
1. Guessing wrong would be **expensive for the business** (money, access rights, mass
   communication, lost clients — not cosmetics), AND
2. You genuinely **cannot infer the answer with high confidence** from the dictation, the
   draft, or the codebase.

Everything that fails this gate you decide YOURSELF and record in the TZ (business-shaped
guesses → «⚠️ ПРИПУЩЕННЯ»; technical choices → «Технічні рішення за замовчуванням»).
**Typical interview: 0-3 questions. Hard cap: 7.** Zero questions is a perfectly good
outcome — it means the dictation was complete.

## The three hard rules

**Rule 1 — business only.** Questions may be ONLY about business logic. Never technology.

| ✅ можна питати (бізнес) | ❌ ніколи не питати (технічне — вирішуй сам) |
|---|---|
| Хто користувач і яку роботу це для нього робить? | ОС, хостинг, сервер, хмара |
| Що таке «успіх», бажано в цифрах? | База даних, схема, ORM |
| Що відбувається, коли X платить / скасовує / падає? | Мова, фреймворк, бібліотека |
| Кому що дозволено (ролі, бізнес-термінами)? | Архітектура, форма API |
| Що явно ПОЗА scope v1? | Механізм auth, токени |
| Які наявні потоки не можна зламати? | Деплой, CI, стратегія тестування |
| Бізнес-крайні випадки («клієнт має два контракти?») | Ліміти, кеш, черги |
| Пріоритети: яку половину ріжемо, якщо треба? | Будь-яке «який інструмент» |

**Rule 2 — answer-first, ALWAYS.** Every question — no exceptions — arrives WITH:
(а) варіанти відповідей, (б) **твоя рекомендація: одна позначена відповідь**, і
(в) **пояснення, ЧОМУ вона найправильніша в цій ситуації** (1-3 речення, з опорою на
надиктоване / чернетку / кодову базу). Варіанти існують лише щоб незгода коштувала одну
літеру, а не есе — вони НЕ перекладають вибір на людину. Людина, яка не розуміє
варіантів, просто каже «так» на рекомендацію. Голе питання без рекомендації з
поясненням — порушення протоколу.

**Rule 3 — the confidence gate** (описаний вище): не питай того, на що можеш відповісти
сам з високою впевненістю. Питання, яке не пройшло гейт — вирішуй сам і записуй у ТЗ.

## Protocol

### Step 0 — Listen and structure (silently)

Input, in order of preference:
1. **Надиктований монолог** — user talks/types freely for 10-15 min. This is the primary
   mode: «Я тобі зараз виговорюсь, а ти впорядкуй мої думки і перетвори їх на ТЗ».
2. **Чернетка ТЗ** — file path or pasted text.
3. **Сира ідея** — a few sentences.

Do NOT interrupt a monologue with questions. When it's done:
- Read the codebase around the feature area (grep models, routes, existing flows) —
  a question the code already answers is spam.
- Locate `{TZ_DIR}` per the `/tz-review` convention (`.ai-context/` → else `docs/specs/`
  or `docs/tz/` → else create `docs/tz/`).
- Structure everything said into the coverage checklist (Step 4) IN YOUR HEAD, and build
  the gap list. Run every gap through the confidence gate — most gaps die there and
  become your own recorded decisions. What survives (typically 0-3 items) is the
  interview, ordered by cost-of-guessing-wrong.

### Step 1 — ONE opening message: JTBD + попередження + ВЕСЬ батч питань

**Всі питання йдуть ОДНИМ повідомленням, не по одному.** Причина — економіка токенів:
кожен додатковий раунд «питання → відповідь» змушує модель перечитувати всю історію
чату заново (кеш пом'якшує це, але не скасовує — і між повільними людськими
відповідями він встигає протухнути). Батч з N питань замість N раундів économить
N-1 повних перечитувань історії.

**Чому батч тут безпечний (а в класичних інтерв'ю — ні).** У класичному інтерв'ю з
голими питаннями батч мовчки губить відповіді: людина відповіла на 3 з 7, і ніхто не
помітив. Тут КОЖНЕ питання несе рекомендовану відповідь — пропущене питання
автоматично отримує її з позначкою «✅ авто-прийнято» в ТЗ. Батч не втрачає нічого.

The opening message contains, in this order:

**1. JTBD readback (+ не-цілі + самокваліфікація):**

```
📋 Як я зрозумів задачу (JTBD):
Коли [ситуація], [хто] хоче [що зробити], щоб [бізнес-результат].
Успіх виглядає так: [метрика/спостережуваний наслідок].
Точно НЕ робимо: [2-5 явних не-цілей — те, що спокусливо додати, але в v1 свідомо ні].

Самокваліфікація: [«впевненість висока — вирішую решту сам, питань {N}» /
«впевненість достатня, крім {зона} — тому питання {N} саме про неї»].

Якщо прочитання неправильне — поправ мене ПЕРШИМ рядком відповіді, це найдешевше
місце зловити хибний напрям.
```

Не-цілі — обов'язкова частина прочитання, нарівні з JTBD: саме вони захищають від
розповзання scope, і користувач мусить побачити їх ДО того, як ТЗ написане.
Самокваліфікація робить confidence gate видимим: рядок пояснює, ЧОМУ питань саме
стільки — кількість завжди похідна від названих туманних зон, ніколи не квота.

**2. Обов'язкове попередження про батч** (перед питаннями, дослівно за змістом):

```
⚠️ Нижче — ВСІ мої питання одним блоком (їх {N}). Це свідомо: кожен окремий раунд
«питання-відповідь» змушує мене перечитувати всю історію чату і палить токени.
Відповідай, будь ласка, ОДНИМ повідомленням, наприклад: «1а, 2 так, 3 своя
відповідь: …, 4 так». Пропустиш якесь питання — не страшно: я візьму свою
рекомендовану відповідь. Напишеш «ФІНІШ» — приймаю свої рекомендації на ВСІ
питання одразу і видаю ТЗ.
```

**3. Батч питань** (кожне answer-first, той самий формат):

```
Питання {N}: {питання}
Чому питаю: {що зламається в бізнесі, якщо вгадати неправильно, і чому я не можу
вивести відповідь сам}
Варіанти:
  a) {варіант}
  b) {варіант}
  c) {варіант}
✅ Рекомендую: {літера}) — {чому саме вона найправильніша: 1-3 речення}
```

**4. ФІНІШ footer** (як завжди).

Rules:
- Якщо після гейта питань ≥3 — останнім у батчі йде **pre-mortem**: «Уяви: місяць
  після запуску, фіча провалилась. Найімовірніша причина?» — теж зі своєю
  рекомендованою відповіддю. Результат → «Відкриті ризики».
- Якщо після гейта питань НУЛЬ — попередження про батч не потрібне: «Питань не маю,
  надиктоване повне» + JTBD + одразу до Step 3.
- Hard cap 7 питань у батчі. Другого батчу НЕ буває — що не влізло в перший, вирішуй
  сам за confidence gate.

### Step 2 — Process the single reply

- Пронумеровані відповіді користувача → lock THEIRS (можеш заперечити РАЗ, якщо
  відповідь створює конкретний бізнес-ризик, потім прийняти).
- Пропущені питання → lock YOUR recommendation, позначка «✅ авто-прийнято» в ТЗ.
- Відповіді суперечать одна одній або перевертають JTBD → ОДНЕ уточнювальне
  повідомлення (тільки про суперечність), потім видача. Це єдиний легальний
  додатковий раунд.
- Якщо відповіді розкрили, що це два проєкти → сказати, запропонувати який з них v1
  (YAGNI) — у тому самому повідомленні, що й видача.

### The code word — «ФІНІШ» / "FINISH" / "DONE" (same word, any language)

Printed at the end of EVERY message of this skill:

> Напишіть **«ФІНІШ»** — я прийму власні рекомендації на все, що лишилось, одразу видам
> підсилене ТЗ і команду для наступного кроку (`/tz-review`).

Semantics: stop asking instantly; auto-resolve remaining gaps with YOUR recommendations;
produce the TZ (Step 4) immediately. Auto-accepted rules are marked
**«✅ авто-прийнято (ФІНІШ)»** in the document; what even you couldn't answer →
**«⚠️ ПРИПУЩЕННЯ»** in «Відкриті ризики». Informal stops («досить», «далі сам»,
«переходь до рев'ю») count as ФІНІШ too — the footer exists so the user never has to
wonder HOW to stop you, not to make the literal word mandatory.

### Step 3 — Summary + TZ in ONE message (no extra confirmation round)

Після обробки відповідей — НЕ окремий підтверджувальний раунд. Одним повідомленням:
**коротке резюме (5-8 рядків)** — мета, користувач, ядро сценарію, non-goals, 2-3
найризиковіші бізнес-правила з позначками звідки вони (відповідь / ✅ авто-прийнято) —
і ОДРАЗУ під ним підсилене ТЗ (Step 4). Резюме — це зміст-навігація для людини, а не
гейт: усі спірні місця вже або підтверджені відповідями, або чесно позначені
✅/⚠️ у документі, тож помилка виправляється правкою, а не ще одним раундом.

Виняток (єдиний): відповіді суперечливі чи перевернули JTBD → одне уточнення
(див. Step 2), потім видача.

### Step 4 — Produce the strengthened TZ (EDIT, don't replace)

**The output is the user's material, structured and reinforced — never your document
instead of theirs.**

- Чернетка-файл → edit THAT file (bump version у заголовку: «v2 — підсилено /tz-draft,
  {date}»). Надиктовка/вставлений текст → write `{TZ_DIR}/TZ_{slug}.md`, зберігаючи
  формулювання і акценти користувача скрізь, де вони здорові.
- **Insert, don't overwrite.** Переписати пасаж можна лише якщо інтерв'ю його спростувало
  — і тоді це йде в changelog.
- At the top, a changelog block:

  ```markdown
  > **Що підсилено відносно надиктованого/чернетки ({date}):**
  > - додано: {правило} — з відповіді на питання N
  > - додано: {…} — ✅ авто-прийнято (ФІНІШ)
  > - змінено: {було → стало} — бо {відповідь користувача}
  ```

- **Coverage checklist** — після твоїх правок документ мусить відповідати на все нижче
  (додавай розділ, лише якщо його справді бракує; стиль заголовків — як у користувача):
  1. Мета і JTBD (+ метрика успіху + блок «Не-цілі: чого точно НЕ робимо» одразу
     поруч — 2-5 головних відмов зі Step 1; детальний «Поза scope v1» нижче їх
     доповнює, не замінює) — з підтвердженого Step 1
  2. Користувачі та ролі
  3. Основний сценарій (очима користувача)
  4. Бізнес-правила — нумеровані; кожне: підтверджено / ✅ авто-прийнято (ФІНІШ)
  5. Крайні випадки (бізнес)
  6. Поза scope v1 (явні відмови + YAGNI-зрізання)
  7. Порядок реалізації — 2-4 фази, кожна закінчується чимось ПРАЦЮЮЧИМ; фаза 1 =
     найтонший наскрізний зріз
  8. Acceptance Criteria — AC-1..N; один критерій = одне перевірне твердження без «and»;
     формат, який `/tz-verify` зможе розібрати
  9. Технічні рішення за замовчуванням — усе, про що ти НЕ питав: рішення + 1 речення
     чому. **Перший рядок цього розділу — ЗАВЖДИ, без винятків:**

     > Реалізацію вести в ізольованому git worktree (гілка `feat/{slug}`): агент сам
     > створює worktree ДО першої правки, комітить часто, здає через push + Pull Request
     > після зелених перевірок і прибирає worktree після мерджу. Незамерджену роботу
     > можна знищити лише за явним словом «discard» від людини.

     Це інструкція агенту-виконавцю, вшита в ТЗ. Користувач нею не керує і не мусить
     розуміти git — виконавець, читаючи ТЗ, ізолюється сам.
  10. Відкриті ризики — pre-mortem результат + ⚠️ ПРИПУЩЕННЯ

### Step 5 — Hand off

```
✅ ТЗ готове: {path}
Що змінилось відносно надиктованого — у changelog-блоці вгорі документа.
{якщо були авто-прийняті: N правил прийнято автоматично — позначені ✅}
{якщо були припущення: ⚠️ перевір розділ «Відкриті ризики»}

Наступний крок — аудит трьома незалежними моделями:
/tz-review {path}
```

Do NOT auto-run `/tz-review` — it is expensive; the user triggers it.

## Anti-patterns

- Leading with questions instead of listening — the monologue comes first, always.
- JTBD readback без «Точно НЕ робимо» або без рядка самокваліфікації — користувач
  мусить бачити і межу задачі, і те, чому питань саме стільки.
- **Asking a question you could answer yourself with high confidence** — the #1 way this
  skill becomes annoying. The confidence gate is not optional.
- A question without a recommended answer AND the reasoning why it's the most correct one.
- **Розсипати питання по окремих повідомленнях** — кожен зайвий раунд = повторне
  перечитування всієї історії чату. Всі питання — одним батчем в одному повідомленні.
- Батч без попередження «відповідай одним повідомленням; пропущене → візьму свою
  рекомендацію» — людина мусить знати правила гри ДО того, як на неї впаде блок питань.
- Другий батч питань після першого — що не влізло, вирішуй сам (confidence gate).
- Anything from the ❌ column — catch yourself, decide it, розділ 9.
- Interrupting the dictation.
- A message without the «ФІНІШ» footer.
- Ignoring an informal stop because it wasn't the literal code word.
- Зайвий підтверджувальний раунд перед видачею ТЗ, коли відповіді несуперечливі —
  резюме і ТЗ ідуть одним повідомленням.
- Rewriting the user's sound text with your own phrasing — insert and augment; their
  words are the backbone, you are the reinforcement.
- Inventing business rules that trace to nothing — everything in розділ 4 is confirmed,
  ✅ авто-прийнято, or doesn't exist.
- Omitting the worktree instruction from розділ 9 — it is mandatory in every TZ.

## When NOT to invoke

- ТЗ вже повне і підтверджене → одразу `/tz-review`.
- Багфікс чи тривіальна зміна → просто зроби, без інтерв'ю.
- Вхід уже відповідає на весь чек-лист → нуль питань, Step 3 summary одразу, з приміткою
  «питань не було — вхід був повний», але JTBD-відкриття (Step 1) все одно обов'язкове.
