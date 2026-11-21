// Claude Whip rules, pure so node --test can cover them (whip/test/rules.test.mjs).
// The tray (ClaudeMaxxing > Claude Whip) writes whip.json; the statusline keeps usage.json up to date.

// forecast: also on before the threshold when the window is on pace to run out (off unless switched on).
export type Settings = { enabled?: boolean; threshold?: number; agents?: string[]; forecast?: boolean }
// The company policy IT puts in %ProgramData%\ClaudeMaxxing\policy.json (lib\business.ps1). Read here too, so editing
// whip.json does not get around a policy that turns the whip off.
export type Policy = { disabled?: string[] }

export function policyAllows(policy: Policy | undefined): boolean {
  return !Array.isArray(policy?.disabled) || !policy.disabled.includes('whip')
}
type Window = { used_percentage?: number; resets_at?: number }
export type Usage = { rate_limits?: { five_hour?: Window; seven_day?: Window } }

// Each id is also its CLI's command (agy: the Google Antigravity CLI).
export const AGENTS = ['codex', 'agy', 'opencode', 'copilot']

// Tools that write or spend the plan on their own: blocked while the whip is on. PowerShell too (the runner is bash).
export const BLOCKED_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Agent', 'Task', 'PowerShell'])

// Shell words allowed besides git, the runner and the agents: moving around and reading/filtering output.
const READ_WORDS = new Set(['cd', 'ls', 'pwd', 'cat', 'head', 'tail', 'grep', 'wc', 'sort', 'uniq', 'echo', 'which'])

// git subcommands and options that run other programs or write files from text Claude typed (a patch, an alias, a
// pager): with them git would be a way to edit or run anything. Commit, checkout, stash, diff and the rest pass.
const GIT_BLOCKED = new Set(['config', 'apply', 'am', 'difftool', 'mergetool', 'filter-branch', 'filter-repo', 'bisect', 'submodule', 'archive'])
const GIT_BLOCKED_OPTIONS = /^(-c|--config-env(=.*)?|--exec-path(=.*)?|-x|--exec(=.*)?|--extcmd(=.*)?|--output(=.*)?|-o)$/

// MCP tools that run code or write files (context-mode's ctx_execute, a server's run_command, write_file...).
const MCP_BLOCKED_WORDS = new Set(['execute', 'exec', 'run', 'write', 'edit', 'shell', 'bash', 'eval', 'apply', 'patch'])

export function blockedTool(tool: string): boolean {
  if (BLOCKED_TOOLS.has(tool)) return true
  if (!tool.startsWith('mcp__')) return false
  const name = tool.slice(tool.lastIndexOf('__') + 2).toLowerCase()
  return name.split(/[_-]/).some(word => MCP_BLOCKED_WORDS.has(word))
}

export function parseJson<T>(text: string | undefined): T | undefined {
  if (!text) return undefined
  try { return JSON.parse(text.replace(/^﻿/, '')) as T } catch { return undefined }
}

// The highest use among the plan windows that have not reset yet (Claude Code keeps an expired one in the snapshot).
export function usagePercent(usage: Usage | undefined, nowSec: number): number {
  let top = 0
  for (const w of [usage?.rate_limits?.five_hour, usage?.rate_limits?.seven_day]) {
    if (!w || typeof w.used_percentage !== 'number') continue
    if (typeof w.resets_at === 'number' && w.resets_at <= nowSec) continue
    top = Math.max(top, w.used_percentage)
  }
  return top
}

export function enabledAgents(settings: Settings | undefined): string[] {
  return (settings?.agents ?? []).filter(a => AGENTS.includes(a))
}

// The tray's forecast for the open 5-hour window (whip-forecast.json, rewritten every 5 minutes while the whip is on).
export type Forecast = { projectedPercent?: number; limitAt?: string; at?: number }
// Below half the plan a forecast is mostly a guess; a stale one (the tray stopped) does not count.
export const FORECAST_FLOOR = 50
const FORECAST_MAX_AGE = 15 * 60

// Whether, at this pace, the window hits its limit before it resets.
export function forecastHit(forecast: Forecast | undefined, percent: number, nowSec: number): boolean {
  if (!forecast || typeof forecast.projectedPercent !== 'number' || typeof forecast.at !== 'number') return false
  return forecast.projectedPercent >= 100 && percent >= FORECAST_FLOOR && nowSec - forecast.at <= FORECAST_MAX_AGE
}

// On, with an agent to hand work to, and the plan at or past the threshold (0 = always), or on pace to hit the limit
// when that switch is on: the threshold the user picked is never crossed otherwise.
export function isActive(settings: Settings | undefined, percent: number, hit = false): boolean {
  if (!settings?.enabled || enabledAgents(settings).length === 0) return false
  const threshold = typeof settings.threshold === 'number' ? settings.threshold : 85
  return percent >= threshold || (hit && settings.forecast === true)
}

// "plan at 62%, on pace to hit the limit at 15:40" when the forecast is what turned it on.
const planText = (percent: number, limitAt?: string) =>
  limitAt ? `plan at ${percent}%, on pace to hit the limit at ${limitAt}` : `plan at ${percent}%`

const words = (segment: string) => segment.replace(/["']/g, '').trim().split(/\s+/).filter(Boolean)
const slashes = (path: string) => path.split('\\').join('/')
const samePath = (a: string, b: string) => slashes(a).toLowerCase() === slashes(b).toLowerCase()

// Whether a Bash command only reads, runs git, the runner, the check (git + tests) or an enabled agent. A quoted
// heredoc's body is data (the task for the agent) and is not checked; every other line is. Writing to a file with
// ">" is editing. $runnerDir: the plugin's bin folder, the only whip-run.sh / whip-check.sh that count (one planted
// in the repo would run anything). This is a guard on the plan, not a sandbox: whip-check.sh runs its argument.
export function allowedCommand(command: string, agents: string[], runnerDir?: string): boolean {
  const lines = command.replace(/\r/g, '').split('\n')
  const checked: string[] = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    checked.push(line)
    const heredoc = /<<-?\s*(['"]?)(\w+)\1/.exec(line)
    if (!heredoc) continue
    const end = lines.findIndex((l, j) => j > i && l.trim() === heredoc[2])
    const body = lines.slice(i + 1, end < 0 ? lines.length : end)
    // An unquoted heredoc expands $(...) and `...` in its body: that is running code.
    if (!heredoc[1] && body.some(l => /\$\(|`/.test(l))) return false
    if (end < 0) break
    i = end
  }
  const commands = checked.filter(line => line.trim() !== '')
  return commands.length > 0 && commands.every(line => allowedLine(line, agents, runnerDir))
}

function allowedLine(raw: string, agents: string[], runnerDir?: string): boolean {
  let line = raw.replace(/<<-?\s*['"]?\w+['"]?/g, '')
  // $(...), `...` and <(...) run a command anywhere but inside single quotes.
  if (/\$\(|`|[<>]\(/.test(line.replace(/'[^']*'/g, ''))) return false
  // Inside quotes an operator is text (whip-check.sh "npm run build && npm test").
  line = line.replace(/"[^"]*"|'[^']*'/g, quoted => quoted.replace(/[&|;<>]/g, ' '))
  line = line.replace(/\d?>&\d|&?\d?>\s*\/dev\/null/g, '')
  if (line.includes('>')) return false
  // A lone & runs what precedes it in the background: it separates commands like ; does.
  const segments = line.split(/&&|\|\||;|\||&/).map(s => s.trim()).filter(Boolean)
  if (segments.length === 0) return false
  const isRunner = (x: string) => /(^|[\\/])whip-(run|check)\.sh$/.test(x) &&
    (!runnerDir || samePath(slashes(x).slice(0, slashes(x).lastIndexOf('/')), runnerDir))
  return segments.every(segment => {
    const w = words(segment)
    // VAR=value before a command changes what it runs (PATH, GIT_EXTERNAL_DIFF, GIT_PAGER...).
    if (w.length === 0 || /^\w+=/.test(w[0])) return false
    const [first, second = ''] = w
    if (first === 'git') {
      const sub = w.slice(1).find(x => !x.startsWith('-') && !/^-C$/.test(x)) ?? ''
      return !GIT_BLOCKED.has(sub) && !w.slice(1).some(x => GIT_BLOCKED_OPTIONS.test(x))
    }
    // sort -o and uniq <in> <out> write files.
    if (first === 'sort') return !w.some(x => /^(-o|--output(=.*)?)$/.test(x) || /^-[a-z]*o/.test(x))
    if (first === 'uniq') return w.slice(1).filter(x => !x.startsWith('-')).length <= 1
    if (READ_WORDS.has(first) || isRunner(first)) return true
    if ((first === 'bash' || first === 'sh') && isRunner(second)) return true
    return agents.includes(first)
  })
}

const checkOf = (runner: string) => runner.replace(/whip-run\.sh$/, 'whip-check.sh')

export function denyText(percent: number, runner: string, agents: string[], limitAt?: string): string {
  return `Claude Whip is on (${planText(percent, limitAt)}): an agent writes the code, you watch git, run the tests and send it ` +
    `feedback. Editing, subagents and shell commands other than git, reading, the agents and the check are blocked. ` +
    `Hand it a task: bash "${runner}" <${agents.join('|')}> [--resume] <<'EOF' ... EOF (Bash, run_in_background: true); ` +
    `run tests with: bash "${checkOf(runner)}" "<test command>". The claude-whip skill has the loop.`
}

export function contextText(percent: number, threshold: number, runner: string, agents: string[], limitAt?: string): string {
  const why = limitAt ? `at ${percent}% and on pace to hit its limit at ${limitAt}` : `at ${percent}% (threshold ${threshold}%)`
  return `[Claude Whip] The Claude plan is ${why}, so this session directs a feedback ` +
    `loop with an agent: plan and brief -> the agent writes the code -> you check git and run the tests -> you send the ` +
    `agent what failed (--resume keeps its conversation) -> repeat until green, at most 3 rounds, then report. ` +
    `Agents on: ${agents.join(', ')}. Agent: bash "${runner}" <agent> [--resume] <<'EOF' <task or feedback> EOF ` +
    `(Bash, run_in_background: true; one agent per working tree at a time). Check after every round: ` +
    `bash "${checkOf(runner)}" "<test command>" (git status, diff --stat and the test result in a few lines). ` +
    `Read only what you need (Grep, Glob, Read with ranges, git diff -- <file>). Load the claude-whip skill for the ` +
    `loop. Edit, Write, subagents and other shell commands are blocked.`
}
