#!/usr/bin/env node
// `npx github:SantiagoRuizM/ClaudeMaxxing [install.ps1 options]`: runs this copy's install.ps1, which copies
// everything to %LOCALAPPDATA%\ClaudeMaxxing, so npx's cache can go afterwards. Options pass through
// (-SkipBridge, -NoHotkeys...).
const { spawnSync } = require('node:child_process')
const path = require('node:path')

if (process.platform !== 'win32') {
  console.error('ClaudeMaxxing runs on Windows 11.')
  process.exit(1)
}
const powershell = path.join(process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
const installer = path.join(__dirname, '..', 'install.ps1')
const result = spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', installer, ...process.argv.slice(2)], { stdio: 'inherit' })
process.exit(result.status ?? 1)
