# ClaudeMaxxing on the phone: the app (mobile\) pairs with this PC by scanning a QR in Celular and then talks to
# the tray over HTTPS on the home network, or from anywhere through Tailscale. No server of ours in between.
#
# lib\mobile.cs holds the server (TLS with a self-signed certificate the app pins, one HTTP request per connection)
# and the QR encoder. The requests wait in a queue that MobileTimer drains on the tray's UI thread, where the hub's
# functions live: the phone's panel is the hub's sections described as a list of items (texts, switches, choices,
# buttons, meters), already translated, so the app only draws them. An item's action is one of the scriptblocks
# this file registered while describing the section: the phone sends its id, never code.
#
# Writing to a session goes through Claude Code's cross-session inbox, a named pipe per session: the voice plugin's
# SessionStart hook (voice\hooks\on-start.ps1) leaves its path and token in mobile\inbox\<session id>.json.
# The session sees the text as a message from another session: it can steer the work, never approve a permission.
#
# Each paired phone keeps a random token; only its SHA-256 is stored (mobile\devices.json). Revoking deletes it.

$MobileHome = Join-Path $TrayHome 'mobile'
$MobileSettingsFile = Join-Path $MobileHome 'settings.json'
$MobileDevicesFile = Join-Path $MobileHome 'devices.json'
$MobileInboxDir = Join-Path $MobileHome 'inbox'
$MobileLogFile = Join-Path $MobileHome 'mobile.log'
$MobileDefaultPort = 47830
$MobilePairSeconds = 300
$MobileFirewallGroup = 'ClaudeMaxxing Celular'
$MobileReleasesUrl = 'https://github.com/SantiagoRuizM/ClaudeMaxxing/releases'
$MobilePowerLabel = Ux 'Energ\u00eda'
$MobileShutdownSeconds = 60

$script:Mobile = @{ Running = $false; Error = ''; Cert = $null; Pairing = $null; Devices = $null; Actions = @{}
    Dirty = $false; FirewallAt = [datetime]::MinValue; Firewall = $false; FirewallProcess = $null; CacheAt = [datetime]::MinValue
    TranscriptPaths = @{}; SeenSaved = [datetime]::MinValue }

function Write-MobileLog([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $MobileHome)) { New-Item -ItemType Directory -Force -Path $MobileHome | Out-Null }
        Add-Content -LiteralPath $MobileLogFile -Value ((Get-Date).ToString('s') + ' ' + $Message) -Encoding UTF8
    } catch { }
}

# lib\mobile.cs compiled once into $BinDir, like lib\snip.cs.
function Initialize-MobileNative {
    if ('ClaudeTray.MobileGate' -as [type]) { return }
    $source = [IO.File]::ReadAllText((Join-Path $TrayRoot 'lib\mobile.cs'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source))[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $BinDir "ClaudeMobile-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
        $tmp = Join-Path $BinDir "ClaudeMobile-$hash-$PID.dll"
        Add-Type -TypeDefinition $source -ReferencedAssemblies System.Core -OutputAssembly $tmp -OutputType Library
        try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $BinDir -Filter 'ClaudeMobile-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    Add-Type -Path $dll
}

# ---------------------------------------------------------------- settings and devices

function Get-MobileSettings([string]$Path = $MobileSettingsFile) {
    $saved = Read-JsonFile $Path
    $port = if ($saved -and [int]$saved.port -ge 1024 -and [int]$saved.port -le 65535) { [int]$saved.port } else { $MobileDefaultPort }
    [pscustomobject]@{ Enabled = [bool]($saved -and $saved.enabled); Port = $port; Thumbprint = $(if ($saved) { [string]$saved.thumbprint } else { '' }) }
}

function Save-MobileSettings($Settings, [string]$Path = $MobileSettingsFile) {
    Write-JsonFile $Path ([ordered]@{ enabled = [bool]$Settings.Enabled; port = [int]$Settings.Port; thumbprint = [string]$Settings.Thumbprint })
}

function Read-MobileDevices([string]$Path = $MobileDevicesFile) {
    @(Read-JsonFile $Path | Where-Object { $_ -and $_.id -and $_.tokenHash })
}

function Write-MobileDevices($Devices, [string]$Path = $MobileDevicesFile) { Write-JsonFile $Path @($Devices | Where-Object { $_ }) }

function Get-MobileDevices {
    if ($null -eq $script:Mobile.Devices) { $script:Mobile.Devices = @(Read-MobileDevices) }
    $script:Mobile.Devices
}

# The device a bearer token belongs to, or $null.
function Find-MobileDevice($Devices, [string]$Token) {
    if (-not $Token -or $Token.Length -lt 32) { return $null }
    $hash = Get-Sha256Hex $Token
    @($Devices | Where-Object { $_.tokenHash -eq $hash })[0]
}

function Remove-MobileDevice([string]$Id) {
    $script:Mobile.Devices = @(Get-MobileDevices | Where-Object { $_.id -ne $Id })
    Write-MobileDevices $script:Mobile.Devices
    $script:Mobile.Dirty = $true
    Write-MobileLog "revoked $Id"
}

# ---------------------------------------------------------------- pairing

# A one-time code for the QR, good for $MobilePairSeconds and 5 wrong tries.
function New-MobilePairing([datetime]$Now = (Get-Date)) {
    @{ Code = (New-RandomHex 8); Until = $Now.AddSeconds($MobilePairSeconds); Tries = 0 }
}

# 'ok', or why the code was refused: 'none', 'expired', 'wrong'. A wrong code counts a try; the fifth ends the pairing.
function Test-MobilePairCode($Pairing, [string]$Code, [datetime]$Now = (Get-Date)) {
    if (-not $Pairing) { return 'none' }
    if ($Now -gt $Pairing.Until -or $Pairing.Tries -ge 5) { return 'expired' }
    if ($Code -cne $Pairing.Code) { $Pairing.Tries++; return 'wrong' }
    'ok'
}

# The addresses the phone can try, most likely first: private networks Windows knows (Otros PCs' list), Tailscale,
# then any other private address. At most 4.
function Get-MobileHosts {
    $hosts = New-Object System.Collections.Generic.List[string]
    try { foreach ($n in @(Get-BridgeNetworks)) { if (-not $hosts.Contains($n.Address)) { $hosts.Add($n.Address) } } } catch { }
    $others = @()
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        # Hyper-V and WSL switches are on no network a phone is on.
        if ($nic.Description -match 'Hyper-V|WSL' -or $nic.Name -like 'vEthernet*') { continue }
        foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
            if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
            $a = $u.Address.ToString()
            if ($hosts.Contains($a) -or -not [ClaudeTray.MobileGate]::IsAllowed($u.Address) -or $a.StartsWith('169.254.')) { continue }
            $b = $u.Address.GetAddressBytes()
            if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { $hosts.Add($a) } else { $others += $a }
        }
    }
    foreach ($a in $others) { if (-not $hosts.Contains($a)) { $hosts.Add($a) } }
    @($hosts | Select-Object -First 4)
}

function Format-MobilePairUri([string[]]$Hosts, [int]$Port, [string]$Fingerprint, [string]$Code, [string]$Name) {
    'cmx://pair?h=' + ($Hosts -join ',') + "&p=$Port&f=$Fingerprint&c=$Code&n=" + [uri]::EscapeDataString($Name)
}

function Start-MobilePairing {
    $script:Mobile.Pairing = New-MobilePairing
    $script:Mobile.Dirty = $true
}

function Stop-MobilePairing { $script:Mobile.Pairing = $null; $script:Mobile.Dirty = $true }

function Get-MobilePairUri {
    $p = $script:Mobile.Pairing
    if (-not $p -or -not $script:Mobile.Cert) { return '' }
    Format-MobilePairUri (Get-MobileHosts) (Get-MobileSettings).Port (Get-MobileFingerprint $script:Mobile.Cert) $p.Code $env:COMPUTERNAME
}

# ---------------------------------------------------------------- certificate, firewall, server

function Get-MobileFingerprint($Cert) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Cert.RawData) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

# This PC's certificate for the phone (CurrentUser\My, no admin), made on first use and again when it expires.
function Get-MobileCertificate($Settings) {
    if ($Settings.Thumbprint) {
        $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($Settings.Thumbprint)" -ErrorAction SilentlyContinue
        if ($cert -and $cert.HasPrivateKey -and $cert.NotAfter -gt (Get-Date).AddDays(30)) { return $cert }
    }
    $cert = New-SelfSignedCertificate -Subject "CN=ClaudeMaxxing $env:COMPUTERNAME" -FriendlyName 'ClaudeMaxxing (Celular)' `
        -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(10) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1')
    $Settings.Thumbprint = $cert.Thumbprint
    Save-MobileSettings $Settings
    # A new certificate changes the fingerprint every paired phone pinned: they pair again.
    if (@(Get-MobileDevices).Count) { $script:Mobile.Devices = @(); Write-MobileDevices @() }
    Write-MobileLog "new certificate $($cert.Thumbprint)"
    $cert
}

function Test-MobileFirewall([int]$Port) {
    $rules = @(Get-NetFirewallRule -Group $MobileFirewallGroup -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
    if (-not $rules.Count) { return $false }
    $ports = @($rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.LocalPort })
    $ports -contains "$Port"
}

# Inbound TCP to the tray's PowerShell on the port: Private and Domain networks, from the local subnet or Tailscale.
function Get-MobileFirewallScript([int]$Port) {
    $q = { param($s) "'" + $s.Replace("'", "''") + "'" }
    @(
        "Remove-NetFirewallRule -Group $(& $q $MobileFirewallGroup) -ErrorAction SilentlyContinue"
        "New-NetFirewallRule -DisplayName 'ClaudeMaxxing - app del celular (TCP $Port)' -Group $(& $q $MobileFirewallGroup) -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program $(& $q $BridgePowerShell) -Profile Private,Domain -RemoteAddress LocalSubnet,100.64.0.0/10 | Out-Null"
    ) -join "`n"
}

function Get-MobileFirewallRemovalScript { "Remove-NetFirewallRule -Group '$MobileFirewallGroup' -ErrorAction SilentlyContinue" }

# Get-NetFirewallRule goes through WMI: asked again at most every 20 seconds.
function Update-MobileFirewallState([switch]$Force) {
    if (-not $Force -and ((Get-Date) - $script:Mobile.FirewallAt).TotalSeconds -lt 20) { return }
    $script:Mobile.FirewallAt = Get-Date
    try { $script:Mobile.Firewall = Test-MobileFirewall (Get-MobileSettings).Port } catch { $script:Mobile.Firewall = $false }
}

function Start-MobileServer {
    $settings = Get-MobileSettings
    Initialize-MobileNative
    $script:Mobile.Cert = Get-MobileCertificate $settings
    [ClaudeTray.MobileGate]::Start($settings.Port, $script:Mobile.Cert)
    $script:Mobile.Running = $true
    $script:Mobile.Error = ''
    Write-MobileLog "listening on $($settings.Port)"
}

function Stop-MobileServer {
    if ('ClaudeTray.MobileGate' -as [type]) { [ClaudeTray.MobileGate]::Stop() }
    if ($script:Mobile.Running) { Write-MobileLog 'stopped' }
    $script:Mobile.Running = $false
    $script:Mobile.Pairing = $null
}

# On when switched on and the company policy allows it; called at start and after every change.
function Update-MobileServer {
    $want = (Get-MobileSettings).Enabled -and (Test-HubModule 'mobile')
    if ($want -and -not $script:Mobile.Running) {
        try { Start-MobileServer } catch { $script:Mobile.Error = $_.Exception.Message; $script:Mobile.Running = $false; Write-MobileLog "start: $($script:Mobile.Error)" }
    } elseif (-not $want -and $script:Mobile.Running) { Stop-MobileServer }
    $script:Mobile.Dirty = $true
}

function Set-MobileEnabled([bool]$On) {
    $settings = Get-MobileSettings
    $settings.Enabled = $On
    Save-MobileSettings $settings
    Update-MobileServer
    if ($On) {
        Update-MobileFirewallState -Force
        # One UAC prompt; the tray does not wait for it (Start-Elevated), the hub shows the rule once it exists.
        if (-not $script:Mobile.Firewall -and -not $script:Mobile.FirewallProcess) { $script:Mobile.FirewallProcess = Start-Elevated (Get-MobileFirewallScript $settings.Port) }
        if ($script:Mobile.Running -and -not @(Get-MobileDevices).Count) { Start-MobilePairing }
    }
}

# ---------------------------------------------------------------- requests

$script:MobileTimer = $null

function Start-MobileTimer {
    if ($script:MobileTimer) { return }
    $script:MobileTimer = New-Object System.Windows.Forms.Timer
    $script:MobileTimer.Interval = 150
    $script:MobileTimer.Add_Tick({ Invoke-MobileTick })
    $script:MobileTimer.Start()
}

function Stop-MobileTimer {
    if ($script:MobileTimer) { $script:MobileTimer.Stop(); $script:MobileTimer.Dispose(); $script:MobileTimer = $null }
    Stop-MobileServer
    # The tray quitting while dark: give the brightness back.
    try { Stop-MobileDarkScreen } catch { }
}

function Invoke-MobileTick {
    $p = $script:Mobile.FirewallProcess
    if ($p -and $p.HasExited) { $script:Mobile.FirewallProcess = $null; Update-MobileFirewallState -Force; $script:Mobile.Dirty = $true }
    if ($script:Mobile.Pairing -and (Get-Date) -gt $script:Mobile.Pairing.Until) { Stop-MobilePairing }
    if (-not $script:Mobile.Running) { return }
    for ($i = 0; $i -lt 8; $i++) {
        $request = [ClaudeTray.MobileGate]::Next()
        if (-not $request) { break }
        try {
            $answer = Invoke-MobileRequest $request
            $request.Answer([int]$answer.Status, (ConvertTo-Json -InputObject $answer.Body -Depth 10 -Compress))
        } catch {
            Write-MobileLog "$($request.Method) $($request.Path): $($_.Exception.Message)"
            $request.Answer(500, (ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Compress))
        }
    }
    if ($script:Mobile.Dirty) {
        $script:Mobile.Dirty = $false
        if ($script:HubDialog -and $script:Hub.Section -eq 'mobile') { $script:HubDialog.Invalidate() }
    }
}

function ConvertFrom-MobileQuery([string]$Query) {
    $result = @{}
    foreach ($pair in ($Query -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $result[[uri]::UnescapeDataString($kv[0])] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
    }
    $result
}

function New-MobileAnswer([int]$Status, $Body) { @{ Status = $Status; Body = $Body } }

# One request: its status and the object to send as JSON. Everything but /info and /pair needs a paired device.
function Invoke-MobileRequest($Request) {
    $route = "$($Request.Method) $($Request.Path)"
    $query = ConvertFrom-MobileQuery $Request.Query
    # A body is parsed only for /pair (1 MB at most) or once the token checked out.
    $body = $null
    $badJson = New-MobileAnswer 400 @{ error = 'bad json' }
    if ($route -eq 'GET /info') { return New-MobileAnswer 200 @{ app = 'ClaudeMaxxing'; pc = $env:COMPUTERNAME } }
    if ($route -eq 'POST /pair') {
        if ($Request.Body) { try { $body = $Request.Body | ConvertFrom-Json } catch { return $badJson } }
        return Invoke-MobilePair $body $Request.Remote
    }

    $devices = Get-MobileDevices
    $device = Find-MobileDevice $devices $Request.Token
    if (-not $device) { return New-MobileAnswer 401 @{ error = 'not paired' } }
    $device.lastSeen = (Get-Date).ToString('o')
    $device.address = $Request.Remote
    if (((Get-Date) - $script:Mobile.SeenSaved).TotalSeconds -ge 60) { $script:Mobile.SeenSaved = Get-Date; Write-MobileDevices $devices; $script:Mobile.Dirty = $true }
    if ($Request.Body) { try { $body = $Request.Body | ConvertFrom-Json } catch { return $badJson } }

    switch ($route) {
        'GET /eggs'     { return Get-MobileEggsAnswer ([string]$query['color']) }
        'POST /upload'  { return Save-MobileUpload ([string]$query['session']) ([string]$query['name']) ([string]$query['caption']) $Request.BodyBytes }
        'GET /state'    { return New-MobileAnswer 200 (Get-MobilePanelState) }
        'GET /section'  { return New-MobileAnswer 200 (Get-MobileSection ([string]$query['id'])) }
        'POST /action'  { return Invoke-MobileAction ([string]$body.section) ([string]$body.id) $body.arg }
        'GET /messages' {
            $after = -1L
            [void][long]::TryParse([string]$query['after'], [ref]$after)
            return Get-MobileMessagesAnswer ([string]$query['session']) $after
        }
        'POST /prompt'  { return Send-MobilePrompt ([string]$body.session) ([string]$body.text) }
        'GET /voices'   { return New-MobileAnswer 200 @{ voices = @(Get-MobileVoices ([string]$query['after'])) } }
        'GET /voice'    { return Get-MobileVoiceAnswer ([string]$query['id']) }
        'POST /unpair'  { Remove-MobileDevice $device.id; return New-MobileAnswer 200 @{ ok = $true } }
    }
    New-MobileAnswer 404 @{ error = 'unknown route' }
}

# The eggs of the tray for one session color, drawn by the tray's own functions (lib\traysessions.ps1): still, the
# 9 frames of thinking and the 8 of speaking, as PNG in base64, and the tray's 120 ms per frame. Cached per color.
function Get-MobileEggsAnswer([string]$Hex) {
    if ($Hex -notmatch '^#[0-9a-fA-F]{6}$') { return New-MobileAnswer 400 @{ error = 'bad color' } }
    if (-not $script:Mobile.Eggs) { $script:Mobile.Eggs = @{} }
    $key = $Hex.ToLowerInvariant()
    if (-not $script:Mobile.Eggs.ContainsKey($key)) {
        $size = 96
        $png = { param($Bitmap) $ms = New-Object IO.MemoryStream; $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $Bitmap.Dispose(); [Convert]::ToBase64String($ms.ToArray()) }
        $script:Mobile.Eggs[$key] = [ordered]@{
            interval = 120
            still    = (& $png (New-SessionIconBitmap $Hex $size))
            thinking = @(for ($f = 0; $f -lt (Get-EggFrameCount); $f++) { & $png (New-SessionIconBitmap $Hex $size $f) })
            speaking = @(for ($f = 0; $f -lt $script:SpeakFrameCount; $f++) { & $png (New-SpeakingIconBitmap $Hex $size $f) })
        }
    }
    New-MobileAnswer 200 $script:Mobile.Eggs[$key]
}

# A name safe to keep on disk: letters, digits, dot, dash and underscore, at most 80 characters, its extension kept.
function Get-MobileSafeName([string]$Name) {
    $leaf = [IO.Path]::GetFileName($Name)
    $safe = ($leaf -replace '[^A-Za-z0-9._-]', '_').Trim('.', '_')
    if (-not $safe) { $safe = 'file' }
    if ($safe.Length -gt 80) { $ext = [IO.Path]::GetExtension($safe); $safe = $safe.Substring(0, 80 - $ext.Length) + $ext }
    $safe
}

# The message for an upload: the caption, then one line the app shows as the attachment.
function Format-MobileUploadText([string]$Caption, [string]$Path) {
    $line = "$MobileAttachMark $Path"
    if ($Caption.Trim()) { $Caption.Trim() + "`n" + $line } else { $line }
}

# A photo, audio or document from the phone: kept in mobile\uploads\<session>, and its path sent to the session with
# the caption, as Snip sends its pictures.
function Save-MobileUpload([string]$SessionId, [string]$Name, [string]$Caption, [byte[]]$Bytes) {
    if (-not (Test-MobileSessionId $SessionId)) { return New-MobileAnswer 400 @{ error = 'bad session' } }
    if (-not $Bytes -or -not $Bytes.Length) { return New-MobileAnswer 400 @{ error = 'empty file' } }
    if (-not (Test-Path -LiteralPath (Join-Path $MobileInboxDir "$SessionId.json"))) { return New-MobileAnswer 409 @{ error = (Tx 'Esa sesi\u00f3n no recibe mensajes: \u00e1brela de nuevo desde el men\u00fa.') } }
    $dir = Join-Path (Join-Path $MobileHome 'uploads') $SessionId
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir ((Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + (Get-MobileSafeName $Name))
    [IO.File]::WriteAllBytes($path, $Bytes)
    Write-MobileLog "upload $($Bytes.Length) bytes for ${SessionId}: $path"
    Send-MobilePrompt $SessionId (Format-MobileUploadText $Caption $path)
}

function Invoke-MobilePair($Body, [string]$Remote) {
    $verdict = Test-MobilePairCode $script:Mobile.Pairing ([string]$Body.code)
    if ($verdict -ne 'ok') { Write-MobileLog "pair refused ($verdict) from $Remote"; $script:Mobile.Dirty = $true; return New-MobileAnswer 401 @{ error = $verdict } }
    $token = New-RandomHex 32
    $name = ([string]$Body.device).Trim()
    if (-not $name -or $name.Length -gt 60) { $name = L 'Celular' }
    $device = [pscustomobject]@{ id = (New-RandomHex 6); name = $name; tokenHash = (Get-Sha256Hex $token)
        pairedAt = (Get-Date).ToString('o'); lastSeen = (Get-Date).ToString('o'); address = $Remote }
    $script:Mobile.Devices = @(@(Get-MobileDevices) + $device)
    Write-MobileDevices $script:Mobile.Devices
    $script:Mobile.Pairing = $null
    $script:Mobile.Dirty = $true
    Write-MobileLog "paired $($device.id) '$name' from $Remote"
    New-MobileAnswer 200 @{ token = $token; device = $device.id; pc = $env:COMPUTERNAME }
}

# ---------------------------------------------------------------- the hub's data without its window

# The hub's functions keep their data in $script:Hub; with the window never opened the phone gets its own.
function Initialize-MobileHub {
    if (-not $script:Hub) {
        $script:Hub = @{ Section = 'home'; Cache = @{}; SlowAt = [datetime]::MinValue; Message = ''; MessageAt = [datetime]::MinValue
            Preview = $false; Timer = $null; Error = ''; StatsTab = 'summary'; StatsRange = 'recent'; StatsError = ''; PlanPreview = ''
            EnvsPreview = ''; W = 0; H = 0; Zoom = 1.0; FullScale = 1.0; Normal = $null; CodeHelp = $false; Visits = $null; SkillsTab = 'installed' }
    }
    if (-not $script:Hub.Languages) { try { $script:Hub.Languages = Get-UiLanguages } catch { } }
    # The window refreshes every 2 seconds; the phone's requests do not refresh more often than that.
    if (-not $script:HubDialog -and ((Get-Date) - $script:Mobile.CacheAt).TotalSeconds -ge 2) {
        $script:Mobile.CacheAt = Get-Date
        try { Update-HubCache -Full:($script:Hub.Cache.Count -eq 0) } catch { }
    }
}

# After /clear a window holds a new conversation (new id, transcript and voice name), but sessions.json keeps the id
# it was opened with. The voice's turn-<that key> (Save-SessionTurn) points at the current transcript, <id>.jsonl.
function Get-MobileCurrentSessionId([string]$Id) {
    $turn = Read-JsonFile (Join-Path $VoiceStateDir ('turn-' + (Get-HubSessionKey $Id)))
    $current = if ($turn -and $turn.transcript) { [IO.Path]::GetFileNameWithoutExtension([string]$turn.transcript) } else { '' }
    if (Test-MobileSessionId $current) { $current } else { $Id }
}

# The sessions open from the menu, as the phone swipes through them.
function Get-MobileSessions {
    $eggs = Read-JsonFile (Join-Path $TrayHome 'eggs.json')
    $list = foreach ($r in @(Read-JsonFile $SessionsFile | Where-Object { $_ -and $_.sessionId })) {
        $hwnd = [long]$r.hwnd
        if (-not ($hwnd -ne 0 -and [ClaudeTray.Native]::IsWindow([IntPtr]$hwnd))) { continue }
        $first = [string]$r.sessionId
        $id = Get-MobileCurrentSessionId $first
        $voice = Read-JsonFile (Join-Path $VoiceStateDir ('name-' + (Get-HubSessionKey $id)))
        $state = if ($eggs -and $eggs.PSObject.Properties[$first]) { [string]$eggs.$first } else { 'idle' }
        $name = if ($voice -and $voice.name) { [string]$voice.name } elseif ($r.name) { [string]$r.name } else { (L 'Ventana {0}') -f ([int]$r.slot + 1) }
        [ordered]@{ id = $id; slot = [int]$r.slot; name = $name
            role = $(if ($voice) { [string]$voice.role } else { '' }); color = (Get-HubSlotHex ([string]$r.color)); dir = [string]$r.dir
            folder = (Split-Path -Leaf ([string]$r.dir)); state = $state; canWrite = (Test-Path -LiteralPath (Join-Path $MobileInboxDir "$id.json")) }
    }
    , @($list | Sort-Object { $_.slot })
}

function Get-MobileWindow($Window) {
    if (-not $Window) { return $null }
    $now = Get-Date
    [ordered]@{ percent = $(if ($Window.Active) { [int]$Window.Percent } else { 0 }); active = [bool]$Window.Active
        reset = $(if ($Window.Active) { (L 'Se renueva en ') + (Format-Remaining ($Window.ResetsAt - $now)) } else { L 'Sin empezar' }) }
}

# What the app polls: the PC, the plan, the sections of the side menu and the open sessions.
function Get-MobileState {
    Initialize-MobileHub
    $view = $script:View
    $sections = @(Get-HubVisibleSections | ForEach-Object { [ordered]@{ id = $_.Id; label = (L $_.Label) } })
    $sections += [ordered]@{ id = 'settings'; label = (L (Ux 'Configuraci\u00f3n')) }
    # Only on the phone: the dark screen and the shutdown, first so it is at hand when leaving.
    $sections = @([ordered]@{ id = 'power'; label = (L $MobilePowerLabel) }) + $sections
    [ordered]@{
        pc = $env:COMPUTERNAME; language = [string]$script:UiLanguage
        plan = [ordered]@{ session = (Get-MobileWindow $(if ($view -and $view.HasData) { $view.Session })); weekly = (Get-MobileWindow $(if ($view -and $view.HasData) { $view.Weekly })) }
        sections = @($sections | Where-Object { $_.id -ne 'self' } | Group-Object { $_.id } | ForEach-Object { $_.Group[0] })
        sessions = (Get-MobileSessions)
    }
}

# /state: the state and, first in the panel, the Nueva sesion of Claude Code (registered under code, so after a tray
# restart the action is found again by describing that section).
function Get-MobilePanelState {
    $state = Get-MobileState
    $script:MobileSection = 'code'
    $state.newSession = Get-MobileNewSessionItem
    $state
}

# ---------------------------------------------------------------- sessions: transcript and prompt

function Test-MobileSessionId([string]$Id) { $Id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }

# ~/.claude/projects/<folder with every non-alphanumeric turned into ->/<id>.jsonl, else found by name.
function Get-MobileTranscriptPath([string]$SessionId, [string]$Dir) {
    $cached = $script:Mobile.TranscriptPaths[$SessionId]
    if ($cached -and (Test-Path -LiteralPath $cached)) { return $cached }
    $projects = Join-Path $env:USERPROFILE '.claude\projects'
    $path = $null
    if ($Dir) {
        $guess = Join-Path (Join-Path $projects ($Dir -replace '[^A-Za-z0-9]', '-')) "$SessionId.jsonl"
        if (Test-Path -LiteralPath $guess) { $path = $guess }
    }
    if (-not $path -and (Test-Path -LiteralPath $projects)) {
        foreach ($folder in Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $folder.FullName "$SessionId.jsonl"
            if (Test-Path -LiteralPath $candidate) { $path = $candidate; break }
        }
    }
    if ($path) { $script:Mobile.TranscriptPaths[$SessionId] = $path }
    $path
}

# The complete lines of a transcript from byte $After (-1: the last $TailBytes), and where the next read starts.
function Read-MobileTranscript([string]$Path, [long]$After, [int]$TailBytes = 524288, [int]$MaxBytes = 2097152) {
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $length = $stream.Length
        $reset = $After -lt 0 -or $After -gt $length
        $start = if ($reset) { [Math]::Max(0L, $length - $TailBytes) } else { $After }
        if ($length - $start -gt $MaxBytes) { $start = $length - $MaxBytes; $reset = $true }
        $count = [int]($length - $start)
        $buffer = New-Object byte[] $count
        [void]$stream.Seek($start, 'Begin')
        $read = 0
        while ($read -lt $count) { $n = $stream.Read($buffer, $read, $count - $read); if ($n -le 0) { break }; $read += $n }
    } finally { $stream.Dispose() }
    $end = [Array]::LastIndexOf($buffer, [byte]10, [Math]::Max(0, $read - 1))
    if ($read -eq 0 -or $end -lt 0) { return [pscustomobject]@{ Lines = @(); Offset = $start; Reset = $reset } }
    $lines = @([System.Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1) -split "`n" | Where-Object { $_.Trim() })
    # Started mid-file: the first line is a piece of one.
    if ($reset -and $start -gt 0 -and $lines.Count) { $lines = @($lines | Select-Object -Skip 1) }
    [pscustomobject]@{ Lines = $lines; Offset = $start + $end + 1; Reset = $reset }
}

function Format-MobileToolLine($Tool) {
    $in = $Tool.input
    $detail = ''
    if ($in) {
        foreach ($name in 'description', 'command', 'file_path', 'pattern', 'url', 'query', 'prompt') {
            if ($in.PSObject.Properties[$name] -and "$($in.$name)") { $detail = "$($in.$name)"; break }
        }
    }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 140) { $detail = $detail.Substring(0, 139) + [char]0x2026 }
    if ($detail) { "$($Tool.name): $detail" } else { [string]$Tool.name }
}

function Limit-MobileText([string]$Text, [int]$Max = 6000) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + [char]0x2026
}

# The chat items of one transcript line: what the user wrote, Claude's text and one line per tool. Meta lines,
# tool results and thinking are left out.
$MobilePromptMark = "(ClaudeMaxxing app, from the user's phone)"
$MobileAttachMark = '[phone attachment]'

# What a session received from another one, without Claude Code's wrapper around it: the user's when it carries the
# phone's mark, else a line saying another session wrote.
function Get-MobilePeerText([string]$Content) {
    $text = $Content
    $start = $text.IndexOf("sent a message:`n")
    if ($start -ge 0) { $text = $text.Substring($start + 16) }
    $end = $text.IndexOf("`n`nThis came from another Claude session")
    if ($end -ge 0) { $text = $text.Substring(0, $end) }
    $text = $text.Trim()
    if (-not $text) { return $null }
    if ($text.StartsWith($MobilePromptMark)) { return @{ Role = 'user'; Text = $text.Substring($MobilePromptMark.Length).Trim() } }
    @{ Role = 'tool'; Text = (Tx 'Mensaje de otra sesi\u00f3n: ') + $text }
}

function ConvertFrom-MobileTranscriptLine([string]$Line) {
    if ($Line.Length -gt 262144 -or -not ($Line.Contains('"type":"user"') -or $Line.Contains('"type":"assistant"'))) { return }
    try { $o = $Line | ConvertFrom-Json } catch { return }
    if ($o.isSidechain -or -not $o.message) { return }
    # A message from another session (the phone's arrive that way) is a meta line with origin.kind peer.
    if ($o.isMeta) {
        if (-not ($o.origin -and $o.origin.kind -eq 'peer' -and $o.message.content -is [string])) { return }
        $peer = Get-MobilePeerText $o.message.content
        if ($peer) { [ordered]@{ role = $peer.Role; text = (Limit-MobileText $peer.Text); at = [string]$o.timestamp } }
        return
    }
    $at = [string]$o.timestamp
    $content = $o.message.content
    if ($o.type -eq 'user') {
        $texts = if ($content -is [string]) { @($content) } else { @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) }
        foreach ($t in $texts) {
            $t = $t.Trim()
            if (-not $t -or $t.StartsWith('<local-command') -or $t.StartsWith('<system-reminder>') -or $t.StartsWith('[Request interrupted')) { continue }
            if ($t -match '^<command-name>(/[^<]*)</command-name>') { $t = $Matches[1] + $(if ($t -match '<command-args>([^<]*)</command-args>' -and $Matches[1]) { ' ' + $Matches[1] } else { '' }) }
            [ordered]@{ role = 'user'; text = (Limit-MobileText $t); at = $at }
        }
    } elseif ($o.type -eq 'assistant') {
        foreach ($part in @($content)) {
            if ($part.type -eq 'text' -and "$($part.text)".Trim()) { [ordered]@{ role = 'assistant'; text = (Limit-MobileText "$($part.text)".Trim()); at = $at } }
            elseif ($part.type -eq 'tool_use') { [ordered]@{ role = 'tool'; text = (Format-MobileToolLine $part); at = $at } }
        }
    }
}

function Get-MobileMessagesAnswer([string]$SessionId, [long]$After) {
    if (-not (Test-MobileSessionId $SessionId)) { return New-MobileAnswer 400 @{ error = 'bad session' } }
    $record = @(Read-JsonFile $SessionsFile | Where-Object { $_ -and $_.sessionId -and (Get-MobileCurrentSessionId ([string]$_.sessionId)) -eq $SessionId })[0]
    if (-not $record) { return New-MobileAnswer 404 @{ error = 'unknown session' } }
    $path = Get-MobileTranscriptPath $SessionId ([string]$record.dir)
    if (-not $path) { return New-MobileAnswer 200 @{ offset = 0; reset = $true; items = @() } }
    $chunk = Read-MobileTranscript $path $After
    $items = @(foreach ($line in $chunk.Lines) { ConvertFrom-MobileTranscriptLine $line })
    if ($chunk.Reset -and $items.Count -gt 80) { $items = @($items | Select-Object -Last 80) }
    New-MobileAnswer 200 @{ offset = $chunk.Offset; reset = $chunk.Reset; items = $items }
}

# ---------------------------------------------------------------- sessions: what the voice said

# The voice's history (voice\hooks\common.ps1, Add-History): <yyyyMMdd-HHmmss-fff>-<session>.json and its .mp3, the
# last 100 of all sessions (historySize). The phone keeps its own copy, so it can play them after the PC drops them.
$MobileVoiceDir = Join-Path $env:TEMP 'claude-voice\history'  # $VoiceStateDir of lib\hub.ps1, which this file does not need
$MobileVoiceIdPattern = '^\d{8}-\d{6}-\d{3}-[A-Za-z0-9-]{1,64}$'

# The spoken lines with audio newer than $After (an id; the ids sort by time), oldest first: id, at (with the PC's
# offset), session, name and text.
function Get-MobileVoices([string]$After, [string]$Dir = $MobileVoiceDir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $id = $file.BaseName
        if ($id -notmatch $MobileVoiceIdPattern -or ($After -and [string]::CompareOrdinal($id, $After) -le 0)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Dir "$id.mp3"))) { continue }
        $entry = Read-JsonFile $file.FullName
        if (-not $entry) { continue }
        $at = try { ([datetimeoffset][datetime]::Parse([string]$entry.time, [Globalization.CultureInfo]::InvariantCulture)).ToString("yyyy-MM-dd'T'HH:mm:sszzz") } catch { '' }
        [ordered]@{ id = $id; at = $at; session = [string]$entry.session; name = [string]$entry.name; text = [string]$entry.text }
    }
}

# One spoken line's audio, as base64 (an mp3 of a sentence is tens of KB).
function Get-MobileVoiceAnswer([string]$Id, [string]$Dir = $MobileVoiceDir) {
    if ($Id -notmatch $MobileVoiceIdPattern) { return New-MobileAnswer 400 @{ error = 'bad id' } }
    $path = Join-Path $Dir "$Id.mp3"
    if (-not (Test-Path -LiteralPath $path)) { return New-MobileAnswer 404 @{ error = 'gone' } }
    New-MobileAnswer 200 @{ id = $Id; mime = 'audio/mpeg'; audio = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
}

# The two lines Claude Code's inbox takes: who is writing (the session's token), then the message.
function Format-MobileInboxLines([string]$Token, [string]$Text) {
    $auth = ConvertTo-Json -InputObject ([ordered]@{ type = 'auth'; token = $Token }) -Compress
    $message = ConvertTo-Json -InputObject ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = $Text } }) -Compress -Depth 4
    , @($auth, $message)
}

function Send-MobilePrompt([string]$SessionId, [string]$Text) {
    if (-not (Test-MobileSessionId $SessionId)) { return New-MobileAnswer 400 @{ error = 'bad session' } }
    $Text = $Text.Trim()
    if (-not $Text -or $Text.Length -gt 8000) { return New-MobileAnswer 400 @{ error = 'empty or too long' } }
    $inbox = Read-JsonFile (Join-Path $MobileInboxDir "$SessionId.json")
    if (-not $inbox -or -not $inbox.socket -or -not $inbox.token) { return New-MobileAnswer 409 @{ error = (Tx 'Esa sesi\u00f3n no recibe mensajes: \u00e1brela de nuevo desde el men\u00fa.') } }
    $lines = Format-MobileInboxLines ([string]$inbox.token) ("$MobilePromptMark " + $Text)
    try { [ClaudeTray.MobileGate]::SendToInbox([string]$inbox.socket, $lines[0], $lines[1]) }
    catch { Write-MobileLog "prompt to ${SessionId}: $($_.Exception.Message)"; return New-MobileAnswer 409 @{ error = (Tx 'La sesi\u00f3n no responde: puede que se haya cerrado.') } }
    New-MobileAnswer 200 @{ ok = $true }
}

# ---------------------------------------------------------------- the panel: sections as items

$script:MobileSection = ''

function Register-MobileAction([string]$Id, [scriptblock]$Action) {
    $script:Mobile.Actions["$($script:MobileSection)/$Id"] = $Action
    $Id
}

function MText([string]$Text, [string]$Tone = '') { [ordered]@{ t = 'text'; text = (L $Text); tone = $Tone } }
function MCaption([string]$Text, [string]$Right = '') { [ordered]@{ t = 'caption'; text = (L $Text); right = (L $Right) } }
function MRow([string]$Label, [string]$Sub = '', [string]$Right = '', [string]$Color = '', [string]$Tone = '') {
    [ordered]@{ t = 'row'; label = (L $Label); sub = (L $Sub); right = $Right; color = $Color; tone = $Tone }
}
function MMeter([string]$Label, $Window) {
    [ordered]@{ t = 'meter'; label = (L $Label); percent = $(if ($Window) { $Window.percent } else { $null }); sub = $(if ($Window) { $Window.reset } else { (Tx 'Sin datos todav\u00eda') }) }
}
# $Confirm: the question the app asks before sending the action (the PC asks nothing then: nobody may be at it).
function MSwitch([string]$Id, [string]$Label, [string]$Sub, [bool]$On, [scriptblock]$Action, [bool]$Enabled = $true, [string]$Confirm = '') {
    [ordered]@{ t = 'switch'; id = (Register-MobileAction $Id $Action); label = (L $Label); sub = (L $Sub); on = $On; enabled = $Enabled; confirm = $Confirm }
}
function MButton([string]$Id, [string]$Label, [scriptblock]$Action, [switch]$Accent, [switch]$OnPc, [string]$Confirm = '') {
    [ordered]@{ t = 'button'; id = (Register-MobileAction $Id $Action); label = (L $Label); accent = [bool]$Accent; pc = [bool]$OnPc; confirm = $Confirm }
}
# A dropdown of the hub: $Command takes a step (-1, +1...), as Draw-HubDropdown calls it; the app sends the step.
function MChoice([string]$Id, [string]$Label, $Options, [string]$Current, [string]$Command, [bool]$Enabled = $true) {
    $list = @(foreach ($key in $Options.Keys) { [ordered]@{ k = [string]$key; label = (L ([string]$Options[$key])) } })
    [ordered]@{ t = 'choice'; id = (Register-MobileAction $Id ([scriptblock]::Create("param([int]`$Step) $Command `$Step"))); label = (L $Label)
        options = $list; current = $Current; enabled = $Enabled }
}
function MOpenOnPc([string]$Section) { MButton 'open-pc' (L 'Abrir en el PC') ([scriptblock]::Create("Show-HubDialog '$Section'")) -OnPc }

function Get-MobileSection([string]$Id) {
    Initialize-MobileHub
    $script:MobileSection = $Id
    $visible = @(@(Get-HubVisibleSections | ForEach-Object { $_.Id }) + 'settings' + 'power')
    if ($visible -notcontains $Id) { return [ordered]@{ id = $Id; title = ''; items = @(MText (Tx 'Esta parte no est\u00e1 disponible en este PC.') 'warn') } }
    $title = if ($Id -eq 'power') { L $MobilePowerLabel } else { L (@($script:HubSections | Where-Object { $_.Id -eq $Id })[0]).Label }
    $items = try {
        switch ($Id) {
            'power'    { Get-MobilePowerItems }
            'home'     { Get-MobileHomeItems }
            'business' { Get-MobileBusinessItems }
            'plan'     { Get-MobilePlanItems }
            'usage'    { Get-MobileUsageItems }
            'stats'    { Get-MobileStatsItems }
            'envs'     { Get-MobileEnvsItems }
            'code'     { Get-MobileCodeItems }
            'whip'     { Get-MobileWhipItems }
            'skills'   { Get-MobileSkillsItems }
            'voice'    { Get-MobileVoiceItems }
            'pcs'      { Get-MobilePcsItems }
            'whisper'  { Get-MobileWhisperItems }
            'settings' { Get-MobileSettingsItems }
            'mobile'   { Get-MobileSelfItems }
        }
    } catch { Write-MobileLog "section ${Id}: $($_.Exception.Message)"; @(MText ((L 'No se pudo leer esta parte: ') + $_.Exception.Message) 'warn') }
    [ordered]@{ id = $Id; title = $title; items = @($items | Where-Object { $_ }) }
}

function Invoke-MobileAction([string]$Section, [string]$Id, $Arg) {
    $key = "$Section/$Id"
    # Ids are stable: after a tray restart the section is described again to register them.
    if (-not $script:Mobile.Actions.ContainsKey($key)) { [void](Get-MobileSection $Section) }
    $action = $script:Mobile.Actions[$key]
    if (-not $action) { return New-MobileAnswer 404 @{ error = 'unknown action' } }
    $before = $script:Hub.MessageAt
    $step = 0
    if ($null -ne $Arg -and -not [int]::TryParse([string]$Arg, [ref]$step)) { return New-MobileAnswer 400 @{ error = 'bad argument' } }
    $step = [Math]::Max(-50, [Math]::Min(50, $step))
    try { if ($null -ne $Arg) { & $action $step } else { & $action } }
    catch { Write-MobileLog "action ${key}: $($_.Exception.Message)"; return New-MobileAnswer 500 @{ error = $_.Exception.Message } }
    $script:Mobile.CacheAt = [datetime]::MinValue
    $message = if ($script:Hub.MessageAt -ne $before) { [string]$script:Hub.Message } else { '' }
    New-MobileAnswer 200 @{ ok = $true; message = $message; section = (Get-MobileSection $Section) }
}

function Get-MobileHomeItems {
    $c = $script:Hub.Cache
    $state = Get-MobileState
    MMeter (Tx 'SESI\u00d3N DE 5 H') $state.plan.session
    MMeter 'SEMANA' $state.plan.weekly
    $next = Get-HubNextRow
    $now = Get-Date
    if ($next) {
        $kind = if ($next.TaskName -like "$AutoTaskPrefix*") { Tx 'autom\u00e1tica' } elseif ($next.Kind -eq 'pc') { L 'en este PC' } else { L 'en la nube' }
        MText ((Tx 'Pr\u00f3xima sesi\u00f3n: ') + (Format-DialogDateTime $next.At $now) + (Tx ' \u00b7 ') + $kind) 'muted'
    } else { MText (L 'Nada agendado') 'muted' }
    MCaption (L 'HOY')
    $live = @($c.CodeSessions | Where-Object { $_.Live }).Count
    MRow $(if ($live -eq 1) { Tx '1 sesi\u00f3n de Claude Code abierta' } elseif ($live) { (Tx '{0} sesiones de Claude Code abiertas') -f $live } else { Tx 'Ninguna sesi\u00f3n de Claude Code abierta' }) '' '' '' $(if ($live) { 'ok' } else { 'faint' })
    $hs = $c.Harness
    if ((Test-HubModule 'ambientes') -and $hs -and $hs.Active) { MRow ((L 'Ambiente {0}, desde las {1}') -f $hs.Active.name, (Format-HubHarnessTime $hs.Active.since)) '' '' '' 'ok' }
    if ((Test-HubModule 'whisper') -and $c.WhisperRunning) { MRow (Tx 'Claude Whisper est\u00e1 abierto') '' '' '' 'ok' }
    if ($c.VoiceMuted) { MRow (Tx 'La voz de las sesiones est\u00e1 apagada') '' '' '' 'faint' }
}

# Nueva sesion from the phone: no folder picker there, so the folders of the open and recent sessions.
function Get-MobileNewSessionItem {
    $dirs = [ordered]@{ '' = (L 'Elige una carpeta') }
    # Each environment's root folder (and the one its Claude opens in) first, then the open and recent sessions'.
    $envDirs = @($script:Hub.Cache.Harness.Envs | ForEach-Object { $_.Folders })
    $all = @($envDirs + @(Read-JsonFile $SessionsFile | Where-Object { $_ } | ForEach-Object { [string]$_.dir }) + @((Get-SnipSettings).Recent))
    foreach ($d in $all) { if ($d -and -not $dirs.Contains($d) -and (Test-Path -LiteralPath $d -PathType Container)) { $dirs[$d] = Split-Path -Leaf $d } }
    if ($dirs.Count -le 1) { return }
    $list = @(foreach ($key in $dirs.Keys) { [ordered]@{ k = [string]$key; label = [string]$dirs[$key] } })
    # The step is the folder's place in the list, so the phone picks any one of them.
    $keys = @($dirs.Keys)
    $script:Mobile.NewSessionDirs = $keys
    [ordered]@{ t = 'choice'; id = (Register-MobileAction 'new-session' { param([int]$Step) $d = @($script:Mobile.NewSessionDirs)[$Step]; if ($d) { Start-ClaudeCodeSession $d; Set-HubMessage ((L 'Abriendo Claude Code en ') + (Split-Path -Leaf $d) + '...') } })
        label = (Tx 'Nueva sesi\u00f3n'); options = $list; current = ''; enabled = $true; absolute = $true }
}

function Get-MobileUsageItems {
    $state = Get-MobileState
    $view = $script:View
    MCaption (Tx 'L\u00cdMITES DEL PLAN') $(if ($view) { Format-Age $view.AgeMinutes } else { L 'Sin datos' })
    MMeter (Tx 'SESI\u00d3N (5 H)') $state.plan.session
    MMeter 'SEMANAL' $state.plan.weekly
    MButton 'usage-refresh' (L 'Actualizar') { Start-UsageRefresh; Set-HubMessage (Tx 'Actualizando el uso\u2026') }
    $extra = $script:Extras.ExtraUsage
    if ($extra) { MRow ((L 'Uso extra: ') + $(if ($null -ne $extra.Percent) { "$($extra.Percent)%" } else { L 'activado' })) '' ([string]$extra.AmountText) }
    $reset = $script:Extras.LimitReset
    if ($reset) { MRow ([string]$reset.Title) ([string]$reset.Detail) }
    Get-MobileAutoItems
    MCaption 'AGENDADAS' (Tx 'Abren la sesi\u00f3n de 5 h antes de que la necesites')
    $rows = @($script:Hub.Cache.ScheduleRows)
    if (-not $rows.Count) { MText (Tx 'Nada agendado todav\u00eda.') 'muted' }
    $now = Get-Date
    foreach ($item in @($rows | Select-Object -First 8)) {
        $status = Get-HubRowStatus $item
        MRow (Format-DialogDateTime $item.At $now) $(if ($item.TaskName -like "$AutoTaskPrefix*") { 'AUTO' } elseif ($item.Kind -eq 'pc') { 'PC' } else { L 'NUBE' }) ([string]$status.Text)
    }
    MOpenOnPc 'usage'
}

# Abrir las ventanas solo (lib\hubauto.ps1): the switch, the peak hour and how many days ahead.
function Get-MobileAutoItems {
    $view = $script:Hub.Cache.Auto
    if (-not $view) { return }
    $settings = $view.Settings
    $hasPlan = [bool]$view.Plan
    MSwitch 'auto' (L 'Abrir las ventanas solo') (Tx 'Un mensaje corto a Claude en cada cambio') ([bool]$settings.enabled) ([scriptblock]::Create("Set-AutoEnabled `$$(-not [bool]$settings.enabled)")) $hasPlan
    $peaks = [ordered]@{ '-1' = (Tx 'Autom\u00e1tica') }
    foreach ($h in 0..23) { $peaks["$h"] = Format-HourMark $h }
    MChoice 'plan-peak' (L 'Hora pico') $peaks $(if ($settings.boundary -ge 0) { "$($settings.boundary)" } else { '-1' }) 'Step-HubPlanPeak' $hasPlan
    $days = [ordered]@{}
    foreach ($d in 1..7) { $days["$d"] = $(if ($d -eq 1) { Tx '1 d\u00eda' } else { (Tx '{0} d\u00edas') -f $d }) }
    MChoice 'plan-days' (L 'Agendar por delante') $days "$($settings.days)" 'Step-HubPlanDays' $hasPlan
}

function Get-MobilePlanItems {
    Get-MobileAutoItems
    $c = $script:Hub.Cache
    MCaption 'CLAUDE JUDGE'
    $status = $c.JudgeStatus
    if ($status -and $status.state -eq 'running') { MText ((L 'Juicio en curso') + $(if ($c.JudgeProgress) { ': ' + $c.JudgeProgress } else { '' })) 'ok' }
    $trials = @($c.JudgeTrials)
    MText $(if ($trials.Count) { (L '{0} juicios recientes') -f $trials.Count } else { Tx 'Ning\u00fan juicio todav\u00eda.' }) 'muted'
    MOpenOnPc 'plan'
}

function Get-MobileStatsItems {
    $stats = Read-JsonFile $StatsFile
    if (-not $stats -or -not $stats.recent) { MText (Tx 'Sin estad\u00edsticas todav\u00eda: \u00e1brelas en el PC una vez.') 'muted'; MOpenOnPc 'stats'; return }
    foreach ($range in @(@{ Key = 'recent'; Label = (L 'ULTIMOS 30 DIAS') }, @{ Key = 'all'; Label = (L 'DESDE EL PRINCIPIO') })) {
        $s = $stats.($range.Key)
        if (-not $s) { continue }
        MCaption $range.Label ((L 'desde ') + [string]$s.from)
        MRow (L 'Tiempo trabajando') '' (Format-HubDuration ([double]$s.seconds))
        MRow (L 'Sesiones') '' (Format-HubNumber ([double]$s.sessions))
        MRow (L 'Mensajes tuyos') '' (Format-HubNumber ([double]$s.prompts))
        MRow (L 'Herramientas usadas') '' (Format-HubNumber ([double]$s.toolCalls))
        MRow (Tx 'D\u00edas activos') '' (Format-HubNumber ([double]$s.activeDays))
        MRow (L 'Racha') '' ((L '{0} d (mejor {1})') -f $s.streak, $s.bestStreak)
    }
    if ($stats.all -and $stats.all.today) { MRow (L 'Hoy') '' (Format-HubDuration ([double]$stats.all.today.seconds)) }
    MOpenOnPc 'stats'
}

function Get-MobileEnvsItems {
    $hs = $script:Hub.Cache.Harness
    if (-not $hs -or -not @($hs.Envs).Count) { MText (Tx 'Ning\u00fan ambiente en este PC todav\u00eda.') 'muted'; MOpenOnPc 'envs'; return }
    if ($hs.Active) { MText ((L 'Ambiente {0}, desde las {1}') -f $hs.Active.name, (Format-HubHarnessTime $hs.Active.since)) 'ok' }
    $busy = $hs.Job -and $hs.Job.state -eq 'running'
    if ($busy) { MText (Tx 'Espera: hay un cambio en curso.') 'muted' }
    MCaption 'AMBIENTES'
    foreach ($e in @($hs.Envs)) {
        $on = $hs.Active -and $hs.Active.id -eq $e.Id
        MSwitch "env-$($e.Id)" ([string]$e.Name) '' ([bool]$on) ([scriptblock]::Create("Switch-HubHarness '$($e.Id)' -NoConfirm")) (-not $busy) (Get-HubHarnessQuestion $e.Id)
    }
    MOpenOnPc 'envs'
}

function Get-MobileCodeItems {
    $c = $script:Hub.Cache
    $screens = [Math]::Max(1, [int]$c.Screens)
    $per = [Math]::Max(1, [int]$c.PerScreen)
    $slots = $per * $screens
    $limit = $c.SessionLimit -ne $false
    $sessions = @($c.CodeSessions)
    $live = @($sessions | Where-Object { $_.Live }).Count
    MCaption 'SESIONES' $(if ($limit) { (L '{0} de {1} abiertas') -f $live, $slots } else { (L '{0} abiertas') -f $live })
    if (-not $sessions.Count) { MText (Tx 'Ninguna sesi\u00f3n abierta desde el men\u00fa.') 'muted' }
    foreach ($s in $sessions) {
        $name = if ($s.Name) { $s.Name } else { (L 'Ventana {0}') -f ($s.Slot + 1) }
        if ($s.Role) { $name += (Tx ' \u00b7 ') + $s.Role }
        MRow $name (Split-Path -Leaf $s.Dir) $(if ($s.Live) { '' } else { L 'cerrada' }) $(if ($s.Live) { Get-HubSlotHex $s.Color } else { '' }) $(if ($s.Live) { '' } else { 'faint' })
    }
    Get-MobileNewSessionItem
    MCaption 'AJUSTES DE LAS SESIONES'
    MChoice 'code-first' (L 'Primera pantalla') (Get-HubScreenFirstOptions) ([string]$c.ScreenFirst) 'Step-HubScreenFirst'
    MChoice 'code-per' (L 'Por pantalla') $HubPerScreenOptions ([string]$per) 'Step-HubPerScreen'
    MSwitch 'code-limit' ((Tx 'Una sesi\u00f3n por hueco, hasta {0}') -f $slots) $(if ($limit) { '' } else { (Tx 'Sin l\u00edmite: desde la {0}\u00aa se superponen.') -f ($slots + 1) }) $limit ([scriptblock]::Create("Set-HubSessionLimit `$$(-not $limit)"))
    $cm = $c.ContextMode
    $busy = $c.MaxxStatus -and $c.MaxxStatus.state -eq 'running'
    MSwitch 'maxx-cm' (L 'Ahorro de contexto (context-mode)') (Tx 'Deja fuera del contexto las salidas largas de las herramientas: la cuota dura m\u00e1s.') ([bool]($cm -and $cm.Enabled)) ([scriptblock]::Create("Set-HubContextMode `$$(-not ($cm -and $cm.Enabled))")) (-not $busy)
    $eggs = [ordered]@{}
    foreach ($edge in $EggDockEdges) { $eggs[$edge] = $script:EggDockLabels[$edge] }
    MChoice 'code-eggs' (Tx 'Icono de cada sesi\u00f3n') $eggs (Get-EggDock).Edge 'Step-HubEggDock'
}

function Get-MobileWhipItems {
    $c = $script:Hub.Cache
    $s = $c.Whip
    if (-not $s) { return }
    $pct = Get-HubPlanPercent
    $forecast = Read-JsonFile $WhipForecastFile
    $mode = Get-WhipMode $s $pct $forecast
    $agents = @($c.WhipAgents)
    $names = @($agents | Where-Object { $s.Agents -contains $_.Id } | ForEach-Object { $_.Label }) -join ', '
    $status, $tone = switch ($mode) {
        'off'      { (Tx 'Apagado. Cuando el plan llegue al umbral, un agente programa y Claude revisa el git, ejecuta los tests y le devuelve lo que falle.'), 'muted' }
        'noagent'  { (Tx 'Activa al menos un agente abajo: sin agentes, Claude Whip no entra en acci\u00f3n.'), 'warn' }
        'armed'    { ((Tx 'Listo: entra en acci\u00f3n cuando el plan llegue al {0}% (ahora {1}%) o vaya a agotarse antes de reiniciarse.') -f $s.Threshold, $pct), 'muted' }
        'forecast' { ((Tx '\u2713 En acci\u00f3n antes del umbral: a este ritmo el plan ({0}%) se agota a las {1}. Programa {2}.') -f $pct, $forecast.limitAt, $names), 'ok' }
        default    { ((Tx '\u2713 En acci\u00f3n (plan al {0}%): programa {1}; Claude revisa el git y los tests.') -f $pct, $names), 'ok' }
    }
    MSwitch 'whip-switch' 'Claude Whip' $status ([bool]$s.Enabled) ([scriptblock]::Create("Set-HubWhipEnabled `$$(-not $s.Enabled)"))
    [ordered]@{ t = 'stepper'; id = (Register-MobileAction 'whip-threshold' { param([int]$Step) Step-HubWhipThreshold $Step }); label = (L 'Se activa'); value = (Format-WhipThreshold $s.Threshold) }
    MCaption 'AGENTES' (L 'Cada uno gasta su propia cuota')
    foreach ($agent in $agents) {
        $on = $s.Agents -contains $agent.Id
        $sub = if ($agent.Installed) { $agent.Note } else { (L 'No instalado: ') + $agent.Install }
        if ($agent.Installed -and $agent.Account -and $agent.Account.Text) { $sub = "$sub $(Tx '\u00b7') $($agent.Account.Text)" }
        MSwitch "whip-agent-$($agent.Id)" "$($agent.Label)  $(Tx '\u00b7')  $($agent.Vendor)" $sub $on ([scriptblock]::Create("Set-HubWhipAgent '$($agent.Id)' `$$(-not $on)")) ([bool]($agent.Installed -or $on))
    }
}

function Get-MobileSkillsItems {
    $c = $script:Hub.Cache
    if ($null -eq $c.Skills) { try { Update-HubSkills -Force } catch { } }
    MRow 'Skills' '' "$(@($c.Skills).Count)"
    MRow (L 'Servidores MCP') '' "$(@($c.Mcp).Count)"
    foreach ($pack in @($c.Packs)) { if ($pack.Label) { MRow ([string]$pack.Label) ([string]$pack.Note) } }
    MText (Tx 'El cat\u00e1logo y las instalaciones se manejan en el PC.') 'muted'
    MOpenOnPc 'skills'
}

function Get-MobileVoiceItems {
    $c = $script:Hub.Cache
    if (-not $c.VoiceInstalled) { MText (Tx 'La voz no est\u00e1 instalada en este PC.') 'warn'; return }
    MSwitch 'voice-on' (L 'Voz en todas las sesiones') (Tx 'Si la apagas, ninguna sesi\u00f3n habla') (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)"))
    MButton 'voice-test' (L 'Probar voz') { Invoke-VoiceCtl 'test' 'Reproduciendo una frase de prueba...' } -OnPc
    MSwitch 'voice-keys' (L 'Atajos de teclado') '' ([bool]$c.HotkeysOn) ([scriptblock]::Create("Set-HubHotkeys `$$(-not $c.HotkeysOn)"))
    $sessions = @($c.VoiceSessions)
    if ($sessions.Count) { MCaption (Tx 'VOCES DE LAS \u00daLTIMAS SESIONES') }
    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $s = $sessions[$i]
        $label = $s.Name + $(if ($s.Role) { (Tx ' \u00b7 ') + $s.Role } else { '' })
        MSwitch "voice-session-$i" $label (Format-VoiceName $s.Voice) (-not $s.Muted) ([scriptblock]::Create("Set-HubVoiceSessionMuted $i"))
    }
    MOpenOnPc 'voice'
}

function Get-MobilePcsItems {
    $b = $script:Bridge
    if ($b -and $b.Settings) {
        $on = [bool]$b.Settings.acceptIncoming
        MSwitch 'pcs-accept' (L 'Aceptar conexiones de otros PCs') '' $on ([scriptblock]::Create("Set-BridgeAccept `$$(-not $on)"))
    }
    $nodes = @(Get-HubNetworkNodes)
    MCaption 'PCS'
    if (-not $nodes.Count) { MText (Tx 'Ning\u00fan PC a la vista en esta red.') 'muted' }
    foreach ($n in $nodes) {
        $tone = switch ($n.State) { 'session' { 'ok' } 'online' { 'ok' } 'unpaired' { 'faint' } default { 'muted' } }
        MRow ([string]$n.Name) (L ([string]$n.Sub)) '' '' $tone
    }
    MOpenOnPc 'pcs'
}

function Get-MobileWhisperItems {
    $c = $script:Hub.Cache
    $settings = $c.WhisperSettings
    MText $(if ($c.WhisperRunning) { Tx 'Claude Whisper est\u00e1 abierto' } else { L 'Cerrado' }) $(if ($c.WhisperRunning) { 'ok' } else { 'muted' })
    if ($settings) {
        $enabled = -not $c.WhisperRunning
        MChoice 'wl' (L 'Idioma') $script:WhisperLanguages ([string]$settings.language) "Set-HubWhisperSetting 'language'" $enabled
        MSwitch 'ws-useMic' (Tx 'Transcribir tambi\u00e9n mi micr\u00f3fono') '' ([bool]$settings.useMic) { Set-HubWhisperSetting 'useMic' } $enabled
        MSwitch 'ws-gateMic' (L 'Uso altavoces, sin auriculares') (Tx 'Evita que tu micr\u00f3fono transcriba el eco') ([bool]$settings.gateMic) { Set-HubWhisperSetting 'gateMic' } $enabled
        MSwitch 'ws-autoAnswer' (L 'Responder sola a las preguntas') (L 'Apagado, responde solo cuando lo pides') ([bool]$settings.autoAnswer) { Set-HubWhisperSetting 'autoAnswer' } $enabled
        MSwitch 'ws-meetingNotice' (L 'Avisarme al empezar una llamada') '' ([bool]$settings.meetingNotice) { Set-HubWhisperSetting 'meetingNotice' } $enabled
        MSwitch 'ws-topMost' (Tx 'Siempre encima de las dem\u00e1s ventanas') '' ([bool]$settings.topMost) { Set-HubWhisperSetting 'topMost' } $enabled
    }
    $calls = @($c.Calls)
    if ($calls.Count) { MCaption (L 'LLAMADAS') }
    foreach ($call in $calls) { MRow ([string]$call.Title) ([string]$call.When) }
    MOpenOnPc 'whisper'
}

function Get-MobileBusinessItems {
    $state = $script:Business
    if ($state -and $state.Policy -and $state.Policy.company) { MRow ([string]$state.Policy.company) (Tx 'Edici\u00f3n Empresa') }
    $off = @($state.Policy.disabled)
    if ($off.Count) { MText ((L 'Apagado por la empresa: ') + ($off -join ', ')) 'muted' }
    MOpenOnPc 'business'
}

function Get-MobileSettingsItems {
    $c = $script:Hub.Cache
    if ($script:Hub.Languages) { MChoice 'language' (L 'Idioma') $script:Hub.Languages ([string]$script:UiLanguage) 'Step-HubLanguage' }
    MSwitch 'snip' ((L 'Captura a Claude Code') + ' (' + $(if ($script:SnipHotkeyName) { $script:SnipHotkeyName } else { 'Win+Alt+C' }) + ')') '' ([bool]$c.SnipEnabled) ([scriptblock]::Create("Set-HubSnip `$$(-not [bool]$c.SnipEnabled)"))
    if ($c.VoiceInstalled) { MSwitch 'settings-voice-on' (L 'Voz en todas las sesiones') (Tx 'Si la apagas, ninguna sesi\u00f3n habla') (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)")) }
    MOpenOnPc 'settings'
}

function Get-MobileSelfItems {
    foreach ($d in @(Get-MobileDevices)) { MRow ([string]$d.name) ((L 'Visto ') + (Format-HubAgo ([string]$d.lastSeen))) }
}

# ---------------------------------------------------------------- Energia (phone only): dark screen and shutdown

$script:MobileDark = $null

function Get-MobilePowerItems {
    MCaption 'PANTALLA'
    if ($script:MobileDark) {
        MText (Tx 'La pantalla est\u00e1 oscura y el PC sigue trabajando.') 'ok'
        MButton 'dark-off' (L 'Encender la pantalla') { Stop-MobileDarkScreen; Set-HubMessage (L 'Pantalla encendida.') } -Accent -OnPc
    } else {
        MText (Tx 'Negro en todas las pantallas y el brillo al m\u00ednimo; las sesiones, la red y los servidores siguen. En el PC, Esc la quita.') 'muted'
        MButton 'dark-on' (L 'Oscurecer la pantalla') { Start-MobileDarkScreen; Set-HubMessage (L 'Pantalla oscura: el PC sigue trabajando. Esc en el PC la quita.') } -OnPc
    }
    MCaption 'APAGAR'
    $at = $script:Mobile.ShutdownAt
    if ($at -and $at -gt (Get-Date)) {
        MText ((L 'El PC se apaga a las {0}.') -f $at.ToString('HH:mm')) 'warn'
        MButton 'shutdown-cancel' (L 'Cancelar el apagado') { Stop-MobileShutdown } -Accent
    } else {
        MText (Tx 'Cierra todo, tambi\u00e9n las sesiones de Claude Code, y apaga el PC un minuto despu\u00e9s: hasta entonces puedes cancelarlo.') 'muted'
        MButton 'shutdown' (L 'Apagar el PC') { Start-MobileShutdown } -OnPc -Confirm ((Tx '\u00bfApagar {0}? Se cierra todo lo abierto, tambi\u00e9n las sesiones de Claude Code.') -f $env:COMPUTERNAME)
    }
}

# A black window on every screen, the backlight at its lowest (laptops: WMI; other monitors only get the black) and
# the PC kept awake, so the sessions, the network and the servers go on. Not the monitor off: on Modern Standby PCs
# that puts Windows to sleep and pauses everything. Esc is a global hotkey while dark: the windows, opened from the
# tray in the background, may not get the keyboard.
function Start-MobileDarkScreen {
    if ($script:MobileDark) { return }
    Initialize-MobileNative
    Initialize-SnipNative
    $dark = @{ Forms = @(); Hotkey = $null; Brightness = $null }
    $script:MobileDark = $dark
    $hint = L 'Pulsa Esc para volver'
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true; $f.KeyPreview = $true
        $f.BackColor = [System.Drawing.Color]::Black; $f.StartPosition = 'Manual'; $f.Bounds = $screen.Bounds
        if ($screen.Primary) {
            $label = New-Object System.Windows.Forms.Label
            $label.Dock = 'Fill'; $label.TextAlign = 'BottomCenter'; $label.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 48)
            $label.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60); $label.Font = New-Object System.Drawing.Font('Segoe UI', 11); $label.Text = $hint
            $f.Controls.Add($label)
        }
        $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { Request-MobileDarkScreenStop } })
        $f.Show()
        $f.Bounds = $screen.Bounds
        $dark.Forms += $f
    }
    $dark.Hotkey = New-Object ClaudeTray.SnipHotkey([uint32]0, [uint32]0x1B)
    if ($dark.Hotkey.Registered) { $dark.Hotkey.add_Pressed({ Request-MobileDarkScreenStop }) }
    else { $dark.Hotkey.Dispose(); $dark.Hotkey = $null; $dark.Forms[0].Activate() }
    [System.Windows.Forms.Cursor]::Hide()
    [ClaudeTray.MobilePower]::KeepAwake($true)
    try {
        $dark.Brightness = [int](@(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop)[0].CurrentBrightness)
        Set-MobileBrightness 0
    } catch { $dark.Brightness = $null }
}

function Set-MobileBrightness([int]$Percent) {
    Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop |
        Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]0; Brightness = [byte]$Percent } -ErrorAction Stop | Out-Null
}

# From Esc: after the key's own message, since closing a window or freeing the hotkey inside its handler is unsafe.
function Request-MobileDarkScreenStop {
    $dark = $script:MobileDark
    if ($dark -and $dark.Forms.Count) { [void]$dark.Forms[0].BeginInvoke([System.Windows.Forms.MethodInvoker]{ Stop-MobileDarkScreen }) }
}

function Stop-MobileDarkScreen {
    $dark = $script:MobileDark
    if (-not $dark) { return }
    $script:MobileDark = $null
    if ($dark.Hotkey) { $dark.Hotkey.Dispose() }
    foreach ($f in $dark.Forms) { $f.Close(); $f.Dispose() }
    [System.Windows.Forms.Cursor]::Show()
    [ClaudeTray.MobilePower]::KeepAwake($false)
    if ($null -ne $dark.Brightness) { try { Set-MobileBrightness $dark.Brightness } catch { Write-MobileLog "brightness: $($_.Exception.Message)" } }
}

# Windows' own countdown (shutdown /s /t, which also closes apps that would hold it up): a minute to cancel it.
function Start-MobileShutdown {
    $out = & shutdown.exe /s /t $MobileShutdownSeconds /c (L 'ClaudeMaxxing apaga este PC: lo pidieron desde el celular.') 2>&1
    if ($LASTEXITCODE) { Set-HubMessage ((L 'No se pudo apagar el PC: ') + ($out -join ' ')) -Failed; return }
    $script:Mobile.ShutdownAt = (Get-Date).AddSeconds($MobileShutdownSeconds)
    Write-MobileLog 'shutdown requested from the phone'
    Set-HubMessage (L 'El PC se apaga en un minuto.')
}

function Stop-MobileShutdown {
    $script:Mobile.ShutdownAt = $null
    & shutdown.exe /a 2>&1 | Out-Null
    Set-HubMessage (L 'Apagado cancelado.')
}
