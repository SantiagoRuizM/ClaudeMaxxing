# Installs or updates the "Abrir con Claude Code" entry of the Windows 11 Explorer menu from the prebuilt
# files in menu\bin, so it needs neither Visual Studio nor the Windows SDK:
#   1. copies the DLL, stub and icons to %LOCALAPPDATA%\ClaudeCodeMenu, the package's external location,
#   2. when the package is missing or older than package\AppxManifest.xml: creates this PC's signing
#      certificate if missing (CN=ClaudeCodeMenu in CurrentUser\My; its private key never leaves the PC),
#      trusts it (one UAC prompt), signs a temporary copy of bin\ClaudeCodeMenu.msix and registers it.
# -Build rebuilds the DLL and stub first (needs Visual Studio with the C++ tools).
# Explorer is never restarted here: a newly registered entry appears after restarting Explorer or signing out.
param([switch]$Build)

$ErrorActionPreference = 'Stop'
$MenuRoot = $PSScriptRoot
$bin = Join-Path $MenuRoot 'bin'
$deploy = Join-Path $env:LOCALAPPDATA 'ClaudeCodeMenu'
$packageName = 'ClaudeCode.ContextMenu'
$subject = 'CN=ClaudeCodeMenu'

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -ne 'AMD64') { throw "the menu DLL is built for x64 only (this PC is $arch)" }

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

# This PC's signing certificate, created on first use and trusted for packages (LocalMachine\TrustedPeople).
function Get-SigningCertificate {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature -FriendlyName 'Claude Code Context Menu' `
            -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(20) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
        Write-Host "created signing certificate $($cert.Thumbprint)"
    }
    if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cert.Thumbprint)) {
        $cer = Join-Path $env:TEMP "ClaudeCodeMenu-$($cert.Thumbprint).cer"
        Export-Certificate -Cert $cert -FilePath $cer | Out-Null
        Write-Host 'Trusting the package certificate (accept the UAC prompt)...'
        $command = "Import-Certificate -FilePath '$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
        $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -Command $command"
        Remove-Item -LiteralPath $cer -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) { throw 'could not trust the package certificate' }
    }
    $cert
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
# A ZIP downloaded from GitHub marks every file as coming from the internet.
Get-ChildItem -LiteralPath $deploy -Recurse -File | Unblock-File

$wanted = [version]([xml](Get-Content -LiteralPath (Join-Path $MenuRoot 'package\AppxManifest.xml') -Raw)).Package.Identity.Version
$registered = Get-AppxPackage -Name $packageName
if ($registered -and [version]$registered.Version -ge $wanted) {
    Write-Host "package $packageName $($registered.Version) already registered"
    return
}

$cert = Get-SigningCertificate
if (-not ('MsixSigner' -as [type])) { Add-Type -Path (Join-Path $MenuRoot 'src\MsixSigner.cs') }
$signed = Join-Path $env:TEMP ('ClaudeCodeMenu-{0}.msix' -f [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath (Join-Path $bin 'ClaudeCodeMenu.msix') -Destination $signed
try {
    [MsixSigner]::Sign($signed, $cert.Handle)
    Add-AppxPackage -Path $signed -ExternalLocation $deploy
} finally {
    Remove-Item -LiteralPath $signed -ErrorAction SilentlyContinue
}
$action = if ($registered) { "updated to $wanted" } else { 'registered; restart Explorer or sign out to see the menu entry' }
Write-Host "package $packageName $action"
