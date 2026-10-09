# Builds the sparse MSIX for the Explorer menu into menu\bin and signs it.
# A sparse package holds only the manifest and logos; the DLL and stub live in its external location
# (%LOCALAPPDATA%\ClaudeCodeMenu), so they can be rebuilt without repackaging.
# Signs with the CN=ClaudeCodeMenu certificate in CurrentUser\My, creating it if missing, and exports
# its public part to bin\ClaudeCodeMenu.cer. Needs the Windows SDK (makeappx, signtool).
$ErrorActionPreference = 'Stop'
$MenuRoot = $PSScriptRoot
$bin = Join-Path $MenuRoot 'bin'
$msix = Join-Path $bin 'ClaudeCodeMenu.msix'
$cer = Join-Path $bin 'ClaudeCodeMenu.cer'
$subject = 'CN=ClaudeCodeMenu'

function Find-SdkTool([string]$Name) {
    $tool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -in 'x64', 'x86' } | Sort-Object { $_.Directory.Name -ne 'x64' }, FullName -Descending |
        Select-Object -First 1
    if (-not $tool) { throw "$Name not found; install the Windows SDK" }
    $tool.FullName
}

$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'
if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature -FriendlyName 'Claude Code Context Menu' `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(20) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Write-Host "created signing certificate $($cert.Thumbprint)"
}
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

# /nv: the manifest names an executable that is not inside the package (it is in the external location).
& $makeappx pack /o /nv /d (Join-Path $MenuRoot 'package') /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }
& $signtool sign /q /fd SHA256 /sha1 $cert.Thumbprint $msix
if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }
Write-Host "package: $msix (signed by $($cert.Thumbprint))"
