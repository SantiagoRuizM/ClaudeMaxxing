# ClaudeMaxxing window: every tool in one place, opened from the popup's "Entrar a ClaudeMaxxing" button.
# Sections: Inicio (overview, with the diagram of nearby PCs and the latest calls), Planear sesion (lib\hubplan.ps1:
# an idea on trial before Claude Judge), Ambientes (lib\harness.ps1: a graph of the harness\ environments, click
# to turn it on or off), Uso y agenda, Claude Code
# (sessions opened from the Explorer menu), Otros PCs (diagram of nearby PCs and their connection), Claude
# Whisper (settings and call history) and Voz. The longer flows keep their own windows: the schedule dialog,
# pairing in Otros PCs (pairing is only accepted while that window is open) and the Whisper context dialog.
# Owner-drawn like the rest of the tray; Paint only reads $script:Hub.Cache, which a timer refreshes.
# Needs theme.ps1, usage.ps1, schedule.ps1, sessions.ps1, bridgeui.ps1, whisper.ps1, whisperui.ps1, freellm.ps1, harness.ps1 and hubbusiness.ps1 (Empresa, business edition).
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

$script:HubDialog = $null
$script:Hub = $null
$HubWidth = 840
$HubHeight = 640
$HubNavWidth = 200
# The voice keeps its state here (voice\hooks\common.ps1 calls it $StateDir; that file is not loaded in the tray).
$VoiceStateDir = Join-Path $env:TEMP 'claude-voice'
$script:WhisperCallCache = @{}
# How many times each section was opened: Inicio's header has shortcuts to the ones used most.
$HubVisitsFile = Join-Path $TrayHome 'hub-visits.json'
# Until there are visits (and in the previews), the shortcuts are these.
$HubDefaultFavorites = @('usage', 'code', 'stats', 'voice')

$script:HubFonts = @{
    Icon      = New-UiFont 'Segoe MDL2 Assets' 11
    Node      = New-UiFont 'Segoe MDL2 Assets' 13
    NodeLarge = New-UiFont 'Segoe MDL2 Assets' 16
    Nav       = New-UiFont 'Segoe UI' 9.5
    NavStrong = New-UiFont 'Segoe UI Semibold' 9.5
    Brand     = New-UiFont 'Georgia' 13
    Label     = New-UiFont 'Segoe UI Semibold' 8.5
    Key       = New-UiFont 'Consolas' 9
}

# Business: only in the business edition (lib\hubbusiness.ps1). Module: hidden when the company policy turns it off.
# Nav = $false: not in the side menu. Group: the caption the side menu draws above the first section of each group.
# Labels are translated when drawn.
$script:HubSections = @(
    @{ Id = 'home'; Label = 'Inicio'; Glyph = '\ue80f' },
    @{ Id = 'business'; Label = 'Empresa'; Glyph = '\ue821'; Business = $true },
    @{ Id = 'plan'; Label = (Ux 'Planear sesi\u00f3n'); Glyph = '\uea80'; Group = 'PLANEAR' },
    @{ Id = 'usage'; Label = 'Uso y agenda'; Glyph = '\ue787'; Group = 'PLANEAR' },
    @{ Id = 'stats'; Label = (Ux 'Estad\u00edsticas'); Glyph = '\ue9d2'; Group = 'PLANEAR' },
    @{ Id = 'envs'; Label = 'Ambientes'; Glyph = '\ue7e8'; Module = 'ambientes'; Group = 'FOCO' },
    # SelfHarness is the Foco y ajustes tab of Ambientes (Set-HubSection 'self' opens it there).
    @{ Id = 'self'; Label = 'SelfHarness'; Glyph = '\ue83d'; Module = 'ambientes'; Nav = $false },
    @{ Id = 'code'; Label = 'Claude Code'; Glyph = '\ue943'; Group = 'SESIONES' },
    # Icon: drawn instead of a Segoe MDL2 glyph (there is no whip among them).
    @{ Id = 'whip'; Label = 'Claude Whip'; Icon = 'Draw-HubWhipIcon'; Module = 'whip'; Group = 'SESIONES' },
    @{ Id = 'skills'; Label = 'Skills y MCP'; Glyph ='\uea86'; Group = 'SESIONES' },
    @{ Id = 'voice'; Label = 'Voz'; Glyph = '\ue767'; Group = 'SESIONES' },
    @{ Id = 'pcs'; Label = 'Otros PCs'; Glyph = '\ue968'; Module = 'bridge'; Group = 'CONEXIONES' },
    @{ Id = 'whisper'; Label = 'Claude Whisper'; Glyph = '\ue720'; Module = 'whisper'; Group = 'CONEXIONES' },
    @{ Id = 'mobile'; Label = 'Celular'; Glyph = '\ue8ea'; Module = 'mobile'; Group = 'CONEXIONES' },
    @{ Id = 'settings'; Label = (Ux 'Configuraci\u00f3n'); Glyph = '\ue713'; Group = ' ' }
)

# ---------------------------------------------------------------- data

# The latest calls, newest first. Files are parsed again only when they change.
function Get-WhisperCalls([int]$Count) {
    $script:Hub.Cache.CallCount = 0
    if (-not (Test-Path -LiteralPath $WhisperSessionsDir)) { return , @() }
    $files = @(Get-ChildItem -LiteralPath $WhisperSessionsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $script:Hub.Cache.CallCount = $files.Count
    $calls = @()
    foreach ($file in @($files | Select-Object -First $Count)) {
        $stamp = $file.LastWriteTimeUtc.Ticks
        $cached = $script:WhisperCallCache[$file.FullName]
        if (-not $cached -or $cached.Stamp -ne $stamp) {
            $lines = @()
            try { $lines = [IO.File]::ReadAllLines($file.FullName, [Text.Encoding]::UTF8) } catch { }
            $call = ConvertFrom-WhisperCallLog $file.BaseName $lines
            $call.Path = $file.FullName
            $cached = @{ Stamp = $stamp; Call = $call }
            $script:WhisperCallCache[$file.FullName] = $cached
        }
        $calls += $cached.Call
    }
    , $calls
}

# Session ids go into file names: letters, digits and dashes only (same rule as the voice's Get-SessionKey).
function Get-HubSessionKey([string]$SessionId) {
    $key = [regex]::Replace("$SessionId", '[^A-Za-z0-9-]', '')
    if ($key) { $key } else { 'manual' }
}

function Get-HubSlotHex([string]$ColorName) {
    $match = @($SlotColors | Where-Object { $_.Name -eq $ColorName }) | Select-Object -First 1
    if ($match) { return $match.Hex }
    '#A6A39A'
}

# Claude Code windows opened from the Explorer menu (sessions.json), open ones first.
function Get-HubCodeSessions {
    $records = @(Read-JsonFile $SessionsFile | Where-Object { $_ })
    $sessions = foreach ($r in $records) {
        $hwnd = [long]$r.hwnd
        $at = $null
        try { if ($r.at) { $at = [datetime]$r.at } } catch { }
        $key = Get-HubSessionKey $r.sessionId
        $voice = Read-JsonFile (Join-Path $VoiceStateDir ('name-' + $key))
        [pscustomobject]@{
            Key = $key; Slot = [int]$r.slot; Hwnd = $hwnd; Live = ($hwnd -ne 0 -and [ClaudeTray.Native]::IsWindow([IntPtr]$hwnd))
            Dir = [string]$r.dir; At = $at; Color = [string]$r.color; Name = [string]$r.name
            Role = $(if ($voice) { [string]$voice.role } else { '' }); Voice = $(if ($voice) { [string]$voice.voice } else { '' })
            Backend = [string]$r.backend
        }
    }
    , @($sessions | Sort-Object @{ Expression = { -not $_.Live } }, Slot)
}

# Sessions that used the voice in the last 12 hours, newest first.
function Get-HubVoiceSessions {
    if (-not (Test-Path -LiteralPath $VoiceStateDir)) { return , @() }
    $since = (Get-Date).AddHours(-12)
    $files = @(Get-ChildItem -LiteralPath $VoiceStateDir -Filter 'voice-*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 7)
    $sessions = foreach ($file in $files) {
        $key = $file.Name.Substring(6)
        $info = Read-JsonFile (Join-Path $VoiceStateDir "name-$key")
        $voice = ''
        try { $voice = [IO.File]::ReadAllText($file.FullName).Trim() } catch { }
        [pscustomobject]@{
            Key = $key; Name = $(if ($info -and $info.name) { [string]$info.name } else { 'Sin nombre' })
            Role = $(if ($info) { [string]$info.role } else { '' }); Color = $(if ($info) { [string]$info.color } else { '' })
            Voice = $voice; Used = $file.LastWriteTime; Muted = (Test-Path -LiteralPath (Join-Path $VoiceStateDir "muted-$key"))
        }
    }
    , @($sessions)
}

function Test-VoiceHotkeys {
    $pidFile = Join-Path $VoiceStateDir 'hotkeys.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    $hotkeyPid = 0
    try { $hotkeyPid = [int]([IO.File]::ReadAllText($pidFile).Trim()) } catch { return $false }
    [bool](Get-Process -Id $hotkeyPid -ErrorAction SilentlyContinue)
}

# "es-CO-SalomeNeural" -> "Salome (es-CO)".
function Format-VoiceName([string]$Voice) {
    if ($Voice -match '^([a-z]{2,3}-[A-Z]{2})-([A-Za-z]+?)Neural$') { return '{0} ({1})' -f $Matches[2], $Matches[1] }
    $Voice
}

# FreeLLMAPI card: what is installed, the saved settings and the install progress. Exe, port and server
# are looked up only with -Slow (a socket), and the registry only with -Full or while it is installed.
function Get-HubFreeLlm($Previous, [switch]$Slow, [switch]$Full) {
    $state = @{ Installed = $false; Exe = $null; Port = $FreeLlmDefaultPort; Up = $false }
    if ($Previous) { foreach ($k in 'Installed', 'Exe', 'Port', 'Up') { $state[$k] = $Previous[$k] } }
    if ($Slow -or $Full -or -not $Previous) {
        $quick = $Previous -and -not $Full -and -not $Previous.Installed
        $state.Exe = Get-FreeLlmExe -Quick:$quick
        $state.Installed = [bool]$state.Exe
        $state.Port = Get-FreeLlmPort
        $state.Up = $state.Installed -and (Test-FreeLlmUp $state.Port 150)
    }
    $settings = Get-FreeLlmSettings
    $state.Enabled = $settings.Enabled
    $state.HasKey = Test-FreeLlmKeyFormat $settings.Key
    $install = Get-FreeLlmInstallStatus
    $state.Installing = $false
    if ($install -and $install.state -in 'downloading', 'installing') {
        # A worker that died leaves its last state behind: after 20 minutes it no longer counts.
        try { $state.Installing = ((Get-Date) - [datetime]$install.at).TotalMinutes -lt 20 } catch { }
    }
    $state.Install = $install
    $state
}

function Update-HubCache([switch]$Full) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Preview) { return }
    $c = $hub.Cache
    $now = Get-Date
    $c.WhisperRunning = Test-WhisperRunning
    $c.WhisperSettings = Get-WhisperSettings (Read-JsonFile $WhisperSettingsFile)
    $c.CodeSessions = Get-HubCodeSessions
    $c.VoiceMuted = Test-Path -LiteralPath (Join-Path $VoiceStateDir 'muted')
    $c.HotkeysOn = Test-VoiceHotkeys
    $c.ScheduleRows = @(Get-ScheduleRows $script:PendingTasks (Read-JsonFile $CloudFile) (Read-JsonFile $HistoryFile) $now 5)
    $slow = $Full -or ($now - $hub.SlowAt).TotalSeconds -ge 10
    $c.FreeLlm = Get-HubFreeLlm $c.FreeLlm -Slow:$slow -Full:$Full
    try { $c.ContextMode = Get-ContextModeState; $c.MaxxStatus = Get-MaxxStatus } catch { }
    try { Update-HubJudge } catch { }
    try { $c.Harness = Get-HarnessState } catch { $c.Harness = $null }
    try { $c.SelfHarness = Get-SelfHarnessSettings } catch { $c.SelfHarness = $null }
    try { Update-HubSkills } catch { }
    try { $c.Whip = Get-WhipSettings; if ($slow -or -not $c.WhipAgents) { $c.WhipAgents = Get-WhipAgentStates } } catch { }
    try { Update-HubBusiness } catch { }
    if ($slow) {
        $hub.SlowAt = $now
        $c.Calls = Get-WhisperCalls 5
        $c.VoiceSessions = Get-HubVoiceSessions
        $c.MenuInstalled = [bool](Get-ItemProperty -LiteralPath $MenuKey -Name Launcher -ErrorAction SilentlyContinue)
        $c.Screens = [System.Windows.Forms.Screen]::AllScreens.Count
        # Their bounds, for Claude Code's map (ordered there by Get-ScreenOrder, like the launcher).
        $c.ScreenAreas = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { [pscustomobject]@{ Left = $_.Bounds.Left; Top = $_.Bounds.Top; Right = $_.Bounds.Right; Bottom = $_.Bounds.Bottom } })
        $c.ScreenFirst = Get-ScreenFirst
        $c.SessionLimit = Test-SessionLimit
        $c.PerScreen = Get-SessionsPerScreen
        $c.Activity = Get-SessionActivity
        $c.SnipEnabled = (Get-SnipSettings).Enabled
        $c.VoiceInstalled = Test-Path -LiteralPath (Join-Path $TrayRoot 'voice\hooks\speak.ps1')
        try { $c.VoiceEngine = Get-VoiceEngineState } catch { $c.VoiceEngine = $null }
        $c.Auto = Get-HubAutoView
    }
}

# ---------------------------------------------------------------- actions

function Set-HubSection([string]$Id) {
    # SelfHarness lives in Ambientes now, as its second tab.
    if ($Id -eq 'self') { $Id = 'envs'; $script:Hub.EnvsTab = 'focus' }
    $script:Hub.Section = $Id
    if ($Id -ne 'home' -and -not $script:Hub.Preview) { Add-HubVisit $Id }
    if ($Id -eq 'stats') { Update-HubStats }
    # The automatic agenda needs the stats: the first time, compute them.
    if ($Id -eq 'plan') { Update-HubAuto }
    if ($Id -eq 'usage') { Update-HubAuto; if (-not (Test-Path -LiteralPath $StatsFile)) { Update-HubStats } }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Get-HubVisits {
    if ($null -eq $script:Hub.Visits) {
        $visits = @{}
        if (-not $script:Hub.Preview) {
            $saved = Read-JsonFile $HubVisitsFile
            if ($saved) { foreach ($p in $saved.PSObject.Properties) { $visits[$p.Name] = [int]$p.Value } }
        }
        $script:Hub.Visits = $visits
    }
    $script:Hub.Visits
}

function Add-HubVisit([string]$Id) {
    $visits = Get-HubVisits
    $visits[$Id] = 1 + [int]$visits[$Id]
    # A failed write only loses this count.
    try { Write-JsonFile $HubVisitsFile $visits } catch { }
}

# The sections opened most (ties, and no visits yet, go by $HubDefaultFavorites, then by the side menu's order).
function Get-HubFavorites([int]$Count = 4) {
    $visits = Get-HubVisits
    $sections = @(Get-HubVisibleSections | Where-Object { $_.Id -ne 'home' })
    $order = @{}
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $d = [Array]::IndexOf($HubDefaultFavorites, $sections[$i].Id)
        $order[$sections[$i].Id] = if ($d -ge 0) { $d } else { 100 + $i }
    }
    @($sections | Sort-Object @{ Expression = { -[int]$visits[$_.Id] } }, @{ Expression = { $order[$_.Id] } } | Select-Object -First $Count)
}

# Full screen (F11): the window covers its screen and the hub is drawn for that size. Px and the fonts grow while it
# paints (Enter-HubScale), so the text stays sharp (stretching the picture would blur it) and the cards get the width.
function Set-HubFullScreen([System.Drawing.Rectangle]$Screen) {
    $hub = $script:Hub
    $hub.FullScale = [Math]::Min($Screen.Width / [double](Px $HubWidth), $Screen.Height / [double](Px $HubHeight))
    $hub.Zoom = 1.0; $hub.W = $Screen.Width; $hub.H = $Screen.Height
    Update-HubMarks
}

function Switch-HubFullScreen {
    $dlg = $script:HubDialog; $hub = $script:Hub
    if (-not $dlg -or $hub.Preview) { return }
    if ($hub.Normal) {
        $hub.FullScale = 1.0; $hub.Zoom = $hub.NormalZoom; $hub.W = Px $HubWidth; $hub.H = Px $HubHeight
        $dlg.Bounds = $hub.Normal
        $hub.Normal = $null
        Update-HubMarks
        $corner = 2
    } else {
        $hub.Normal = $dlg.Bounds; $hub.NormalZoom = $hub.Zoom
        $screen = [System.Windows.Forms.Screen]::FromControl($dlg).Bounds
        Set-HubFullScreen $screen
        $dlg.Bounds = $screen
        $corner = 1
    }
    $dlg.Tag.Zoom = $hub.Zoom
    # DWMWA_WINDOW_CORNER_PREFERENCE: square corners while it fills the screen, round again after.
    [void][ClaudeTray.Native]::DwmSetWindowAttribute($dlg.Handle, 33, [ref]$corner, 4)
    $dlg.Invalidate()
}

# The jellyfish bitmaps, at the size the hub is drawn.
function Update-HubMarks {
    $hub = $script:Hub
    $k = if ($hub.FullScale) { $hub.FullScale } else { 1.0 }
    foreach ($name in 'Logo', 'Watermark', 'NavMark') { if ($hub[$name]) { $hub[$name].Dispose() } }
    $accent = $script:Palette.Accent
    $hub.Logo = New-BrandMark $accent ([int]((Px 26) * $k))
    $hub.Watermark = New-BrandMark $accent ([int]((Px 380) * $k)) 0.07
    $hub.NavMark = New-BrandMark $accent ([int]((Px 96) * $k)) 0.12
}

# While the hub paints in full screen, Px and the shared fonts are the scaled ones; Exit-HubScale puts them back, so
# the popup and the other windows (drawn outside this paint) keep their size.
function Enter-HubScale {
    $hub = $script:Hub
    $k = $hub.FullScale
    if (-not $k -or $k -eq 1) { return $null }
    if ($hub.ScaledK -ne $k) {
        foreach ($set in @($hub.ScaledFonts)) { if ($set) { foreach ($f in $set.Values) { $f.Dispose() } } }
        $hub.ScaledFonts = foreach ($set in $script:Fonts, $script:HubFonts) {
            $copy = @{}
            foreach ($key in $set.Keys) { $f = $set[$key]; $copy[$key] = New-Object System.Drawing.Font($f.FontFamily, [single]($f.Size * $k), $f.Style) }
            $copy
        }
        $hub.ScaledK = $k
    }
    $saved = @{ Scale = $script:Scale; Fonts = $script:Fonts; HubFonts = $script:HubFonts }
    $script:Scale = $saved.Scale * $k
    $script:Fonts = $hub.ScaledFonts[0]
    $script:HubFonts = $hub.ScaledFonts[1]
    $saved
}

function Exit-HubScale($Saved) {
    if (-not $Saved) { return }
    $script:Scale = $Saved.Scale; $script:Fonts = $Saved.Fonts; $script:HubFonts = $Saved.HubFonts
}

# Header note after an action. Errors ("No se pudo...", or -Failed) are drawn in the error color and stay longer.
function Set-HubMessage([string]$Text, [switch]$Failed) {
    $script:Hub.Message = $Text
    $script:Hub.MessageError = $Failed -or $Text -like 'No se pud*'
    $script:Hub.MessageAt = Get-Date
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Update-HubNow {
    try { Update-HubCache } catch { }
    try { Complete-HubStatsScan } catch { }
    # Estadisticas > Consumo follows the open session: an incremental scan (about a second) every 2 minutes.
    $hub = $script:Hub
    if ($hub -and -not $hub.Preview -and $hub.Section -eq 'stats' -and $hub.StatsTab -eq 'usage' -and $hub.Cache.Stats -and
        (Get-StatsAgeMinutes $hub.Cache.Stats) -ge 2) { Start-HubStatsScan }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Open-HubSchedule([string]$Tab = 'schedule') {
    if ($script:Hub.Preview) { return }
    Show-ScheduleDialog -Tab $Tab
    Update-ScheduleState
    Update-HubNow
}

function Open-HubCodeSession {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = Tx 'Carpeta donde abrir Claude Code (en el siguiente hueco libre de la pantalla)'
    if ($picker.ShowDialog($script:HubDialog) -ne 'OK' -or -not $picker.SelectedPath) { return }
    Start-ClaudeCodeSession $picker.SelectedPath
    Set-HubMessage ((L 'Abriendo Claude Code en ') + (Split-Path -Leaf $picker.SelectedPath) + '...')
}

function Show-HubCodeWindow([int]$Index) {
    $session = @($script:Hub.Cache.CodeSessions)[$Index]
    if (-not $session -or -not $session.Live) { return }
    $hwnd = [IntPtr]$session.Hwnd
    if ([ClaudeTray.Native]::IsIconic($hwnd)) { [void][ClaudeTray.Native]::ShowWindow($hwnd, 9) }
    [void][ClaudeTray.Native]::SetForegroundWindow($hwnd)
}

function Install-HubFreeLlm {
    if ($script:Hub.Preview) { return }
    $ask = (Tx 'FreeLLMAPI es una app de terceros. Se descarga su instalador oficial {0} (unos 110 MB, sin firma de c\u00f3digo; se comprueba su SHA-512) y se instala para tu usuario. \u00bfSeguir?') -f $FreeLlmVersion
    if (-not (Confirm-UiAction $ask $script:HubDialog)) { return }
    $worker = Join-Path $TrayRoot 'lib\freellm-install.ps1'
    # Written first, so it never overwrites the worker's own progress.
    Write-JsonFile $FreeLlmInstallFile ([ordered]@{ state = 'downloading'; message = (Tx 'Preparando la descarga\u2026'); version = $FreeLlmVersion; at = (Get-Date).ToString('o') })
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $worker) -WindowStyle Hidden
    Update-HubNow
}

# The desktop app is single-instance: starting it again brings its window up.
function Open-HubFreeLlm {
    if ($script:Hub.Preview) { return }
    $exe = Get-FreeLlmExe
    if ($exe) { Start-Process -FilePath $exe } else { Start-Process (Get-FreeLlmBaseUrl (Get-FreeLlmPort)) }
    Set-HubMessage 'Abriendo FreeLLMAPI...'
}

# Takes the unified key from the clipboard (copied from the Keys page of FreeLLMAPI) and checks it there.
# A call that blocks for seconds (a web check, a compile): say so and show the wait cursor before it starts,
# since the window cannot repaint until it returns.
# (Odd parameter names: $BusyWork runs here and sees these variables, so they must not shadow the caller's.)
function Invoke-HubBusy([string]$BusyNote, [scriptblock]$BusyWork) {
    Set-HubMessage $BusyNote
    $busyForm = $script:HubDialog
    if ($busyForm) { $busyForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $busyForm.Refresh() }
    try { & $BusyWork } finally { if ($busyForm -and -not $busyForm.IsDisposed) { $busyForm.Cursor = [System.Windows.Forms.Cursors]::Default } }
}

# A key read from the clipboard and saved: it leaves the clipboard (and so Win+V's history from now on).
function Clear-ClipboardSecret([string]$Key) {
    try { if ($Key -and ([System.Windows.Forms.Clipboard]::GetText()).Trim() -eq $Key) { [System.Windows.Forms.Clipboard]::Clear() } } catch { }
}

function Set-HubFreeLlmKey {
    if ($script:Hub.Preview) { return }
    $key = ''
    try { $key = ([System.Windows.Forms.Clipboard]::GetText()).Trim() } catch { }
    if (-not (Test-FreeLlmKeyFormat $key)) {
        Set-HubMessage (Tx 'Copia primero la clave unificada (freellmapi-\u2026) en FreeLLMAPI > Keys.')
        return
    }
    $settings = Get-FreeLlmSettings
    $check = Invoke-HubBusy (Tx 'Comprobando la clave en FreeLLMAPI\u2026') { Test-FreeLlmKey (Get-FreeLlmPort) $key }
    if ($check.Status -eq 'bad-key') { Set-HubMessage (Tx 'FreeLLMAPI no acepta esa clave: c\u00f3piala otra vez de su p\u00e1gina Keys.'); return }
    try { Save-FreeLlmSettings $settings.Enabled $key } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message); return }
    Clear-ClipboardSecret $key
    switch ($check.Status) {
        'ok'           { Set-HubMessage (Tx ((Tx '\u2713 Clave guardada: ') + $check.Models.Count + (L ' modelos disponibles'))) }
        'no-providers' { Set-HubMessage (Tx 'Clave guardada, pero a\u00fan no hay claves de proveedores en FreeLLMAPI.') }
        'down'         { Set-HubMessage (Tx 'Clave guardada (FreeLLMAPI no est\u00e1 abierto: no se pudo comprobar).') }
        default        { Set-HubMessage (Tx 'Clave guardada (no se pudo comprobar).') }
    }
    Update-HubCache -Full
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubFreeLlmEnabled([bool]$On) {
    if ($script:Hub.Preview) { return }
    $settings = Get-FreeLlmSettings
    try { Save-FreeLlmSettings $On $settings.Key } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message); return }
    if ($On) {
        # Warm it up now so the next session does not wait for it.
        if (-not (Test-FreeLlmUp (Get-FreeLlmPort))) { $exe = Get-FreeLlmExe; if ($exe) { Start-Process -FilePath $exe -WindowStyle Minimized } }
        Set-HubMessage (Tx 'Las sesiones nuevas usar\u00e1n FreeLLMAPI.')
    } else {
        Set-HubMessage (Tx 'Las sesiones nuevas vuelven a tu plan de Claude.')
    }
    Update-HubCache -Full
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# Ahorro de tokens (lib\maxx.ps1): context-mode on or off for new sessions, in the background.
function Set-HubSessionLimit([bool]$On) {
    if ($script:Hub.Preview) { return }
    Set-SessionLimit $On
    $script:Hub.Cache.SessionLimit = $On
    Set-HubMessage $(if ($On) { (L 'Sesiones limitadas a {0} por pantalla.') -f (Get-SessionsPerScreen) } else { (Tx 'Sin l\u00edmite de sesiones: las nuevas se superponen.') })
    Update-HubNow
}

# Sesiones por pantalla: 1, 2 or 4, stepped by the dropdown (Draw-HubCodeSection).
$HubPerScreenOptions = [ordered]@{ '1' = 'Una, entera'; '2' = 'Dos, en mitades'; '4' = 'Cuatro, en cuartos' }
function Step-HubPerScreen([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $keys = @($HubPerScreenOptions.Keys)
    $i = [array]::IndexOf($keys, [string]$script:Hub.Cache.PerScreen)
    $next = [int]$keys[[Math]::Max(0, [Math]::Min($keys.Count - 1, $i + $Delta))]
    try { Set-SessionsPerScreen $next } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message) -Failed; return }
    $script:Hub.Cache.PerScreen = $next
    Set-HubMessage 'Las sesiones nuevas se acomodan con el nuevo reparto.'
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# Captura a Claude Code (lib\snip.ps1): its hotkey, and the box after a Win+Shift+S snip.
function Set-HubSnip([bool]$On) {
    if ($script:Hub.Preview) { return }
    Set-SnipEnabled $On
    $script:Hub.Cache.SnipEnabled = $On
    try { Update-SnipHotkey } catch { Write-SnipLog $_.Exception.Message }
    Set-HubMessage $(if ($On -and $script:SnipHotkeyName) { (L '{0} recorta para Claude Code; tras Win+Shift+S aparece el cuadro.') -f $script:SnipHotkeyName } elseif ($On) { L 'Los atajos de la captura los usan otras apps.' } else { L 'El atajo queda libre y los recortes ya no abren el cuadro.' })
    Update-HubNow
}

function Set-HubContextMode([bool]$On) {
    if ($script:Hub.Preview) { return }
    $status = $script:Hub.Cache.MaxxStatus
    if ($status -and $status.state -eq 'running') { return }
    Start-MaxxJob $(if ($On) { 'contextmode-on' } else { 'contextmode-off' })
    Set-HubMessage $(if ($On) { 'Activando context-mode...' } else { 'Desactivando context-mode...' })
    Update-HubNow
}

function Stop-HubPeerSessions([string]$PeerId) {
    $sessions = @($script:Bridge.Sessions.Values | Where-Object { $_.PeerId -eq $PeerId })
    if (-not $sessions.Count) { return }
    if (-not (Confirm-UiAction ((Tx '\u00bfCerrar lo que {0} tiene abierto en este PC? Lo que est\u00e9 haciendo all\u00ed se corta.') -f $sessions[0].PeerName) $script:HubDialog)) { return }
    foreach ($session in $sessions) { Stop-BridgeSession $session.Id }
    Set-HubMessage 'Sesiones de ese PC cerradas.'
}

# Whisper settings are edited here only while Whisper is closed: the open window keeps its own copy and
# writes the whole file when anything changes there.
function Set-HubWhisperSetting([string]$Key, [int]$Delta = 0) {
    if ($script:Hub.Preview) { return }
    if (Test-WhisperRunning) { Set-HubMessage (Tx 'Claude Whisper est\u00e1 abierto: cambia sus ajustes desde su ventana.'); return }
    $settings = Get-WhisperSettings (Read-JsonFile $WhisperSettingsFile)
    switch ($Key) {
        'language' { $keys = @($script:WhisperLanguages.Keys) }
        'model'    { $keys = @($script:WhisperModels.Keys) }
        default    { $keys = $null }
    }
    if ($keys) {
        $index = [array]::IndexOf($keys, $settings[$Key])
        $settings[$Key] = $keys[($index + $Delta + $keys.Count) % $keys.Count]
    } else {
        $settings[$Key] = -not [bool]$settings[$Key]
    }
    try { Write-JsonFile $WhisperSettingsFile $settings } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message); return }
    $script:Hub.Cache.WhisperSettings = $settings
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Edit-HubWhisperContext {
    if ($script:Hub.Preview) { return }
    if (Test-WhisperRunning) {
        Start-WhisperWindow $TrayRoot
        Set-HubMessage (Tx 'Claude Whisper est\u00e1 abierto: usa Contexto en su ventana.')
        return
    }
    $settings = Get-WhisperSettings (Read-JsonFile $WhisperSettingsFile)
    $updated = Show-WhisperContextDialog $settings $script:Palette $script:HubDialog
    if (-not $updated) { return }
    try { Write-JsonFile $WhisperSettingsFile $updated; Set-HubMessage (Tx '\u2713 Contexto guardado') } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message) }
    Update-HubNow
}

function Open-HubWhisper {
    if ($script:Hub.Preview) { return }
    Start-WhisperWindow $TrayRoot
    Set-HubMessage 'Abriendo Claude Whisper...'
}

function Open-HubCall([int]$Index) {
    $call = @($script:Hub.Cache.Calls)[$Index]
    if (-not $call) { return }
    if (Test-Path -LiteralPath $call.Path) { Start-Process -FilePath $call.Path }
    else { Set-HubMessage (Tx 'No se pudo abrir: esa llamada ya no est\u00e1 en el historial.') }
}

function Open-HubCallFolder {
    if (-not (Test-Path -LiteralPath $WhisperSessionsDir)) { New-Item -ItemType Directory -Force -Path $WhisperSessionsDir | Out-Null }
    Start-Process explorer.exe $WhisperSessionsDir
}

# voice\ctl.ps1 in its own hidden process ("hotkeys on" waits a few seconds; the tray must not).
function Invoke-VoiceCtl([string]$Arguments, [string]$Done) {
    if ($script:Hub.Preview) { return }
    $ctl = Join-Path $TrayRoot 'voice\ctl.ps1'
    if (-not (Test-Path -LiteralPath $ctl)) { Set-HubMessage (Tx 'La voz no est\u00e1 instalada: ejecuta install.ps1.'); return }
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ctl, $Arguments) -WindowStyle Hidden
    if ($Done) { Set-HubMessage $Done }
}

function Set-HubVoiceMuted([bool]$Muted) {
    if ($script:Hub.Preview) { return }
    $file = Join-Path $VoiceStateDir 'muted'
    if ($Muted) {
        try {
            if (-not (Test-Path -LiteralPath $VoiceStateDir)) { New-Item -ItemType Directory -Force -Path $VoiceStateDir | Out-Null }
            [IO.File]::WriteAllText($file, '')
        } catch { Set-HubMessage ((L 'No se pudo silenciar la voz: ') + $_.Exception.Message); return }
        Invoke-VoiceCtl 'stop'
    } else {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    Update-HubNow
}

function Set-HubVoiceSessionMuted([int]$Index) {
    if ($script:Hub.Preview) { return }
    $session = @($script:Hub.Cache.VoiceSessions)[$Index]
    if (-not $session) { return }
    $file = Join-Path $VoiceStateDir "muted-$($session.Key)"
    if ($session.Muted) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    else {
        try { [IO.File]::WriteAllText($file, '') }
        catch { Set-HubMessage ((L 'No se pudo silenciar esa voz: ') + $_.Exception.Message); return }
    }
    $session.Muted = -not $session.Muted
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# Voz: the engine that reads the summaries, and the keys of ElevenLabs and Gemini (lib\voiceengine.ps1).
function Set-HubVoiceEngine([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $keys = @($script:VoiceEngines.Keys)
    $current = if ($script:Hub.Cache.VoiceEngine) { $script:Hub.Cache.VoiceEngine.Engine } else { 'edge' }
    $next = $keys[([array]::IndexOf($keys, $current) + $Delta + $keys.Count) % $keys.Count]
    try { Set-VoiceEngine $next } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message); return }
    $state = Get-VoiceEngineState
    $script:Hub.Cache.VoiceEngine = $state
    if ($next -eq 'elevenlabs' -and -not $state.ElevenKey) { Set-HubMessage (Tx 'Pega tu clave de ElevenLabs: hasta entonces se usa Edge.') }
    elseif ($next -eq 'gemini' -and -not $state.GeminiKey) { Set-HubMessage (Tx 'Pega tu clave de Gemini: hasta entonces se usa Edge.') }
    else { Set-HubMessage ((L 'Motor de voz: ') + $script:VoiceEngines[$next]) }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubVoiceGender([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $keys = @($script:HubVoiceGenderLabels.Keys)
    $current = if ($script:Hub.Cache.VoiceEngine) { $script:Hub.Cache.VoiceEngine.Gender } else { 'mix' }
    $next = $keys[([array]::IndexOf($keys, $current) + $Delta + $keys.Count) % $keys.Count]
    try { Set-VoiceGender $next } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message); return }
    $script:Hub.Cache.VoiceEngine = Get-VoiceEngineState
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubVoiceKey([string]$Engine) {
    if ($script:Hub.Preview) { return }
    $result = Show-VoiceKeyDialog $Engine $script:Palette $script:HubDialog
    if ($result) { Set-HubMessage ([string][char]0x2713 + ' ' + $result.Message) }
    $script:Hub.Cache.VoiceEngine = Get-VoiceEngineState
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# A box to paste the ElevenLabs or Gemini key (prefilled from the clipboard when it holds one). Saving checks the
# key with the service; on failure the window stays open with the whole error. Returns Save-VoiceKey's result or $null.
# Reuses the Claude Judge dialog helpers (hubplan.ps1).
function Show-VoiceKeyDialog([string]$Engine, $Palette, $Owner) {
    $P = $Palette
    $name = if ($Engine -eq 'elevenlabs') { 'ElevenLabs' } else { 'Gemini' }
    $dlg = New-JudgeForm '' $P 500 210
    $dlg.Text = (L 'Clave de ') + $name
    # New-JudgeForm's minimum is taller than this window: lower it and size the window again.
    $dlg.MinimumSize = New-Object System.Drawing.Size((Px 400), (Px 230))
    $dlg.ClientSize = New-Object System.Drawing.Size((Px 500), (Px 210))
    $hint = if ($Engine -eq 'elevenlabs') { Tx 'Pega tu clave de ElevenLabs (empieza por sk_). Cr\u00e9ala en elevenlabs.io > Developers > API Keys con los permisos Text to Speech, Voices (Read) y User (Read): el \u00faltimo deja ver tus cr\u00e9ditos y cu\u00e1ndo se renuevan.' }
            else { Tx 'Pega tu clave de Google AI Studio (empieza por AIza). Cr\u00e9ala en aistudio.google.com > Get API key.' }
    $label = New-JudgeLabel $hint $P.Muted
    $label.MaximumSize = New-Object System.Drawing.Size((Px 460), 0)
    Add-JudgeRow $dlg $label
    $box = New-Object System.Windows.Forms.TextBox
    $box.UseSystemPasswordChar = $true
    $box.BackColor = $P.Surface; $box.ForeColor = $P.Text; $box.BorderStyle = 'FixedSingle'
    $box.Font = New-UiFont 'Segoe UI' 10
    $box.Margin = New-Object System.Windows.Forms.Padding(0, (Px 6), 0, (Px 6))
    $clip = ''
    try { $clip = ([System.Windows.Forms.Clipboard]::GetText()).Trim() } catch { }
    if (Test-VoiceKeyFormat $Engine $clip) { $box.Text = $clip }
    Add-JudgeRow $dlg $box
    # Fills the free height and wraps, so a long error is read whole.
    $err = New-JudgeLabel '' $P.Error
    $err.AutoSize = $false
    Add-JudgeRow $dlg $err 100
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'
    $save = New-WhisperButton 'Guardar' $P $true
    $cancel = New-WhisperButton 'Cancelar' $P
    $cancel.DialogResult = 'Cancel'
    $buttons.Controls.Add($save); $buttons.Controls.Add($cancel)
    Add-JudgeRow $dlg $buttons
    $dlg.AcceptButton = $save
    $dlg.CancelButton = $cancel
    $state = @{ Result = $null }
    $save.Add_Click({
        $err.ForeColor = $P.Muted; $err.Text = Tx 'Comprobando la clave\u2026'
        $dlg.UseWaitCursor = $true; $save.Enabled = $false; $dlg.Refresh()
        $r = Save-VoiceKey $Engine $box.Text.Trim()
        $dlg.UseWaitCursor = $false; $save.Enabled = $true
        if ($r.Ok) { Clear-ClipboardSecret $box.Text.Trim(); $state.Result = $r; $dlg.DialogResult = 'OK' }
        else { $err.ForeColor = $P.Error; $err.Text = $r.Message; $box.Focus(); $box.SelectAll() }
    })
    $dlg.Add_Shown({ $box.Focus(); $box.SelectAll() })
    [void]$dlg.ShowDialog($Owner)
    $dlg.Dispose()
    $state.Result
}

function Update-HubVoiceCredits {
    if ($script:Hub.Preview) { return }
    $credits = Invoke-HubBusy (Tx 'Leyendo los cr\u00e9ditos de ElevenLabs\u2026') { Update-ElevenCredits }
    Set-HubMessage $(if ($credits -and $credits.error -eq 'missing_permissions') { Tx 'Tu clave no puede leer los cr\u00e9ditos: en elevenlabs.io > Developers > API Keys dale el permiso User (Read) (o crea otra y p\u00e9gala).' }
        elseif ($credits) { (L 'ElevenLabs: quedan ') + (Format-ElevenCredits $credits) } else { (Tx 'No se pudieron leer los cr\u00e9ditos de ElevenLabs.') })
    $script:Hub.Cache.VoiceEngine = Get-VoiceEngineState
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubHotkeys([bool]$On) {
    if ($On) { Invoke-VoiceCtl 'hotkeys on' 'Activando los atajos de voz...' } else { Invoke-VoiceCtl 'hotkeys off' 'Atajos de voz desactivados.' }
}

# ---------------------------------------------------------------- window

# The environments are this PC's .json files: open their folder to add or edit one.
function Open-HubHarnessFolder {
    if ($script:Hub.Preview) { return }
    $dir = Join-Path $HarnessHome 'environments'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir)
}

# What switching environment $Id closes and opens, asked before doing it (here, or on the phone: lib\mobile.ps1).
function Get-HubHarnessQuestion([string]$Id) {
    $state = $script:Hub.Cache.Harness
    $target = @($state.Envs | Where-Object { $_.Id -eq $Id })[0]
    if (-not $target) { return '' }
    if ($state.Active -and $state.Active.id -eq $Id) {
        # Tx only on literal text: names and paths may hold backslashes, which Tx would try to decode.
        $ask = (Tx '\u00bfApagar ') + $target.Name + (Tx '? Se cierra solo lo suyo: sus pesta\u00f1as, servidores, Docker, m\u00fasica y carpeta, con apagado suave.')
    } else {
        $ask = (Tx '\u00bfEncender ') + $target.Name + (L '? Se cierra lo que no sea suyo (cada cierre con su motivo, con apagado suave) y se abre lo suyo.')
        if ($state.Active) { $ask += (L ' Sales de ') + $state.Active.name + '.' }
    }
    $ask
}

# A dot was clicked: turn that environment on, or off when it is the one on. Asks first, since both close things;
# -NoConfirm when the phone already asked.
function Switch-HubHarness([string]$Id, [switch]$NoConfirm) {
    if ($script:Hub.Preview) { return }
    $state = $script:Hub.Cache.Harness
    if (-not $state -or -not $state.Dir) { return }
    if ($state.Job -and $state.Job.state -eq 'running') { Set-HubMessage (Tx 'Espera: hay un cambio en curso.'); return }
    $target = @($state.Envs | Where-Object { $_.Id -eq $Id })[0]
    if (-not $target) { return }
    $isOn = $state.Active -and $state.Active.id -eq $Id
    $action = if ($isOn) { 'off' } else { 'on' }
    if (-not $NoConfirm -and -not (Confirm-UiAction (Get-HubHarnessQuestion $Id) $script:HubDialog)) { return }
    $failed = Start-HarnessJob $state.Dir $Id $action
    if ($failed) { Set-HubMessage $failed -Failed; return }
    Set-HubMessage $(if ($isOn) { (L 'Apagando {0}...') -f $target.Name } else { (L 'Encendiendo {0}...') -f $target.Name })
    Update-HubNow
}

# "Detectar ahora": the detection the tray runs every 3 minutes, now and even if nothing changed. Its offer,
# if any, comes from the tray's next tick.
function Invoke-HubHarnessDetect {
    if ($script:Hub.Preview) { return }
    $state = $script:Hub.Cache.Harness
    if (-not $state -or -not $state.Dir) { return }
    $w = $script:HarnessWatch
    if ($w.Process -and -not $w.Process.HasExited) { return }
    $w.LastRun = Get-Date
    $w.Process = Start-HarnessDetect $state.Dir -Force
    if ($w.Process) { Set-HubMessage (Tx 'Detectando qu\u00e9 ambiente encaja\u2026') } else { Set-HubMessage 'No se pudo detectar: falta Node.js o harness\env.js.' -Failed }
    Update-HubNow
}

# The window opens like a session: on the first half, quarter or screen no live session holds (Claude Code >
# sesiones por pantalla), or over the first one when all are taken. $null when the screens cannot be read.
# shortcut: the window does not hold its slot; a session opened next can land under it.
function Get-HubFreeSlot {
    try {
        $slots = Get-ScreenSlots @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea }) (Get-ScreenFirst) (Get-SessionsPerScreen)
        if (-not $slots.Count) { return $null }
        $s = $slots[(Get-FreeSlot $slots.Count @(Get-HubCodeSessions | Where-Object { $_.Live }) $true) % $slots.Count]
        New-Rect $s.X $s.Y $s.Width $s.Height
    } catch { $null }
}

# How much the window shrinks to fit the screen's work area (with a margin), 1 when it fits; never under 0.6.
function Get-HubZoom([int]$AreaWidth, [int]$AreaHeight, [int]$Width, [int]$Height, [int]$Margin = 24) {
    $zoom = [Math]::Min(1.0, [Math]::Min(($AreaWidth - $Margin) / [double]$Width, ($AreaHeight - $Margin) / [double]$Height))
    [Math]::Max(0.6, $zoom)
}

function Show-HubDialog([string]$Section = 'home', [string]$RenderPath) {
    # "home-full", "code-full"...: the preview of a section in full screen, on a 1920x1080 screen.
    $fullPreview = $false
    if ($RenderPath -and $Section -match '^(.+)-full$') { $fullPreview = $true; $Section = $Matches[1] }
    # "code-help": Claude Code with its guide to file and image previews open.
    $codeHelp = $false
    if ($Section -eq 'code-help') { $codeHelp = $true; $Section = 'code' }
    # "skills-mcp": Skills y MCP on its MCP tab.
    $skillsTab = $null
    if ($Section -eq 'skills-mcp') { $skillsTab = 'mcp'; $Section = 'skills' }
    # "envs-lists": Ambientes on its Skills y MCP tab.
    $envsTab = $null
    if ($Section -eq 'envs-lists') { $envsTab = 'lists'; $Section = 'envs' }
    # "stats-hours", "stats-models-all"...: a tab (and the all-time range) of Estadisticas.
    $statsTab = 'summary'; $statsRange = 'recent'
    if ($Section -match '^stats-([a-z]+?)(?:-(all))?$') { $statsTab = $Matches[1]; if ($Matches[2]) { $statsRange = 'all' }; $Section = 'stats' }
    # "plan-running", "plan-error", "plan-empty": the preview's sample state of Planear sesion.
    $planPreview = ''
    if ($Section -match '^plan-([a-z]+)$') { $planPreview = $Matches[1]; $Section = 'plan' }
    # "envs-busy", "envs-error", "envs-none": the preview's sample state of Ambientes.
    $envsPreview = ''
    if ($Section -match '^envs-([a-z]+)$') { $envsPreview = $Matches[1]; $Section = 'envs' }
    # "home-business": Inicio as the business edition draws it (the preview of Empresa itself is "business").
    if ($Section -eq 'home-business') { $script:BusinessPreview = $true; $Section = 'home' }
    if ($script:HubDialog) {
        if ($Section) { Set-HubSection $Section }
        Update-HubNow
        if ($script:HubDialog.WindowState -eq 'Minimized') { $script:HubDialog.WindowState = 'Normal' }
        $script:HubDialog.Activate()
        return
    }
    $P = $script:Palette
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $AppName
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.BackColor = $P.Back
    $slot = if ($RenderPath) { $null } else { Get-HubFreeSlot }
    $dlg.KeyPreview = $true
    # The window is drawn at its full size; on a screen too small for it (1366x768 at 125 %), shown smaller.
    $area = if ($slot) { $slot } else { [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea }
    $zoom = if ($RenderPath) { 1.0 } else { Get-HubZoom $area.Width $area.Height (Px $HubWidth) (Px $HubHeight) }
    $dlg.ClientSize = New-Object System.Drawing.Size([int]((Px $HubWidth) * $zoom), [int]((Px $HubHeight) * $zoom))
    if ($slot) {
        $dlg.StartPosition = 'Manual'
        $dlg.Location = New-Object System.Drawing.Point(($slot.X + [int](($slot.Width - $dlg.Width) / 2)), ($slot.Y + [int](($slot.Height - $dlg.Height) / 2)))
    }
    $appIcon = Get-AppIcon; if ($appIcon) { $dlg.Icon = $appIcon }
    Enable-DoubleBuffer $dlg
    $dlg.Tag = New-HitMap
    Register-HitMap $dlg
    $script:HubDialog = $dlg
    $script:Hub = @{ Section = $(if ($Section) { $Section } else { 'home' }); Cache = @{}
        SlowAt = [datetime]::MinValue; Message = ''; MessageAt = [datetime]::MinValue; Preview = [bool]$RenderPath; Timer = $null; Error = ''
        StatsTab = $statsTab; StatsRange = $statsRange; StatsError = ''; PlanPreview = $planPreview; EnvsPreview = $envsPreview
        W = (Px $HubWidth); H = (Px $HubHeight); Zoom = $zoom; FullScale = 1.0; Normal = $null; CodeHelp = $codeHelp; Visits = $null; SkillsTab = $skillsTab; EnvsTab = $envsTab }
    Update-HubMarks
    if ($fullPreview) {
        $screen = New-Rect 0 0 1920 1080
        Set-HubFullScreen $screen
        $dlg.ClientSize = $screen.Size
    }
    $dlg.Tag.Zoom = $script:Hub.Zoom
    # A damaged data file must not take the click handler (and the tray) down: the section just shows less.
    if ($RenderPath) { Set-HubPreview } else { try { Update-HubCache -Full; if ($script:Hub.Section -eq 'stats') { Update-HubStats } } catch { } }

    # F11 goes in and out of full screen; Esc leaves it first, then closes.
    $dlg.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'F11') { Switch-HubFullScreen }
        elseif ($e.KeyCode -eq 'Escape') {
            if ($script:Hub.Normal) { Switch-HubFullScreen }
            elseif ($script:Hub.Section -eq 'skills' -and $script:Hub.SkillsQuery) { $e.SuppressKeyPress = $true; [void](Send-HubSkillsKey ([char]27)) }
            else { $sender.Close() }
        }
    })
    # Skills y MCP: typing goes to its search box.
    $dlg.Add_KeyPress({ param($sender, $e) if (Send-HubSkillsKey $e.KeyChar) { $e.Handled = $true } })
    # Drag the window by the header or the brand area (not in full screen).
    $dlg.Add_MouseDown({
        param($sender, $e)
        if ($script:Hub.Normal -or $e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Y -gt (Px 56) * $script:Hub.Zoom) { return }
        if (Find-Hit $sender.Tag $e.Location) { return }
        [void][ClaudeTray.Native]::ReleaseCapture()
        [void][ClaudeTray.Native]::SendMessage($sender.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    })
    $dlg.Add_HandleCreated({ param($sender, $e) Set-RoundedWindow $sender $script:Palette.Border })
    $dlg.Add_Paint({
        param($sender, $e)
        $scaled = Enter-HubScale
        try {
            if ($script:Hub.Zoom -ge 1) { Draw-Hub $sender $e.Graphics }
            else {
                # TextRenderer ignores a Graphics transform: draw at full size, then scale the picture down.
                # Drawn through the bitmap's HDC, as on screen: TextRenderer (GDI) on a Graphics.FromImage would blend
                # its ClearType text against the wrong background where GDI+ filled a shape (the accent buttons).
                $full = New-Object System.Drawing.Bitmap($script:Hub.W, $script:Hub.H, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $image = [System.Drawing.Graphics]::FromImage($full)
                $hdc = $image.GetHdc()
                try {
                    $g = [System.Drawing.Graphics]::FromHdc($hdc)
                    try { $g.Clear($script:Palette.Back); Draw-Hub $sender $g } finally { $g.Dispose() }
                } finally { $image.ReleaseHdc($hdc); $image.Dispose() }
                try {
                    $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $e.Graphics.DrawImage($full, 0, 0, $sender.ClientSize.Width, $sender.ClientSize.Height)
                } finally { $full.Dispose() }
            }
        }
        catch {
            $script:Hub.Error = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            if ($script:Hub.Preview) { [Console]::Error.WriteLine('hub paint: ' + $script:Hub.Error + "`n" + $_.ScriptStackTrace) }
            # Said at the bottom of the window, so a half-drawn section is not mistaken for missing data.
            try {
                Draw-Text $e.Graphics ((Tx 'Esta secci\u00f3n no se pudo dibujar entera: ') + $script:Hub.Error) $script:Fonts.Small $script:Palette.Error ((Px $HubNavWidth) + (Px 24)) ($sender.ClientSize.Height - (Px 26)) ($sender.ClientSize.Width - (Px $HubNavWidth) - (Px 48)) (Px 20)
            } catch { }
        }
        finally { Exit-HubScale $scaled }
    })
    $dlg.Add_FormClosed({
        if ($script:Hub.Timer) { $script:Hub.Timer.Stop(); $script:Hub.Timer.Dispose() }
        if ($script:Hub.Logo) { $script:Hub.Logo.Dispose() }
        if ($script:Hub.Watermark) { $script:Hub.Watermark.Dispose() }
        if ($script:Hub.NavMark) { $script:Hub.NavMark.Dispose() }
        if ($script:Hub.StatsBitmap) { $script:Hub.StatsBitmap.Dispose() }
        foreach ($set in @($script:Hub.ScaledFonts)) { if ($set) { foreach ($f in $set.Values) { $f.Dispose() } } }
        $script:HubDialog = $null
    })

    if ($RenderPath) {
        $dlg.StartPosition = 'Manual'
        $dlg.Location = New-Object System.Drawing.Point(-5000, -5000)
        $dlg.Add_Shown({
            param($sender, $e)
            [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($sender.Width, $sender.Height)
            $sender.DrawToBitmap($bmp, (New-Rect 0 0 $sender.Width $sender.Height))
            $bmp.Save($RenderPath)
            $sender.Close()
        })
        [void]$dlg.ShowDialog()
        return
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({ Update-HubNow })
    $script:Hub.Timer = $timer
    $timer.Start()
    $dlg.Show()
    $dlg.Activate()
}

# ---------------------------------------------------------------- drawing helpers

function Draw-HubCard($G, [System.Drawing.Rectangle]$Rect) { Fill-Round $G $Rect (Px 10) $script:Palette.Surface }

# Claude Whip's icon, a whip the size of a nav glyph centred in Rect: a thick handle and a lash that curls back and
# thins out to its tip. Points on a 16-unit grid.
function Draw-HubWhipIcon($G, [System.Drawing.Rectangle]$Rect, [System.Drawing.Color]$Color) {
    $u = (Px 16) / 16.0
    $ox = $Rect.X + ($Rect.Width - (Px 16)) / 2.0
    $oy = $Rect.Y + ($Rect.Height - (Px 16)) / 2.0
    $pt = { param($x, $y) New-Object System.Drawing.PointF([single]($ox + $x * $u), [single]($oy + $y * $u)) }
    $round = [System.Drawing.Drawing2D.LineCap]::Round
    # The handle, with a knob at its end.
    $handle = New-Object System.Drawing.Pen($Color, [single](2.4 * $u))
    $handle.StartCap = $round; $handle.EndCap = $round
    $G.DrawLine($handle, (& $pt 1.6 14.4), (& $pt 5.2 10.8))
    $handle.Dispose()
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $G.FillEllipse($brush, [single]($ox + 0.1 * $u), [single]($oy + 13.1 * $u), [single](2.8 * $u), [single](2.8 * $u))
    $brush.Dispose()
    # The lash in three pieces, each thinner, as an S in the air: up from the handle, across, and down to the tip.
    foreach ($seg in @(@(1.6, @(5.2, 10.8, 8.4, 7.6, 4.6, 2.4, 8.6, 1.6)), @(1.15, @(8.6, 1.6, 12, 0.9, 10.8, 7.4, 13.6, 8.6)), @(0.75, @(13.6, 8.6, 14.8, 9.1, 15.6, 8.2, 15.4, 6.8)))) {
        $pen = New-Object System.Drawing.Pen($Color, [single]($seg[0] * $u))
        $pen.StartCap = $round; $pen.EndCap = $round
        $c = $seg[1]
        $G.DrawBezier($pen, (& $pt $c[0] $c[1]), (& $pt $c[2] $c[3]), (& $pt $c[4] $c[5]), (& $pt $c[6] $c[7]))
        $pen.Dispose()
    }
    # The crack at the tip: two short strokes.
    $spark = New-Object System.Drawing.Pen($Color, [single](0.75 * $u))
    $spark.StartCap = $round; $spark.EndCap = $round
    $G.DrawLine($spark, (& $pt 14.2 5.2), (& $pt 13.6 3.9))
    $G.DrawLine($spark, (& $pt 15.8 5.2), (& $pt 16.4 3.9))
    $spark.Dispose()
}

function Draw-HubDot($G, [int]$X, [int]$Y, [int]$Size, [System.Drawing.Color]$Color) {
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $G.FillEllipse($brush, $X, $Y, $Size, $Size)
    $brush.Dispose()
}

# A session's egg in its color (the tray's egg, lib\traysessions.ps1), centered on ($CX, $CY). Drawn once per color and size.
$script:HubEggCache = @{}
function Draw-HubEgg($G, [int]$CX, [int]$CY, [int]$Size, [string]$Hex) {
    $key = "$Hex/$Size"
    if (-not $script:HubEggCache.ContainsKey($key)) { $script:HubEggCache[$key] = New-SessionIconBitmap $Hex $Size }
    $G.DrawImage($script:HubEggCache[$key], ($CX - [int]($Size / 2)), ($CY - [int]($Size / 2)), $Size, $Size)
}

function ConvertFrom-Hex([string]$Hex) {
    try { [System.Drawing.ColorTranslator]::FromHtml($Hex) } catch { $script:Palette.Faint }
}

# On/off switch; $Action runs on click (whole $HitRect when given). Disabled: drawn faint, no click.
function Draw-HubSwitch($G, $Map, [string]$Id, [int]$X, [int]$Y, [bool]$On, [scriptblock]$Action, [bool]$Enabled = $true, $HitRect = $null) {
    $P = $script:Palette
    $switch = New-Rect $X $Y (Px 36) (Px 20)
    $track = if ($On) { if ($Enabled) { $P.Accent } else { $P.Faint } } else { $P.Track }
    Fill-Round $G $switch (Px 10) $track
    $knobX = if ($On) { $switch.Right - (Px 18) } else { $switch.X + (Px 2) }
    Draw-HubDot $G $knobX ($switch.Y + (Px 2)) (Px 16) $(if ($Enabled) { $P.AccentText } else { $P.Muted })
    if ($Enabled -and $Action) { Add-Hit $Map $Id $(if ($HitRect) { $HitRect } else { $switch }) $Action }
}

# A labeled settings row inside a card: label (and an optional second line) on the left, a switch on the right.
function Draw-HubToggleRow($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Row, [string]$Label, [string]$Sub, [bool]$On, [scriptblock]$Action, [bool]$Enabled = $true) {
    $P = $script:Palette
    $F = $script:Fonts
    if ($Enabled -and $Hover -eq $Id) { Fill-Round $G $Row (Px 6) $P.SurfaceHover }
    $labelColor = if ($Enabled) { $P.Text } else { $P.Muted }
    $textW = $Row.Width - (Px 66)
    if ($Sub) {
        Draw-Text $G $Label $F.Body $labelColor ($Row.X + (Px 10)) ($Row.Y + (Px 3)) $textW (Px 20)
        Draw-Text $G $Sub $F.Small $P.Muted ($Row.X + (Px 10)) ($Row.Y + (Px 21)) $textW (Px 18)
    } else {
        Draw-Text $G $Label $F.Body $labelColor ($Row.X + (Px 10)) $Row.Y $textW $Row.Height
    }
    Draw-HubSwitch $G $Map $Id ($Row.Right - (Px 46)) ($Row.Y + [int](($Row.Height - (Px 20)) / 2)) $On $Action $Enabled $Row
}

# "< value >" picker inside a row; each arrow steps the value.
function Draw-HubPicker($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Row, [string]$Label, [string]$Value, [string]$Command, [bool]$Enabled = $true) {
    $P = $script:Palette
    $F = $script:Fonts
    Draw-Text $G $Label $F.Body $(if ($Enabled) { $P.Text } else { $P.Muted }) ($Row.X + (Px 10)) $Row.Y (Px 120) $Row.Height
    $box = New-Rect ($Row.Right - (Px 156)) ($Row.Y + (Px 3)) (Px 148) ($Row.Height - (Px 6))
    Fill-Round $G $box (Px 7) $P.Back
    $dec = New-Rect $box.X $box.Y (Px 26) $box.Height
    $inc = New-Rect ($box.Right - (Px 26)) $box.Y (Px 26) $box.Height
    foreach ($arrow in @(@{ Rect = $dec; Id = "$Id-dec"; Glyph = '\u2039'; Delta = -1 }, @{ Rect = $inc; Id = "$Id-inc"; Glyph = '\u203a'; Delta = 1 })) {
        if ($Enabled -and $Hover -eq $arrow.Id) { Fill-Round $G $arrow.Rect (Px 7) $P.SurfaceHover }
        $color = if (-not $Enabled) { $P.Faint } elseif ($Hover -eq $arrow.Id) { $P.Accent } else { $P.Muted }
        Draw-Text $G (Tx $arrow.Glyph) $F.Close $color $arrow.Rect.X ($arrow.Rect.Y - (Px 2)) $arrow.Rect.Width $arrow.Rect.Height 'Center'
        if ($Enabled) { Add-Hit $Map $arrow.Id $arrow.Rect ([scriptblock]::Create("$Command $($arrow.Delta)")) }
    }
    Draw-Text $G $Value $F.Body $(if ($Enabled) { $P.Text } else { $P.Muted }) $dec.Right $box.Y ($inc.X - $dec.Right) $box.Height 'Center'
}

function Draw-HubCaption($G, [string]$Text, [int]$X, [int]$Y, [int]$W, [string]$Right) {
    $F = $script:Fonts
    Draw-Text $G $Text $F.Caps $script:Palette.Muted $X $Y $W (Px 18)
    if ($Right) { Draw-Text $G $Right $F.Small $script:Palette.Faint $X $Y $W (Px 18) 'Right' }
}

# A usage window (5-hour session or weekly) as label, percent, bar and reset line.
function Draw-HubUsage($G, [string]$Label, $Window, [int]$X, [int]$Y, [int]$W, [switch]$Short) {
    $P = $script:Palette
    $F = $script:Fonts
    $active = $Window -and $Window.Active
    Draw-Text $G $Label $F.Caps $P.Muted $X $Y $W (Px 20)
    # No snapshot at all is not the same as an idle window: no made-up 0 %.
    $pct = if ($active) { "$($Window.Percent)%" } elseif ($Window) { '0%' } else { [string][char]0x2013 }
    Draw-Text $G $pct $F.Number $(if ($active) { $P.Text } else { $P.Faint }) $X ($Y - (Px 4)) $W (Px 26) 'Right'
    $track = New-Rect $X ($Y + (Px 26)) $W (Px 6)
    Fill-Round $G $track (Px 3) $P.Track
    if ($active -and $Window.Percent -gt 0) {
        Fill-Round $G (New-Rect $X $track.Y ([Math]::Max((Px 6), [int]($W * [Math]::Min(100, $Window.Percent) / 100))) $track.Height) (Px 3) $P[(Get-UsageLevel $Window.Percent)]
    }
    $now = Get-Date
    if (-not $Window) { $reset = Tx 'Sin datos todav\u00eda' }
    elseif (-not $active) { $reset = 'Sin empezar' }
    elseif ($Short) { $reset = (L 'Se renueva en ') + (Format-Remaining ($Window.ResetsAt - $now)) }
    else { $reset = (L 'Se renueva ') + (Format-ResetText $Window.ResetsAt $now) }
    Draw-Text $G $reset $F.Small $P.Muted $X ($Y + (Px 36)) $W (Px 18)
}

function Get-HubRowStatus($Item) {
    $P = $script:Palette
    switch ($Item.State) {
        'pending'      { return @{ Text = 'Pendiente'; Color = $P.Muted } }
        'requested'    { return @{ Text = 'Por confirmar'; Color = $P.Muted } }
        'creating'     { return @{ Text = (Tx 'Creando\u2026'); Color = $P.Accent } }
        'cloud-ok'     { return @{ Text = (Tx '\u2713 En la nube'); Color = $P.Ok } }
        'cloud-failed' { return @{ Text = 'No se pudo crear'; Color = $P.Error } }
        'ok'           { return @{ Text = (Tx '\u2713 Hecha'); Color = $P.Ok } }
        'failed'       { return @{ Text = (Tx 'Fall\u00f3'); Color = $P.Error } }
    }
    @{ Text = 'Enviada a la nube'; Color = $P.Muted }
}

function Get-HubNextRow {
    @($script:Hub.Cache.ScheduleRows | Where-Object { $_.State -in 'pending', 'requested', 'creating', 'cloud-ok' }) | Sort-Object At | Select-Object -First 1
}

# Small marker in the side menu: a colored dot or a short text.
function Get-HubNavBadge([string]$Id) {
    $P = $script:Palette
    $c = $script:Hub.Cache
    switch ($Id) {
        'usage' {
            $view = $script:View
            if ($view -and $view.HasData -and $view.Session.Active) { return @{ Text = "$($view.Session.Percent)%"; Color = $P[(Get-UsageLevel $view.Session.Percent)] } }
        }
        'code' {
            $open = @($c.CodeSessions | Where-Object { $_.Live }).Count
            if ($open) { return @{ Text = [string]$open; Color = $P.Muted } }
        }
        'pcs' {
            $nodes = @(Get-HubNetworkNodes | Where-Object { $_.Paired })
            if (@($nodes | Where-Object { $_.State -eq 'session' }).Count) { return @{ Dot = $P.Accent } }
            if (@($nodes | Where-Object { $_.State -eq 'online' }).Count) { return @{ Dot = $P.Ok } }
        }
        'plan' { if ($c.JudgeStatus -and $c.JudgeStatus.state -eq 'running') { return @{ Dot = $P.Accent } } }
        'envs' {
            $hs = $c.Harness
            if ($hs -and $hs.Job -and $hs.Job.state -eq 'running') { return @{ Dot = $P.Accent } }
            # The tabs out of focus (its Foco y ajustes tab) count before the plain "on" dot.
            $focus = Get-HubNavBadge 'self'
            if ($focus) { return $focus }
            if ($hs -and $hs.Active) { return @{ Dot = $P.Ok } }
        }
        'self' {
            # How many open tabs do not fit the environment on (from the last detection).
            $hs = $c.Harness
            if ($hs -and $hs.Active -and $hs.Focus -and [string]$hs.Focus.active -eq [string]$hs.Active.id) {
                $n = @($hs.Focus.tabs).Count
                if ($n) { return @{ Text = [string]$n; Color = $P.Warn } }
            }
        }
        'whisper' { if ($c.WhisperRunning) { return @{ Dot = $P.Ok } } }
        'voice' { if ($c.VoiceMuted) { return @{ Text = 'off'; Color = $P.Faint } } }
    }
    $null
}

# ---------------------------------------------------------------- network diagram

# Paired PCs (with their state) and PCs with ClaudeMaxxing seen on the network but not paired, one per output.
function Get-HubNetworkNodes {
    $b = $script:Bridge
    if (-not $b -or -not $b.Ready) { return }
    $now = Get-Date
    $nodes = @()
    foreach ($peer in @($b.Peers)) {
        $seen = $b.Discovered[$peer.id]
        $online = $seen -and ($now - $seen.seen).TotalSeconds -le $BridgeSeenSeconds
        $sessions = @($b.Sessions.Values | Where-Object { $_.PeerId -eq $peer.id })
        if ($sessions.Count) {
            $state = 'session'
            $sub = (Get-SessionLabel $sessions[0]) + (L ' abierta')
            if ($sessions.Count -gt 1) { $sub = (L '{0} sesiones abiertas') -f $sessions.Count }
        } elseif ($online) { $state = 'online'; $sub = Tx 'en l\u00ednea' }
        else { $state = 'offline'; $sub = Format-SeenText $peer }
        $nodes += [pscustomobject]@{ Id = [string]$peer.id; Name = [string]$peer.name; Paired = $true; State = $state; Sub = $sub; Sessions = $sessions; Address = [string]$peer.address }
    }
    $unpaired = @($b.Discovered.Values | Where-Object { ($now - $_.seen).TotalSeconds -le $BridgeSeenSeconds -and -not (Find-BridgePeer $_.id) } | Sort-Object name)
    foreach ($pc in $unpaired) {
        $nodes += [pscustomobject]@{ Id = [string]$pc.id; Name = [string]$pc.name; Paired = $false; State = 'unpaired'; Sub = 'sin emparejar'; Sessions = @(); Address = [string]$pc.address }
    }
    $nodes
}

function New-HubPen([System.Drawing.Color]$Color, [double]$Width, [string]$Dash = 'Solid') {
    $pen = New-Object System.Drawing.Pen($Color, [single]([Math]::Max(1, $Width * $script:Scale)))
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]$Dash
    $pen
}

function Get-HubLinkStyle([string]$State) {
    $P = $script:Palette
    switch ($State) {
        'session'  { return @{ Color = $P.Accent; Width = 3; Dash = 'Solid' } }
        'online'   { return @{ Color = $P.Ok; Width = 2; Dash = 'Solid' } }
        'offline'  { return @{ Color = $P.Faint; Width = 1.5; Dash = 'Dash' } }
    }
    @{ Color = $P.Faint; Width = 1.2; Dash = 'Dot' }
}

# This PC in the middle, the other PCs around it; the line to each one says whether it is connected.
# $NodeAction: 'section' (go to Otros PCs) or 'none' for paired PCs; unpaired ones always open Otros PCs.
function Draw-HubNetwork($G, $Map, $Hover, [System.Drawing.Rectangle]$Area, [bool]$Large, [string]$NodeAction = 'section') {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $b = $script:Bridge
    $status = Get-BridgeStatus
    $x = $Area.X + (Px 16)
    $w = $Area.Width - (Px 32)
    Draw-Text $G 'RED LOCAL' $F.Caps $P.Muted $x ($Area.Y + (Px 10)) (Px 100) (Px 18)
    # The large diagram sits under the status card; the small one says it in short.
    if (-not $Large) {
        $statusText = $status.Text
        if ($b -and $b.Ready -and $status.Color -eq $P.Ok -and $b.Networks.Count) { $statusText = (L 'Red ') + ($b.Networks | Select-Object -First 1).Name }
        Draw-Text $G $statusText $F.Small $status.Color ($x + (Px 90)) ($Area.Y + (Px 10)) ($w - (Px 90)) (Px 18) 'Right'
    }

    if (-not $b -or -not $b.Ready) {
        Draw-Wrapped $G $status.Text $F.Body $status.Color $x ($Area.Y + [int]($Area.Height / 2) - (Px 20)) $w (Px 40)
        return
    }
    $nodes = @(Get-HubNetworkNodes)
    $max = 4
    $hidden = 0
    if ($nodes.Count -gt $max) { $hidden = $nodes.Count - $max; $nodes = @($nodes[0..($max - 1)]) }

    $legendY = $Area.Bottom - (Px 26)
    $top = $Area.Y + (Px 32)
    $cx = $Area.X + [int]($Area.Width / 2)
    $cy = $top + [int](($legendY - $top) / 2) - (Px 16)
    $r0 = Px $(if ($Large) { 30 } else { 24 })
    $r = Px $(if ($Large) { 23 } else { 18 })
    $rx = [int]($Area.Width / 2) - (Px $(if ($Large) { 120 } else { 64 }))
    # The other PCs alternate right and left of this one, spread top to bottom on each side (labels go under them).
    $band = $legendY - $top - (Px 6)
    $rightCount = [int][Math]::Ceiling($nodes.Count / 2)
    $leftCount = $nodes.Count - $rightCount
    $points = @()
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $onRight = ($i % 2 -eq 0)
        $k = if ($onRight) { $rightCount } else { $leftCount }
        $j = [int][Math]::Floor($i / 2)
        $ny = $top + [int]($band * ($j + 0.5) / $k) - (Px 16)
        $nx = if ($onRight) { $cx + $rx } else { $cx - $rx }
        $points += , @($nx, $ny)
    }

    # links
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $style = Get-HubLinkStyle $nodes[$i].State
        $pen = New-HubPen $style.Color $style.Width $style.Dash
        $G.DrawLine($pen, [int]$cx, [int]$cy, [int]$points[$i][0], [int]$points[$i][1])
        $pen.Dispose()
    }
    # what is open on each connected link, on its middle (the small diagram only has room for the label under the PC)
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        if (-not $Large -or $nodes[$i].State -ne 'session') { continue }
        $label = Get-SessionLabel $nodes[$i].Sessions[0]
        if ($nodes[$i].Sessions.Count -gt 1) { $label = (L '{0} sesiones') -f $nodes[$i].Sessions.Count }
        $pw = (Measure-TextWidth $label $F.Badge) + (Px 14)
        $mx = [int](($cx + $points[$i][0]) / 2)
        $my = [int](($cy + $points[$i][1]) / 2)
        $pill = New-Rect ($mx - [int]($pw / 2)) ($my - (Px 9)) $pw (Px 18)
        Fill-Round $G $pill (Px 9) $P.Accent
        Draw-Text $G $label $F.Badge $P.AccentText $pill.X $pill.Y $pill.Width $pill.Height 'Center'
    }

    # this PC
    $center = New-Rect ($cx - $r0) ($cy - $r0) (2 * $r0) (2 * $r0)
    Draw-HubDot $G $center.X $center.Y $center.Width $P.AccentTint
    $ring = New-HubPen $P.Accent 2
    $G.DrawEllipse($ring, $center)
    $ring.Dispose()
    $glyphFont = if ($Large) { $HF.NodeLarge } else { $HF.Node }
    Draw-Text $G (Tx '\ue7f4') $glyphFont $P.Accent $center.X $center.Y $center.Width $center.Height 'Center'
    $selfName = if ($b.Identity) { [string]$b.Identity.name } else { $env:COMPUTERNAME }
    Draw-Text $G 'Este PC' $HF.Label $P.Text ($cx - (Px 70)) ($center.Bottom + (Px 3)) (Px 140) (Px 16) 'Center'
    Draw-Text $G $selfName $F.Small $P.Muted ($cx - (Px 70)) ($center.Bottom + (Px 18)) (Px 140) (Px 15) 'Center'

    # other PCs
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        $nx = $points[$i][0]; $ny = $points[$i][1]
        $box = New-Rect ($nx - $r) ($ny - $r) (2 * $r) (2 * $r)
        $style = Get-HubLinkStyle $node.State
        $hitId = "node-$i"
        $fill = if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Back }
        Draw-HubDot $G $box.X $box.Y $box.Width $fill
        $border = New-HubPen $style.Color $(if ($node.State -eq 'session') { 2.5 } else { 1.5 }) $(if ($node.Paired) { 'Solid' } else { 'Dash' })
        $G.DrawEllipse($border, $box)
        $border.Dispose()
        $glyphColor = switch ($node.State) { 'session' { $P.Accent } 'online' { $P.Ok } default { $P.Faint } }
        Draw-Text $G (Tx '\ue7f4') $glyphFont $glyphColor $box.X $box.Y $box.Width $box.Height 'Center'
        $nameColor = if ($node.Paired) { $P.Text } else { $P.Muted }
        Draw-Text $G $node.Name $HF.Label $nameColor ($nx - (Px 75)) ($box.Bottom + (Px 3)) (Px 150) (Px 16) 'Center'
        $subColor = switch ($node.State) { 'session' { $P.Accent } 'online' { $P.Ok } default { $P.Faint } }
        Draw-Text $G $node.Sub $F.Small $subColor ($nx - (Px 75)) ($box.Bottom + (Px 18)) (Px 150) (Px 15) 'Center'
        $nodeRect = New-Rect ($nx - (Px 60)) $box.Y (Px 120) ($box.Height + (Px 36))
        if (-not $node.Paired) { Add-Hit $Map $hitId $nodeRect { Show-BridgeDialog } }
        elseif ($NodeAction -eq 'section') { Add-Hit $Map $hitId $nodeRect { Set-HubSection 'pcs' } }
    }
    if (-not $nodes.Count) {
        Draw-Text $G (Tx 'Ning\u00fan otro PC con ClaudeMaxxing a la vista.') $F.Small $P.Faint $x ($center.Bottom + (Px 38)) $w (Px 18) 'Center'
    }
    if ($hidden) { Draw-Text $G ("+$hidden " + (Tx 'm\u00e1s')) $F.Small $P.Muted $x ($Area.Y + (Px 30)) $w (Px 18) 'Right' }

    # legend, for the states on screen
    $lx = $x
    $shown = @($nodes | ForEach-Object { $_.State })
    foreach ($item in @(@('session', 'conectado'), @('online', (Tx 'en l\u00ednea')), @('offline', (Tx 'sin conexi\u00f3n')), @('unpaired', 'sin emparejar'))) {
        if ($shown -notcontains $item[0]) { continue }
        $style = Get-HubLinkStyle $item[0]
        $pen = New-HubPen $style.Color $style.Width $style.Dash
        $G.DrawLine($pen, [int]$lx, [int]($legendY + (Px 9)), [int]($lx + (Px 18)), [int]($legendY + (Px 9)))
        $pen.Dispose()
        $tw = Measure-TextWidth $item[1] $F.Small
        Draw-Text $G $item[1] $F.Small $P.Muted ($lx + (Px 24)) $legendY ($tw + (Px 4)) (Px 18)
        $lx += (Px 24) + $tw + (Px 14)
    }
}

# ---------------------------------------------------------------- paint

function Draw-Hub($Form, $G) {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $hub = $script:Hub
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $map = $Form.Tag
    $map.Items.Clear()
    $hover = $map.Hover
    $w = $script:Hub.W
    $h = $script:Hub.H
    $navW = Px $HubNavWidth

    # side menu
    $navBrush = New-Object System.Drawing.SolidBrush($P.Surface)
    $G.FillRectangle($navBrush, 0, 0, $navW, $h)
    $navBrush.Dispose()
    if ($hub.Logo) { $G.DrawImage($hub.Logo, (Px 16), (Px 16), $hub.Logo.Width, $hub.Logo.Height) }
    Draw-Text $G $AppName $HF.Brand $P.Text (Px 48) (Px 14) ($navW - (Px 52)) (Px 32)
    $y = Px 70
    $sections = @(Get-HubVisibleSections)
    # A caption over each group (a blank group is only a gap). Rows get closer when there are many, so the last one
    # stays above the version line.
    $groups = @($sections | ForEach-Object { $_.Group } | Where-Object { $_ } | Select-Object -Unique).Count
    $captionH = Px 24
    $step = [Math]::Min((Px 38), [int](($h - (Px 112) - $groups * $captionH) / $sections.Count))
    $group = ''
    foreach ($section in $sections) {
        if ($section.Group -and $section.Group -ne $group) {
            $group = $section.Group
            if ($group.Trim()) { Draw-Text $G $group $F.Caps $P.Faint (Px 22) ($y + (Px 6)) ($navW - (Px 32)) (Px 18) }
            $y += $captionH
        }
        $item = New-Rect (Px 10) $y ($navW - (Px 20)) (Px 34)
        $active = $hub.Section -eq $section.Id
        $hitId = "nav-$($section.Id)"
        if ($active) { Fill-Round $G $item (Px 8) $P.AccentTint } elseif ($hover -eq $hitId) { Fill-Round $G $item (Px 8) $P.SurfaceHover }
        $iconColor = if ($active) { $P.Accent } else { $P.Muted }
        if ($section.Icon) { & $section.Icon $G (New-Rect ($item.X + (Px 8)) $item.Y (Px 24) $item.Height) $iconColor }
        else { Draw-Text $G (Tx $section.Glyph) $HF.Icon $iconColor ($item.X + (Px 8)) $item.Y (Px 24) $item.Height 'Center' }
        $badge = Get-HubNavBadge $section.Id
        # The label takes the room its badge leaves ("Copiloto de llamadas" fits when there is none).
        $labelW = $item.Width - $(if (-not $badge) { Px 48 } elseif ($badge.Dot) { Px 60 } else { Px 76 })
        Draw-Text $G $section.Label $(if ($active) { $HF.NavStrong } else { $HF.Nav }) $(if ($active) { $P.Accent } else { $P.Text }) ($item.X + (Px 40)) $item.Y $labelW $item.Height
        if ($badge -and $badge.Dot) { Draw-HubDot $G ($item.Right - (Px 20)) ($item.Y + (Px 13)) (Px 8) $badge.Dot }
        elseif ($badge) { Draw-Text $G $badge.Text $F.Small $badge.Color ($item.Right - (Px 50)) $item.Y (Px 40) $item.Height 'Right' }
        if (-not $active) { Add-Hit $map $hitId $item ([scriptblock]::Create("Set-HubSection '$($section.Id)'")) }
        $y += $step
    }
    # A small faint jellyfish in the free space between the last section and the version line (when there is any).
    if ($hub.NavMark -and $y -le $h - $hub.NavMark.Height - (Px 40)) { $G.DrawImage($hub.NavMark, $navW - $hub.NavMark.Width - (Px 14), $h - $hub.NavMark.Height - (Px 40), $hub.NavMark.Width, $hub.NavMark.Height) }
    $plan = if ($script:Plan) { "Plan $($script:Plan)  " + (Tx '\u00b7  ') } else { '' }
    Draw-Text $G ($plan + "v$AppVersion") $F.Small $P.Faint (Px 22) ($h - (Px 36)) ($navW - (Px 30)) (Px 20)
    $pen = New-Object System.Drawing.Pen($P.Border)
    $G.DrawLine($pen, $navW, 0, $navW, $h)

    # header
    $x0 = $navW + (Px 24)
    $inner = $w - $x0 - (Px 24)
    $title = (@($script:HubSections | Where-Object { $_.Id -eq $hub.Section })[0]).Label

    if ($hub.Section -eq 'plan') { $title = Tx 'Planear sesi\u00f3n del d\u00eda' }
    if ($hub.Section -eq 'self') { $title = 'Ambientes' }
    Draw-Text $G $title $F.Title $P.Text $x0 (Px 14) (Px 320) (Px 32)
    # Minimize, maximize (full screen, F11) and close, with the Windows caption glyphs (Segoe MDL2: ChromeMinimize,
    # ChromeMaximize / ChromeRestore, ChromeClose); close turns red on hover like Windows.
    $close = New-Rect ($w - (Px 52)) (Px 16) (Px 30) (Px 30)
    if ($hover -eq 'close') { Fill-Round $G $close (Px 6) ([System.Drawing.Color]::FromArgb(196, 43, 28)) }
    Draw-Text $G (Tx '\ue8bb') $HF.Icon $(if ($hover -eq 'close') { [System.Drawing.Color]::White } else { $P.Muted }) $close.X $close.Y $close.Width $close.Height 'Center'
    Add-Hit $map 'close' $close { $script:HubDialog.Close() } 'Cerrar (Esc)'
    $full = New-Rect ($close.X - (Px 34)) $close.Y $close.Width $close.Height
    if ($hover -eq 'fullscreen') { Fill-Round $G $full (Px 6) $P.SurfaceHover }
    Draw-Text $G (Tx $(if ($hub.Normal) { '\ue923' } else { '\ue922' })) $HF.Icon $P.Muted $full.X $full.Y $full.Width $full.Height 'Center'
    Add-Hit $map 'fullscreen' $full { Switch-HubFullScreen } $(if ($hub.Normal) { 'Salir de pantalla completa (F11)' } else { 'Pantalla completa (F11)' })
    $min = New-Rect ($full.X - (Px 34)) $close.Y $close.Width $close.Height
    if ($hover -eq 'minimize') { Fill-Round $G $min (Px 6) $P.SurfaceHover }
    Draw-Text $G (Tx '\ue921') $HF.Icon $P.Muted $min.X $min.Y $min.Width $min.Height 'Center'
    Add-Hit $map 'minimize' $min { $script:HubDialog.WindowState = 'Minimized' } 'Minimizar'
    if ($hub.Message -and ((Get-Date) - $hub.MessageAt).TotalSeconds -lt $(if ($hub.MessageError) { 15 } else { 8 })) {
        Draw-Text $G $hub.Message $F.Small $(if ($hub.MessageError) { $P.Error } else { $P.Accent }) ($x0 + (Px 220)) (Px 20) ($min.X - $x0 - (Px 230)) (Px 20) 'Right'
    }
    $G.DrawLine($pen, $x0, (Px 56), $x0 + $inner, (Px 56))
    $pen.Dispose()
    # The jellyfish peeks in faintly from the bottom-right corner of every section, under its cards.
    if ($hub.Watermark) { $G.DrawImage($hub.Watermark, $w - (Px 300), $h - (Px 330), $hub.Watermark.Width, $hub.Watermark.Height) }

    switch ($hub.Section) {
        'business' { Draw-HubBusinessSection $G $map $hover $x0 $inner }
        'plan'    { Draw-HubPlanSession $G $map $hover $x0 $inner }
        'envs'    { Draw-HubAmbientes $G $map $hover $x0 $inner }
        'self'    { Draw-HubAmbientes $G $map $hover $x0 $inner }
        'usage'   { Draw-HubUsageSection $G $map $hover $x0 $inner }
        'stats'   { Draw-HubStatsSection $G $map $hover $x0 $inner }
        'code'    { Draw-HubCodeSection $G $map $hover $x0 $inner }
        'skills'  { Draw-HubSkillsSection $G $map $hover $x0 $inner }
        'whip'    { Draw-HubWhipSection $G $map $hover $x0 $inner }
        'pcs'     { Draw-HubPcsSection $G $map $hover $x0 $inner }
        'whisper' { Draw-HubWhisperSection $G $map $hover $x0 $inner }
        'mobile'  { Draw-HubMobileSection $G $map $hover $x0 $inner }
        'voice'   { Draw-HubVoiceSection $G $map $hover $x0 $inner }
        'settings' { Draw-HubSettingsSection $G $map $hover $x0 $inner }
        default   { Draw-HubHome $G $map $hover $x0 $inner }
    }

    $border = New-Object System.Drawing.Pen($P.Border)
    $G.DrawRectangle($border, 0, 0, $w - 1, $h - 1)
    $border.Dispose()
}

# ---------------------------------------------------------------- Ambientes

function Format-HubHarnessTime($Iso) {
    try { ([datetime]$Iso).ToString('HH:mm') } catch { '' }
}

# The prompt that has Claude Code write the environments: it reads this PC's usage and sessions, proposes them, asks
# what it cannot tell, writes each .json and checks it with a preview (which never closes anything). Real paths.
function Get-HubEnvPrompt {
    $harness = Get-HarnessDir
    if (-not $harness) { $harness = Join-Path $TrayRoot 'harness' }
    # Tx only on the text: a path could hold "\u" followed by four hex digits. {0}..{6} are the paths.
    $paths = @((Join-Path $harness 'README.md'), (Join-Path $harness 'test\environments\trabajo.json'), $StatsFile, $SessionsFile,
        (Join-Path $env:USERPROFILE '.claude\projects'), (Join-Path (Join-Path $HarnessHome 'environments') '<id>.json'), (Join-Path $harness 'env.js'))
    $text = Tx ((Tx 'Ay\u00fadame a crear mis ambientes de trabajo de ClaudeMaxxing. Un ambiente es un JSON que dice qu\u00e9 abrir y qu\u00e9 cerrar para entrar en foco en un proyecto (pesta\u00f1as de Chrome, carpetas, servidores, Docker, m\u00fasica, apps, una sesi\u00f3n de Claude Code).') +
        '||1. Lee el formato en {0} (secci\u00f3n Ambientes) y el ejemplo {1}.' +
        '|2. Analiza c\u00f3mo trabajo: mi consumo y mis proyectos en {2} (horas, proyectos, horarios), mis sesiones en {3} y las carpetas de mis conversaciones en {4}. Res\u00famelo en una tabla corta: proyecto, horas, cu\u00e1ndo.' +
        '|3. Prop\u00f3n de 2 a 5 ambientes (uno por proyecto o tipo de trabajo, y uno para descansar o terminar el d\u00eda si encaja), con su carpeta, la sesi\u00f3n de Claude Code, los servidores de desarrollo que veas en cada proyecto (package.json, docker-compose) y las pesta\u00f1as \u00fatiles. Preg\u00fantame lo que no puedas saber: el perfil de Chrome, la m\u00fasica, qu\u00e9 cerrar.' +
        '|4. Cuando te diga que s\u00ed, escribe cada uno en {5} (id en min\u00fasculas, sin espacios) y pru\u00e9balo con: node "{6}" <id>  (solo la vista previa: nunca uses --yes ni enciendas un ambiente).' +
        '||No cierres ni abras nada en mi PC: solo lee y escribe esos archivos.')
    ($text -f $paths).Replace('|', "`r`n")
}

function Copy-HubEnvPrompt {
    if ($script:Hub.Preview) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText((Get-HubEnvPrompt))
        Set-HubMessage (Tx 'Prompt copiado: p\u00e9galo en una sesi\u00f3n de Claude Code')
    } catch { Set-HubMessage 'No se pudo copiar el prompt' -Failed }
}

# Ambientes with none yet (a new install starts so): how one is made, and the prompt that has Claude make them.
function Draw-HubEnvsStart($G, $Map, $Hover, [int]$X0, [int]$Y, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $card = New-Rect $X0 $Y $Inner (Px 262)
    Draw-HubCard $G $card
    $cx = $card.X + (Px 16)
    $cw = $card.Width - (Px 32)
    $copyW = Get-PillWidth 'Copiar prompt'
    $newW = Get-PillWidth (Tx 'Nueva sesi\u00f3n...')
    Draw-PillButton $G $Map $Hover 'envs-copy' (New-Rect ($card.Right - (Px 16) - $copyW) ($card.Y + (Px 14)) $copyW (Px 26)) 'Copiar prompt' { Copy-HubEnvPrompt } -Accent
    Draw-PillButton $G $Map $Hover 'envs-session' (New-Rect ($card.Right - (Px 24) - $copyW - $newW) ($card.Y + (Px 14)) $newW (Px 26)) (Tx 'Nueva sesi\u00f3n...') { Open-HubCodeSession }
    $tw = $cw - $copyW - $newW - (Px 16)
    Draw-Text $G (Tx 'Que Claude cree tus ambientes') $F.BodyStrong $P.Text $cx ($card.Y + (Px 12)) $tw (Px 22)
    Draw-Text $G (Tx 'Copia el prompt y p\u00e9galo en una sesi\u00f3n de Claude Code.') $F.Small $P.Muted $cx ($card.Y + (Px 34)) $tw (Px 18)
    # The prompt as it will be pasted (its paths are this PC's), in a box like a code block.
    $box = New-Rect $cx ($card.Y + (Px 62)) $cw ($card.Bottom - (Px 14) - ($card.Y + (Px 62)))
    Fill-Round $G $box (Px 8) $P.Back
    # Whole lines only (the rest is in the clipboard copy), ending in an ellipsis.
    $lineH = $script:HubFonts.Key.Height
    Draw-Wrapped $G (Get-HubEnvPrompt) $script:HubFonts.Key $P.Muted ($box.X + (Px 12)) ($box.Y + (Px 10)) ($box.Width - (Px 24)) ([Math]::Floor(($box.Height - (Px 20)) / $lineH) * $lineH)

    $y = $card.Bottom + (Px 16)
    Draw-HubCaption $G (Tx 'C\u00d3MO SE CREA UN AMBIENTE') $X0 $y $Inner 'empiezas sin ninguno'
    $y += Px 24
    $steps = @(
        'Claude analiza tu consumo y tus sesiones: en qu\u00e9 proyectos trabajas, cu\u00e1ntas horas y a qu\u00e9 horas.',
        'Te propone los ambientes, uno por proyecto o tipo de trabajo, y te pregunta lo que no sabe: el perfil de Chrome, la m\u00fasica, qu\u00e9 cerrar.',
        'Escribe un .json por ambiente en la carpeta de ambientes y lo prueba en vista previa, sin cerrar nada.',
        'Aparecen aqu\u00ed como bolitas: haz clic en una para encenderla. A mano: copia el ejemplo trabajo.json a la carpeta y ed\u00edtalo.'
    )
    $folderW = Get-PillWidth 'Abrir carpeta'
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Draw-Text $G ([string]($i + 1)) $F.BodyStrong $P.Accent $X0 $y (Px 18) (Px 18)
        $sw = $Inner - (Px 24) - $(if ($i -eq $steps.Count - 1) { $folderW + (Px 12) } else { 0 })
        Draw-Wrapped $G (Tx $steps[$i]) $F.Small $P.Muted ($X0 + (Px 24)) ($y + (Px 1)) $sw (Px 32)
        $y += Px 36
    }
    Draw-PillButton $G $Map $Hover 'envs-folder' (New-Rect ($X0 + $Inner - $folderW) ($y - (Px 36)) $folderW (Px 26)) 'Abrir carpeta' { Open-HubHarnessFolder }
}

# One dot per environment (harness\env.js): green on, accent while changing, track off, error ring when the last
# change failed. Clicking a dot turns it on (or off when it is the one on); no clicks while a change runs.
function Draw-HubEnvsSection($G, $Map, $Hover, [int]$X0, [int]$Inner, [int]$OffsetY = 0) {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $hs = $script:Hub.Cache.Harness
    $y = (Px 72) + $OffsetY

    if (-not $hs -or -not $hs.Dir) {
        $card = New-Rect $X0 $y $Inner (Px 80)
        Draw-HubCard $G $card
        Draw-Text $G 'Falta harness\env.js' $F.BodyStrong $P.Text ($card.X + (Px 16)) ($card.Y + (Px 12)) ($card.Width - (Px 32)) (Px 22)
        Draw-Wrapped $G (Tx 'Los ambientes vienen con ClaudeMaxxing: vuelve a ejecutar install.ps1. Necesitan Node.js y la extensi\u00f3n de Chrome (harness\\extension, cargada en cada perfil).') $F.Small $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 38)) ($card.Width - (Px 32)) (Px 36)
        return
    }

    $envs = @($hs.Envs)
    $job = $hs.Job
    $running = $job -and $job.state -eq 'running'
    $activeId = if ($hs.Active) { [string]$hs.Active.id } else { '' }
    $right = if ($hs.Active) { (L 'Encendido: ') + $hs.Active.name + (L ' desde ') + (Format-HubHarnessTime $hs.Active.since) } else { 'Ninguno encendido' }
    Draw-HubCaption $G 'CAMBIOS ENTRE AMBIENTES' $X0 $y $Inner $right
    $y += Px 28

    if (-not $envs.Count) { Draw-HubEnvsStart $G $Map $Hover $X0 $y $Inner; return }

    # A graph: the environments on an ellipse, one arrow per direction you have switched (with how many times)
    # and, under each one, the time spent there today and in total. Hovering one lights its arrows.
    # Each node's name and time sit outside the ellipse (left, right, above or below), so the arrows inside stay clear.
    $graph = Get-HarnessGraph $hs
    $size = Px 46
    $textW = Px 128
    $cx = $X0 + [int]($Inner / 2)
    $cy = $y + (Px 172)
    $rx = [Math]::Min((Px 190), [int](($Inner / 2 - $textW - $size / 2 - (Px 10)) / 0.87))
    $ry = Px 108
    $pos = @{}
    for ($i = 0; $i -lt $envs.Count; $i++) {
        $angle = -[Math]::PI / 2 + 2 * [Math]::PI * $i / $envs.Count
        $pos[$envs[$i].Id] = @{ X = $cx + $rx * [Math]::Cos($angle); Y = $cy + $ry * [Math]::Sin($angle); Cos = [Math]::Cos($angle); Sin = [Math]::Sin($angle) }
    }
    $hoverId = if ($Hover -like 'env-*') { $Hover.Substring(4) } else { '' }
    $suggested = if ($hs.Detect -and $hs.Detect.offer) { [string]$hs.Detect.suggestion } else { '' }
    $most = [Math]::Max(1, [int](@($graph.Edges | ForEach-Object { $_.Count }) + 0 | Measure-Object -Maximum).Maximum)
    $labels = @()
    foreach ($edge in @($graph.Edges)) {
        $a = $pos[$edge.From]; $b = $pos[$edge.To]
        $dx = $b.X - $a.X; $dy = $b.Y - $a.Y
        $len = [Math]::Sqrt($dx * $dx + $dy * $dy)
        if ($len -lt 1) { continue }
        $ux = $dx / $len; $uy = $dy / $len
        # Each direction to the right of its travel, so A->B and B->A are two arrows side by side.
        $ox = -$uy * (Px 5); $oy = $ux * (Px 5)
        $gap = $size / 2 + (Px 5)
        $x1 = $a.X + $ux * $gap + $ox; $y1 = $a.Y + $uy * $gap + $oy
        $x2 = $b.X - $ux * $gap + $ox; $y2 = $b.Y - $uy * $gap + $oy
        $lit = $hoverId -and ($edge.From -eq $hoverId -or $edge.To -eq $hoverId)
        $pen = New-HubPen $(if ($lit) { $P.Accent } else { $P.Faint }) (1.5 + 2 * $edge.Count / $most)
        $pen.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(3, 3)
        $G.DrawLine($pen, [single]$x1, [single]$y1, [single]$x2, [single]$y2)
        $pen.Dispose()
        # Its count near the arrow head, on its own side: drawn after every arrow so no line crosses it.
        $labels += @{ X = $x1 + ($x2 - $x1) * 0.66 + $ox * 2.4; Y = $y1 + ($y2 - $y1) * 0.66 + $oy * 2.4; Text = [string]$edge.Count; Lit = $lit }
    }
    foreach ($l in $labels) {
        $lw = (Measure-TextWidth $l.Text $F.Small) + (Px 10)
        $box = New-Rect ([int]($l.X - $lw / 2)) ([int]($l.Y - (Px 9))) $lw (Px 18)
        Fill-Round $G $box (Px 9) $P.Surface
        Draw-Text $G $l.Text $F.Small $(if ($l.Lit) { $P.Accent } else { $P.Muted }) $box.X $box.Y $box.Width $box.Height 'Center'
    }

    foreach ($e in $envs) {
        $c = $pos[$e.Id]
        $dot = New-Rect ([int]($c.X - $size / 2)) ([int]($c.Y - $size / 2)) $size $size
        $hitId = "env-$($e.Id)"
        $busy = $running -and $job.id -eq $e.Id
        $on = $activeId -eq $e.Id
        $failed = -not $running -and $job -and $job.id -eq $e.Id -and $job.state -eq 'error'

        if (-not $running -and $Hover -eq $hitId) {
            Draw-HubDot $G ($dot.X - (Px 6)) ($dot.Y - (Px 6)) ($size + (Px 12)) $P.SurfaceHover
        }
        if ($e.Id -eq $suggested) {
            # The detection says you are here: a dashed ring until you switch.
            $pen = New-HubPen $P.Accent 2 'Dash'
            $G.DrawEllipse($pen, $dot.X - (Px 5), $dot.Y - (Px 5), $size + (Px 10), $size + (Px 10))
            $pen.Dispose()
        }
        Draw-HubDot $G $dot.X $dot.Y $size $(if ($busy) { $P.Accent } elseif ($on) { $P.Ok } else { $P.Track })
        if ($failed) {
            $pen = New-Object System.Drawing.Pen($P.Error, (Px 3))
            $G.DrawEllipse($pen, $dot.X - (Px 2), $dot.Y - (Px 2), $size + (Px 4), $size + (Px 4))
            $pen.Dispose()
        }
        Draw-Text $G (Tx '\ue7e8') $HF.NodeLarge $(if ($busy -or $on) { $P.AccentText } else { $P.Muted }) $dot.X $dot.Y $dot.Width $dot.Height 'Center'

        $t = $graph.Time[$e.Id]
        if ($busy) {
            $line = if ($job.step) { [string]$job.step } elseif ($job.action -eq 'off') { Tx 'Apagando\u2026' } else { Tx 'Encendiendo\u2026' }
            $color = $P.Accent
        } elseif ($failed) { $line = (Tx 'Fall\u00f3: ') + [string]$job.message; $color = $P.Error }
        elseif ($t.Total -lt 60) { $line = $(if ($on) { 'Encendido' } else { 'Sin tiempo' }); $color = $(if ($on) { $P.Ok } else { $P.Faint }) }
        else { $line = (L 'hoy ') + (Format-HubDuration $t.Today) + (Tx ' \u00b7 ') + (Format-HubDuration $t.Total); $color = $(if ($on) { $P.Ok } else { $P.Muted }) }
        # The detection's pick says so in words, not only with its dashed ring.
        if (-not $busy -and -not $failed -and -not $on -and $e.Id -eq $suggested) {
            $line = (L 'sugerido') + $(if ($t.Today -ge 60) { (Tx ' \u00b7 ') + (Format-HubDuration $t.Today) } else { '' })
            $color = $P.Accent
        }
        $textH = Px 37
        if ($c.Cos -gt 0.3) { $textX = $dot.Right + (Px 8); $ty = [int]($c.Y - $textH / 2); $align = 'Left' }
        elseif ($c.Cos -lt -0.3) { $textX = $dot.X - (Px 8) - $textW; $ty = [int]($c.Y - $textH / 2); $align = 'Right' }
        elseif ($c.Sin -lt 0) { $textX = [int]($c.X - $textW / 2); $ty = $dot.Y - (Px 4) - $textH; $align = 'Center' }
        else { $textX = [int]($c.X - $textW / 2); $ty = $dot.Bottom + (Px 4); $align = 'Center' }
        Draw-Text $G ([string]$e.Name) $F.BodyStrong $P.Text $textX $ty $textW (Px 20) $align
        Draw-Text $G $line $F.Small $color $textX ($ty + (Px 20)) $textW (Px 17) $align

        if (-not $running) {
            $tip = if ($on) { (L 'Apagar {0}') -f $e.Name } else { (L 'Encender {0}') -f $e.Name }
            if ($e.Focus) { $tip += ': ' + $e.Focus }
            $left = [Math]::Min($dot.X, $textX); $top = [Math]::Min($dot.Y, $ty)
            $hit = New-Rect $left $top ([Math]::Max($dot.Right, $textX + $textW) - $left) ([Math]::Max($dot.Bottom, $ty + $textH) - $top)
            Add-Hit $Map $hitId $hit ([scriptblock]::Create("Switch-HubHarness '$($e.Id)'")) $tip
        }
    }
    $y += Px 350

    # The last change, in full: its step while it runs, what failed, or when it ended.
    $card = New-Rect $X0 $y $Inner (Px 64)
    Draw-HubCard $G $card
    $bw = Get-PillWidth 'Abrir carpeta'
    Draw-PillButton $G $Map $Hover 'envs-folder' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 18)) $bw (Px 26)) 'Abrir carpeta' { Open-HubHarnessFolder }
    # More environments, made by Claude: the same prompt as when there are none.
    $pw = Get-PillWidth 'Crear con Claude'
    Draw-PillButton $G $Map $Hover 'envs-copy' (New-Rect ($card.Right - (Px 24) - $bw - $pw) ($card.Y + (Px 18)) $pw (Px 26)) 'Crear con Claude' { Copy-HubEnvPrompt }
    $bw += $pw + (Px 8)
    $tw = $card.Width - $bw - (Px 48)
    if ($job) {
        $verb = if ($job.action -eq 'off') { L 'Apagar' } else { L 'Encender' }
        $when = if ($job.endedAt) { (Tx ' \u00b7 ') + (Format-HubHarnessTime $job.endedAt) } else { '' }
        $title = "$verb $($job.name)$when"
        switch ($job.state) {
            'running' { $sub = (Tx 'En curso: ') + [string]$job.step; $subColor = $P.Accent }
            'error'   { $sub = (Tx 'Fall\u00f3: ') + [string]$job.message; $subColor = $P.Error }
            default   { $sub = $(if ($job.message) { (Tx '\u2713 Hecho, con avisos: ') + [string]$job.message } else { Tx '\u2713 Hecho' }); $subColor = $(if ($job.message) { $P.Warn } else { $P.Ok }) }
        }
    } else {
        $title = (Tx 'Ning\u00fan cambio todav\u00eda')
        $sub = 'Haz clic en una bolita para encender o apagar su ambiente.'
        $subColor = $P.Muted
    }
    Draw-Text $G $title $F.BodyStrong $P.Text ($card.X + (Px 16)) ($card.Y + (Px 12)) $tw (Px 22)
    Draw-Text $G $sub $F.Small $subColor ($card.X + (Px 16)) ($card.Y + (Px 36)) $tw (Px 18)
    $y = $card.Bottom + (Px 10)

    # The detection: which environment what is open fits (env.js detect, every 3 minutes from the tray). When it
    # finds you in another one, the same question the tray asks, with its two answers.
    $d = $hs.Detect
    if ($d -and $d.offer -and $d.suggestion -and -not $running) {
        $card = New-Rect $X0 $y $Inner (Px 70)
        Fill-Round $G $card (Px 10) $P.AccentTint
        $stay = (L 'Sigo en ') + $(if ($hs.Active) { $hs.Active.name } else { '' })
        $go = (L 'Cambiar a ') + $d.name
        $gw = Get-PillWidth $go
        $sw = Get-PillWidth $stay
        Draw-PillButton $G $Map $Hover 'envs-offer-go' (New-Rect ($card.Right - (Px 16) - $gw) ($card.Y + (Px 21)) $gw (Px 28)) $go ([scriptblock]::Create("Switch-HubHarness '$($d.suggestion)'")) -Accent
        Draw-PillButton $G $Map $Hover 'envs-offer-stay' (New-Rect ($card.Right - (Px 24) - $gw - $sw) ($card.Y + (Px 21)) $sw (Px 28)) $stay { Skip-HubHarnessOffer }
        $tw = $card.Width - $gw - $sw - (Px 56)
        Draw-Text $G ((Tx '\u00bfCambiar a ') + $d.name + '?') $F.BodyStrong $P.Text ($card.X + (Px 16)) ($card.Y + (Px 12)) $tw (Px 22)
        Draw-Text $G (((L 'Lo abierto encaja un {0} % con {1}') -f [int]([double]$d.confidence * 100), $d.name) + (Tx ' \u00b7 ') + (Format-HubHarnessTime $d.at) + (Tx ' \u00b7 seg\u00fan ') + (Format-HarnessJudge $d.judge)) $F.Small $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 38)) $tw (Px 18)
        return
    }
    $card = New-Rect $X0 $y $Inner (Px 64)
    Draw-HubCard $G $card
    $bw = Get-PillWidth 'Detectar ahora'
    $w = $script:HarnessWatch
    $detecting = $w -and $w.Process -and -not $w.Process.HasExited
    if (-not $detecting) { Draw-PillButton $G $Map $Hover 'envs-detect' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 18)) $bw (Px 26)) 'Detectar ahora' { Invoke-HubHarnessDetect } }
    $tw = $card.Width - $bw - (Px 48)
    if ($d -and $d.at) {
        $when = (Tx ' \u00b7 ') + (Format-HubHarnessTime $d.at)
        if ($d.error) { $title = (Tx 'Detecci\u00f3n') + $when; $sub = (Tx 'Fall\u00f3: ') + [string]$d.error; $subColor = $P.Error }
        else {
            $title = $(if ($d.suggestion) { (L 'Parece ') + $d.name } else { Tx 'No encaja en ning\u00fan ambiente' }) + $when
            $sub = (Tx 'Seg\u00fan ') + (Format-HarnessJudge $d.judge) + ', ' + [int]([double]$d.confidence * 100) + ' %' + $(if ($d.reason) { ': ' + $d.reason } else { '' })
            $subColor = if ($d.offer) { $P.Accent } else { $P.Muted }
        }
    } else {
        $title = (Tx 'Sin detecci\u00f3n todav\u00eda')
        $sub = (Tx 'Cada 3 minutos se mira qu\u00e9 tienes abierto; si es de otro ambiente, te pregunta si quieres pasarte.')
        $subColor = $P.Muted
    }
    if ($detecting) { $sub = (Tx 'Mirando qu\u00e9 tienes abierto\u2026'); $subColor = $P.Accent }
    Draw-Text $G $title $F.BodyStrong $P.Text ($card.X + (Px 16)) ($card.Y + (Px 12)) $tw (Px 22)
    Draw-Text $G $sub $F.Small $subColor ($card.X + (Px 16)) ($card.Y + (Px 36)) $(if ($detecting) { $card.Width - (Px 32) } else { $tw }) (Px 18)
}

# ---------------------------------------------------------------- SelfHarness

function Format-HubAgo($Iso) {
    try { $minutes = [int]((Get-Date) - [datetime]$Iso).TotalMinutes } catch { return '' }
    if ($minutes -lt 1) { L 'ahora' } else { (L 'hace {0}') -f (Format-HubDuration ($minutes * 60)) }
}

# Up to $Max environments as "Name 1 h 20 min \u00b7 Name 40 min", biggest first, from Get-HarnessGraph's times.
function Format-HubEnvTimes($Graph, $Envs, [string]$Field, [int]$Max = 4) {
    $rows = @(foreach ($e in @($Envs)) {
        $t = $Graph.Time[$e.Id]
        if ($t -and $t[$Field] -ge 60) { [pscustomobject]@{ Name = $e.Name; Secs = [double]$t[$Field] } }
    })
    if (-not $rows.Count) { return [string][char]0x2013 }
    (@($rows | Sort-Object Secs -Descending | Select-Object -First $Max | ForEach-Object { $_.Name + ' ' + (Format-HubDuration $_.Secs) })) -join (Tx ' \u00b7 ')
}

# The watcher on yourself: what the environment on would close (focus drift), the dev servers listening, the
# watcher's settings and a few numbers from the environments' history. Drift and servers come from
# harness\env.js detect (run\focus.json), refreshed with every detection or with "Revisar ahora".
function Draw-HubSelfSection($G, $Map, $Hover, [int]$X0, [int]$Inner, [int]$OffsetY = 0) {
    $P = $script:Palette
    $F = $script:Fonts
    $hs = $script:Hub.Cache.Harness
    $set = $script:Hub.Cache.SelfHarness
    if (-not $set) { $set = Get-SelfHarnessSettings $null }
    $y = (Px 72) + $OffsetY
    if (-not $hs -or -not $hs.Dir) {
        Draw-Text $G 'Falta harness\env.js: vuelve a ejecutar install.ps1.' $F.Body $P.Muted $X0 $y $Inner (Px 24)
        return
    }
    $colW = [int](($Inner - (Px 16)) / 2)
    $rx = $X0 + $colW + (Px 16)
    $focus = $hs.Focus
    $w = $script:HarnessWatch
    $detecting = $w -and $w.Process -and -not $w.Process.HasExited
    $activeId = if ($hs.Active) { [string]$hs.Active.id } else { '' }
    # The drift is about the environment on now; one computed for another (before a switch) is not shown.
    $fresh = $focus -and $focus.at -and [string]$focus.active -eq $activeId
    $at = if ($focus) { [string]$focus.at } else { '' }
    $hiddenTabs = if ($w -and $w.Hidden[$at]) { @($w.Hidden[$at]) } else { @() }
    $hiddenPorts = if ($w -and $w.Hidden["$at|ports"]) { @($w.Hidden["$at|ports"]) } else { @() }

    # ---- focus drift (left)
    $when = if ($detecting) { Tx 'revisando\u2026' } elseif ($at) { Format-HubAgo $at } else { '' }
    Draw-HubCaption $G 'DISTRACCIONES AHORA' $X0 $y $colW $when
    $card = New-Rect $X0 ($y + (Px 24)) $colW (Px 300)
    Draw-HubCard $G $card
    $ix = $card.X + (Px 12)
    $iw = $card.Width - (Px 24)
    $iy = $card.Y + (Px 10)
    # @(...) outside the if: an if returns one item unwrapped, and a lone pscustomobject has no .Count in PS 5.1.
    $tabs = @(if ($fresh) { $focus.tabs | Where-Object { $hiddenTabs -notcontains [long]$_.id } })
    if (-not $hs.Active) {
        Draw-Wrapped $G (Tx 'Enciende un ambiente en Ambientes: aqu\u00ed saldr\u00e1 lo que no encaja con \u00e9l, cada cosa con su motivo.') $F.Small $P.Muted $ix $iy $iw (Px 54)
    } elseif (-not $fresh) {
        Draw-Wrapped $G ((Tx 'Todav\u00eda no se ha revisado lo abierto con ') + $hs.Active.name + (Tx ': pulsa Revisar ahora.')) $F.Small $P.Muted $ix $iy $iw (Px 54)
    } elseif (-not $tabs.Count) {
        Draw-Text $G ((Tx '\u2713 Todo encaja con ') + $hs.Active.name) $F.BodyStrong $P.Ok $ix $iy $iw (Px 22)
    } else {
        Draw-Text $G ([string]$tabs.Count + $(if ($tabs.Count -eq 1) { Tx ' pesta\u00f1a no encaja con ' } else { Tx ' pesta\u00f1as no encajan con ' }) + $hs.Active.name) $F.BodyStrong $P.Text $ix $iy $iw (Px 22)
        $ry = $iy + (Px 28)
        foreach ($t in @($tabs | Select-Object -First 5)) {
            $row = New-Rect ($ix - (Px 6)) $ry ($iw + (Px 12)) (Px 38)
            $closeId = "self-close-$($t.id)"
            if ($Hover -eq $closeId) { Fill-Round $G $row (Px 6) $P.SurfaceHover }
            Draw-Text $G ([string]$t.title) $F.Body $P.Text $ix ($ry + (Px 1)) ($iw - (Px 30)) (Px 19)
            Draw-Text $G ([string]$t.profile + (Tx ' \u00b7 ') + [string]$t.reason) $F.Small $P.Muted $ix ($ry + (Px 19)) ($iw - (Px 30)) (Px 17)
            $x = New-Rect ($row.Right - (Px 30)) ($ry + (Px 7)) (Px 24) (Px 24)
            Draw-Text $G (Tx '\u2715') $F.Body $(if ($Hover -eq $closeId) { $P.Accent } else { $P.Faint }) $x.X $x.Y $x.Width $x.Height 'Center'
            Add-Hit $Map $closeId $row ([scriptblock]::Create("Close-HubSelfTabs @($($t.id))")) (Tx 'Cerrar esta pesta\u00f1a (vuelve con Ctrl+Shift+T)')
            $ry += Px 40
        }
        if ($tabs.Count -gt 5) { Draw-Text $G ((Tx '+') + ($tabs.Count - 5) + (Tx ' m\u00e1s')) $F.Small $P.Faint $ix $ry $iw (Px 18) }
    }
    if ($fresh -and @($focus.apps).Count) {
        $apps = (@($focus.apps | ForEach-Object { [string]$_.name })) -join ', '
        Draw-Text $G ((Tx 'Apps fuera de foco: ') + $apps) $F.Small $P.Warn $ix ($card.Bottom - (Px 58)) $iw (Px 18)
    }
    $by = $card.Bottom - (Px 36)
    if (-not $detecting) {
        $bw = Get-PillWidth 'Revisar ahora'
        Draw-PillButton $G $Map $Hover 'self-check' (New-Rect $ix $by $bw (Px 26)) 'Revisar ahora' { Invoke-HubHarnessDetect }
    }
    if ($tabs.Count) {
        $label = (L 'Cerrar todas (') + $tabs.Count + ')'
        $bw = Get-PillWidth $label
        $ids = (@($tabs | ForEach-Object { [long]$_.id })) -join ','
        Draw-PillButton $G $Map $Hover 'self-close-all' (New-Rect ($card.Right - (Px 12) - $bw) $by $bw (Px 26)) $label ([scriptblock]::Create("Close-HubSelfTabs @($ids)")) -Accent
    }

    # ---- dev servers (right, top)
    $servers = @(if ($focus) { $focus.servers | Where-Object { $hiddenPorts -notcontains [int]$_.port } })
    Draw-HubCaption $G 'SERVIDORES LOCALES' $rx $y $colW $(if ($servers.Count) { [string]$servers.Count + (L ' escuchando') } else { '' })
    $shown = [Math]::Min(3, $servers.Count)
    $card = New-Rect $rx ($y + (Px 24)) $colW ((Px 16) + [Math]::Max(1, $shown) * (Px 32) + $(if ($servers.Count -gt 3) { Px 18 } else { 0 }))
    Draw-HubCard $G $card
    $sx = $card.X + (Px 12)
    $sw = $card.Width - (Px 24)
    $sy = $card.Y + (Px 8)
    if (-not $servers.Count) {
        Draw-Text $G $(if ($focus) { Tx 'Ning\u00fan servidor de desarrollo escuchando.' } else { Tx 'Sin revisar todav\u00eda.' }) $F.Small $P.Muted $sx ($sy + (Px 6)) $sw (Px 20)
    }
    foreach ($s in @($servers | Select-Object -First 3)) {
        $bw = Get-PillWidth 'Apagar'
        Draw-Text $G (':' + $s.port) $F.BodyStrong $P.Text $sx ($sy + (Px 4)) (Px 58) (Px 22)
        $what = $(if ($s.label) { [string]$s.label + (Tx ' \u00b7 ') } else { '' }) + [string]$s.name + ' ' + $s.pid
        Draw-Text $G $what $F.Small $P.Muted ($sx + (Px 60)) ($sy + (Px 6)) ($sw - (Px 68) - $bw) (Px 18)
        Draw-PillButton $G $Map $Hover "self-stop-$($s.port)" (New-Rect ($card.Right - (Px 12) - $bw) ($sy + (Px 2)) $bw (Px 26)) 'Apagar' ([scriptblock]::Create("Stop-HubSelfServer $([int]$s.port) $([int]$s.pid)"))
        $sy += Px 32
    }
    if ($servers.Count -gt 3) { Draw-Text $G ((Tx '+') + ($servers.Count - 3) + (Tx ' m\u00e1s')) $F.Small $P.Faint $sx $sy $sw (Px 18) }

    # ---- the watcher's settings (right, below)
    $ay = $card.Bottom + (Px 12)
    Draw-HubCaption $G 'AVISO DE CAMBIO DE AMBIENTE' $rx $ay $colW
    $envs = @($hs.Envs)
    # Quiet chips flow in rows inside the card; measured first so the card fits them.
    $chips = @()
    $cx = 0; $crow = 0
    foreach ($e in $envs) {
        $cw = Get-PillWidth ((Tx '\u2713 ') + [string]$e.Name)
        if ($cx -gt 0 -and $cx + $cw -gt $colW - (Px 24)) { $cx = 0; $crow++ }
        $chips += @{ Env = $e; X = $cx; Row = $crow; W = $cw }
        $cx += $cw + (Px 6)
    }
    $chipRows = if ($chips.Count) { $crow + 1 } else { 0 }
    $card = New-Rect $rx ($ay + (Px 24)) $colW ((Px 184) + $chipRows * (Px 30))
    Draw-HubCard $G $card
    $rowX = $card.X + (Px 6)
    $rowW = $card.Width - (Px 12)
    Draw-HubToggleRow $G $Map $Hover 'self-detect' (New-Rect $rowX ($card.Y + (Px 6)) $rowW (Px 42)) 'Detectar y preguntar' (Tx 'Si lo abierto es de otro ambiente') ([bool]$set.detect) { Switch-HubSelfDetect }
    # Lists, not steppers: each option in sight (keys as text, as the dropdown compares them).
    $minutes = [ordered]@{}; foreach ($m in $SelfHarnessMinutes) { $minutes["$m"] = "$m min" }
    $confidences = [ordered]@{}; foreach ($v in $SelfHarnessConfidences) { $confidences["$v"] = "$([int]($v * 100)) %" }
    $judges = [ordered]@{ haiku = 'Haiku (tu plan)'; jev = 'Jev (clave de API)' }
    Draw-HubDropdown $G $Map $Hover 'self-min' (New-Rect $rowX ($card.Y + (Px 52)) $rowW (Px 30)) 'Revisar cada' $minutes "$($set.minutes)" 'Step-HubSelfMinutes' ([bool]$set.detect)
    Draw-HubDropdown $G $Map $Hover 'self-conf' (New-Rect $rowX ($card.Y + (Px 86)) $rowW (Px 30)) 'Avisar desde' $confidences "$([double]$set.minConfidence)" 'Step-HubSelfConfidence' ([bool]$set.detect)
    Draw-HubDropdown $G $Map $Hover 'self-judge' (New-Rect $rowX ($card.Y + (Px 120)) $rowW (Px 30)) (Tx 'Qui\u00e9n decide') $judges $(if ($set.judge -eq 'jev') { 'jev' } else { 'haiku' }) 'Step-HubSelfJudge' ([bool]$set.detect)
    Draw-Text $G 'Silenciar en estos ambientes (ni detecta ni avisa):' $F.Small $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 156)) ($card.Width - (Px 32)) (Px 18)
    foreach ($c in $chips) {
        $rect = New-Rect ($card.X + (Px 12) + $c.X) ($card.Y + (Px 178) + $c.Row * (Px 30)) $c.W (Px 26)
        $quiet = @($set.quiet) -contains [string]$c.Env.Id
        $action = [scriptblock]::Create("Switch-HubSelfQuiet '$($c.Env.Id)'")
        # A check mark says it is on: an accent pill alone read as "selected or not?".
        if ($quiet) { Draw-PillButton $G $Map $Hover "self-quiet-$($c.Env.Id)" $rect ((Tx '\u2713 ') + [string]$c.Env.Name) $action -Accent }
        else { Draw-PillButton $G $Map $Hover "self-quiet-$($c.Env.Id)" $rect ([string]$c.Env.Name) $action }
    }

    # ---- a few numbers from the environments' history (full width, below both columns)
    $graph = Get-HarnessGraph $hs
    $sy = [Math]::Max($card.Bottom, $y + (Px 324)) + (Px 12)
    Draw-HubCaption $G 'TIEMPO EN CADA AMBIENTE' $X0 $sy $Inner ''
    $card = New-Rect $X0 ($sy + (Px 24)) $Inner (Px 104)
    Draw-HubCard $G $card
    $top = $graph.Top
    $names = @{}
    foreach ($e in $envs) { $names[$e.Id] = $e.Name }
    $switches = if ($graph.Switches) { [string]$graph.Switches + (L ' en total') + $(if ($top) { (Tx ' \u00b7 el m\u00e1s com\u00fan: ') + $names[$top.From] + (Tx ' \u2192 ') + $names[$top.To] + ' (' + $top.Count + ')' } else { '' }) } else { [string][char]0x2013 }
    $lines = @(
        @('HOY', (Format-HubEnvTimes $graph $envs 'Today')),
        @((Tx '7 D\u00cdAS'), (Format-HubEnvTimes $graph $envs 'Week')),
        @('FOCO MEDIO', (Format-HubEnvTimes $graph $envs 'Mean')),
        @('CAMBIOS', $switches)
    )
    $ly = $card.Y + (Px 10)
    foreach ($l in $lines) {
        Draw-Text $G $l[0] $F.Caps $P.Muted ($card.X + (Px 16)) ($ly + (Px 1)) (Px 92) (Px 20)
        Draw-Text $G $l[1] $F.Small $P.Text ($card.X + (Px 112)) $ly ($card.Width - (Px 128)) (Px 20)
        $ly += Px 22
    }
}

# Ambientes, in two tabs: the map of environments and Foco y ajustes (what was the SelfHarness section). The tab
# that is not open carries the out-of-focus count, as the side menu does.
function Draw-HubAmbientes($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $HF = $script:HubFonts
    $tab = if ($script:Hub.Section -eq 'self' -or $script:Hub.EnvsTab -eq 'focus') { 'focus' } elseif ($script:Hub.EnvsTab -eq 'lists') { 'lists' } else { 'map' }
    $badge = Get-HubNavBadge 'self'
    $tx = $X0
    foreach ($t in @(@{ Id = 'map'; Label = 'Mapa' }, @{ Id = 'lists'; Label = 'Skills y MCP' }, @{ Id = 'focus'; Label = 'Foco y ajustes' })) {
        $on = $tab -eq $t.Id
        $font = if ($on) { $HF.NavStrong } else { $HF.Nav }
        $lw = (Measure-TextWidth $t.Label $font) + (Px 6)
        $count = if ($t.Id -eq 'focus' -and $badge -and $badge.Text) { [string]$badge.Text } else { '' }
        $cw = if ($count) { (Measure-TextWidth $count $script:Fonts.Badge) + (Px 14) } else { 0 }
        $rect = New-Rect $tx (Px 64) ($lw + $(if ($cw) { $cw + (Px 6) } else { 0 })) (Px 28)
        $hitId = "envs-tab-$($t.Id)"
        Draw-Text $G $t.Label $font $(if ($on -or $Hover -eq $hitId) { $P.Text } else { $P.Muted }) $rect.X $rect.Y $lw (Px 24)
        if ($count) {
            $pill = New-Rect ($rect.X + $lw + (Px 6)) ($rect.Y + (Px 4)) $cw (Px 16)
            Fill-Round $G $pill (Px 8) $P.Warn
            Draw-Text $G $count $script:Fonts.Badge $P.Back $pill.X $pill.Y $pill.Width $pill.Height 'Center'
        }
        if ($on) { Fill-Round $G (New-Rect $rect.X ($rect.Bottom - (Px 3)) $rect.Width (Px 3)) (Px 1) $P.Accent }
        else { Add-Hit $Map $hitId $rect ([scriptblock]::Create("Set-HubEnvsTab '$($t.Id)'")) }
        $tx = $rect.Right + (Px 24)
    }
    # Below the tabs (not $top: PowerShell names ignore case and the sections use $top for their own values).
    $tabsH = Px 34
    if ($tab -eq 'focus') { Draw-HubSelfSection $G $Map $Hover $X0 $Inner $tabsH }
    elseif ($tab -eq 'lists') { Draw-HubEnvLists $G $Map $Hover $X0 $Inner $tabsH }
    else { Draw-HubEnvsSection $G $Map $Hover $X0 $Inner $tabsH }
}

function Set-HubEnvsTab([string]$Tab) {
    $script:Hub.EnvsTab = $Tab
    if ($script:Hub.Section -eq 'self') { $script:Hub.Section = 'envs' }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# "Sigo en ...": the tray's No to the same verdict, so neither the window nor the tray asks it again.
function Skip-HubHarnessOffer {
    $hs = $script:Hub.Cache.Harness
    if ($hs -and $hs.Detect) {
        if ($script:HarnessWatch) { $script:HarnessWatch.Asked = [string]$hs.Detect.at }
        $hs.Detect.offer = $false
    }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# A drift tab's x (one id) or "Cerrar todas" (asks first). Closed tabs stay hidden until the next detection.
function Close-HubSelfTabs([long[]]$Ids) {
    if ($script:Hub.Preview -or -not $Ids.Count) { return }
    $hs = $script:Hub.Cache.Harness
    if (-not $hs -or -not $hs.Dir) { return }
    if ($Ids.Count -gt 1) {
        $ask = (Tx '\u00bfCerrar ') + $Ids.Count + (Tx ' pesta\u00f1as que no encajan con ') + $hs.Active.name + (Tx '? Se recuperan con Ctrl+Shift+T.')
        if (-not (Confirm-UiAction $ask $script:HubDialog)) { return }
    }
    $failed = Close-HarnessTabs $hs.Dir $Ids
    if ($failed) { Set-HubMessage $failed -Failed; return }
    $key = if ($hs.Focus) { [string]$hs.Focus.at } else { '' }
    $script:HarnessWatch.Hidden[$key] = @(@($script:HarnessWatch.Hidden[$key]) + $Ids | Where-Object { $_ })
    Set-HubMessage $(if ($Ids.Count -eq 1) { Tx 'Pesta\u00f1a cerrada.' } else { "$($Ids.Count) " + (Tx 'pesta\u00f1as cerradas.') })
    Update-HubNow
}

function Stop-HubSelfServer([int]$Port, [int]$ProcessId) {
    if ($script:Hub.Preview) { return }
    $ask = (Tx '\u00bfApagar el servidor del puerto ') + $Port + " (pid $ProcessId)? " + (Tx 'Se cierra ese proceso y lo que lanz\u00f3.')
    if (-not (Confirm-UiAction $ask $script:HubDialog)) { return }
    $failed = Stop-HarnessServer $Port $ProcessId
    if ($failed) { Set-HubMessage $failed -Failed; return }
    $hs = $script:Hub.Cache.Harness
    $key = if ($hs -and $hs.Focus) { [string]$hs.Focus.at + '|ports' } else { '|ports' }
    $script:HarnessWatch.Hidden[$key] = @(@($script:HarnessWatch.Hidden[$key]) + $Port | Where-Object { $_ })
    Set-HubMessage ((L 'Servidor :{0} apagado.') -f $Port)
    Update-HubNow
}

function Switch-HubSelfDetect {
    if ($script:Hub.Preview) { return }
    Set-SelfHarnessSetting 'detect' (-not (Get-SelfHarnessSettings).detect)
    Update-HubNow
}

# "< value >" pickers: one step through the choices lib\harness.ps1 accepts.
function Step-HubSelfChoice([string]$Name, $Choices, [int]$Delta) {
    if ($script:Hub.Preview) { return }
    $i = [Array]::IndexOf($Choices, (Get-SelfHarnessSettings)[$Name])
    $i = [Math]::Max(0, [Math]::Min($Choices.Count - 1, $i + $Delta))
    Set-SelfHarnessSetting $Name $Choices[$i]
    Update-HubNow
}
function Step-HubSelfMinutes([int]$Delta) { Step-HubSelfChoice 'minutes' $SelfHarnessMinutes $Delta }
function Step-HubSelfConfidence([int]$Delta) { Step-HubSelfChoice 'minConfidence' $SelfHarnessConfidences $Delta }
function Step-HubSelfJudge([int]$Delta) { Step-HubSelfChoice 'judge' $SelfHarnessJudges $Delta }

function Switch-HubSelfQuiet([string]$Id) {
    if ($script:Hub.Preview) { return }
    $quiet = @((Get-SelfHarnessSettings).quiet)
    $quiet = if ($quiet -contains $Id) { @($quiet | Where-Object { $_ -ne $Id }) } else { $quiet + $Id }
    Set-SelfHarnessSetting 'quiet' $quiet
    Update-HubNow
}

# ---------------------------------------------------------------- Inicio

function Draw-HubHome($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $view = $script:View
    $now = Get-Date
    if (-not $script:HubFonts.Big) { $script:HubFonts.Big = New-UiFont 'Segoe UI Semibold' 22 }

    # The plan, big: how much of each window is used and when it renews. A click opens Uso y agenda.
    $card = New-Rect $X0 (Px 72) $Inner (Px 168)
    Fill-Round $G $card (Px 12) $(if ($Hover -eq 'home-usage') { $P.SurfaceHover } else { $P.Surface })
    Add-Hit $Map 'home-usage' $card { Set-HubSection 'usage' }
    $hasData = $view -and $view.HasData
    $colW = [int](($card.Width - (Px 72)) / 2)
    foreach ($i in 0, 1) {
        $x = $card.X + (Px 24) + $i * ($colW + (Px 24))
        $window = if (-not $hasData) { $null } elseif ($i -eq 0) { $view.Session } else { $view.Weekly }
        $active = $window -and $window.Active
        $pct = if ($active) { [int]$window.Percent } else { 0 }
        Draw-Text $G $(if ($i -eq 0) { (Tx 'SESI\u00d3N DE 5 H') } else { 'SEMANA' }) $F.Caps $P.Muted $x ($card.Y + (Px 18)) $colW (Px 18)
        $used = if ($window) { "$pct %" } else { [string][char]0x2013 }
        $lw = Measure-TextWidth $used $script:HubFonts.Big
        Draw-Text $G $used $script:HubFonts.Big $P.Text $x ($card.Y + (Px 38)) ($lw + (Px 4)) (Px 40)
        if ($window) { Draw-Text $G 'usado' $F.Small $P.Muted ($x + $lw + (Px 8)) ($card.Y + (Px 52)) (Px 80) (Px 20) }
        $track = New-Rect $x ($card.Y + (Px 86)) $colW (Px 8)
        Fill-Round $G $track (Px 4) $P.Track
        if ($active -and $pct -gt 0) { Fill-Round $G (New-Rect $x $track.Y ([Math]::Max((Px 8), [int]($colW * [Math]::Min(100, $pct) / 100))) $track.Height) (Px 4) $P[(Get-UsageLevel $pct)] }
        $reset = if (-not $window) { Tx 'Sin datos todav\u00eda' } elseif (-not $active) { 'Sin empezar' } else { (L 'Se renueva en ') + (Format-Remaining ($window.ResetsAt - $now)) }
        Draw-Text $G $reset $F.Small $P.Muted $x ($card.Y + (Px 100)) $colW (Px 18)
    }
    $pen = New-HubPen $P.Border 1
    $G.DrawLine($pen, $card.X + (Px 24), $card.Y + (Px 128), $card.Right - (Px 24), $card.Y + (Px 128))
    $pen.Dispose()
    $next = Get-HubNextRow
    $nextText = if ($next) {
        $kind = if ($next.TaskName -like "$AutoTaskPrefix*") { Tx 'autom\u00e1tica' } elseif ($next.Kind -eq 'pc') { L 'en este PC' } else { L 'en la nube' }
        (Tx 'Pr\u00f3xima sesi\u00f3n: ') + (Format-DialogDateTime $next.At $now) + (Tx ' \u00b7 ') + $kind
    } else { 'Nada agendado' }
    $link = New-Rect ($card.Right - (Px 124)) ($card.Y + (Px 136)) (Px 100) (Px 22)
    Draw-Text $G $nextText $F.Small $P.Muted ($card.X + (Px 24)) ($card.Y + (Px 136)) ($card.Width - (Px 160)) (Px 22)
    Draw-Text $G (Tx 'Agendar \u203a') $F.Small $(if ($Hover -eq 'home-schedule') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height 'Right'
    Add-Hit $Map 'home-schedule' $link { Open-HubSchedule }

    $y = $card.Bottom + (Px 16)
    # The business edition keeps its company card here.
    if (Test-HubBusiness) {
        Draw-HubBusinessHome $G $Map $Hover (New-Rect $X0 $y $Inner (Px 262))
        $y += Px 278
    }

    # Today: one line per thing worth knowing, each opening its section. Only what is happening shows.
    $rows = @()
    $live = @($c.CodeSessions | Where-Object { $_.Live }).Count
    $rows += @{ Id = 'code'; Dot = $(if ($live) { $P.Ok } else { $P.Faint }); Text = $(if ($live -eq 1) { Tx '1 sesi\u00f3n de Claude Code abierta' } elseif ($live) { (Tx '{0} sesiones de Claude Code abiertas') -f $live } else { Tx 'Ninguna sesi\u00f3n de Claude Code abierta' }) }
    $hs = $c.Harness
    if ((Test-HubModule 'ambientes') -and $hs -and $hs.Active) {
        $rows += @{ Id = 'envs'; Dot = $P.Ok; Text = (L 'Ambiente {0}, desde las {1}') -f $hs.Active.name, (Format-HubHarnessTime $hs.Active.since) }
        $focus = Get-HubNavBadge 'self'
        if ($focus -and $focus.Text) { $rows += @{ Id = 'self'; Dot = $P.Warn; Text = $(if ($focus.Text -eq '1') { Tx '1 pesta\u00f1a fuera de foco' } else { (Tx '{0} pesta\u00f1as fuera de foco') -f $focus.Text }) } }
    }
    if (Test-HubModule 'bridge') {
        $nodes = @(Get-HubNetworkNodes | Where-Object { $_.Paired })
        $linked = @($nodes | Where-Object { $_.State -eq 'session' })
        $online = @($nodes | Where-Object { $_.State -eq 'online' })
        if ($linked.Count) { $rows += @{ Id = 'pcs'; Dot = $P.Ok; Text = (L '{0} conectado a este PC') -f $linked[0].Name } }
        elseif ($online.Count) { $rows += @{ Id = 'pcs'; Dot = $P.Ok; Text = $(if ($online.Count -eq 1) { (Tx '{0} en l\u00ednea') -f $online[0].Name } else { (Tx '{0} PCs en l\u00ednea') -f $online.Count }) } }
    }
    if ((Test-HubModule 'whisper') -and $c.WhisperRunning) { $rows += @{ Id = 'whisper'; Dot = $P.Ok; Text = (Tx 'Claude Whisper est\u00e1 abierto') } }
    if ($c.VoiceMuted) { $rows += @{ Id = 'voice'; Dot = $P.Faint; Text = (Tx 'La voz de las sesiones est\u00e1 apagada') } }

    Draw-HubCaption $G 'HOY' $X0 $y $Inner ''
    $y += Px 24
    foreach ($row in $rows) {
        $rect = New-Rect $X0 $y $Inner (Px 44)
        $hitId = "home-row-$($row.Id)"
        if ($Hover -eq $hitId) { Fill-Round $G $rect (Px 8) $P.SurfaceHover }
        Draw-HubDot $G ($rect.X + (Px 8)) ($rect.Y + (Px 18)) (Px 8) $row.Dot
        Draw-Text $G $row.Text $F.Body $P.Text ($rect.X + (Px 28)) $rect.Y ($rect.Width - (Px 60)) $rect.Height
        Draw-Text $G (Tx '\u203a') $F.Close $P.Muted ($rect.Right - (Px 28)) ($rect.Y - (Px 1)) (Px 20) $rect.Height 'Center'
        Add-Hit $Map $hitId $rect ([scriptblock]::Create("Set-HubSection '$($row.Id)'"))
        $pen = New-HubPen $P.Border 1
        $G.DrawLine($pen, $rect.X, $rect.Bottom, $rect.Right, $rect.Bottom)
        $pen.Dispose()
        $y += Px 44
    }

    # One action: a new session (the Explorer's right click does the same).
    $label = Tx 'Nueva sesi\u00f3n'
    $bw = (Get-PillWidth $label) + (Px 16)
    $by = $y + (Px 20)
    Draw-PillButton $G $Map $Hover 'home-code-new' (New-Rect ($X0 + $Inner - $bw) $by $bw (Px 30)) $label { Open-HubCodeSession } -Accent
    Draw-Text $G (Tx 'Clic derecho en una carpeta del Explorador tambi\u00e9n abre una sesi\u00f3n.') $F.Small $P.Muted $X0 $by ($Inner - $bw - (Px 16)) (Px 30)
}


# ---------------------------------------------------------------- Uso y agenda

function Draw-HubUsageSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $view = $script:View
    $now = Get-Date

    # header line: data age and refresh
    if ($script:Refresh) { $age = Tx 'Actualizando\u2026'; $ageColor = $P.Muted }
    elseif ($script:RefreshError -and ($now - $script:RefreshErrorAt).TotalSeconds -lt 30) { $age = $script:RefreshError; $ageColor = $P.Error }
    else { $age = if ($view) { Format-Age $view.AgeMinutes } else { 'Sin datos' }; $ageColor = $P.Muted }
    $bw = Get-PillWidth 'Actualizar'
    $refresh = New-Rect ($X0 + $Inner - $bw) (Px 70) $bw (Px 24)
    Draw-PillButton $G $Map $Hover 'usage-refresh' $refresh 'Actualizar' { Start-UsageRefresh; Set-HubMessage (Tx 'Actualizando el uso\u2026') }
    $caption = Tx 'L\u00cdMITES DEL PLAN'
    Draw-Text $G $caption $F.Caps $P.Muted $X0 (Px 74) (Px 200) (Px 18)
    # The age (or a long refresh error) only gets the space between the caption and the button.
    $ageX = $X0 + (Measure-TextWidth $caption $F.Caps) + (Px 12)
    Draw-Text $G $age $F.Small $ageColor $ageX (Px 70) ($refresh.X - $ageX - (Px 10)) (Px 24) 'Right'

    $y = Px 102
    $card = New-Rect $X0 $y $Inner (Px 128)
    Draw-HubCard $G $card
    if (-not $view -or -not $view.HasData) {
        Draw-Text $G (Tx 'Sin datos de uso todav\u00eda') $F.BodyStrong $P.Text ($card.X + (Px 18)) ($card.Y + (Px 20)) ($card.Width - (Px 36)) (Px 22)
        Draw-Text $G 'Manda un mensaje en Claude Code o pulsa Actualizar.' $F.Small $P.Muted ($card.X + (Px 18)) ($card.Y + (Px 44)) ($card.Width - (Px 36)) (Px 20)
    } else {
        Draw-HubUsage $G (Tx 'SESI\u00d3N (5 H)') $view.Session ($card.X + (Px 18)) ($card.Y + (Px 14)) ($card.Width - (Px 36))
        Draw-HubUsage $G 'SEMANAL' $view.Weekly ($card.X + (Px 18)) ($card.Y + (Px 72)) ($card.Width - (Px 36))
    }
    $y = $card.Bottom + (Px 10)
    $autoCard = New-Rect $X0 $y $Inner (Px 196)
    Draw-HubAutoCard $G $Map $Hover $autoCard
    $y = $autoCard.Bottom + (Px 10)

    # extra usage and a limit reset offer
    $extra = $script:Extras.ExtraUsage
    $reset = $script:Extras.LimitReset
    if ($extra -or $reset) {
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 10) $(if ($reset) { $P.AccentTint } else { $P.Surface })
        # (only room for one: the limit reset offer goes first)
        if ($reset) {
            Draw-Text $G $reset.Title $F.BodyStrong $P.Text ($row.X + (Px 14)) ($row.Y + (Px 3)) ($row.Width - (Px 120)) (Px 20)
            Draw-Text $G $reset.Detail $F.Small $P.Muted ($row.X + (Px 14)) ($row.Y + (Px 22)) ($row.Width - (Px 120)) (Px 18)
            $bw = Get-PillWidth 'Reclamar'
            Draw-PillButton $G $Map $Hover 'usage-reset' (New-Rect ($row.Right - (Px 12) - $bw) ($row.Y + (Px 10)) $bw (Px 24)) 'Reclamar' { Start-Process 'https://claude.ai/settings/usage' } -Accent
        } else {
            $pct = if ($null -ne $extra.Percent) { "$($extra.Percent)%" } else { 'activado' }
            Draw-Text $G ((L 'Uso extra: ') + $pct) $F.BodyStrong $P.Text ($row.X + (Px 14)) $row.Y (Px 220) $row.Height
            if ($extra.AmountText) { Draw-Text $G $extra.AmountText $F.Body $P.Text ($row.X + (Px 14)) $row.Y ($row.Width - (Px 28)) $row.Height 'Right' }
        }
        $y += Px 56
    }

    # scheduled sessions
    $rows = @($c.ScheduleRows)
    $maxRows = [Math]::Max(1, [int](((Px 572) - ($y + (Px 22))) / (Px 38)))
    $note = if ($rows.Count -gt $maxRows) { (Tx '+{0} m\u00e1s en Agendar sesi\u00f3n\u2026') -f ($rows.Count - $maxRows) } else { Tx 'Abren la sesi\u00f3n de 5 h antes de que la necesites' }
    Draw-HubCaption $G 'AGENDADAS' $X0 $y $Inner $note
    $y += Px 22
    if (-not $rows.Count) {
        $row = New-Rect $X0 $y $Inner (Px 34)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Nada agendado todav\u00eda.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 34)
        $y += Px 38
    }
    foreach ($item in @($rows | Select-Object -First $maxRows)) {
        $row = New-Rect $X0 $y $Inner (Px 34)
        Fill-Round $G $row (Px 8) $P.Surface
        $upcoming = $item.State -in 'pending', 'requested', 'creating', 'cloud-ok', 'cloud-failed'
        $pill = New-Rect ($row.X + (Px 10)) ($row.Y + (Px 9)) (Px 42) (Px 16)
        Fill-Round $G $pill (Px 8) $(if ($upcoming) { $P.AccentTint } else { $P.Track })
        Draw-Text $G $(if ($item.TaskName -like "$AutoTaskPrefix*") { 'AUTO' } elseif ($item.Kind -eq 'pc') { 'PC' } else { 'NUBE' }) $F.Badge $(if ($upcoming) { $P.Accent } else { $P.Muted }) $pill.X $pill.Y $pill.Width $pill.Height 'Center'
        Draw-Text $G (Format-DialogDateTime $item.At $now) $F.Body $(if ($upcoming) { $P.Text } else { $P.Muted }) ($row.X + (Px 62)) $row.Y (Px 240) $row.Height
        $status = Get-HubRowStatus $item
        Draw-Text $G $status.Text $F.Small $status.Color $row.X $row.Y ($row.Width - (Px 14)) $row.Height 'Right'
        $y += Px 38
    }

    # actions
    $by = Px 584
    $x = $X0
    foreach ($button in @(@{ Id = 'usage-schedule'; Label = (Tx 'Agendar sesi\u00f3n...'); Action = { Open-HubSchedule }; Accent = $true },
                          @{ Id = 'usage-plan'; Label = 'Plan semanal...'; Action = { Open-HubSchedule 'plan' }; Accent = $false },
                          @{ Id = 'usage-web'; Label = 'Ver uso en claude.ai'; Action = { Start-Process 'https://claude.ai/settings/usage' }; Accent = $false })) {
        $bw = (Get-PillWidth $button.Label) + (Px 10)
        Draw-PillButton $G $Map $Hover $button.Id (New-Rect $x $by $bw (Px 30)) $button.Label $button.Action -Accent:$button.Accent
        $x += $bw + (Px 8)
    }
}

# ---------------------------------------------------------------- Claude Code

# Primera pantalla: left to right (as before), Windows' main one, or each monitor after the first in that order.
function Get-HubScreenFirstOptions {
    $options = [ordered]@{ '' = 'De izquierda a derecha'; windows = 'Principal (Windows)' }
    $count = @($script:Hub.Cache.ScreenAreas).Count
    for ($i = 1; $i -lt $count; $i++) { $options["$i"] = (L 'Pantalla {0} de la izquierda') -f ($i + 1) }
    $options
}

function Step-HubScreenFirst([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $keys = @((Get-HubScreenFirstOptions).Keys)
    $i = [array]::IndexOf($keys, [string]$script:Hub.Cache.ScreenFirst)
    $next = $keys[[Math]::Max(0, [Math]::Min($keys.Count - 1, $i + $Delta))]
    try { Set-ScreenFirst $next } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message) -Failed; return }
    $script:Hub.Cache.ScreenFirst = $next
    Set-HubMessage 'Las sesiones nuevas siguen el nuevo orden.'
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# Every monitor as a small screen in the order sessions fill them, each with its slots (whole, halves or quarters): the session on each
# (its color and name), the free ones numbered, and the next one to fill outlined in the accent color.
function Draw-HubScreenMap($G, [System.Drawing.Rectangle]$Area, $Sessions) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $screens = Get-ScreenOrder @($c.ScreenAreas) ([string]$c.ScreenFirst)
    if (-not $screens.Count) { return }
    $gap = Px 14
    $labelH = Px 22
    $maxH = [double]($Area.Height - $labelH)
    $totalW = [double](($screens | ForEach-Object { [int]$_.Right - [int]$_.Left } | Measure-Object -Sum).Sum)
    $tallest = [double](($screens | ForEach-Object { [int]$_.Bottom - [int]$_.Top } | Measure-Object -Maximum).Maximum)
    $scale = [Math]::Min(($Area.Width - $gap * ($screens.Count - 1)) / $totalW, $maxH / $tallest)
    $live = @($Sessions | Where-Object { $_.Live })
    $per = [Math]::Max(1, [int]$c.PerScreen)
    $cols = if ($per -eq 1) { 1 } else { 2 }
    $rows = if ($per -eq 4) { 2 } else { 1 }
    $slotCount = $per * $screens.Count
    $next = -1
    for ($s = 0; $s -lt $slotCount; $s++) { if (-not @($live | Where-Object { [int]$_.Slot -eq $s }).Count) { $next = $s; break } }
    $x = $Area.X
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $scr = $screens[$i]
        $w = [int](([int]$scr.Right - [int]$scr.Left) * $scale)
        $h = [int](([int]$scr.Bottom - [int]$scr.Top) * $scale)
        $box = New-Rect $x ($Area.Y + [int]$maxH - $h) $w $h
        Fill-Round $G $box (Px 6) $P.Back
        Stroke-Round $G $box (Px 6) $P.Border
        $cw = [int](($w - (Px 3) * ($cols + 1)) / $cols)
        $ch = [int](($h - (Px 3) * ($rows + 1)) / $rows)
        for ($k = 0; $k -lt $per; $k++) {
            $slot = $per * $i + $k
            $cell = New-Rect ($box.X + (Px 3) + ($k % $cols) * ($cw + (Px 3))) ($box.Y + (Px 3) + [int][Math]::Floor($k / $cols) * ($ch + (Px 3))) $cw $ch
            $session = @($live | Where-Object { [int]$_.Slot -eq $slot }) | Select-Object -First 1
            if ($session) {
                $hex = ConvertFrom-Hex (Get-HubSlotHex $session.Color)
                Fill-Round $G $cell (Px 4) ([System.Drawing.Color]::FromArgb(70, $hex))
                Draw-Text $G ("$($slot + 1) " + (Tx '\u00b7 ') + $session.Name) $F.Small $P.Text ($cell.X + (Px 2)) $cell.Y ($cell.Width - (Px 4)) $cell.Height 'Center'
            } else {
                $pen = New-HubPen $(if ($slot -eq $next) { $P.Accent } else { $P.Border }) $(if ($slot -eq $next) { 1.5 } else { 1 }) $(if ($slot -eq $next) { 'Solid' } else { 'Dash' })
                $G.DrawRectangle($pen, $cell.X, $cell.Y, $cell.Width - 1, $cell.Height - 1)
                $pen.Dispose()
                $text = if ($slot -eq $next) { "$($slot + 1) " + (Tx '\u00b7 sigue') } else { "$($slot + 1)" }
                Draw-Text $G $text $F.Small $(if ($slot -eq $next) { $P.Accent } else { $P.Faint }) $cell.X $cell.Y $cell.Width $cell.Height 'Center'
            }
        }
        # The main one (holding the desktop's origin, as Get-ScreenOrder tells it) says so.
        $main = [int]$scr.Left -le 100 -and 100 -lt [int]$scr.Right -and [int]$scr.Top -le 100 -and 100 -lt [int]$scr.Bottom
        Draw-Text $G ("$($i + 1)" + $(if ($main) { (Tx ' \u00b7 principal') } else { '' })) $F.Small $P.Muted $box.X ($box.Bottom + (Px 4)) $box.Width (Px 18) 'Center'
        $x = $box.Right + $gap
    }
}

function Draw-HubCodeSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $screens = [Math]::Max(1, [int]$c.Screens)
    $per = [Math]::Max(1, [int]$c.PerScreen)
    $slots = $per * $screens
    $limit = $c.SessionLimit -ne $false
    $sessions = @($c.CodeSessions)
    $live = @($sessions | Where-Object { $_.Live }).Count

    # Your screens, in the order sessions fill them, and the one button to open the next.
    $card = New-Rect $X0 (Px 72) $Inner (Px 166)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $tw = $card.Width - (Px 32)
    $screensText = if ($screens -eq 1) { L '1 pantalla' } else { (L '{0} pantallas') -f $screens }
    Draw-Text $G 'TUS PANTALLAS, EN EL ORDEN EN QUE SE LLENAN' $F.Caps $P.Muted $tx ($card.Y + (Px 12)) $tw (Px 18)
    Draw-Text $G $(if ($limit) { (L '{0} de {1} abiertas') -f $live, $slots } else { (L '{0} abiertas') -f $live }) $F.Small $P.Muted $tx ($card.Y + (Px 12)) $tw (Px 18) 'Right'
    $label = Tx 'Nueva sesi\u00f3n'
    $bw = (Get-PillWidth $label) + (Px 12)
    Draw-PillButton $G $Map $Hover 'code-new' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 44)) $bw (Px 30)) $label { Open-HubCodeSession } -Accent
    Draw-HubScreenMap $G (New-Rect $tx ($card.Y + (Px 36)) ($tw - $bw - (Px 24)) (Px 72)) $sessions
    $half = [int](($card.Width - (Px 12)) / 2)
    Draw-HubDropdown $G $Map $Hover 'code-first' (New-Rect ($card.X + (Px 6)) ($card.Y + (Px 110)) $half (Px 30)) 'Primera pantalla' (Get-HubScreenFirstOptions) ([string]$c.ScreenFirst) 'Step-HubScreenFirst'
    Draw-HubDropdown $G $Map $Hover 'code-per' (New-Rect ($card.X + (Px 6) + $half) ($card.Y + (Px 110)) $half (Px 30)) 'Por pantalla' $HubPerScreenOptions ([string]$per) 'Step-HubPerScreen'
    # How much the agents worked this week and how many per screen that suggests (Get-PerScreenAdvice).
    $advice = Get-PerScreenAdvice $c.Activity
    $adviceText = if (-not $advice) { Tx 'Midiendo cu\u00e1nto trabajan tus agentes: la recomendaci\u00f3n sale tras una hora de sesiones.' }
        elseif ($advice.PerScreen -eq 4) { (Tx 'Esta semana tus agentes trabajaron el {0} % del tiempo abiertos: te esperan poco, prueba 4 por pantalla.') -f $advice.Percent }
        elseif ($advice.PerScreen -eq 1) { (Tx 'Esta semana tus agentes trabajaron el {0} % del tiempo abiertos: casi siempre te esperan, con 1 por pantalla ves m\u00e1s de cada uno.') -f $advice.Percent }
        else { (Tx 'Esta semana tus agentes trabajaron el {0} % del tiempo abiertos: 2 por pantalla es lo tuyo.') -f $advice.Percent }
    $adviceColor = if ($advice -and $advice.PerScreen -ne $per) { $P.Accent } else { $P.Muted }
    Draw-Text $G $adviceText $F.Small $adviceColor $tx ($card.Y + (Px 142)) $tw (Px 18)

    # The link on the caption's right swaps the lower part for the guide to Peek (file and image previews) and back.
    $help = [bool]$script:Hub.CodeHelp
    $y = $card.Bottom + (Px 12)
    $linkText = if ($help) { Tx '\u2039 Volver a las sesiones' } else { Tx 'C\u00f3mo se ven los archivos en las respuestas \u203a' }
    $lw = (Measure-TextWidth $linkText $F.Small) + (Px 4)
    $link = New-Rect ($X0 + $Inner - $lw) $y $lw (Px 18)
    Draw-Text $G $linkText $F.Small $(if ($Hover -eq 'code-help') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height 'Right'
    Add-Hit $Map 'code-help' $link { $script:Hub.CodeHelp = -not $script:Hub.CodeHelp; $script:HubDialog.Invalidate() }
    if ($help) {
        Draw-Text $G (Tx 'ARCHIVOS E IM\u00c1GENES EN LAS RESPUESTAS') $F.Caps $P.Muted $X0 $y ($Inner - $lw - (Px 10)) (Px 18)
        Draw-HubPeekHelp $G $X0 ($y + (Px 26)) $Inner
        return
    } else {
        Draw-Text $G ('SESIONES' + $(if ($sessions.Count -gt 2) { (Tx '  \u00b7  +{0} m\u00e1s') -f ($sessions.Count - 2) } else { '' })) $F.Caps $P.Muted $X0 $y ($Inner - $lw - (Px 10)) (Px 18)
        $y += Px 22
        if (-not $sessions.Count) {
            $row = New-Rect $X0 $y $Inner (Px 40)
            Fill-Round $G $row (Px 8) $P.Surface
            Draw-Text $G (Tx 'Ninguna sesi\u00f3n abierta desde el men\u00fa.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
            $y += Px 46
        }
        $now = Get-Date
        for ($i = 0; $i -lt [Math]::Min(2, $sessions.Count); $i++) {
            $session = $sessions[$i]
            $row = New-Rect $X0 $y $Inner (Px 50)
            Fill-Round $G $row (Px 8) $P.Surface
            $hex = if ($session.Live) { Get-HubSlotHex $session.Color } else { [System.Drawing.ColorTranslator]::ToHtml($P.Faint) }
            Draw-HubEgg $G ($row.X + (Px 20)) ($row.Y + (Px 25)) (Px 24) $hex
            $right = $row.Right - (Px 12)
            if ($session.Live) {
                $sw = Get-PillWidth 'Mostrar'
                $btn = New-Rect ($right - $sw) ($row.Y + (Px 13)) $sw (Px 24)
                Draw-PillButton $G $Map $Hover "code-show-$i" $btn 'Mostrar' ([scriptblock]::Create("Show-HubCodeWindow $i"))
                $right = $btn.X - (Px 10)
            } else {
                Draw-Text $G 'cerrada' $F.Small $P.Faint ($right - (Px 80)) $row.Y (Px 80) $row.Height 'Right'
                $right -= Px 90
            }
            $name = if ($session.Name) { $session.Name } else { ((L 'Ventana {0}') -f ($session.Slot + 1)) }
            if ($session.Role) { $name += (Tx ' \u00b7 ') + $session.Role }
            $textX = $row.X + (Px 36)
            $folder = Split-Path -Leaf $session.Dir
            $folderW = [Math]::Min([int](($right - $textX) * 0.4), (Measure-TextWidth $folder $F.Small))
            Draw-Text $G $name $F.BodyStrong $(if ($session.Live) { $P.Text } else { $P.Muted }) $textX ($row.Y + (Px 6)) ($right - $textX - $folderW - (Px 8)) (Px 20)
            $meta = @(Format-SlotPlace $session.Slot $per $slots)
            if ($session.Backend -eq 'freellm') { $meta = @('FreeLLMAPI') + $meta }
            if ($session.At) { $meta += (L 'desde ') + (Format-DialogDateTime $session.At $now) }
            if ($session.Voice) { $meta += (L 'voz ') + (Format-VoiceName $session.Voice) }
            Draw-Text $G ($meta -join ((Tx '  \u00b7  '))) $F.Small $P.Muted $textX ($row.Y + (Px 26)) ($right - $textX) (Px 18)
            Draw-Text $G $folder $F.Small $P.Faint ($right - $folderW) ($row.Y + (Px 6)) $folderW (Px 20) 'Right'
            $y += Px 56
        }
    }

    # Settings of the sessions: one row each, what it does and its control.
    $y = [Math]::Max($y, (Px 384))
    Draw-HubCaption $G 'AJUSTES DE LAS SESIONES' $X0 $y $Inner ''
    $scard = New-Rect $X0 ($y + (Px 22)) $Inner (Px 140)
    Draw-HubCard $G $scard
    $rowX = $scard.X + (Px 6)
    $rowW = $scard.Width - (Px 12)
    $menuText = if ($c.MenuInstalled) { Tx '\u2713 Clic derecho en una carpeta del Explorador \u203a Abrir con Claude Code.' } else { Tx 'El men\u00fa del Explorador no est\u00e1 instalado: ejecuta install.ps1.' }
    $limitSub = if ($limit) { $menuText } else { (Tx 'Sin l\u00edmite: desde la {0}\u00aa se superponen.') -f ($slots + 1) }
    Draw-HubToggleRow $G $Map $Hover 'code-limit' (New-Rect $rowX ($scard.Y + (Px 6)) $rowW (Px 42)) ((Tx 'Una sesi\u00f3n por hueco, hasta {0} ({1})') -f $slots, $screensText) $limitSub $limit ([scriptblock]::Create("Set-HubSessionLimit `$$(-not $limit)"))
    $cm = $c.ContextMode
    $job = $c.MaxxStatus
    $busy = $job -and $job.state -eq 'running'
    $sub = if ($busy) { Tx 'Aplicando el cambio con claude plugin\u2026' }
        elseif ($job -and $job.state -eq 'error' -and $job.action -like 'contextmode*') { [string]$job.message }
        else { Tx 'Deja fuera del contexto las salidas largas de las herramientas: la cuota dura m\u00e1s.' }
    Draw-HubToggleRow $G $Map $Hover 'maxx-cm' (New-Rect $rowX ($scard.Y + (Px 52)) $rowW (Px 42)) 'Ahorro de contexto (context-mode)' $sub ([bool]($cm -and $cm.Enabled)) ([scriptblock]::Create("Set-HubContextMode `$$(-not ($cm -and $cm.Enabled))")) (-not $busy)
    # Where the session eggs go: the taskbar, or a strip stuck to one edge of the screen (lib\traysessions.ps1).
    # In $EggDockEdges' order, the one Step-HubEggDock steps through (the labels' table has none).
    $eggs = [ordered]@{}
    foreach ($edge in $EggDockEdges) { $eggs[$edge] = $script:EggDockLabels[$edge] }
    Draw-HubDropdown $G $Map $Hover 'code-eggs' (New-Rect $rowX ($scard.Y + (Px 102)) $rowW (Px 30)) (Tx 'Icono de cada sesi\u00f3n') $eggs (Get-EggDock).Edge 'Step-HubEggDock'

    $fy = $scard.Bottom + (Px 6)
    if (Test-HubModule 'freellm') { Draw-HubFreeLlmCard $G $Map $Hover (New-Rect $X0 $fy $Inner (Px 84)) }
    else { Draw-HubPolicyNote $G (New-Rect $X0 $fy $Inner (Px 84)) 'Modelos gratis con FreeLLMAPI' (Tx 'Apagado por la pol\u00edtica de la empresa: las sesiones usan solo el plan de Claude, sin enviar prompts a proveedores de terceros.') }
}


# What Peek (peek\README.md) does with the paths in Claude's answers: what each gesture shows or opens.
$script:PeekHelpRows = @(
    @('Rutas', 'Cada ruta a un archivo o carpeta que existe es un enlace; al final, Referencias lista todas las que nombr\u00f3, con su tipo.'),
    @('Rat\u00f3n encima', 'Imagen, video o PDF: miniatura, tama\u00f1o, p\u00edxeles, duraci\u00f3n o p\u00e1ginas, sin quitar el foco. C\u00f3digo o texto: sus primeras l\u00edneas con colores.'),
    @('Un tramo', 'Con app.ts[12:20] muestra solo las l\u00edneas 12 a 20; con app.ts:12, esa l\u00ednea.'),
    @('Clic', 'Abre el Explorador con el archivo seleccionado.'),
    @('Clic derecho', 'O Alt / Ctrl + clic: lo abre con su programa (el video se reproduce, el PDF se abre).'),
    @('Opciones', '/config > maxx-peek: la vista previa en ventana o en una tarjeta, y qu\u00e9 rutas lista Referencias.')
)

function Draw-HubPeekHelp($G, [int]$X0, [int]$Y, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    Draw-HubCaption $G 'VISTA PREVIA DE ARCHIVOS (PEEK)' $X0 $Y $Inner 'en las sesiones de Claude Code'
    $card = New-Rect $X0 ($Y + (Px 22)) $Inner (Px 204)
    Draw-HubCard $G $card
    $ry = $card.Y + (Px 10)
    $labelW = Px 110
    $textX = $card.X + (Px 14) + $labelW
    $textW = $card.Right - (Px 14) - $textX
    foreach ($row in $script:PeekHelpRows) {
        Draw-Text $G (Tx $row[0]) $F.BodyStrong $P.Text ($card.X + (Px 14)) $ry $labelW (Px 18)
        Draw-Wrapped $G (Tx $row[1]) $F.Small $P.Muted $textX ($ry + (Px 1)) $textW (Px 30)
        $ry += Px 32
    }
}

$script:EggDockLabels = @{ taskbar = 'Barra de tareas'; left = 'Lateral izquierdo'; right = 'Lateral derecho'; top = 'Arriba'; bottom = 'Abajo' }
function Step-HubEggDock([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $i = ([Array]::IndexOf($EggDockEdges, (Get-EggDock).Edge) + $Delta + $EggDockEdges.Count) % $EggDockEdges.Count
    Set-EggDock $EggDockEdges[$i]
    Update-HubNow
}

# FreeLLMAPI: free models for new sessions when the plan's quota runs out (lib\freellm.ps1).
function Draw-HubFreeLlmCard($G, $Map, $Hover, [System.Drawing.Rectangle]$Card) {
    $P = $script:Palette
    $F = $script:Fonts
    $free = $script:Hub.Cache.FreeLlm
    Draw-HubCard $G $Card
    if (-not $free) { return }
    $tx = $Card.X + (Px 16)
    $right = $Card.Right - (Px 16)
    $by = $Card.Y + (Px 14)
    $view = $script:View
    $outOfQuota = $view -and $view.HasData -and (($view.Session.Active -and $view.Session.Percent -ge 100) -or ($view.Weekly.Active -and $view.Weekly.Percent -ge 100))

    # buttons (and the switch), right to left
    $buttons = @()
    if ($free.Installing) { }
    elseif (-not $free.Installed) { $buttons += @{ Id = 'free-install'; Label = $(if ($free.Install -and $free.Install.state -eq 'error') { 'Reintentar' } else { 'Instalar' }); Action = { Install-HubFreeLlm }; Accent = $true } }
    elseif (-not $free.HasKey) {
        $buttons += @{ Id = 'free-key'; Label = 'Pegar clave'; Action = { Set-HubFreeLlmKey }; Accent = $true }
        $buttons += @{ Id = 'free-open'; Label = 'Abrir FreeLLMAPI'; Action = { Open-HubFreeLlm }; Accent = $false }
    } else {
        Draw-HubSwitch $G $Map 'free-switch' ($right - (Px 36)) ($by + (Px 3)) ([bool]$free.Enabled) ([scriptblock]::Create("Set-HubFreeLlmEnabled `$$(-not $free.Enabled)"))
        $right -= Px 50
        $buttons += @{ Id = 'free-key'; Label = 'Cambiar clave'; Action = { Set-HubFreeLlmKey }; Accent = $false }
        $buttons += @{ Id = 'free-open'; Label = 'Abrir'; Action = { Open-HubFreeLlm }; Accent = $false }
    }
    foreach ($button in $buttons) {
        $bw = Get-PillWidth $button.Label
        Draw-PillButton $G $Map $Hover $button.Id (New-Rect ($right - $bw) $by $bw (Px 26)) $button.Label $button.Action -Accent:$button.Accent
        $right -= $bw + (Px 8)
    }
    $tw = $right - $tx - (Px 4)

    Draw-Text $G 'Modelos gratis con FreeLLMAPI' $F.BodyStrong $P.Text $tx ($Card.Y + (Px 12)) $tw (Px 22)
    $line2 = $null; $line2Color = $P.Muted; $line3 = $null; $line3Color = $P.Faint
    if ($free.Installing) {
        $line2 = [string]$free.Install.message; $line2Color = $P.Accent
        $line3 = 'Puedes seguir usando ClaudeMaxxing mientras tanto.'
    } elseif (-not $free.Installed) {
        $line2 = (Tx 'Para cuando se acabe la cuota: junta las capas gratis de Groq, Google, Mistral\u2026 en un servidor local.')
        if ($free.Install -and $free.Install.state -eq 'error') { $line3 = [string]$free.Install.message; $line3Color = $P.Error }
        else { $line3 = (L 'Instala la app oficial v{0} (unos 110 MB, sin firma digital). Calidad y velocidad variables.') -f $FreeLlmVersion }
    } elseif (-not $free.HasKey) {
        $line2 = (Tx '1. Abre FreeLLMAPI, crea tu cuenta y a\u00f1ade claves de proveedores en Keys.')
        $line3 = (Tx '2. Copia all\u00ed tu clave unificada (freellmapi-\u2026) y pulsa Pegar clave.')
    } else {
        if ($free.Enabled) { $line2 = (Tx '\u2713 Las sesiones nuevas usan FreeLLMAPI. Las ya abiertas siguen con tu plan.'); $line2Color = $P.Ok }
        elseif ($outOfQuota) { $line2 = (Tx 'Se acab\u00f3 tu cuota: act\u00edvalo y abre una sesi\u00f3n nueva para seguir.'); $line2Color = $P.Warn }
        else { $line2 = (Tx 'Act\u00edvalo cuando se acabe la cuota: las sesiones nuevas usar\u00e1n modelos gratis.') }
        $server = ((L 'Servidor 127.0.0.1:{0} ') -f $free.Port) + (Tx '\u00b7 ') + $(if ($free.Up) { L 'abierto' } else { (Tx 'cerrado (se abre solo al lanzar una sesi\u00f3n)') })
        $line3 = $server
    }
    Draw-Text $G $line2 $F.Small $line2Color $tx ($Card.Y + (Px 42)) ($Card.Width - (Px 32)) (Px 18)
    if ($line3) { Draw-Text $G $line3 $F.Small $line3Color $tx ($Card.Y + (Px 60)) ($Card.Width - (Px 32)) (Px 18) }
}

# ---------------------------------------------------------------- Claude Whip (lib\whip.ps1)

# The plan's highest window, as the whip plugin reads it from usage.json.
function Get-HubPlanPercent {
    $view = $script:View
    $pct = 0
    if ($view -and $view.HasData) { foreach ($w in @($view.Session, $view.Weekly)) { if ($w -and $w.Active) { $pct = [Math]::Max($pct, [int]$w.Percent) } } }
    $pct
}

# Every 5 minutes from the tray: the open window's forecast for the Whip plugin (whip-forecast.json), only while the
# whip is on and the 5-hour window is past half (below, the plugin ignores it). A stale statistics scan underestimates
# the spending so far: past 5 minutes a background scan is started and the next tick uses it.
function Update-WhipForecast {
    $now = Get-Date
    $settings = Get-WhipSettings
    $view = $script:View
    $session = if ($view -and $view.HasData -and $view.Session.Active) { $view.Session } else { $null }
    if (-not $settings.Enabled -or -not (Test-HubModule 'whip') -or -not $session -or [int]$session.Percent -lt $WhipForecastFloor) {
        Save-WhipForecast $null $now
        return
    }
    $stats = Get-BusinessStats
    if (-not $stats -or (Get-StatsAgeMinutes $stats) -gt 5) { Start-HubStatsScan }
    if (-not $stats -or (Get-StatsAgeMinutes $stats) -gt 15) { Save-WhipForecast $null $now; return }
    Save-WhipForecast (Get-UsageForecast $stats.recent.usage $session $now) $now
}

function Update-HubWhip([scriptblock]$Change, [string]$Message) {
    if ($script:Hub.Preview -or -not (Test-HubModule 'whip')) { return }
    $settings = Get-WhipSettings
    & $Change $settings
    try { Save-WhipSettings $settings; Set-HubMessage $Message } catch { Set-HubMessage 'No se pudo guardar Claude Whip.' }
    Update-HubNow
}

function Set-HubWhipEnabled([bool]$On) {
    Update-HubWhip { param($s) $s.Enabled = $On } $(if ($On) { 'Claude Whip activado.' } else { 'Claude Whip apagado.' })
}

function Set-HubWhipAgent([string]$Id, [bool]$On) {
    Update-HubWhip { param($s) $s.Agents = @(@($s.Agents | Where-Object { $_ -ne $Id }) + @(if ($On) { $Id })) } $(if ($On) { (L '{0} activado.') -f $Id } else { (L '{0} apagado.') -f $Id })
}

function Set-HubWhipForecast([bool]$On) {
    Update-HubWhip { param($s) $s.Forecast = $On } $(if ($On) { 'Claude Whip entra antes del umbral si el plan va a agotarse.' } else { 'Claude Whip entra solo desde el umbral.' })
}

function Step-HubWhipThreshold([int]$Delta) {
    Update-HubWhip { param($s) $s.Threshold = Step-WhipThreshold $s.Threshold $Delta } 'Umbral de Claude Whip cambiado.'
}

function Draw-HubWhipSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $s = $c.Whip
    if (-not $s) { return }
    $pct = Get-HubPlanPercent
    $forecast = Read-JsonFile $WhipForecastFile
    $mode = Get-WhipMode $s $pct $forecast
    $agents = @($c.WhipAgents)
    $names = @($agents | Where-Object { $s.Agents -contains $_.Id } | ForEach-Object { $_.Label }) -join ', '

    # the switch, what it is doing now and the threshold
    $card = New-Rect $X0 (Px 72) $Inner (Px 154)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $tw = $card.Width - (Px 84)
    Draw-HubSwitch $G $Map 'whip-switch' ($card.Right - (Px 52)) ($card.Y + (Px 14)) ([bool]$s.Enabled) ([scriptblock]::Create("Set-HubWhipEnabled `$$(-not $s.Enabled)"))
    Draw-Text $G 'Claude Whip' $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) $tw (Px 22)
    $status, $color = switch ($mode) {
        'off'     { (Tx 'Apagado. Cuando el plan llegue al umbral, un agente programa y Claude revisa el git, ejecuta los tests y le devuelve lo que falle.'), $P.Muted }
        'noagent' { (Tx 'Activa al menos un agente abajo: sin agentes, Claude Whip no entra en acci\u00f3n.'), $P.Warn }
        'armed'   { $(if ($s.Forecast) { (Tx 'Listo: entra en acci\u00f3n cuando el plan llegue al {0}% (ahora {1}%) o vaya a agotarse antes de reiniciarse.') } else { (Tx 'Listo: entra en acci\u00f3n cuando el plan llegue al {0}% (ahora {1}%).') }) -f $s.Threshold, $pct; $P.Muted }
        'forecast' { ((Tx '\u2713 En acci\u00f3n antes del umbral: a este ritmo el plan ({0}%) se agota a las {1}. Programa {2}.') -f $pct, $forecast.limitAt, $names), $P.Ok }
        default   { ((Tx '\u2713 En acci\u00f3n (plan al {0}%): programa {1}; Claude revisa el git y los tests.') -f $pct, $names), $P.Ok }
    }
    Draw-Text $G $status $F.Small $color $tx ($card.Y + (Px 38)) ($card.Width - (Px 32)) (Px 18)
    Draw-HubPicker $G $Map $Hover 'whip-threshold' (New-Rect ($card.X + (Px 6)) ($card.Y + (Px 66)) ($card.Width - (Px 12)) (Px 30)) 'Se activa' (Format-WhipThreshold $s.Threshold) 'Step-HubWhipThreshold'
    # The forecast turns it on before the threshold only when switched on here: the threshold is what the user picked.
    Draw-HubToggleRow $G $Map $Hover 'whip-forecast' (New-Rect ($card.X + (Px 6)) ($card.Y + (Px 104)) ($card.Width - (Px 12)) (Px 42)) (Tx 'Antes del umbral, si va a agotarse') (Tx 'Desde el 50 %, cuando a este ritmo el plan se acaba antes de renovarse.') ([bool]$s.Forecast) ([scriptblock]::Create("Set-HubWhipForecast `$$(-not $s.Forecast)")) ($s.Threshold -gt 0)

    # the agents
    $y = Px 238
    Draw-HubCaption $G 'AGENTES' $X0 $y $Inner 'Cada uno gasta su propia cuota'
    $y += Px 22
    $list = New-Rect $X0 $y $Inner ([Math]::Max(1, $agents.Count) * (Px 46) + (Px 8))
    Draw-HubCard $G $list
    $ry = $list.Y + (Px 4)
    foreach ($agent in $agents) {
        $on = $s.Agents -contains $agent.Id
        $sub = if ($agent.Installed) { $agent.Note } else { (L 'No instalado: ') + $agent.Install }
        $row = New-Rect ($list.X + (Px 6)) $ry ($list.Width - (Px 12)) (Px 42)
        Draw-HubToggleRow $G $Map $Hover "whip-agent-$($agent.Id)" $row "$($agent.Label)  $(Tx '\u00b7')  $($agent.Vendor)" $sub $on ([scriptblock]::Create("Set-HubWhipAgent '$($agent.Id)' `$$(-not $on)")) ([bool]($agent.Installed -or $on))
        # the account, plan and until when, right-aligned on the label's line
        if ($agent.Installed -and $agent.Account -and $agent.Account.Text) {
            $tone = switch ($agent.Account.Tone) { 'ok' { $P.Ok } 'warn' { $P.Warn } default { $P.Faint } }
            Draw-Text $G $agent.Account.Text $F.Small $tone ($row.X + (Px 200)) ($row.Y + (Px 4)) ($row.Width - (Px 266)) (Px 18) 'Right'
        }
        $ry += Px 46
    }

    $y = $list.Bottom + (Px 14)
    Draw-HubCaption $G (Tx 'C\u00d3MO FUNCIONA') $X0 $y $Inner ''
    Draw-Wrapped $G (Tx 'Un ciclo entre Claude y el agente: Claude planea y escribe el encargo, el agente programa, Claude mira el git y ejecuta los tests, y le devuelve lo que fall\u00f3 hasta que pasen (como mucho 3 rondas). En todas las sesiones, tambi\u00e9n las abiertas, Claude no puede editar, escribir ni lanzar subagentes (skill claude-whip).') $F.Small $P.Muted $X0 ($y + (Px 22)) $Inner (Px 54)
    Draw-Wrapped $G (Tx 'El uso del plan sale de la statusline de ClaudeMaxxing. Apagado o por debajo del umbral, las sesiones funcionan como siempre.') $F.Small $P.Faint $X0 ($y + (Px 80)) $Inner (Px 36)
}

# ---------------------------------------------------------------- Otros PCs

function Draw-HubPcsSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $b = $script:Bridge

    # this PC: status, fix and the "Acepta conexiones" switch
    $card = New-Rect $X0 (Px 72) $Inner (Px 64)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $self = if ($b -and $b.Identity) { $b.Identity.name + (Tx '  \u00b7  ') + $b.Identity.user } else { $env:COMPUTERNAME }
    Draw-Text $G 'ESTE PC' $F.Caps $P.Muted $tx ($card.Y + (Px 10)) (Px 120) (Px 18)
    Draw-Text $G $self $F.BodyStrong $P.Text ($tx + (Px 64)) ($card.Y + (Px 8)) (Px 300) (Px 22)
    $status = Get-BridgeStatus
    $statusW = $card.Width - (Px 32)
    if ($status.Fix) {
        $fw = Get-PillWidth $status.Fix
        Draw-PillButton $G $Map $Hover 'pcs-fix' (New-Rect ($card.Right - (Px 16) - $fw) ($card.Y + (Px 34)) $fw (Px 22)) $status.Fix $status.FixAction -Accent
        $statusW -= $fw + (Px 8)
    }
    Draw-Text $G $status.Text $F.Small $status.Color $tx ($card.Y + (Px 36)) $statusW (Px 18)
    if ($b -and $b.Ready) {
        $on = [bool]$b.Settings.acceptIncoming
        $sx = $card.Right - (Px 52)
        $labelW = Px 130
        $hit = New-Rect ($sx - $labelW - (Px 8)) ($card.Y + (Px 9)) ($labelW + (Px 44)) (Px 20)
        Draw-Text $G 'Acepta conexiones' $F.Small $P.Muted $hit.X $hit.Y $labelW $hit.Height 'Right'
        Draw-HubSwitch $G $Map 'pcs-accept' $sx ($card.Y + (Px 9)) $on ([scriptblock]::Create("Set-BridgeAccept `$$(-not $on)")) $true $hit
    }

    # diagram, shorter: the list below says the same in words
    $net = New-Rect $X0 (Px 148) $Inner (Px 200)
    Draw-HubCard $G $net
    Draw-HubNetwork $G $Map $Hover $net $true 'none'

    # every PC: paired ones first, then the ones found and not paired, each with what can be done now
    $y = Px 362
    $nodes = @(Get-HubNetworkNodes | Where-Object { $_.Id })
    $rows = @(@($nodes | Where-Object { $_.Paired }) + @($nodes | Where-Object { -not $_.Paired }))
    Draw-HubCaption $G 'TUS PCS' $X0 $y $Inner $(if ($rows.Count -gt 4) { "+$($rows.Count - 4) " + (Tx 'm\u00e1s en Otros PCs') } else { '' })
    $y += Px 22
    if (-not $rows.Count) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'A\u00fan no hay PCs emparejados. Abre Otros PCs en los dos para emparejarlos.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
        $y += Px 44
    }
    foreach ($node in @($rows | Select-Object -First 4)) {
        $row = New-Rect $X0 $y $Inner (Px 50)
        Fill-Round $G $row (Px 8) $P.Surface
        $style = Get-HubLinkStyle $node.State
        $live = $node.State -eq 'session' -or $node.State -eq 'online'
        Draw-HubDot $G ($row.X + (Px 14)) ($row.Y + (Px 21)) (Px 8) $(if ($live) { $P.Ok } else { $style.Color })
        $right = $row.Right - (Px 10)
        # Only what works now: a PC not seen today gets no buttons, one not paired gets Emparejar.
        $buttons = @()
        if (-not $node.Paired) { $buttons = @(@{ Id = "pcs-pair-$($node.Id)"; Label = 'Emparejar'; Action = 'Show-BridgeDialog' }) }
        elseif ($live) {
            $buttons = @(@{ Id = "pcs-term-$($node.Id)"; Label = 'Terminal'; Action = "Open-BridgeTerminal '$($node.Id)'" },
                         @{ Id = "pcs-claude-$($node.Id)"; Label = 'Claude Code'; Action = "Open-BridgeTerminal '$($node.Id)' -Claude" })
            if ($node.Sessions.Count) { $buttons += @{ Id = "pcs-stop-$($node.Id)"; Label = 'Desconectar'; Action = "Stop-HubPeerSessions '$($node.Id)'" } }
        }
        foreach ($button in $buttons) {
            $bw = Get-PillWidth $button.Label
            $rect = New-Rect ($right - $bw) ($row.Y + (Px 12)) $bw (Px 26)
            Draw-PillButton $G $Map $Hover $button.Id $rect $button.Label ([scriptblock]::Create($button.Action))
            $right = $rect.X - (Px 6)
        }
        $textX = $row.X + (Px 30)
        $textW = $right - $textX - (Px 10)
        Draw-Text $G $node.Name $F.BodyStrong $P.Text $textX ($row.Y + (Px 5)) $textW (Px 20)
        $sub = $node.Sub
        if ($node.Address) { $sub = $node.Address + (Tx '  \u00b7  ') + $sub }
        Draw-Text $G $sub $F.Small $(if ($live) { $P.Ok } else { $P.Muted }) $textX ($row.Y + (Px 26)) $textW (Px 18)
        $y += Px 54
    }

    $label = 'Emparejar otro PC'
    $bw = (Get-PillWidth $label) + (Px 10)
    $by = [Math]::Max($y + (Px 8), (Px 590))
    Draw-PillButton $G $Map $Hover 'pcs-open' (New-Rect $X0 $by $bw (Px 30)) $label { Show-BridgeDialog } -Accent
    Draw-Wrapped $G (Tx 'El otro PC tambi\u00e9n debe tener abierta Otros PCs mientras emparejas. Cada conexi\u00f3n entrante te pide permiso.') $F.Small $P.Muted ($X0 + $bw + (Px 14)) ($by - (Px 2)) ($Inner - $bw - (Px 14)) (Px 34)
}

# ---------------------------------------------------------------- Claude Whisper

# A few options side by side with the current one highlighted. A click on another runs "$Command <steps>", the same
# step command the pickers use, so the setting is saved the same way. Returns the control's rectangle.
function Draw-HubSegmented($G, $Map, $Hover, [string]$Id, [int]$Right, [int]$Y, $Options, [string]$Current, [string]$Command, [bool]$Enabled = $true) {
    $P = $script:Palette
    $F = $script:Fonts
    $keys = @($Options.Keys)
    $widths = @($keys | ForEach-Object { (Measure-TextWidth $Options[$_] $script:HubFonts.Label) + (Px 22) })
    $total = [int](($widths | Measure-Object -Sum).Sum) + (Px 4)
    $box = New-Rect ($Right - $total) $Y $total (Px 28)
    Fill-Round $G $box (Px 7) $P.Back
    Stroke-Round $G $box (Px 7) $P.Border
    $at = [array]::IndexOf($keys, $Current)
    $x = $box.X + (Px 2)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $seg = New-Rect $x ($box.Y + (Px 2)) $widths[$i] ($box.Height - (Px 4))
        $hitId = "$Id-$($keys[$i])"
        $on = $i -eq $at
        if ($on) { Fill-Round $G $seg (Px 5) $P.AccentTint } elseif ($Enabled -and $Hover -eq $hitId) { Fill-Round $G $seg (Px 5) $P.SurfaceHover }
        $color = if ($on) { $P.Accent } elseif ($Enabled) { $P.Muted } else { $P.Faint }
        Draw-Text $G $Options[$keys[$i]] $(if ($on) { $script:HubFonts.Label } else { $F.Small }) $color $seg.X $seg.Y $seg.Width $seg.Height 'Center'
        if ($Enabled -and -not $on) { Add-Hit $Map $hitId $seg ([scriptblock]::Create("$Command $($i - $at)")) }
        $x += $widths[$i]
    }
    $box
}

# "Ctrl+Alt+Shift+R" as one key cap per key, from $X. Returns the width; -Measure only measures (to right-align).
function Draw-HubKeys($G, [string]$Keys, [int]$X, [int]$Y, [switch]$Measure) {
    $P = $script:Palette
    $font = $script:HubFonts.Key
    # Not $x: PowerShell names ignore case, so it would be the $X parameter itself.
    $capX = $X
    foreach ($key in @(([string]$Keys -split '\+') | Where-Object { $_ })) {
        $w = (Measure-TextWidth $key $font) + (Px 10)
        if (-not $Measure) {
            $cap = New-Rect $capX $Y $w (Px 20)
            Fill-Round $G $cap (Px 4) $P.Back
            Stroke-Round $G $cap (Px 4) $P.Border
            Draw-Text $G $key $font $P.Text $cap.X $cap.Y $cap.Width $cap.Height 'Center'
        }
        $capX += $w + (Px 4)
    }
    [Math]::Max(0, $capX - $X - (Px 4))
}

# A value picked from a list that opens under it: Windows' own menu, in the palette. Choosing runs "$Command <steps>",
# the step command the pickers use, so the setting is saved the same way.
$script:HubDropdowns = @{}
function Draw-HubDropdown($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Row, [string]$Label, $Options, [string]$Current, [string]$Command, [bool]$Enabled = $true) {
    $P = $script:Palette
    $F = $script:Fonts
    Draw-Text $G $Label $F.Body $(if ($Enabled) { $P.Text } else { $P.Muted }) ($Row.X + (Px 10)) $Row.Y (Px 150) $Row.Height
    $box = New-Rect ($Row.Right - (Px 168)) ($Row.Y + (Px 3)) (Px 160) ($Row.Height - (Px 6))
    Fill-Round $G $box (Px 7) $(if ($Enabled -and $Hover -eq $Id) { $P.SurfaceHover } else { $P.Back })
    Stroke-Round $G $box (Px 7) $P.Border
    $value = if ($Options.Contains($Current)) { $Options[$Current] } else { $Current }
    Draw-Text $G $value $F.Body $(if ($Enabled) { $P.Text } else { $P.Muted }) ($box.X + (Px 10)) $box.Y ($box.Width - (Px 34)) $box.Height
    Draw-Text $G (Tx '\u25be') $F.Body $P.Muted ($box.Right - (Px 26)) $box.Y (Px 18) $box.Height 'Center'
    if (-not $Enabled) { return }
    $script:HubDropdowns[$Id] = @{ Box = $box; Options = $Options; Current = $Current; Command = $Command; Zoom = $Map.Zoom }
    Add-Hit $Map $Id $box ([scriptblock]::Create("Show-HubDropdown '$Id'"))
}

function Show-HubDropdown([string]$Id) {
    $d = $script:HubDropdowns[$Id]
    if (-not $d -or -not $script:HubDialog) { return }
    # The default colors are light blue on white; compiled on the first dropdown only.
    if (-not ('ClaudeTray.DarkMenuColors' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
namespace ClaudeTray {
    public class DarkMenuColors : ProfessionalColorTable {
        private readonly Color back, hover, border;
        public DarkMenuColors(Color back, Color hover, Color border) { this.back = back; this.hover = hover; this.border = border; }
        public override Color ToolStripDropDownBackground { get { return back; } }
        public override Color ImageMarginGradientBegin { get { return back; } }
        public override Color ImageMarginGradientMiddle { get { return back; } }
        public override Color ImageMarginGradientEnd { get { return back; } }
        public override Color MenuBorder { get { return border; } }
        public override Color MenuItemBorder { get { return hover; } }
        public override Color MenuItemSelected { get { return hover; } }
    }
}
'@
    }
    $P = $script:Palette
    if ($script:HubDropdownMenu) { $script:HubDropdownMenu.Dispose() }
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:HubDropdownMenu = $menu
    $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object ClaudeTray.DarkMenuColors($P.Surface, $P.SurfaceHover, $P.Border)))
    $menu.ShowImageMargin = $false
    $menu.ShowCheckMargin = $false
    $menu.BackColor = $P.Surface
    $menu.Font = $script:Fonts.Body
    $zoom = if ($d.Zoom -and $d.Zoom -lt 1) { $d.Zoom } else { 1 }
    $menu.MinimumSize = New-Object System.Drawing.Size([int]($d.Box.Width * $zoom), 0)
    $keys = @($d.Options.Keys)
    $at = [array]::IndexOf($keys, $d.Current)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem((L $d.Options[$keys[$i]]))
        $item.ForeColor = if ($i -eq $at) { $P.Accent } else { $P.Text }
        $item.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
        if ($i -ne $at) { $item.Add_Click([scriptblock]::Create("$($d.Command) $($i - $at)")) }
        [void]$menu.Items.Add($item)
    }
    $menu.Show($script:HubDialog, (New-Object System.Drawing.Point([int]($d.Box.X * $zoom), [int](($d.Box.Bottom + (Px 2)) * $zoom))))
}

function Draw-HubGroupTitle($G, [string]$Text, [int]$X, [int]$Y, [int]$W) {
    Draw-Text $G $Text $script:Fonts.Caps $script:Palette.Accent $X $Y $W (Px 18)
}

$script:HubWhisperModelLabels = [ordered]@{ sonnet = 'Sonnet'; haiku = 'Haiku'; opus = 'Opus' }

function Draw-HubWhisperSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $c = $script:Hub.Cache
    $running = [bool]$c.WhisperRunning
    $settings = $c.WhisperSettings
    if (-not $settings) { $settings = Get-WhisperDefaults }

    # status and the one main action
    $card = New-Rect $X0 (Px 72) $Inner (Px 70)
    Draw-HubCard $G $card
    $icon = New-Rect ($card.X + (Px 14)) ($card.Y + (Px 15)) (Px 40) (Px 40)
    Draw-HubDot $G $icon.X $icon.Y $icon.Width $(if ($running) { $P.AccentTint } else { $P.Back })
    Draw-Text $G (Tx '\ue720') $HF.NodeLarge $(if ($running) { $P.Accent } else { $P.Muted }) $icon.X $icon.Y $icon.Width $icon.Height 'Center'
    $label = if ($running) { 'Mostrar ventana' } else { 'Abrir Claude Whisper' }
    $bw = (Get-PillWidth $label) + (Px 8)
    $open = New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 21)) $bw (Px 28)
    Draw-PillButton $G $Map $Hover 'whisper-open' $open $label { Open-HubWhisper } -Accent
    $tx = $icon.Right + (Px 12)
    $state = if ($running) { 'Abierto' } else { 'Cerrado' }
    Draw-HubDot $G $tx ($card.Y + (Px 21)) (Px 8) $(if ($running) { $P.Ok } else { $P.Faint })
    Draw-Text $G $state $F.BodyStrong $P.Text ($tx + (Px 14)) ($card.Y + (Px 13)) ($open.X - $tx - (Px 26)) (Px 22)
    Draw-Wrapped $G (Tx 'Transcribe la llamada y te dice qu\u00e9 responder, con tu suscripci\u00f3n de Claude.') $F.Small $P.Muted $tx ($card.Y + (Px 36)) ($open.X - $tx - (Px 12)) (Px 30)

    $leftW = [int]($Inner * 0.54)
    $rx = $X0 + $leftW + (Px 14)
    $rw = $Inner - $leftW - (Px 14)

    # settings, in three groups; edited here only while Whisper is closed (Set-HubWhisperSetting)
    $enabled = -not $running
    $scard = New-Rect $X0 (Px 154) $leftW (Px 356)
    Draw-HubCard $G $scard
    $rowX = $scard.X + (Px 4)
    $rowW = $scard.Width - (Px 8)
    $gx = $scard.X + (Px 14)
    $ry = $scard.Y + (Px 10)
    Draw-HubGroupTitle $G 'ESCUCHAR' $gx $ry $rowW
    $ry += Px 22
    Draw-HubDropdown $G $Map $Hover 'wl' (New-Rect $rowX $ry $rowW (Px 30)) 'Idioma' $script:WhisperLanguages $settings.language "Set-HubWhisperSetting 'language'" $enabled
    $ry += Px 32
    Draw-HubToggleRow $G $Map $Hover 'ws-useMic' (New-Rect $rowX $ry $rowW (Px 30)) (Tx 'Transcribir tambi\u00e9n mi micr\u00f3fono') '' ([bool]$settings.useMic) { Set-HubWhisperSetting 'useMic' } $enabled
    $ry += Px 32
    Draw-HubToggleRow $G $Map $Hover 'ws-gateMic' (New-Rect $rowX $ry $rowW (Px 42)) 'Uso altavoces, sin auriculares' (Tx 'Evita que tu micr\u00f3fono transcriba el eco') ([bool]$settings.gateMic) { Set-HubWhisperSetting 'gateMic' } $enabled
    $ry += Px 50
    Draw-HubGroupTitle $G 'RESPONDER' $gx $ry $rowW
    $ry += Px 22
    Draw-Text $G 'Modelo' $F.Body $(if ($enabled) { $P.Text } else { $P.Muted }) ($rowX + (Px 10)) $ry (Px 120) (Px 30)
    [void](Draw-HubSegmented $G $Map $Hover 'wm' ($scard.Right - (Px 12)) ($ry + (Px 1)) $script:HubWhisperModelLabels $settings.model "Set-HubWhisperSetting 'model'" $enabled)
    $ry += Px 34
    Draw-HubToggleRow $G $Map $Hover 'ws-autoAnswer' (New-Rect $rowX $ry $rowW (Px 42)) 'Responder sola a las preguntas' 'Apagado, responde solo cuando lo pides' ([bool]$settings.autoAnswer) { Set-HubWhisperSetting 'autoAnswer' } $enabled
    $ry += Px 44
    Draw-HubToggleRow $G $Map $Hover 'ws-meetingNotice' (New-Rect $rowX $ry $rowW (Px 30)) 'Avisarme al empezar una llamada' '' ([bool]$settings.meetingNotice) { Set-HubWhisperSetting 'meetingNotice' } $enabled
    $ry += Px 38
    Draw-HubGroupTitle $G 'VENTANA' $gx $ry $rowW
    $ry += Px 22
    Draw-HubToggleRow $G $Map $Hover 'ws-topMost' (New-Rect $rowX $ry $rowW (Px 30)) (Tx 'Siempre encima de las dem\u00e1s ventanas') '' ([bool]$settings.topMost) { Set-HubWhisperSetting 'topMost' } $enabled
    $note = if ($running) { Tx 'Mientras est\u00e1 abierto, cambia los ajustes desde su ventana (Contexto y el men\u00fa \u22ef).' }
            else { Tx 'Los cambios se aplican la pr\u00f3xima vez que lo abras.' }
    Draw-Wrapped $G $note $F.Small $P.Muted $X0 ($scard.Bottom + (Px 8)) $leftW (Px 34)

    # context, with its Editar button inside
    $ccard = New-Rect $rx (Px 154) $rw (Px 118)
    $hitId = 'whisper-context-card'
    Fill-Round $G $ccard (Px 10) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
    Add-Hit $Map $hitId $ccard { Edit-HubWhisperContext }
    $ebw = Get-PillWidth 'Editar'
    Draw-PillButton $G $Map $Hover 'whisper-context' (New-Rect ($ccard.Right - (Px 12) - $ebw) ($ccard.Y + (Px 10)) $ebw (Px 24)) 'Editar' { Edit-HubWhisperContext }
    Draw-Text $G 'CONTEXTO PARA LAS RESPUESTAS' $F.Caps $P.Muted ($ccard.X + (Px 14)) ($ccard.Y + (Px 13)) ($ccard.Width - $ebw - (Px 40)) (Px 18)
    $termCount = @(([string]$settings.keyterms) -split '[,;\r\n]+' | Where-Object { $_.Trim() }).Count
    $lines = @(
        @('Perfil', $(if ($settings.profile) { ((L '{0} caracteres') -f ([string]$settings.profile).Length) } else { (Tx 'vac\u00edo: a\u00f1ade tu CV') })),
        @((Tx 'Conversaci\u00f3n'), $(if ($settings.meeting) { (([string]$settings.meeting) -split "`n")[0].Trim() } else { 'sin describir' })),
        @((Tx 'T\u00e9rminos'), $(if ($termCount) { "$termCount " + (Tx 'para la transcripci\u00f3n') } else { 'ninguno' }))
    )
    $ly = $ccard.Y + (Px 42)
    foreach ($line in $lines) {
        Draw-Text $G $line[0] $F.Small $P.Muted ($ccard.X + (Px 14)) $ly (Px 90) (Px 24)
        Draw-Text $G $line[1] $F.Body $P.Text ($ccard.X + (Px 104)) $ly ($ccard.Width - (Px 118)) (Px 24)
        $ly += Px 24
    }

    # global hotkeys: what each does, its key caps under it (the column is too narrow for both on one line)
    $kcard = New-Rect $rx ($ccard.Bottom + (Px 12)) $rw (Px 172)
    Draw-HubCard $G $kcard
    Draw-Text $G 'ATAJOS, EN CUALQUIER VENTANA' $F.Caps $P.Muted ($kcard.X + (Px 14)) ($kcard.Y + (Px 10)) ($kcard.Width - (Px 28)) (Px 18)
    $ky = $kcard.Y + (Px 32)
    foreach ($key in @(@($settings.hotkeyAnswer, 'Responder ahora'), @($settings.hotkeyScreen, 'Resolver la pantalla'), @($settings.hotkeyToggle, 'Mostrar u ocultar'))) {
        Draw-Text $G $key[1] $F.Small $P.Text ($kcard.X + (Px 14)) $ky ($kcard.Width - (Px 28)) (Px 18)
        [void](Draw-HubKeys $G $key[0] ($kcard.X + (Px 14)) ($ky + (Px 19)))
        $ky += Px 46
    }

    # the latest calls
    $count = [int]$c.CallCount
    $cy = $kcard.Bottom + (Px 14)
    Draw-HubCaption $G $(if ($count) { (L 'LLAMADAS ({0})') -f $count } else { 'LLAMADAS' }) $rx $cy $rw ''
    $folder = New-Rect ($rx + $rw - (Px 110)) $cy (Px 110) (Px 18)
    Draw-Text $G (Tx 'Abrir carpeta \u203a') $F.Small $(if ($Hover -eq 'whisper-folder') { $P.AccentHover } else { $P.Accent }) $folder.X $folder.Y $folder.Width $folder.Height 'Right'
    Add-Hit $Map 'whisper-folder' $folder { Open-HubCallFolder }
    $calls = @($c.Calls)
    $y = $cy + (Px 22)
    if (-not $calls.Count) {
        $row = New-Rect $rx $y $rw (Px 60)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Wrapped $G (Tx 'A\u00fan no hay llamadas. Abre Claude Whisper durante una llamada y pulsa Escuchar: cada llamada se guarda aqu\u00ed.') $F.Small $P.Muted ($rx + (Px 14)) ($y + (Px 10)) ($rw - (Px 28)) (Px 44)
    }
    $now = Get-Date
    for ($i = 0; $i -lt [Math]::Min(3, $calls.Count); $i++) {
        $call = $calls[$i]
        $row = New-Rect $rx $y $rw (Px 46)
        $hitId = "whisper-call-$i"
        Fill-Round $G $row (Px 8) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
        $when = if ($call.Started) { Format-DialogDateTime $call.Started $now } else { $call.Name }
        Draw-Text $G $when $F.BodyStrong $P.Text ($row.X + (Px 12)) ($row.Y + (Px 4)) ($row.Width - (Px 24)) (Px 20)
        Draw-Text $G (Format-CallDuration $call.Minutes) $F.Small $P.Muted ($row.X + (Px 12)) ($row.Y + (Px 4)) ($row.Width - (Px 24)) (Px 20) 'Right'
        $topic = if ($call.Topic) { $call.Topic } else { 'Sin preguntas' }
        Draw-Text $G $topic $F.Small $P.Muted ($row.X + (Px 12)) ($row.Y + (Px 24)) ($row.Width - (Px 24)) (Px 18)
        Add-Hit $Map $hitId $row ([scriptblock]::Create("Open-HubCall $i"))
        $y += Px 50
    }
}

# ---------------------------------------------------------------- Voz

$script:HubVoiceEngineLabels = [ordered]@{ edge = 'Edge'; elevenlabs = 'ElevenLabs'; gemini = 'Gemini'; sapi = 'Windows' }
$script:HubVoiceGenderLabels = [ordered]@{ mix = 'Mixtas'; f = 'Femeninas'; m = 'Masculinas' }

function Draw-HubVoiceSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache

    $card = New-Rect $X0 (Px 72) $Inner (Px 112)
    Draw-HubCard $G $card
    if (-not $c.VoiceInstalled) {
        Draw-Wrapped $G (Tx 'La voz no est\u00e1 instalada. Vuelve a ejecutar install.ps1.') $F.Body $P.Warn ($card.X + (Px 16)) ($card.Y + (Px 16)) ($card.Width - (Px 32)) (Px 40)
        return
    }
    $rowX = $card.X + (Px 6)
    $rowW = $card.Width - (Px 12)
    $row = New-Rect $rowX ($card.Y + (Px 8)) $rowW (Px 42)
    Draw-HubToggleRow $G $Map $Hover 'voice-on' $row 'Voz en todas las sesiones' (Tx 'Si la apagas, ninguna sesi\u00f3n habla') (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)"))
    # Drawn after its row, so its click wins over the row's (Find-Hit takes the last one).
    $bw = Get-PillWidth 'Probar voz'
    Draw-PillButton $G $Map $Hover 'voice-test' (New-Rect ($row.Right - (Px 58) - $bw) ($row.Y + (Px 8)) $bw (Px 26)) 'Probar voz' { Invoke-VoiceCtl 'test' 'Reproduciendo una frase de prueba...' } -Accent
    # A one-space second line puts the label on top; the key caps go under it.
    $row = New-Rect $rowX ($card.Y + (Px 56)) $rowW (Px 50)
    Draw-HubToggleRow $G $Map $Hover 'voice-keys' $row 'Atajos de teclado' ' ' ([bool]$c.HotkeysOn) ([scriptblock]::Create("Set-HubHotkeys `$$(-not $c.HotkeysOn)"))
    $kx = $row.X + (Px 10)
    foreach ($pair in @(@((Tx 'Repetir lo \u00faltimo'), 'Ctrl+Alt+Shift+O'), @('Detener', 'Ctrl+Alt+Shift+P'))) {
        $lw = (Measure-TextWidth $pair[0] $F.Small) + (Px 6)
        Draw-Text $G $pair[0] $F.Small $P.Muted $kx ($row.Y + (Px 24)) $lw (Px 20)
        $kx += $lw + (Draw-HubKeys $G $pair[1] ($kx + $lw) ($row.Y + (Px 24))) + (Px 18)
    }

    # engine: the four side by side, its credits and its key
    $state = $c.VoiceEngine
    $engine = if ($state) { $state.Engine } else { 'edge' }
    $ey = $card.Bottom + (Px 12)
    $credits = if ($engine -eq 'elevenlabs' -and $state.ElevenKey -and $state.Credits -and $state.Credits.limit -and -not $state.Snooze) { $state.Credits } else { $null }
    $keyed = $engine -in @('elevenlabs', 'gemini')
    $eh = (Px 96) + $(if ($credits) { Px 66 } else { 0 }) + $(if ($keyed) { Px 42 } else { 0 })
    $ecard = New-Rect $X0 $ey $Inner $eh
    Draw-HubCard $G $ecard
    $seg = Draw-HubSegmented $G $Map $Hover 'voice-engine' ($ecard.Right - (Px 14)) ($ecard.Y + (Px 12)) $script:HubVoiceEngineLabels $engine 'Set-HubVoiceEngine'
    $tx = $ecard.X + (Px 16)
    $tw = $seg.X - $tx - (Px 16)
    Draw-Text $G 'Motor de voz' $F.BodyStrong $P.Text $tx ($ecard.Y + (Px 12)) $tw (Px 22)
    $detail = switch ($engine) {
        'elevenlabs' {
            if (-not $state.ElevenKey) { Tx 'La m\u00e1s natural. Crea una cuenta gratis en elevenlabs.io (unos 10.000 cr\u00e9ditos al mes, unos 100 res\u00famenes) y pega aqu\u00ed tu clave. Sin clave se usa Edge.' }
            else { (Tx 'Voces de tu cuenta, una distinta por sesi\u00f3n. ') + (Tx ' Sin cr\u00e9ditos, pasa sola a Edge.') }
        }
        'gemini' {
            if (-not $state.GeminiKey) { Tx 'Muy natural. Pide una clave gratis en aistudio.google.com (capa gratuita con l\u00edmite diario) y p\u00e9gala aqu\u00ed. Sin clave se usa Edge.' }
            else { Tx 'Voces de Google con tono c\u00e1lido y conversacional. Si llega al l\u00edmite gratis del d\u00eda, pasa sola a Edge.' }
        }
        'sapi' { Tx 'La voz de Windows: sin internet, pero la menos natural.' }
        default { Tx 'Voces neuronales de Microsoft, gratis y sin clave. ElevenLabs y Gemini suenan m\u00e1s naturales.' }
    }
    $detailColor = $P.Muted
    if ($state -and $state.Snooze) {
        $detail = $script:VoiceEngines[$engine] + (L ' en pausa hasta las ') + (Format-Clock $state.Snooze.Until) + $(if ($state.Snooze.Why) { ' (' + $state.Snooze.Why + ')' } else { '' }) + (Tx ': mientras, los res\u00famenes usan Edge.')
        # Out of credits: they come back with the plan's monthly renewal, not at the end of the pause.
        if ($engine -eq 'elevenlabs' -and "$($state.Snooze.Why)" -like 'sin cr*') { $detail = Get-ElevenNoCreditsText $state.Credits }
        $detailColor = $P.Warn
    }
    Draw-Wrapped $G $detail $F.Small $detailColor $tx ($ecard.Y + (Px 38)) $tw (Px 50)
    $y = $ecard.Y + (Px 96)
    if ($credits -or $keyed) {
        $pen = New-HubPen $P.Border 1
        $G.DrawLine($pen, $tx, ($y - (Px 6)), ($ecard.Right - (Px 16)), ($y - (Px 6)))
        $pen.Dispose()
    }
    $rw = $ecard.Width - (Px 32)
    if ($credits) {
        $limit = [int]$credits.limit
        $left = [Math]::Max(0, $limit - [int]$credits.used)
        Draw-Text $G (Tx 'Cr\u00e9ditos de ElevenLabs') $F.Body $P.Text $tx $y $rw (Px 22)
        Draw-Text $G ((L '{0} de {1} ').Trim() -f $left.ToString('N0', $UiCulture), $limit.ToString('N0', $UiCulture)) $F.BodyStrong $P.Text $tx $y $rw (Px 22) 'Right'
        $track = New-Rect $tx ($y + (Px 26)) $rw (Px 8)
        Fill-Round $G $track (Px 4) $P.Track
        $fraction = [Math]::Min(1.0, $left / [double]$limit)
        if ($fraction -gt 0) { Fill-Round $G (New-Rect $tx $track.Y ([Math]::Max((Px 8), [int]($rw * $fraction))) $track.Height) (Px 4) $(if ($fraction -lt 0.1) { $P.Warn } else { $P.Ok }) }
        $renew = ''
        if ($credits.resetAt) { try { $renew = (L 'Se renuevan el {0}, con tu plan mensual.') -f ([datetime]$credits.resetAt).ToString('d MMM', $UiCulture).TrimEnd('.') } catch { } }
        $link = New-Rect ($tx + $rw - (Px 160)) ($y + (Px 38)) (Px 160) (Px 20)
        Draw-Text $G $renew $F.Small $P.Muted $tx ($y + (Px 38)) ($rw - (Px 170)) (Px 20)
        Draw-Text $G (Tx 'Actualizar cr\u00e9ditos') $F.Small $(if ($Hover -eq 'voice-credits') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height 'Right'
        Add-Hit $Map 'voice-credits' $link { Update-HubVoiceCredits }
        $y += Px 66
    }
    if ($keyed) {
        $hasKey = if ($engine -eq 'elevenlabs') { [bool]$state.ElevenKey } else { [bool]$state.GeminiKey }
        $label = if ($hasKey) { 'Cambiar clave' } else { 'Pegar clave' }
        $bw = Get-PillWidth $label
        Draw-PillButton $G $Map $Hover 'voice-key' (New-Rect ($tx + $rw - $bw) ($y + (Px 2)) $bw (Px 26)) $label ([scriptblock]::Create("Set-HubVoiceKey '$engine'")) -Accent:(-not $hasKey)
        Draw-Text $G $(if ($hasKey) { (L 'Clave guardada') } else { (L 'Sin clave: mientras, se usa Edge.') }) $F.Small $(if ($hasKey) { $P.Muted } else { $P.Warn }) $tx $y ($rw - $bw - (Px 12)) (Px 30)
    }

    # sessions of the last 12 hours, each with its own switch
    $y = $ecard.Bottom + (Px 16)
    $sessions = @($c.VoiceSessions)
    Draw-HubCaption $G (Tx 'SESIONES DE LAS \u00daLTIMAS 12 H') $X0 $y $Inner $(if ($sessions.Count -gt 4) { (Tx '+{0} m\u00e1s') -f ($sessions.Count - 4) } else { '' })
    $y += Px 22
    if (-not $sessions.Count) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Ninguna sesi\u00f3n ha hablado en las \u00faltimas horas.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
        $y += Px 44
    }
    $now = Get-Date
    for ($i = 0; $i -lt [Math]::Min(4, $sessions.Count); $i++) {
        $session = $sessions[$i]
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 8) $P.Surface
        $hex = if ($session.Color) { Get-HubSlotHex $session.Color } else { [System.Drawing.ColorTranslator]::ToHtml($P.Faint) }
        Draw-HubEgg $G ($row.X + (Px 20)) ($row.Y + (Px 22)) (Px 22) $hex
        $name = $session.Name
        if ($session.Role) { $name += (Tx ' \u00b7 ') + $session.Role }
        $textX = $row.X + (Px 36)
        $textW = $row.Width - (Px 100)
        Draw-Text $G $name $F.BodyStrong $(if ($session.Muted) { $P.Muted } else { $P.Text }) $textX ($row.Y + (Px 4)) $textW (Px 20)
        $ago = $now - $session.Used
        $used = if ($ago.TotalMinutes -lt 1) { L 'ahora' } elseif ($ago.TotalHours -lt 1) { (L 'hace {0} min') -f [int]$ago.TotalMinutes } else { (L 'a las ') + (Format-Clock $session.Used) }
        $when = if ($session.Muted) { L 'silenciada' } else { $used }
        Draw-Text $G ((L 'voz ') + (Format-VoiceName $session.Voice) + (Tx '  \u00b7  ') + $when) $F.Small $P.Muted $textX ($row.Y + (Px 23)) $textW (Px 18)
        Draw-HubSwitch $G $Map "voice-session-$i" ($row.Right - (Px 50)) ($row.Y + (Px 12)) (-not $session.Muted) ([scriptblock]::Create("Set-HubVoiceSessionMuted $i"))
        $y += Px 48
    }
    Draw-Text $G (Tx 'Para cambiar la voz de una sesi\u00f3n, escribe /voz dentro de ella.') $F.Small $P.Muted $X0 ($y + (Px 2)) $Inner (Px 20)
}

# ---------------------------------------------------------------- preview (tray.ps1 -RenderHubTo)

# ---------------------------------------------------------------- Configuracion

function Draw-HubSettingsSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    # Read once per window: the catalogs do not change while it is open.
    if (-not $script:Hub.Languages) { $script:Hub.Languages = Get-UiLanguages }
    Draw-HubCaption $G 'IDIOMA' $X0 (Px 74) $Inner ''
    $card = New-Rect $X0 (Px 96) $Inner (Px 96)
    Draw-HubCard $G $card
    Draw-HubDropdown $G $Map $Hover 'language' (New-Rect ($card.X + (Px 8)) ($card.Y + (Px 12)) ($card.Width - (Px 16)) (Px 30)) 'Idioma' $script:Hub.Languages $script:UiLanguage 'Step-HubLanguage'
    Draw-Wrapped $G (Tx 'El de esta ventana, la bandeja y sus avisos. Claude Whisper y las dem\u00e1s ventanas lo toman al abrirse de nuevo.') $F.Small $P.Muted ($card.X + (Px 18)) ($card.Y + (Px 52)) ($card.Width - (Px 36)) (Px 36)

    # Captura a Claude Code (lib\snip.ps1).
    Draw-HubCaption $G 'CAPTURAS' $X0 (Px 210) $Inner ''
    $card = New-Rect $X0 (Px 232) $Inner (Px 54)
    Draw-HubCard $G $card
    $snip = $script:Hub.Cache.SnipEnabled -ne $false
    $sub = if ($snip -and -not $script:Hub.Preview -and -not $script:SnipHotkey) { Tx 'Win+Alt+C, Win+Shift+X y Ctrl+Alt+C los usan otras apps: cierra una y vuelve a encender esto.' }
        else { Tx 'Recortador como el de Windows (v\u00eddeo, dibujo, color, texto) con el prompt al lado.' }
    Draw-HubToggleRow $G $Map $Hover 'snip' (New-Rect ($card.X + (Px 6)) ($card.Y + (Px 6)) ($card.Width - (Px 12)) (Px 42)) ((L 'Captura a Claude Code') + ' (' + $(if ($script:SnipHotkeyName) { $script:SnipHotkeyName } else { 'Win+Alt+C' }) + ')') $sub $snip ([scriptblock]::Create("Set-HubSnip `$$(-not $snip)"))

    # Voces de las sesiones: the same switch as Voz, and which voices new sessions get.
    Draw-HubCaption $G 'VOZ' $X0 (Px 304) $Inner ''
    $c = $script:Hub.Cache
    $card = New-Rect $X0 (Px 326) $Inner (Px 104)
    Draw-HubCard $G $card
    if (-not $c.VoiceInstalled) {
        Draw-Wrapped $G (Tx 'La voz no est\u00e1 instalada. Vuelve a ejecutar install.ps1.') $F.Body $P.Warn ($card.X + (Px 16)) ($card.Y + (Px 16)) ($card.Width - (Px 32)) (Px 40)
        return
    }
    Draw-HubToggleRow $G $Map $Hover 'settings-voice-on' (New-Rect ($card.X + (Px 6)) ($card.Y + (Px 6)) ($card.Width - (Px 12)) (Px 42)) 'Voz en todas las sesiones' (Tx 'Si la apagas, ninguna sesi\u00f3n habla') (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)"))
    $gender = if ($c.VoiceEngine) { $c.VoiceEngine.Gender } else { 'mix' }
    $gy = $card.Y + (Px 58)
    $seg = Draw-HubSegmented $G $Map $Hover 'voice-gender' ($card.Right - (Px 14)) $gy $script:HubVoiceGenderLabels $gender 'Set-HubVoiceGender'
    $tw = $seg.X - $card.X - (Px 32)
    Draw-Text $G 'Voces' $F.Body $P.Text ($card.X + (Px 16)) ($gy - (Px 4)) $tw (Px 20)
    Draw-Text $G (Tx 'Para las sesiones nuevas: nombre y voz del mismo g\u00e9nero') $F.Small $P.Muted ($card.X + (Px 16)) ($gy + (Px 16)) $tw (Px 18)
}

function Step-HubLanguage([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $codes = @($script:Hub.Languages.Keys)
    if ($codes.Count -lt 2) { return }
    $code = $codes[([array]::IndexOf($codes, $script:UiLanguage) + $Delta + $codes.Count) % $codes.Count]
    try { Save-UiLanguage $code } catch { Set-HubMessage ((Tx 'No se pudo guardar: ') + $_.Exception.Message) -Failed; return }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubPreview {
    Set-BridgePreview
    $b = $script:Bridge
    $b.Pairing = $null
    $b.Requests.Clear()
    $key = $b.Peers[0].hostKey
    $b.Peers = @($b.Peers) + @([pscustomobject]@{ id = 'dddddddddddd'; name = 'MINI-SALA'; user = 'ana'; port = $BridgeSshPort; address = '192.168.1.52'; hostKey = $key; clientKey = $key })
    $b.Sessions[('e' * 32)] = [pscustomobject]@{ Id = ('e' * 32); PeerId = 'bbbbbbbbbbbb'; PeerName = 'PORTATIL-ANA'; Kind = 'shell'; Command = ''; Pid = 0; Started = (Get-Date) }
    $now = Get-Date
    $c = $script:Hub.Cache
    $c.WhisperRunning = $false
    $c.WhisperSettings = Get-WhisperSettings ([pscustomobject]@{ profile = ('x' * 1240); meeting = "Entrevista para Backend Senior en Acme`nObjetivo: pasar a la ronda final"; keyterms = 'Kubernetes, FastAPI, PostgreSQL' })
    $c.CodeSessions = @(
        [pscustomobject]@{ Slot = 0; Hwnd = 0; Live = $true; Dir = 'D:\proyectos\tienda-web'; At = $now.AddMinutes(-95); Color = 'blue'; Name = 'Isabela'; Role = 'codificadora'; Voice = 'es-CO-SalomeNeural' },
        [pscustomobject]@{ Slot = 1; Hwnd = 0; Live = $true; Dir = 'D:\proyectos\ClaudeMaxxing'; At = $now.AddMinutes(-20); Color = 'orange'; Name = 'Mateo'; Role = 'revisor'; Voice = 'es-MX-JorgeNeural'; Backend = 'freellm' },
        [pscustomobject]@{ Slot = 2; Hwnd = 0; Live = $false; Dir = 'D:\datos\informe'; At = $now.AddHours(-5); Color = 'green'; Name = 'Camila'; Role = 'analista'; Voice = 'es-PE-CamilaNeural' }
    )
    $c.MenuInstalled = $true
    # Three screens: a laptop left of the main one and a monitor to its right; sessions start on the main one.
    $c.Screens = 3
    $c.ScreenAreas = @([pscustomobject]@{ Left = -1920; Top = 0; Right = 0; Bottom = 1080 }, [pscustomobject]@{ Left = 0; Top = 0; Right = 2560; Bottom = 1440 },
        [pscustomobject]@{ Left = 2560; Top = 0; Right = 4480; Bottom = 1080 })
    $c.ScreenFirst = 'windows'
    $c.PerScreen = 2
    $c.Activity = [pscustomobject]@{ Open = 36000; Busy = 22000 }
    $c.ContextMode = [pscustomobject]@{ Installed = $true; Enabled = $true }
    $c.MaxxStatus = $null
    # Skills y MCP: one package installed, one installing, one not.
    $c.MaxxStatus = [pscustomobject]@{ action = 'pack-install'; plugin = 'mcp-server-dev@claude-plugins-official'; state = 'running'; message = ''; at = $now.ToString('o') }
    $c.Packs = @([pscustomobject]@{ Id = 'skill-creator'; Installed = $true }, [pscustomobject]@{ Id = 'mcp-server-dev'; Installed = $false }, [pscustomobject]@{ Id = 'plugin-dev'; Installed = $false })
    $c.Skills = @(
        [pscustomobject]@{ Name = 'ship'; Description = 'Commit y push de los cambios pendientes en commits l\u00f3gicos, sin PR ni merge.'; Source = 'tuyas' },
        [pscustomobject]@{ Name = 'opciones-diseno'; Description = 'Varias direcciones de dise\u00f1o en un artifact para elegir antes de implementar.'; Source = 'tuyas' },
        [pscustomobject]@{ Name = 'informe-semanal'; Description = 'Resume la semana de trabajo a partir de los commits y las notas.'; Source = 'tuyas' },
        [pscustomobject]@{ Name = 'skill-creator'; Description = 'Create new skills, improve existing skills, and measure skill performance.'; Source = 'plugin skill-creator' },
        [pscustomobject]@{ Name = 'context-mode'; Description = 'Keeps big tool outputs out of the context window.'; Source = 'plugin context-mode' },
        [pscustomobject]@{ Name = 'docx'; Description = 'Create, read and edit Word documents.'; Source = 'claude.ai' },
        [pscustomobject]@{ Name = 'pdf'; Description = 'Read, fill and create PDF files.'; Source = 'claude.ai' })
    foreach ($skill in $c.Skills) { $skill.Description = Tx $skill.Description }
    $c.Mcp = @(
        [pscustomobject]@{ Name = 'playwright'; Kind = 'stdio'; Target = 'npx.cmd'; Source = 'tuyos' },
        [pscustomobject]@{ Name = 'github'; Kind = 'http'; Target = 'api.githubcopilot.com'; Source = 'plugin github' },
        [pscustomobject]@{ Name = 'context-mode'; Kind = 'stdio'; Target = 'node.exe'; Source = 'plugin context-mode' })
    # The catalog as shipped, with two skills and one server on (one skill only in the Trabajo environment).
    $c.Catalog = @(Get-CatalogItems (Join-Path $TrayRoot 'catalog'))
    # The keys skillOverrides and deniedMcpServers take: "plugin:skill", "plugin:<plugin>:<server>".
    foreach ($row in @($c.Skills) + @($c.Mcp)) {
        $plugin = if ($row.Source -like 'plugin *') { $row.Source.Substring(7) } else { '' }
        $key = if (-not $plugin) { $row.Name } elseif ($row.PSObject.Properties['Target']) { "plugin:${plugin}:$($row.Name)" } else { "${plugin}:$($row.Name)" }
        $row | Add-Member -NotePropertyName Key -NotePropertyValue $key
    }
    # Trabajo has its own list (two skills and context7); Casa still loads what Siempre does. informe-semanal is off.
    $c.CatalogSettings = @{ skills = @{ 'accessibility' = [string[]]@('*'); 'agent-eval' = [string[]]@('trabajo'); 'ship' = [string[]]@('trabajo') }
        mcp = @{ 'context7' = [string[]]@('*', 'trabajo') }; limited = [string[]]@('trabajo') }
    $c.CatalogTargets = [ordered]@{ '*' = [pscustomobject]@{ Id = '*'; Name = 'Siempre'; Dir = ''; Skills = ''; Scope = 'user' }
        'trabajo' = [pscustomobject]@{ Id = 'trabajo'; Name = 'Trabajo'; Dir = 'D:\Trabajo'; Skills = ''; Scope = 'local' }
        'casa' = [pscustomobject]@{ Id = 'casa'; Name = 'Casa'; Dir = 'D:\Casa'; Skills = ''; Scope = 'local' } }
    $c.CatalogApplied = @{ '*' = [string[]]@('context7') }
    $c.SkillOff = [string[]]@('informe-semanal')
    Update-HubSkillRows
    $c.VoiceEngine = [pscustomobject]@{ Engine = 'elevenlabs'; Gender = 'mix'; ElevenKey = $true; ElevenVoices = 21; GeminiKey = $false; Credits = [pscustomobject]@{ used = 1568; limit = 10000; resetAt = (Get-Date).AddDays(12).ToString('s') } }
    $c.FreeLlm = @{ Installed = $true; Exe = 'FreeLLMAPI.exe'; Port = $FreeLlmDefaultPort; Up = $true; Enabled = $true; HasKey = $true; Installing = $false; Install = $null }
    $c.VoiceInstalled = $true
    $c.Whip = [pscustomobject]@{ Enabled = $true; Threshold = 85; Agents = @('codex', 'agy') }
    $previewAccounts = @{ codex = (New-WhipAccount 'ana@ejemplo.com \u00b7 ChatGPT Plus \u00b7 hasta el 7 dic' 'ok'); agy = (New-WhipAccount 'ana@ejemplo.com \u00b7 el plan solo se ve en agy')
        opencode = (New-WhipAccount 'Sin cuentas: solo modelos gratis (opencode auth login)') }
    $c.WhipAgents = @(Get-WhipAgentStates (Join-Path $env:TEMP 'cmx-no-home') | ForEach-Object { $_.Installed = $_.Id -ne 'copilot'; $_.Account = $previewAccounts[$_.Id]; $_ })
    $c.VoiceMuted = $false
    $c.HotkeysOn = $true
    $c.VoiceSessions = @(
        [pscustomobject]@{ Key = 'a1'; Name = 'Mateo'; Role = 'revisor'; Color = 'orange'; Voice = 'es-MX-JorgeNeural'; Used = $now.AddMinutes(-2); Muted = $false },
        [pscustomobject]@{ Key = 'a2'; Name = 'Isabela'; Role = 'codificadora'; Color = 'blue'; Voice = 'es-CO-SalomeNeural'; Used = $now.AddMinutes(-14); Muted = $false },
        [pscustomobject]@{ Key = 'a3'; Name = 'Camila'; Role = 'analista'; Color = 'green'; Voice = 'es-PE-CamilaNeural'; Used = $now.AddHours(-3); Muted = $true }
    )
    $sample = @(
        (Tx '**Ellos** 15:58:04 Buenos d\u00edas, gracias por venir a la entrevista.'),
        (Tx '**Ellos** 15:58:10 \u00bfCu\u00e1l es tu experiencia con Kubernetes y con Python?'),
        (Tx '### Claude \u00b7 \u00bfCu\u00e1l es tu experiencia con Kubernetes y con Python?'),
        (Tx '**T\u00fa** 16:04:40 Llevo cuatro a\u00f1os con Python.')
    )
    $first = ConvertFrom-WhisperCallLog ($now.ToString('yyyyMMdd') + '-155804') $sample
    $second = ConvertFrom-WhisperCallLog ($now.AddDays(-1).ToString('yyyyMMdd') + '-101500') @(
        '**Ellos** 10:15:02 Let us start with system design.', ('### Claude ' + [char]0x00B7 + ' How would you design a rate limiter?'),
        ('### Claude ' + [char]0x00B7 + (L ' Pantalla')), '**Ellos** 10:52:30 Thanks, that is all.')
    $c.Calls = @($first, $second)
    $c.CallCount = 2
    $c.Auto = Get-HubAutoView
    if ($c.Auto.Plan) { $c.Auto.Settings.enabled = $true }
    # Estadisticas: the last real result on this PC, when there is one (the window is only drawn locally).
    $c.Stats = Read-JsonFile $StatsFile
    $c.ToolStats = @{ Calls = 2; CallMinutes = 45; CallAnswers = 3; Runs = 14; RunsOk = 13; MenuOpens = 90; Paired = 2 }
    $c.ScheduleRows = @(Get-ScheduleRows $script:PendingTasks (Read-JsonFile $CloudFile) (Read-JsonFile $HistoryFile) $now 5)
    # Ambientes: -HubSection envs, envs-busy, envs-error or envs-none (harness\ missing).
    $sampleEnvs = @(
        [pscustomobject]@{ Id = 'atlas'; Name = 'Atlas'; Focus = 'Modulo: Libro 1 y Libro 2, con el Tablero' },
        [pscustomobject]@{ Id = 'endday'; Name = 'EndDay'; Focus = (Tx 'terminar el d\u00eda: se apaga el trabajo') },
        [pscustomobject]@{ Id = 'gaming'; Name = 'Gaming'; Focus = (Tx 'jugar: Steam y nada m\u00e1s') },
        [pscustomobject]@{ Id = 'trabajo'; Name = 'Trabajo'; Focus = 'Cliente: backend Django + frontend React/Vite' },
        [pscustomobject]@{ Id = 'startday'; Name = 'StartDay'; Focus = (Tx 'planear el d\u00eda: agenda, correo, mensajes y Claude') },
        [pscustomobject]@{ Id = 'vacio'; Name = (Tx 'Vac\u00edo'); Focus = (Tx 'nada abierto: la m\u00ednima RAM') }
    )
    $sampleActive = [pscustomobject]@{ id = 'trabajo'; name = 'Trabajo'; since = $now.AddMinutes(-48).ToString('o') }
    $day = $now.ToString('yyyy-MM-dd')
    $sampleHistory = [pscustomobject]@{ last = 'trabajo'
        edges = [pscustomobject]@{ 'startday>trabajo' = 9; 'trabajo>atlas' = 4; 'atlas>trabajo' = 3; 'trabajo>endday' = 6; 'endday>gaming' = 2; 'gaming>vacio' = 1; 'vacio>startday' = 1; 'endday>startday' = 5 }
        time = [pscustomobject]@{ $day = [pscustomobject]@{ startday = 1500; atlas = 2400 }; '2026-11-01' = [pscustomobject]@{ trabajo = 61200; atlas = 9000; endday = 3600; gaming = 7200; startday = 5400 } } }
    $sampleFocus = [pscustomobject]@{ at = $now.AddMinutes(-2).ToString('o'); active = 'trabajo'
        tabs = @([pscustomobject]@{ id = 11; title = 'I Survived 7 Days In Abandoned City'; profile = 'work'; reason = (Tx 'sin relaci\u00f3n con Trabajo') },
            [pscustomobject]@{ id = 12; title = 'Recibidos (1321) - Gmail'; profile = 'personal'; reason = 'perfil Personal: personal, fuera de Trabajo' },
            [pscustomobject]@{ id = 13; title = 'Tablero del Modulo'; profile = 'personal'; reason = 'perfil Personal: personal, fuera de Trabajo' })
        apps = @([pscustomobject]@{ name = 'steam'; pids = @(40); reason = 'juegos' })
        servers = @([pscustomobject]@{ port = 5173; pid = 500; name = 'node'; label = 'Frontend Vite' }, [pscustomobject]@{ port = 8765; pid = 612; name = 'python'; label = $null }) }
    $c.SelfHarness = Get-SelfHarnessSettings $null
    $sampleDetect = [pscustomobject]@{ at = $now.AddMinutes(-2).ToString('o'); active = 'trabajo'; suggestion = 'atlas'; name = 'Atlas'; confidence = 0.86; judge = 'jev'; reason = 'probabilidades: atlas 86 %, trabajo 9 %, startday 3 %'; offer = $true }
    $c.Harness = switch ($script:Hub.EnvsPreview) {
        'none'  { @{ Dir = $null; Envs = @(); Active = $null; Job = $null } }
        # A new install: harness\ is there, no environment yet.
        'empty' { @{ Dir = 'D:\ClaudeMaxxing\harness'; DataDir = $HarnessHome; Envs = @(); Active = $null; Job = $null } }
        'busy'  { @{ Dir = 'D:\ClaudeMaxxing\harness'; Envs = $sampleEnvs; Active = $sampleActive; History = $sampleHistory; Detect = $sampleDetect
                     Job = [pscustomobject]@{ id = 'atlas'; name = 'Atlas'; action = 'on'; state = 'running'; step = 'Parando 5 contenedores de Cliente'; message = '' } } }
        'error' { @{ Dir = 'D:\ClaudeMaxxing\harness'; Envs = $sampleEnvs; Active = $null; History = $sampleHistory; Detect = $null
                     Job = [pscustomobject]@{ id = 'trabajo'; name = 'Trabajo'; action = 'on'; state = 'error'; step = ''; message = (Tx 'Docker Desktop no respondi\u00f3 en 2 minutos'); endedAt = $now.AddMinutes(-3).ToString('o') } } }
        default { @{ Dir = 'D:\ClaudeMaxxing\harness'; Envs = $sampleEnvs; Active = $sampleActive; History = $sampleHistory; Detect = $sampleDetect; Focus = $sampleFocus
                     Job = [pscustomobject]@{ id = 'trabajo'; name = 'Trabajo'; action = 'on'; state = 'done'; step = ''; message = ''; endedAt = $now.AddMinutes(-48).ToString('o') } } }
    }
    # Planear sesion: -HubSection plan, plan-running, plan-error or plan-empty.
    $state = $script:Hub.PlanPreview
    $c.JudgeTrials = @(if ($state -ne 'empty') { @(
        [pscustomobject]@{ Title = (Tx 'Grabar un curso de Claude Code en espa\u00f1ol y venderlo en Hotmart'); At = $now.AddHours(-2); Tally = [pscustomobject]@{ verdict = 'GUILTY'; guilty = 4; not_guilty = 2 } },
        [pscustomobject]@{ Title = 'Migrar la tienda web a Next.js antes del viernes'; At = $now.AddDays(-1).AddHours(-3); Tally = [pscustomobject]@{ verdict = 'NOT GUILTY'; guilty = 5; not_guilty = 7 } },
        [pscustomobject]@{ Title = (Tx 'Dedicar la ma\u00f1ana a ClaudeMaxxing y la tarde a clientes'); At = $now.AddDays(-3); Tally = [pscustomobject]@{ verdict = 'HUNG JURY'; guilty = 3; not_guilty = 3 } }
    ) })
    $c.JudgeStatus = switch ($state) {
        'running' { [pscustomobject]@{ state = 'running'; jury = 6; at = $now.AddMinutes(-3).ToString('o') } }
        # Any existing file stands in for the log, so the preview shows the "Ver registro" button.
        'error'   { [pscustomobject]@{ state = 'error'; log = (Join-Path $TrayRoot 'tray.ps1'); message = 'Claude no tuvo permiso para Write .court\20261020-122700\case.md (y 3 m' + [char]0x00E1 + 's).' } }
        default   { $null }
    }
    $c.JudgeProgress = 'Jurado: 4 de 6 votos'
    # Empresa: -HubSection business, or home-business for Inicio in that edition.
    if ($script:Hub.Section -eq 'business' -or $script:BusinessPreview) { Set-BusinessPreview }
}
