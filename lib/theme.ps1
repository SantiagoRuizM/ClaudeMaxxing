# Claude-style palette, fonts and drawing helpers shared by the popup and the schedule dialog.
# Requires System.Windows.Forms and System.Drawing to be loaded.

if (-not ('ClaudeTray.Native' -as [type])) {
    Add-Type -Namespace ClaudeTray -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
'@
}

# Must run before measuring DPI; otherwise Windows reports 96 and bitmap-scales the windows.
[void][ClaudeTray.Native]::SetProcessDPIAware()
$screenGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = $screenGraphics.DpiX / 96.0
$screenGraphics.Dispose()
function Px([double]$Value) { [int][Math]::Round($Value * $script:Scale) }

function New-Rgb([int]$R, [int]$G, [int]$B) { [System.Drawing.Color]::FromArgb($R, $G, $B) }

function Test-AppsLightTheme {
    try {
        $theme = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
        return ($theme.AppsUseLightTheme -eq 1)
    } catch { return $false }
}

# Colors follow claude.ai: warm off-white or warm charcoal, with the clay accent. Muted and Faint text stay at
# 4.5:1 or more on the window background (WCAG AA), with Muted a step stronger than Faint.
function Get-ClaudePalette([bool]$Light) {
    if ($Light) {
        return @{
            Back = New-Rgb 250 249 245; Surface = New-Rgb 240 238 230; SurfaceHover = New-Rgb 232 229 218
            Border = New-Rgb 222 219 207; Text = New-Rgb 20 20 19; Muted = New-Rgb 90 89 84; Faint = New-Rgb 117 115 107
            Accent = New-Rgb 217 119 87; AccentHover = New-Rgb 198 97 63; AccentText = New-Rgb 255 255 255
            AccentTint = New-Rgb 247 229 220; Track = New-Rgb 228 225 214
            low = New-Rgb 106 150 90; medium = New-Rgb 201 145 50; high = New-Rgb 196 72 54
            Ok = New-Rgb 86 135 72; Error = New-Rgb 190 65 50; Warn = New-Rgb 176 120 30
        }
    }
    @{
        Back = New-Rgb 38 38 36; Surface = New-Rgb 48 48 46; SurfaceHover = New-Rgb 58 58 55
        Border = New-Rgb 66 65 61; Text = New-Rgb 250 249 245; Muted = New-Rgb 166 163 154; Faint = New-Rgb 142 140 133
        Accent = New-Rgb 217 119 87; AccentHover = New-Rgb 229 136 105; AccentText = New-Rgb 255 255 255
        AccentTint = New-Rgb 70 52 44; Track = New-Rgb 62 62 58
        low = New-Rgb 132 176 112; medium = New-Rgb 226 171 78; high = New-Rgb 226 101 80
        Ok = New-Rgb 132 176 112; Error = New-Rgb 232 112 92; Warn = New-Rgb 226 171 78
    }
}

function New-UiFont([string]$Family, [double]$Size, [string]$Style = 'Regular') {
    New-Object System.Drawing.Font($Family, [single]$Size, [System.Drawing.FontStyle]$Style)
}

$script:Fonts = @{
    Title      = New-UiFont 'Georgia' 14
    Caps       = New-UiFont 'Segoe UI Semibold' 7.5
    Body       = New-UiFont 'Segoe UI' 9
    BodyStrong = New-UiFont 'Segoe UI Semibold' 9.5
    Number     = New-UiFont 'Segoe UI Semibold' 14
    Small      = New-UiFont 'Segoe UI' 8
    Button     = New-UiFont 'Segoe UI Semibold' 9.5
    Badge      = New-UiFont 'Segoe UI Semibold' 7.5
    Close      = New-UiFont 'Segoe UI' 12
    Refresh    = New-UiFont 'Segoe UI Symbol' 11
}

function Get-ClaudeIconPath([string]$Name) {
    $package = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package) {
        $path = Join-Path $package.InstallLocation "app\resources\$Name"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $fallback = Join-Path $TrayRoot "assets\$Name"
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    $null
}

# Taskbar icon: white glyph on dark taskbars, black on light ones.
function Get-TrayIcon {
    $lightTaskbar = $false
    try {
        $theme = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
        $lightTaskbar = ($theme.SystemUsesLightTheme -eq 1)
    } catch { }
    $name = if ($lightTaskbar) { 'Tray-Win32.ico' } else { 'Tray-Win32-Dark.ico' }
    $path = Get-ClaudeIconPath $name
    if ($path) {
        try { return New-Object System.Drawing.Icon($path, (Px 16), (Px 16)) } catch { }
    }
    [System.Drawing.SystemIcons]::Information
}

# The Claude spark recolored to a solid color (RGB replaced, alpha kept).
function New-TintedLogo([System.Drawing.Color]$Color, [int]$Size) {
    $path = Get-ClaudeIconPath 'Tray-Win32.ico'
    if (-not $path) { return $null }
    $icon = New-Object System.Drawing.Icon($path, 64, 64)
    $source = $icon.ToBitmap()
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $matrix = New-Object System.Drawing.Imaging.ColorMatrix
    $matrix.Matrix00 = 0; $matrix.Matrix11 = 0; $matrix.Matrix22 = 0
    $matrix.Matrix40 = $Color.R / 255.0; $matrix.Matrix41 = $Color.G / 255.0; $matrix.Matrix42 = $Color.B / 255.0
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $attributes.SetColorMatrix($matrix)
    $g.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)), 0, 0, $source.Width, $source.Height,
        [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    $g.Dispose(); $source.Dispose(); $icon.Dispose()
    $bitmap
}

function New-Rect([int]$X, [int]$Y, [int]$W, [int]$H) { New-Object System.Drawing.Rectangle($X, $Y, $W, $H) }

function New-RoundedPath([System.Drawing.Rectangle]$Rect, [int]$Radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Max(1, [Math]::Min($Radius * 2, [Math]::Min($Rect.Width, $Rect.Height)))
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function Fill-Round($G, [System.Drawing.Rectangle]$Rect, [int]$Radius, [System.Drawing.Color]$Color) {
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $path = New-RoundedPath $Rect $Radius
    $G.FillPath($brush, $path)
    $path.Dispose(); $brush.Dispose()
}

function Stroke-Round($G, [System.Drawing.Rectangle]$Rect, [int]$Radius, [System.Drawing.Color]$Color, [double]$Width = 1) {
    $pen = New-Object System.Drawing.Pen($Color, [single]([Math]::Max(1, $Width * $script:Scale)))
    $path = New-RoundedPath $Rect $Radius
    $G.DrawPath($pen, $path)
    $path.Dispose(); $pen.Dispose()
}

function Draw-Text($G, [string]$Text, $Font, $Color, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Align = 'Left') {
    # NoPrefix: an "&" is drawn as itself, not taken as a keyboard-shortcut marker (which would hide it and
    # underline the next letter, as in "a & b" shown as "a _b").
    $flags = [System.Windows.Forms.TextFormatFlags]'VerticalCenter, NoPadding, EndEllipsis, SingleLine, NoPrefix'
    if ($Align -eq 'Right') { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
    if ($Align -eq 'Center') { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $Font, (New-Rect $X $Y $W $H), $Color, $flags)
}

function Measure-TextWidth([string]$Text, $Font) {
    [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font).Width
}

function Set-RoundedWindow([System.Windows.Forms.Form]$Form, [System.Drawing.Color]$BorderColor) {
    # DWMWA_WINDOW_CORNER_PREFERENCE = 33 (2 = round); DWMWA_BORDER_COLOR = 34 (COLORREF 0x00BBGGRR).
    $round = 2
    [void][ClaudeTray.Native]::DwmSetWindowAttribute($Form.Handle, 33, [ref]$round, 4)
    $colorRef = [int]$BorderColor.R -bor ([int]$BorderColor.G -shl 8) -bor ([int]$BorderColor.B -shl 16)
    [void][ClaudeTray.Native]::DwmSetWindowAttribute($Form.Handle, 34, [ref]$colorRef, 4)
}

function Enable-DoubleBuffer($Control) {
    $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($Control, $true, $null)
}

# ---------------------------------------------------------------- hit map
# Owner-drawn forms register clickable rectangles while painting; mouse handlers look them up.
# The map lives in the form's Tag so handlers need no closures. $Tip is shown while the mouse is over it
# (icon-only buttons such as the refresh arrow or a close cross). An area with no action only has a tip.
# Keyboard: Tab / Shift+Tab move a focus ring through the areas with an action, in drawing order, and
# Enter or Space runs it. Forms with a text box keep Tab for it, so this only works on fully drawn forms.

function New-HitMap { @{ Items = New-Object System.Collections.ArrayList; Hover = $null; Focus = $null; Tip = $null; TipId = $null } }

function Add-Hit($Map, [string]$Id, [System.Drawing.Rectangle]$Rect, [scriptblock]$Action, [string]$Tip) {
    [void]$Map.Items.Add(@{ Id = $Id; Rect = $Rect; Action = $Action; Tip = $Tip })
}

function Test-HitAction($Item) { [bool]($Item.Action -and $Item.Action.ToString().Trim()) }

# The ring around the area that has the keyboard focus; Register-HitMap draws it after the form's own Paint.
function Draw-HitFocus($G, $Map) {
    if (-not $Map.Focus) { return }
    $item = @($Map.Items | Where-Object { $_.Id -eq $Map.Focus }) | Select-Object -First 1
    if (-not $item) { $Map.Focus = $null; return }
    $r = $item.Rect
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Stroke-Round $G (New-Rect ($r.X - (Px 2)) ($r.Y - (Px 2)) ($r.Width + (Px 4)) ($r.Height + (Px 4))) (Px 8) $script:Palette.Accent 2
}

function Move-HitFocus($Form, [int]$Step) {
    $map = $Form.Tag
    $items = @($map.Items | Where-Object { Test-HitAction $_ })
    if (-not $items.Count) { return }
    $index = -1
    for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Id -eq $map.Focus) { $index = $i; break } }
    $index = if ($index -lt 0) { if ($Step -gt 0) { 0 } else { $items.Count - 1 } } else { ($index + $Step + $items.Count) % $items.Count }
    $map.Focus = $items[$index].Id
    $map.Hover = $map.Focus
    $Form.Invalidate()
}

function Find-Hit($Map, [System.Drawing.Point]$Point) {
    for ($i = $Map.Items.Count - 1; $i -ge 0; $i--) {
        if ($Map.Items[$i].Rect.Contains($Point)) { return $Map.Items[$i] }
    }
    $null
}

function Register-HitMap([System.Windows.Forms.Form]$Form) {
    $Form.Tag.Tip = New-Object System.Windows.Forms.ToolTip
    $Form.KeyPreview = $true
    $Form.Add_MouseMove({
        param($sender, $e)
        $map = $sender.Tag
        $hit = Find-Hit $map $e.Location
        $id = if ($hit) { $hit.Id } else { $null }
        $sender.Cursor = if ($hit -and (Test-HitAction $hit)) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        if ($map.Focus) { $map.Focus = $null; $sender.Invalidate() }
        if ($map.Hover -ne $id) { $map.Hover = $id; $sender.Invalidate() }
        $tip = if ($hit) { $hit.Tip } else { $null }
        if ($map.TipId -ne $id) {
            $map.TipId = $id
            if ($tip) { $map.Tip.Show($tip, $sender, $e.X + (Px 12), $e.Y + (Px 18), 4000) } else { $map.Tip.Hide($sender) }
        }
    })
    $Form.Add_MouseLeave({
        param($sender, $e)
        $sender.Tag.TipId = $null
        $sender.Tag.Tip.Hide($sender)
        if ($sender.Tag.Hover) { $sender.Tag.Hover = $null; $sender.Invalidate() }
    })
    $Form.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $hit = Find-Hit $sender.Tag $e.Location
        if ($hit -and (Test-HitAction $hit)) { & $hit.Action }
    })
    # Tab only reaches KeyDown on a form without focusable controls (a text box keeps it).
    $Form.Add_PreviewKeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Tab') { $e.IsInputKey = $true } })
    $Form.Add_KeyDown({
        param($sender, $e)
        if ($sender.ActiveControl -or $sender.Tag.NoKeys) { return }
        if ($e.KeyCode -eq 'Tab') { Move-HitFocus $sender $(if ($e.Shift) { -1 } else { 1 }); $e.Handled = $true; return }
        if ($sender.Tag.Focus -and ($e.KeyCode -eq 'Enter' -or $e.KeyCode -eq 'Space')) {
            $item = @($sender.Tag.Items | Where-Object { $_.Id -eq $sender.Tag.Focus }) | Select-Object -First 1
            if ($item -and (Test-HitAction $item)) { $e.Handled = $true; $e.SuppressKeyPress = $true; & $item.Action }
        }
    })
    # Added once the window exists, so it runs after the form's own Paint handler and the ring is on top.
    $Form.Add_HandleCreated({ param($sender, $e) $sender.Add_Paint({ param($s, $pe) try { Draw-HitFocus $pe.Graphics $s.Tag } catch { } }) })
}

# Yes/No before something that cannot be undone; No is the default button. $Owner keeps it on top of that window.
function Confirm-UiAction([string]$Text, $Owner = $null) {
    $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo
    $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    $default = [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    $answer = if ($Owner) { [System.Windows.Forms.MessageBox]::Show($Owner, $Text, 'ClaudeMaxxing', $buttons, $icon, $default) }
        else { [System.Windows.Forms.MessageBox]::Show($Text, 'ClaudeMaxxing', $buttons, $icon, $default) }
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}
