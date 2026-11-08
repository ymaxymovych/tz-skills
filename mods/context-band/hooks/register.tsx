import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Brain, Fill } from '../types'
import { buildCheckpoint, missingSections, withCanon } from './canon'

const fill = atom({ plugin: 'context-band', key: 'fill' } as const, null)
const brain = atom({ plugin: 'context-band', key: 'brain' } as const, null)
const marked = atom({ plugin: 'context-band', key: 'marked' } as const, false)
// Instructions handed in by /compact-prep through compact_now; the mod compacts with them once the turn ends.
const pending = atom({ plugin: 'context-band', key: 'pending' } as const, null)

// Above this the band lights the /compact-prep button and the chat title gets a marker.
const HEAVY = 500_000
// …or this share of the window, for the 200K windows most people have.
const HEAVY_PERCENT = 70
const isHeavy = (tokens: number | null | undefined, percent: number | null | undefined) =>
  (tokens ?? 0) >= HEAVY || (percent ?? 0) >= HEAVY_PERCENT
const MARK = '🟣 '

const TOOL_DESCRIPTION =
  'Стиснути ЦЮ сесію з наданим 7-розділовим блоком інструкцій (крок 3 скіла /compact-prep). ' +
  'Стиснення стартує саме, щойно закінчиться поточна відповідь, — вставляти блок вручну не треба. ' +
  'Викликай лише після кроку 0 (усе довговічне вже у файлах, робота закомічена) і останньою дією ходу.'

// The engine refuses compact while a turn runs; turn.complete still counts as inside it, so wait a beat and retry.
const compactLater = ($: EngineInterface, text: string, attempt = 0) => {
  $.clock.after(attempt === 0 ? 1500 : 3000, () => {
    void (async () => {
      try {
        const res = await $.session.compact({ instructions: text })
        $.ui.toast(res.skip ? `Стиснення скасовано: ${res.skip}` : 'Чат стиснуто за /compact-prep — продовжуємо', { timeoutMs: 8000 })
      } catch (err) {
        // A headless / SDK session compacts only inside a turn: run /compact itself, as a person pasting the block would.
        if (/headless|SDK/.test(err instanceof Error ? err.message : String(err))) {
          try {
            await $.command.run({ command: 'compact', args: text })
            return
          } catch (cmdErr) {
            $.ui.toast(`/compact-prep: /compact не запустився (${cmdErr instanceof Error ? cmdErr.message : String(cmdErr)})`, { timeoutMs: 15000 })
            return
          }
        }
        if (attempt < 6) return compactLater($, text, attempt + 1)
        $.ui.toast(`/compact-prep: не вдалося стиснути (${err instanceof Error ? err.message : String(err)}). Натисни кнопку ще раз.`, { timeoutMs: 15000 })
      }
    })()
  })
}

const gitState = async ($: EngineInterface, cwd: string): Promise<string> => {
  try {
    const st = await $.process.run(['git', 'status', '--short', '--branch'], { cwd, timeoutMs: 8000 })
    if (st.exitCode !== 0 || !st.stdout.trim()) return ''
    const head = await $.process.run(['git', 'log', '-1', '--format=%h %s'], { cwd, timeoutMs: 8000 })
    const lines = st.stdout.trim().split('\n')
    const more = lines.length > 20 ? `\n… ще ${lines.length - 20} рядків` : ''
    return `HEAD ${head.stdout.trim()}\n${lines.slice(0, 20).join('\n')}${more}`
  } catch {
    return ''
  }
}

const transcriptPath = async ($: EngineInterface): Promise<string> => {
  try {
    const id = await $.session.id()
    const root = await $.session.root()
    const configured = await $.env.get('CLAUDE_CONFIG_DIR')
    const user = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? ''
    const sep = (configured ?? user).includes('\\') ? '\\' : '/'
    const home = configured ?? `${user}${sep}.claude`
    const path = [home, 'projects', root.replace(/[^A-Za-z0-9]/g, '-'), `${id}.jsonl`].join(sep)
    return (await $.fs.exists(path)) ? path : [home, 'projects', '*', `${id}.jsonl`].join(sep)
  } catch {
    return '~/.claude/projects/*/<session_id>.jsonl'
  }
}

const toFill = (c: { tokens?: number; window: number; percent?: number }): Fill => ({
  tokens: c.tokens ?? null,
  window: c.window,
  percent: c.percent ?? null,
})

const short = (n: number) => (n >= 1_000_000 ? `${+(n / 1_000_000).toFixed(1)}M` : `${Math.round(n / 1000)}K`)

const modelName = (id: string) => {
  const [, family, major, minor] = id.match(/claude-([a-z]+)-(\d+)(?:-(\d+))?/) ?? []
  if (!family || !major) return id
  return `${family.charAt(0).toUpperCase()}${family.slice(1)} ${major}${minor ? `.${minor}` : ''}`
}

type Block = { text?: string }

// get_session answers with JSON text in its content blocks; take its title.
const titleOf = (r: unknown): string => {
  const o = r as { content?: Block[]; result?: { content?: Block[] } }
  for (const b of o.result?.content ?? o.content ?? []) {
    if (!b.text) continue
    try {
      const j = JSON.parse(b.text) as { title?: unknown }
      if (typeof j.title === 'string') return j.title
    } catch {
      const m = /"title"\s*:\s*"([^"]*)"/.exec(b.text)
      if (m?.[1]) return m[1]
    }
  }
  return ''
}

// Puts or removes the marker at the start of this chat's title in the sidebar.
const syncTitle = async ($: EngineInterface, heavy: boolean) => {
  if ((await read($, marked)) === heavy) return
  try {
    const got = await $.tool.call({ tool: 'mcp__ccd_session_mgmt__get_session', session_id: 'self' })
    const title = titleOf(got)
    if (!title) return
    const bare = title.startsWith(MARK) ? title.slice(MARK.length) : title
    const next = heavy ? MARK + bare : bare
    if (next !== title) {
      await $.tool.call({ tool: 'mcp__ccd_session_mgmt__set_session_title', session_id: 'self', title: next })
    }
    await update($, marked, () => heavy)
  } catch {
    // Outside the desktop app the session tools are absent: the band still shows the fill.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.tool.register({
      name: 'compact_now',
      description: TOOL_DESCRIPTION,
      inputSchema: {
        type: 'object',
        properties: {
          instructions: {
            type: 'string',
            description: 'Повний 7-розділовий блок для резюме (РІШЕННЯ, ЧЕРГА, ЗАРАЗ, ШЛЯХИ І ЗНАЧЕННЯ, ЛІЧИЛЬНИКИ, ВІДКРИТЕ, ІНСТРУМЕНТИ І ДОМОВЛЕНОСТІ), без префікса /compact',
          },
        },
        required: ['instructions'],
      },
    })
    const { context } = await $.session.usage()
    await update($, fill, () => toFill(context))
    const model = await $.session.model()
    await update($, brain, b => b ?? { model, effort: null })
    return result
  })

  on('tool.call', { tool: /^mcp__context-band__compact_now$/ }, async ($, e) => {
    const raw = (e as unknown as { instructions?: unknown }).instructions
    const text = (typeof raw === 'string' ? raw : '').replace(/^\s*\/compact\s+/, '').trim()
    if (text.length < 300 || !/РІШЕННЯ/.test(text) || !/ЗАРАЗ/.test(text)) {
      return { result: 'НЕ заплановано: instructions порожні або без 7 розділів (РІШЕННЯ … ІНСТРУМЕНТИ). Передай повний блок.' }
    }
    await update($, pending, () => text)
    return {
      result:
        'Заплановано: сесію буде стиснуто з цими інструкціями одразу після кінця цієї відповіді. ' +
        'Більше нічого в цьому ході не роби — одним-двома реченнями скажи користувачу, що чат стискається і робота продовжиться з того ж місця.',
    }
  }).catch(() => ({ result: 'НЕ заплановано: compact_now зламався всередині моду — надрукуй блок /compact для ручної вставки.' }))

  // Every compaction of the main conversation (manual, auto, plugin, precompute) gets our canon in its
  // instructions, and every one that stands gets a checkpoint built by code appended after the summary.
  on('session.compact', async ($, e, next) => {
    if (e.agentId) return next(e)
    const result = await next({ ...e, instructions: withCanon(e.instructions, e.trigger) })
    if (result.skip !== undefined || e.trigger === 'precompute') return result
    try {
      const cwd = await $.session.cwd()
      const where = { transcript: await transcriptPath($), cwd, git: await gitState($, cwd), missing: missingSections(result.messages) }
      const text = buildCheckpoint(e.messages, where)
      return { ...result, messages: [...result.messages, { role: 'user', text, toolUses: [] }] }
    } catch (err) {
      $.ui.toast(`context-band: чекпоінт після стиснення не зібрано (${err instanceof Error ? err.message : String(err)})`, { timeoutMs: 10000 })
      return result
    }
  }).catch(($, e, next) => (next.called ? Promise.reject(new Error('context-band: session.compact hook failed')) : next(e)))

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId) return result
    const text = await read($, pending)
    if (!text) return result
    await update($, pending, () => null)
    if (e.isAborted) {
      $.ui.toast('/compact-prep: хід перервано — стиснення не запускаю. Натисни кнопку ще раз, коли треба.', { timeoutMs: 10000 })
    } else {
      compactLater($, text)
    }
    return result
  })

  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('context')) {
      await update($, fill, () => toFill(e.context))
      if (e.context.tokens !== undefined) await syncTitle($, isHeavy(e.context.tokens, e.context.percent))
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    if (!e.agentId) {
      const b: Brain = { model: e.model, effort: e.effort === undefined ? null : String(e.effort) }
      await update($, brain, () => b)
    }
    return yield* next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const f = await read($, fill)
    const b = await read($, brain)
    const queued = await read($, pending)
    if (!f && !b) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const pct = f?.percent ?? null
    const heavy = isHeavy(f?.tokens, f?.percent)
    const color = pct === null ? undefined : heavy || pct >= 85 ? 'red' : pct >= 60 ? 'yellow' : 'green'
    const used = f?.tokens != null ? `${short(f.tokens)} / ${short(f.window)}` : f ? `— / ${short(f.window)}` : ''

    return (
      <Box>
        {f ? <Text color={color}>Контекст {pct === null ? '—' : `${pct}%`} </Text> : null}
        <Text dimColor>
          {used}
          {b ? ` · ${modelName(b.model)}${b.effort ? ` · ${b.effort}` : ''}` : ''}{' '}
        </Text>
        {queued ? <Text color="magenta">⏳ стисну після відповіді </Text> : null}
        {e.props.isWorking || queued ? null : (
        <Button
          key="compact-prep"
          label={heavy ? 'Стиснути зараз: /compact-prep' : '/compact-prep'}
          variant={heavy ? 'primary' : 'secondary'}
          dimColor={!heavy}
          onPress={async () => {
            try {
              await $.command.run({ command: 'compact-prep' })
            } catch (err) {
              $.ui.toast(`/compact-prep не запустилась: ${err instanceof Error ? err.message : String(err)}`)
            }
          }}
        />
        )}
      </Box>
    )
  })
}
