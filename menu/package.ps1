# Builds the sparse MSIX for the Explorer menu into menu\bin, unsigned. Only needed when the manifest or
# the logos change; the result is committed so installing needs no Windows SDK.
# A sparse package holds only the manifest and logos; the DLL and stub live in its external location
# (%LOCALAPPDATA%\ClaudeCodeMenu). menu\install.ps1 signs a copy with a certificate made on each PC.
# Needs the Windows SDK (makeappx).
$ErrorActionPreference = 'Stop'
$MenuRoot = $PSScriptRoot
$bin = Join-Path $MenuRoot 'bin'
$msix = Join-Path $bin 'ClaudeCodeMenu.msix'

$makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -in 'x64', 'x86' } | Sort-Object { $_.Directory.Name -ne 'x64' }, FullName -Descending |
    Select-Object -First 1
if (-not $makeappx) { throw 'makeappx.exe not found; install the Windows SDK' }
if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }

# /nv: the manifest names an executable that is not inside the package (it is in the external location).
& $makeappx.FullName pack /o /nv /d (Join-Path $MenuRoot 'package') /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }
Write-Host "package: $msix (unsigned)"
