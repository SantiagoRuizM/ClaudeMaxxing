# ClaudeMaxxing in one command, from any PowerShell window (nothing to install first):
#   irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1 | iex
# With install.ps1's options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1))) -SkipBridge
# It downloads the newest release (or the branch -Ref names; main when there is no release yet), checks the ZIP
# against the release's SHA256SUMS.txt, unzips it to a temporary folder, runs its install.ps1 and deletes the
# folder: everything runs from %LOCALAPPDATA%\ClaudeMaxxing afterwards. Run it again to update. Keep this file ASCII.
param(
    [string]$Ref,
    [string]$InstallDir,
    [switch]$NoStart,
    [switch]$SkipMenu,
    [switch]$SkipVoiceDeps,
    [switch]$NoHotkeys,
    [switch]$SkipBridge
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows downloads down in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = 'SantiagoRuizM/ClaudeMaxxing'
$headers = @{ 'User-Agent' = 'ClaudeMaxxing-get' }

$expected = $null
if (-not $Ref) {
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
        $asset = @($release.assets | Where-Object { $_.name -like 'ClaudeMaxxing-*.zip' })[0]
        if (-not $asset) { throw "release $($release.tag_name) has no ZIP" }
        $url = $asset.browser_download_url
        $sums = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })[0]
        if ($sums) {
            $line = @(([string](Invoke-RestMethod $sums.browser_download_url -Headers $headers)) -split "`n" | Where-Object { $_ -match [regex]::Escape($asset.name) })[0]
            if ($line) { $expected = ($line.Trim() -split '\s+')[0].ToUpperInvariant() }
        }
        Write-Host "ClaudeMaxxing $($release.tag_name)"
    } catch {
        Write-Host "No release to download ($($_.Exception.Message)); installing the main branch."
        $Ref = 'main'
    }
}
if ($Ref) { $url = "https://github.com/$repo/archive/refs/heads/$Ref.zip" }

$work = Join-Path ([IO.Path]::GetTempPath()) ('claudemaxxing-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $zip = Join-Path $work 'claudemaxxing.zip'
    Write-Host "Downloading $url"
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing -Headers $headers
    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "The download does not match the release's SHA-256 ($actual, expected $expected): not installed." }
        Write-Host 'SHA-256 checked.'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
    $installer = @(Get-ChildItem -LiteralPath $work -Directory | ForEach-Object { Join-Path $_.FullName 'install.ps1' } | Where-Object { Test-Path -LiteralPath $_ })[0]
    if (-not $installer) { throw 'The download has no install.ps1.' }
    $options = @()
    if ($InstallDir) { $options += @('-InstallDir', $InstallDir) }
    foreach ($name in 'NoStart', 'SkipMenu', 'SkipVoiceDeps', 'NoHotkeys', 'SkipBridge') {
        if ((Get-Variable $name -ValueOnly).IsPresent) { $options += "-$name" }
    }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $installer @options
    if ($LASTEXITCODE) { throw "install.ps1 ended with code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
