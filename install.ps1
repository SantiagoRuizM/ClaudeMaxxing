# Installs ClaudeMaxxing for the current user. The repo is only the installer: everything that runs is copied
# to the install folder (default %LOCALAPPDATA%\ClaudeMaxxing), so the repo can be moved or deleted afterwards.
# Run it again (from any copy of the repo) to update; it is idempotent.
#   1. checks claude, Windows Terminal and the Windows version,
#   2. stops the tray left running by a previous install,
#   3. copies the runtime (tray, menu launcher, voice) to the install folder,
#   4. adds the snapshot block to the Claude Code statusline script (backup kept),
#   5. installs or updates the "Abrir con Claude Code" Explorer menu (menu\install.ps1; the first time, one
#      UAC prompt to trust this PC's signing certificate) and points it at the installed open-session.ps1,
#   6. voice: /voz for menu sessions, edge-tts and ffplay (winget and pip, unless -SkipVoiceDeps) and the
#      global hotkeys (unless -NoHotkeys),
#   7. Otros PCs (unless -SkipBridge): the pinned, Microsoft-signed portable OpenSSH in <install>\ssh, the
#      Include in ~/.ssh/config, and the firewall rules (Private networks, local subnet; one UAC prompt the
#      first time),
#   8. startup shortcut, an entry in Settings > Apps (its uninstall runs the installed uninstall.ps1), and
#      starts the tray.
param(
    [string]$InstallDir,
    [switch]$NoStart,
    [switch]$SkipMenu,
    [switch]$BuildMenu,
    [switch]$SkipVoiceDeps,
    [switch]$NoHotkeys,
    [switch]$SkipBridge
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $RepoRoot 'lib\common.ps1')
. (Join-Path $RepoRoot 'lib\statusline.ps1')
. (Join-Path $RepoRoot 'lib\schedule.ps1')
. (Join-Path $RepoRoot 'lib\installer.ps1')
. (Join-Path $RepoRoot 'lib\bridge.ps1')
. (Join-Path $RepoRoot 'lib\bridgeinstall.ps1')
if (-not $InstallDir) { $InstallDir = $DefaultInstallDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($InstallDir -eq $RepoRoot.TrimEnd('\')) { throw 'The install folder cannot be the repo itself.' }
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$warnings = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Add-Warning([string]$Text) { $warnings.Add($Text); Write-Warning $Text }

# ---------------------------------------------------------------- 1. requirements
Write-Step "$AppName $AppVersion -> $InstallDir"
if (-not (Test-Path -LiteralPath $TrayHome)) { New-Item -ItemType Directory -Force -Path $TrayHome | Out-Null }

# The first claude on PATH may be a stale shim, so each candidate is run.
$candidates = @()
foreach ($name in 'claude.cmd', 'claude.exe') {
    $candidates += @(Get-Command $name -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
}
$candidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
$claude = $null
foreach ($path in ($candidates | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try {
        $version = & $path --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) { $claude = @{ Path = $path; Version = ([string]$version).Trim() }; break }
    } catch { }
}
if ($claude) {
    Write-JsonFile $ConfigFile @{ claudePath = $claude.Path }
    Write-Host "claude: $($claude.Path) ($($claude.Version))"
} else {
    Add-Warning 'Claude Code (claude) not found on PATH: install it and run install.ps1 again. Menu sessions and scheduled sessions need it.'
}
if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Add-Warning 'Windows Terminal (wt.exe) not found: menu sessions open in a plain console, without half-screen placement or tab colors.'
}
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Add-Warning 'This is not Windows 11 (untested): the "Abrir con Claude Code" entry may not show, or only under "Show more options".'
}

# ---------------------------------------------------------------- 2. previous install
Write-Step 'Stopping the running tray'
$stopped = Stop-RecordedTray
if ($stopped) { Write-Host "tray stopped (PID $stopped)" } else { Write-Host 'no tray running' }
$stopped = Stop-RecordedWhisper
if ($stopped) { Write-Host "Claude Whisper stopped (PID $stopped)" }

# ---------------------------------------------------------------- 3. runtime files
Write-Step 'Copying the runtime'
$count = Sync-Runtime $RepoRoot $InstallDir
Write-Host "$count files in $InstallDir"
# Tray icons: taken from the installed Claude app (not redistributed here); without it the tray uses a stock icon.
$assets = Join-Path $InstallDir 'assets'
$claudeApp = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claudeApp) {
    if (-not (Test-Path -LiteralPath $assets)) { New-Item -ItemType Directory -Force -Path $assets | Out-Null }
    foreach ($icon in 'Tray-Win32.ico', 'Tray-Win32-Dark.ico') {
        $src = Join-Path $claudeApp.InstallLocation "app\resources\$icon"
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $assets -Force }
    }
}

# ---------------------------------------------------------------- 4. statusline
Write-Step 'Statusline'
$statusline = Get-StatuslineScriptPath
if ($statusline) {
    Write-Host "statusline: $(Install-StatuslineBlock $statusline) ($statusline)"
    $gitJq = Get-Command git.exe -ErrorAction SilentlyContinue | ForEach-Object { Join-Path (Split-Path (Split-Path $_.Source)) 'usr\bin\jq.exe' }
    if (-not (Get-Command jq -ErrorAction SilentlyContinue) -and -not ($gitJq -and (Test-Path -LiteralPath $gitJq))) {
        Add-Warning 'jq not found: the statusline block needs it to save usage (winget install jqlang.jq). Until then the tray only updates when it asks the usage endpoint (on start, when opened, and with its refresh button).'
    }
} else {
    Add-Warning 'No bash statusline script in ~/.claude/settings.json, so Claude Code does not report usage to the tray on every response. The tray still asks the usage endpoint on start, when opened and with its refresh button.'
}

# ---------------------------------------------------------------- 5. Explorer menu
Write-Step 'Explorer menu (Abrir con Claude Code)'
if ($SkipMenu) {
    Write-Host 'skipped (-SkipMenu)'
} else {
    try {
        & (Join-Path $RepoRoot 'menu\install.ps1') -Build:$BuildMenu
    } catch {
        Add-Warning "Explorer menu not installed or updated: $($_.Exception.Message)"
    }
    # The menu DLL runs this command, with %1 replaced by the quoted folder; without it, it opens plain wt.exe.
    $launcher = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Dir %1' -f $powershell, (Join-Path $InstallDir 'open-session.ps1')
    if (-not (Test-Path -LiteralPath $MenuKey)) { New-Item -Path $MenuKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $MenuKey -Name Launcher -Value $launcher
    Write-Host "menu launcher: $launcher"
}

# ---------------------------------------------------------------- 6. voice
Write-Step 'Voice'
$voiceDir = Join-Path $InstallDir 'voice'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ctl = Join-Path $voiceDir 'ctl.ps1'
# /voz for menu sessions: the plugin's skill, with the installed ctl.ps1.
$skill = [IO.File]::ReadAllText((Join-Path $voiceDir 'templates\skill-voz.md'), $utf8NoBom).Replace('{{CTL}}', ($ctl -replace '\\', '/'))
$skillDir = Join-Path $voiceDir 'plugin\skills\voz'
if (-not (Test-Path -LiteralPath $skillDir)) { New-Item -ItemType Directory -Force -Path $skillDir | Out-Null }
[IO.File]::WriteAllText((Join-Path $skillDir 'SKILL.md'), $skill, $utf8NoBom)
Write-Host "/voz: $skillDir"

if ($SkipVoiceDeps) {
    Write-Host 'voice dependencies skipped (-SkipVoiceDeps)'
} else {
    foreach ($note in (Install-VoiceDependencies $voiceDir)) { if ($note.Warn) { Add-Warning $note.Text } else { Write-Host $note.Text } }
}

if (-not $NoHotkeys) {
    # In its own process: ctl.ps1 loads voice\hooks\common.ps1, whose names clash with lib\common.ps1.
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $ctl hotkeys on | ForEach-Object { Write-Host $_ }
}

# ---------------------------------------------------------------- 7. Otros PCs
Write-Step 'Otros PCs (terminals between PCs over SSH)'
if ($SkipBridge) {
    Write-Host 'skipped (-SkipBridge)'
} else {
    try {
        Write-Host (Install-BridgeOpenSsh $InstallDir)
        $bridgeCtx = New-BridgeContext -SshDir (Join-Path $InstallDir 'ssh')
        Write-Host (Install-SshInclude $bridgeCtx)
        Write-Host 'firewall rules (Private networks, local subnet; accept the UAC prompt if one appears)...'
        Write-Host "firewall: $(Set-BridgeFirewall (Join-Path $InstallDir 'ssh\sshd.exe'))"
    } catch {
        Add-Warning "Otros PCs is not fully set up: $($_.Exception.Message). Run install.ps1 again to finish it (the firewall rules can also be created from the tray, in Otros PCs...)."
    }
}

# ---------------------------------------------------------------- 8. startup, Settings > Apps, start
Write-Step 'Startup and Settings > Apps'
$tray = Get-TrayLaunch $InstallDir
New-Shortcut $TrayLink $tray.File $tray.Arguments $InstallDir "$AppName - Claude usage in the notification area"
Write-Host "startup shortcut: $TrayLink"
if (Test-Path -LiteralPath $LegacyTrayLink) { Remove-Item -LiteralPath $LegacyTrayLink; Write-Host "old startup shortcut removed: $LegacyTrayLink" }
$legacyTasks = Remove-AllSessionTasks -LegacyOnly
if ($legacyTasks) { Add-Warning "$legacyTasks scheduled session(s) from the old ClaudeTray folder were removed; schedule them again from the tray." }
Register-AppEntry $InstallDir
Write-Host "Settings > Apps: $AppName"

if (-not $NoStart) {
    Start-Process -FilePath $tray.File -ArgumentList $tray.Arguments -WorkingDirectory $InstallDir
    Write-Host 'tray started'
}

Write-Host ''
if ($warnings.Count) {
    Write-Host "Installed with $($warnings.Count) warning(s):" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host " - $w" -ForegroundColor Yellow }
} else {
    Write-Host 'Installed.' -ForegroundColor Green
}
Write-Host "Everything runs from $InstallDir; this repo is no longer needed (run install.ps1 again from a newer copy to update)."
if (-not $NoStart) {
    Write-Host 'Next: find the Claude icon in the notification area (it may be under the ^ arrow with the hidden icons).'
    Write-Host '  Left-click shows your usage; "Entrar a ClaudeMaxxing" opens the window with every tool.'
}
Write-Host 'Menu sessions that were already open keep the previous paths until you close and reopen them.'
