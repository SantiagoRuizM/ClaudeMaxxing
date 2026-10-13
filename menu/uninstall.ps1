# Removes the "Abrir con Claude Code" Explorer menu entry: unregisters the package, deletes the launcher
# setting and the deployed files, and removes the signing certificate (one UAC prompt for the machine store).
# Explorer is not restarted; the entry disappears after restarting Explorer or signing out.
# -AlsoElevated: more PowerShell commands to run in that same elevated prompt (uninstall.ps1 passes the
# removal of the Otros PCs firewall rules), so uninstalling asks only once.
param([string]$AlsoElevated)
$deploy = Join-Path $env:LOCALAPPDATA 'ClaudeCodeMenu'

Get-AppxPackage -Name 'ClaudeCode.ContextMenu' | Remove-AppxPackage
Remove-Item -LiteralPath 'HKCU:\Software\ClaudeCodeMenu' -Recurse -ErrorAction SilentlyContinue
# The DLL may still be loaded by the COM surrogate; if so the folder stays and can be deleted after signing out.
Remove-Item -LiteralPath $deploy -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $deploy) { Write-Host "some files are in use; delete $deploy after signing out" }

Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq 'CN=ClaudeCodeMenu' | Remove-Item
$elevated = "Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=ClaudeCodeMenu' | Remove-Item"
if ($AlsoElevated) { $elevated += "`n" + $AlsoElevated }
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevated))
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -EncodedCommand $encoded"
Write-Host 'Explorer menu entry removed (restart Explorer or sign out to refresh the menu).'
