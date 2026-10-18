# ClaudeMaxxing window: every tool in one place, opened from the popup's "Entrar a ClaudeMaxxing" button.
# Sections: Inicio (overview, with the diagram of nearby PCs and the latest calls), Uso y agenda, Claude Code
# (sessions opened from the Explorer menu), Otros PCs (diagram of nearby PCs and their connection), Claude
# Whisper (settings and call history) and Voz. The longer flows keep their own windows: the schedule dialog,
# pairing in Otros PCs (pairing is only accepted while that window is open) and the Whisper context dialog.
# Owner-drawn like the rest of the tray; Paint only reads $script:Hub.Cache, which a timer refreshes.
# Needs theme.ps1, usage.ps1, schedule.ps1, sessions.ps1, bridgeui.ps1, whisper.ps1 and whisperui.ps1.
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

$script:HubDialog = $null
$script:Hub = $null
$HubWidth = 840
$HubHeight = 640
$HubNavWidth = 200
# The voice keeps its state here (voice\hooks\common.ps1 calls it $StateDir; that file is not loaded in the tray).
$VoiceStateDir = Join-Path $env:TEMP 'claude-voice'
$script:WhisperCallCache = @{}

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

$script:HubSections = @(
    @{ Id = 'home'; Label = 'Inicio'; Glyph = '\ue80f' },
    @{ Id = 'usage'; Label = 'Uso y agenda'; Glyph = '\ue787' },
    @{ Id = 'stats'; Label = (Tx 'Estad\u00edsticas'); Glyph = '\ue9d2' },
    @{ Id = 'code'; Label = 'Claude Code'; Glyph = '\ue943' },
    @{ Id = 'pcs'; Label = 'Otros PCs'; Glyph = '\ue968' },
    @{ Id = 'whisper'; Label = 'Claude Whisper'; Glyph = '\ue720' },
    @{ Id = 'voice'; Label = 'Voz'; Glyph = '\ue767' }
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
        $voice = Read-JsonFile (Join-Path $VoiceStateDir ('name-' + (Get-HubSessionKey $r.sessionId)))
        [pscustomobject]@{
            Slot = [int]$r.slot; Hwnd = $hwnd; Live = ($hwnd -ne 0 -and [ClaudeTray.Native]::IsWindow([IntPtr]$hwnd))
            Dir = [string]$r.dir; At = $at; Color = [string]$r.color; Name = [string]$r.name
            Role = $(if ($voice) { [string]$voice.role } else { '' }); Voice = $(if ($voice) { [string]$voice.voice } else { '' })
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

# How old the usage data is, in Spanish (the popup's Format-Age is in English).
function Format-HubAge($AgeMinutes) {
    if ($null -eq $AgeMinutes) { return 'Sin datos' }
    $minutes = [int][Math]::Floor($AgeMinutes)
    if ($minutes -lt 1) { return 'Actualizado ahora' }
    if ($minutes -lt 60) { return "Actualizado hace $minutes min" }
    'Actualizado hace {0} h' -f [int][Math]::Floor($minutes / 60)
}

# "es-CO-SalomeNeural" -> "Salome (es-CO)".
function Format-VoiceName([string]$Voice) {
    if ($Voice -match '^([a-z]{2,3}-[A-Z]{2})-([A-Za-z]+?)Neural$') { return '{0} ({1})' -f $Matches[2], $Matches[1] }
    $Voice
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
    if ($Full -or ($now - $hub.SlowAt).TotalSeconds -ge 10) {
        $hub.SlowAt = $now
        $c.Calls = Get-WhisperCalls 5
        $c.VoiceSessions = Get-HubVoiceSessions
        $c.MenuInstalled = [bool](Get-ItemProperty -LiteralPath $MenuKey -Name Launcher -ErrorAction SilentlyContinue)
        $c.Screens = [System.Windows.Forms.Screen]::AllScreens.Count
        $c.VoiceInstalled = Test-Path -LiteralPath (Join-Path $TrayRoot 'voice\hooks\speak.ps1')
    }
}

# ---------------------------------------------------------------- actions

function Set-HubSection([string]$Id) {
    $script:Hub.Section = $Id
    if ($Id -eq 'stats') { Update-HubStats }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubMessage([string]$Text) {
    $script:Hub.Message = $Text
    $script:Hub.MessageAt = Get-Date
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Update-HubNow {
    try { Update-HubCache } catch { }
    try { Complete-HubStatsScan } catch { }
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
    $picker.Description = Tx 'Carpeta donde abrir Claude Code (en la siguiente mitad de pantalla libre)'
    if ($picker.ShowDialog($script:HubDialog) -ne 'OK' -or -not $picker.SelectedPath) { return }
    # A trailing backslash ("C:\") would escape the closing quote.
    $dir = $picker.SelectedPath
    if ($dir.EndsWith('\')) { $dir += '.' }
    $launch = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Dir "{1}"' -f (Join-Path $TrayRoot 'open-session.ps1'), $dir
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $launch -WorkingDirectory $TrayRoot
    Set-HubMessage ('Abriendo Claude Code en ' + (Split-Path -Leaf $picker.SelectedPath) + '...')
}

function Show-HubCodeWindow([int]$Index) {
    $session = @($script:Hub.Cache.CodeSessions)[$Index]
    if (-not $session -or -not $session.Live) { return }
    $hwnd = [IntPtr]$session.Hwnd
    if ([ClaudeTray.Native]::IsIconic($hwnd)) { [void][ClaudeTray.Native]::ShowWindow($hwnd, 9) }
    [void][ClaudeTray.Native]::SetForegroundWindow($hwnd)
}

function Stop-HubPeerSessions([string]$PeerId) {
    foreach ($session in @($script:Bridge.Sessions.Values | Where-Object { $_.PeerId -eq $PeerId })) { Stop-BridgeSession $session.Id }
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
    try { Write-JsonFile $WhisperSettingsFile $settings } catch { Set-HubMessage ('No se pudo guardar: ' + $_.Exception.Message); return }
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
    try { Write-JsonFile $WhisperSettingsFile $updated; Set-HubMessage (Tx '\u2713 Contexto guardado') } catch { Set-HubMessage ('No se pudo guardar: ' + $_.Exception.Message) }
    Update-HubNow
}

function Open-HubWhisper {
    if ($script:Hub.Preview) { return }
    Start-WhisperWindow $TrayRoot
    Set-HubMessage 'Abriendo Claude Whisper...'
}

function Open-HubCall([int]$Index) {
    $call = @($script:Hub.Cache.Calls)[$Index]
    if ($call -and (Test-Path -LiteralPath $call.Path)) { Start-Process -FilePath $call.Path }
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
        if (-not (Test-Path -LiteralPath $VoiceStateDir)) { New-Item -ItemType Directory -Force -Path $VoiceStateDir | Out-Null }
        [IO.File]::WriteAllText($file, '')
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
    else { [IO.File]::WriteAllText($file, '') }
    $session.Muted = -not $session.Muted
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-HubHotkeys([bool]$On) {
    if ($On) { Invoke-VoiceCtl 'hotkeys on' 'Activando los atajos de voz...' } else { Invoke-VoiceCtl 'hotkeys off' 'Atajos de voz desactivados.' }
}

# ---------------------------------------------------------------- window

function Show-HubDialog([string]$Section = 'home', [string]$RenderPath) {
    # "stats-hours", "stats-models-all"...: a tab (and the all-time range) of Estadisticas.
    $statsTab = 'summary'; $statsRange = 'recent'
    if ($Section -match '^stats-([a-z]+?)(?:-(all))?$') { $statsTab = $Matches[1]; if ($Matches[2]) { $statsRange = 'all' }; $Section = 'stats' }
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
    $dlg.KeyPreview = $true
    $dlg.ClientSize = New-Object System.Drawing.Size((Px $HubWidth), (Px $HubHeight))
    if ($script:Notify -and $script:Notify.Icon) { $dlg.Icon = $script:Notify.Icon }
    Enable-DoubleBuffer $dlg
    $dlg.Tag = New-HitMap
    Register-HitMap $dlg
    $script:HubDialog = $dlg
    $script:Hub = @{ Section = $(if ($Section) { $Section } else { 'home' }); Logo = (New-TintedLogo $P.Accent (Px 22)); Cache = @{}
        SlowAt = [datetime]::MinValue; Message = ''; MessageAt = [datetime]::MinValue; Preview = [bool]$RenderPath; Timer = $null; Error = ''
        StatsTab = $statsTab; StatsRange = $statsRange; StatsError = '' }
    # A damaged data file must not take the click handler (and the tray) down: the section just shows less.
    if ($RenderPath) { Set-HubPreview } else { try { Update-HubCache -Full; if ($script:Hub.Section -eq 'stats') { Update-HubStats } } catch { } }

    $dlg.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.Close() } })
    # Drag the window by the header or the brand area.
    $dlg.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Y -gt (Px 56)) { return }
        if (Find-Hit $sender.Tag $e.Location) { return }
        [void][ClaudeTray.Native]::ReleaseCapture()
        [void][ClaudeTray.Native]::SendMessage($sender.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    })
    $dlg.Add_HandleCreated({ param($sender, $e) Set-RoundedWindow $sender $script:Palette.Border })
    $dlg.Add_Paint({
        param($sender, $e)
        try { Draw-Hub $sender $e.Graphics }
        catch {
            $script:Hub.Error = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            if ($script:Hub.Preview) { [Console]::Error.WriteLine('hub paint: ' + $script:Hub.Error + "`n" + $_.ScriptStackTrace) }
        }
    })
    $dlg.Add_FormClosed({
        if ($script:Hub.Timer) { $script:Hub.Timer.Stop(); $script:Hub.Timer.Dispose() }
        if ($script:Hub.Logo) { $script:Hub.Logo.Dispose() }
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

function Draw-HubDot($G, [int]$X, [int]$Y, [int]$Size, [System.Drawing.Color]$Color) {
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $G.FillEllipse($brush, $X, $Y, $Size, $Size)
    $brush.Dispose()
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
    Draw-Text $G $(if ($active) { "$($Window.Percent)%" } else { '0%' }) $F.Number $(if ($active) { $P.Text } else { $P.Faint }) $X ($Y - (Px 4)) $W (Px 26) 'Right'
    $track = New-Rect $X ($Y + (Px 26)) $W (Px 6)
    Fill-Round $G $track (Px 3) $P.Track
    if ($active -and $Window.Percent -gt 0) {
        Fill-Round $G (New-Rect $X $track.Y ([Math]::Max((Px 6), [int]($W * [Math]::Min(100, $Window.Percent) / 100))) $track.Height) (Px 3) $P[(Get-UsageLevel $Window.Percent)]
    }
    $now = Get-Date
    if (-not $active) { $reset = 'Sin empezar' }
    elseif ($Short) { $reset = 'Se renueva en ' + (Format-Remaining ($Window.ResetsAt - $now)) }
    else { $reset = 'Se renueva ' + (Format-DialogDateTime $Window.ResetsAt $now) + ' (en ' + (Format-Remaining ($Window.ResetsAt - $now)) + ')' }
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
            $sub = (Get-SessionLabel $sessions[0]) + ' abierta'
            if ($sessions.Count -gt 1) { $sub = "$($sessions.Count) sesiones abiertas" }
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
        if ($b -and $b.Ready -and $status.Color -eq $P.Ok -and $b.Networks.Count) { $statusText = 'Red ' + ($b.Networks | Select-Object -First 1).Name }
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
        if ($nodes[$i].Sessions.Count -gt 1) { $label = "$($nodes[$i].Sessions.Count) sesiones" }
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
    $w = $Form.ClientSize.Width
    $h = $Form.ClientSize.Height
    $navW = Px $HubNavWidth

    # side menu
    $navBrush = New-Object System.Drawing.SolidBrush($P.Surface)
    $G.FillRectangle($navBrush, 0, 0, $navW, $h)
    $navBrush.Dispose()
    if ($hub.Logo) { $G.DrawImage($hub.Logo, (Px 18), (Px 19)) }
    Draw-Text $G $AppName $HF.Brand $P.Text (Px 48) (Px 14) ($navW - (Px 52)) (Px 32)
    $y = Px 70
    foreach ($section in $script:HubSections) {
        $item = New-Rect (Px 10) $y ($navW - (Px 20)) (Px 36)
        $active = $hub.Section -eq $section.Id
        $hitId = "nav-$($section.Id)"
        if ($active) { Fill-Round $G $item (Px 8) $P.AccentTint } elseif ($hover -eq $hitId) { Fill-Round $G $item (Px 8) $P.SurfaceHover }
        Draw-Text $G (Tx $section.Glyph) $HF.Icon $(if ($active) { $P.Accent } else { $P.Muted }) ($item.X + (Px 8)) $item.Y (Px 24) $item.Height 'Center'
        Draw-Text $G $section.Label $(if ($active) { $HF.NavStrong } else { $HF.Nav }) $(if ($active) { $P.Accent } else { $P.Text }) ($item.X + (Px 40)) $item.Y ($item.Width - (Px 76)) $item.Height
        $badge = Get-HubNavBadge $section.Id
        if ($badge -and $badge.Dot) { Draw-HubDot $G ($item.Right - (Px 20)) ($item.Y + (Px 14)) (Px 8) $badge.Dot }
        elseif ($badge) { Draw-Text $G $badge.Text $F.Small $badge.Color ($item.Right - (Px 50)) $item.Y (Px 40) $item.Height 'Right' }
        if (-not $active) { Add-Hit $map $hitId $item ([scriptblock]::Create("Set-HubSection '$($section.Id)'")) }
        $y += Px 40
    }
    $plan = if ($script:Plan) { "Plan $($script:Plan)  " + (Tx '\u00b7') + '  ' } else { '' }
    Draw-Text $G ($plan + "v$AppVersion") $F.Small $P.Faint (Px 22) ($h - (Px 36)) ($navW - (Px 30)) (Px 20)
    $pen = New-Object System.Drawing.Pen($P.Border)
    $G.DrawLine($pen, $navW, 0, $navW, $h)

    # header
    $x0 = $navW + (Px 24)
    $inner = $w - $x0 - (Px 24)
    $title = (@($script:HubSections | Where-Object { $_.Id -eq $hub.Section })[0]).Label
    if ($hub.Section -eq 'home') { $title = 'Todo ClaudeMaxxing' }
    Draw-Text $G $title $F.Title $P.Text $x0 (Px 14) (Px 320) (Px 32)
    $close = New-Rect ($w - (Px 52)) (Px 16) (Px 30) (Px 30)
    if ($hover -eq 'close') { Fill-Round $G $close (Px 6) $P.SurfaceHover }
    Draw-Text $G (Tx '\u00d7') $F.Close $P.Muted $close.X $close.Y $close.Width $close.Height 'Center'
    Add-Hit $map 'close' $close { $script:HubDialog.Close() }
    if ($hub.Message -and ((Get-Date) - $hub.MessageAt).TotalSeconds -lt 8) {
        Draw-Text $G $hub.Message $F.Small $P.Accent ($x0 + (Px 220)) (Px 20) ($close.X - $x0 - (Px 230)) (Px 20) 'Right'
    }
    $G.DrawLine($pen, $x0, (Px 56), $x0 + $inner, (Px 56))
    $pen.Dispose()

    switch ($hub.Section) {
        'usage'   { Draw-HubUsageSection $G $map $hover $x0 $inner }
        'stats'   { Draw-HubStatsSection $G $map $hover $x0 $inner }
        'code'    { Draw-HubCodeSection $G $map $hover $x0 $inner }
        'pcs'     { Draw-HubPcsSection $G $map $hover $x0 $inner }
        'whisper' { Draw-HubWhisperSection $G $map $hover $x0 $inner }
        'voice'   { Draw-HubVoiceSection $G $map $hover $x0 $inner }
        default   { Draw-HubHome $G $map $hover $x0 $inner }
    }

    $border = New-Object System.Drawing.Pen($P.Border)
    $G.DrawRectangle($border, 0, 0, $w - 1, $h - 1)
    $border.Dispose()
}

# ---------------------------------------------------------------- Inicio

function Draw-HubHome($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $view = $script:View
    $gap = Px 12

    # usage and the next scheduled session
    $cw = [int](($Inner - 2 * $gap) / 3)
    $y = Px 72
    $hasData = $view -and $view.HasData
    foreach ($i in 0, 1) {
        $card = New-Rect ($X0 + $i * ($cw + $gap)) $y $cw (Px 84)
        $hitId = "home-usage-$i"
        Fill-Round $G $card (Px 10) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
        $window = if (-not $hasData) { $null } elseif ($i -eq 0) { $view.Session } else { $view.Weekly }
        Draw-HubUsage $G $(if ($i -eq 0) { (Tx 'SESI\u00d3N (5 H)') } else { 'SEMANAL' }) $window ($card.X + (Px 14)) ($card.Y + (Px 14)) ($card.Width - (Px 28)) -Short
        Add-Hit $Map $hitId $card { Set-HubSection 'usage' }
    }
    $card = New-Rect ($X0 + 2 * ($cw + $gap)) $y ($Inner - 2 * ($cw + $gap)) (Px 84)
    Draw-HubCard $G $card
    Draw-Text $G (Tx 'PR\u00d3XIMA SESI\u00d3N') $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 14)) ($card.Width - (Px 28)) (Px 18)
    $next = Get-HubNextRow
    if ($next) {
        Draw-Text $G (Format-DialogDateTime $next.At (Get-Date)) $F.BodyStrong $P.Text ($card.X + (Px 14)) ($card.Y + (Px 32)) ($card.Width - (Px 28)) (Px 20)
        Draw-Text $G $(if ($next.Kind -eq 'pc') { 'En este PC' } else { 'En la nube' }) $F.Small $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 52)) (Px 90) (Px 18)
    } else {
        Draw-Text $G 'Nada agendado' $F.BodyStrong $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 32)) ($card.Width - (Px 28)) (Px 20)
    }
    $bw = Get-PillWidth 'Agendar'
    Draw-PillButton $G $Map $Hover 'home-schedule' (New-Rect ($card.Right - (Px 12) - $bw) ($card.Y + (Px 50)) $bw (Px 24)) 'Agendar' { Open-HubSchedule } -Accent

    # nearby PCs and Claude Whisper
    $y = Px 168
    $netW = [int]($Inner * 0.6)
    $net = New-Rect $X0 $y $netW (Px 262)
    Draw-HubCard $G $net
    Draw-HubNetwork $G $Map $Hover $net $false 'section'

    $wcard = New-Rect ($X0 + $netW + $gap) $y ($Inner - $netW - $gap) (Px 262)
    Draw-HubCard $G $wcard
    $wx = $wcard.X + (Px 14)
    $ww = $wcard.Width - (Px 28)
    Draw-Text $G 'CLAUDE WHISPER' $F.Caps $P.Muted $wx ($wcard.Y + (Px 10)) $ww (Px 18)
    $running = [bool]$c.WhisperRunning
    Draw-HubDot $G $wx ($wcard.Y + (Px 37)) (Px 8) $(if ($running) { $P.Ok } else { $P.Faint })
    Draw-Text $G $(if ($running) { 'Abierto' } else { 'Cerrado' }) $F.BodyStrong $P.Text ($wx + (Px 14)) ($wcard.Y + (Px 30)) (Px 90) (Px 22)
    $label = if ($running) { 'Mostrar' } else { 'Abrir' }
    $bw = Get-PillWidth $label
    Draw-PillButton $G $Map $Hover 'home-whisper' (New-Rect ($wcard.Right - (Px 12) - $bw) ($wcard.Y + (Px 29)) $bw (Px 24)) $label { Open-HubWhisper } -Accent
    $settings = $c.WhisperSettings
    if ($settings) {
        $model = $script:WhisperModels[$settings.model] -replace ' \(.*\)$', ''
        Draw-Text $G ($script:WhisperLanguages[$settings.language] + '  ' + (Tx '\u00b7') + '  ' + $model) $F.Small $P.Muted $wx ($wcard.Y + (Px 54)) $ww (Px 18)
    }
    Draw-Text $G (Tx '\u00daLTIMAS LLAMADAS') $F.Caps $P.Muted $wx ($wcard.Y + (Px 82)) $ww (Px 18)
    $calls = @($c.Calls)
    $cy = $wcard.Y + (Px 102)
    if (-not $calls.Count) {
        Draw-Wrapped $G (Tx 'A\u00fan no hay llamadas. \u00c1brelo en una llamada y pulsa Escuchar.') $F.Small $P.Faint $wx $cy $ww (Px 36)
    }
    for ($i = 0; $i -lt [Math]::Min(3, $calls.Count); $i++) {
        $call = $calls[$i]
        $row = New-Rect ($wx - (Px 6)) $cy ($ww + (Px 12)) (Px 40)
        $hitId = "home-call-$i"
        if ($Hover -eq $hitId) { Fill-Round $G $row (Px 6) $P.SurfaceHover }
        $when = if ($call.Started) { Format-DialogDateTime $call.Started (Get-Date) } else { $call.Name }
        Draw-Text $G $when $F.Body $P.Text $wx ($cy + (Px 2)) $ww (Px 18)
        $answers = if ($call.Answers -eq 1) { '1 respuesta' } else { "$($call.Answers) respuestas" }
        Draw-Text $G ((Format-CallDuration $call.Minutes) + '  ' + (Tx '\u00b7') + '  ' + $answers) $F.Small $P.Muted $wx ($cy + (Px 20)) $ww (Px 16)
        Add-Hit $Map $hitId $row ([scriptblock]::Create("Open-HubCall $i"))
        $cy += Px 44
    }
    $more = New-Rect ($wcard.Right - (Px 110)) ($wcard.Bottom - (Px 28)) (Px 96) (Px 20)
    Draw-Text $G (Tx 'Ver todo \u203a') $F.Small $(if ($Hover -eq 'home-whisper-more') { $P.AccentHover } else { $P.Accent }) $more.X $more.Y $more.Width $more.Height 'Right'
    Add-Hit $Map 'home-whisper-more' $more { Set-HubSection 'whisper' }

    # Claude Code sessions and the voice
    $y = Px 442
    $half = [int](($Inner - $gap) / 2)
    $ccard = New-Rect $X0 $y $half (Px 178)
    Draw-HubCard $G $ccard
    $cx = $ccard.X + (Px 14)
    $cww = $ccard.Width - (Px 28)
    $sessions = @($c.CodeSessions | Where-Object { $_.Live })
    $slots = 2 * [Math]::Max(1, [int]$c.Screens)
    Draw-Text $G 'CLAUDE CODE' $F.Caps $P.Muted $cx ($ccard.Y + (Px 10)) $cww (Px 18)
    Draw-Text $G "$($sessions.Count) de $slots abiertas" $F.Small $P.Muted $cx ($ccard.Y + (Px 10)) $cww (Px 18) 'Right'
    $sy = $ccard.Y + (Px 34)
    if (-not $sessions.Count) {
        Draw-Wrapped $G (Tx 'Ninguna sesi\u00f3n abierta. Clic derecho en una carpeta > Abrir con Claude Code.') $F.Small $P.Faint $cx $sy $cww (Px 36)
    }
    foreach ($session in @($sessions | Select-Object -First 3)) {
        Draw-HubDot $G $cx ($sy + (Px 6)) (Px 10) (ConvertFrom-Hex (Get-HubSlotHex $session.Color))
        $name = $session.Name
        if ($session.Role) { $name += ' ' + (Tx '\u00b7') + ' ' + $session.Role }
        Draw-Text $G $name $F.Body $P.Text ($cx + (Px 18)) $sy ($cww - (Px 18)) (Px 22)
        Draw-Text $G (Split-Path -Leaf $session.Dir) $F.Small $P.Muted ($cx + (Px 18)) $sy ($cww - (Px 18)) (Px 22) 'Right'
        $sy += Px 26
    }
    $bw = Get-PillWidth (Tx 'Nueva sesi\u00f3n...')
    Draw-PillButton $G $Map $Hover 'home-code-new' (New-Rect ($ccard.Right - (Px 12) - $bw) ($ccard.Bottom - (Px 36)) $bw (Px 24)) (Tx 'Nueva sesi\u00f3n...') { Open-HubCodeSession } -Accent
    $link = New-Rect $cx ($ccard.Bottom - (Px 34)) (Px 120) (Px 20)
    Draw-Text $G (Tx 'Ver sesiones \u203a') $F.Small $(if ($Hover -eq 'home-code-more') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height
    Add-Hit $Map 'home-code-more' $link { Set-HubSection 'code' }

    $vcard = New-Rect ($X0 + $half + $gap) $y ($Inner - $half - $gap) (Px 178)
    Draw-HubCard $G $vcard
    $vx = $vcard.X + (Px 4)
    $vw = $vcard.Width - (Px 8)
    Draw-Text $G 'VOZ' $F.Caps $P.Muted ($vcard.X + (Px 14)) ($vcard.Y + (Px 10)) (Px 100) (Px 18)
    if (-not $c.VoiceInstalled) {
        Draw-Wrapped $G (Tx 'La voz no est\u00e1 instalada. Vuelve a ejecutar install.ps1.') $F.Small $P.Warn ($vcard.X + (Px 14)) ($vcard.Y + (Px 36)) ($vcard.Width - (Px 28)) (Px 36)
    } else {
        Draw-HubToggleRow $G $Map $Hover 'home-voice-on' (New-Rect $vx ($vcard.Y + (Px 32)) $vw (Px 40)) 'Voz en las sesiones' 'Lee el resumen de cada respuesta' (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)"))
        Draw-HubToggleRow $G $Map $Hover 'home-voice-keys' (New-Rect $vx ($vcard.Y + (Px 76)) $vw (Px 40)) 'Atajos de teclado' 'Ctrl+Alt+Shift+O repite, P detiene' ([bool]$c.HotkeysOn) ([scriptblock]::Create("Set-HubHotkeys `$$(-not $c.HotkeysOn)"))
        $bw = Get-PillWidth 'Probar voz'
        Draw-PillButton $G $Map $Hover 'home-voice-test' (New-Rect ($vcard.Right - (Px 12) - $bw) ($vcard.Bottom - (Px 36)) $bw (Px 24)) 'Probar voz' { Invoke-VoiceCtl 'test' 'Reproduciendo una frase de prueba...' }
        $link = New-Rect ($vcard.X + (Px 14)) ($vcard.Bottom - (Px 34)) (Px 120) (Px 20)
        Draw-Text $G (Tx 'Ver voces \u203a') $F.Small $(if ($Hover -eq 'home-voice-more') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height
        Add-Hit $Map 'home-voice-more' $link { Set-HubSection 'voice' }
    }
}

# ---------------------------------------------------------------- Uso y agenda

function Draw-HubUsageSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $view = $script:View
    $now = Get-Date

    # header line: data age and refresh
    if ($script:Refresh) { $age = 'Actualizando...'; $ageColor = $P.Muted }
    elseif ($script:RefreshError -and ($now - $script:RefreshErrorAt).TotalSeconds -lt 30) { $age = $script:RefreshError; $ageColor = $P.Error }
    else { $age = if ($view) { Format-HubAge $view.AgeMinutes } else { 'Sin datos' }; $ageColor = $P.Muted }
    $bw = Get-PillWidth 'Actualizar'
    $refresh = New-Rect ($X0 + $Inner - $bw) (Px 70) $bw (Px 24)
    Draw-PillButton $G $Map $Hover 'usage-refresh' $refresh 'Actualizar' { Start-UsageRefresh; Set-HubMessage 'Actualizando el uso...' }
    Draw-Text $G $age $F.Small $ageColor $X0 (Px 70) ($refresh.X - $X0 - (Px 10)) (Px 24) 'Right'
    Draw-Text $G (Tx 'L\u00cdMITES DEL PLAN') $F.Caps $P.Muted $X0 (Px 74) (Px 200) (Px 18)

    $y = Px 102
    $card = New-Rect $X0 $y $Inner (Px 152)
    Draw-HubCard $G $card
    if (-not $view -or -not $view.HasData) {
        Draw-Text $G (Tx 'Sin datos de uso todav\u00eda') $F.BodyStrong $P.Text ($card.X + (Px 18)) ($card.Y + (Px 20)) ($card.Width - (Px 36)) (Px 22)
        Draw-Text $G 'Manda un mensaje en Claude Code o pulsa Actualizar.' $F.Small $P.Muted ($card.X + (Px 18)) ($card.Y + (Px 44)) ($card.Width - (Px 36)) (Px 20)
    } else {
        Draw-HubUsage $G (Tx 'SESI\u00d3N (5 H)') $view.Session ($card.X + (Px 18)) ($card.Y + (Px 18)) ($card.Width - (Px 36))
        Draw-HubUsage $G 'SEMANAL' $view.Weekly ($card.X + (Px 18)) ($card.Y + (Px 88)) ($card.Width - (Px 36))
    }
    $y = $card.Bottom + (Px 12)

    # extra usage and a limit reset offer
    $extra = $script:Extras.ExtraUsage
    $reset = $script:Extras.LimitReset
    if ($extra -or $reset) {
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 10) $(if ($reset) { $P.AccentTint } else { $P.Surface })
        if ($reset) {
            Draw-Text $G $reset.Title $F.BodyStrong $P.Text ($row.X + (Px 14)) ($row.Y + (Px 3)) ($row.Width - (Px 120)) (Px 20)
            Draw-Text $G $reset.Detail $F.Small $P.Muted ($row.X + (Px 14)) ($row.Y + (Px 22)) ($row.Width - (Px 120)) (Px 18)
            $bw = Get-PillWidth 'Usar'
            Draw-PillButton $G $Map $Hover 'usage-reset' (New-Rect ($row.Right - (Px 12) - $bw) ($row.Y + (Px 10)) $bw (Px 24)) 'Usar' { Start-Process 'https://claude.ai/settings/usage' } -Accent
        } else {
            $pct = if ($null -ne $extra.Percent) { "$($extra.Percent)%" } else { 'activado' }
            Draw-Text $G ('Uso extra: ' + $pct) $F.BodyStrong $P.Text ($row.X + (Px 14)) $row.Y (Px 220) $row.Height
            if ($extra.AmountText) { Draw-Text $G $extra.AmountText $F.Body $P.Text ($row.X + (Px 14)) $row.Y ($row.Width - (Px 28)) $row.Height 'Right' }
        }
        $y += Px 56
    }

    # scheduled sessions
    Draw-HubCaption $G 'AGENDADAS' $X0 $y $Inner (Tx 'Abren la ventana de 5 h antes de que la necesites')
    $y += Px 22
    $rows = @($c.ScheduleRows)
    if (-not $rows.Count) {
        $row = New-Rect $X0 $y $Inner (Px 34)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Nada agendado todav\u00eda.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 34)
        $y += Px 38
    }
    $maxRows = [Math]::Max(1, [int](((Px 572) - $y) / (Px 38)))
    foreach ($item in @($rows | Select-Object -First $maxRows)) {
        $row = New-Rect $X0 $y $Inner (Px 34)
        Fill-Round $G $row (Px 8) $P.Surface
        $upcoming = $item.State -in 'pending', 'requested', 'creating', 'cloud-ok', 'cloud-failed'
        $pill = New-Rect ($row.X + (Px 10)) ($row.Y + (Px 9)) (Px 42) (Px 16)
        Fill-Round $G $pill (Px 8) $(if ($upcoming) { $P.AccentTint } else { $P.Track })
        Draw-Text $G $(if ($item.Kind -eq 'pc') { 'PC' } else { 'NUBE' }) $F.Badge $(if ($upcoming) { $P.Accent } else { $P.Muted }) $pill.X $pill.Y $pill.Width $pill.Height 'Center'
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

function Draw-HubCodeSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    $screens = [Math]::Max(1, [int]$c.Screens)
    $slots = 2 * $screens

    $card = New-Rect $X0 (Px 72) $Inner (Px 84)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $bw = Get-PillWidth (Tx 'Nueva sesi\u00f3n...')
    $new = New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 14)) $bw (Px 26)
    Draw-PillButton $G $Map $Hover 'code-new' $new (Tx 'Nueva sesi\u00f3n...') { Open-HubCodeSession } -Accent
    $tw = $new.X - $tx - (Px 10)
    Draw-Text $G 'Abrir con Claude Code' $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) $tw (Px 22)
    if ($c.MenuInstalled) {
        Draw-Text $G (Tx '\u2713 En el men\u00fa del Explorador: clic derecho en una carpeta') $F.Small $P.Ok $tx ($card.Y + (Px 36)) $tw (Px 18)
    } else {
        Draw-Text $G (Tx 'El men\u00fa del Explorador no est\u00e1 instalado: ejecuta install.ps1.') $F.Small $P.Warn $tx ($card.Y + (Px 36)) $tw (Px 18)
    }
    $screensText = if ($screens -eq 1) { '1 pantalla' } else { "$screens pantallas" }
    Draw-Text $G ((Tx 'Cada sesi\u00f3n ocupa media pantalla, con su color, nombre y voz: ') + "$screensText, hasta $slots a la vez.") $F.Small $P.Muted $tx ($card.Y + (Px 56)) ($card.Width - (Px 32)) (Px 18)

    $sessions = @($c.CodeSessions)
    $live = @($sessions | Where-Object { $_.Live }).Count
    $y = Px 172
    Draw-HubCaption $G 'SESIONES' $X0 $y $Inner "$live de $slots abiertas"
    $y += Px 22
    if (-not $sessions.Count) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Ninguna sesi\u00f3n abierta desde el men\u00fa.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
    }
    $now = Get-Date
    for ($i = 0; $i -lt [Math]::Min(7, $sessions.Count); $i++) {
        $session = $sessions[$i]
        $row = New-Rect $X0 $y $Inner (Px 50)
        Fill-Round $G $row (Px 8) $P.Surface
        $color = ConvertFrom-Hex (Get-HubSlotHex $session.Color)
        if (-not $session.Live) { $color = $P.Faint }
        Draw-HubDot $G ($row.X + (Px 14)) ($row.Y + (Px 19)) (Px 12) $color
        $right = $row.Right - (Px 12)
        if ($session.Live) {
            $bw = Get-PillWidth 'Mostrar'
            $btn = New-Rect ($right - $bw) ($row.Y + (Px 13)) $bw (Px 24)
            Draw-PillButton $G $Map $Hover "code-show-$i" $btn 'Mostrar' ([scriptblock]::Create("Show-HubCodeWindow $i"))
            $right = $btn.X - (Px 10)
        } else {
            Draw-Text $G 'cerrada' $F.Small $P.Faint ($right - (Px 80)) $row.Y (Px 80) $row.Height 'Right'
            $right -= Px 90
        }
        $name = if ($session.Name) { $session.Name } else { "Ventana $($session.Slot + 1)" }
        if ($session.Role) { $name += ' ' + (Tx '\u00b7') + ' ' + $session.Role }
        $textX = $row.X + (Px 36)
        Draw-Text $G $name $F.BodyStrong $(if ($session.Live) { $P.Text } else { $P.Muted }) $textX ($row.Y + (Px 6)) ($right - $textX) (Px 20)
        $side = if ($session.Slot % 2 -eq 0) { 'izquierda' } else { 'derecha' }
        $sub = $session.Dir
        $meta = @("mitad $side de la pantalla $([int][Math]::Floor($session.Slot / 2) + 1)")
        if ($session.At) { $meta += 'desde ' + (Format-DialogDateTime $session.At $now) }
        if ($session.Voice) { $meta += 'voz ' + (Format-VoiceName $session.Voice) }
        Draw-Text $G ($meta -join ('  ' + (Tx '\u00b7') + '  ')) $F.Small $P.Muted $textX ($row.Y + (Px 26)) ($right - $textX) (Px 18)
        Draw-Text $G (Split-Path -Leaf $sub) $F.Small $P.Faint ($textX + (Px 240)) ($row.Y + (Px 6)) ($right - $textX - (Px 240)) (Px 20) 'Right'
        $y += Px 56
    }
    Draw-Wrapped $G (Tx 'Al cerrar una ventana su mitad queda libre para la siguiente. Las sesiones de otros PCs se abren desde Otros PCs.') $F.Small $P.Faint $X0 (Px 584) $Inner (Px 34)
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
    $self = if ($b -and $b.Identity) { $b.Identity.name + '  ' + (Tx '\u00b7') + '  ' + $b.Identity.user } else { $env:COMPUTERNAME }
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

    # diagram
    $net = New-Rect $X0 (Px 148) $Inner (Px 268)
    Draw-HubCard $G $net
    Draw-HubNetwork $G $Map $Hover $net $true 'none'

    # paired PCs with their actions
    $y = Px 428
    $peers = @(Get-HubNetworkNodes | Where-Object { $_.Paired })
    Draw-HubCaption $G 'EMPAREJADOS' $X0 $y $Inner $(if ($peers.Count -gt 3) { "+$($peers.Count - 3) " + (Tx 'm\u00e1s en Otros PCs') } else { '' })
    $y += Px 22
    if (-not $peers.Count) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'A\u00fan no hay PCs emparejados. Abre Otros PCs en los dos para emparejarlos.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
        $y += Px 44
    }
    foreach ($node in @($peers | Select-Object -First 3)) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        $style = Get-HubLinkStyle $node.State
        Draw-HubDot $G ($row.X + (Px 14)) ($row.Y + (Px 16)) (Px 8) $style.Color
        $right = $row.Right - (Px 10)
        $buttons = @(@{ Id = "pcs-claude-$($node.Id)"; Label = 'Claude Code'; Action = "Open-BridgeTerminal '$($node.Id)' -Claude"; Accent = $false },
                     @{ Id = "pcs-term-$($node.Id)"; Label = 'Terminal'; Action = "Open-BridgeTerminal '$($node.Id)'"; Accent = $true })
        if ($node.Sessions.Count) { $buttons = @(@{ Id = "pcs-stop-$($node.Id)"; Label = 'Desconectar'; Action = "Stop-HubPeerSessions '$($node.Id)'"; Accent = $false }) + $buttons }
        foreach ($button in $buttons) {
            $bw = Get-PillWidth $button.Label
            $rect = New-Rect ($right - $bw) ($row.Y + (Px 8)) $bw (Px 24)
            Draw-PillButton $G $Map $Hover $button.Id $rect $button.Label ([scriptblock]::Create($button.Action)) -Accent:$button.Accent
            $right = $rect.X - (Px 6)
        }
        $textX = $row.X + (Px 30)
        $nameW = [Math]::Min((Measure-TextWidth $node.Name $F.BodyStrong) + (Px 4), $right - $textX)
        Draw-Text $G $node.Name $F.BodyStrong $P.Text $textX $row.Y $nameW $row.Height
        $sub = $node.Sub
        if ($node.Address) { $sub = $node.Address + '  ' + (Tx '\u00b7') + '  ' + $sub }
        Draw-Text $G $sub $F.Small $(if ($node.State -eq 'session') { $P.Accent } else { $P.Muted }) ($textX + $nameW + (Px 10)) $row.Y ($right - $textX - $nameW - (Px 14)) $row.Height
        $y += Px 44
    }

    $label = 'Emparejar o buscar un PC...'
    $bw = (Get-PillWidth $label) + (Px 10)
    Draw-PillButton $G $Map $Hover 'pcs-open' (New-Rect $X0 (Px 584) $bw (Px 30)) $label { Show-BridgeDialog } -Accent
    Draw-Wrapped $G (Tx 'Emparejar solo se acepta con la ventana de Otros PCs abierta. Cada conexi\u00f3n entrante te pide permiso.') $F.Small $P.Faint ($X0 + $bw + (Px 14)) (Px 582) ($Inner - $bw - (Px 14)) (Px 34)
}

# ---------------------------------------------------------------- Claude Whisper

function Draw-HubWhisperSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $c = $script:Hub.Cache
    $running = [bool]$c.WhisperRunning
    $settings = $c.WhisperSettings
    if (-not $settings) { $settings = Get-WhisperDefaults }

    # status and the main actions
    $card = New-Rect $X0 (Px 72) $Inner (Px 70)
    Draw-HubCard $G $card
    $icon = New-Rect ($card.X + (Px 14)) ($card.Y + (Px 15)) (Px 40) (Px 40)
    Draw-HubDot $G $icon.X $icon.Y $icon.Width $(if ($running) { $P.AccentTint } else { $P.Back })
    Draw-Text $G (Tx '\ue720') $HF.NodeLarge $(if ($running) { $P.Accent } else { $P.Muted }) $icon.X $icon.Y $icon.Width $icon.Height 'Center'
    $right = $card.Right - (Px 16)
    foreach ($button in @(@{ Id = 'whisper-open'; Label = $(if ($running) { 'Mostrar ventana' } else { 'Abrir Claude Whisper' }); Action = { Open-HubWhisper }; Accent = $true },
                          @{ Id = 'whisper-context'; Label = 'Contexto...'; Action = { Edit-HubWhisperContext }; Accent = $false })) {
        $bw = (Get-PillWidth $button.Label) + (Px 8)
        $rect = New-Rect ($right - $bw) ($card.Y + (Px 21)) $bw (Px 28)
        Draw-PillButton $G $Map $Hover $button.Id $rect $button.Label $button.Action -Accent:$button.Accent
        $right = $rect.X - (Px 8)
    }
    $tx = $icon.Right + (Px 12)
    Draw-HubDot $G $tx ($card.Y + (Px 21)) (Px 8) $(if ($running) { $P.Ok } else { $P.Faint })
    Draw-Text $G $(if ($running) { (Tx 'Abierto \u00b7 copiloto de llamadas') } else { (Tx 'Cerrado \u00b7 copiloto de llamadas') }) $F.BodyStrong $P.Text ($tx + (Px 14)) ($card.Y + (Px 13)) ($right - $tx - (Px 14)) (Px 22)
    Draw-Wrapped $G (Tx 'Transcribe la llamada y te dice qu\u00e9 responder, con tu suscripci\u00f3n de Claude.') $F.Small $P.Muted $tx ($card.Y + (Px 36)) ($right - $tx - (Px 6)) (Px 30)

    $leftW = Px 290
    $rx = $X0 + $leftW + (Px 16)
    $rw = $Inner - $leftW - (Px 16)

    # settings
    $enabled = -not $running
    Draw-HubCaption $G 'AJUSTES' $X0 (Px 154) $leftW $(if ($running) { 'en su ventana' } else { '' })
    $scard = New-Rect $X0 (Px 176) $leftW (Px 228)
    Draw-HubCard $G $scard
    $rowX = $scard.X + (Px 4)
    $rowW = $scard.Width - (Px 8)
    $ry = $scard.Y + (Px 6)
    Draw-HubPicker $G $Map $Hover 'wl' (New-Rect $rowX $ry $rowW (Px 30)) 'Idioma' $script:WhisperLanguages[$settings.language] "Set-HubWhisperSetting 'language'" $enabled
    $ry += Px 31
    Draw-HubPicker $G $Map $Hover 'wm' (New-Rect $rowX $ry $rowW (Px 30)) 'Modelo' ($script:WhisperModels[$settings.model] -replace ' \(.*\)$', '') "Set-HubWhisperSetting 'model'" $enabled
    $ry += Px 31
    foreach ($toggle in @(@('autoAnswer', 'Responder solo a preguntas'), @('useMic', (Tx 'Transcribir mi micr\u00f3fono')), @('gateMic', 'Sin auriculares (evita el eco)'),
                          @('meetingNotice', 'Avisar al empezar una llamada'), @('topMost', 'Ventana siempre visible'))) {
        Draw-HubToggleRow $G $Map $Hover "ws-$($toggle[0])" (New-Rect $rowX $ry $rowW (Px 30)) $toggle[1] '' ([bool]$settings[$toggle[0]]) ([scriptblock]::Create("Set-HubWhisperSetting '$($toggle[0])'")) $enabled
        $ry += Px 31
    }

    # hotkeys
    Draw-HubCaption $G 'ATAJOS GLOBALES' $X0 (Px 414) $leftW ''
    $kcard = New-Rect $X0 (Px 436) $leftW (Px 92)
    Draw-HubCard $G $kcard
    $ky = $kcard.Y + (Px 8)
    foreach ($key in @(@($settings.hotkeyAnswer, 'Responder ahora'), @($settings.hotkeyScreen, 'Resolver la pantalla'), @($settings.hotkeyToggle, 'Mostrar u ocultar'))) {
        Draw-Text $G $key[0] $HF.Key $P.Accent ($kcard.X + (Px 14)) $ky (Px 150) (Px 25)
        Draw-Text $G $key[1] $F.Small $P.Muted ($kcard.X + (Px 14)) $ky ($kcard.Width - (Px 28)) (Px 25) 'Right'
        $ky += Px 25
    }
    $note = if ($running) { Tx 'Mientras est\u00e1 abierto, cambia los ajustes desde su ventana (Contexto y el men\u00fa \u22ef).' }
            else { Tx 'Los cambios se aplican la pr\u00f3xima vez que lo abras.' }
    Draw-Wrapped $G $note $F.Small $P.Faint $X0 (Px 536) $leftW (Px 34)

    # calls
    $count = [int]$c.CallCount
    Draw-HubCaption $G $(if ($count) { "LLAMADAS ($count)" } else { 'LLAMADAS' }) $rx (Px 154) $rw ''
    $folder = New-Rect ($rx + $rw - (Px 110)) (Px 154) (Px 110) (Px 18)
    Draw-Text $G (Tx 'Abrir carpeta \u203a') $F.Small $(if ($Hover -eq 'whisper-folder') { $P.AccentHover } else { $P.Accent }) $folder.X $folder.Y $folder.Width $folder.Height 'Right'
    Add-Hit $Map 'whisper-folder' $folder { Open-HubCallFolder }
    $calls = @($c.Calls)
    $y = Px 176
    if (-not $calls.Count) {
        $row = New-Rect $rx $y $rw (Px 60)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Wrapped $G (Tx 'A\u00fan no hay llamadas. Abre Claude Whisper durante una llamada y pulsa Escuchar: cada llamada se guarda aqu\u00ed.') $F.Small $P.Muted ($rx + (Px 14)) ($y + (Px 10)) ($rw - (Px 28)) (Px 44)
    }
    $now = Get-Date
    for ($i = 0; $i -lt $calls.Count; $i++) {
        $call = $calls[$i]
        $row = New-Rect $rx $y $rw (Px 46)
        $hitId = "whisper-call-$i"
        Fill-Round $G $row (Px 8) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
        $when = if ($call.Started) { Format-DialogDateTime $call.Started $now } else { $call.Name }
        Draw-Text $G $when $F.BodyStrong $P.Text ($row.X + (Px 12)) ($row.Y + (Px 4)) ($row.Width - (Px 24)) (Px 20)
        $answers = if ($call.Answers -eq 1) { '1 respuesta' } else { "$($call.Answers) respuestas" }
        Draw-Text $G ((Format-CallDuration $call.Minutes) + '  ' + (Tx '\u00b7') + '  ' + $answers) $F.Small $P.Muted ($row.X + (Px 12)) ($row.Y + (Px 4)) ($row.Width - (Px 24)) (Px 20) 'Right'
        $topic = if ($call.Topic) { $call.Topic } else { 'Sin preguntas' }
        Draw-Text $G $topic $F.Small $P.Muted ($row.X + (Px 12)) ($row.Y + (Px 24)) ($row.Width - (Px 24)) (Px 18)
        Add-Hit $Map $hitId $row ([scriptblock]::Create("Open-HubCall $i"))
        $y += Px 50
    }

    # context summary
    $cy = Px 436
    Draw-HubCaption $G 'CONTEXTO' $rx $cy $rw ''
    $ccard = New-Rect $rx ($cy + (Px 22)) $rw (Px 92)
    $hitId = 'whisper-context-card'
    Fill-Round $G $ccard (Px 10) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
    $termCount = @(([string]$settings.keyterms) -split '[,;\r\n]+' | Where-Object { $_.Trim() }).Count
    $lines = @(
        @('Perfil', $(if ($settings.profile) { "$(([string]$settings.profile).Length) caracteres" } else { (Tx 'vac\u00edo: a\u00f1ade tu CV') })),
        @((Tx 'Conversaci\u00f3n'), $(if ($settings.meeting) { (([string]$settings.meeting) -split "`n")[0].Trim() } else { 'sin describir' })),
        @((Tx 'T\u00e9rminos'), $(if ($termCount) { "$termCount " + (Tx 'para la transcripci\u00f3n') } else { 'ninguno' }))
    )
    $ly = $ccard.Y + (Px 8)
    foreach ($line in $lines) {
        Draw-Text $G $line[0] $F.Small $P.Muted ($ccard.X + (Px 12)) $ly (Px 90) (Px 24)
        Draw-Text $G $line[1] $F.Body $P.Text ($ccard.X + (Px 100)) $ly ($ccard.Width - (Px 112)) (Px 24)
        $ly += Px 25
    }
    Add-Hit $Map $hitId $ccard { Edit-HubWhisperContext }
}

# ---------------------------------------------------------------- Voz

function Draw-HubVoiceSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache

    $card = New-Rect $X0 (Px 72) $Inner (Px 150)
    Draw-HubCard $G $card
    if (-not $c.VoiceInstalled) {
        Draw-Wrapped $G (Tx 'La voz no est\u00e1 instalada. Vuelve a ejecutar install.ps1.') $F.Body $P.Warn ($card.X + (Px 16)) ($card.Y + (Px 16)) ($card.Width - (Px 32)) (Px 40)
        return
    }
    $rowX = $card.X + (Px 6)
    $rowW = $card.Width - (Px 12)
    Draw-HubToggleRow $G $Map $Hover 'voice-on' (New-Rect $rowX ($card.Y + (Px 8)) $rowW (Px 42)) 'Voz en todas las sesiones' (Tx 'Cada sesi\u00f3n lee en voz alta un resumen de cada respuesta, con su propia voz.') (-not $c.VoiceMuted) ([scriptblock]::Create("Set-HubVoiceMuted `$$([bool]$c.VoiceMuted -eq $false)"))
    Draw-HubToggleRow $G $Map $Hover 'voice-keys' (New-Rect $rowX ($card.Y + (Px 54)) $rowW (Px 42)) 'Atajos de teclado' (Tx 'Ctrl+Alt+Shift+O repite lo \u00faltimo  \u00b7  Ctrl+Alt+Shift+P detiene el audio') ([bool]$c.HotkeysOn) ([scriptblock]::Create("Set-HubHotkeys `$$(-not $c.HotkeysOn)"))
    $x = $card.X + (Px 16)
    foreach ($button in @(@{ Id = 'voice-test'; Label = 'Probar voz'; Action = { Invoke-VoiceCtl 'test' 'Reproduciendo una frase de prueba...' }; Accent = $true },
                          @{ Id = 'voice-repeat'; Label = (Tx 'Repetir lo \u00faltimo'); Action = { Invoke-VoiceCtl 'repeat' 'Repitiendo...' }; Accent = $false },
                          @{ Id = 'voice-stop'; Label = 'Detener audio'; Action = { Invoke-VoiceCtl 'stop' 'Audio detenido.' }; Accent = $false })) {
        $bw = Get-PillWidth $button.Label
        Draw-PillButton $G $Map $Hover $button.Id (New-Rect $x ($card.Y + (Px 110)) $bw (Px 26)) $button.Label $button.Action -Accent:$button.Accent
        $x += $bw + (Px 8)
    }

    $y = Px 236
    Draw-HubCaption $G 'SESIONES RECIENTES' $X0 $y $Inner (Tx '\u00daltimas 12 horas  \u00b7  /voz dentro de una sesi\u00f3n para cambiar la suya')
    $y += Px 22
    $sessions = @($c.VoiceSessions)
    if (-not $sessions.Count) {
        $row = New-Rect $X0 $y $Inner (Px 40)
        Fill-Round $G $row (Px 8) $P.Surface
        Draw-Text $G (Tx 'Ninguna sesi\u00f3n ha hablado en las \u00faltimas horas.') $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 40)
    }
    $now = Get-Date
    for ($i = 0; $i -lt [Math]::Min(7, $sessions.Count); $i++) {
        $session = $sessions[$i]
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 8) $P.Surface
        $color = if ($session.Color) { ConvertFrom-Hex (Get-HubSlotHex $session.Color) } else { $P.Faint }
        Draw-HubDot $G ($row.X + (Px 14)) ($row.Y + (Px 16)) (Px 12) $color
        $name = $session.Name
        if ($session.Role) { $name += ' ' + (Tx '\u00b7') + ' ' + $session.Role }
        $textX = $row.X + (Px 36)
        $textW = $row.Width - (Px 140)
        Draw-Text $G $name $F.BodyStrong $P.Text $textX ($row.Y + (Px 4)) $textW (Px 20)
        $ago = $now - $session.Used
        $used = if ($ago.TotalMinutes -lt 1) { 'ahora' } elseif ($ago.TotalHours -lt 1) { 'hace ' + [int]$ago.TotalMinutes + ' min' } else { 'a las ' + (Format-Clock $session.Used) }
        Draw-Text $G ('voz ' + (Format-VoiceName $session.Voice) + '  ' + (Tx '\u00b7') + '  ' + $used) $F.Small $P.Muted $textX ($row.Y + (Px 23)) $textW (Px 18)
        $sx = $row.Right - (Px 50)
        Draw-Text $G $(if ($session.Muted) { 'callada' } else { 'habla' }) $F.Small $P.Muted ($sx - (Px 70)) $row.Y (Px 62) $row.Height 'Right'
        Draw-HubSwitch $G $Map "voice-session-$i" $sx ($row.Y + (Px 12)) (-not $session.Muted) ([scriptblock]::Create("Set-HubVoiceSessionMuted $i"))
        $y += Px 48
    }
}

# ---------------------------------------------------------------- preview (tray.ps1 -RenderHubTo)

function Set-HubPreview {
    Set-BridgePreview
    $b = $script:Bridge
    $b.Pairing = $null
    $b.Requests.Clear()
    $key = $b.Peers[0].hostKey
    $b.Peers = @($b.Peers) + @([pscustomobject]@{ id = 'dddddddddddd'; name = 'MINI-SALA'; user = 'santi'; port = $BridgeSshPort; address = '192.168.1.52'; hostKey = $key; clientKey = $key })
    $b.Sessions[('e' * 32)] = [pscustomobject]@{ Id = ('e' * 32); PeerId = 'bbbbbbbbbbbb'; PeerName = 'PORTATIL-ANA'; Kind = 'shell'; Command = ''; Pid = 0; Started = (Get-Date) }
    $now = Get-Date
    $c = $script:Hub.Cache
    $c.WhisperRunning = $false
    $c.WhisperSettings = Get-WhisperSettings ([pscustomobject]@{ profile = ('x' * 1240); meeting = "Entrevista para Backend Senior en Acme`nObjetivo: pasar a la ronda final"; keyterms = 'Kubernetes, FastAPI, PostgreSQL' })
    $c.CodeSessions = @(
        [pscustomobject]@{ Slot = 0; Hwnd = 0; Live = $true; Dir = 'D:\proyectos\tienda-web'; At = $now.AddMinutes(-95); Color = 'blue'; Name = 'Isabela'; Role = 'codificadora'; Voice = 'es-CO-SalomeNeural' },
        [pscustomobject]@{ Slot = 1; Hwnd = 0; Live = $true; Dir = 'D:\proyectos\ClaudeMaxxing'; At = $now.AddMinutes(-20); Color = 'orange'; Name = 'Mateo'; Role = 'revisor'; Voice = 'es-MX-JorgeNeural' },
        [pscustomobject]@{ Slot = 2; Hwnd = 0; Live = $false; Dir = 'D:\datos\informe'; At = $now.AddHours(-5); Color = 'green'; Name = 'Camila'; Role = 'analista'; Voice = 'es-PE-CamilaNeural' }
    )
    $c.MenuInstalled = $true
    $c.Screens = 2
    $c.VoiceInstalled = $true
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
        ('### Claude ' + [char]0x00B7 + ' Pantalla'), '**Ellos** 10:52:30 Thanks, that is all.')
    $c.Calls = @($first, $second)
    $c.CallCount = 2
    # Estadisticas: the last real result on this PC, when there is one (the window is only drawn locally).
    $c.Stats = Read-JsonFile $StatsFile
    $c.ToolStats = @{ Calls = 2; CallMinutes = 45; CallAnswers = 3; Runs = 14; RunsOk = 13; MenuOpens = 90; Paired = 2 }
    $c.ScheduleRows = @(Get-ScheduleRows $script:PendingTasks (Read-JsonFile $CloudFile) (Read-JsonFile $HistoryFile) $now 5)
}
