// Claude Whip rules, pure so node --test can cover them (whip/test/rules.test.mjs).
// The tray (ClaudeMaxxing > Claude Whip) writes whip.json; the statusline keeps usage.json up to date.

export type Settings = { enabled?: boolean; threshold?: number; agents?: string[] }
type Window = { used_percentage?: number; resets_at?: number }
export type Usage = { rate_limits?: { five_hour?: Window; seven_day?: Window } }

// Each id is also its CLI's command (agy: the Google Antigravity CLI).
export const AGENTS = ['codex', 'agy', 'opencode', 'copilot']

// Tools that write or spend the plan on their own: blocked while the whip is on. PowerShell too (the runner is bash).
export const BLOCKED_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Agent', 'Task', 'PowerShell'])

// Shell words allowed besides git, the runner and the agents: moving around and reading/filtering output.
const READ_WORDS = new Set(['cd', 'ls', 'pwd', 'cat', 'head', 'tail', 'grep', 'wc', 'sort', 'uniq', 'echo', 'which'])

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

// On, with an agent to hand work to, and the plan at or past the threshold (0 = always).
export function isActive(settings: Settings | undefined, percent: number): boolean {
  if (!settings?.enabled || enabledAgents(settings).length === 0) return false
  const threshold = typeof settings.threshold === 'number' ? settings.threshold : 85
  return percent >= threshold
}

const words = (segment: string) => segment.replace(/["']/g, '').trim().split(/\s+/).filter(Boolean)

// Whether a Bash command only reads, runs git, the runner, the check (git + tests) or an enabled agent. Only its
// first line is checked: the
// rest is a heredoc body (the task for the agent), which is data. Writing to a file with ">" is editing.
export function allowedCommand(command: string, agents: string[]): boolean {
  let line = command.split('\n')[0].replace(/<<-?\s*['"]?\w+['"]?/g, '')
  // Inside quotes an operator is text (whip-check.sh "npm run build && npm test").
  line = line.replace(/"[^"]*"|'[^']*'/g, quoted => quoted.replace(/[&|;<>]/g, ' '))
  line = line.replace(/\d?>&\d|&?\d?>\s*\/dev\/null/g, '')
  if (line.includes('>')) return false
  const segments = line.split(/&&|\|\||;|\|/).map(s => s.trim()).filter(Boolean)
  if (segments.length === 0) return false
  return segments.every(segment => {
    const w = words(segment)
    while (w.length && /^\w+=/.test(w[0])) w.shift()
    if (w.length === 0) return false
    const [first, second = ''] = w
    const isRunner = (x: string) => /(^|[\\/])whip-(run|check)\.sh$/.test(x)
    if (first === 'git' || READ_WORDS.has(first) || isRunner(first)) return true
    if ((first === 'bash' || first === 'sh') && isRunner(second)) return true
    return agents.includes(first)
  })
}

const checkOf = (runner: string) => runner.replace(/whip-run\.sh$/, 'whip-check.sh')

export function denyText(percent: number, runner: string, agents: string[]): string {
  return `Claude Whip is on (plan at ${percent}%): an agent writes the code, you watch git, run the tests and send it ` +
    `feedback. Editing, subagents and shell commands other than git, reading, the agents and the check are blocked. ` +
    `Hand it a task: bash "${runner}" <${agents.join('|')}> [--resume] <<'EOF' ... EOF (Bash, run_in_background: true); ` +
    `run tests with: bash "${checkOf(runner)}" "<test command>". The claude-whip skill has the loop.`
}

export function contextText(percent: number, threshold: number, runner: string, agents: string[]): string {
  return `[Claude Whip] The Claude plan is at ${percent}% (threshold ${threshold}%), so this session directs a feedback ` +
    `loop with an agent: plan and brief -> the agent writes the code -> you check git and run the tests -> you send the ` +
    `agent what failed (--resume keeps its conversation) -> repeat until green, at most 3 rounds, then report. ` +
    `Agents on: ${agents.join(', ')}. Agent: bash "${runner}" <agent> [--resume] <<'EOF' <task or feedback> EOF ` +
    `(Bash, run_in_background: true; one agent per working tree at a time). Check after every round: ` +
    `bash "${checkOf(runner)}" "<test command>" (git status, diff --stat and the test result in a few lines). ` +
    `Read only what you need (Grep, Glob, Read with ranges, git diff -- <file>). Load the claude-whip skill for the ` +
    `loop. Edit, Write, subagents and other shell commands are blocked.`
}
