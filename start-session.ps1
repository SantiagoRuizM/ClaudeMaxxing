# Runs a tiny Claude Code prompt so the 5-hour usage window starts now. Launched by Task Scheduler.
# Runs from a neutral folder so no project hooks (e.g. ClaudeVoice) fire.

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
Clear-ClaudeSessionEnv

$startedAt = Get-Date
$result = [ordered]@{ at = $startedAt.ToString('o'); ok = $false; exitCode = $null; output = '' }

try {
    $config = Read-JsonFile $ConfigFile
    if (-not $config -or -not $config.claudePath -or -not (Test-Path -LiteralPath $config.claudePath)) {
        throw 'no se encuentra claude: instala Claude Code y reinstala ClaudeMaxxing (install.ps1 desde el repo)'
    }
    if (-not (Test-Path -LiteralPath $RunsDir)) { New-Item -ItemType Directory -Force -Path $RunsDir | Out-Null }
    Push-Location $RunsDir
    try {
        $output = & $config.claudePath -p 'Reply with only the word: ok' --model haiku `
            --setting-sources user --no-session-persistence --strict-mcp-config 2>&1 | Out-String
        $result.exitCode = $LASTEXITCODE
        $result.ok = ($LASTEXITCODE -eq 0)
        $result.output = $output.Trim()
    } finally {
        Pop-Location
    }
} catch {
    $result.output = $_.Exception.Message
}

if ($result.output.Length -gt 300) { $result.output = $result.output.Substring(0, 300) }
Add-ScheduleHistory $result
$line = '{0} ok={1} exit={2} {3}' -f $result.at, $result.ok, $result.exitCode, ($result.output -replace '\s+', ' ')
Add-Content -LiteralPath $RunLogFile -Value $line -Encoding UTF8
exit 0
