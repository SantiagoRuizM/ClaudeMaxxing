# The window of an update (lib\update.ps1, Start-AppUpdate): runs the installed get.ps1 over this install, keeping
# what it was installed without. install.ps1 stops the tray, so a failed update starts it again.
param([Parameter(Mandatory = $true)][string]$InstallDir)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'installer.ps1')
. (Join-Path $PSScriptRoot 'update.ps1')

$startup = [Environment]::GetFolderPath('Startup')
$hasHotkeys = [bool](@('ClaudeMaxxing atajos.lnk', 'ClaudeVoice atajos.lnk') | Where-Object { Test-Path -LiteralPath (Join-Path $startup $_) })
$hasMenu = [bool](Get-ItemProperty -LiteralPath $MenuKey -Name Launcher -ErrorAction SilentlyContinue)
$options = Get-UpdateOptions $hasMenu $hasHotkeys (Read-JsonFile $InstallOptionsFile)

$failed = $false
try {
    & (Join-Path $InstallDir 'get.ps1') -InstallDir $InstallDir @options
} catch {
    $failed = $true
    Write-Host ''
    Write-Host ((L 'No se pudo actualizar: ') + $_.Exception.Message) -ForegroundColor Red
    $tray = Get-TrayLaunch $InstallDir
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'tray.ps1')) { Start-Process -FilePath $tray.File -ArgumentList $tray.Arguments -WorkingDirectory $InstallDir }
}
Write-Host ''
[void](Read-Host (L 'Pulsa Enter para cerrar'))
if ($failed) { exit 1 }
