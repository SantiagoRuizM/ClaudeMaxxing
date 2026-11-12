// Claude Whip (ClaudeMaxxing): when the plan runs low, the session only reads, plans and runs other agents.
// Off, or under its threshold, every hook just passes through. The settings come from the tray's whip.json and the
// plan use from the statusline's usage.json, both read on each event (small files, read in process).
import type { EngineInterface, Register } from 'claude-code'
import { allowedCommand, BLOCKED_TOOLS, contextText, denyText, enabledAgents, isActive, parseJson, usagePercent } from './rules'
import type { Settings, Usage } from './rules'

type State = { active: boolean; percent: number; threshold: number; agents: string[]; runner: string }

async function stateOf($: EngineInterface): Promise<State> {
  const home = ((await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '').replace(/\\/g, '/')
  const dir = `${home}/.claude/usage-tray`
  const read = (name: string) => $.fs.read(`${dir}/${name}`).catch(() => undefined)
  const settings = parseJson<Settings>(await read('whip.json'))
  const percent = Math.round(usagePercent(parseJson<Usage>(await read('usage.json')), (await $.clock.now()) / 1000))
  return {
    active: isActive(settings, percent),
    percent,
    threshold: settings?.threshold ?? 85,
    agents: enabledAgents(settings),
    runner: `${$.plugin.root.replace(/\\/g, '/')}/bin/whip-run.sh`,
  }
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    const s = await stateOf($)
    if (!s.active) return next(e)
    return next({ ...e, context: [...(e.context ?? []), contextText(s.percent, s.threshold, s.runner, s.agents)] })
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const isShell = e.tool === 'Bash'
    if (!isShell && !BLOCKED_TOOLS.has(e.tool)) return next(e)
    const s = await stateOf($)
    if (!s.active) return next(e)
    if (isShell && allowedCommand(String((e as { command?: unknown }).command ?? ''), s.agents)) return next(e)
    return { deny: denyText(s.percent, s.runner, s.agents) }
    // A broken guard fails open: it must never stop the session's work.
  }).catch(($, e, next) => next(e))
}
