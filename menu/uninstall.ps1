# Quita "Abrir con Claude Code" del menu contextual y el certificado asociado.
Get-AppxPackage ClaudeCode.ContextMenu | Remove-AppxPackage
Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq 'CN=ClaudeCodeMenu' | Remove-Item
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=ClaudeCodeMenu' | Remove-Item"
Stop-Process -Name explorer -Force
Start-Sleep -Seconds 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
Write-Host 'Menu de Claude Code eliminado.'
