// node --test whip/test (Node 22.6+ reads the .ts module, its types stripped)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { allowedCommand, blockedTool, enabledAgents, forecastHit, isActive, parseJson, policyAllows, usagePercent } from '../hooks/rules.ts'

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

const BIN = 'C:/x/whip/bin'

test('bash: the bypasses found in the audit are blocked', () => {
  const agents = ['codex']
  for (const bad of [
    'git status & rm -rf build',
    'git status\nrm -rf build',
    'echo $(node -e 1)',
    'ls `rm x`',
    'cat <(node evil.js)',
    'echo "$(node -e 1)"',
    "git apply <<'EOF'\n--- a/x\n+++ b/x\nEOF",
    'git -c alias.x="!node evil.js" x',
    'git -c core.pager=evil log',
    'git config alias.x "!rm -rf ."',
    'git rebase -x "node evil.js" HEAD~1',
    'sort -o out.txt in.txt',
    'sort -uo out.txt in.txt',
    'uniq in.txt out.txt',
    'PATH=. git status',
    'GIT_EXTERNAL_DIFF=evil git diff',
    `bash "${BIN}/whip-run.sh" codex <<'EOF'\ntask\nEOF\nrm -rf build`,
    `bash "${BIN}/whip-run.sh" codex <<EOF\nrun $(rm -rf build)\nEOF`,
    'bash ./whip-check.sh "sed -i s/a/b/ f.ts"',
    'bash C:/repo/evil/whip-check.sh "x"',
  ]) assert.equal(allowedCommand(bad, agents, BIN), false, bad)
})

test('bash: what the loop needs still passes with the plugin folder known', () => {
  const agents = ['codex']
  for (const ok of [
    `bash "${BIN}/whip-run.sh" codex <<'EOF'\nFix x; then $(npm test) | tail > out.txt\nEOF`,
    `bash "${BIN}/whip-check.sh" "npm run build && npm test | tail -5"`,
    'bash C:\\x\\whip\\bin\\whip-check.sh "npm test"',
    "echo '$(not run)'",
    'git log --oneline | sort | uniq -c',
    'git commit -m "fix: login"',
    'git -C /c/repo status',
    'sort -u notes.txt',
  ]) assert.equal(allowedCommand(ok, agents, BIN), true, ok)
})

test('tools: MCP tools that run code or write are blocked, readers pass', () => {
  for (const bad of ['Edit', 'Agent', 'mcp__plugin_context-mode_context-mode__ctx_execute', 'mcp__fs__write_file', 'mcp__srv__run_command', 'mcp__blender__execute_blender_code'])
    assert.equal(blockedTool(bad), true, bad)
  for (const ok of ['Read', 'Grep', 'mcp__plugin_context-mode_context-mode__ctx_search', 'mcp__fs__read_file', 'mcp__claude-in-chrome__read_page', 'mcp__runtime__status'])
    assert.equal(blockedTool(ok), false, ok)
})


test('forecast: on pace to hit the limit turns it on under the threshold, from half the plan, while fresh', () => {
  const on = { enabled: true, threshold: 85, agents: ['codex'] }
  const fc = { projectedPercent: 120, limitAt: '15:40', at: NOW - 60 }
  assert.equal(forecastHit(fc, 62, NOW), true)
  assert.equal(isActive(on, 62, forecastHit(fc, 62, NOW)), true)
  assert.equal(forecastHit(fc, 40, NOW), false, 'under half the plan a forecast is a guess')
  assert.equal(forecastHit({ ...fc, projectedPercent: 95 }, 62, NOW), false, 'ends under the limit')
  assert.equal(forecastHit({ ...fc, at: NOW - 3600 }, 62, NOW), false, 'stale: the tray stopped writing it')
  assert.equal(forecastHit(undefined, 99, NOW), false)
  assert.equal(isActive({ ...on, enabled: false }, 62, true), false, 'off stays off')
})

test('policy: an IT policy that turns the whip off wins over whip.json', () => {
  assert.equal(policyAllows(undefined), true)
  assert.equal(policyAllows({ disabled: ['bridge'] }), true)
  assert.equal(policyAllows({ disabled: ['whip', 'bridge'] }), false)
})
