# "Otros PCs" on the network: UDP beacons so ClaudeMaxxing PCs find each other, and pairing.
# Every message is one small JSON datagram on UDP $BridgeUdpPort, only on networks Windows marks Private.
#   hello  {id,name,user,port,pairing}  every 30 s (broadcast and to paired PCs) and as the answer to a probe
#   probe  {id}                          "who is there?" when the Otros PCs window opens, or to a typed IP
#   pair1..pair5                         pairing, below
# Pairing swaps each PC's SSH keys (client key: to log in there; host key: pinned here) and makes both screens
# show the same 6-digit code. The code is computed from both key sets and two nonces, and the PC that answers
# commits to its nonce before it sees the other's (numeric comparison, as in Bluetooth pairing): a machine in
# the middle cannot make the codes on the two screens match. Nothing is saved until both users confirm.
#   initiator -> pair1 {from}                    responder answers only while its Otros PCs window is open
#   responder -> pair2 {from, commit}            commit = sha256(initiator info | responder info | responder nonce)
#   initiator -> pair3 {nonce}
#   responder -> pair4 {nonce}                   initiator checks the commit; both show the code
#   each side -> pair5 {ok}                      sent when its user confirms (or cancels); repeated until answered
# Needs common.ps1 and bridge.ps1. Keep this file ASCII.

$BridgeMessageTypes = @('hello', 'probe', 'pair1', 'pair2', 'pair3', 'pair4', 'pair5')
$PairingTimeoutSeconds = 120

# ---------------------------------------------------------------- messages

function ConvertTo-BridgeDatagram([hashtable]$Message) {
    $Message['app'] = 'cmx'
    $Message['v'] = 1
    [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Message -Compress -Depth 4))
}

# The PC's public info as sent in hello (no keys) or in pairing messages (with keys).
function Get-BridgeInfo($Identity, $Keys) {
    $info = [ordered]@{ id = $Identity.id; name = $Identity.name; user = $Identity.user; port = [int]$Identity.port }
    if ($Keys) { $info.hostKey = $Keys.hostKey; $info.clientKey = $Keys.clientKey }
    $info
}

function Test-BridgeInfo($Info, [switch]$WithKeys) {
    if (-not $Info) { return $false }
    if (-not (Test-BridgeId ([string]$Info.id))) { return $false }
    if (-not (Test-BridgeName ([string]$Info.name) 40) -or -not (Test-BridgeName ([string]$Info.user) 64)) { return $false }
    $port = 0
    if (-not [int]::TryParse([string]$Info.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $false }
    if ($WithKeys -and (-not (Get-BridgeKeyText ([string]$Info.hostKey)) -or -not (Get-BridgeKeyText ([string]$Info.clientKey)))) { return $false }
    $true
}

# A received datagram as a checked object, or $null for anything malformed, foreign or oversized.
function ConvertFrom-BridgeDatagram([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -gt 4096) { return $null }
    try { $msg = [System.Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json } catch { return $null }
    if (-not $msg -or $msg.app -ne 'cmx' -or $msg.v -ne 1 -or $BridgeMessageTypes -notcontains [string]$msg.t) { return $null }
    $sidOk = ([string]$msg.sid) -cmatch '^[0-9a-f]{16}$'
    switch ([string]$msg.t) {
        'hello' { if (-not (Test-BridgeInfo $msg)) { return $null } }
        'probe' { if (-not (Test-BridgeId ([string]$msg.id))) { return $null } }
        'pair1' { if (-not $sidOk -or -not (Test-BridgeInfo $msg.from -WithKeys)) { return $null } }
        'pair2' { if (-not $sidOk -or -not (Test-BridgeInfo $msg.from -WithKeys) -or ([string]$msg.commit) -cnotmatch '^[0-9a-f]{64}$') { return $null } }
        { $_ -in 'pair3', 'pair4' } { if (-not $sidOk -or ([string]$msg.nonce) -cnotmatch '^[0-9a-f]{32}$') { return $null } }
        'pair5' { if (-not $sidOk -or $msg.ok -isnot [bool]) { return $null } }
    }
    $msg
}

# ---------------------------------------------------------------- pairing state machine (no I/O)

function Format-PairInfoText($Info) {
    @($Info.id, $Info.name, $Info.user, $Info.port, (Get-BridgeKeyText $Info.hostKey), (Get-BridgeKeyText $Info.clientKey)) -join '|'
}

function Get-PairCommit($InitiatorInfo, $ResponderInfo, [string]$ResponderNonce) {
    Get-Sha256Hex ('cmx-commit-v1|' + (Format-PairInfoText $InitiatorInfo) + '|' + (Format-PairInfoText $ResponderInfo) + '|' + $ResponderNonce)
}

# Six digits, shown as "123 456".
function Get-PairCode($InitiatorInfo, $ResponderInfo, [string]$InitiatorNonce, [string]$ResponderNonce) {
    $hex = Get-Sha256Hex ('cmx-code-v1|' + (Format-PairInfoText $InitiatorInfo) + '|' + (Format-PairInfoText $ResponderInfo) + '|' + $InitiatorNonce + '|' + $ResponderNonce)
    $number = [Convert]::ToUInt32($hex.Substring(0, 8), 16) % 1000000
    $digits = $number.ToString('000000')
    $digits.Substring(0, 3) + ' ' + $digits.Substring(3)
}

function New-PairState([string]$Role, [string]$Sid, $Self, [string]$Address, [int]$Port) {
    @{
        Role = $Role; Sid = $Sid; Self = $Self; Peer = $null; Address = $Address; Port = $Port
        Nonce = (New-RandomHex 16); PeerNonce = $null; Commit = $null
        Stage = ''; Code = $null; LocalOk = $false; RemoteOk = $false; Error = $null
        Out = $null; Started = (Get-Date); LastSent = [datetime]::MinValue
    }
}

# This PC asks the PC at Address:Port to pair.
function New-PairInitiator($Self, [string]$Address, [int]$Port) {
    $state = New-PairState 'initiator' (New-RandomHex 8) $Self $Address $Port
    $state.Stage = 'asking'
    $state.Out = @{ t = 'pair1'; sid = $state.Sid; from = $Self }
    $state
}

# Another PC asked (pair1); only called while this PC's Otros PCs window is open.
function New-PairResponder($Self, $Msg, [string]$Address, [int]$Port) {
    $state = New-PairState 'responder' ([string]$Msg.sid) $Self $Address $Port
    $state.Peer = $Msg.from
    $state.Commit = Get-PairCommit $Msg.from $Self $state.Nonce
    $state.Stage = 'committed'
    $state.Out = @{ t = 'pair2'; sid = $state.Sid; from = $Self; commit = $state.Commit }
    $state
}

# Applies one message of this pairing to the state. Sets Out to what must be sent back ($null: nothing).
# A repeated message gets the same answer again, so a lost datagram only costs a retry.
function Step-Pairing($State, $Msg) {
    $State.Out = $null
    if ([string]$Msg.sid -ne $State.Sid -or $State.Stage -in 'failed', 'cancelled') { return }
    switch ("$($State.Role)/$($Msg.t)") {
        'initiator/pair2' {
            if ($State.Stage -ne 'asking') { return }
            if ($Msg.from.id -eq $State.Self.id) { return }
            $State.Peer = $Msg.from
            $State.Commit = [string]$Msg.commit
            $State.Stage = 'revealed'
            $State.Out = @{ t = 'pair3'; sid = $State.Sid; nonce = $State.Nonce }
        }
        'initiator/pair4' {
            if ($State.Stage -ne 'revealed') { return }
            if ((Get-PairCommit $State.Self $State.Peer ([string]$Msg.nonce)) -ne $State.Commit) {
                $State.Stage = 'failed'; $State.Error = 'commit'
                return
            }
            $State.PeerNonce = [string]$Msg.nonce
            $State.Code = Get-PairCode $State.Self $State.Peer $State.Nonce $State.PeerNonce
            $State.Stage = 'confirm'
        }
        'responder/pair1' {
            if ($State.Stage -eq 'committed') { $State.Out = @{ t = 'pair2'; sid = $State.Sid; from = $State.Self; commit = $State.Commit } }
        }
        'responder/pair3' {
            if ($State.Stage -eq 'committed') {
                $State.PeerNonce = [string]$Msg.nonce
                $State.Code = Get-PairCode $State.Peer $State.Self $State.PeerNonce $State.Nonce
                $State.Stage = 'confirm'
            } elseif ($State.Stage -notin 'confirm', 'done' -or [string]$Msg.nonce -ne $State.PeerNonce) { return }
            $State.Out = @{ t = 'pair4'; sid = $State.Sid; nonce = $State.Nonce }
        }
        { $_ -like '*/pair5' } {
            if ($State.Stage -notin 'confirm', 'done') { return }
            if (-not $Msg.ok) { $State.Stage = 'cancelled'; $State.Error = 'peer'; return }
            $State.RemoteOk = $true
            if ($State.LocalOk) {
                $State.Stage = 'done'
                # The other side may still be waiting for ours.
                $State.Out = @{ t = 'pair5'; sid = $State.Sid; ok = $true }
            }
        }
    }
}

function Confirm-Pairing($State) {
    if ($State.Stage -ne 'confirm') { return }
    $State.LocalOk = $true
    $State.Out = @{ t = 'pair5'; sid = $State.Sid; ok = $true }
    if ($State.RemoteOk) { $State.Stage = 'done' }
}

function Stop-Pairing($State) {
    $notify = $State.Stage -in 'committed', 'revealed', 'confirm'
    $State.Stage = 'cancelled'
    $State.Error = 'local'
    $State.Out = if ($notify) { @{ t = 'pair5'; sid = $State.Sid; ok = $false } } else { $null }
}

# What the waiting side sends again after a second without an answer ($null: nothing to repeat).
function Get-PairingRetry($State) {
    switch ($State.Stage) {
        'asking'   { return @{ t = 'pair1'; sid = $State.Sid; from = $State.Self } }
        'revealed' { return @{ t = 'pair3'; sid = $State.Sid; nonce = $State.Nonce } }
        'confirm'  { if ($State.LocalOk -and -not $State.RemoteOk) { return @{ t = 'pair5'; sid = $State.Sid; ok = $true } } }
    }
    $null
}

# The paired PC as saved in peers.json.
function New-PeerRecord($State) {
    [pscustomobject]@{
        id = [string]$State.Peer.id; name = [string]$State.Peer.name; user = [string]$State.Peer.user
        port = [int]$State.Peer.port; address = $State.Address
        hostKey = Get-BridgeKeyText $State.Peer.hostKey; clientKey = Get-BridgeKeyText $State.Peer.clientKey
        pairedAt = (Get-Date).ToString('o')
    }
}

# ---------------------------------------------------------------- socket

# Bound to this PC's address in the Private network (it still gets that subnet's broadcasts), not to every
# interface, so nothing listens on a Public one.
function Open-BridgeSocket([int]$Port, [string]$Address = '0.0.0.0') {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Address), $Port)))
    $udp.EnableBroadcast = $true
    # SIO_UDP_CONNRESET off: an ICMP "port unreachable" from a PC without the tray would otherwise make the
    # next Receive throw.
    [void]$udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null)
    $udp
}

# The datagrams waiting on the socket, without blocking, at most $Max per call: a flood from the network then
# costs a few milliseconds per tick instead of freezing the tray (the rest waits, or the OS drops it).
function Receive-BridgeDatagrams($Udp, [int]$Max = 64) {
    $received = @()
    $count = 0
    while ($Udp -and $Udp.Available -gt 0 -and $count -lt $Max) {
        $count++
        $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        try { $bytes = $Udp.Receive([ref]$endpoint) } catch { break }
        $msg = ConvertFrom-BridgeDatagram $bytes
        if ($msg) { $received += [pscustomobject]@{ Address = $endpoint.Address.ToString(); Port = $endpoint.Port; Message = $msg } }
    }
    $received
}

function Send-BridgeDatagram($Udp, [hashtable]$Message, [string]$Address, [int]$Port) {
    if (-not $Udp) { return }
    $bytes = ConvertTo-BridgeDatagram $Message
    try { [void]$Udp.Send($bytes, $bytes.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Address), $Port))) } catch { }
}
