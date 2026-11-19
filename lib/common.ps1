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

# UI language. The text in the code is Spanish; lib\lang\<code>.json has "name" (shown in Configuracion), "culture"
# (numbers, money and dates) and "strings": each Spanish text, decoded, with its translation. A text missing there
# is shown in Spanish, so adding a language is adding one file. The choice is saved in $LanguageFile; without it,
# the Windows display language if there is a file for it, else Spanish.
$LangDir = Join-Path $PSScriptRoot 'lang'
$LanguageFile = Join-Path $TrayHome 'language.json'
$script:UiStrings = $null

# Translates a whole text (as written in the code, decoded). Draw-Text, Measure-TextWidth and the other text helpers
# call it, so a literal passed to them needs nothing else; the text is returned as it is when there is no translation.
function L([string]$Text) {
    if ($script:UiStrings -and $Text -and $script:UiStrings.ContainsKey($Text)) { return $script:UiStrings[$Text] }
    $Text
}

# Non-ASCII UI text is written as \uXXXX escapes: Tx decodes and translates, Ux only decodes (for a text kept to be
# translated when drawn, so a language change shows at once).
function Ux([string]$Text) { [regex]::Unescape($Text) }
function Tx([string]$Text) { L ([regex]::Unescape($Text)) }

# A catalog as a case-sensitive dictionary: ConvertFrom-Json (PowerShell 5.1) refuses keys that differ only in case,
# and a catalog has them ("Hoy" the day label, "hoy " in a sentence). $null when missing or invalid.
function Read-UiCatalog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $catalog = $serializer.DeserializeObject([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
        if ($catalog -is [System.Collections.Generic.IDictionary[string, object]]) { return $catalog }
    } catch { }
    $null
}

# code -> name of every language with a file in $LangDir, Spanish first.
function Get-UiLanguages {
    $languages = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $LangDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object { $_.BaseName -ne 'es' }, BaseName)) {
        $catalog = Read-UiCatalog $file.FullName
        if ($catalog -and $catalog['name']) { $languages[$file.BaseName] = [string]$catalog['name'] }
    }
    $languages
}

# $env:CLAUDEMAXXING_LANG wins: the tests pin Spanish with it and the previews (-RenderHubTo) draw other languages.
function Get-UiLanguage {
    $saved = Read-JsonFile $LanguageFile
    $code = if ($env:CLAUDEMAXXING_LANG) { $env:CLAUDEMAXXING_LANG } elseif ($saved -and $saved.language) { [string]$saved.language }
        else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    if ($code -notmatch '^[a-z]{2,3}(-[A-Za-z]+)?$' -or -not (Test-Path -LiteralPath (Join-Path $LangDir "$code.json"))) { $code = 'es' }
    $code
}

# Loads a language's strings and culture. Numbers, money and dates follow the user's own culture when Windows is in
# that language (es-CO, en-GB...), the file's otherwise. Format-Clock (lib\schedule.ps1) and Format-Usd use it.
function Set-UiLanguage([string]$Code) {
    $catalog = Read-UiCatalog (Join-Path $LangDir "$Code.json")
    $strings = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if ($catalog -and $catalog['strings'] -is [System.Collections.IDictionary]) {
        foreach ($pair in $catalog['strings'].GetEnumerator()) { if ($pair.Value) { $strings[$pair.Key] = [string]$pair.Value } }
    }
    $script:UiStrings = $strings
    $script:UiLanguage = $Code
    $current = [Globalization.CultureInfo]::CurrentCulture
    $script:UiCulture = if ($current.TwoLetterISOLanguageName -eq $Code.Split('-')[0]) { $current }
        else { try { [Globalization.CultureInfo]::GetCultureInfo($(if ($catalog -and $catalog['culture']) { [string]$catalog['culture'] } else { 'es-ES' })) } catch { [Globalization.CultureInfo]::GetCultureInfo('es-ES') } }
}

# Saves the choice and applies it in this process; the other windows (Claude Whisper...) take it when they open.
function Save-UiLanguage([string]$Code) {
    Write-JsonFile $LanguageFile @{ language = $Code }
    Set-UiLanguage $Code
}

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

# The claude to run: the preferred path, the one install.ps1 recorded (it may be stale: Claude Code moved from npm to
# the native installer), then claude.exe or claude.cmd on PATH and the native installer's. Only real programs: an npm
# claude.ps1 shim may point at an exe that no longer exists. The workers, start-session.ps1 and cloud-schedule.ps1.
function Resolve-ClaudePath([string]$Preferred) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Preferred) { $candidates.Add($Preferred) }
    $config = Read-JsonFile $ConfigFile
    if ($config -and $config.claudePath) { $candidates.Add([string]$config.claudePath) }
    foreach ($name in 'claude.exe', 'claude.cmd') {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) { $candidates.Add($cmd.Source) }
    }
    $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
    foreach ($path in $candidates) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    $null
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

Set-UiLanguage (Get-UiLanguage)
