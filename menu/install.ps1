# Installs or updates the "Abrir con Claude Code" entry of the Windows 11 Explorer menu:
#   1. builds the DLL and stub into menu\bin when missing (or with -Build), with build.cmd,
#   2. builds the signed sparse package when missing, with package.ps1,
#   3. copies the runtime files to %LOCALAPPDATA%\ClaudeCodeMenu, the package's external location,
#   4. registers the package if it is not registered yet (trusting its certificate takes one UAC prompt).
# Explorer is never restarted here: a newly registered entry appears after restarting Explorer or signing out.
param([switch]$Build)

$ErrorActionPreference = 'Stop'
$MenuRoot = $PSScriptRoot
$bin = Join-Path $MenuRoot 'bin'
$deploy = Join-Path $env:LOCALAPPDATA 'ClaudeCodeMenu'
$packageName = 'ClaudeCode.ContextMenu'

# The COM surrogate may have the DLL loaded. A loaded file can still be renamed, and the next surrogate
# loads the new copy; renamed copies are deleted on a later run once nothing holds them.
function Copy-RuntimeFile([string]$Source, [string]$Target) {
    Get-ChildItem -Path "$Target.old-*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Target) {
        if ((Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Target).Hash) { return 'unchanged' }
        try {
            Copy-Item -LiteralPath $Source -Destination $Target -Force
            return 'updated'
        } catch {
            Rename-Item -LiteralPath $Target -NewName ((Split-Path -Leaf $Target) + '.old-' + (Get-Date).ToString('yyyyMMddHHmmss'))
            Copy-Item -LiteralPath $Source -Destination $Target
            return 'updated (the copy in use was renamed)'
        }
    }
    Copy-Item -LiteralPath $Source -Destination $Target
    'installed'
}

$dll = Join-Path $bin 'ClaudeCodeMenu.dll'
$stub = Join-Path $bin 'ClaudeCodeMenuStub.exe'
if ($Build -or -not (Test-Path -LiteralPath $dll) -or -not (Test-Path -LiteralPath $stub)) {
    & cmd.exe /c ('"{0}"' -f (Join-Path $MenuRoot 'build.cmd'))
    if ($LASTEXITCODE -ne 0) { throw 'build.cmd failed' }
}

$assets = Join-Path $deploy 'Assets'
if (-not (Test-Path -LiteralPath $assets)) { New-Item -ItemType Directory -Force -Path $assets | Out-Null }
$files = [ordered]@{
    $dll  = Join-Path $deploy 'ClaudeCodeMenu.dll'
    $stub = Join-Path $deploy 'ClaudeCodeMenuStub.exe'
    (Join-Path $MenuRoot 'claude.ico') = Join-Path $assets 'claude.ico'
}
foreach ($logo in Get-ChildItem -LiteralPath (Join-Path $MenuRoot 'package\Assets')) { $files[$logo.FullName] = Join-Path $assets $logo.Name }
foreach ($source in $files.Keys) { Write-Host ('{0}: {1}' -f (Split-Path -Leaf $files[$source]), (Copy-RuntimeFile $source $files[$source])) }

if (Get-AppxPackage -Name $packageName) {
    Write-Host "package $packageName already registered"
    return
}

$msix = Join-Path $bin 'ClaudeCodeMenu.msix'
if (-not (Test-Path -LiteralPath $msix)) { & (Join-Path $MenuRoot 'package.ps1') }
$cer = Join-Path $bin 'ClaudeCodeMenu.cer'
$thumbprint = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer)).Thumbprint
if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $thumbprint)) {
    Write-Host 'Trusting the package certificate (accept the UAC prompt)...'
    $command = "Import-Certificate -FilePath '$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -Command $command"
    if ($p.ExitCode -ne 0) { throw 'could not trust the package certificate' }
}
Add-AppxPackage -Path $msix -ExternalLocation $deploy
Write-Host "package $packageName registered; restart Explorer or sign out to see the menu entry"
