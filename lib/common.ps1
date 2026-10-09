# Shared paths and small helpers. Keep this file ASCII: PowerShell 5.1 reads BOM-less scripts as ANSI.

$TrayHome      = Join-Path $env:USERPROFILE '.claude\usage-tray'
$UsageFile     = Join-Path $TrayHome 'usage.json'
$ConfigFile    = Join-Path $TrayHome 'config.json'
$HistoryFile   = Join-Path $TrayHome 'history.json'
$CloudFile     = Join-Path $TrayHome 'cloud.json'
$ExtrasFile    = Join-Path $TrayHome 'extras.json'
$RunLogFile    = Join-Path $TrayHome 'scheduled.log'
$TrayPidFile   = Join-Path $TrayHome 'tray.pid'
$RunsDir       = Join-Path $TrayHome 'runs'
$CredsFile     = Join-Path $env:USERPROFILE '.claude\.credentials.json'

# Non-ASCII UI text is written as \uXXXX escapes and decoded here.
function Tx([string]$Text) { [regex]::Unescape($Text) }

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # -InputObject keeps arrays as arrays (the pipeline would unroll a one-item array).
    $json = ConvertTo-Json -InputObject $Object -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# A process started from inside a Claude Code session inherits its markers (CLAUDE_CODE_CHILD_SESSION,
# session id, messaging pipe...), which make child `claude` runs act as sub-sessions without a saved
# transcript. Dropping them makes every claude we launch a normal top-level run.
function Clear-ClaudeSessionEnv {
    $names = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -match '^(CLAUDE_CODE_|CLAUDECODE$|CLAUDE_PID$)' })
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
