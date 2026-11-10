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
  '6) Сім заголовків (РІШЕННЯ, ЧЕРГА, ЗАРАЗ, ШЛЯХИ І ЗНАЧЕННЯ, ЛІЧИЛЬНИКИ, ВІДКРИТЕ, ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ) — обовʼязкові окремі рядки резюме, і вони йдуть ПЕРШИМИ. Стандартні розділи (Primary Request…, All user messages…) — після них, а не замість них.',
].join('\n')


export const CHECKPOINT_TAG = 'ЧЕКПОІНТ ПІСЛЯ СТИСНЕННЯ'

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
// The owner writes most corrections while a turn runs and several per stretch (audit 10.11: 55 of 60 missed
// messages were such), so four short slots were too few; a long dictation keeps its head and its tail.
const OWNER_MSGS = 6
const OWNER_HEAD_CHARS = 600
const OWNER_TAIL_CHARS = 250
const CUT = '…[обрізано, повністю в транскрипті]'
const MAX_FILES = 25
const TEMP_PATH = /[\\/](te?mp)[\\/]|scratchpad/i

export const SECTIONS = ['РІШЕННЯ', 'ЧЕРГА', 'ЗАРАЗ', 'ШЛЯХИ І ЗНАЧЕННЯ', 'ЛІЧИЛЬНИКИ', 'ВІДКРИТЕ', 'ІНСТРУМЕНТИ'] as const

// Which of the seven section names a text does not mention at all (instructions handed to a compaction).
export const lacking = (text: string): string[] => {
  const upper = text.toUpperCase()
  return SECTIONS.filter(h => !upper.includes(h))
}

// Decides what a compaction is told: our sections unless all seven came, the supplement once. Every trigger:
// the mod must not depend on a PreCompact hook being installed in the cell it runs in.
export const withCanon = (instructions: string | undefined): string => {
  let text = (instructions ?? '').trim()
  if (lacking(text).length) text = text ? `${TEMPLATE}\n${text}` : TEMPLATE
  if (!text.includes(SUPPLEMENT_TAG)) text = `${text}\n${SUPPLEMENT}`
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
  /^The context window filled up while you were working/,
  /^Base directory for this skill:/,
]

// What the owner types while a turn runs reaches the model inside the next tool-result message, in the engine's
// framing — not as a message of its own, and not in the rows a session.compact hook is handed.
const MID_TURN = /The user sent a new message while you were working:\n([\s\S]*?)\n\nThis is how Claude Code surfaces/g
const midTurn = (text: string): string[] => [...text.matchAll(MID_TURN)].map(x => (x[1] ?? '').trim()).filter(Boolean)

const ownerTexts = (m: SessionMessage): string[] => {
  if (m.role !== 'user') return []
  const mid = midTurn(m.text)
  if (mid.length || (m.toolResults?.length ?? 0) > 0) return mid
  const t = m.text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim()
  if (!t || t.startsWith(CHECKPOINT_TAG) || NOT_OWNER.some(re => re.test(t))) return []
  return [t]
}

type ApiBlock = { type?: string; text?: unknown; tool_use_id?: unknown }
export type MidTurn = ReadonlyMap<string, readonly string[]>

// The mid-turn messages of the conversation's API form ($.session.messages({ as: 'api' })), keyed by the tool
// call whose result they rode in with ('' before any) — the rows carry that id, so each lands in its place.
export const midTurnWords = (api: readonly { role: string; content: unknown }[]): Map<string, string[]> => {
  const found = new Map<string, string[]>()
  let lastId = ''
  for (const m of api) {
    if (m.role !== 'user' || !Array.isArray(m.content)) continue
    const blocks = m.content as ApiBlock[]
    for (const b of blocks) if (b.type === 'tool_result' && typeof b.tool_use_id === 'string') lastId = b.tool_use_id
    for (const b of blocks) {
      if (b.type !== 'text' || typeof b.text !== 'string') continue
      for (const said of midTurn(b.text)) found.set(lastId, [...(found.get(lastId) ?? []), said])
    }
  }
  return found
}

// Built by code from the messages being compacted — the summary is prose a model wrote, this is not.
export type Where = { transcript: string; cwd: string; git: string; missing?: readonly string[] }

// Which of the seven sections the summary the engine wrote has no heading for (the summary is the first message
// after compaction). A heading is a short line naming one section — «1. Primary Request and Intent (РІШЕННЯ)»
// counts, a sentence listing all seven does not (10.11: such a summary passed for a full one).
export const missingSections = (messages: readonly SessionMessage[]): string[] => {
  const summary = messages.find(m => m.role === 'user' && /Summary:|continued from a previous conversation/.test(m.text))
  if (!summary) return []
  const lines = summary.text.toUpperCase().split('\n').filter(l => l.length <= 90)
  return SECTIONS.filter(h => !lines.some(l => l.includes(h) && SECTIONS.every(o => o === h || !l.includes(o))))
}

const OWNER_HEAD = 'Останні повідомлення користувача (від старшого до свіжого; довгі — початок і кінець):'
// Checkpoints written before 10.11.2026 carry this heading; their words must still be read.
const OWNER_HEADS = [
  OWNER_HEAD,
  'Останні повідомлення користувача ДОСЛІВНО (від старшого до свіжого):',
  'Останні повідомлення Ярослава (від старшого до свіжого; довгі — початок і кінець):',
  'Останні повідомлення Ярослава ДОСЛІВНО (від старшого до свіжого):',
]
const FILES_HEAD = '\nФайли, які ця сесія редагувала'

const shorten = (t: string): string =>
  t.includes(CUT) || t.length <= OWNER_HEAD_CHARS + OWNER_TAIL_CHARS
    ? t
    : `${t.slice(0, OWNER_HEAD_CHARS)} ${CUT} ${t.slice(-OWNER_TAIL_CHARS)}`

export const buildCheckpoint = (messages: readonly SessionMessage[], where: Where, mid?: MidTurn): string => {
  const owner: string[] = []
  const files = new Map<string, number>()
  let order = 0
  let hidden = 0
  owner.push(...(mid?.get('') ?? []))
  for (const m of messages) {
    if (m.role === 'user' && m.text.startsWith(CHECKPOINT_TAG)) {
      // Carry the earlier checkpoint's owner words forward: a stretch of nothing but app events must not erase them.
      const head = OWNER_HEADS.find(h => m.text.includes(`${h}\n`))
      const said = head ? ((m.text.split(`${head}\n`)[1] ?? '').split('\n\nФайли, які')[0]?.split('\ngit у ')[0] ?? '') : ''
      for (const entry of said.split(/\n(?=» )/)) {
        const t = entry.startsWith('» ') ? entry.slice(2).replace(/\n {2}/g, '\n') : ''
        // An older mod version let app events in; they must not ride forward for ever.
        if (t && !NOT_OWNER.some(re => re.test(t))) owner.push(t)
      }
      // Carry the earlier checkpoint's file trail forward: it lists the freshest first, so ranks go down the list.
      const block = m.text.split(FILES_HEAD)[1] ?? ''
      let rank = -1_000_000
      for (const line of block.split('\n')) {
        if (line.startsWith('- ')) files.set(line.slice(2), (rank -= 1))
        else hidden += Number(/^… і ще (\d+)/.exec(line)?.[1] ?? 0)
      }
      continue
    }
    owner.push(...ownerTexts(m))
    for (const r of m.toolResults ?? []) owner.push(...(mid?.get(r.tool_use_id) ?? []))
    for (const u of m.toolUses) {
      // A refused or failed edit changed nothing.
      if (!EDIT_TOOLS.has(u.tool) || u.isError) continue
      const p = u.input['file_path'] ?? u.input['notebook_path']
      if (typeof p === 'string') files.set(p, (order += 1))
    }
  }
  const fresh = [...files.entries()].sort((a, b) => b[1] - a[1]).map(([p]) => p)
  // Scratch files were 60 % of the trail and pushed project files past the limit (audit 10.11).
  const recent = [...fresh.filter(p => !TEMP_PATH.test(p)), ...fresh.filter(p => TEMP_PATH.test(p))]
  // The same message can come twice: as a row and as a carried quote of it.
  const spoken = owner.filter((t, i) => !owner.slice(i + 1).some(later => later.slice(0, 500) === t.slice(0, 500)))

  const parts = [
    `${CHECKPOINT_TAG} (зібрано кодом моду context-band з повідомлень до стиснення, не моделлю; це вказівник, а не повна памʼять).`,
    `Транскрипт ДО стиснення (усі повідомлення): ${where.transcript}`,
    'Бракує деталі (причина рішення, точне значення, слова користувача) → спершу грепни цей файл, потім файл рішень проєкту і CLAUDE.md; НЕ перепитуй користувача і НЕ перевирішуй.',
  ]
  if (where.missing?.length) {
    parts.push(`⚠️ У резюме бракує розділів: ${where.missing.join(', ')} — перш ніж діяти, відтвори їх із транскрипту вище (grep), не з памʼяті.`)
  }
  const last = spoken.slice(-OWNER_MSGS)
  if (!last.length) {
    parts.push('Нових повідомлень користувача в цьому відрізку не було (лише службові події) — його слова шукай у резюме і транскрипті.')
  } else {
    parts.push(OWNER_HEAD)
    for (const t of last) parts.push(`» ${shorten(t).replace(/\n/g, '\n  ')}`)
  }
  if (recent.length) {
    const more = recent.length - Math.min(recent.length, MAX_FILES) + hidden
    parts.push(`${FILES_HEAD} інструментами Edit/Write (${recent.length + hidden}; робочі першими, тимчасові в кінці, у кожній групі свіжі першими):`)
    parts.push(...recent.slice(0, MAX_FILES).map(p => `- ${p}`))
    if (more) parts.push(`… і ще ${more} — у транскрипті (grep "file_path")`)
  }
  if (where.git) parts.push(`\ngit у ${where.cwd}:\n${where.git}`)
  return parts.join('\n')
}
