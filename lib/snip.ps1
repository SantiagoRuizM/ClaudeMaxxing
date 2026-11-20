# Captura a Claude Code. Win+Alt+C (or the next free hotkey, $SnipHotkeys) freezes the screen darkened, like the Windows snipping tool: drag a rectangle,
# it shows clear and a panel next to it asks for a prompt and a folder; Enter (or Enviar) opens a ClaudeMaxxing
# session there with the image and the prompt. After a Win+Shift+S snip, a box in the bottom right corner asks the
# same: Win+Shift+S belongs to the Windows shell (it cannot be registered or changed, nor does it say where the snip
# was taken), so the tray watches the clipboard and reacts only to images the snipping tool put there: its process
# owns the clipboard, or it has just saved the snip in Pictures\Screenshots (it may have exited by then).
# The default folder is the one of the environment on in Ambientes (its Claude Code folder, else its project folder).
# Needs lib\common.ps1, lib\harness.ps1 ($HarnessHome), lib\sessions.ps1 and, for the windows, lib\theme.ps1.

$SnipFile = Join-Path $TrayHome 'snip.json'
# Out of .claude: Claude Code reads the image from here.
$SnipDir = Join-Path $DefaultInstallDir 'snips'
$SnipOwners = @('ScreenClippingHost', 'SnippingTool', 'ScreenSketch')
$script:SnipSeq = $null
$script:SnipBox = $null
$script:SnipHotkey = $null

# snip.json: { enabled, recent: [folders used from the box, newest first], systemAudio, microphone (what a recording
# takes; the speakers by default, not the microphone, like the Windows snipping tool) }. On unless switched off.
function Get-SnipSettings([string]$Path = $SnipFile) {
    $saved = Read-JsonFile $Path
    @{
        Enabled = -not ($saved -and $saved.enabled -eq $false)
        Recent = @(if ($saved -and $saved.recent) { @($saved.recent) | Where-Object { $_ } })
        SystemAudio = -not ($saved -and $saved.systemAudio -eq $false)
        Microphone = [bool]($saved -and $saved.microphone -eq $true)
    }
}

# One key of snip.json, keeping the others.
function Set-SnipSetting([string]$Name, $Value, [string]$Path = $SnipFile) {
    $saved = Read-JsonFile $Path
    $all = [ordered]@{}
    if ($saved) { foreach ($property in $saved.PSObject.Properties) { $all[$property.Name] = $property.Value } }
    $all[$Name] = $Value
    Write-JsonFile $Path $all
}

function Set-SnipEnabled([bool]$On, [string]$Path = $SnipFile) { Set-SnipSetting 'enabled' $On $Path }

function Add-SnipRecent([string]$Dir, [string]$Path = $SnipFile) {
    $settings = Get-SnipSettings $Path
    Set-SnipSetting 'recent' @(@($Dir) + @($settings.Recent | Where-Object { $_.TrimEnd('\') -ne $Dir.TrimEnd('\') }) | Select-Object -First 5) $Path
}

# The environment on in Ambientes and its folder: claude.dir (where it opens Claude Code), else folder. $null without one.
function Get-SnipEnvironment([string]$DataDir = $HarnessHome) {
    $active = Read-JsonFile (Join-Path $DataDir 'run\active.json')
    if (-not $active -or -not $active.id) { return $null }
    $def = Read-JsonFile (Join-Path $DataDir ('environments\' + $active.id + '.json'))
    if (-not $def) { return $null }
    $dir = if ($def.claude -and $def.claude.dir) { [string]$def.claude.dir } else { [string]$def.folder }
    if (-not $dir) { return $null }
    [pscustomobject]@{ Name = $(if ($active.name) { [string]$active.name } else { [string]$active.id }); Dir = $dir }
}

# The box's folders, the default first: the environment's, the open sessions', the last used from the box, then
# Escritorio, Documentos and Descargas. Missing folders and repeats are left out.
function Get-SnipFolders($Environment, [string[]]$SessionDirs, [string[]]$Recent) {
    $list = New-Object System.Collections.ArrayList
    $candidates = @()
    if ($Environment) { $candidates += , @($Environment.Dir, ((L 'ambiente {0}') -f $Environment.Name)) }
    foreach ($dir in $SessionDirs) { $candidates += , @($dir, (Tx 'sesi\u00f3n abierta')) }
    foreach ($dir in $Recent) { $candidates += , @($dir, (L 'reciente')) }
    $candidates += , @([Environment]::GetFolderPath('Desktop'), (L 'Escritorio'))
    $candidates += , @([Environment]::GetFolderPath('MyDocuments'), (L 'Documentos'))
    $candidates += , @((Join-Path $env:USERPROFILE 'Downloads'), (L 'Descargas'))
    foreach ($c in $candidates) {
        $dir = [string]$c[0]
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        if (@($list | Where-Object { $_.Dir.TrimEnd('\') -eq $dir.TrimEnd('\') }).Count) { continue }
        $leaf = Split-Path -Leaf $dir
        [void]$list.Add([pscustomobject]@{ Dir = $dir; Label = $(if ($leaf) { $leaf + (Tx '  \u00b7  ') + $c[1] } else { $dir + (Tx '  \u00b7  ') + $c[1] }) })
    }
    , @($list)
}

# One line (wt and cmd would cut it at a line break), no double quotes (they would close the argument). The prompt
# is for Claude, not translated.
function Format-SnipPrompt([string]$Text, [string]$ImagePath, [string]$TextPath) {
    $line = (($Text -replace '\s+', ' ').Trim()).Replace('"', "'")
    if ($TextPath) { return "$line [Captura de pantalla: $ImagePath; texto extraido: $TextPath]" }
    "$line [Captura de pantalla: $ImagePath]"
}

# Claude reads images, not video: the recording goes with a few of its frames.
function Format-SnipVideoPrompt([string]$Text, [string]$VideoPath, [string[]]$Frames) {
    $line = (($Text -replace '\s+', ' ').Trim()).Replace('"', "'")
    $tail = if ($Frames) { '; fotogramas: ' + ($Frames -join ', ') } else { '' }
    "$line [Video de la pantalla: $VideoPath$tail]"
}

# A snip: the snipping tool owns the clipboard, or saved a screenshot in the last 10 seconds.
function Test-SnipSource([string]$Owner, $LastShot, [datetime]$Now = (Get-Date)) {
    if ($Owner -and $SnipOwners -contains $Owner) { return $true }
    [bool]($LastShot -and ($Now - [datetime]$LastShot).TotalSeconds -le 10 -and ($Now - [datetime]$LastShot).TotalSeconds -ge -2)
}

function Get-SnipClipboardOwner {
    $hwnd = [ClaudeTray.Native]::GetClipboardOwner()
    if ($hwnd -eq [IntPtr]::Zero) { return '' }
    $ownerPid = [uint32]0
    [void][ClaudeTray.Native]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid)
    try { (Get-Process -Id $ownerPid -ErrorAction Stop).ProcessName } catch { '' }
}

# The folder's own write time changes when a screenshot is added: no listing of a folder with thousands of files.
function Get-SnipLastShot {
    $shots = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
    if (Test-Path -LiteralPath $shots) { (Get-Item -LiteralPath $shots).LastWriteTime } else { $null }
}

function Write-SnipLog([string]$Text) {
    try { Add-Content -LiteralPath $SessionLogFile -Value ((Get-Date).ToString('s') + ' snip: ' + $Text) -Encoding UTF8 } catch { }
}

# The folder of snips and recordings, without what is older than 7 days.
function Initialize-SnipDir([string]$Dir = $SnipDir, [datetime]$Now = (Get-Date)) {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Now.AddDays(-7) } | Remove-Item -ErrorAction SilentlyContinue
}

# Like the Windows snipping tool, every snip also goes to Pictures\Screenshots and every recording to Videos\Screen
# Recordings, with the names Windows gives them. Win+Shift+S's watch then ignores that folder for a moment (it would
# take an image copied meanwhile for a snip).
# $Dir: another folder (tests).
function Save-SnipToLibrary([System.Drawing.Image]$Image, [string]$VideoPath, [datetime]$Now = (Get-Date), [string]$Dir) {
    try {
        $stamp = $Now.ToString('yyyy-MM-dd HHmmss')
        if ($VideoPath) {
            $dir = if ($Dir) { $Dir } else { Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Screen Recordings' }
            $file = Join-Path $dir ((Tx 'Grabaci\u00f3n de pantalla') + " $stamp.mp4")
        } else {
            $dir = if ($Dir) { $Dir } else { Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots' }
            $file = Join-Path $dir ((L 'Captura de pantalla') + " $stamp.png")
        }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $script:SnipSavedAt = Get-Date
        if ($VideoPath) { Copy-Item -LiteralPath $VideoPath -Destination $file -Force } else { $Image.Save($file, [System.Drawing.Imaging.ImageFormat]::Png) }
        $file
    } catch { Write-SnipLog ('library: ' + $_.Exception.Message) }
}

# Saves the snip as a PNG. Returns its path.
function Save-SnipImage([System.Drawing.Image]$Image, [string]$Dir = $SnipDir, [datetime]$Now = (Get-Date)) {
    Initialize-SnipDir $Dir $Now
    $path = Join-Path $Dir ('snip-' + $Now.ToString('yyyyMMdd-HHmmss-fff') + '.png')
    $Image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $path
}

# ---------------------------------------------------------------- native side

# lib\snip.cs (the hotkey, the veil, the windows and screens, the recorder), compiled once into $BinDir (Add-Type
# costs about half a second per run) and loaded from there.
function Initialize-SnipNative {
    if ('ClaudeTray.SnipRecorder' -as [type]) { return }
    $source = [IO.File]::ReadAllText((Join-Path $TrayRoot 'lib\snip.cs'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source))[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $BinDir "ClaudeSnip-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
        # Compile to a private name first so a concurrent run never loads a half-written file.
        $tmp = Join-Path $BinDir "ClaudeSnip-$hash-$PID.dll"
        Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing, System.Windows.Forms -OutputAssembly $tmp -OutputType Library
        try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $BinDir -Filter 'ClaudeSnip-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    Add-Type -Path $dll
}

# Per-monitor pixels (-4, PER_MONITOR_AWARE_V2) while $Action runs: the tray's system DPI would see a screen at another
# scale shrunk (1920 x 1080 at 125 % as 1536 x 864), and windows created meanwhile keep these pixels.
function Invoke-SnipPerMonitor([scriptblock]$Action) {
    $dpi = [ClaudeTray.Native]::SetThreadDpiAwarenessContext([IntPtr]-4)
    try { & $Action } finally { if ($dpi -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::SetThreadDpiAwarenessContext($dpi) } }
}

# The rectangle between where the drag started and where the mouse is, in any direction.
function Get-SnipRect([System.Drawing.Point]$A, [System.Drawing.Point]$B) {
    New-Object System.Drawing.Rectangle([Math]::Min($A.X, $B.X), [Math]::Min($A.Y, $B.Y), [Math]::Abs($A.X - $B.X), [Math]::Abs($A.Y - $B.Y))
}

# Where the prompt panel goes: right of the snip, else left, below or above it, inside its screen's work area; with
# no room around it (a full-screen snip), over its bottom right corner.
function Get-SnipPanelPosition([System.Drawing.Rectangle]$Region, [System.Drawing.Rectangle]$Area, [int]$Width, [int]$Height, [int]$Gap) {
    $y = [Math]::Max($Area.Top, [Math]::Min($Region.Top, $Area.Bottom - $Height))
    if ($Region.Right + $Gap + $Width -le $Area.Right) { return New-Object System.Drawing.Point(($Region.Right + $Gap), $y) }
    if ($Region.Left - $Gap - $Width -ge $Area.Left) { return New-Object System.Drawing.Point(($Region.Left - $Gap - $Width), $y) }
    $x = [Math]::Max($Area.Left, [Math]::Min($Region.Left, $Area.Right - $Width))
    if ($Region.Bottom + $Gap + $Height -le $Area.Bottom) { return New-Object System.Drawing.Point($x, ($Region.Bottom + $Gap)) }
    if ($Region.Top - $Gap - $Height -ge $Area.Top) { return New-Object System.Drawing.Point($x, ($Region.Top - $Gap - $Height)) }
    New-Object System.Drawing.Point(($Area.Right - $Width - $Gap), ($Area.Bottom - $Height - $Gap))
}

# ---------------------------------------------------------------- the watch and the hotkey

function Start-SnipWatch {
    Initialize-SnipNative
    $script:SnipSeq = [ClaudeTray.Native]::GetClipboardSequenceNumber()
    $script:SnipTimer = New-Object System.Windows.Forms.Timer
    # Fast: the snipping tool can exit a moment after copying, and then the clipboard has no owner to tell.
    $script:SnipTimer.Interval = 250
    $script:SnipTimer.Add_Tick({ try { Invoke-SnipWatch } catch { Write-SnipLog $_.Exception.Message } })
    $script:SnipTimer.Start()
    Update-SnipHotkey
    # A rehearsal off screen a few seconds after the tray starts: PowerShell compiles each function on its first call,
    # and the first capture would otherwise take twice as long.
    $script:SnipWarmup = New-Object System.Windows.Forms.Timer
    $script:SnipWarmup.Interval = 4000
    $script:SnipWarmup.Add_Tick({
        $this.Stop()
        $this.Dispose()
        try { Invoke-SnipWarmup } catch { Write-SnipLog ('warm-up: ' + $_.Exception.Message) }
    })
    $script:SnipWarmup.Start()
}

function Invoke-SnipWarmup {
    # The native calls of Start-SnipCapture too (the .NET code compiles on first use as well).
    Invoke-SnipPerMonitor {
        $titles = $null; $handles = $null
        [void](ConvertFrom-SnipRects ([ClaudeTray.SnipDesktop]::Windows([ref]$titles, [ref]$handles)) 4 (New-Object System.Drawing.Point(0, 0)))
        [void](ConvertFrom-SnipRects ([ClaudeTray.SnipDesktop]::Screens()) 8 (New-Object System.Drawing.Point(0, 0)))
        ([ClaudeTray.SnipCanvas]::FromScreen(0, 0, 16, 16)).Dispose()
    }
    $file = Join-Path ([IO.Path]::GetTempPath()) ('claudemaxxing-snip-warmup-' + $PID + '.png')
    $shot = New-Object System.Drawing.Bitmap(96, 96)
    $screens = New-Object System.Collections.ArrayList
    [void]$screens.Add(@((New-Rect 0 0 96 96), (New-Rect 0 0 96 96)))
    Show-SnipCapture $shot (New-Object System.Drawing.Point(0, 0)) $screens (New-Object System.Collections.ArrayList) (New-Object System.Drawing.Point(40, 40)) -Render @{ Path = $file; Region = (New-Rect 10 10 40 40) }
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}

# The hotkey: the capture, or, while recording, the end of the recording.
function Invoke-SnipHotkey {
    if ($script:SnipRecording) { Stop-SnipRecording } else { Start-SnipCapture }
}

function Stop-SnipWatch {
    if ($script:SnipRecording) { Stop-SnipRecording -Discard }
    if ($script:SnipTimer) { $script:SnipTimer.Stop(); $script:SnipTimer.Dispose(); $script:SnipTimer = $null }
    if ($script:SnipHotkey) { $script:SnipHotkey.Dispose(); $script:SnipHotkey = $null }
    if ($script:SnipBox) { $script:SnipBox.Close() }
}

# The capture's hotkey: the first of these that no other app holds on this PC (Windows only hands out free ones;
# Win+Shift+C, the obvious one, is taken on many PCs). Configuracion shows which one it got.
$SnipHotkeys = @(
    @{ Name = 'Win+Alt+C'; Mods = 9; Key = 0x43 }
    @{ Name = 'Win+Shift+X'; Mods = 12; Key = 0x58 }
    @{ Name = 'Ctrl+Alt+C'; Mods = 3; Key = 0x43 }
)
$script:SnipHotkeyName = $null

# The hotkey while the feature is on; off, the keys go back to the other apps.
function Update-SnipHotkey {
    $on = (Get-SnipSettings).Enabled
    if ($on -and -not $script:SnipHotkey) {
        foreach ($candidate in $SnipHotkeys) {
            $hotkey = New-Object ClaudeTray.SnipHotkey($candidate.Mods, $candidate.Key)
            if (-not $hotkey.Registered) { $hotkey.Dispose(); continue }
            $hotkey.add_Pressed({ try { Invoke-SnipHotkey } catch { Write-SnipLog $_.Exception.Message } })
            $script:SnipHotkey = $hotkey
            $script:SnipHotkeyName = $candidate.Name
            break
        }
        if (-not $script:SnipHotkey) { Write-SnipLog ('every hotkey is taken: ' + (($SnipHotkeys | ForEach-Object { $_.Name }) -join ', ')) }
    } elseif (-not $on -and $script:SnipHotkey) {
        $script:SnipHotkey.Dispose()
        $script:SnipHotkey = $null
        $script:SnipHotkeyName = $null
    }
}

# After Win+Shift+S: the corner box with the snip. The snipping tool copies twice (a second later): ignored while a
# box is open.
function Invoke-SnipWatch {
    $seq = [ClaudeTray.Native]::GetClipboardSequenceNumber()
    if ($seq -eq $script:SnipSeq) { return }
    $script:SnipSeq = $seq
    if ($script:SnipBox) { return }
    $owner = Get-SnipClipboardOwner
    try { if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return } } catch { return }
    if (-not (Get-SnipSettings).Enabled) { return }
    $lastShot = Get-SnipLastShot
    if ($script:SnipSavedAt -and ((Get-Date) - $script:SnipSavedAt).TotalSeconds -lt 12) { $lastShot = $null }
    $isSnip = Test-SnipSource $owner $lastShot
    Write-SnipLog ('image from "{0}", last screenshot {1}: {2}' -f $owner, $lastShot, $(if ($isSnip) { 'box' } else { 'ignored' }))
    if (-not $isSnip) { return }
    try { $image = [System.Windows.Forms.Clipboard]::GetImage() } catch { return }
    if ($image) { Show-SnipBox $image }
}

# ---------------------------------------------------------------- the windows (shared by the capture and the corner box)

# A tray in the background cannot take the focus by itself: attached to the foreground window's input, it can.
function Set-SnipForeground([System.Windows.Forms.Form]$Form) {
    $fg = [ClaudeTray.Native]::GetForegroundWindow()
    $fgPid = [uint32]0
    $fgThread = [ClaudeTray.Native]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $me = [ClaudeTray.Native]::GetCurrentThreadId()
    $attached = $fgThread -and $fgThread -ne $me -and [ClaudeTray.Native]::AttachThreadInput($me, $fgThread, $true)
    [void][ClaudeTray.Native]::SetForegroundWindow($Form.Handle)
    $Form.Activate()
    if ($attached) { [void][ClaudeTray.Native]::AttachThreadInput($me, $fgThread, $false) }
}

# Windows 11's icon font, or Windows 10's.
function Get-SnipIconFont([double]$Size) {
    if (-not $script:SnipIconFamily) {
        $names = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
        $script:SnipIconFamily = if ($names -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
    }
    New-UiFont $script:SnipIconFamily $Size
}

function Get-SnipTips {
    if (-not $script:SnipTips) { $script:SnipTips = New-Object System.Windows.Forms.ToolTip }
    $script:SnipTips
}

# A small icon button (a glyph of the icon font) with its tooltip.
function New-SnipGlyphButton([string]$Glyph, [string]$Tip, [scriptblock]$Click, [int]$Size) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = [string][char][Convert]::ToInt32($Glyph, 16)
    $label.Font = Get-SnipIconFont 10.5
    $label.ForeColor = $script:Palette.Muted
    $label.Cursor = [System.Windows.Forms.Cursors]::Hand
    $label.TextAlign = 'MiddleCenter'
    $label.Size = New-Object System.Drawing.Size($Size, $Size)
    $label.Add_Click($Click)
    $label.Add_MouseEnter({ $this.ForeColor = $script:Palette.Text })
    $label.Add_MouseLeave({ $this.ForeColor = $script:Palette.Muted })
    (Get-SnipTips).SetToolTip($label, $Tip)
    $label
}

# EM_SETCUEBANNER: the grey hint in the empty prompt (it copies the text).
function Set-SnipCue([System.Windows.Forms.TextBox]$Box) {
    $cue = [Runtime.InteropServices.Marshal]::StringToHGlobalUni((Tx '\u00bfQu\u00e9 hace Claude con esta captura?'))
    [void][ClaudeTray.Native]::SendMessage($Box.Handle, 0x1501, [IntPtr]1, $cue)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($cue)
}

# Fills the folder list, the default (the environment's) selected.
function Set-SnipFolderList($State, $Folders) {
    $State.Busy = $true
    try {
        $State.Folders = New-Object System.Collections.ArrayList(, @($Folders))
        $State.Combo.Items.Clear()
        foreach ($folder in $Folders) { [void]$State.Combo.Items.Add($folder.Label) }
        [void]$State.Combo.Items.Add((Tx 'Otra carpeta\u2026'))
        $State.Combo.SelectedIndex = 0
        $State.Index = 0
    } finally { $State.Busy = $false }
}

function Get-SnipFormFolders {
    $sessionDirs = @()
    try { $sessionDirs = @(Get-HubCodeSessions | Where-Object { $_.Live -and $_.Dir } | ForEach-Object { $_.Dir }) } catch { }
    Get-SnipFolders (Get-SnipEnvironment) $sessionDirs (Get-SnipSettings).Recent
}

function New-SnipForm {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = $script:Palette.Back
    $form.KeyPreview = $true
    $form.Text = 'Claude Code'
    $form
}

# The title with Copiar, Guardar and the close cross; the extracted text when there is some; the prompt with its
# Enviar button, the folder list (Set-SnipFolderList) and the hint; from $Top down in $Parent ($Width wide).
# Returns the controls and Bottom, where the last one ends.
function Add-SnipFields($Parent, [int]$Width, [int]$Top, [string]$Title, [string]$OcrText, [switch]$NoText) {
    $P = $script:Palette
    $F = $script:Fonts
    $pad = Px 16
    $inner = $Width - 2 * $pad
    $sendW = Px 76
    $controls = New-Object System.Collections.ArrayList

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = $F.Caps
    $titleLabel.ForeColor = $P.Accent
    $titleLabel.SetBounds($pad, (Px 12), ($inner - (Px 84)), (Px 18))
    [void]$controls.Add($titleLabel)
    $x = $Width - $pad - (Px 22)
    $close = New-SnipGlyphButton 'E711' (L 'Cerrar (Esc)') { $this.FindForm().Close() } (Px 26)
    $close.Location = New-Object System.Drawing.Point($x, (Px 6))
    $save = New-SnipGlyphButton 'E74E' (Tx 'Guardar como\u2026') { Save-SnipResult $this.FindForm() } (Px 26)
    $save.Location = New-Object System.Drawing.Point(($x - (Px 28)), (Px 6))
    $copy = New-SnipGlyphButton 'E8C8' (L 'Copiar') { Copy-SnipResult $this.FindForm() } (Px 26)
    $copy.Location = New-Object System.Drawing.Point(($x - (Px 56)), (Px 6))
    [void]$controls.AddRange(@($close, $save, $copy))

    if ($OcrText -or $NoText) {
        $ocr = New-Object System.Windows.Forms.TextBox
        $ocr.Multiline = $true
        $ocr.ReadOnly = $true
        $ocr.TabStop = $false
        # A scroll bar only for long text (a light system one otherwise sits in the dark box).
        $ocr.ScrollBars = $(if (@($OcrText -split "`n").Count -gt 5) { 'Vertical' } else { 'None' })
        $ocr.WordWrap = $true
        $ocr.Font = $F.Body
        $ocr.BackColor = $P.Surface
        $ocr.ForeColor = $(if ($OcrText) { $P.Text } else { $P.Muted })
        $ocr.BorderStyle = 'FixedSingle'
        $ocr.Text = $(if ($OcrText) { $OcrText } else { Tx 'No se encontr\u00f3 texto en el recuadro.' })
        $ocr.SetBounds($pad, $Top, $inner, (Px 96))
        [void]$controls.Add($ocr)
        $Top += Px 104
    }

    $text = New-Object System.Windows.Forms.TextBox
    $text.SetBounds($pad, $Top, ($inner - $sendW - (Px 8)), (Px 26))
    $text.Font = $F.Body
    $text.BackColor = $P.Surface
    $text.ForeColor = $P.Text
    $text.BorderStyle = 'FixedSingle'

    $send = New-Object System.Windows.Forms.Button
    $send.Text = L 'Enviar'
    $send.Font = $F.Button
    $send.FlatStyle = 'Flat'
    $send.FlatAppearance.BorderSize = 0
    $send.FlatAppearance.MouseOverBackColor = $P.AccentHover
    $send.BackColor = $P.Accent
    $send.ForeColor = $P.AccentText
    $send.Cursor = [System.Windows.Forms.Cursors]::Hand
    $send.SetBounds(($pad + $inner - $sendW), ($Top - 1), $sendW, ($text.Height + 2))
    $send.Add_Click({ Submit-SnipBox })

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.SetBounds($pad, ($Top + (Px 34)), $inner, (Px 26))
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle = 'Flat'
    $combo.Font = $F.Body
    $combo.BackColor = $P.Surface
    $combo.ForeColor = $P.Text
    $combo.MaxDropDownItems = 12
    # Drawn by hand: a DropDownList ignores BackColor and shows white with the system highlight.
    $combo.DrawMode = 'OwnerDrawFixed'
    $combo.ItemHeight = Px 20
    $combo.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $P = $script:Palette
        $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -and -not ($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit)
        $back = New-Object System.Drawing.SolidBrush($(if ($selected) { $P.SurfaceHover } else { $P.Surface }))
        $e.Graphics.FillRectangle($back, $e.Bounds)
        $back.Dispose()
        $color = if ($e.Index -eq $sender.Items.Count - 1) { $P.Accent } else { $P.Text }
        Draw-Text $e.Graphics ([string]$sender.Items[$e.Index]) $sender.Font $color ($e.Bounds.X + (Px 4)) $e.Bounds.Y ($e.Bounds.Width - (Px 8)) $e.Bounds.Height
    })
    $combo.Add_SelectedIndexChanged({ Select-SnipFolder $this })

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = Tx 'Enter abre Claude Code en la siguiente mitad libre  \u00b7  Esc cierra'
    $hint.Font = $F.Small
    $hint.ForeColor = $P.Faint
    $hint.SetBounds($pad, ($Top + (Px 72)), $inner, (Px 20))

    [void]$controls.AddRange(@($text, $send, $combo, $hint))
    foreach ($control in $controls) { $Parent.Controls.Add($control) }
    @{ Text = $text; Combo = $combo; Hint = $hint; Bottom = ($Top + (Px 92)) }
}

# Says something in the hint line (Copiado, Guardado...), in green.
function Set-SnipHint($State, [string]$Text) {
    if ($State.Hint) { $State.Hint.Text = $Text; $State.Hint.ForeColor = $script:Palette.Ok }
}

# What both windows share: Esc, Enter, the cleanup and the focus. $AutoClose: gone after 30 seconds left alone.
function Register-SnipForm([System.Windows.Forms.Form]$Form, [bool]$AutoClose) {
    $script:SnipBox = $Form
    $Form.Add_KeyDown({
        param($sender, $e)
        if ($e.Handled) { return }
        $s = $sender.Tag
        if ($e.KeyCode -eq 'Escape') { $e.SuppressKeyPress = $true; $sender.Close() }
        elseif ($e.KeyCode -eq 'Return' -and $s.Text -and ($s.Image -or $s.Video) -and -not $s.Combo.DroppedDown) { $e.SuppressKeyPress = $true; Submit-SnipBox }
    })
    if ($AutoClose) {
        $Form.Tag.Timer = New-Object System.Windows.Forms.Timer
        $Form.Tag.Timer.Interval = 30000
        $Form.Tag.Timer.Add_Tick({
            $box = $script:SnipBox
            $this.Stop()
            if ($box -and -not $box.Tag.Text.Text -and -not $box.ContainsFocus) { $box.Close() }
        })
    }
    $Form.Add_FormClosed({
        $s = $this.Tag
        if ($s.Timer) { $s.Timer.Stop(); $s.Timer.Dispose() }
        foreach ($bitmap in $s.Image, $s.Bright, $s.Canvas, $s.WindowShot) { if ($bitmap) { $bitmap.Dispose() } }
        if ($s.ToolbarImage) { $s.ToolbarImage.Bitmap.Dispose() }
        if ($s.EscKey) { $s.EscKey.Dispose() }
        if ($script:SnipBox -eq $this) { $script:SnipBox = $null }
        # The capture kept per-monitor pixels while it was open (Start-SnipCapture).
        if ($s.DpiOld -and $s.DpiOld -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::SetThreadDpiAwarenessContext($s.DpiOld) }
        $this.Dispose()
    })
    $Form.Add_Shown({
        if (-not $this.Tag.Bright) { Set-RoundedWindow $this $script:Palette.Border }
        Set-SnipForeground $this
        if ($this.Tag.Text) { [void]$this.Tag.Text.Focus() }
        if ($this.Tag.Timer) { $this.Tag.Timer.Start() }
    })
    $Form.Show()
    if ($Form.Tag.Text) { Set-SnipCue $Form.Tag.Text }
}

function Save-SnipRender([System.Windows.Forms.Form]$Form, [string]$Path) {
    $Form.Location = New-Object System.Drawing.Point(-12000, -12000)
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
    $Form.DrawToBitmap($bmp, (New-Rect 0 0 $Form.Width $Form.Height))
    $bmp.Save($Path)
    $bmp.Dispose()
    foreach ($bitmap in $Form.Tag.Image, $Form.Tag.Bright, $Form.Tag.Canvas, $Form.Tag.WindowShot) { if ($bitmap) { $bitmap.Dispose() } }
    $Form.Tag.Image = $null; $Form.Tag.Bright = $null; $Form.Tag.Canvas = $null
    $Form.Close()
}

# A PNG read without keeping the file locked.
function Read-SnipBitmap([string]$Path) {
    $memory = New-Object System.IO.MemoryStream(, [IO.File]::ReadAllBytes($Path))
    New-Object System.Drawing.Bitmap($memory)
}

function Format-SnipDuration([TimeSpan]$Span) { '{0}:{1:00}' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds }

# After Win+Shift+S (a snip) or a recording ($Video: Path, Frames, Duration): a box in the bottom right corner with a
# thumbnail and the prompt.
function Show-SnipBox([System.Drawing.Image]$Image, [string]$RenderPath, $Video) {
    $P = $script:Palette
    $form = New-SnipForm
    $w = Px 420
    $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.SetBounds((Px 16), (Px 36), ($w - (Px 32)), (Px 128))
    $picture.SizeMode = 'Zoom'
    $picture.BackColor = $P.Surface
    $picture.Image = $Image
    $form.Controls.Add($picture)
    $title = if ($Video) { (Tx 'V\u00cdDEO PARA CLAUDE CODE') + '  ' + (Format-SnipDuration $Video.Duration) } else { L 'CAPTURA PARA CLAUDE CODE' }
    $fields = Add-SnipFields $form $w (Px 174) $title
    $form.ClientSize = New-Object System.Drawing.Size($w, ($fields.Bottom + (Px 12)))
    $form.Location = New-Object System.Drawing.Point(($area.Right - $w - (Px 16)), ($area.Bottom - $form.Height - (Px 16)))
    $form.Tag = @{ Image = $Image; Video = $Video; Text = $fields.Text; Combo = $fields.Combo; Hint = $fields.Hint; Folders = $null; Index = 0; Busy = $false }
    Set-SnipFolderList $form.Tag (Get-SnipFormFolders)
    if ($RenderPath) { Save-SnipRender $form $RenderPath; return }
    Register-SnipForm $form $true
}

# "Otra carpeta..." (the last item): a folder picker; what it picks goes first in the list.
function Select-SnipFolder([System.Windows.Forms.ComboBox]$Combo) {
    $form = $Combo.FindForm()
    $s = $form.Tag
    if (-not $s -or $s.Busy) { return }
    $combo = $s.Combo
    if ($combo.SelectedIndex -lt $s.Folders.Count) { $s.Index = $combo.SelectedIndex; return }
    $s.Busy = $true
    try {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = Tx 'Carpeta donde abrir Claude Code con la captura'
        if ($picker.ShowDialog($form) -eq 'OK' -and $picker.SelectedPath) {
            $dir = $picker.SelectedPath
            $leaf = Split-Path -Leaf $dir
            $s.Folders.Insert(0, [pscustomobject]@{ Dir = $dir; Label = $(if ($leaf) { $leaf } else { $dir }) })
            $combo.Items.Insert(0, $s.Folders[0].Label)
            $s.Index = 0
        }
        $combo.SelectedIndex = $s.Index
    } finally { $s.Busy = $false }
    [void]$s.Text.Focus()
}

# The capture's image with what was drawn on it, up to date (Update-SnipCaptureImage, lib\snipcapture.ps1).
function Update-SnipResult([System.Windows.Forms.Form]$Form) {
    if ($Form.Tag.Bright) { Update-SnipCaptureImage $Form }
}

# Copiar: the video as a file, the extracted text, or the image.
function Copy-SnipResult([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    try {
        if ($s.Video) {
            $files = New-Object System.Collections.Specialized.StringCollection
            [void]$files.Add($s.Video.Path)
            [System.Windows.Forms.Clipboard]::SetFileDropList($files)
        } elseif ($s.OcrText) {
            [System.Windows.Forms.Clipboard]::SetText($s.OcrText)
        } else {
            Update-SnipResult $Form
            [System.Windows.Forms.Clipboard]::SetImage($s.Image)
        }
        # Not a Win+Shift+S snip: the clipboard watch lets it be.
        $script:SnipSeq = [ClaudeTray.Native]::GetClipboardSequenceNumber()
        Set-SnipHint $s (L 'Copiado al portapapeles')
    } catch { Set-SnipHint $s $_.Exception.Message }
}

# Guardar como: a PNG, or the MP4, in Pictures\Screenshots by default, named like the Windows snipping tool does.
function Save-SnipResult([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    $pictures = [Environment]::GetFolderPath('MyPictures')
    $shots = Join-Path $pictures 'Screenshots'
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.InitialDirectory = $(if (Test-Path -LiteralPath $shots) { $shots } else { $pictures })
    $stamp = (Get-Date).ToString('yyyy-MM-dd HHmmss')
    if ($s.Video) {
        $dialog.Filter = 'MP4 (*.mp4)|*.mp4'
        $dialog.FileName = (Tx 'Grabaci\u00f3n de pantalla') + " $stamp.mp4"
    } else {
        $dialog.Filter = 'PNG (*.png)|*.png'
        $dialog.FileName = (L 'Captura de pantalla') + " $stamp.png"
    }
    if ($dialog.ShowDialog($Form) -ne 'OK') { return }
    try {
        if ($s.Video) { Copy-Item -LiteralPath $s.Video.Path -Destination $dialog.FileName -Force }
        else { Update-SnipResult $Form; $s.Image.Save($dialog.FileName, [System.Drawing.Imaging.ImageFormat]::Png) }
        Set-SnipHint $s ((L 'Guardado en ') + (Split-Path -Leaf $dialog.FileName))
    } catch { Set-SnipHint $s $_.Exception.Message }
}

function Submit-SnipBox {
    $box = $script:SnipBox
    if (-not $box) { return }
    $s = $box.Tag
    $prompt = $s.Text.Text.Trim()
    if (-not ($s.Image -or $s.Video) -or -not $prompt) { [void]$s.Text.Focus(); return }
    $dir = $s.Folders[$s.Index].Dir
    try {
        if ($s.Video) {
            $line = Format-SnipVideoPrompt $prompt $s.Video.Path @($s.Video.Frames)
        } else {
            Update-SnipResult $box
            $file = Save-SnipImage $s.Image
            $textFile = $null
            if ($s.OcrText) {
                $textFile = [IO.Path]::ChangeExtension($file, '.txt')
                [IO.File]::WriteAllText($textFile, $s.OcrText, (New-Object System.Text.UTF8Encoding($false)))
            }
            $line = Format-SnipPrompt $prompt $file $textFile
        }
        Start-ClaudeCodeSession $dir $line
        Add-SnipRecent $dir
        Write-SnipLog "session in $dir"
    } catch {
        Write-SnipLog $_.Exception.Message
        Set-SnipHint $s $_.Exception.Message
        return
    }
    $box.Close()
}

# ---------------------------------------------------------------- text in the snip (Windows OCR)

# The Windows OCR engine (Windows.Media.Ocr, the one behind the snipping tool's text actions) in the languages of the
# user's profile. Lines joined with line breaks; '' when there is no text or no OCR language installed.
function Get-SnipText([System.Drawing.Bitmap]$Image) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) { return '' }
    # Small text reads better bigger; the engine takes at most MaxImageDimension pixels a side.
    $max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $scale = [Math]::Min([Math]::Max(1.0, 1200.0 / [Math]::Max($Image.Width, $Image.Height)), 3.0)
    $scale = [Math]::Min($scale, $max / [double][Math]::Max($Image.Width, $Image.Height))
    $w = [Math]::Max(1, [int]($Image.Width * $scale))
    $h = [Math]::Max(1, [int]($Image.Height * $scale))
    $sized = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($sized)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($Image, 0, 0, $w, $h)
    $g.Dispose()
    $memory = New-Object System.IO.MemoryStream
    $sized.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
    $sized.Dispose()
    $memory.Position = 0
    try {
        $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
        $decoder = Wait-SnipAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-SnipAsync ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-SnipAsync ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        (@($result.Lines | ForEach-Object { $_.Text }) -join "`r`n")
    } finally { $memory.Dispose() }
}

# A WinRT IAsyncOperation<T> awaited from PowerShell (it has no await): as a .NET task, waited for.
function Wait-SnipAsync($Operation, [type]$ResultType) {
    if (-not $script:SnipAsTask) {
        $script:SnipAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
            Select-Object -First 1
    }
    $task = $script:SnipAsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    $task.Result
}
