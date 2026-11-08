import { expect, test } from 'claude-code/testing'

import { buildCheckpoint, missingSections, withCanon } from '../hooks/canon'

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
  const manual = withCanon('', 'manual')
  expect(manual).toContain('РІШЕННЯ')
  expect(manual).toContain('[compact-canon v2]')
  // auto gets the sections too: students may have no PreCompact hook
  expect(withCanon('', 'auto')).toContain('РІШЕННЯ')
  const own = withCanon('РІШЕННЯ — моє', 'plugin')
  expect(own.startsWith('РІШЕННЯ — моє')).toBe(true)
  expect(withCanon(own, 'plugin')).toBe(own)
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
