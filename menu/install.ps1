# Instala "Abrir con Claude Code" en el menu contextual de Windows 11.
# 1) Confia en el certificado autofirmado (pide UAC una vez).
# 2) Registra el paquete sparse para el usuario actual.
# 3) Reinicia el Explorador para que cargue el menu.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=ClaudeCodeMenu'
if (-not $trusted) {
    Write-Host 'Confiando en el certificado (acepta el aviso de UAC)...'
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -Command Import-Certificate -FilePath '$dir\ClaudeCodeMenu.cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    if ($p.ExitCode -ne 0) { throw 'No se pudo importar el certificado.' }
}

Get-AppxPackage ClaudeCode.ContextMenu | Remove-AppxPackage
Add-AppxPackage -Path "$dir\ClaudeCodeMenu.msix" -ExternalLocation $dir

Stop-Process -Name explorer -Force
Start-Sleep -Seconds 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }

Write-Host 'Listo: clic derecho en una carpeta -> "Abrir con Claude Code".'
