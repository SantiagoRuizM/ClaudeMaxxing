// claude plugin test whip: the mod against the engine, with whip.json and usage.json in memory.
import { expect, mock, test } from 'claude-code/testing'

const DIR = 'C:/Users/u/.claude/usage-tray'
const NOW_MS = 1_800_000_000_000
const usage = (pct: number) => JSON.stringify({ rate_limits: { five_hour: { used_percentage: pct, resets_at: NOW_MS / 1000 + 3600 } } })

function world(on: Parameters<Parameters<typeof test>[1]>[1], files: Record<string, string>) {
  mock.env(on, { USERPROFILE: 'C:\\Users\\u' })
  mock.clock(on, { now: NOW_MS })
  on('fs.read', (_, e) => {
    const text = files[(e as { path: string }).path.replace(/\\/g, '/')]
    if (text === undefined) throw new Error('ENOENT')
    return { value: text }
  })
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
}

const ON = JSON.stringify({ enabled: true, threshold: 85, agents: ['codex'] })

test('past the threshold: Edit is denied and git passes', async ($, on) => {
  world(on, { [`${DIR}/whip.json`]: ON, [`${DIR}/usage.json`]: usage(90) })
  const edit = await $.tool.call({ tool: 'Edit', file_path: 'a.ts', old_string: 'a', new_string: 'b' })
  // The test's own $.tool.call gets a plugin's deny as { deny } (a session's model reads it as the error text).
  expect(String(edit.deny)).toMatch(/Claude Whip is on \(plan at 90%\).*whip-run\.sh/)
  const npm = await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(npm.deny).toBeDefined()
  const agent = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'x' })
  expect(agent.deny).toBeDefined()
  const git = await $.tool.call({ tool: 'Bash', command: 'git diff --stat' })
  expect(git.deny).toBeUndefined()
  const read = await $.tool.call({ tool: 'Read', file_path: 'a.ts' })
  expect(read.deny).toBeUndefined()
})

test('past the threshold: each prompt carries the director note', async ($, on) => {
  world(on, { [`${DIR}/whip.json`]: ON, [`${DIR}/usage.json`]: usage(90) })
  const sent = await $.prompt.submit({ text: 'arregla el login' })
  expect((sent as { context?: string[] }).context?.join('\n') ?? '').toMatch(/\[Claude Whip\].*90%.*whip-run\.sh/s)
})

test('under the threshold: nothing changes', async ($, on) => {
  world(on, { [`${DIR}/whip.json`]: ON, [`${DIR}/usage.json`]: usage(50) })
  const edit = await $.tool.call({ tool: 'Edit', file_path: 'a.ts', old_string: 'a', new_string: 'b' })
  expect(edit.deny).toBeUndefined()
  const sent = await $.prompt.submit({ text: 'hola' })
  expect((sent as { context?: string[] }).context ?? []).toEqual([])
})

test('no whip.json at all: nothing changes', async ($, on) => {
  world(on, {})
  const write = await $.tool.call({ tool: 'Write', file_path: 'a.ts', content: 'x' })
  expect(write.deny).toBeUndefined()
})
