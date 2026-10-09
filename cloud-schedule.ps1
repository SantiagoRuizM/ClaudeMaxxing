# Creates the one-off cloud routine the user confirmed in the schedule dialog. Started by the dialog
# without a console window; the dialog follows this run through the request's status in cloud.json.
# Claude Code may only use the routines tool (RemoteTrigger); every other tool is denied.
param(
    [Parameter(Mandatory = $true)][string]$At,
    [Parameter(Mandatory = $true)][string]$Id
)

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
Clear-ClaudeSessionEnv

$logFile = Join-Path $RunsDir "cloud-$Id.log"
try {
    $config = Read-JsonFile $ConfigFile
    if (-not $config -or -not $config.claudePath -or -not (Test-Path -LiteralPath $config.claudePath)) {
        throw 'claude not found; run install.ps1 again'
    }
    $when = [datetime]::ParseExact($At, 'yyyy-MM-ddTHH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not (Test-Path -LiteralPath $RunsDir)) { New-Item -ItemType Directory -Force -Path $RunsDir | Out-Null }
    Push-Location $RunsDir
    try {
        $output = & $config.claudePath -p (Format-CloudSchedulePrompt $when) --model sonnet `
            --allowedTools RemoteTrigger --setting-sources user --no-session-persistence 2>&1 | Out-String
    } finally {
        Pop-Location
    }
    [System.IO.File]::WriteAllText($logFile, $output, (New-Object System.Text.UTF8Encoding($false)))
    $outcome = Get-CloudScheduleOutcome $output
    Set-CloudRequestResult $Id $outcome.Status $outcome.RoutineId $outcome.Error
} catch {
    Set-CloudRequestResult $Id 'failed' $null $_.Exception.Message
}
exit 0
