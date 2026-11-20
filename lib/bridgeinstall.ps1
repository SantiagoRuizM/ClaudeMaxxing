# Install and uninstall pieces of "Otros PCs" (lib\bridge.ps1): the portable OpenSSH in <install>\ssh and the
# Include block in ~/.ssh/config. The firewall rules are in bridge.ps1, because the tray can create them too.
# Needs common.ps1 and bridge.ps1.

function Get-BridgeArchitecture { if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }

# Downloads the pinned Win32-OpenSSH zip, checks its SHA-256 and that every program in it is signed by
# Microsoft, and keeps only the programs, DLLs and licenses in <install>\ssh. Skipped when that version is
# already there. The server must not be running (install.ps1 stops the tray and its sshd first).
function Install-BridgeOpenSsh([string]$InstallDir) {
    $arch = Get-BridgeArchitecture
    $package = $OpenSshRelease[$arch]
    if (-not $package) { throw "no OpenSSH package for $arch" }
    $target = Join-Path $InstallDir 'ssh'
    $marker = Join-Path $target 'VERSION.txt'
    $wanted = "$($OpenSshRelease.Tag) $arch"
    if ((Test-Path -LiteralPath (Join-Path $target 'sshd.exe')) -and (Test-Path -LiteralPath $marker) -and
        ([IO.File]::ReadAllText($marker).Trim() -eq $wanted)) {
        return "OpenSSH $($OpenSshRelease.Tag) already in $target"
    }

    $work = Join-Path $env:TEMP ('ClaudeMaxxing-openssh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $savedProgress = $ProgressPreference
    try {
        $zip = Join-Path $work 'openssh.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # The progress bar makes Invoke-WebRequest many times slower on Windows PowerShell.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $package.Url -OutFile $zip
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $package.Sha256) { throw "the downloaded OpenSSH zip does not match the pinned hash ($hash)" }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x') -Force
        $root = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | Select-Object -First 1
        $files = @(Get-ChildItem -LiteralPath $root.FullName -File | Where-Object { $_.Extension -in '.exe', '.dll' -or $_.Name -in 'LICENSE.txt', 'NOTICE.txt' })
        foreach ($file in $files) {
            Unblock-File -LiteralPath $file.FullName
            if ($file.Extension -notin '.exe', '.dll') { continue }
            $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw "$($file.Name) in the OpenSSH zip is not signed by Microsoft ($($sig.Status))"
            }
        }
        if (-not ($files | Where-Object Name -eq 'sshd.exe')) { throw 'the OpenSSH zip has no sshd.exe' }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination $target }
        [IO.File]::WriteAllText($marker, $wanted)
        "OpenSSH $($OpenSshRelease.Tag) installed in $target"
    } finally {
        $ProgressPreference = $savedProgress
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$UserSshConfig = Join-Path $env:USERPROFILE '.ssh\config'

# Puts the Include of the generated ssh_config at the top of ~/.ssh/config, so `ssh cmx-<pc>` works from any
# terminal and from Claude Code. Written without a BOM (ssh would read it as part of the first line).
function Install-SshInclude($Ctx) {
    if (-not (Test-Path -LiteralPath $Ctx.SshConfig)) { Write-BridgeText $Ctx.SshConfig (Format-SshClientConfig $Ctx @()) }
    $text = if (Test-Path -LiteralPath $UserSshConfig) { [IO.File]::ReadAllText($UserSshConfig) } else { '' }
    $updated = Add-SshIncludeBlock $text $Ctx.SshConfig
    if ($updated -eq $text) { return "~/.ssh/config already includes $($Ctx.SshConfig)" }
    if ($text -and -not (Test-Path -LiteralPath "$UserSshConfig.claudemaxxing.bak")) { Copy-Item -LiteralPath $UserSshConfig -Destination "$UserSshConfig.claudemaxxing.bak" }
    Write-BridgeText $UserSshConfig $updated
    "~/.ssh/config includes $($Ctx.SshConfig)"
}

function Uninstall-SshInclude {
    if (-not (Test-Path -LiteralPath $UserSshConfig)) { return 'no ~/.ssh/config' }
    $text = [IO.File]::ReadAllText($UserSshConfig)
    $updated = Remove-SshIncludeBlock $text
    if ($updated -eq $text) { return '~/.ssh/config has no ClaudeMaxxing block' }
    if ($updated.Trim()) { Write-BridgeText $UserSshConfig $updated } else { Remove-Item -LiteralPath $UserSshConfig }
    'ClaudeMaxxing block removed from ~/.ssh/config'
}
