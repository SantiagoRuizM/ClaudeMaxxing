// node --test whip/test (Node 22.6+ reads the .ts module, its types stripped)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { allowedCommand, enabledAgents, isActive, parseJson, usagePercent } from '../hooks/rules.ts'

const NOW = 1_800_000_000

test('usage: the highest window that has not reset', () => {
  const usage = { rate_limits: { five_hour: { used_percentage: 40, resets_at: NOW + 60 }, seven_day: { used_percentage: 88, resets_at: NOW + 999 } } }
  assert.equal(usagePercent(usage, NOW), 88)
  usage.rate_limits.seven_day.resets_at = NOW - 1
  assert.equal(usagePercent(usage, NOW), 40)
  assert.equal(usagePercent(undefined, NOW), 0)
})

test('active: on, with an agent, at or past the threshold (0 = always)', () => {
  assert.equal(isActive({ enabled: true, threshold: 85, agents: ['codex'] }, 85), true)
  assert.equal(isActive({ enabled: true, threshold: 85, agents: ['codex'] }, 84), false)
  assert.equal(isActive({ enabled: true, threshold: 0, agents: ['agy'] }, 0), true)
  assert.equal(isActive({ enabled: false, threshold: 0, agents: ['codex'] }, 99), false)
  assert.equal(isActive({ enabled: true, threshold: 0, agents: ['made-up'] }, 99), false, 'no known agent: off')
  assert.equal(isActive(undefined, 99), false)
  assert.deepEqual(enabledAgents({ agents: ['codex', 'x', 'copilot'] }), ['codex', 'copilot'])
})

test('settings written by PowerShell (BOM) and damaged files', () => {
  assert.deepEqual(parseJson('\uFEFF{"enabled":true}'), { enabled: true })
  assert.equal(parseJson('{oops'), undefined)
  assert.equal(parseJson(undefined), undefined)
})

test('bash: git, reading and the runner pass', () => {
  const agents = ['codex']
  for (const ok of [
    'git status --short',
    'git diff --stat && git log --oneline -5',
    'git diff -- lib/hub.ps1 | head -80',
    'cd /c/repo && git status',
    'ls -la 2>/dev/null',
    'git diff 2>&1 | tail -20',
    `bash "C:/Users/u/AppData/Local/ClaudeMaxxing/whip/bin/whip-run.sh" codex <<'EOF'\nFix x; then run npm test | tail > out.txt\nEOF`,
    `bash "C:/x/whip/bin/whip-run.sh" codex --resume <<'EOF'\nTests fail: test_login; fix src/a.ts:42\nEOF`,
    'bash "C:/x/whip/bin/whip-check.sh" "npm test"',
    'bash "C:/x/whip/bin/whip-check.sh" "npm run build && npm test | tail -5"',
    `bash C:/x/whip/bin/whip-check.sh "powershell -NoProfile -File test\\run-tests.ps1"`,
    'codex exec resume --last',
  ]) assert.equal(allowedCommand(ok, agents), true, ok)
})

test('bash: anything that edits or does the work is blocked', () => {
  const agents = ['codex']
  for (const bad of [
    'npm test',
    'sed -i s/a/b/ file.ts',
    'echo hi > file.txt',
    "cat > notes.md <<'EOF'\nx\nEOF",
    'git status; rm -rf build',
    'python script.py',
    'agy -p "do it"',
    'FOO=1 node build.js',
    '',
  ]) assert.equal(allowedCommand(bad, agents), false, bad)
})
