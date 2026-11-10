import { expect, test } from 'claude-code/testing'

import { buildCheckpoint, midTurnWords, missingSections, withCanon } from '../hooks/canon'

declare const setTimeout: (fn: (v?: unknown) => void, ms: number) => unknown

const BLOCK =
  'РІШЕННЯ — робимо X, бо Y; НЕ робимо Z.\nЧЕРГА — a, b.\nЗАРАЗ — перевірка моду.\n' +
  'ШЛЯХИ І ЗНАЧЕННЯ — ~/.claude/mods/context-band.\nЛІЧИЛЬНИКИ — 1/1.\nВІДКРИТЕ — нічого.\n' +
  'ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ — compact_now.\n' + 'x'.repeat(300)

test('compact_now refuses a block without the sections, queues a full one, compacts after the turn', async ($, on) => {
  const compacted: string[] = []
  on('tool.register', () => ({ value: { tool: 'mcp__context-band__compact_now' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000 }, rateLimits: [], cost: { usd: 0 } } }) as never)
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('clock.after', () => ({ value: undefined }) as never)
  on('session.compact', (_, e) => {
    compacted.push(e.instructions ?? '')
    return { messages: [{ role: 'user', text: 'резюме', toolUses: [] }] } as never
  })
  on('turn.complete', () => ({ text: '' }))
  const toasts: string[] = []
  on('ui.toast', (_, e) => { toasts.push(String((e as { text?: unknown }).text)); return { value: undefined } as never })

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const refused = await $.tool.call({ tool: 'mcp__context-band__compact_now', instructions: 'коротко' } as never)
  expect(String((refused as { result?: unknown }).result)).toContain('НЕ заплановано')

  const queued = await $.tool.call({ tool: 'mcp__context-band__compact_now', instructions: '/compact ' + BLOCK } as never)
  expect(String((queued as { result?: unknown }).result)).toContain('Заплановано')

  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as never)
  await new Promise(r => setTimeout(r, 2500))
  expect(compacted.length).toBe(1)
  expect(toasts.join(' ')).toContain('стиснуто')
  expect(compacted[0]?.startsWith('РІШЕННЯ')).toBe(true)
})

test('withCanon adds the sections where none came and the supplement once', async () => {
  const bare = withCanon('')
  expect(bare).toContain('ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ')
  expect(bare).toContain('[compact-canon v2]')
  // a block that names only some of the seven still gets the template (07–10.11: two words passed for seven sections)
  const partial = withCanon('РІШЕННЯ — моє')
  expect(partial).toContain('ЧЕРГА')
  expect(partial).toContain('РІШЕННЯ — моє')
  const own = withCanon(BLOCK)
  expect(own.startsWith('РІШЕННЯ — робимо X')).toBe(true)
  expect(own.includes('Збережи ДОСЛІВНО під 7 заголовками')).toBe(false)
  expect(withCanon(own)).toBe(own)
})

const setup = async ($: never, on: never, compact: (e: { instructions?: string }) => unknown) => {
  const h = on as unknown as (name: string, fn: (...a: never[]) => unknown) => void
  h('tool.register', () => ({ value: { tool: 'mcp__context-band__compact_now' } }))
  h('session.start', ((_: unknown, e: { cwd: string }) => ({ cwd: e.cwd })) as never)
  h('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000 }, rateLimits: [], cost: { usd: 0 } } }))
  h('session.model', () => ({ value: 'claude-opus-5-5' }))
  h('clock.after', () => ({ value: undefined }))
  h('session.compact', ((_: unknown, e: { instructions?: string }) => compact(e)) as never)
  h('turn.complete', () => ({ text: '' }))
  const toasts: string[] = []
  h('ui.toast', ((_: unknown, e: { text?: unknown }) => { toasts.push(String(e.text)); return { value: undefined } }) as never)
  const api = $ as unknown as {
    session: { start: (a: unknown) => Promise<unknown> }
    tool: { call: (a: unknown) => Promise<{ result?: unknown }> }
    turn: { complete: (a: unknown) => Promise<unknown> }
  }
  await api.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  return {
    toasts,
    ask: (extra: object = {}) => api.tool.call({ tool: 'mcp__context-band__compact_now', instructions: BLOCK, ...extra }),
    end: (turnId: string, isAborted = false) => api.turn.complete({ answer: 'ok', durationMs: 1, isAborted, turnId, reason: 'answer' }),
  }
}
const wait = (ms: number) => new Promise(r => setTimeout(r, ms))
const summary = { messages: [{ role: 'user', text: 'резюме', toolUses: [] }] }

test('one request, one compaction: the request dies with the compaction it got', async ($, on) => {
  // The test kit fires $.clock.after callbacks at once, so a timer overtaken by a newer request cannot be staged here.
  let calls = 0
  const s = await setup($ as never, on as never, () => { calls += 1; return summary })
  await s.ask(); await s.end('t1'); await wait(700)
  expect(calls).toBe(1)
  await s.end('t2'); await wait(700)
  expect(calls).toBe(1)
})

test('a compaction that could not run is tried again when the next turn ends, with a note that the block is older', async ($, on) => {
  const seen: string[] = []
  let busy = true
  const s = await setup($ as never, on as never, e => {
    if (busy) throw new Error('a turn is running')
    seen.push(e.instructions ?? '')
    return summary
  })
  await s.ask(); await s.end('t1')
  await wait(700)
  expect(seen.length).toBe(0)
  busy = false
  await s.end('t2'); await wait(700)
  expect(seen.length).toBe(1)
  expect(seen[0]).toContain('складено ДО останнього відрізка')
  expect(seen[0]).toContain('РІШЕННЯ — робимо X')
})

test('an interrupted turn drops the request, and a subagent cannot ask for the main conversation', async ($, on) => {
  let calls = 0
  const s = await setup($ as never, on as never, () => { calls += 1; return summary })
  await s.ask(); await s.end('t1', true); await s.end('t2'); await wait(700)
  expect(calls).toBe(0)
  expect(s.toasts.join(' ')).toContain('хід перервано')
  const refused = await s.ask({ agentId: 'bg-1' })
  expect(String(refused.result)).toContain('лише в головній розмові')
  const partial = await s.ask({ instructions: `РІШЕННЯ ЗАРАЗ ${'x'.repeat(320)}` })
  expect(String(partial.result)).toContain('бракує розділів (ЧЕРГА')
})

test('mid-turn words come from the API form and land where they were said', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const note = (said: string) =>
    `<system-reminder>\nThe user sent a new message while you were working:\n${said}\n\nThis is how Claude Code surfaces messages the user sends mid-turn.\n</system-reminder>`
  const mid = midTurnWords([
    { role: 'user', content: [{ type: 'text', text: 'Перевір лог' }] },
    { role: 'assistant', content: [{ type: 'tool_use', id: 'a' }] },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'a' }, { type: 'text', text: note('це був не мій чат,\nа чат студента') }] },
    { role: 'user', content: 'рядок, не блоки' },
  ])
  const out = buildCheckpoint(
    [
      { role: 'user', text: 'Перевір лог', toolUses: [] },
      { role: 'user', text: '', toolUses: [], toolResults: [{ tool_use_id: 'a', text: 'ok' }] },
      { role: 'user', text: 'Не треба', toolUses: [] },
    ] as never,
    where,
    mid,
  )
  expect(out).toContain('» це був не мій чат,\n  а чат студента')
  expect(out.indexOf('» Перевір лог') < out.indexOf('» це був не мій чат')).toBe(true)
  expect(out.indexOf('» це був не мій чат') < out.indexOf('» Не треба')).toBe(true)
  expect(out.includes('This is how Claude Code')).toBe(false)
})

test('the checkpoint says what it cut: long words keep head and tail, files keep their order and their count', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const long = `${'a'.repeat(900)} НЕ ВИДАЛЯТИ`
  const uses = Array.from({ length: 27 }, (_, i) => ({ tool_use_id: `${i}`, tool: 'Edit', input: { file_path: `C:/p/file-${i}.ts` } }))
  const first = buildCheckpoint(
    [
      { role: 'user', text: long, toolUses: [] },
      { role: 'assistant', text: '', toolUses: [{ tool_use_id: 's', tool: 'Write', input: { file_path: 'D:/Temp/claude/x/scratchpad/note.md' } }, ...uses] },
      { role: 'assistant', text: '', toolUses: [{ tool_use_id: 'f', tool: 'Edit', input: { file_path: 'C:/p/failed.ts' }, isError: true }] },
    ] as never,
    where,
  )
  expect(first).toContain('НЕ ВИДАЛЯТИ')
  expect(first).toContain('…[обрізано, повністю в транскрипті]')
  expect(first.includes('failed.ts')).toBe(false)
  const lines = (s: string) => s.split('\n').filter(l => l.startsWith('- '))
  expect(lines(first)[0]).toBe('- C:/p/file-26.ts')
  expect(lines(first).length).toBe(25)
  expect(first).toContain('… і ще 3 —')
  const second = buildCheckpoint([{ role: 'user', text: first, toolUses: [] }] as never, where)
  expect(lines(second)[0]).toBe('- C:/p/file-26.ts')
  expect(second).toContain('(28;')
  expect(second).toContain('… і ще 3 —')
  expect(second).toContain('НЕ ВИДАЛЯТИ')
  expect(second.split('…[обрізано, повністю в транскрипті]').length).toBe(2)
})

test('old checkpoints are still read, and app events they carried are dropped', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const old = [
    'ЧЕКПОІНТ ПІСЛЯ СТИСНЕННЯ (зібрано кодом моду context-band з повідомлень до стиснення, не моделлю — йому можна вірити).',
    'Останні повідомлення Ярослава ДОСЛІВНО (від старшого до свіжого):',
    '» <task-notification> <task-id>x</task-id>',
    '» The context window filled up while you were working, so the conversation was compacted.',
    '» Роби через шлюз',
    '',
    'Файли, які ця сесія редагувала (2, свіжі першими):',
    '- C:/p/new.ts',
    '- C:/p/old.ts',
  ].join('\n')
  const out = buildCheckpoint([{ role: 'user', text: old, toolUses: [] }, { role: 'user', text: 'Роби через шлюз', toolUses: [] }] as never, where)
  expect(out).toContain('» Роби через шлюз')
  expect(out.split('» ').length).toBe(2)
  expect(out.includes('task-notification')).toBe(false)
  expect(out.indexOf('- C:/p/new.ts') < out.indexOf('- C:/p/old.ts')).toBe(true)
})

test('the checkpoint keeps the owner words verbatim, the file trail across compactions, git and the transcript', async () => {
  const where = { transcript: 'C:/Users/y/.claude/projects/J--wt-x/abc.jsonl', cwd: 'J:/wt/x', git: ['HEAD 1a2b fix', '## main', ' M a.ts'].join('\n') }
  const first = buildCheckpoint(
    [
      { role: 'user', text: 'Робимо через мод, бо хуки захищені <system-reminder>шум</system-reminder>', toolUses: [] },
      { role: 'assistant', text: 'ok', toolUses: [{ tool_use_id: '1', tool: 'Edit', input: { file_path: 'C:/x/old.ts' } }] },
      { role: 'user', text: '', toolUses: [], toolResults: [{ tool_use_id: '1', text: 'done' }] },
    ] as never,
    where,
  )
  expect(first).toContain('» Робимо через мод, бо хуки захищені')
  expect(first.includes('шум')).toBe(false)
  expect(first).toContain('- C:/x/old.ts')
  expect(first).toContain(where.transcript)
  expect(first).toContain('## main')

  const second = buildCheckpoint(
    [
      { role: 'user', text: 'резюме', toolUses: [] },
      { role: 'user', text: first, toolUses: [] },
      { role: 'assistant', text: '', toolUses: [{ tool_use_id: '2', tool: 'Write', input: { file_path: 'C:/x/new.ts' } }] },
    ] as never,
    where,
  )
  expect(second.indexOf('- C:/x/new.ts') < second.indexOf('- C:/x/old.ts')).toBe(true)
  expect(second.split('ЧЕКПОІНТ ПІСЛЯ СТИСНЕННЯ').length).toBe(2)
})

test('missingSections names the sections the summary left out', async () => {
  const full = 'Summary:\nРІШЕННЯ x\nЧЕРГА x\nЗАРАЗ x\nШЛЯХИ І ЗНАЧЕННЯ x\nЛІЧИЛЬНИКИ x\nВІДКРИТЕ x\nІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ x'
  expect(missingSections([{ role: 'user', text: full, toolUses: [] }] as never).length).toBe(0)
  expect(missingSections([{ role: 'user', text: 'Summary:\nРІШЕННЯ x', toolUses: [] }] as never)).toContain('ЗАРАЗ')
  const listed = 'Summary:\n- 7-розділовий блок: РІШЕННЯ, ЧЕРГА, ЗАРАЗ, ШЛЯХИ І ЗНАЧЕННЯ, ЛІЧИЛЬНИКИ, ВІДКРИТЕ, ІНСТРУМЕНТИ.'
  expect(missingSections([{ role: 'user', text: listed, toolUses: [] }] as never).length).toBe(7)
  const mapped = 'Summary:\n1. Primary Request and Intent (РІШЕННЯ)\nтекст'
  expect(missingSections([{ role: 'user', text: mapped, toolUses: [] }] as never).includes('РІШЕННЯ')).toBe(false)
  const where = { transcript: 't', cwd: 'c', git: '', missing: ['ЗАРАЗ'] }
  expect(buildCheckpoint([] as never, where)).toContain('бракує розділів: ЗАРАЗ')
})

test('the checkpoint leaves out app and harness events posing as user messages', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const out = buildCheckpoint(
    [
      { role: 'user', text: 'Перевір, чи все пройшло добре', toolUses: [] },
      { role: 'user', text: '<task-notification>\n<task-id>x</task-id>\n</task-notification>', toolUses: [] },
      { role: 'user', text: '<ci-monitor-event>PR #1</ci-monitor-event>', toolUses: [] },
      { role: 'user', text: 'Stop hook feedback:\n[command hook 2]: review', toolUses: [] },
      { role: 'user', text: 'Tool loaded.', toolUses: [] },
    ] as never,
    where,
  )
  expect(out).toContain('» Перевір, чи все пройшло добре')
  expect(out.includes('task-notification')).toBe(false)
  expect(out.includes('ci-monitor-event')).toBe(false)
  expect(out.includes('Stop hook feedback')).toBe(false)
  expect(out.includes('Tool loaded')).toBe(false)
})

test('the checkpoint keeps what the owner typed while a turn was running', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const note = (said: string) =>
    `The user sent a new message while you were working:\n${said}\n\nThis is how Claude Code surfaces messages the user sends mid-turn — within the running turn. Address the message above as you continue this turn.`
  const out = buildCheckpoint(
    [
      { role: 'user', text: 'Перевір лог', toolUses: [] },
      { role: 'user', text: note('це був не мій чат,\nа чат студента'), toolUses: [], toolResults: [{ tool_use_id: '1', text: 'ok' }] },
      { role: 'user', text: `<system-reminder>\n${note('і додай інструкцію')}\n</system-reminder>`, toolUses: [] },
      { role: 'user', text: 'звичайний вивід інструмента', toolUses: [], toolResults: [{ tool_use_id: '2', text: 'ok' }] },
    ] as never,
    where,
  )
  expect(out).toContain('» це був не мій чат,\n  а чат студента')
  expect(out).toContain('» і додай інструкцію')
  expect(out.includes('This is how Claude Code')).toBe(false)
  expect(out.includes('звичайний вивід')).toBe(false)
  expect(out.split('» ').length).toBe(4)
})

test('owner words survive a stretch of nothing but app events, and their absence is said plainly', async () => {
  const where = { transcript: 't', cwd: 'c', git: '' }
  const first = buildCheckpoint([{ role: 'user', text: 'Роби через шлюз,\nне напряму', toolUses: [] }] as never, where)
  const second = buildCheckpoint(
    [
      { role: 'user', text: first, toolUses: [] },
      { role: 'user', text: '<task-notification>x</task-notification>', toolUses: [] },
    ] as never,
    where,
  )
  expect(second).toContain('» Роби через шлюз,\n  не напряму')
  expect(second.split('» ').length).toBe(2)
  expect(buildCheckpoint([{ role: 'user', text: '<ci-monitor-event>x</ci-monitor-event>', toolUses: [] }] as never, where)).toContain('Нових повідомлень користувача')
})

test('all four released checkpoint headings preserve owner words', async () => {
  const heads = [
    'Останні повідомлення користувача (від старшого до свіжого; довгі — початок і кінець):',
    'Останні повідомлення користувача ДОСЛІВНО (від старшого до свіжого):',
    'Останні повідомлення Ярослава (від старшого до свіжого; довгі — початок і кінець):',
    'Останні повідомлення Ярослава ДОСЛІВНО (від старшого до свіжого):',
  ]
  for (const head of heads) {
    const text = ['ЧЕКПОІНТ ПІСЛЯ СТИСНЕННЯ', head, '» Не видаляй файли'].join('\n')
    const out = buildCheckpoint([{ role: 'user', text, toolUses: [] }] as never, { transcript: 't', cwd: 'c', git: '' })
    expect(out).toContain('» Не видаляй файли')
    expect(out).toContain(heads[0])
  }
})
