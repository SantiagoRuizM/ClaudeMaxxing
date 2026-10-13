# "Otros PCs": terminals between PCs that both run ClaudeMaxxing, over SSH on the local network.
# Each PC runs its own sshd (the portable Win32-OpenSSH that install.ps1 puts in <install>\ssh) as the signed-in
# user, without a service or admin rights, so only that same user can log in, and only while the tray runs.
# Logins use keys exchanged when two PCs pair (lib\bridgenet.ps1); there are no passwords. Every key in
# authorized_keys is forced through the gate (lib\bridgegate.cs), which asks the tray on that PC to approve
# the connection before it runs anything. A firewall rule (Private networks, local subnet) keeps it on the LAN.
# Needs common.ps1. Keep this file ASCII.

$BridgeLibDir        = $PSScriptRoot
$BridgeSshPort       = 41022
$BridgeUdpPort       = 41021
$BridgeFirewallGroup = 'ClaudeMaxxing'
$BridgeAliasPrefix   = 'cmx-'
# Source addresses a paired key is accepted from (authorized_keys from=): private and link-local IPv4.
$BridgePrivateRanges = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16')
# How long the gate waits for someone to answer on this PC.
$BridgeApprovalSeconds = 60

# Win32-OpenSSH release that install.ps1 downloads; the hash pins the exact zip (GitHub shows the same digest).
$OpenSshRelease = @{
    Tag   = '10.0.0.0p2-Preview'
    AMD64 = @{ Url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip'
               Sha256 = '23F50F3458C4C5D0B12217C6A5DDFDE0137210A30FA870E98B29827F7B43ABA5' }
    ARM64 = @{ Url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64.zip'
               Sha256 = '698C6AEC31C1DD0FB996206E8741F4531A97355686B5431EF347D531B07FCD42' }
}

# Every path and port the bridge uses. Tests and the loopback check pass their own folder and ports, and a fixed
# ListenAddress; without one the server listens only on this PC's addresses in Private networks.
function New-BridgeContext([string]$DataDir = $BridgeHome, [string]$SshDir, [int]$SshPort = $BridgeSshPort,
        [int]$UdpPort = $BridgeUdpPort, [string]$ListenAddress = '', [switch]$AllowLoopback) {
    if (-not $SshDir) { $SshDir = Join-Path $DefaultInstallDir 'ssh' }
    @{
        Home = $DataDir; SshDir = $SshDir; SshPort = $SshPort; UdpPort = $UdpPort
        ListenAddress = $ListenAddress; AllowLoopback = [bool]$AllowLoopback
        IdentityFile = Join-Path $DataDir 'identity.json'
        PeersFile = Join-Path $DataDir 'peers.json'
        SettingsFile = Join-Path $DataDir 'settings.json'
        GrantsFile = Join-Path $DataDir 'grants.txt'
        ClientKey = Join-Path $DataDir 'keys\id_ed25519'
        HostKey = Join-Path $DataDir 'keys\host_ed25519'
        SshdConfig = Join-Path $DataDir 'sshd_config'
        AuthorizedKeys = Join-Path $DataDir 'authorized_keys'
        KnownHosts = Join-Path $DataDir 'known_hosts'
        SshConfig = Join-Path $DataDir 'ssh_config'
        GateConf = Join-Path $DataDir 'gate.conf'
        GateDir = Join-Path $DataDir 'bin'
        RequestsDir = Join-Path $DataDir 'requests'
        SessionsDir = Join-Path $DataDir 'sessions'
        PidFile = Join-Path $DataDir 'sshd.pid'
        SshdLog = Join-Path $DataDir 'sshd.log'
        Log = Join-Path $DataDir 'bridge.log'
    }
}

function Write-BridgeLog($Ctx, [string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $Ctx.Home)) { New-Item -ItemType Directory -Force -Path $Ctx.Home | Out-Null }
        if ((Test-Path -LiteralPath $Ctx.Log) -and (Get-Item -LiteralPath $Ctx.Log).Length -gt 512KB) {
            Move-Item -LiteralPath $Ctx.Log -Destination ($Ctx.Log + '.1') -Force
        }
        Add-Content -LiteralPath $Ctx.Log -Value ((Get-Date).ToString('s') + ' ' + $Message) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- pure helpers

function New-RandomHex([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buffer); $rng.Dispose()
    -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    $sha.Dispose()
    -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Test-BridgeId([string]$Id) { $Id -cmatch '^[0-9a-f]{12}$' }

# "ssh-ed25519 AAAA..." without the comment, or $null when it is not an ed25519 public key.
function Get-BridgeKeyText([string]$Line) {
    if (-not $Line) { return $null }
    $parts = $Line.Trim() -split '\s+'
    if ($parts.Count -lt 2 -or $parts[0] -cne 'ssh-ed25519' -or $parts[1] -cnotmatch '^AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$') { return $null }
    "$($parts[0]) $($parts[1])"
}

# A computer or user name as another PC sent it: letters, digits, space, dot, dash, underscore and apostrophe only.
# That keeps out anything ssh_config or a command line would read, and invisible or direction-changing Unicode
# characters that could make a name look like another one in the dialogs.
function Test-BridgeName([string]$Name, [int]$Max = 64) {
    $Name -and $Name.Length -le $Max -and $Name -cmatch "^[\p{L}\p{N}][\p{L}\p{N} ._'-]*$" -and $Name.Trim() -eq $Name
}

# Paths in sshd_config and ssh_config: forward slashes, % doubled (both expand %-tokens), quoted when needed.
function Format-SshPath([string]$Path) {
    $value = $Path.Replace('\', '/').Replace('%', '%%')
    if ($value -match '[\s#]') { return '"' + $value + '"' }
    $value
}

# Paths in ssh_config and its Include line, which two different ssh clients read: Windows' OpenSSH and Git's
# (MSYS, the one Claude Code's Bash tool runs). Git's takes "C:/..." in Include as relative to ~/.ssh, so paths
# under the user's profile are written as ~/..., which both expand to that same folder.
function Format-SshClientPath([string]$Path, [string]$UserHome = $env:USERPROFILE) {
    $prefix = $UserHome.TrimEnd('\') + '\'
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $value = '~/' + $Path.Substring($prefix.Length).Replace('\', '/').Replace('%', '%%')
        if ($value -match '[\s#]') { return '"' + $value + '"' }
        return $value
    }
    Format-SshPath $Path
}

# "Martin's PC" -> cmx-martin-s-pc; two paired PCs with the same name get the start of their id appended.
function Get-PeerAlias($Peer, $AllPeers) {
    $base = ([string]$Peer.name).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $base = $base.Trim('-')
    if (-not $base) { $base = 'pc' }
    $same = @($AllPeers | Where-Object { $_ -and $_.id -ne $Peer.id -and ((([string]$_.name).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) -eq $base })
    if ($same.Count) { $base += '-' + ([string]$Peer.id).Substring(0, 4) }
    $BridgeAliasPrefix + $base
}

function Get-HostKeyAlias([string]$PeerId) { "claudemaxxing-$PeerId" }

# sshd runs a key's command= through `cmd.exe /c "<command>"`. cmd keeps the quotes only when there are
# exactly two of them around an existing program with spaces in its path, so the gate command is one quoted
# path plus the peer id. Characters cmd treats as special inside the quotes would still break it.
function Test-CmdSafePath([string]$Path) { $Path -notmatch '[&<>()@^|%!"]' }

function Format-GateCommand([string]$GateExe, [string]$PeerId) {
    if (-not (Test-CmdSafePath $GateExe)) { throw "gate path has characters cmd.exe cannot pass: $GateExe" }
    if (-not (Test-BridgeId $PeerId)) { throw "bad peer id: $PeerId" }
    '"' + $GateExe + '" ' + $PeerId
}

# One authorized_keys line: no forwarding of any kind, a terminal allowed, LAN source addresses only, and
# whatever the client asks for goes through the gate (it finds it in SSH_ORIGINAL_COMMAND).
function Format-AuthorizedKeyLine([string]$GateExe, [string]$PeerId, [string]$ClientKey, [string[]]$From) {
    $key = Get-BridgeKeyText $ClientKey
    if (-not $key) { throw "not an ed25519 public key for $PeerId" }
    $command = (Format-GateCommand $GateExe $PeerId).Replace('"', '\"')
    'restrict,pty,from="{0}",command="{1}" {2} cmx-{3}' -f ($From -join ','), $command, $key, $PeerId
}

function Get-BridgeSourceRanges($Ctx) {
    $ranges = @($BridgePrivateRanges)
    if ($Ctx.AllowLoopback) { $ranges += '127.0.0.1' }
    $ranges
}

function Format-AuthorizedKeys($Ctx, $Peers, [string]$GateExe) {
    $lines = @('# Written by ClaudeMaxxing from the paired PCs; edits are overwritten.')
    foreach ($peer in @($Peers | Where-Object { $_ -and $_.clientKey })) {
        $lines += Format-AuthorizedKeyLine $GateExe $peer.id $peer.clientKey (Get-BridgeSourceRanges $Ctx)
    }
    ($lines -join "`n") + "`n"
}

function Format-SshdConfig($Ctx, [string]$SftpServer, [string[]]$Listen) {
    $lines = @(
        '# Written by the ClaudeMaxxing tray every time it starts this server; edits are overwritten.'
        "Port $($Ctx.SshPort)"
    ) + @($Listen | ForEach-Object { "ListenAddress $_" }) + @(
        'AddressFamily inet'
        "HostKey $(Format-SshPath $Ctx.HostKey)"
        "AuthorizedKeysFile $(Format-SshPath $Ctx.AuthorizedKeys)"
        'PidFile none'
        'StrictModes yes'
        'AuthenticationMethods publickey'
        'PubkeyAuthentication yes'
        'PasswordAuthentication no'
        'KbdInteractiveAuthentication no'
        'HostbasedAuthentication no'
        'MaxSessions 4'
        'DisableForwarding yes'
        'PermitTunnel no'
        'PermitUserEnvironment no'
        'LoginGraceTime 20'
        'MaxAuthTries 3'
        'ClientAliveInterval 30'
        'ClientAliveCountMax 4'
        "Subsystem sftp $(Format-SshPath $SftpServer)"
        'LogLevel INFO'
    )
    ($lines -join "`n") + "`n"
}

# The client side: one Host per paired PC. The host key is pinned under an alias, so the address can follow
# the PC around the network (it comes from unauthenticated beacons) without ever trusting a new key.
function Format-SshClientConfig($Ctx, $Peers) {
    $lines = @('# Written by ClaudeMaxxing ("Otros PCs") when paired PCs change; edits are overwritten.')
    $all = @($Peers | Where-Object { $_ -and $_.hostKey -and $_.address })
    foreach ($peer in $all) {
        $user = [string]$peer.user
        if ($user -match '\s') { $user = '"' + $user + '"' }
        $lines += ''
        $lines += "Host $(Get-PeerAlias $peer $all)"
        $lines += "    HostName $($peer.address)"
        $lines += "    Port $($peer.port)"
        $lines += "    User $user"
        $lines += "    HostKeyAlias $(Get-HostKeyAlias $peer.id)"
        $lines += "    UserKnownHostsFile $(Format-SshClientPath $Ctx.KnownHosts)"
        $lines += '    StrictHostKeyChecking yes'
        $lines += '    CheckHostIP no'
        $lines += "    IdentityFile $(Format-SshClientPath $Ctx.ClientKey)"
        $lines += '    IdentitiesOnly yes'
        $lines += '    PasswordAuthentication no'
        $lines += '    KbdInteractiveAuthentication no'
        # The user's own "Host *" settings come later and only fill what is not set here: nothing of this PC
        # (agent, X display, local ports) is handed to the other PC, and it cannot rewrite the pinned key.
        $lines += '    ForwardAgent no'
        $lines += '    ForwardX11 no'
        $lines += '    ClearAllForwardings yes'
        $lines += '    ProxyCommand none'
        $lines += '    ProxyJump none'
        $lines += '    PermitLocalCommand no'
        $lines += '    UpdateHostKeys no'
        $lines += '    ServerAliveInterval 30'
    }
    ($lines -join "`n") + "`n"
}

function Format-KnownHosts($Peers) {
    $lines = @($Peers | Where-Object { $_ -and (Get-BridgeKeyText $_.hostKey) } | ForEach-Object { "$(Get-HostKeyAlias $_.id) $(Get-BridgeKeyText $_.hostKey)" })
    ($lines -join "`n") + "`n"
}

# What the gate reads (key=value; it has no JSON parser).
function Format-GateConf([string]$SftpServer, [string]$Name, [int]$TimeoutSeconds = $BridgeApprovalSeconds) {
    (@("sftp=$SftpServer", 'shell=powershell.exe -NoLogo', "timeout=$TimeoutSeconds", "name=$Name") -join "`n") + "`n"
}

# grants.txt: "<peer id> <unix seconds>" per line; the gate lets that PC in without asking until then.
# A grant never lasts more than an hour; a longer one was not written by the tray and is dropped.
$BridgeGrantSeconds = 3600
function ConvertFrom-GrantsText([string]$Text, [long]$NowUnix) {
    $grants = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ne 2 -or -not (Test-BridgeId $parts[0])) { continue }
        $until = 0L
        if ([long]::TryParse($parts[1], [ref]$until) -and $until -gt $NowUnix -and $until -le $NowUnix + $BridgeGrantSeconds + 60) { $grants[$parts[0]] = $until }
    }
    $grants
}

function Format-GrantsText($Grants) {
    (($Grants.Keys | Sort-Object | ForEach-Object { "$_ $($Grants[$_])" }) -join "`n") + "`n"
}

# A command as the dialog shows it: line breaks and control or invisible characters made visible, runs of spaces
# collapsed (they could push the dangerous part out of view), and the length when it does not fit. The remote
# text never goes through Tx.
function Format-CommandPreview([string]$Command, [int]$Max = 150) {
    $text = $Command -replace "`r?`n", (' [salto de l' + (Tx '\u00ed') + 'nea] ')
    $text = [regex]::Replace($text, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '[?]')
    $text = ($text -replace '\s{2,}', ' ').Trim()
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) + " ... (+$($text.Length - $Max) caracteres)" }
    $text
}

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ~/.ssh/config: an Include of the generated ssh_config, first in the file so its Host entries apply before
# any of the user's own (ssh keeps the first value it reads). Marked so uninstall removes exactly this.
$SshIncludeStart = '# >>> ClaudeMaxxing (Otros PCs; uninstall removes this block)'
$SshIncludeEnd   = '# <<< ClaudeMaxxing'

function Add-SshIncludeBlock([string]$Text, [string]$IncludePath) {
    $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    $block = $SshIncludeStart + $nl + 'Include ' + (Format-SshClientPath $IncludePath) + $nl + $SshIncludeEnd + $nl
    $rest = Remove-SshIncludeBlock $Text
    if ($rest) { return $block + $nl + $rest }
    $block
}

function Remove-SshIncludeBlock([string]$Text) {
    if (-not $Text) { return '' }
    $pattern = '(?s)' + [regex]::Escape($SshIncludeStart) + '.*?' + [regex]::Escape($SshIncludeEnd) + '\r?\n?(\r?\n)?'
    [regex]::Replace($Text, $pattern, '')
}

# Directed broadcast of an IPv4 address with the given prefix length (192.168.1.23/24 -> 192.168.1.255).
function Get-BroadcastAddress([string]$Address, [int]$PrefixLength) {
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, $PrefixLength - 8 * $i))
        $hostMask = (0xFF -shr $bits) -band 0xFF
        $bytes[$i] = $bytes[$i] -bor $hostMask
    }
    ([System.Net.IPAddress]$bytes).ToString()
}

function Test-PrivateAddress([string]$Address) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { return $false }
    $b = $ip.GetAddressBytes()
    ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254)
}

# ---------------------------------------------------------------- identity, keys and paired PCs

function Get-BridgeIdentity($Ctx) {
    $identity = Read-JsonFile $Ctx.IdentityFile
    if (-not $identity -or -not (Test-BridgeId $identity.id)) {
        $identity = [pscustomobject]@{ id = (New-RandomHex 6) }
        Write-JsonFile $Ctx.IdentityFile $identity
    }
    [pscustomobject]@{ id = [string]$identity.id; name = $env:COMPUTERNAME; user = $env:USERNAME; port = $Ctx.SshPort }
}

# This PC's client key (to log in elsewhere) and host key (what others pin), created on first use.
function Initialize-BridgeKeys($Ctx) {
    $keygen = Join-Path $Ctx.SshDir 'ssh-keygen.exe'
    foreach ($key in @(@{ Path = $Ctx.ClientKey; Comment = "ClaudeMaxxing $env:COMPUTERNAME" }, @{ Path = $Ctx.HostKey; Comment = "ClaudeMaxxing host $env:COMPUTERNAME" })) {
        if ((Test-Path -LiteralPath $key.Path) -and (Test-Path -LiteralPath ($key.Path + '.pub'))) { continue }
        $dir = Split-Path -Parent $key.Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        foreach ($stale in $key.Path, ($key.Path + '.pub')) { if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force } }
        $out = & $keygen -q -t ed25519 -N '""' -f $key.Path -C $key.Comment 2>&1
        if (-not (Test-Path -LiteralPath ($key.Path + '.pub'))) { throw "ssh-keygen failed: $out" }
    }
    [pscustomobject]@{
        clientKey = Get-BridgeKeyText ([IO.File]::ReadAllText($Ctx.ClientKey + '.pub'))
        hostKey = Get-BridgeKeyText ([IO.File]::ReadAllText($Ctx.HostKey + '.pub'))
    }
}

function Read-BridgePeers($Ctx) { @(Read-JsonFile $Ctx.PeersFile | Where-Object { $_ -and (Test-BridgeId $_.id) }) }

function Write-BridgePeers($Ctx, $Peers) { Write-JsonFile $Ctx.PeersFile @($Peers | Where-Object { $_ }) }

function Read-BridgeSettings($Ctx) {
    $saved = Read-JsonFile $Ctx.SettingsFile
    $settings = [ordered]@{ acceptIncoming = $true; noticed = @() }
    if ($saved) {
        if ($null -ne $saved.acceptIncoming) { $settings.acceptIncoming = [bool]$saved.acceptIncoming }
        if ($saved.noticed) { $settings.noticed = @($saved.noticed | Where-Object { Test-BridgeId $_ }) }
    }
    $settings
}

function Read-BridgeGrants($Ctx) {
    $text = if (Test-Path -LiteralPath $Ctx.GrantsFile) { [IO.File]::ReadAllText($Ctx.GrantsFile) } else { '' }
    ConvertFrom-GrantsText $text (Get-UnixNow)
}

function Set-BridgeGrant($Ctx, [string]$PeerId, [long]$UntilUnix) {
    $grants = Read-BridgeGrants $Ctx
    if ($UntilUnix -gt 0) { $grants[$PeerId] = $UntilUnix } else { $grants.Remove($PeerId) }
    Write-BridgeText $Ctx.GrantsFile (Format-GrantsText $grants)
}

function Write-BridgeText([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- gate

# The gate is compiled once per source version into <bridge>\bin; it finds the bridge folder from there.
function Import-BridgeGate($Ctx) {
    $source = Join-Path $BridgeLibDir 'bridgegate.cs'
    $text = [IO.File]::ReadAllText($source)
    $hash = (Get-Sha256Hex $text).Substring(0, 12)
    $exe = Join-Path $Ctx.GateDir "cmx-gate-$hash.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        if (-not (Test-Path -LiteralPath $Ctx.GateDir)) { New-Item -ItemType Directory -Force -Path $Ctx.GateDir | Out-Null }
        $tmp = Join-Path $Ctx.GateDir "cmx-gate-$hash-$PID.exe"
        Add-Type -TypeDefinition $text -OutputAssembly $tmp -OutputType ConsoleApplication
        try { Move-Item -LiteralPath $tmp -Destination $exe -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        # Older gates may still run open sessions; they go on a later start.
        Get-ChildItem -LiteralPath $Ctx.GateDir -Filter 'cmx-gate-*.exe' | Where-Object { $_.FullName -ne $exe } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    if (-not (Test-CmdSafePath $exe)) {
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile($exe).ShortPath
        if (Test-CmdSafePath $short) { return $short }
    }
    $exe
}

# Rewrites everything the server and the ssh client read from the paired PCs (sshd_config is written when the
# server starts, with the addresses it listens on).
function Update-BridgeFiles($Ctx, [string]$GateExe) {
    $peers = Read-BridgePeers $Ctx
    $sftp = Join-Path $Ctx.SshDir 'sftp-server.exe'
    foreach ($dir in $Ctx.RequestsDir, $Ctx.SessionsDir) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
    if ($GateExe) {
        Write-BridgeText $Ctx.AuthorizedKeys (Format-AuthorizedKeys $Ctx $peers $GateExe)
        Write-BridgeText $Ctx.GateConf (Format-GateConf $sftp $env:COMPUTERNAME)
    }
    Write-BridgeText $Ctx.SshConfig (Format-SshClientConfig $Ctx $peers)
    Write-BridgeText $Ctx.KnownHosts (Format-KnownHosts $peers)
}

# The files sshd and the gate trust, compared with what the tray would write now. A connection that was allowed
# runs with this user's rights and could add a key without the gate to authorized_keys, or point the gate at
# another shell; the tray checks every few seconds and puts them back. Returns the names that differ.
function Get-BridgeTampered($Ctx, [string]$GateExe, [string]$SshdText) {
    $peers = Read-BridgePeers $Ctx
    $expected = [ordered]@{
        authorized_keys = Format-AuthorizedKeys $Ctx $peers $GateExe
        'gate.conf'     = Format-GateConf (Join-Path $Ctx.SshDir 'sftp-server.exe') $env:COMPUTERNAME
    }
    if ($SshdText) { $expected['sshd_config'] = $SshdText }
    $paths = @{ authorized_keys = $Ctx.AuthorizedKeys; 'gate.conf' = $Ctx.GateConf; sshd_config = $Ctx.SshdConfig }
    $changed = @()
    foreach ($name in $expected.Keys) {
        $actual = if (Test-Path -LiteralPath $paths[$name]) { [IO.File]::ReadAllText($paths[$name]) } else { $null }
        if ($actual -ne $expected[$name]) { $changed += $name }
    }
    $changed
}

# ---------------------------------------------------------------- server process

function Get-BridgeServerProcess($Ctx) {
    if (-not (Test-Path -LiteralPath $Ctx.PidFile)) { return $null }
    $serverPid = 0
    [void][int]::TryParse(([IO.File]::ReadAllText($Ctx.PidFile)).Trim(), [ref]$serverPid)
    if ($serverPid -le 0) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
    # Only the sshd started with this context's config, never another process that reused the PID.
    if (-not $proc -or $proc.Name -ne 'sshd.exe' -or $proc.CommandLine -notlike "*$($Ctx.SshdConfig)*") { return $null }
    $proc
}

function Stop-BridgeServer($Ctx) {
    $proc = Get-BridgeServerProcess $Ctx
    Remove-Item -LiteralPath $Ctx.PidFile -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    # /T: the per-connection sshd-session processes and the sessions they run go too.
    & taskkill.exe /PID $proc.ProcessId /T /F 2>&1 | Out-Null
    $proc.ProcessId
}

# $Listen: the addresses to listen on (this PC's in Private networks); the context's fixed one wins.
function Start-BridgeServer($Ctx, [string]$GateExe, [string[]]$Listen) {
    $sshd = Join-Path $Ctx.SshDir 'sshd.exe'
    if (-not (Test-Path -LiteralPath $sshd)) { throw "OpenSSH is not installed ($sshd)" }
    if ($Ctx.ListenAddress) { $Listen = @($Ctx.ListenAddress) }
    $Listen = @($Listen | Where-Object { $_ })
    if (-not $Listen.Count) { throw 'no Private network address to listen on' }
    [void](Stop-BridgeServer $Ctx)
    Update-BridgeFiles $Ctx $GateExe
    Write-BridgeText $Ctx.SshdConfig (Format-SshdConfig $Ctx (Join-Path $Ctx.SshDir 'sftp-server.exe') $Listen)
    if ((Test-Path -LiteralPath $Ctx.SshdLog) -and (Get-Item -LiteralPath $Ctx.SshdLog).Length -gt 1MB) {
        Move-Item -LiteralPath $Ctx.SshdLog -Destination ($Ctx.SshdLog + '.1') -Force
    }
    $arguments = '-D -f "{0}" -E "{1}"' -f $Ctx.SshdConfig, $Ctx.SshdLog
    $proc = Start-Process -FilePath $sshd -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Write-BridgeText $Ctx.PidFile ([string]$proc.Id)
    Write-BridgeLog $Ctx "sshd started (PID $($proc.Id), $($Listen -join ', ') port $($Ctx.SshPort))"
    $proc
}

# Last lines of the server log, to tell the user why it stopped (port taken, bad key permissions...).
function Get-BridgeServerError($Ctx) {
    if (-not (Test-Path -LiteralPath $Ctx.SshdLog)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($Ctx.SshdLog, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object System.IO.StreamReader($fs)
        $lines = @($reader.ReadToEnd() -split "`r?`n" | Where-Object { $_ })
        $reader.Dispose()
        ($lines | Select-Object -Last 1)
    } catch { '' }
}

# ---------------------------------------------------------------- firewall

$BridgePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Both rules exist, are on, and let in the given sshd and this PowerShell (reading them needs no admin).
function Test-BridgeFirewall([string]$SshdPath) {
    $rules = @(Get-NetFirewallRule -Group $BridgeFirewallGroup -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
    if ($rules.Count -lt 2) { return $false }
    if (-not $SshdPath) { return $true }
    $programs = @($rules | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | ForEach-Object { $_.Program })
    ($programs -contains $SshdPath) -and ($programs -contains $BridgePowerShell)
}

# Commands for an elevated PowerShell: inbound rules for the SSH server (TCP) and discovery (UDP), Private
# networks only and from the local subnet only, so nothing outside the LAN or on public Wi-Fi gets through.
function Get-BridgeFirewallScript([string]$SshdPath) {
    $q = { param($s) "'" + $s.Replace("'", "''") + "'" }
    @(
        "Remove-NetFirewallRule -Group $(& $q $BridgeFirewallGroup) -ErrorAction SilentlyContinue"
        "New-NetFirewallRule -DisplayName 'ClaudeMaxxing - SSH entre PCs (TCP $BridgeSshPort)' -Group $(& $q $BridgeFirewallGroup) -Direction Inbound -Action Allow -Protocol TCP -LocalPort $BridgeSshPort -Program $(& $q $SshdPath) -Profile Private -RemoteAddress LocalSubnet | Out-Null"
        "New-NetFirewallRule -DisplayName 'ClaudeMaxxing - encontrar PCs (UDP $BridgeUdpPort)' -Group $(& $q $BridgeFirewallGroup) -Direction Inbound -Action Allow -Protocol UDP -LocalPort $BridgeUdpPort -Program $(& $q $BridgePowerShell) -Profile Private -RemoteAddress LocalSubnet | Out-Null"
    ) -join "`n"
}

# Runs PowerShell commands elevated (one UAC prompt). Returns $true when they ran and succeeded.
function Invoke-Elevated([string]$Script) {
    $wrapped = "`$ErrorActionPreference = 'Stop'`ntry {`n$Script`n} catch { exit 1 }`nexit 0"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
    try {
        $p = Start-Process -FilePath $BridgePowerShell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        return ($p.ExitCode -eq 0)
    } catch {
        # The user declined the UAC prompt.
        return $false
    }
}

function Set-BridgeFirewall([string]$SshdPath) {
    if (Test-BridgeFirewall $SshdPath) { return 'up to date' }
    if (Invoke-Elevated (Get-BridgeFirewallScript $SshdPath)) { return 'created' }
    throw 'the firewall rules were not created (UAC prompt declined?)'
}

function Get-BridgeFirewallRemovalScript { "Remove-NetFirewallRule -Group '$BridgeFirewallGroup' -ErrorAction SilentlyContinue" }

# ---------------------------------------------------------------- network

# IPv4 addresses on networks Windows marks Private, with their broadcast address and network name.
function Get-BridgeNetworks {
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { [string]$_.NetworkCategory -eq 'Private' })
    $result = @()
    if (-not $profiles.Count) { return $result }
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $props = $nic.GetIPProperties()
        try { $index = $props.GetIPv4Properties().Index } catch { continue }
        $match = $profiles | Where-Object { $_.InterfaceIndex -eq $index } | Select-Object -First 1
        if (-not $match) { continue }
        foreach ($unicast in $props.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -ne 'InterNetwork') { continue }
            $address = $unicast.Address.ToString()
            $result += [pscustomobject]@{
                Name = [string]$match.Name; Address = $address; Prefix = $unicast.PrefixLength
                Broadcast = Get-BroadcastAddress $address $unicast.PrefixLength
            }
        }
    }
    $result
}
