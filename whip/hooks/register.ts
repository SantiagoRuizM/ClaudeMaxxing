// Claude Whip (ClaudeMaxxing): when the plan runs low, the session only reads, plans and runs other agents.
// Off, or under its threshold, every hook just passes through. The settings come from the tray's whip.json, the
// plan use from the statusline's usage.json and the window's forecast from the tray's whip-forecast.json, all read
// on each event (small files, read in process).
import type { EngineInterface, Register } from 'claude-code'
import { allowedCommand, blockedTool, contextText, denyText, enabledAgents, forecastHit, isActive, parseJson, policyAllows, usagePercent } from './rules'
import type { Forecast, Policy, Settings, Usage } from './rules'

// limitAt: set only when the forecast, not the threshold, is what turned it on.
type State = { active: boolean; percent: number; threshold: number; agents: string[]; runner: string; limitAt?: string }

async function stateOf($: EngineInterface): Promise<State> {
  const home = ((await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '').replace(/\\/g, '/')
  const dir = `${home}/.claude/usage-tray`
  const read = (name: string) => $.fs.read(`${dir}/${name}`).catch(() => undefined)
  const settings = parseJson<Settings>(await read('whip.json'))
  const nowSec = (await $.clock.now()) / 1000
  const percent = Math.round(usagePercent(parseJson<Usage>(await read('usage.json')), nowSec))
  const threshold = settings?.threshold ?? 85
  const forecast = parseJson<Forecast>(await read('whip-forecast.json'))
  const hit = forecastHit(forecast, percent, nowSec)
  const programData = ((await $.env.get('ProgramData')) ?? (await $.env.get('PROGRAMDATA')) ?? '').replace(/\\/g, '/')
  const policy = programData ? parseJson<Policy>(await $.fs.read(`${programData}/ClaudeMaxxing/policy.json`).catch(() => undefined)) : undefined
  return {
    active: policyAllows(policy) && isActive(settings, percent, hit),
    percent,
    threshold,
    agents: enabledAgents(settings),
    runner: `${$.plugin.root.replace(/\\/g, '/')}/bin/whip-run.sh`,
    limitAt: hit && percent < threshold ? forecast?.limitAt || undefined : undefined,
  }
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    const s = await stateOf($)
    if (!s.active) return next(e)
    return next({ ...e, context: [...(e.context ?? []), contextText(s.percent, s.threshold, s.runner, s.agents, s.limitAt)] })
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const isShell = e.tool === 'Bash'
    if (!isShell && !blockedTool(e.tool)) return next(e)
    const s = await stateOf($)
    if (!s.active) return next(e)
    const bin = s.runner.slice(0, s.runner.lastIndexOf('/'))
    if (isShell && allowedCommand(String((e as { command?: unknown }).command ?? ''), s.agents, bin)) return next(e)
    return { deny: denyText(s.percent, s.runner, s.agents, s.limitAt) }
    // A broken guard fails open: it must never stop the session's work.
  }).catch(($, e, next) => next(e))
}
