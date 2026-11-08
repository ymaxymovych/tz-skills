import type { SessionMessage } from 'claude-code'

// The seven sections /compact-prep and the optional PreCompact hook ask for (canon: skills/compact-prep/SKILL.md in tz-skills).
export const TEMPLATE = [
  'Збережи ДОСЛІВНО під 7 заголовками (причини зникають першими). Пиши українською.',
  '- РІШЕННЯ — що вирішили і ЧОМУ, з відкинутими варіантами («робимо X / НЕ робимо Y, бо …») і умовою, за якої рішення переглянути; хто вирішив (користувач словами чи чат сам); якщо записано у файл — один рядок зі шляхом',
  '- ЧЕРГА — задачі з пріоритетом; окремо що чекає на користувача (гроші, зовнішня людина, його акаунт); дозволи на відправку не переносяться — «надіслано» або «чекає дозволу»',
  '- ЗАРАЗ — активна задача або жива помилка + наступний крок однією дією',
  '- ШЛЯХИ І ЗНАЧЕННЯ — робоче дерево і гілка, точні файли, номери PR, chat_id, ID, прапорці, URL, константи — символ у символ',
  '- ЛІЧИЛЬНИКИ — цифри самоперевірки (тести, гейти, розміри, кількості) + що НЕ доведено',
  '- ВІДКРИТЕ — що зламалось чи лишилось; граблі з симптомом; фонові процеси, що ще біжать',
  '- ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ — скрипти, скіли, MCP, формати; зовнішні люди і що їм обіцяно',
  'Те, що працює, — один рядок. Викинь: пошук помилок туди-сюди, мертві гіпотези, вміст файлів (крім точних значень), логи. Секрети не пиши — лише назву змінної чи файлу.',
].join('\n')

export const SUPPLEMENT_TAG = '[compact-canon v2]'

// What the research (Factory 12.2025 anchored summaries, ACON, Cognition) and our own transcripts say gets lost.
export const SUPPLEMENT = [
  `${SUPPLEMENT_TAG} Додатково:`,
  '1) Якщо розмова починається з попереднього резюме — перенеси КОЖЕН його пункт у той самий розділ, якщо його не скасовано явно; доповнюй, не переписуй з нуля (повторне стиснення інакше губить старі рішення).',
  '2) Слова користувача, що задають рішення, заборону чи пріоритет, — дослівно в лапках, з датою.',
  '3) Розрізняй «зроблено й перевірено» / «зроблено, не перевірено» / «лише спробувано» — не перетворюй спробу на факт.',
  '4) Конкретні правила разом із причиною («тести ганяти лише локально, бо CI платний»), а не лише загальне «тести — локально». Якщо пункт черги змінився — лиши ОДНУ актуальну версію з позначкою «оновлено», без старої поруч.',
  '5) Після резюме в розмову автоматично додасться машинний ЧЕКПОІНТ (шлях до транскрипту, файли сесії, git, останні слова користувача) — не витрачай на це місце.',
].join('\n')

export const CHECKPOINT_TAG = 'ЧЕКПОІНТ ПІСЛЯ СТИСНЕННЯ'

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const OWNER_MSGS = 4
const OWNER_CHARS = 600
const MAX_FILES = 25

// Decides what a compaction is told: our sections when nothing like them came, the supplement once.
export const withCanon = (instructions: string | undefined, _trigger: string): string => {
  let text = (instructions ?? '').trim()
  // Any compaction without the sections gets them here (with the optional PreCompact hook they may come twice — harmless).
  if (!/РІШЕННЯ/.test(text)) text = text ? `${TEMPLATE}\n${text}` : TEMPLATE
  if (!text.includes(SUPPLEMENT_TAG)) text = text ? `${text}\n${SUPPLEMENT}` : SUPPLEMENT
  return text
}

// Messages in the user's role that the person never typed: app and harness events, hook feedback, tool notices.
// A tag-led message (<task-notification>, <ci-monitor-event>, <cross-session-message>, <side-sessions-event>, <command-…>)
// is never the owner's words; caught live 07.11 in the infra chat, where four such events filled the checkpoint.
const NOT_OWNER = [
  /^</,
  /^Caveat:/,
  /^Stop hook feedback/,
  /^\[SYSTEM NOTIFICATION/,
  /^Tool loaded\.?$/,
  /^Another Claude session sent a message/,
  /^This session is being continued/,
]

const ownerText = (m: SessionMessage): string => {
  if (m.role !== 'user' || (m.toolResults?.length ?? 0) > 0) return ''
  const t = m.text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim()
  if (!t || t.startsWith(CHECKPOINT_TAG) || NOT_OWNER.some(re => re.test(t))) return ''
  return t
}

// Built by code from the messages being compacted — the summary is prose a model wrote, this is not.
export type Where = { transcript: string; cwd: string; git: string; missing?: readonly string[] }

export const SECTIONS = ['РІШЕННЯ', 'ЧЕРГА', 'ЗАРАЗ', 'ШЛЯХИ І ЗНАЧЕННЯ', 'ЛІЧИЛЬНИКИ', 'ВІДКРИТЕ', 'ІНСТРУМЕНТИ'] as const

// Which of the seven sections the summary the engine wrote left out (the summary is the first message after compaction).
export const missingSections = (messages: readonly SessionMessage[]): string[] => {
  const summary = messages.find(m => m.role === 'user' && /Summary:|continued from a previous conversation/.test(m.text))
  if (!summary) return []
  const upper = summary.text.toUpperCase()
  return SECTIONS.filter(h => !upper.includes(h))
}

const OWNER_HEAD = 'Останні повідомлення користувача ДОСЛІВНО (від старшого до свіжого):'

export const buildCheckpoint = (messages: readonly SessionMessage[], where: Where): string => {
  const owner: string[] = []
  const files = new Map<string, number>()
  let order = 0
  for (const m of messages) {
    if (m.role === 'user' && m.text.startsWith(CHECKPOINT_TAG)) {
      // Carry the earlier checkpoint's owner words forward: a stretch of nothing but app events must not erase them.
      const said = (m.text.split(`${OWNER_HEAD}\n`)[1] ?? '').split('\n\nФайли, які')[0]?.split('\ngit у ')[0] ?? ''
      for (const entry of said.split(/\n(?=» )/)) {
        if (entry.startsWith('» ')) owner.push(entry.slice(2).replace(/\n {2}/g, '\n').replace(/ …\[обрізано, повністю в транскрипті\]$/, ''))
      }
      // Carry the earlier checkpoint's file trail forward, oldest first.
      const block = m.text.split('\nФайли, які ця сесія редагувала')[1] ?? ''
      for (const line of block.split('\n')) if (line.startsWith('- ')) files.set(line.slice(2), (order += 1) - 1_000_000)
      continue
    }
    const t = ownerText(m)
    if (t) owner.push(t)
    for (const u of m.toolUses) {
      if (!EDIT_TOOLS.has(u.tool)) continue
      const p = u.input['file_path'] ?? u.input['notebook_path']
      if (typeof p === 'string') files.set(p, (order += 1))
    }
  }
  const recent = [...files.entries()].sort((a, b) => b[1] - a[1]).map(([p]) => p)

  const parts = [
    `${CHECKPOINT_TAG} (зібрано кодом моду context-band з повідомлень до стиснення, не моделлю — йому можна вірити).`,
    `Транскрипт ДО стиснення (усі повідомлення): ${where.transcript}`,
    'Бракує деталі (причина рішення, точне значення, слова користувача) → спершу грепни цей файл, потім файл рішень проєкту і CLAUDE.md; НЕ перепитуй користувача і НЕ перевирішуй.',
  ]
  if (where.missing?.length) {
    parts.push(`⚠️ У резюме бракує розділів: ${where.missing.join(', ')} — перш ніж діяти, відтвори їх із транскрипту вище (grep), не з памʼяті.`)
  }
  const last = owner.slice(-OWNER_MSGS)
  if (!last.length) {
    parts.push('Нових повідомлень користувача в цьому відрізку не було (лише службові події) — його слова шукай у резюме і транскрипті.')
  } else {
    parts.push(OWNER_HEAD)
    for (const t of last) {
      const cut = t.length > OWNER_CHARS ? `${t.slice(0, OWNER_CHARS)} …[обрізано, повністю в транскрипті]` : t
      parts.push(`» ${cut.replace(/\n/g, '\n  ')}`)
    }
  }
  if (recent.length) {
    parts.push(`\nФайли, які ця сесія редагувала (${recent.length}, свіжі першими):`)
    parts.push(...recent.slice(0, MAX_FILES).map(p => `- ${p}`))
  }
  if (where.git) parts.push(`\ngit у ${where.cwd}:\n${where.git}`)
  return parts.join('\n')
}
