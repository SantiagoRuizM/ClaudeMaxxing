# "Otros PCs" in the tray: runs this PC's side of lib\bridge.ps1 (its SSH server, beacons, pairing, the approval
# dialog for incoming connections, session notices) and draws the Otros PCs window.
#   - The server runs only with at least one paired PC, "Acepta conexiones" on and the firewall rules present.
#   - Pairing is accepted only while the Otros PCs window is open on this PC.
#   - Every connection a paired PC opens waits in requests\ until someone here answers the approval dialog,
#     unless that PC was allowed for an hour (grants.txt).
# Needs bridge.ps1, bridgenet.ps1, theme.ps1 and the tray's $script:Notify. Keep this file ASCII.

$script:Bridge = $null
$script:BridgeDialog = $null
$script:ApprovalForm = $null
$script:BridgeBalloonAction = $null
$script:BridgeCodeFont = New-UiFont 'Segoe UI Semibold' 22
$BridgeSeenSeconds = 120

# ---------------------------------------------------------------- state and lifecycle

function New-BridgeState([string]$SshDir) {
    @{
        Ctx = (New-BridgeContext -SshDir $SshDir); SshdPath = (Join-Path $SshDir 'sshd.exe')
        Ready = $false; Problem = ''; Detail = ''
        Identity = $null; Keys = $null; Gate = $null; Udp = $null; FirewallOk = $false; FirewallJob = $null; FirewallState = ''
        Server = $null; ServerListen = ''; ServerStarts = @(); Peers = @(); Settings = $null
        Discovered = @{}; Networks = @(); NetworksAt = [datetime]::MinValue
        Pairing = $null; PairingMode = $false; PairingModeAt = [datetime]::MinValue; UdpAddress = ''
        ProbeReplies = @{}; NoticeShownAt = [datetime]::MinValue; AddressSavedAt = @{}
        Requests = [ordered]@{}; Sessions = @{}; NoticeAt = @{}
        LastBeacon = [datetime]::MinValue; LastSlow = [datetime]::MinValue; Busy = $false; Dirty = $false
    }
}

# Called once, from the first timer tick (the tray icon is already up): keys, gate, firewall check, socket, server.
function Initialize-BridgeTray([string]$SshDir) {
    $b = New-BridgeState $SshDir
    $script:Bridge = $b
    if (-not (Test-Path -LiteralPath $b.SshdPath)) { $b.Problem = 'openssh'; return }
    try {
        $b.Identity = Get-BridgeIdentity $b.Ctx
        $b.Keys = Initialize-BridgeKeys $b.Ctx
        $b.Gate = Import-BridgeGate $b.Ctx
    } catch {
        $b.Problem = 'error'; $b.Detail = $_.Exception.Message
        Write-BridgeLog $b.Ctx "init failed: $($b.Detail)"
        return
    }
    $b.Settings = Read-BridgeSettings $b.Ctx
    $b.Peers = @(Read-BridgePeers $b.Ctx)
    [void](Stop-BridgeServer $b.Ctx)
    Clear-BridgeLeftovers
    Update-BridgeFiles $b.Ctx $b.Gate
    $b.Ready = $true
    $b.Networks = @(Get-BridgeNetworks); $b.NetworksAt = Get-Date
    $b.FirewallOk = Test-BridgeFirewall $b.SshdPath
    Update-BridgeNetwork
    Update-BridgeServer
    Send-BridgeHello -Probe
}

function Stop-BridgeTray {
    $b = $script:Bridge
    if (-not $b) { return }
    if ($b.Udp) { try { $b.Udp.Close() } catch { } ; $b.Udp = $null }
    if ($b.Ready) { [void](Stop-BridgeServer $b.Ctx) }
}

# The discovery socket is open only with the firewall rules present and at least one Private network. Otherwise
# nothing listens: on a Public network, or without the rules, Windows would ask to allow PowerShell or sshd,
# and both answers are bad (Allow opens it on public Wi-Fi; dismissing leaves block rules behind).
function Update-BridgeNetwork {
    $b = $script:Bridge
    $address = @(Get-BridgeListen) | Select-Object -First 1
    if ($b.Udp -and (-not $b.FirewallOk -or $b.UdpAddress -ne $address)) {
        $b.Udp.Close(); $b.Udp = $null; $b.UdpAddress = ''
    }
    if (-not $b.FirewallOk -or -not $address -or $b.Udp) { return }
    try {
        $b.Udp = Open-BridgeSocket $b.Ctx.UdpPort $address
        $b.UdpAddress = $address
    } catch { Write-BridgeLog $b.Ctx "UDP $address`:$($b.Ctx.UdpPort) not available: $($_.Exception.Message)" }
}

# This PC's addresses in Private networks: the only ones the server listens on.
function Get-BridgeListen {
    $b = $script:Bridge
    if ($b.Ctx.ListenAddress) { return @($b.Ctx.ListenAddress) }
    @($b.Networks | ForEach-Object { $_.Address } | Select-Object -Unique)
}

function Update-BridgeServer {
    $b = $script:Bridge
    if (-not $b.Ready) { return }
    $listen = @(Get-BridgeListen)
    $want = $b.FirewallOk -and $b.Settings.acceptIncoming -and $listen.Count -gt 0 -and @($b.Peers | Where-Object { $_.clientKey }).Count -gt 0
    $running = $b.Server -and -not $b.Server.HasExited
    # A new address (another network, a new DHCP lease): restart on the new one.
    if ($want -and $running -and $b.ServerListen -ne ($listen -join ',')) {
        [void](Stop-BridgeServer $b.Ctx)
        $b.Server = $null
        $running = $false
    }
    if ($want -and -not $running) {
        $recent = @($b.ServerStarts | Where-Object { $_ -gt (Get-Date).AddMinutes(-5) })
        if ($recent.Count -ge 3) {
            if ($b.Problem -ne 'server') {
                $b.Problem = 'server'; $b.Detail = Get-BridgeServerError $b.Ctx
                Show-BridgeBalloon ((Tx 'El servidor de Otros PCs se detuvo: ') + $b.Detail) 'dialog'
            }
            return
        }
        try {
            $b.Server = Start-BridgeServer $b.Ctx $b.Gate $listen
            $b.ServerListen = $listen -join ','
            $b.ServerStarts = $recent + @(Get-Date)
            if ($b.Problem -eq 'server') { $b.Problem = '' }
        } catch {
            $b.Problem = 'server'; $b.Detail = $_.Exception.Message
        }
        $b.Dirty = $true
    } elseif (-not $want -and ($running -or (Test-Path -LiteralPath $b.Ctx.PidFile))) {
        [void](Stop-BridgeServer $b.Ctx)
        $b.Server = $null
        $b.Dirty = $true
    }
}

function Test-GateProcess([int]$GatePid) {
    $proc = Get-Process -Id $GatePid -ErrorAction SilentlyContinue
    $proc -and $proc.ProcessName -like 'cmx-gate*'
}

# Requests and session records whose gate is gone (killed, or left from a crash).
function Clear-BridgeLeftovers {
    $b = $script:Bridge
    foreach ($dir in $b.Ctx.RequestsDir, $b.Ctx.SessionsDir) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($file in [IO.Directory]::GetFiles($dir, '*.json')) {
            $record = Read-JsonFile $file
            if ($record -and $record.pid -and (Test-GateProcess ([int]$record.pid))) { continue }
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($file -replace '\.json$', '.answer') -ErrorAction SilentlyContinue
        }
    }
}

function Save-BridgePeers {
    $b = $script:Bridge
    Write-BridgePeers $b.Ctx $b.Peers
    Update-BridgeFiles $b.Ctx $b.Gate
    Update-BridgeServer
    $b.Dirty = $true
}

function Find-BridgePeer([string]$Id) { $script:Bridge.Peers | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Save-BridgeSettings {
    $b = $script:Bridge
    Write-JsonFile $b.Ctx.SettingsFile $b.Settings
}

# ---------------------------------------------------------------- beacons and messages

function Test-BridgeSource([string]$Address) {
    (Test-PrivateAddress $Address) -or ($script:Bridge.Ctx.AllowLoopback -and $Address -eq '127.0.0.1')
}

function Get-BridgeHello {
    $b = $script:Bridge
    @{ t = 'hello'; id = $b.Identity.id; name = $b.Identity.name; user = $b.Identity.user; port = $b.Ctx.SshPort; pairing = [bool](Test-PairingOpen) }
}

# A hello (and a probe, which makes the others answer at once) to every private network and to every paired PC.
function Send-BridgeHello([switch]$Probe, [string]$To, [int]$Port) {
    $b = $script:Bridge
    if (-not $b.Udp -or -not $b.Identity) { return }
    if (-not $Port) { $Port = $b.Ctx.UdpPort }
    if ($To) {
        $targets = @($To)
    } else {
        if (-not $b.Networks.Count) { return }
        $targets = @($b.Networks | ForEach-Object { $_.Broadcast }) + @($b.Peers | Where-Object { $_.address } | ForEach-Object { $_.address })
        $targets = @($targets | Select-Object -Unique)
    }
    foreach ($target in $targets) {
        Send-BridgeDatagram $b.Udp (Get-BridgeHello) $target $Port
        if ($Probe) { Send-BridgeDatagram $b.Udp @{ t = 'probe'; id = $b.Identity.id } $target $Port }
    }
    if (-not $To) { $b.LastBeacon = Get-Date }
}

function Receive-BridgeMessages {
    $b = $script:Bridge
    foreach ($d in @(Receive-BridgeDatagrams $b.Udp)) {
        $m = $d.Message
        if (-not (Test-BridgeSource $d.Address)) { continue }
        switch ([string]$m.t) {
            'probe' {
                # At most one answer per address every 2 s: a forged source address cannot turn this PC into a
                # stream of datagrams aimed at someone else.
                $last = $b.ProbeReplies[$d.Address]
                if ($m.id -ne $b.Identity.id -and (-not $last -or ((Get-Date) - $last).TotalSeconds -ge 2)) {
                    if ($b.ProbeReplies.Count -gt 256) { $b.ProbeReplies.Clear() }
                    $b.ProbeReplies[$d.Address] = Get-Date
                    Send-BridgeHello -To $d.Address -Port $d.Port
                }
            }
            'hello' { if ($m.id -ne $b.Identity.id) { Register-BridgeHello $m $d.Address $d.Port } }
            'pair1' { Receive-PairRequest $m $d.Address $d.Port }
            default {
                $pairing = $b.Pairing
                # Only from the PC this pairing is with (the session id alone travels in clear on the network).
                if (-not $pairing -or [string]$m.sid -ne $pairing.Sid -or $d.Address -ne $pairing.Address) { continue }
                Step-Pairing $pairing $m
                Send-PairingOut
                if ($pairing.Stage -eq 'done') { Complete-BridgePairing }
                $b.Dirty = $true
            }
        }
    }
}

# Beacons are not authenticated, so anyone on the network can send them, with any id: the list is capped,
# a paired PC's address is saved at most every 30 s, and the "new PC" notice shows at most once a minute.
$BridgeMaxDiscovered = 32
function Register-BridgeHello($Msg, [string]$Address, [int]$Port) {
    $b = $script:Bridge
    $id = [string]$Msg.id
    $peer = Find-BridgePeer $id
    if (-not $b.Discovered.ContainsKey($id) -and $b.Discovered.Count -ge $BridgeMaxDiscovered) {
        if (-not $peer) { return }
        $oldest = @($b.Discovered.Values | Sort-Object seen | Select-Object -First 1)[0]
        $b.Discovered.Remove($oldest.id)
    }
    $b.Discovered[$id] = [pscustomobject]@{
        id = $id; name = [string]$Msg.name; user = [string]$Msg.user; port = [int]$Msg.port
        address = $Address; udpPort = $Port; pairing = [bool]$Msg.pairing; seen = (Get-Date)
    }
    if ($peer) {
        # Safe to follow: the host key stays pinned, so a forged beacon can only make connecting fail.
        $savedAt = $b.AddressSavedAt[$id]
        if ($peer.address -ne $Address -and (-not $savedAt -or ((Get-Date) - $savedAt).TotalSeconds -ge 30)) {
            $b.AddressSavedAt[$id] = Get-Date
            $peer.address = $Address
            Save-BridgePeers
        }
    } elseif ($b.Settings.noticed -notcontains $id -and ((Get-Date) - $b.NoticeShownAt).TotalSeconds -ge 60) {
        $b.NoticeShownAt = Get-Date
        $b.Settings.noticed = @(@($b.Settings.noticed) + $id | Select-Object -Last 100)
        Save-BridgeSettings
        if (-not $script:BridgeDialog) {
            Show-BridgeBalloon ((Tx 'ClaudeMaxxing est\u00e1 en ') + [string]$Msg.name + (Tx '. Haz clic para emparejar.')) 'dialog'
        }
    }
    $b.Dirty = $true
}

# ---------------------------------------------------------------- pairing

function Send-PairingOut {
    $pairing = $script:Bridge.Pairing
    if (-not $pairing -or -not $pairing.Out) { return }
    Send-BridgeDatagram $script:Bridge.Udp $pairing.Out $pairing.Address $pairing.Port
    $pairing.LastSent = Get-Date
}

function Get-BridgeSelfInfo { Get-BridgeInfo $script:Bridge.Identity $script:Bridge.Keys }

function Test-PairingActive { $script:Bridge.Pairing -and $script:Bridge.Pairing.Stage -notin 'done', 'failed', 'cancelled' }

function Start-BridgePairing([string]$Id) {
    $b = $script:Bridge
    $target = $b.Discovered[$Id]
    if (-not $target -or (Test-PairingActive)) { return }
    $b.Pairing = New-PairInitiator (Get-BridgeSelfInfo) $target.address $target.udpPort
    $b.Pairing.TargetId = $Id
    $b.Pairing.TargetName = $target.name
    Send-PairingOut
    $b.Dirty = $true
}

# pair1 from another PC: answered only while the Otros PCs window is open here, and only during its first
# $BridgePairingWindowMinutes minutes (a window left open is not an open door).
$BridgePairingWindowMinutes = 10
function Test-PairingOpen {
    $b = $script:Bridge
    $b.PairingMode -and ((Get-Date) - $b.PairingModeAt).TotalMinutes -lt $BridgePairingWindowMinutes
}

function Receive-PairRequest($Msg, [string]$Address, [int]$Port) {
    $b = $script:Bridge
    if (-not (Test-PairingOpen) -or $Msg.from.id -eq $b.Identity.id) { return }
    $current = $b.Pairing
    if (Test-PairingActive) {
        if ($current.Role -eq 'responder' -and $current.Sid -eq [string]$Msg.sid) { Step-Pairing $current $Msg; Send-PairingOut; return }
        # Both users clicked Emparejar on each other at once: the PC with the higher id gives way.
        $crossed = $current.Role -eq 'initiator' -and $current.Stage -eq 'asking' -and $current.TargetId -eq [string]$Msg.from.id
        if (-not ($crossed -and [string]::CompareOrdinal($b.Identity.id, [string]$Msg.from.id) -gt 0)) { return }
    }
    $b.Pairing = New-PairResponder (Get-BridgeSelfInfo) $Msg $Address $Port
    $b.Pairing.TargetId = [string]$Msg.from.id
    $b.Pairing.TargetName = [string]$Msg.from.name
    Send-PairingOut
    $b.Dirty = $true
}

function Update-PairingProgress {
    $b = $script:Bridge
    $pairing = $b.Pairing
    if (-not (Test-PairingActive)) { return }
    if (((Get-Date) - $pairing.Started).TotalSeconds -gt $PairingTimeoutSeconds) {
        $pairing.Stage = 'failed'; $pairing.Error = 'timeout'; $b.Dirty = $true
        return
    }
    if (((Get-Date) - $pairing.LastSent).TotalSeconds -ge 1) {
        $retry = Get-PairingRetry $pairing
        if ($retry) { $pairing.Out = $retry; Send-PairingOut }
    }
}

function Confirm-BridgePairing {
    $pairing = $script:Bridge.Pairing
    if (-not $pairing) { return }
    Confirm-Pairing $pairing
    Send-PairingOut
    if ($pairing.Stage -eq 'done') { Complete-BridgePairing }
    $script:Bridge.Dirty = $true
}

function Stop-BridgePairing {
    $pairing = $script:Bridge.Pairing
    if (-not $pairing) { return }
    if (Test-PairingActive) { Stop-Pairing $pairing; Send-PairingOut }
    $script:Bridge.Pairing = $null
    $script:Bridge.Dirty = $true
}

function Complete-BridgePairing {
    $b = $script:Bridge
    $pairing = $b.Pairing
    if ($pairing.Saved) { return }
    $pairing.Saved = $true
    $record = New-PeerRecord $pairing
    $b.Peers = @($b.Peers | Where-Object { $_.id -ne $record.id }) + $record
    Save-BridgePeers
    Write-BridgeLog $b.Ctx "paired with $($record.name) ($($record.id)) at $($record.address)"
}

# ---------------------------------------------------------------- incoming connections

# Request and session records are named <32 hex>.json by the gate; anything else in those folders is ignored
# (their ids end up inside menu and button actions).
function Test-RecordId([string]$Id) { $Id -cmatch '^[0-9a-f]{32}$' }

function Update-BridgeRequests {
    $b = $script:Bridge
    $dir = $b.Ctx.RequestsDir
    $present = @{}
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in [IO.Directory]::GetFiles($dir, '*.json')) {
            $id = [IO.Path]::GetFileNameWithoutExtension($file)
            if (Test-RecordId $id) { $present[$id] = $file }
        }
    }
    foreach ($id in @($b.Requests.Keys)) { if (-not $present.ContainsKey($id)) { $b.Requests.Remove($id) } }
    foreach ($id in $present.Keys) {
        if ($b.Requests.Contains($id) -or (Test-Path -LiteralPath ($present[$id] -replace '\.json$', '.answer'))) { continue }
        $record = Read-JsonFile $present[$id]
        if (-not $record) { continue }
        $peer = Find-BridgePeer ([string]$record.peer)
        if (-not $peer) {
            Write-AnswerFile ($present[$id] -replace '\.json$', '.answer') 'deny'
            continue
        }
        $b.Requests[$id] = [pscustomobject]@{
            Id = $id; Peer = $peer; Kind = [string]$record.kind; Command = [string]$record.command
            Client = [string]$record.client; Seen = (Get-Date)
        }
        if (-not $script:ApprovalForm) { [System.Media.SystemSounds]::Asterisk.Play() }
    }
    if ($b.Requests.Count -and -not $script:ApprovalForm) { Show-ApprovalForm }
    elseif ($script:ApprovalForm) {
        if (-not $b.Requests.Count) { $script:ApprovalForm.Close() } else { $script:ApprovalForm.Invalidate() }
    }
}

# The request the approval dialog shows: the oldest one waiting. Each is answered on its own, so nothing is
# allowed without being seen.
function Get-ApprovalRequest { @($script:Bridge.Requests.Values) | Select-Object -First 1 }

# The gate polls for the file: write it whole under another name, then rename, so it never reads it half-written.
function Write-AnswerFile([string]$Path, [string]$Answer) {
    try {
        [IO.File]::WriteAllText("$Path.tmp", $Answer)
        Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
    } catch { Remove-Item -LiteralPath "$Path.tmp" -ErrorAction SilentlyContinue }
}

# Answers one request. -ForAnHour also lets that PC in without asking for an hour, which includes the requests
# of that PC already waiting (the dialog says so).
function Send-BridgeAnswer([string]$RequestId, [string]$Answer, [switch]$ForAnHour) {
    $b = $script:Bridge
    if (-not $b.Requests.Contains($RequestId)) { return }
    $request = $b.Requests[$RequestId]
    $answered = @($request)
    if ($ForAnHour) {
        Set-BridgeGrant $b.Ctx $request.Peer.id ((Get-UnixNow) + $BridgeGrantSeconds)
        $answered = @($b.Requests.Values | Where-Object { $_.Peer.id -eq $request.Peer.id })
    }
    foreach ($item in $answered) {
        Write-AnswerFile (Join-Path $b.Ctx.RequestsDir "$($item.Id).answer") $Answer
        $b.Requests.Remove($item.Id)
    }
    Write-BridgeLog $b.Ctx ("answered {0}{1} to {2}: {3} [{4}]" -f $Answer, $(if ($ForAnHour) { ' (1 hour)' } else { '' }), $request.Peer.name, $request.Kind, $request.Command)
    $b.Dirty = $true
}

function Get-SessionLabel($Session) {
    switch ($Session.Kind) {
        'shell' { return 'terminal' }
        'sftp'  { return 'archivos (SFTP)' }
        default { if ($Session.Command.Trim() -ceq 'claude') { return 'Claude Code' } else { return 'comandos' } }
    }
}

function Update-BridgeSessions {
    $b = $script:Bridge
    $dir = $b.Ctx.SessionsDir
    $present = @{}
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in [IO.Directory]::GetFiles($dir, '*.json')) {
            $id = [IO.Path]::GetFileNameWithoutExtension($file)
            if (Test-RecordId $id) { $present[$id] = $file }
        }
    }
    foreach ($id in @($b.Sessions.Keys)) {
        if ($present.ContainsKey($id)) { continue }
        $session = $b.Sessions[$id]
        $b.Sessions.Remove($id)
        if ($session.Kind -eq 'shell' -or $session.Command.Trim() -ceq 'claude') {
            Show-BridgeBalloon ($session.PeerName + (Tx ' cerr\u00f3 su ') + (Get-SessionLabel $session) + ' en este PC.') 'dialog'
        }
        $b.Dirty = $true
    }
    foreach ($id in $present.Keys) {
        if ($b.Sessions.ContainsKey($id)) { continue }
        $record = Read-JsonFile $present[$id]
        if (-not $record) { continue }
        $peer = Find-BridgePeer ([string]$record.peer)
        $session = [pscustomobject]@{
            Id = $id; PeerId = [string]$record.peer; PeerName = $(if ($peer) { $peer.name } else { [string]$record.peer })
            Kind = [string]$record.kind; Command = [string]$record.command; Pid = [int]$record.pid; Started = (Get-Date)
        }
        $b.Sessions[$id] = $session
        # Commands from Claude Code come one connection each: one notice per PC every 10 minutes is enough.
        $interactive = $session.Kind -eq 'shell' -or $session.Command.Trim() -ceq 'claude'
        $last = $b.NoticeAt[$session.PeerId]
        if ($interactive -or -not $last -or ((Get-Date) - $last).TotalMinutes -ge 10) {
            $b.NoticeAt[$session.PeerId] = Get-Date
            $verb = if ($interactive) { Tx ' abri\u00f3 ' } else { Tx ' est\u00e1 usando este PC: ' }
            $text = if ($interactive) { $session.PeerName + $verb + (Get-SessionLabel $session) + ' en este PC.' } else { $session.PeerName + $verb + (Get-SessionLabel $session) + '.' }
            Show-BridgeBalloon $text 'dialog'
        }
        $b.Dirty = $true
    }
}

# Ends one incoming session: its gate and everything under it (only a gate process, checked by name).
function Stop-BridgeSession([string]$Id) {
    $session = $script:Bridge.Sessions[$Id]
    if (-not $session -or -not (Test-GateProcess $session.Pid)) { return }
    & taskkill.exe /PID $session.Pid /T /F 2>&1 | Out-Null
    Remove-Item -LiteralPath (Join-Path $script:Bridge.Ctx.SessionsDir "$Id.json") -ErrorAction SilentlyContinue
}

function Remove-BridgePeer([string]$Id) {
    $b = $script:Bridge
    foreach ($session in @($b.Sessions.Values | Where-Object { $_.PeerId -eq $Id })) { Stop-BridgeSession $session.Id }
    Set-BridgeGrant $b.Ctx $Id 0
    $b.Peers = @($b.Peers | Where-Object { $_.id -ne $Id })
    Save-BridgePeers
}

# An allowed session runs as this user and could add a key that skips the gate, or point the gate somewhere
# else: what sshd and the gate read on every connection is put back as soon as it differs, and the user is told.
function Repair-BridgeTampering {
    $b = $script:Bridge
    if (-not $b.Ready -or -not $b.Gate) { return }
    $changed = @(Get-BridgeTampered $b.Ctx $b.Gate)
    if (-not $changed.Count) { return }
    Update-BridgeFiles $b.Ctx $b.Gate
    Write-BridgeLog $b.Ctx "restored after an outside change: $($changed -join ', ')"
    Show-BridgeBalloon ((Tx 'Algo cambi\u00f3 la configuraci\u00f3n de Otros PCs (') + ($changed -join ', ') + (Tx '); se restaur\u00f3.')) 'dialog'
}

function Set-BridgeAccept([bool]$On) {
    $b = $script:Bridge
    $b.Settings.acceptIncoming = $On
    Save-BridgeSettings
    if (-not $On) { foreach ($session in @($b.Sessions.Values)) { Stop-BridgeSession $session.Id } }
    Update-BridgeServer
    $b.Dirty = $true
}

# "Permitir...": the UAC prompt runs in its own process; Complete-BridgeFirewall picks up the result.
function Repair-BridgeFirewall {
    $b = $script:Bridge
    if ($b.FirewallJob) { return }
    if (Test-BridgeFirewall $b.SshdPath) { Complete-BridgeFirewall; return }
    $b.FirewallJob = Start-Elevated (Get-BridgeFirewallScript $b.SshdPath)
    $b.FirewallState = if ($b.FirewallJob) { 'waiting' } else { 'declined' }
    if (-not $b.FirewallJob) { Write-BridgeLog $b.Ctx 'firewall: UAC prompt declined' }
    $b.Dirty = $true
}

function Complete-BridgeFirewall {
    $b = $script:Bridge
    if ($b.FirewallJob) {
        $ok = $b.FirewallJob.ExitCode -eq 0
        $b.FirewallJob = $null
        if (-not $ok) { Write-BridgeLog $b.Ctx 'firewall: the elevated rules script failed' }
    }
    $b.FirewallOk = Test-BridgeFirewall $b.SshdPath
    $b.FirewallState = if ($b.FirewallOk) { '' } else { 'failed' }
    Update-BridgeNetwork
    Update-BridgeServer
    Send-BridgeHello -Probe
    $b.Dirty = $true
}

# ---------------------------------------------------------------- outgoing: terminals on the other PC

function Open-BridgeTerminal([string]$Id, [switch]$Claude) {
    $b = $script:Bridge
    $peer = Find-BridgePeer $Id
    if (-not $peer) { return }
    $ssh = Join-Path $b.Ctx.SshDir 'ssh.exe'
    $alias = Get-PeerAlias $peer $b.Peers
    $sshArgs = '-F "{0}" {1}{2}' -f $b.Ctx.SshConfig, $(if ($Claude) { '-t ' } else { '' }), $alias
    if ($Claude) { $sshArgs += ' claude' }
    $title = if ($Claude) { "Claude Code en $($peer.name)" } else { $peer.name }
    try {
        Start-Process -FilePath 'wt.exe' -ArgumentList ('-w new --title "{0}" "{1}" {2}' -f $title, $ssh, $sshArgs) -ErrorAction Stop
    } catch {
        Start-Process -FilePath $ssh -ArgumentList $sshArgs
    }
}

# ---------------------------------------------------------------- tray menu and notices

function Show-BridgeBalloon([string]$Text, [string]$Action) {
    if (-not $script:Notify -or -not $script:Notify.Visible) { return }
    $script:BridgeBalloonAction = $Action
    $script:Notify.ShowBalloonTip(6000, 'Otros PCs', $Text, [System.Windows.Forms.ToolTipIcon]::Info)
}

# The "Otros PCs" submenu, rebuilt each time it opens.
function Update-BridgeMenu($Item) {
    $b = $script:Bridge
    $Item.DropDownItems.Clear()
    [void]$Item.DropDownItems.Add('Abrir Otros PCs...', $null, { Show-BridgeDialog })
    if (-not $b -or -not $b.Ready) { return }
    if ($b.Peers.Count) { [void]$Item.DropDownItems.Add('-') }
    foreach ($peer in $b.Peers) {
        [void]$Item.DropDownItems.Add("Terminal en $($peer.name)", $null, [scriptblock]::Create("Open-BridgeTerminal '$($peer.id)'"))
        [void]$Item.DropDownItems.Add("Claude Code en $($peer.name)", $null, [scriptblock]::Create("Open-BridgeTerminal '$($peer.id)' -Claude"))
    }
    $sessions = @($b.Sessions.Values)
    if ($sessions.Count) {
        [void]$Item.DropDownItems.Add('-')
        foreach ($session in $sessions) {
            $ask = "Tx '\u00bfCerrar lo que $($session.PeerName) tiene abierto en este PC? Lo que est\u00e9 haciendo all\u00ed se corta.'"
            [void]$Item.DropDownItems.Add("Desconectar a $($session.PeerName) ($(Get-SessionLabel $session))", $null, [scriptblock]::Create("if (Confirm-UiAction ($ask)) { Stop-BridgeSession '$($session.Id)' }"))
        }
    }
}

function Invoke-BridgeTick {
    $b = $script:Bridge
    if (-not $b) {
        try { Initialize-BridgeTray (Join-Path $TrayRoot 'ssh') }
        catch {
            if ($script:Bridge) { $script:Bridge.Problem = 'error'; $script:Bridge.Detail = $_.Exception.Message; Write-BridgeLog $script:Bridge.Ctx "init: $($_.Exception.Message)" }
        }
        return
    }
    if ($b.FirewallJob -and $b.FirewallJob.HasExited) { Complete-BridgeFirewall }
    if (-not $b.Ready -or $b.Busy) { return }
    $b.Busy = $true
    try {
        $now = Get-Date
        if (($now - $b.NetworksAt).TotalSeconds -ge 60) {
            $before = @(Get-BridgeListen) -join ','
            $b.Networks = @(Get-BridgeNetworks); $b.NetworksAt = $now
            if ((@(Get-BridgeListen) -join ',') -ne $before) { Update-BridgeNetwork; Update-BridgeServer; Send-BridgeHello -Probe; $b.Dirty = $true }
        }
        if ($b.Udp) { Receive-BridgeMessages }
        Update-PairingProgress
        Update-BridgeRequests
        Update-BridgeSessions
        if (($now - $b.LastSlow).TotalSeconds -ge 5) {
            $b.LastSlow = $now
            Update-BridgeServer
            Clear-BridgeLeftovers
            Repair-BridgeTampering
        }
        if (($now - $b.LastBeacon).TotalSeconds -ge 30) { Send-BridgeHello }
        if ($script:ApprovalForm) { $script:ApprovalForm.Invalidate() }
        if ($script:BridgeDialog -and $b.Dirty) { $script:BridgeDialog.Invalidate() }
        $b.Dirty = $false
    } catch {
        Write-BridgeLog $b.Ctx "tick: $($_.Exception.Message)"
    } finally {
        $b.Busy = $false
    }
}

# ---------------------------------------------------------------- drawing helpers

function Draw-Wrapped($G, [string]$Text, $Font, $Color, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $flags = [System.Windows.Forms.TextFormatFlags]'WordBreak, NoPadding, EndEllipsis, NoPrefix'
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $Font, (New-Rect $X $Y $W $H), $Color, $flags)
}

function Draw-PillButton($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Rect, [string]$Label, [scriptblock]$Action, [switch]$Accent) {
    $P = $script:Palette
    if ($Accent) {
        Fill-Round $G $Rect (Px 7) $(if ($Hover -eq $Id) { $P.AccentHover } else { $P.Accent })
        $color = $P.AccentText
    } else {
        Fill-Round $G $Rect (Px 7) $(if ($Hover -eq $Id) { $P.SurfaceHover } else { $P.Back })
        Stroke-Round $G $Rect (Px 7) $P.Border
        $color = $P.Text
    }
    Draw-Text $G $Label $script:Fonts.Small $color $Rect.X $Rect.Y $Rect.Width $Rect.Height 'Center'
    if ($Action) { Add-Hit $Map $Id $Rect $Action }
}

function Get-PillWidth([string]$Label) { (Measure-TextWidth $Label $script:Fonts.Small) + (Px 20) }

function Format-SeenText($Peer) {
    $seen = $script:Bridge.Discovered[$Peer.id]
    if ($seen -and ((Get-Date) - $seen.seen).TotalSeconds -le $BridgeSeenSeconds) { return Tx 'en l\u00ednea' }
    if ($seen) { return 'visto ' + (Format-Clock $seen.seen) }
    'sin verlo hoy'
}

# Status line of the window: text, color and an optional fix.
function Get-BridgeStatus {
    $b = $script:Bridge
    $P = $script:Palette
    if (-not $b) { return @{ Text = 'Preparando...'; Color = $P.Muted } }
    switch ($b.Problem) {
        'openssh' { return @{ Text = (Tx 'Falta OpenSSH: reinstala ClaudeMaxxing (install.ps1 desde el repo).'); Color = $P.Error } }
        'error'   { return @{ Text = "No se pudo preparar: $($b.Detail)"; Color = $P.Error } }
    }
    if (-not $b.FirewallOk) {
        switch ($b.FirewallState) {
            'waiting'  { return @{ Text = (Tx 'Esperando el permiso de administrador\u2026'); Color = $P.Warn } }
            'declined' { return @{ Text = (Tx 'Cancelaste el permiso: sin la regla del firewall no acepta conexiones.'); Color = $P.Warn; Fix = 'Permitir...'; FixAction = { Repair-BridgeFirewall } } }
            'failed'   { return @{ Text = 'No se pudo crear la regla del firewall.'; Color = $P.Error; Fix = 'Reintentar...'; FixAction = { Repair-BridgeFirewall } } }
        }
        return @{ Text = 'Falta la regla del firewall.'; Color = $P.Warn; Fix = 'Permitir...'; FixAction = { Repair-BridgeFirewall } }
    }
    # New Wi-Fi networks are Public by default: the fix is marking this one Private in Settings.
    if (-not $b.Networks.Count) { return @{ Text = 'Red no privada: ni busca PCs ni acepta conexiones.'; Color = $P.Warn; Fix = 'Hacerla privada...'; FixAction = { Start-Process 'ms-settings:network-status' } } }
    $network = ($b.Networks | Select-Object -First 1).Name
    if ($b.Problem -eq 'server') { return @{ Text = "El servidor SSH no arranca: $($b.Detail)"; Color = $P.Error } }
    if (-not $b.Settings.acceptIncoming) { return @{ Text = "Red $network " + (Tx '\u00b7') + ' no acepta conexiones entrantes'; Color = $P.Muted } }
    if (-not @($b.Peers | Where-Object { $_.clientKey }).Count) { return @{ Text = "Red $network " + (Tx '\u00b7') + ' empareja un PC para empezar'; Color = $P.Muted } }
    @{ Text = "Red $network " + (Tx '\u00b7') + ' aceptando a los PCs emparejados'; Color = $P.Ok }
}

# ---------------------------------------------------------------- Otros PCs window

function Show-BridgeDialog([string]$RenderPath) {
    if ($script:BridgeDialog) { $script:BridgeDialog.Activate(); return }
    $P = $script:Palette
    $F = $script:Fonts
    $W = 440

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Otros PCs'
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.BackColor = $P.Back
    $dlg.KeyPreview = $true
    $dlg.TopMost = $true
    $dlg.ClientSize = New-Object System.Drawing.Size((Px $W), (Px 480))
    if ($script:Notify -and $script:Notify.Icon) { $dlg.Icon = $script:Notify.Icon }
    Enable-DoubleBuffer $dlg
    $dlg.Tag = New-HitMap
    Register-HitMap $dlg
    $script:BridgeDialog = $dlg
    $script:BridgeUi = @{ Logo = (New-TintedLogo $P.Accent (Px 22)); ConfirmForget = ''; Message = ''; MessageAt = [datetime]::MinValue
        Render = [bool]$RenderPath; Resizing = $false; WantHeight = 0 }

    $ipBox = New-Object System.Windows.Forms.TextBox
    $ipBox.BorderStyle = 'None'
    $ipBox.BackColor = $P.Surface
    $ipBox.ForeColor = $P.Text
    $ipBox.Font = $F.Body
    $ipBox.Width = Px 200
    $dlg.Controls.Add($ipBox)
    $script:BridgeUi.IpBox = $ipBox
    $ipBox.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Find-BridgeAddress } })
    # Placeholder text inside the box until it gets the focus.
    $ipBox.Add_Enter({ param($sender, $e) if ($sender.Tag -eq 'hint') { $sender.Text = ''; $sender.ForeColor = $script:Palette.Text; $sender.Tag = $null } })
    $ipBox.Add_Leave({ param($sender, $e) Set-IpHint $sender })
    Set-IpHint $ipBox

    $dlg.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.Close() } })
    $dlg.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Y -gt (Px 56)) { return }
        if (Find-Hit $sender.Tag $e.Location) { return }
        [void][ClaudeTray.Native]::ReleaseCapture()
        [void][ClaudeTray.Native]::SendMessage($sender.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    })
    $dlg.Add_HandleCreated({ param($sender, $e) Set-RoundedWindow $sender $script:Palette.Border })
    $dlg.Add_Paint({ param($sender, $e) try { Draw-BridgeDialog $sender $e.Graphics } catch { if ($script:Bridge) { Write-BridgeLog $script:Bridge.Ctx "paint: $($_.Exception.Message)" } } })
    $dlg.Add_FormClosed({
        $b = $script:Bridge
        if ($b -and -not $script:BridgeUi.Render) {
            Stop-BridgePairing
            $b.PairingMode = $false
            Send-BridgeHello
        }
        if ($script:BridgeUi.Logo) { $script:BridgeUi.Logo.Dispose() }
        $script:BridgeDialog = $null
    })

    $b = $script:Bridge
    if ($b -and $b.Ready -and -not $RenderPath) {
        $b.PairingMode = $true
        $b.PairingModeAt = Get-Date
        $b.Networks = @(Get-BridgeNetworks); $b.NetworksAt = Get-Date
        Send-BridgeHello -Probe
    }

    if ($RenderPath) {
        $dlg.StartPosition = 'Manual'
        $dlg.Location = New-Object System.Drawing.Point(-5000, -5000)
        $dlg.Add_Shown({
            param($sender, $e)
            # Off screen the form only paints through DrawToBitmap: the first one measures, the queued resize
            # applies, the second one draws at the final size.
            $probe = New-Object System.Drawing.Bitmap($sender.Width, $sender.Height)
            $sender.DrawToBitmap($probe, (New-Rect 0 0 $sender.Width $sender.Height))
            $probe.Dispose()
            [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($sender.Width, $sender.Height)
            $sender.DrawToBitmap($bmp, (New-Rect 0 0 $sender.Width $sender.Height))
            $bmp.Save($RenderPath)
            $sender.Close()
        })
        [void]$dlg.ShowDialog()
        return
    }
    $dlg.Show()
    $dlg.Activate()
}

function Resize-BridgeDialog {
    $ui = $script:BridgeUi
    $ui.Resizing = $false
    if (-not $script:BridgeDialog) { return }
    # Never taller than the screen, and pulled back up when it grew past the bottom.
    $area = [System.Windows.Forms.Screen]::FromControl($script:BridgeDialog).WorkingArea
    $script:BridgeDialog.ClientSize = New-Object System.Drawing.Size((Px 440), [Math]::Min($ui.WantHeight, $area.Height - (Px 16)))
    if ($script:BridgeDialog.Bottom -gt $area.Bottom) { $script:BridgeDialog.Top = [Math]::Max($area.Top, $area.Bottom - $script:BridgeDialog.Height) }
    $script:BridgeDialog.Invalidate()
}

function Set-IpHint($Box) {
    if ($Box.Text.Trim()) { return }
    $Box.Tag = 'hint'
    $Box.ForeColor = $script:Palette.Faint
    $Box.Text = Tx '\u00bfNo aparece? Escribe su IP'
}

function Find-BridgeAddress {
    $text = if ($script:BridgeUi.IpBox.Tag -eq 'hint') { '' } else { $script:BridgeUi.IpBox.Text.Trim() }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ip) -or -not (Test-BridgeSource $text)) {
        Set-BridgeMessage (Tx 'Escribe la IP privada del otro PC (por ejemplo 192.168.1.20).')
        return
    }
    Send-BridgeHello -Probe -To $text
    Set-BridgeMessage "Buscando ClaudeMaxxing en $text..."
}

function Set-BridgeMessage([string]$Text) {
    $script:BridgeUi.Message = $Text
    $script:BridgeUi.MessageAt = Get-Date
    if ($script:BridgeDialog) { $script:BridgeDialog.Invalidate() }
}

function Copy-BridgeCommand([string]$Text) {
    try { [System.Windows.Forms.Clipboard]::SetText($Text) } catch { }
    Set-BridgeMessage ("Copiado: $Text")
}

function Draw-BridgeDialog($Form, $G) {
    $P = $script:Palette
    $F = $script:Fonts
    $b = $script:Bridge
    $ui = $script:BridgeUi
    $W = 440
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $map = $Form.Tag
    $map.Items.Clear()
    $hover = $map.Hover
    $left = Px 24
    $inner = Px ($W - 48)

    # header
    if ($ui.Logo) { $G.DrawImage($ui.Logo, $left, (Px 19)) }
    Draw-Text $G 'Otros PCs' $F.Title $P.Text (Px 56) (Px 14) (Px 300) (Px 32)
    $close = New-Rect (Px ($W - 52)) (Px 16) (Px 30) (Px 30)
    if ($hover -eq 'close') { Fill-Round $G $close (Px 6) $P.SurfaceHover }
    Draw-Text $G (Tx '\u00d7') $F.Close $P.Muted $close.X $close.Y $close.Width $close.Height 'Center'
    Add-Hit $map 'close' $close { $script:BridgeDialog.Close() } 'Cerrar (Esc)'
    $pen = New-Object System.Drawing.Pen($P.Border)
    $G.DrawLine($pen, $left, (Px 56), $left + $inner, (Px 56))
    $pen.Dispose()

    # this PC
    $y = Px 70
    $card = New-Rect $left $y $inner (Px 74)
    Fill-Round $G $card (Px 10) $P.Surface
    Draw-Text $G 'ESTE PC' $F.Caps $P.Muted (Px 40) ($y + (Px 10)) (Px 200) (Px 18)
    $self = if ($b -and $b.Identity) { $b.Identity.name + '  ' + (Tx '\u00b7') + '  ' + $b.Identity.user } else { $env:COMPUTERNAME }
    Draw-Text $G $self $F.BodyStrong $P.Text (Px 40) ($y + (Px 28)) (Px 260) (Px 22)
    $status = Get-BridgeStatus
    $statusW = $inner - (Px 32)
    if ($status.Fix) {
        $fixW = Get-PillWidth $status.Fix
        $fix = New-Rect ($card.Right - (Px 16) - $fixW) ($y + (Px 46)) $fixW (Px 22)
        Draw-PillButton $G $map $hover 'fix' $fix $status.Fix $status.FixAction -Accent
        $statusW -= $fixW + (Px 8)
    }
    Draw-Text $G $status.Text $F.Small $status.Color (Px 40) ($y + (Px 48)) $statusW (Px 18)
    if ($b -and $b.Ready) {
        # "Acepta conexiones" switch
        $on = [bool]$b.Settings.acceptIncoming
        $switch = New-Rect ($card.Right - (Px 52)) ($y + (Px 10)) (Px 36) (Px 20)
        Fill-Round $G $switch (Px 10) $(if ($on) { $P.Accent } else { $P.Track })
        $knobX = if ($on) { $switch.Right - (Px 18) } else { $switch.X + (Px 2) }
        $G.FillEllipse((New-Object System.Drawing.SolidBrush($P.AccentText)), $knobX, $switch.Y + (Px 2), (Px 16), (Px 16))
        $labelW = Px 130
        Draw-Text $G 'Acepta conexiones' $F.Small $P.Muted ($switch.X - $labelW - (Px 8)) $switch.Y $labelW $switch.Height 'Right'
        Add-Hit $map 'accept' (New-Rect ($switch.X - $labelW - (Px 8)) $switch.Y ($labelW + $switch.Width + (Px 8)) $switch.Height) ([scriptblock]::Create("Set-BridgeAccept `$$(-not $on)"))
    }
    $y += Px 86

    # pairing in progress
    if ($b -and $b.Pairing) { $y = Draw-PairingCard $G $map $hover $b.Pairing $left $inner $y }

    # paired PCs
    Draw-Text $G 'EMPAREJADOS' $F.Caps $P.Muted $left $y (Px 200) (Px 18)
    $y += Px 22
    $peers = @(if ($b) { $b.Peers })
    if (-not $peers.Count) {
        $row = New-Rect $left $y $inner (Px 36)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'A\u00fan no hay PCs emparejados.') $F.Body $P.Muted ($left + (Px 14)) $y ($inner - (Px 28)) (Px 36)
        $y += Px 42
    }
    $grants = @{}
    if ($b -and $b.Ready -and -not $ui.Render) { $grants = Read-BridgeGrants $b.Ctx }
    # Paired PC: name and buttons on the first line, the ssh command (click to copy) and status under them.
    foreach ($peer in $peers) {
        $row = New-Rect $left $y $inner (Px 58)
        Fill-Round $G $row (Px 8) $P.Surface
        $alias = Get-PeerAlias $peer $peers
        $right = $row.Right - (Px 10)
        if ($ui.ConfirmForget -eq $peer.id) {
            foreach ($button in @(@{ Id = "forget-no"; Label = 'No'; Action = '$script:BridgeUi.ConfirmForget = ""; $script:BridgeDialog.Invalidate()'; Accent = $false },
                                  @{ Id = "forget-yes"; Label = 'Olvidar'; Action = "Remove-BridgePeer '$($peer.id)'; `$script:BridgeUi.ConfirmForget = ''"; Accent = $true })) {
                $bw = Get-PillWidth $button.Label
                $rect = New-Rect ($right - $bw) ($row.Y + (Px 8)) $bw (Px 24)
                Draw-PillButton $G $map $hover $button.Id $rect $button.Label ([scriptblock]::Create($button.Action)) -Accent:$button.Accent
                $right = $rect.X - (Px 6)
            }
            Draw-Text $G (Tx '\u00bfOlvidar este PC?') $F.Small $P.Warn ($right - (Px 110)) ($row.Y + (Px 8)) (Px 110) (Px 24) 'Right'
            $right -= Px 116
        } else {
            $forget = New-Rect ($right - (Px 22)) ($row.Y + (Px 9)) (Px 22) (Px 22)
            if ($hover -eq "forget-$($peer.id)") { Fill-Round $G $forget (Px 6) $P.SurfaceHover }
            Draw-Text $G (Tx '\u00d7') $F.BodyStrong $P.Muted $forget.X $forget.Y $forget.Width $forget.Height 'Center'
            Add-Hit $map "forget-$($peer.id)" $forget ([scriptblock]::Create("`$script:BridgeUi.ConfirmForget = '$($peer.id)'; `$script:BridgeDialog.Invalidate()")) 'Olvidar este PC'
            $right = $forget.X - (Px 6)
            foreach ($button in @(@{ Id = "claude-$($peer.id)"; Label = 'Claude Code'; Action = "Open-BridgeTerminal '$($peer.id)' -Claude" },
                                  @{ Id = "term-$($peer.id)"; Label = 'Terminal'; Action = "Open-BridgeTerminal '$($peer.id)'" })) {
                $bw = Get-PillWidth $button.Label
                $rect = New-Rect ($right - $bw) ($row.Y + (Px 8)) $bw (Px 24)
                Draw-PillButton $G $map $hover $button.Id $rect $button.Label ([scriptblock]::Create($button.Action)) -Accent:($button.Label -eq 'Terminal')
                $right = $rect.X - (Px 6)
            }
        }
        Draw-Text $G $peer.name $F.BodyStrong $P.Text ($row.X + (Px 14)) ($row.Y + (Px 8)) ($right - $row.X - (Px 20)) (Px 24)
        $sub = "ssh $alias  " + (Tx '\u00b7') + '  ' + (Format-SeenText $peer)
        if ($grants.ContainsKey($peer.id)) { $sub += '  ' + (Tx '\u00b7') + '  sin preguntar hasta ' + (Format-Clock ([DateTimeOffset]::FromUnixTimeSeconds($grants[$peer.id]).LocalDateTime)) }
        $subRect = New-Rect ($row.X + (Px 14)) ($row.Y + (Px 35)) ($row.Width - (Px 28)) (Px 16)
        $subColor = if ($hover -eq "copy-$($peer.id)") { $P.Accent } else { $P.Muted }
        Draw-Text $G $sub $F.Small $subColor $subRect.X $subRect.Y $subRect.Width $subRect.Height
        Add-Hit $map "copy-$($peer.id)" (New-Rect $subRect.X $subRect.Y ((Measure-TextWidth "ssh $alias" $F.Small) + (Px 4)) $subRect.Height) ([scriptblock]::Create("Copy-BridgeCommand 'ssh $alias'")) 'Copiar este comando'
        $y += Px 64
    }
    $y += Px 6

    # ClaudeMaxxing PCs seen on the network, not paired yet
    $seen = @()
    if ($b) {
        $seen = @($b.Discovered.Values | Where-Object { ((Get-Date) - $_.seen).TotalSeconds -le $BridgeSeenSeconds -and -not (Find-BridgePeer $_.id) } | Sort-Object name)
    }
    # Up to four, so a busy network does not push the window past the screen; the rest are counted.
    $hiddenSeen = [Math]::Max(0, $seen.Count - 4)
    $seen = @($seen | Select-Object -First 4)
    Draw-Text $G 'EN TU RED' $F.Caps $P.Muted $left $y (Px 200) (Px 18)
    if ($hiddenSeen -gt 0) { Draw-Text $G (Tx "+$hiddenSeen m\u00e1s: escribe su IP abajo") $F.Small $P.Muted $left $y $inner (Px 18) 'Right' }
    $y += Px 22
    if (-not $seen.Count) {
        $row = New-Rect $left $y $inner (Px 36)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Ning\u00fan otro PC con ClaudeMaxxing a la vista.') $F.Body $P.Muted ($left + (Px 14)) $y ($inner - (Px 28)) (Px 36)
        $y += Px 42
    }
    foreach ($pc in $seen) {
        $row = New-Rect $left $y $inner (Px 50)
        Fill-Round $G $row (Px 8) $P.Surface
        $bw = Get-PillWidth 'Emparejar'
        $rect = New-Rect ($row.Right - (Px 10) - $bw) ($row.Y + (Px 13)) $bw (Px 24)
        $busy = Test-PairingActive
        Draw-PillButton $G $map $hover "pair-$($pc.id)" $rect 'Emparejar' $(if ($busy) { $null } else { [scriptblock]::Create("Start-BridgePairing '$($pc.id)'") }) -Accent:(-not $busy)
        $textW = $rect.X - $row.X - (Px 20)
        Draw-Text $G $pc.name $F.BodyStrong $P.Text ($row.X + (Px 14)) ($row.Y + (Px 6)) $textW (Px 20)
        $sub = $pc.user + '  ' + (Tx '\u00b7') + '  ' + $pc.address
        if ($pc.pairing) { $sub += '  ' + (Tx '\u00b7') + '  listo para emparejar' }
        Draw-Text $G $sub $F.Small $(if ($pc.pairing) { $P.Ok } else { $P.Muted }) ($row.X + (Px 14)) ($row.Y + (Px 27)) $textW (Px 16)
        $y += Px 56
    }

    # typed address, for networks that drop broadcasts
    $bw = Get-PillWidth 'Buscar'
    $field = New-Rect $left $y ($inner - $bw - (Px 8)) (Px 30)
    Fill-Round $G $field (Px 8) $P.Surface
    $ipBox = $ui.IpBox
    $boxLocation = New-Object System.Drawing.Point(($field.X + (Px 10)), ($field.Y + [int](($field.Height - $ipBox.Height) / 2)))
    if ($ipBox.Location -ne $boxLocation) { $ipBox.Location = $boxLocation }
    if ($ipBox.Width -ne $field.Width - (Px 20)) { $ipBox.Width = $field.Width - (Px 20) }
    Draw-PillButton $G $map $hover 'find' (New-Rect ($field.Right + (Px 8)) ($y + (Px 3)) $bw (Px 24)) 'Buscar' { Find-BridgeAddress }
    $y += Px 40

    # footer
    if ($ui.Message -and ((Get-Date) - $ui.MessageAt).TotalSeconds -lt 8) {
        Draw-Text $G $ui.Message $F.Small $P.Accent $left $y $inner (Px 18)
    } elseif ($ui.Render -or (Test-PairingOpen)) {
        Draw-Text $G 'Con esta ventana abierta, otros PCs pueden pedir emparejarse con este.' $F.Small $P.Faint $left $y $inner (Px 18)
    } else {
        Draw-Text $G 'Para emparejar otra vez, cierra y vuelve a abrir esta ventana.' $F.Small $P.Faint $left $y $inner (Px 18)
    }
    $y += Px 30

    # Resizing inside Paint does not take; it is done right after.
    if ($Form.ClientSize.Height -ne $y -and -not $ui.Resizing) {
        $ui.WantHeight = $y
        $ui.Resizing = $true
        [void]$Form.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Resize-BridgeDialog })
    }
    $border = New-Object System.Drawing.Pen($P.Border)
    $G.DrawRectangle($border, 0, 0, $Form.ClientSize.Width - 1, $Form.ClientSize.Height - 1)
    $border.Dispose()
}

# The pairing card; returns the y below it.
function Draw-PairingCard($G, $Map, $Hover, $Pairing, [int]$Left, [int]$Inner, [int]$Y) {
    $P = $script:Palette
    $F = $script:Fonts
    $name = if ($Pairing.Peer) { [string]$Pairing.Peer.name } else { [string]$Pairing.TargetName }
    $x = $Left + (Px 16)
    $w = $Inner - (Px 32)
    switch ($Pairing.Stage) {
        'confirm' {
            # The code is only worth something if the user compares it with the other screen: say so, and show
            # where the request comes from (names are whatever the other side claims).
            $card = New-Rect $Left $Y $Inner (Px 156)
            Fill-Round $G $card (Px 10) $P.AccentTint
            Draw-Text $G (Tx 'C\u00d3DIGO PARA EMPAREJAR CON ') $F.Caps $P.Muted $x ($Y + (Px 10)) $w (Px 18)
            Draw-Text $G $name.ToUpperInvariant() $F.Caps $P.Accent ($x + (Measure-TextWidth (Tx 'C\u00d3DIGO PARA EMPAREJAR CON ') $F.Caps)) ($Y + (Px 10)) (Px 200) (Px 18)
            Draw-Text $G $Pairing.Code $script:BridgeCodeFont $P.Text $x ($Y + (Px 28)) $w (Px 40)
            $origin = 'IP ' + $Pairing.Address
            if ($Pairing.Role -eq 'responder') { $origin = 'Lo pide ' + $Pairing.Address }
            if ($Pairing.Peer -and (Find-BridgePeer ([string]$Pairing.Peer.id))) { $origin += (Tx ' \u00b7 ya emparejado: cambia sus llaves') }
            Draw-Text $G $origin $F.Small $P.Muted $x ($Y + (Px 36)) $w (Px 24) 'Right'
            $warning = if ($Pairing.Role -eq 'responder') { Tx 'Confirma solo si pediste emparejar desde tu otro PC y all\u00ed se ve este mismo c\u00f3digo.' }
                       else { Tx 'Confirma solo si tu otro PC muestra exactamente este c\u00f3digo.' }
            Draw-Wrapped $G $warning $F.Small $P.Text $x ($Y + (Px 72)) $w (Px 34)
            if ($Pairing.LocalOk) {
                Draw-Text $G ((Tx 'Esperando que ') + $name + ' confirme...') $F.Small $P.Muted $x ($Y + (Px 124)) ($w - (Px 110)) (Px 18)
                $bw = Get-PillWidth 'Cancelar'
                Draw-PillButton $G $Map $Hover 'pair-cancel' (New-Rect ($card.Right - (Px 16) - $bw) ($Y + (Px 118)) $bw (Px 26)) 'Cancelar' { Stop-BridgePairing }
            } else {
                $yes = Tx 'S\u00ed, es el mismo'
                $bw = Get-PillWidth $yes
                $yesRect = New-Rect ($card.Right - (Px 16) - $bw) ($Y + (Px 118)) $bw (Px 26)
                Draw-PillButton $G $Map $Hover 'pair-yes' $yesRect $yes { Confirm-BridgePairing } -Accent
                $nw = Get-PillWidth 'No coincide'
                Draw-PillButton $G $Map $Hover 'pair-no' (New-Rect ($yesRect.X - (Px 8) - $nw) $yesRect.Y $nw (Px 26)) 'No coincide' { Stop-BridgePairing }
            }
            return $Y + (Px 168)
        }
        default {
            $card = New-Rect $Left $Y $Inner (Px 58)
            Fill-Round $G $card (Px 10) $P.Surface
            $sub = ''
            $subColor = $P.Muted
            $button = 'Cancelar'
            switch ($Pairing.Stage) {
                'asking'   { $title = "Esperando a $name..."; $sub = "Si no responde, abre Otros PCs en $name." }
                'done'     { $title = (Tx '\u2713 Emparejado con ') + $name; $sub = 'Ya puedes abrir una terminal en los dos sentidos.'; $subColor = $P.Ok; $button = 'Listo' }
                'failed'   {
                    $title = 'No se pudo emparejar'; $subColor = $P.Error; $button = 'Cerrar'
                    $sub = switch ($Pairing.Error) {
                        'commit'  { Tx 'Los c\u00f3digos no cuadran: alguien pudo interferir.' }
                        'timeout' { $name + (Tx ' no respondi\u00f3 a tiempo.') }
                        default   { 'Error de red.' }
                    }
                }
                'cancelled' { $title = 'Emparejamiento cancelado'; $sub = $(if ($Pairing.Error -eq 'peer') { $name + (Tx ' lo cancel\u00f3.') } else { '' }); $button = 'Cerrar' }
                default    { $title = "Emparejando con $name..." }
            }
            $bw = Get-PillWidth $button
            $rect = New-Rect ($card.Right - (Px 16) - $bw) ($Y + (Px 16)) $bw (Px 26)
            Draw-PillButton $G $Map $Hover 'pair-close' $rect $button { Stop-BridgePairing }
            Draw-Text $G $title $F.BodyStrong $P.Text $x ($Y + (Px 9)) ($rect.X - $x - (Px 8)) (Px 22)
            Draw-Text $G $sub $F.Small $subColor $x ($Y + (Px 32)) ($rect.X - $x - (Px 8)) (Px 18)
            return $Y + (Px 70)
        }
    }
}

# ---------------------------------------------------------------- approval dialog (incoming connection)

function Show-ApprovalForm([string]$RenderPath) {
    $P = $script:Palette
    $W = 420
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Tx 'Conexi\u00f3n entrante'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $P.Back
    $form.TopMost = $true
    $form.KeyPreview = $true
    $first = Get-ApprovalRequest
    $form.ClientSize = New-Object System.Drawing.Size((Px $W), $(if ($first) { (Get-ApprovalLayout $first).Height } else { Px 342 }))
    if ($script:Notify -and $script:Notify.Icon) { $form.Icon = $script:Notify.Icon }
    Enable-DoubleBuffer $form
    $form.Tag = New-HitMap
    Register-HitMap $form
    # No Tab / Enter here: a window that pops up while you type must not take keys meant for another app.
    $form.Tag.NoKeys = $true
    $script:ApprovalForm = $form
    $script:ApprovalLogo = New-TintedLogo $P.Accent (Px 22)
    $form.Add_HandleCreated({ param($sender, $e) Set-RoundedWindow $sender $script:Palette.Border })
    $form.Add_Paint({ param($sender, $e) try { Draw-ApprovalForm $sender $e.Graphics } catch { } })
    # Esc rejects (the safe answer, so it needs no arming); Enter does nothing, so no key press can allow.
    $form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -ne 'Escape') { return }
        $request = Get-ApprovalRequest
        if ($request) { Send-BridgeAnswer $request.Id 'deny'; Update-BridgeRequests }
    })
    $form.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Y -gt (Px 56) -or (Find-Hit $sender.Tag $e.Location)) { return }
        [void][ClaudeTray.Native]::ReleaseCapture()
        [void][ClaudeTray.Native]::SendMessage($sender.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    })
    $form.Add_FormClosed({
        if ($script:ApprovalLogo) { $script:ApprovalLogo.Dispose() }
        $script:ApprovalForm = $null
    })
    if ($RenderPath) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(-5000, -5000)
        $form.Add_Shown({
            param($sender, $e)
            [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($sender.Width, $sender.Height)
            $sender.DrawToBitmap($bmp, (New-Rect 0 0 $sender.Width $sender.Height))
            $bmp.Save($RenderPath)
            $sender.Close()
        })
        [void]$form.ShowDialog()
        return
    }
    $form.Show()
    $form.Activate()
}

# What a request does, for the dialog: a title and, for a command, the command itself made safe to read.
function Get-RequestView($Request) {
    switch ($Request.Kind) {
        'shell' { return @{ Title = 'Abrir una terminal (PowerShell) en este PC'; Detail = '' } }
        'sftp'  { return @{ Title = 'Copiar archivos de o a este PC (SFTP)'; Detail = '' } }
    }
    # Only the exact command "claude" is shown as Claude Code; anything longer is shown as the command it is.
    if ($Request.Command.Trim() -ceq 'claude') { return @{ Title = 'Abrir Claude Code en este PC'; Detail = '' } }
    @{ Title = 'Ejecutar este comando:'; Detail = (Format-CommandPreview $Request.Command) }
}

$script:BridgeMonoFont = New-UiFont 'Consolas' 9
# Buttons stay off for a moment after a request appears, so a click meant for another window cannot allow it.
$BridgeArmMilliseconds = 1500
$script:ApprovalShown = @{ Id = ''; At = [datetime]::MinValue }

$script:ApprovalTextFlags = [System.Windows.Forms.TextFormatFlags]'WordBreak, NoPadding, NoPrefix, TextBoxControl'

# The command is shown whole: its box, and the window, grow to fit it (Format-CommandPreview caps its length).
# Shift is how far everything under the box moves from its place for a two-line box (88..164 before).
function Get-ApprovalLayout($Request) {
    $view = Get-RequestView $Request
    $detailW = (Px (420 - 48)) - (Px 24)
    $detailH = 0
    if ($view.Detail) {
        $detailH = [System.Windows.Forms.TextRenderer]::MeasureText($view.Detail, $script:BridgeMonoFont, (New-Object System.Drawing.Size($detailW, 0)), $script:ApprovalTextFlags).Height
    }
    $boxH = if ($view.Detail) { [Math]::Max((Px 76), (Px 40) + $detailH) } else { Px 40 }
    $shift = (Px 106) + $boxH - (Px 164)
    @{ View = $view; DetailWidth = $detailW; DetailHeight = $detailH; BoxHeight = $boxH; Shift = $shift; Height = (Px 342) + $shift }
}

function Draw-ApprovalForm($Form, $G) {
    $P = $script:Palette
    $F = $script:Fonts
    $W = 420
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $map = $Form.Tag
    $map.Items.Clear()
    $hover = $map.Hover
    $left = Px 24
    $inner = Px ($W - 48)
    $request = Get-ApprovalRequest
    if (-not $request) { return }
    $peer = $request.Peer
    if ($script:ApprovalShown.Id -ne $request.Id) { $script:ApprovalShown = @{ Id = $request.Id; At = (Get-Date) } }
    $armed = ((Get-Date) - $script:ApprovalShown.At).TotalMilliseconds -ge $BridgeArmMilliseconds

    if ($script:ApprovalLogo) { $G.DrawImage($script:ApprovalLogo, $left, (Px 19)) }
    Draw-Text $G (Tx 'Conexi\u00f3n entrante') $F.Title $P.Text (Px 56) (Px 14) (Px 300) (Px 32)

    # Name and "user desde IP" on two lines, so a long PC name never runs into the address.
    Draw-Text $G $peer.name $F.BodyStrong $P.Text $left (Px 58) $inner (Px 22)
    Draw-Text $G "$($peer.user) desde $($request.Client)" $F.Small $P.Muted $left (Px 80) $inner (Px 18)

    $layout = Get-ApprovalLayout $request
    $view = $layout.View
    if ($Form.ClientSize.Height -ne $layout.Height) { $Form.ClientSize = New-Object System.Drawing.Size($Form.ClientSize.Width, $layout.Height) }
    $box = New-Rect $left (Px 106) $inner $layout.BoxHeight
    Fill-Round $G $box (Px 10) $P.Surface
    Draw-Text $G $view.Title $F.BodyStrong $P.Text ($box.X + (Px 12)) ($box.Y + (Px 8)) ($box.Width - (Px 24)) (Px 20)
    if ($view.Detail) {
        [System.Windows.Forms.TextRenderer]::DrawText($G, $view.Detail, $script:BridgeMonoFont,
            (New-Rect ($box.X + (Px 12)) ($box.Y + (Px 30)) $layout.DetailWidth ($layout.DetailHeight + (Px 4))), $P.Text, $script:ApprovalTextFlags)
    }
    $dy = $layout.Shift

    $card = New-Rect $left ((Px 174) + $dy) $inner (Px 56)
    Fill-Round $G $card (Px 10) $P.AccentTint
    Draw-Wrapped $G (Tx 'Tendr\u00e1 los mismos permisos que tu usuario de Windows: tus archivos, tus programas y tu sesi\u00f3n de Claude Code. Permite solo PCs tuyos o de confianza.') $F.Small $P.Text ($card.X + (Px 12)) ($card.Y + (Px 8)) ($card.Width - (Px 24)) ($card.Height - (Px 12))

    $remaining = $BridgeApprovalSeconds - [int]((Get-Date) - $request.Seen).TotalSeconds
    Draw-Text $G ("Se rechaza sola en $([Math]::Max(0, $remaining)) s") $F.Small $P.Faint $left ((Px 238) + $dy) $inner (Px 18)
    $others = $script:Bridge.Requests.Count - 1
    if ($others -gt 0) {
        $othersText = if ($others -eq 1) { '1 solicitud' } else { "$others solicitudes" }
        Draw-Text $G ($othersText + (Tx ' m\u00e1s en espera')) $F.Small $P.Warn $left ((Px 238) + $dy) $inner (Px 18) 'Right'
    }

    $id = $request.Id
    $right = $left + $inner
    foreach ($button in @(@{ Id = 'allow'; Label = 'Permitir'; Action = "Send-BridgeAnswer '$id' 'allow'"; Accent = $true },
                          @{ Id = 'hour'; Label = 'Permitir 1 hora'; Action = "Send-BridgeAnswer '$id' 'allow' -ForAnHour"; Accent = $false },
                          @{ Id = 'deny'; Label = 'Rechazar'; Action = "Send-BridgeAnswer '$id' 'deny'"; Accent = $false })) {
        $bw = [Math]::Max((Px 84), (Get-PillWidth $button.Label))
        $rect = New-Rect ($right - $bw) ((Px 262) + $dy) $bw (Px 32)
        if ($armed) {
            Draw-PillButton $G $map $hover $button.Id $rect $button.Label ([scriptblock]::Create($button.Action + '; Update-BridgeRequests')) -Accent:$button.Accent
        } else {
            Fill-Round $G $rect (Px 7) $P.Surface
            Draw-Text $G $button.Label $F.Small $P.Faint $rect.X $rect.Y $rect.Width $rect.Height 'Center'
        }
        $right = $rect.X - (Px 8)
    }
    $hourNote = 'Permitir 1 hora: ese PC entra sin preguntar durante una hora'
    if ($others -gt 0) { $hourNote += ', incluidas sus solicitudes en espera' }
    Draw-Wrapped $G ($hourNote + '. Esc rechaza.') $F.Small $P.Faint $left ((Px 302) + $dy) $inner (Px 32)

    $border = New-Object System.Drawing.Pen($P.Border)
    $G.DrawRectangle($border, 0, 0, $Form.ClientSize.Width - 1, $Form.ClientSize.Height - 1)
    $border.Dispose()
}

# ---------------------------------------------------------------- previews (tray.ps1 -RenderBridgeTo / -RenderApprovalTo)

function Set-BridgePreview {
    $b = New-BridgeState (Join-Path $TrayRoot 'ssh')
    $b.Ready = $true; $b.FirewallOk = $true
    $b.Identity = [pscustomobject]@{ id = 'aaaaaaaaaaaa'; name = 'DESKTOP-SANTI'; user = 'santi'; port = $BridgeSshPort }
    $b.Settings = [ordered]@{ acceptIncoming = $true; noticed = @() }
    $b.Networks = @([pscustomobject]@{ Name = 'Casa 5G'; Address = '192.168.1.20'; Prefix = 24; Broadcast = '192.168.1.255' })
    $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPa+Sqs0YdEJlbrjplfv/pPL7Qh9n9FJfyg+mzTrzLsO'
    $b.Peers = @([pscustomobject]@{ id = 'bbbbbbbbbbbb'; name = 'PORTATIL-ANA'; user = 'ana'; port = $BridgeSshPort; address = '192.168.1.31'; hostKey = $key; clientKey = $key })
    $b.Discovered['bbbbbbbbbbbb'] = [pscustomobject]@{ id = 'bbbbbbbbbbbb'; name = 'PORTATIL-ANA'; user = 'ana'; port = $BridgeSshPort; address = '192.168.1.31'; udpPort = $BridgeUdpPort; pairing = $false; seen = (Get-Date) }
    $b.Discovered['cccccccccccc'] = [pscustomobject]@{ id = 'cccccccccccc'; name = 'OFICINA-PC'; user = 'santi'; port = $BridgeSshPort; address = '192.168.1.40'; udpPort = $BridgeUdpPort; pairing = $true; seen = (Get-Date) }
    $pairing = New-PairState 'initiator' '0123456789abcdef' $null '192.168.1.40' $BridgeUdpPort
    $pairing.Stage = 'confirm'; $pairing.Code = '482 913'; $pairing.TargetName = 'OFICINA-PC'
    $pairing.Peer = [pscustomobject]@{ name = 'OFICINA-PC' }
    $b.Pairing = $pairing
    $b.Requests['a' * 32] = [pscustomobject]@{ Id = ('a' * 32); Peer = $b.Peers[0]; Kind = 'exec'; Command = ('git -C C:/proyectos/tienda-web status --short && npm run build --workspaces --if-present' + (' ' * 60) + '& rd /s /q C:/proyectos'); Client = '192.168.1.31'; Seen = (Get-Date).AddSeconds(-12) }
    $script:ApprovalShown = @{ Id = ('a' * 32); At = (Get-Date).AddSeconds(-5) }
    $b.Requests['b' * 32] = [pscustomobject]@{ Id = ('b' * 32); Peer = $b.Peers[0]; Kind = 'exec'; Command = 'git status'; Client = '192.168.1.31'; Seen = (Get-Date).AddSeconds(-11) }
    $script:Bridge = $b
}
