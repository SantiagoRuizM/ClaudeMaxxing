# Removes ClaudeTray: stops the tray, deletes the startup shortcut and scheduled sessions,
# and removes the statusline block. Data in ~/.claude/usage-tray is kept.

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
. (Join-Path $TrayRoot 'lib\statusline.ps1')

# Stop only the tray process recorded in tray.pid, after checking it really is tray.ps1.
if (Test-Path -LiteralPath $TrayPidFile) {
    $trayPid = [int](Get-Content -LiteralPath $TrayPidFile -Raw)
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $trayPid" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -like '*tray.ps1*') {
        Stop-Process -Id $trayPid -Force
        Write-Host "tray stopped (PID $trayPid)"
    }
    Remove-Item -LiteralPath $TrayPidFile -ErrorAction SilentlyContinue
}

$link = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeTray.lnk'
if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link; Write-Host 'startup shortcut removed' }

Remove-AllSessionTasks
Write-Host 'scheduled sessions removed'

$script = Get-StatuslineScriptPath
if ($script) { Write-Host "statusline: $(Uninstall-StatuslineBlock $script)" }

Write-Host "data kept in $TrayHome"
