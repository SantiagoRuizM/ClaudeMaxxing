# Removes ClaudeMaxxing for the current user: the tray and its startup shortcut, the voice hotkeys, the
# "Abrir con Claude Code" Explorer entry (package, certificate and launcher), Otros PCs (its SSH server, firewall
# rules and ~/.ssh/config block; the rules go in the same UAC prompt as the menu certificate), scheduled sessions,
# the statusline block, the voice hooks if they were installed for every session, the Settings > Apps entry and
# the install folder. Usage data (~/.claude/usage-tray) and voice state (%TEMP%\claude-voice) are kept unless
# -RemoveData. -KeepMenu leaves the Explorer entry, which then opens plain Windows Terminal.
# Runs from the repo or from the install folder (Settings > Apps uses the installed copy).
param([string]$InstallDir, [switch]$KeepMenu, [switch]$RemoveData)

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'lib\common.ps1')
. (Join-Path $Here 'lib\schedule.ps1')
. (Join-Path $Here 'lib\statusline.ps1')
. (Join-Path $Here 'lib\installer.ps1')
. (Join-Path $Here 'lib\bridge.ps1')
. (Join-Path $Here 'lib\bridgeinstall.ps1')
if (-not $InstallDir) { $InstallDir = $DefaultInstallDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$stopped = Stop-RecordedTray
if ($stopped) { Write-Host "tray stopped (PID $stopped)" }
$stopped = Stop-RecordedWhisper
if ($stopped) { Write-Host "Claude Whisper stopped (PID $stopped)" }
foreach ($link in $TrayLink, $LegacyTrayLink) {
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link; Write-Host "removed $link" }
}

# Voice: hotkeys (listener and startup shortcut), and the hooks/rule/(voz) if voice\install.ps1 put them in ~/.claude.
$voiceDir = Join-Path $InstallDir 'voice'
if (-not (Test-Path -LiteralPath (Join-Path $voiceDir 'ctl.ps1'))) { $voiceDir = Join-Path $Here 'voice' }
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $voiceDir 'ctl.ps1') hotkeys off | ForEach-Object { Write-Host $_ }
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$claudeMd = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
$globalVoice = ((Test-Path -LiteralPath $settingsPath) -and ((Get-Content -LiteralPath $settingsPath -Raw) -match 'hooks[\\/]+(speak|on-prompt)\.ps1')) -or
    ((Test-Path -LiteralPath $claudeMd) -and ((Get-Content -LiteralPath $claudeMd -Raw) -match 'claudevoice:start'))
if ($globalVoice) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $voiceDir 'install.ps1') -Uninstall | ForEach-Object { Write-Host $_ }
}

# Otros PCs: the server stopped with the tray above; removing the firewall rules needs admin rights.
Write-Host (Uninstall-SshInclude)
$bridgeRules = @(Get-NetFirewallRule -Group $BridgeFirewallGroup -ErrorAction SilentlyContinue).Count
$rulesScript = if ($bridgeRules) { Get-BridgeFirewallRemovalScript } else { '' }

if ($KeepMenu) {
    if (Test-Path -LiteralPath $MenuKey) { Remove-ItemProperty -LiteralPath $MenuKey -Name Launcher -ErrorAction SilentlyContinue }
    Write-Host 'menu launcher removed (the Explorer entry opens plain Windows Terminal)'
    if ($rulesScript) { [void](Invoke-Elevated $rulesScript) }
} else {
    & (Join-Path $Here 'menu\uninstall.ps1') -AlsoElevated $rulesScript
}
if ($bridgeRules) {
    if (@(Get-NetFirewallRule -Group $BridgeFirewallGroup -ErrorAction SilentlyContinue).Count) {
        Write-Host "Otros PCs firewall rules kept (UAC declined): remove the '$BridgeFirewallGroup' group in Windows Defender Firewall"
    } else {
        Write-Host 'Otros PCs firewall rules removed'
    }
}

$removed = Remove-AllSessionTasks
Write-Host "scheduled sessions removed: $removed"

$statusline = Get-StatuslineScriptPath
if ($statusline) { Write-Host "statusline: $(Uninstall-StatuslineBlock $statusline)" }

if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse; Write-Host 'Settings > Apps entry removed' }

if ($RemoveData) {
    foreach ($dir in $TrayHome, (Join-Path $env:TEMP 'claude-voice')) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "removed $dir"
    }
} else {
    Write-Host "data kept in $TrayHome and $(Join-Path $env:TEMP 'claude-voice') (-RemoveData deletes them)"
}

# The install folder last. When this script runs from inside it, a detached cmd deletes it once we exit.
if (Test-Path -LiteralPath $InstallDir) {
    if ($Here.TrimEnd('\') -like "$InstallDir*") {
        Set-Location -LiteralPath $env:TEMP
        Start-Process -FilePath cmd.exe -WindowStyle Hidden -WorkingDirectory $env:TEMP `
            -ArgumentList ('/c ping -n 3 127.0.0.1 >nul & rmdir /s /q "{0}"' -f $InstallDir)
        Write-Host "$InstallDir will be deleted in a few seconds"
    } else {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) { Write-Host "some files in $InstallDir are in use; delete it after closing the open menu sessions" }
        else { Write-Host "removed $InstallDir" }
    }
}
Write-Host "$AppName uninstalled."
