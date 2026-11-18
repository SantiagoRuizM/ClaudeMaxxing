# Shared paths and small helpers. Keep this file ASCII: PowerShell 5.1 reads BOM-less scripts as ANSI.

$AppName       = 'ClaudeMaxxing'
$AppVersion    = '1.1.0'
# install.ps1 copies the runtime here; nothing runs from the repo.
$DefaultInstallDir = Join-Path $env:LOCALAPPDATA $AppName
$TrayHome      = Join-Path $env:USERPROFILE '.claude\usage-tray'
# Windows Terminal profiles of the menu sessions, one per color with its egg as the tab icon (install.ps1).
$TerminalFragmentFile = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ClaudeMaxxing\sessions.json'
$UsageFile     = Join-Path $TrayHome 'usage.json'
$ConfigFile    = Join-Path $TrayHome 'config.json'
$HistoryFile   = Join-Path $TrayHome 'history.json'
$CloudFile     = Join-Path $TrayHome 'cloud.json'
$ExtrasFile    = Join-Path $TrayHome 'extras.json'
$PlanFile      = Join-Path $TrayHome 'plan.json'
$RunLogFile    = Join-Path $TrayHome 'scheduled.log'
$TrayPidFile   = Join-Path $TrayHome 'tray.pid'
$RunsDir       = Join-Path $TrayHome 'runs'
$SessionsFile  = Join-Path $TrayHome 'sessions.json'
$SessionLogFile = Join-Path $TrayHome 'sessions.log'
# The two-sessions-per-monitor limit, switched off in the ClaudeMaxxing window (lib\sessions.ps1, Test-SessionLimit).
$SessionLimitFile = Join-Path $TrayHome 'session-limit.json'
$BinDir        = Join-Path $TrayHome 'bin'
# Estadisticas in the ClaudeMaxxing window: the last result and the per-transcript cache (lib\stats.cs).
$StatsFile     = Join-Path $TrayHome 'stats.json'
$StatsCacheFile = Join-Path $TrayHome 'stats-cache.json'
# "Otros PCs": keys, paired PCs and the SSH server's files (lib\bridge.ps1).
$BridgeHome    = Join-Path $TrayHome 'bridge'
$CredsFile     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$MenuKey       = 'HKCU:\Software\ClaudeCodeMenu'
$UninstallKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
$StartupDir    = [Environment]::GetFolderPath('Startup')
$TrayLink      = Join-Path $StartupDir "$AppName.lnk"
# Names used before the rename to ClaudeMaxxing; install and uninstall clean them up.
$LegacyTrayLink = Join-Path $StartupDir 'ClaudeTray.lnk'

# Non-ASCII UI text is written as \uXXXX escapes and decoded here.
function Tx([string]$Text) { [regex]::Unescape($Text) }

# Numbers, money and dates in the window follow one Spanish culture, like its text: the user's own when Windows is in
# Spanish (es-CO, es-MX...), es-ES otherwise. Format-Clock (lib\schedule.ps1) and Format-Usd (lib\forecast.ps1) use it.
$UiCulture = if ([Globalization.CultureInfo]::CurrentCulture.TwoLetterISOLanguageName -eq 'es') { [Globalization.CultureInfo]::CurrentCulture }
    else { [Globalization.CultureInfo]::GetCultureInfo('es-ES') }

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # -InputObject keeps arrays as arrays (the pipeline would unroll a one-item array).
    $json = ConvertTo-Json -InputObject $Object -Depth 6
    Write-TextFileAtomic $Path $json
}

# API keys at rest (voice\config.local.json, freellm.json): "dpapi:<base64>", encrypted for this Windows user, so a
# copied file or a backup does not carry the key. A plain value (saved before) is read as it is. voice\hooks\common.ps1
# has the same pair for the hooks.
function Protect-Secret([string]$Value) {
    if (-not $Value) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Value), $null, 'CurrentUser')
    'dpapi:' + [Convert]::ToBase64String($bytes)
}

function Unprotect-Secret([string]$Value) {
    if (-not $Value.StartsWith('dpapi:')) { return $Value }
    Add-Type -AssemblyName System.Security
    try { [Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value.Substring(6)), $null, 'CurrentUser')) }
    catch { '' }
}

# Writes a whole file at once: a temporary file next to it, then a rename over it, so a reader in another process
# (the statusline, the Whip plugin, a hook) never sees it empty or half written.
# shortcut: a reader that holds the file without FILE_SHARE_DELETE blocks the rename; then it is written in place.
function Write-TextFileAtomic([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $encoding)
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $Path) }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllText($Path, $Text, $encoding)
    }
}

# A process started from inside a Claude Code session inherits its markers (CLAUDE_CODE_CHILD_SESSION,
# session id, messaging pipe...), which make child `claude` runs act as sub-sessions without a saved
# transcript. Dropping them makes every claude we launch a normal top-level run.
function Clear-ClaudeSessionEnv {
    $names = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -match '^(CLAUDE_CODE_|CLAUDECODE$|CLAUDE_PID$)' })
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
