export type Fill = { tokens: number | null; window: number; percent: number | null }
export type Brain = { model: string; effort: string | null }

declare module 'claude-code' {
  interface PluginState {
    'context-band': { fill: Fill | null; brain: Brain | null; marked: boolean; pending: string | null }
  }
}
