# Notification-area eggs, one per open Claude Code session from the Explorer menu (sessions.json), in the
# session's color. Hovering shows "name - role" and the folder; a click brings that window forward.
# Needs lib\hub.ps1 (Get-HubCodeSessions) and lib\sessions.ps1 ($SlotColors).

# Tooltip: "Isabela - codificadora" plus the folder on a second line. NotifyIcon.Text throws above 63 characters.
function Format-SessionIconTip($Session) {
    $tip = [string]$Session.Name
    if (-not $tip) { $tip = 'Claude Code' }
    if ($Session.Role) { $tip += ' ' + (Tx '\u00b7') + ' ' + $Session.Role }
    $folder = if ($Session.Dir) { Split-Path -Leaf ([string]$Session.Dir).TrimEnd('\', '.') } else { '' }
    if ($folder) { $tip += "`n" + $folder }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + (Tx '\u2026') }
    $tip
}

# Which icon of the pool shows a session: the one of its color, else the one of its slot.
function Get-SessionIconIndex($Session) {
    for ($i = 0; $i -lt $SlotColors.Count; $i++) { if ($SlotColors[$i].Name -eq $Session.Color) { return $i } }
    [int]$Session.Slot % $SlotColors.Count
}

# Claude Code titles its window "<spark> title" while waiting and "<spinner> title" while it works
# (U+2733 vs U+25D0-25D3 and the like). Anything else (a plain shell title) is not a working session.
# Menu sessions turn that title off and their voice hooks write "name - role" instead, with a zero-width space
# at the end while a turn runs (Set-SessionTerminalTitle in voice\hooks\common.ps1).
function Test-SessionTitleBusy([string]$Title) {
    if (-not $Title) { return $false }
    if ($Title[-1] -eq [char]0x200B) { return $true }
    $first = $Title[0]
    $first -ne [char]0x2733 -and -not [char]::IsLetterOrDigit($first) -and -not [char]::IsWhiteSpace($first)
}

# Compiled once, on the first title read (the icon timer's first tick); Show-SessionGlow reuses it.
function Initialize-SessionWindowApi {
    if ('ClaudeTray.SessionWindow' -as [type]) { return }
    Add-Type -Namespace ClaudeTray -Name SessionWindow -MemberDefinition @'
public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder text, int max);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
[DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
'@
}

function Get-SessionWindowTitle([long]$Hwnd) {
    Initialize-SessionWindowApi
    $text = New-Object System.Text.StringBuilder 256
    [void][ClaudeTray.SessionWindow]::GetWindowText([IntPtr]$Hwnd, $text, $text.Capacity)
    $text.ToString()
}

# $Image centered on a transparent square (the egg is taller than wide), as large as fits: tray icons are only
# 16 px at 100 % scale.
function ConvertTo-SquareBitmap([System.Drawing.Image]$Image, [double]$Fill = 0.98) {
    $side = [int][Math]::Ceiling([Math]::Max($Image.Width, $Image.Height) / $Fill)
    $square = New-Object System.Drawing.Bitmap($side, $side)
    $g = [System.Drawing.Graphics]::FromImage($square)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($Image, [int](($side - $Image.Width) / 2), [int](($side - $Image.Height) / 2), $Image.Width, $Image.Height)
    $g.Dispose()
    $square
}

# The two egg_logo images of the project (background already removed), loaded once: egg_logo.png is the still
# egg, egg_logo_gift_thinking.gif gives the thinking frames. Either may be missing.
function Get-EggImages {
    if ($script:EggImages) { return $script:EggImages }
    $still = $null
    $frames = @()
    $pngPath = Join-Path $TrayRoot 'egg_logo.png'
    if (Test-Path -LiteralPath $pngPath) {
        $png = [System.Drawing.Image]::FromFile($pngPath)
        $still = ConvertTo-SquareBitmap $png
        $png.Dispose()
    }
    $gifPath = Join-Path $TrayRoot 'egg_logo_gift_thinking.gif'
    if (Test-Path -LiteralPath $gifPath) {
        $gif = [System.Drawing.Image]::FromFile($gifPath)
        $dimension = New-Object System.Drawing.Imaging.FrameDimension($gif.FrameDimensionsList[0])
        for ($i = 0; $i -lt $gif.GetFrameCount($dimension); $i++) {
            [void]$gif.SelectActiveFrame($dimension, $i)
            $frames += ConvertTo-SquareBitmap $gif
        }
        $gif.Dispose()
    }
    $script:EggImages = [pscustomobject]@{ Still = $still; Frames = $frames }
    $script:EggImages
}

# Thinking light: a round glow behind the egg, a light shade of the session color fading out toward the
# icon's edge, pulsing with the animation. It shows through the egg's stripes and around its sides.
function Add-SessionGlow([System.Drawing.Bitmap]$Egg, [System.Drawing.Color]$Color, [int]$Frame, [int]$Count) {
    $size = $Egg.Width
    $pulse = 0.875 + 0.125 * [Math]::Cos(2 * [Math]::PI * $Frame / [Math]::Max(1, $Count))  # always lit, breathing 75-100 %
    $mix = { param($c) [int]($c + (255 - $c) * 0.55) }
    $light = [System.Drawing.Color]::FromArgb([int](235 * $pulse), (& $mix $Color.R), (& $mix $Color.G), (& $mix $Color.B))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse(-1, -1, $size + 1, $size + 1)
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $brush.CenterColor = $light
    $brush.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, $light))
    $brush.FocusScales = New-Object System.Drawing.PointF(0.35, 0.35)  # a solid core before the fade
    $glowed = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($glowed)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.FillPath($brush, $path)
    $g.DrawImageUnscaled($Egg, 0, 0)
    $g.Dispose(); $brush.Dispose(); $path.Dispose(); $Egg.Dispose()
    $glowed
}

# The egg in the session's color: still while the session waits; frame $Frame of the thinking GIF, with its
# light, while it works. A plain circle if the images are missing.
function New-SessionIconBitmap([string]$Hex, [int]$Size, [int]$Frame = -1) {
    $color = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $eggs = Get-EggImages
    $source = if ($Frame -ge 0 -and $eggs.Frames.Count) { $eggs.Frames[$Frame % $eggs.Frames.Count] } else { $eggs.Still }
    if ($source) {
        $egg = ConvertTo-TintedBitmap $source $color $Size
        if ($Frame -lt 0) { return $egg }
        return Add-SessionGlow $egg $color $Frame (Get-EggFrameCount)
    }
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pad = [Math]::Max(1, [int]($Size / 8))
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, $pad, $pad, $Size - 2 * $pad - 1, $Size - 2 * $pad - 1)
    $brush.Dispose(); $g.Dispose()
    $bitmap
}

# Speaking (its voice is reading the summary): the egg lit up, filled with its color and its lines almost white,
# on a halo of the same color, growing and stretching up from its base with the voice, two beats per cycle.
# The other eggs are outlines: the one talking stands out at a glance.
$script:SpeakFrameCount = 8
function New-SpeakingIconBitmap([string]$Hex, [int]$Size, [int]$Frame) {
    $color = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $beat = [Math]::Abs([Math]::Sin(2 * [Math]::PI * ($Frame % $script:SpeakFrameCount) / $script:SpeakFrameCount))
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $halo = [System.Drawing.Color]::FromArgb([int](110 + 110 * $beat), $color)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse(-1, -1, $Size + 1, $Size + 1)
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $brush.CenterColor = $halo
    $brush.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, $color))
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
    # The egg's square, from 72 % to full size, standing on the bottom edge.
    $side = [Math]::Round($Size * (0.72 + 0.28 * $beat))
    $x = ($Size - $side) / 2; $y = $Size - $side
    # Its inside: an ellipse within the outline (the egg is ~82 % as wide as tall in its square).
    $fill = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($fill, [single]($x + $side * 0.2), [single]($y + $side * 0.1), [single]($side * 0.6), [single]($side * 0.84))
    $fill.Dispose()
    $still = (Get-EggImages).Still
    if ($still) {
        $egg = ConvertTo-TintedBitmap $still (New-Rgb 255 250 242) $Size
        $g.DrawImage($egg, [single]$x, [single]$y, [single]$side, [single]$side)
        $egg.Dispose()
    }
    $g.Dispose()
    $bitmap
}

# An egg image as a grid of dots, $W wide by $H tall ($Dots[$y][$x]), a dot set where the egg covers enough of it.
# The egg's own box is stretched to the grid.
function ConvertTo-EggDots([System.Drawing.Image]$Image, [int]$W, [int]$H) {
    $source = New-Object System.Drawing.Bitmap($Image)
    $left = $source.Width; $top = $source.Height; $right = -1; $bottom = -1
    for ($y = 0; $y -lt $source.Height; $y++) {
        for ($x = 0; $x -lt $source.Width; $x++) {
            if ($source.GetPixel($x, $y).A -gt 40) {
                if ($x -lt $left) { $left = $x }; if ($x -gt $right) { $right = $x }
                if ($y -lt $top) { $top = $y }; if ($y -gt $bottom) { $bottom = $y }
            }
        }
    }
    $small = New-Object System.Drawing.Bitmap($W, $H)
    if ($right -ge 0) {
        $g = [System.Drawing.Graphics]::FromImage($small)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)), $left, $top, ($right - $left + 1), ($bottom - $top + 1), [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
    }
    $source.Dispose()
    $dots = @(for ($y = 0; $y -lt $H; $y++) { , @(for ($x = 0; $x -lt $W; $x++) { $small.GetPixel($x, $y).A -gt 90 }) })
    $small.Dispose()
    , $dots
}

# A grid of dots as terminal pixel art: sextants (2 x 3 dots per cell, Unicode's Symbols for Legacy Computing),
# one string per 3 rows of dots.
function Format-EggSextants($Dots) {
    $rows = [int]($Dots.Count / 3); $cols = [int]($Dots[0].Count / 2)
    $lines = for ($r = 0; $r -lt $rows; $r++) {
        $text = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $cols; $c++) {
            $v = 0
            for ($dy = 0; $dy -lt 3; $dy++) {
                for ($dx = 0; $dx -lt 2; $dx++) { if ($Dots[$r * 3 + $dy][$c * 2 + $dx]) { $v += 1 -shl ($dy * 2 + $dx) } }
            }
            # The block skips the four patterns older characters already have: empty, full and the two halves.
            $glyph = switch ($v) {
                0 { ' ' } 63 { [string][char]0x2588 } 21 { [string][char]0x258C } 42 { [string][char]0x2590 }
                default { [char]::ConvertFromUtf32(0x1FB00 + $v - 1 - [int]($v -gt 21) - [int]($v -gt 42)) }
            }
            [void]$text.Append($glyph)
        }
        $text.ToString()
    }
    , @($lines)
}

# An egg image as terminal pixel art, $Cols cells by $Rows lines. A terminal cell is about half as wide as tall,
# so the grid's proportions already match the egg.
function ConvertTo-EggSextants([System.Drawing.Image]$Image, [int]$Cols, [int]$Rows) {
    Format-EggSextants (ConvertTo-EggDots $Image ($Cols * 2) ($Rows * 3))
}

# The thinking animation for an egg too small for the GIF's waves: its silhouette (inner dots filled) with one
# hole going round the inner dots, clockwise, a frame per step. Each frame as sextant lines.
function New-EggWaveFrames($Dots) {
    $h = $Dots.Count; $w = $Dots[0].Count
    $path = @()
    for ($x = 1; $x -le $w - 2; $x++) { $path += , @($x, 1) }
    for ($y = 2; $y -le $h - 1; $y++) { $path += , @(($w - 2), $y) }
    for ($x = $w - 3; $x -ge 1; $x--) { $path += , @($x, ($h - 1)) }
    for ($y = $h - 2; $y -ge 2; $y--) { $path += , @(1, $y) }
    , @(foreach ($step in $path) {
        $frame = @(for ($y = 0; $y -lt $h; $y++) {
            , @(for ($x = 0; $x -lt $w; $x++) {
                $inner = $x -ge 1 -and $x -le $w - 2 -and $y -ge 1
                if ($x -eq $step[0] -and $y -eq $step[1]) { $false } else { $Dots[$y][$x] -or $inner }
            })
        })
        , (Format-EggSextants $frame)
    })
}

# Steps of the thinking animation: the GIF's frames, or 9 steps of the light alone around the still egg.
function Get-EggFrameCount { $count = (Get-EggImages).Frames.Count; if ($count) { $count } else { 9 } }

# Each color and frame is drawn once and kept: at most 8 colors x (1 + GIF frames + speaking frames) icons.
# shortcut: their HICONs (from GetHicon) are never destroyed; bounded by that cache.
$script:SessionIconCache = @{}
function Get-SessionIcon([int]$Index, [int]$Frame = -1, [switch]$Speaking) {
    $key = if ($Speaking) { "$Index/s$Frame" } else { "$Index/$Frame" }
    if (-not $script:SessionIconCache.ContainsKey($key)) {
        $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        $bitmap = if ($Speaking) { New-SpeakingIconBitmap $SlotColors[$Index].Hex $size $Frame } else { New-SessionIconBitmap $SlotColors[$Index].Hex $size $Frame }
        $script:SessionIconCache[$key] = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        $bitmap.Dispose()
    }
    $script:SessionIconCache[$key]
}

function Show-SessionWindow([long]$Hwnd) {
    if (-not $Hwnd -or -not [ClaudeTray.Native]::IsWindow([IntPtr]$Hwnd)) { return }
    if ([ClaudeTray.Native]::IsIconic([IntPtr]$Hwnd)) { [void][ClaudeTray.Native]::ShowWindow([IntPtr]$Hwnd, 9) }
    [void][ClaudeTray.Native]::SetForegroundWindow([IntPtr]$Hwnd)
}

# Light curve of the glow, in alpha (0-255) by milliseconds since the click: up in 90 ms, soft fade out by 700 ms.
function Get-SessionGlowAlpha([double]$Ms) {
    $peak = 72
    if ($Ms -le 0 -or $Ms -ge 700) { return 0 }
    if ($Ms -lt 90) { return [int]($peak * $Ms / 90) }
    [int]($peak * [Math]::Pow(1 - ($Ms - 90) / 610, 2))
}

# A click on an egg lights its terminal up for a moment in the session's color: a click-through, topmost tint
# over the window that fades out. Every click starts it again.
$script:SessionGlow = $null
function Show-SessionGlow([long]$Hwnd, [string]$Hex) {
    Stop-SessionGlow
    if (-not $Hwnd -or -not [ClaudeTray.Native]::IsWindow([IntPtr]$Hwnd)) { return }
    Initialize-SessionWindowApi
    # The tray is system-DPI-aware: on a monitor with another scale its coordinates are stretched. The glow window is
    # created per-monitor-aware (the context sticks to the window), so it lives in physical pixels like the frame bounds.
    $previous = [ClaudeTray.SessionWindow]::SetThreadDpiAwarenessContext([IntPtr](-4))
    try {
        $rect = New-Object ClaudeTray.SessionWindow+RECT
        # DWMWA_EXTENDED_FRAME_BOUNDS: the visible window in physical pixels, without the invisible resize border.
        if ([ClaudeTray.SessionWindow]::DwmGetWindowAttribute([IntPtr]$Hwnd, 9, [ref]$rect, 16) -ne 0) { return }
        $color = [System.Drawing.ColorTranslator]::FromHtml($Hex)
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.BackColor = $color
        $handle = $form.Handle
        # WS_EX_LAYERED | WS_EX_TRANSPARENT (clicks go through) | WS_EX_TOOLWINDOW (not in Alt+Tab) | WS_EX_NOACTIVATE.
        $ex = [ClaudeTray.SessionWindow]::GetWindowLong($handle, -20) -bor 0x80000 -bor 0x20 -bor 0x80 -bor 0x8000000
        [void][ClaudeTray.SessionWindow]::SetWindowLong($handle, -20, $ex)
        [void][ClaudeTray.SessionWindow]::SetLayeredWindowAttributes($handle, 0, 0, 2)
        Set-RoundedWindow $form $color
        # HWND_TOPMOST at the frame's physical rect, SWP_NOACTIVATE | SWP_SHOWWINDOW: shown without taking the terminal's focus.
        [void][ClaudeTray.SessionWindow]::SetWindowPos($handle, [IntPtr](-1), $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top), 0x50)
    } finally { [void][ClaudeTray.SessionWindow]::SetThreadDpiAwarenessContext($previous) }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 15
    $timer.Add_Tick({ try { Step-SessionGlow } catch { Stop-SessionGlow; Write-SessionIconError $_ } })
    $script:SessionGlow = @{ Form = $form; Timer = $timer; Start = [DateTime]::UtcNow }
    $timer.Start()
}

function Step-SessionGlow {
    $glow = $script:SessionGlow
    if (-not $glow) { return }
    $ms = ([DateTime]::UtcNow - $glow.Start).TotalMilliseconds
    if ($ms -ge 700) { Stop-SessionGlow; return }
    [void][ClaudeTray.SessionWindow]::SetLayeredWindowAttributes($glow.Form.Handle, 0, [byte](Get-SessionGlowAlpha $ms), 2)
}

function Stop-SessionGlow {
    $glow = $script:SessionGlow
    if (-not $glow) { return }
    $script:SessionGlow = $null
    $glow.Timer.Stop(); $glow.Timer.Dispose(); $glow.Form.Dispose()
}

# A fixed pool of icons, created in the same order on every start: Windows 11 remembers each icon id's place and
# "show in the taskbar", so the ids never change. The icons are places, not colors: each one paints the session
# whose terminal matches its place (Get-EggOrder).
# shortcut: two open sessions with the same color share one circle (the later one wins); only past 8 slots.
$script:SessionIcons = @()
# Frame each icon shows: -1 is the still egg, 0..8 the thinking animation.
$script:SessionIconFrames = @{}
# Color ($SlotColors index) each icon is painting now.
$script:SessionIconColor = @{}
# The icon whose session is talking (-1: none) and its speaking frame; it wins over thinking while it lasts.
$script:SessionSpeaking = -1
$script:SessionSpeakFrame = 0

# Keys of the session whose voice is talking now: voice\hooks\play.ps1 writes speaking.json while it holds the turn.
# Its key, plus the one its window was opened with (origin-<key>, voice\hooks\speak.ps1): after /clear the
# conversation has a new id, but sessions.json keeps the first. None if nobody talks, or if that player is gone
# (cut off with taskkill, it never deletes the file).
function Get-SpeakingVoiceKeys {
    $info = Read-JsonFile (Join-Path $VoiceStateDir 'speaking.json')
    if (-not $info -or [int]$info.pid -le 0) { return @() }
    $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
    if (-not $proc -or [string]$proc.StartTime.Ticks -ne [string]$info.start) { return @() }
    $origin = Read-JsonFile (Join-Path $VoiceStateDir ('origin-' + $info.key))
    @([string]$info.key) + @(if ($origin -and $origin.origin) { [string]$origin.origin })
}

# Which icon paints which session: the icons left to right on the taskbar take the terminals left to right (by the
# window's left edge, then top). $IconLefts: the taskbar left of icons 0..n-1, $null where Windows gives none.
# Under ^ they all get the arrow's button: then, and while one is not placed, icon order. Returns icon -> entry.
function Get-EggOrder($IconLefts, $Entries) {
    $sorted = @($Entries | Sort-Object Left, Top, Color)
    $map = @{}
    if (-not $sorted.Count) { return $map }
    $lefts = @($IconLefts)
    $icons = @(0..($sorted.Count - 1))
    if ($lefts.Count -eq $sorted.Count -and -not ($lefts -contains $null) -and @($lefts | Sort-Object -Unique).Count -eq $lefts.Count) {
        $icons = @($icons | Sort-Object { $lefts[$_] })
    }
    for ($k = 0; $k -lt $sorted.Count; $k++) { $map[$icons[$k]] = $sorted[$k] }
    $map
}

# A terminal's visible frame, in physical pixels like the icons' buttons. Minimized or gone: at the right end.
function Get-SessionWindowBounds([long]$Hwnd) {
    Initialize-SessionWindowApi
    $rect = New-Object ClaudeTray.SessionWindow+RECT
    $previous = [ClaudeTray.SessionWindow]::SetThreadDpiAwarenessContext([IntPtr](-4))
    try { $ok = [ClaudeTray.SessionWindow]::DwmGetWindowAttribute([IntPtr]$Hwnd, 9, [ref]$rect, 16) -eq 0 }
    finally { [void][ClaudeTray.SessionWindow]::SetThreadDpiAwarenessContext($previous) }
    if (-not $ok -or $rect.Left -le -32000) { return @{ Left = [int]::MaxValue; Top = 0 } }
    @{ Left = $rect.Left; Top = $rect.Top }
}

function Update-SessionIcons {
    $all = Get-HubCodeSessions  # returns , @(...): piped directly it would arrive as one object
    $byColor = @{}
    foreach ($session in @($all | Where-Object { $_.Live })) { $byColor[(Get-SessionIconIndex $session)] = $session }
    $entries = @(foreach ($color in $byColor.Keys) {
        $bounds = Get-SessionWindowBounds $byColor[$color].Hwnd
        [pscustomobject]@{ Session = $byColor[$color]; Color = [int]$color; Left = $bounds.Left; Top = $bounds.Top }
    })
    # Docked on a screen edge (Get-EggDock): the strip shows them and the taskbar icons stay hidden.
    $docked = (Get-EggDock).Edge -ne 'taskbar'
    # The first icons of the pool, one per session, shown before asking Windows where they are.
    # Shown with its own fixed name, then the session's: Windows finds its taskbar place by that first tooltip.
    for ($i = 0; $i -lt $entries.Count -and -not $docked; $i++) {
        $notify = $script:SessionIcons[$i]
        if (-not $notify.Visible) { $notify.Text = Get-EggIconName $i; $notify.Visible = $true }
    }
    $lefts = @(for ($i = 0; $i -lt $entries.Count -and -not $docked; $i++) { $r = Get-NotifyIconRect $script:SessionIcons[$i]; if ($r) { $r.Left } else { $null } })
    $order = Get-EggOrder $lefts $entries
    $shown = @{}
    foreach ($i in @($order.Keys)) { $shown[$i] = $order[$i].Session }
    $speakKeys = @(Get-SpeakingVoiceKeys)
    $speaking = -1
    if ($speakKeys.Count) { foreach ($i in @($shown.Keys)) { if ($speakKeys -contains $shown[$i].Key) { $speaking = [int]$i } } }
    $anyBusy = $false
    for ($i = 0; $i -lt $script:SessionIcons.Count; $i++) {
        $notify = $script:SessionIcons[$i]
        $session = $shown[$i]
        if ($session -and $script:SessionIconColor[$i] -ne $order[$i].Color) {
            # Another terminal moved into this place: its egg, still until the next step says otherwise.
            $script:SessionIconColor[$i] = $order[$i].Color
            $script:SessionIconFrames[$i] = -1
            if ($i -ne $speaking) { $notify.Icon = Get-SessionIcon $script:SessionIconColor[$i] }
        }
        $busy = $session -and (Test-SessionTitleBusy (Get-SessionWindowTitle $session.Hwnd))
        if ($busy) { $anyBusy = $true; if ($script:SessionIconFrames[$i] -lt 0) { $script:SessionIconFrames[$i] = 0 } }
        elseif ($script:SessionIconFrames[$i] -ge 0) { $script:SessionIconFrames[$i] = -1; if ($i -ne $speaking) { $notify.Icon = Get-SessionIcon $script:SessionIconColor[$i] } }
        if ($docked) { if ($notify.Visible) { $notify.Visible = $false }; continue }
        $placed = Test-TrayIconsPlaced
        if (-not $session) { if ($notify.Visible -and $placed) { $notify.Visible = $false }; continue }
        $notify.Tag = $session.Hwnd
        if (-not $placed) { continue }
        $tip = Format-SessionIconTip $session
        if ($notify.Text -ne $tip) { $notify.Text = $tip }
    }
    if ($speaking -ne $script:SessionSpeaking) {
        $was = $script:SessionSpeaking
        $script:SessionSpeaking = $speaking
        $script:SessionSpeakFrame = 0
        # Back to what it showed before: the still egg, or the thinking frame it is on.
        if ($was -ge 0) { $script:SessionIcons[$was].Icon = Get-SessionIcon $script:SessionIconColor[$was] $script:SessionIconFrames[$was] }
        # Its terminal lights up in its color, as on a click: which window is talking, at a glance.
        if ($speaking -ge 0) { try { Show-SessionGlow $shown[$speaking].Hwnd $SlotColors[$script:SessionIconColor[$speaking]].Hex } catch { Write-SessionIconError $_ } }
    }
    if ($anyBusy -or $speaking -ge 0) { $script:SessionAnimTimer.Start() } else { $script:SessionAnimTimer.Stop() }
    Set-SessionIconsPromoted
    Write-EggStates $shown $speaking
    Update-EggStrip $order
}

# What each open session's egg is doing, by the id its window was opened with, for the statusline's 8-bit egg
# (~/.claude/usage-tray/eggs.json): thinking while the window title shows the spinner, speaking while its voice talks.
# Written only when something changes.
function Write-EggStates($Shown, [int]$Speaking) {
    $states = [ordered]@{}
    foreach ($i in @($Shown.Keys | Sort-Object)) {
        $session = $Shown[$i]
        $states[$session.Key] = if ($i -eq $Speaking) { 'speaking' } elseif ($script:SessionIconFrames[$i] -ge 0) { 'thinking' } else { 'idle' }
    }
    $text = ($states.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    if ($text -eq $script:EggStatesText) { return }
    Write-JsonFile (Join-Path $TrayHome 'eggs.json') $states
    $script:EggStatesText = $text
}

# One step of the thinking animation for every working session (the GIF's own 120 ms per frame), and of the
# speaking one for the session talking.
function Step-SessionIconAnimation {
    for ($i = 0; $i -lt $script:SessionIcons.Count; $i++) {
        if ($i -eq $script:SessionSpeaking) {
            $script:SessionSpeakFrame = ($script:SessionSpeakFrame + 1) % $script:SpeakFrameCount
            if ($script:SessionIcons[$i].Visible) { $script:SessionIcons[$i].Icon = Get-SessionIcon $script:SessionIconColor[$i] $script:SessionSpeakFrame -Speaking }
            continue
        }
        $frame = $script:SessionIconFrames[$i]
        if ($frame -lt 0) { continue }
        $frame = ($frame + 1) % (Get-EggFrameCount)
        $script:SessionIconFrames[$i] = $frame
        if ($script:SessionIcons[$i].Visible) { $script:SessionIcons[$i].Icon = Get-SessionIcon $script:SessionIconColor[$i] $frame }
    }
    if ($script:EggStripShown) { $script:EggStrip.Invalidate() }
}

# Windows 11 puts every new notification icon under the ^ arrow. A circle is only useful on the taskbar, so its
# entry in NotifyIconSettings (the "show in the taskbar" switch of Settings) is turned on. Explorer writes the
# entry some time after the icon first shows, so ids not found yet are retried on the next tick.
$script:SessionIconsPromoted = @{}
function Set-SessionIconsPromoted {
    # The Claude icon and the usage bars (tray.ps1) get the same treatment as the eggs.
    $pending = @(@($script:SessionIcons) + @(@($script:Notify) + @($script:UsageBars) | Where-Object { $_ }) | Where-Object { $_.Visible } |
        ForEach-Object { Get-NotifyIconId $_ } | Where-Object { -not $script:SessionIconsPromoted[$_] })
    if (-not $pending.Count) { return }
    foreach ($key in @(Get-TrayIconEntries)) {
        $entry = Get-ItemProperty -LiteralPath $key.PSPath
        if ($pending -notcontains [int]$entry.UID) { continue }
        # Never set means Windows' default (hidden); a 0 is the user's own choice in Settings and stays.
        if ($null -eq $entry.IsPromoted) { Set-ItemProperty -LiteralPath $key.PSPath -Name IsPromoted -Value 1 -Type DWord }
        $script:SessionIconsPromoted[[int]$entry.UID] = $true
    }
}

# NotifyIconSettings entries of this process's executable (one per icon id Windows has seen from it).
function Get-TrayIconEntries {
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    foreach ($key in @(Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue)) {
        $path = (Get-ItemProperty -LiteralPath $key.PSPath).ExecutablePath
        # ExecutablePath starts with a known-folder GUID ({1AC14E77-...}\WindowsPowerShell\...): compare the rest.
        if ($path -and $exe.EndsWith(($path -replace '^\{[^}]+\}', ''), 'OrdinalIgnoreCase')) { $key }
    }
}

# Fixed ids for the tray's own icons: WinForms numbers icons by creation, which shifts whenever one is added.
# Windows 11 puts an icon it has never seen at the left end of the taskbar icons and keeps that place for good, so
# showing them all once in order (Claude, the usage bars from their right end, then the eggs) leaves them as
# eggs | bars | Claude, side by side. It finds an icon's place by program and first tooltip, else by program and id:
# each icon is always shown with a tooltip of its own that never changes ('ClaudeMaxxing (Claude)',
# 'ClaudeMaxxing (huevo blue)'...), the real text after. Bars and eggs got new ids and names when the order changed
# (they were bars | eggs | Claude), so Windows lays them out again; the old entries are never shown.
$script:TrayIconIds = @{ Claude = 0x4D60; Bars = 0x4D80; Egg = 0x4D90 }
# The usage bars span this many icons (a notification icon is a 16 px square): segment 0 is the left end. Two
# buttons make the continuous bar 64 px at 100 % (Update-UsageOverlay), four times one icon.
$script:UsageBarSegments = 2
function Get-EggIconName([int]$Index) { 'ClaudeMaxxing (huevo ' + $SlotColors[$Index].Name + ')' }
function Get-UsageBarsName([int]$Segment) { 'ClaudeMaxxing (uso ' + ($Segment + 1) + ')' }
function Get-NotifyIdField { [System.Windows.Forms.NotifyIcon].GetField('id', [Reflection.BindingFlags]'NonPublic, Instance') }
function Get-NotifyIconId($Notify) { [int](Get-NotifyIdField).GetValue($Notify) }
# Only before the icon is first shown.
function Set-NotifyIconId($Notify, [int]$Id) { (Get-NotifyIdField).SetValue($Notify, $Id) }
# The icon's button on the taskbar (physical pixels), or $null if Windows has none for it.
function Get-NotifyIconRect($Notify) {
    Initialize-UsageOverlayApi
    $window = [System.Windows.Forms.NotifyIcon].GetField('window', [Reflection.BindingFlags]'NonPublic, Instance').GetValue($Notify)
    $r = New-Object ClaudeTray.UsageOverlay+RECT
    if ([ClaudeTray.UsageOverlay]::IconRect($window.Handle, (Get-NotifyIconId $Notify), [ref]$r)) { $r } else { $null }
}

# True once Windows has an entry for every one of the ids. Until then each icon keeps its first tooltip (Windows
# writes the entry a few seconds after the icon shows, reading the tooltip it has then) and every egg stays shown.
# Explorer never rewrites an entry deleted while it runs: after 15 s the tray goes on without waiting.
$script:TrayIconsPlaced = $false
$script:TrayIconsShownAt = $null
function Test-TrayIconsPlaced {
    if ($script:TrayIconsPlaced) { return $true }
    if ($script:TrayIconsShownAt -and ((Get-Date) - $script:TrayIconsShownAt).TotalSeconds -gt 15) { return ($script:TrayIconsPlaced = $true) }
    $ids = @($script:TrayIconIds.Claude) + @(0..($script:UsageBarSegments - 1) | ForEach-Object { $script:TrayIconIds.Bars + $_ }) +
        @(0..($SlotColors.Count - 1) | ForEach-Object { $script:TrayIconIds.Egg + $_ })
    $known = @(Get-TrayIconEntries | ForEach-Object { [int](Get-ItemProperty -LiteralPath $_.PSPath).UID })
    $script:TrayIconsPlaced = -not @($ids | Where-Object { $known -notcontains $_ }).Count
    $script:TrayIconsPlaced
}

# The usage bars icon: the 5-hour session on top, the weekly below, each filled to its percent in its level color
# ($Palette.low / medium / high) over a faint track. Hard pixel edges: at 16 px a rounded bar only blurs.
# The bars are $Segments icons long; this draws icon $Segment of them (0 is the left end). With $Width, the whole
# bar in one bitmap that wide and $Size tall instead (the continuous bar over the icons, Update-UsageOverlay).
function New-UsageBarsBitmap($View, [int]$Size, $Palette, [bool]$LightTaskbar, [int]$Segment = 0, [int]$Segments = 1, [int]$Width = 0) {
    $track = if ($LightTaskbar) { [System.Drawing.Color]::FromArgb(70, 0, 0, 0) } else { [System.Drawing.Color]::FromArgb(80, 255, 255, 255) }
    $long = if ($Width -gt 0) { $Width } else { $Size * $Segments }
    if ($Width -gt 0) { $Segment = 0 }
    $bitmap = New-Object System.Drawing.Bitmap($(if ($Width -gt 0) { $Width } else { $Size }), $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $barH = [Math]::Max(3, [int][Math]::Round($Size * 0.3))
    $gap = [Math]::Max(2, [int][Math]::Round($Size * 0.14))
    $top = [int][Math]::Floor(($Size - 2 * $barH - $gap) / 2)
    $windows = @($View.Session, $View.Weekly)
    for ($i = 0; $i -lt 2; $i++) {
        $y = $top + $i * ($barH + $gap)
        $brush = New-Object System.Drawing.SolidBrush($track)
        $g.FillRectangle($brush, 0, $y, $bitmap.Width, $barH); $brush.Dispose()
        $w = $windows[$i]
        if (-not ($View.HasData -and $w.Active -and $w.Percent -gt 0)) { continue }
        $fill = [Math]::Max(2, [int][Math]::Round($long * [Math]::Min(100, $w.Percent) / 100)) - $Segment * $Size
        if ($fill -le 0) { continue }
        $brush = New-Object System.Drawing.SolidBrush($Palette[(Get-UsageLevel $w.Percent)])
        $g.FillRectangle($brush, 0, $y, [Math]::Min($bitmap.Width, $fill), $barH); $brush.Dispose()
    }
    $g.Dispose()
    $bitmap
}

# Registry.GetValue (0.4 ms): Get-ItemProperty takes ~10 ms, and the usage overlay asks twice every 300 ms.
function Test-LightTaskbar {
    [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'SystemUsesLightTheme', 0) -eq 1
}

# Each segment's icon, redrawn only when what it shows changes; the previous HICONs are destroyed once replaced.
# -Blank: empty icons, under the continuous bar (they keep the click, menu and tooltip).
$script:UsageBarsHandles = @{}
function Update-UsageBarsIcon($Notifies, $View, [switch]$Blank) {
    $light = Test-LightTaskbar
    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $View.HasData, $View.Session.Active, $View.Session.Percent, $View.Weekly.Active, $View.Weekly.Percent, $light, [bool]$Blank
    if ($script:UsageBarsKey -eq $key) { return }
    Initialize-SessionWindowApi
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $palette = Get-ClaudePalette $light
    for ($i = 0; $i -lt $Notifies.Count; $i++) {
        $bitmap = if ($Blank) { New-Object System.Drawing.Bitmap($size, $size) } else { New-UsageBarsBitmap $View $size $palette $light $i $Notifies.Count }
        $old = $script:UsageBarsHandles[$i]
        $script:UsageBarsHandles[$i] = $bitmap.GetHicon()
        $bitmap.Dispose()
        $Notifies[$i].Icon = [System.Drawing.Icon]::FromHandle($script:UsageBarsHandles[$i])
        if ($old) { [void][ClaudeTray.SessionWindow]::DestroyIcon($old) }
    }
    $script:UsageBarsKey = $key
}

# The continuous bar: a click-through, topmost window with per-pixel alpha over the bar icons' buttons. Works in
# physical pixels (per-monitor DPI) like Show-SessionGlow. Compiled on the first tick.
function Initialize-UsageOverlayApi {
    if ('ClaudeTray.UsageOverlay' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
namespace ClaudeTray {
// Starts a fresh tray when this one stops answering: a hung UI thread (a blocked file read, WMI, a stuck Explorer)
// leaves frozen eggs and an icon that no longer responds until logoff. Its icons go first: killed, they stay as ghosts.
public static class TrayWatchdog {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct NOTIFYICONDATA {
        public int cbSize; public IntPtr hWnd; public int uID; public int uFlags; public int uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIcon(int message, ref NOTIFYICONDATA data);
    static long beat = DateTime.UtcNow.Ticks;

    // From a WinForms timer: it only ticks while the message loop runs. A WM_NULL probe is not enough: an STA thread
    // stuck in a wait or a COM call (WMI) still answers sent messages.
    public static void Beat() { Interlocked.Exchange(ref beat, DateTime.UtcNow.Ticks); }

    // windows[i] owns icon ids[i].
    public static void Start(NativeWindow[] windows, int[] ids, string file, string arguments, string log, int hungSeconds) {
        Beat();
        Thread thread = new Thread(() => {
            while (true) {
                Thread.Sleep(Math.Min(5, hungSeconds) * 1000);
                if ((DateTime.UtcNow - new DateTime(Interlocked.Read(ref beat))).TotalSeconds < hungSeconds) continue;
                try { File.AppendAllText(log, DateTime.Now.ToString("s") + " watchdog: no answer for " + hungSeconds + " s, starting a new tray\r\n"); } catch { }
                for (int i = 0; i < windows.Length; i++) {
                    NOTIFYICONDATA data = new NOTIFYICONDATA();
                    data.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA)); data.hWnd = windows[i].Handle; data.uID = ids[i];
                    if (data.hWnd != IntPtr.Zero) Shell_NotifyIcon(2, ref data);  // NIM_DELETE
                }
                try { ProcessStartInfo start = new ProcessStartInfo(file, arguments); start.UseShellExecute = false; start.CreateNoWindow = true; Process.Start(start); } catch { }
                Process.GetCurrentProcess().Kill();
            }
        });
        thread.IsBackground = true;
        thread.Start();
    }
}

public class UsageOverlay : NativeWindow {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct NID { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int W, H; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLEND { public byte Op, Flags, Alpha, Format; }
    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NID id, out RECT rect);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr dcDst, ref POINT dst, ref SIZE size, IntPtr dcSrc, ref POINT src, int key, ref BLEND blend, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);

    static readonly IntPtr PerMonitor = new IntPtr(-4);
    public bool Shown;

    public UsageOverlay() {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitor);
        try {
            CreateParams cp = new CreateParams();
            cp.Style = unchecked((int)0x80000000);  // WS_POPUP
            // WS_EX_LAYERED | TRANSPARENT (clicks reach the icons) | TOOLWINDOW (not in Alt+Tab) | NOACTIVATE | TOPMOST
            cp.ExStyle = 0x80000 | 0x20 | 0x80 | 0x8000000 | 0x8;
            CreateHandle(cp);
        } finally { SetThreadDpiAwarenessContext(previous); }
    }

    // The icon's button on the taskbar. Under ^ Windows gives the arrow's button instead.
    public static bool IconRect(IntPtr owner, int id, out RECT rect) {
        NID nid = new NID();
        nid.cbSize = (uint)Marshal.SizeOf(typeof(NID)); nid.hWnd = owner; nid.uID = (uint)id;
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitor);
        try { return Shell_NotifyIconGetRect(ref nid, out rect) == 0; } finally { SetThreadDpiAwarenessContext(previous); }
    }

    // The taskbar is what shows at (x, y): false under a full-screen window or with the taskbar auto-hidden.
    // This window is click-through, so WindowFromPoint looks past it.
    public static bool TaskbarAt(int x, int y) {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitor);
        try {
            POINT p; p.X = x; p.Y = y;
            StringBuilder name = new StringBuilder(64);
            GetClassName(GetAncestor(WindowFromPoint(p), 2), name, name.Capacity);
            string cls = name.ToString();
            return cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd";
        } finally { SetThreadDpiAwarenessContext(previous); }
    }

    public void ShowAt(Bitmap bitmap, int x, int y) {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitor);
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr memory = CreateCompatibleDC(screen);
        IntPtr hbitmap = bitmap.GetHbitmap(Color.FromArgb(0));  // premultiplied 32 bpp, as UpdateLayeredWindow wants
        IntPtr old = SelectObject(memory, hbitmap);
        try {
            POINT dst; dst.X = x; dst.Y = y;
            POINT src = new POINT();
            SIZE size; size.W = bitmap.Width; size.H = bitmap.Height;
            BLEND blend = new BLEND(); blend.Alpha = 255; blend.Format = 1;  // AC_SRC_OVER with AC_SRC_ALPHA
            UpdateLayeredWindow(Handle, screen, ref dst, ref size, memory, ref src, 0, ref blend, 2);  // ULW_ALPHA
            Raise();
            Shown = true;
        } finally {
            SelectObject(memory, old); DeleteObject(hbitmap); DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen);
            SetThreadDpiAwarenessContext(previous);
        }
    }

    // HWND_TOPMOST again, shown without activating: a click on the taskbar raises it over this window.
    public void Raise() { SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x40); }

    public void Hide() { if (Shown) { ShowWindow(Handle, 0); Shown = false; } }
}
}
'@
}

# Where the continuous bar goes, from the bar icons' buttons left to right ($null for one Windows did not place):
# across all of them, the bar as tall as the icon drawn in them (half a button's width: 16 of 32 px at 100 %).
# $null unless they sit side by side on one row: under ^ they all get the arrow's button, or an icon dragged between.
function Get-UsageOverlayPlace($Rects) {
    $rects = @($Rects)
    if (-not $rects.Count) { return $null }
    for ($i = 0; $i -lt $rects.Count; $i++) {
        $r = $rects[$i]
        if (-not $r -or $r.Right -le $r.Left -or $r.Top -ne $rects[0].Top -or $r.Bottom -ne $rects[0].Bottom) { return $null }
        if ($i -gt 0 -and $r.Left -ne $rects[$i - 1].Right) { return $null }
    }
    $first = $rects[0]
    # shortcut: icon size taken as half the button's width (Windows 11 at 100-200 %); measure the icon if a build differs.
    $size = [int](($first.Right - $first.Left) / 2)
    # Half an icon of air on the left: flush with the button's edge it looked stuck to the egg beside it.
    $gap = [int]($size / 2)
    [pscustomobject]@{ X = $first.Left + $gap; Y = $first.Top + [int](($first.Bottom - $first.Top - $size) / 2)
        Width = $rects[-1].Right - $first.Left - $gap; Size = $size }
}

# Every 300 ms: the bar over the icons where they are, above the taskbar; the bars back on the icons whenever it
# cannot show (icons under ^, the taskbar covered or hidden).
function Update-UsageOverlay {
    $bars = @($script:UsageBars | Where-Object { $_ })
    if (-not $bars.Count -or -not $script:View) { return }
    $place = $null
    try {
        Initialize-UsageOverlayApi
        if (-not $script:UsageOverlay) { $script:UsageOverlay = New-Object ClaudeTray.UsageOverlay }
        $rects = foreach ($bar in $bars) { Get-NotifyIconRect $bar }
        $place = Get-UsageOverlayPlace $rects
        if ($place -and -not [ClaudeTray.UsageOverlay]::TaskbarAt($place.X + [int]($place.Width / 2), $place.Y + [int]($place.Size / 2))) { $place = $null }
    } catch { $place = $null; Write-SessionIconError $_ }
    Update-UsageBarsIcon $bars $script:View -Blank:([bool]$place)
    if (-not $place) { if ($script:UsageOverlay) { $script:UsageOverlay.Hide() }; $script:UsageOverlayKey = ''; return }
    $view = $script:View
    $light = Test-LightTaskbar
    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $view.HasData, $view.Session.Active, $view.Session.Percent, $view.Weekly.Active, $view.Weekly.Percent, $light, $place.X, $place.Y, $place.Width, $place.Size
    if ($key -eq $script:UsageOverlayKey) { $script:UsageOverlay.Raise(); return }
    $bitmap = New-UsageBarsBitmap $view $place.Size (Get-ClaudePalette $light) $light -Width $place.Width
    try { $script:UsageOverlay.ShowAt($bitmap, $place.X, $place.Y) } finally { $bitmap.Dispose() }
    $script:UsageOverlayKey = $key
}

function Stop-UsageOverlay {
    if ($script:UsageOverlayTimer) { $script:UsageOverlayTimer.Stop() }
    if ($script:UsageOverlay) { $script:UsageOverlay.DestroyHandle(); $script:UsageOverlay = $null }
}

# 90 s without an answer: the longest the tray waits on purpose is ~25 s (Start-FreeLlm). The new tray starts as the
# Startup shortcut does (Get-TrayLaunch, lib\installer.ps1). Call it once every icon exists.
function Start-TrayWatchdog([string]$TrayScript) {
    Initialize-UsageOverlayApi
    $field = [System.Windows.Forms.NotifyIcon].GetField('window', [Reflection.BindingFlags]'NonPublic, Instance')
    $icons = @(@($script:Notify) + @($script:UsageBars) + @($script:SessionIcons) | Where-Object { $_ })
    [ClaudeTray.TrayWatchdog]::Start([System.Windows.Forms.NativeWindow[]]@($icons | ForEach-Object { $field.GetValue($_) }),
        [int[]]@($icons | ForEach-Object { Get-NotifyIconId $_ }), (Join-Path $env:WINDIR 'System32\conhost.exe'),
        ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $TrayScript), (Join-Path $TrayHome 'traysessions.log'), 90)
    $script:TrayBeatTimer = New-Object System.Windows.Forms.Timer
    $script:TrayBeatTimer.Interval = 5000
    $script:TrayBeatTimer.Add_Tick({ [ClaudeTray.TrayWatchdog]::Beat() })
    $script:TrayBeatTimer.Start()
}

function Start-UsageOverlay {
    $script:UsageOverlayTimer = New-Object System.Windows.Forms.Timer
    $script:UsageOverlayTimer.Interval = 300
    $script:UsageOverlayTimer.Add_Tick({ try { Update-UsageOverlay } catch { Write-SessionIconError $_ } })
    $script:UsageOverlayTimer.Start()
}

function Start-SessionIcons {
    for ($i = 0; $i -lt $SlotColors.Count; $i++) {
        $notify = New-Object System.Windows.Forms.NotifyIcon
        Set-NotifyIconId $notify ($script:TrayIconIds.Egg + $i)
        $notify.Icon = Get-SessionIcon $i
        $script:SessionIconColor[$i] = $i
        $script:SessionIconFrames[$i] = -1
        $notify.Text = Get-EggIconName $i
        $notify.Add_MouseClick({
            param($sender, $e)
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            Show-SessionWindow ([long]$sender.Tag)
            # Scriptblocks do not capture the loop's $i: the icon's place in the pool gives the color it paints.
            try { Show-SessionGlow ([long]$sender.Tag) $SlotColors[$script:SessionIconColor[[array]::IndexOf($script:SessionIcons, $sender)]].Hex } catch { Write-SessionIconError $_ }
        })
        $script:SessionIcons += $notify
    }
    # First run with these ids: every egg shows right after the Claude icon and the usage bars (tray.ps1 shows those
    # before this), so Windows lays them out together. Later runs find their places remembered.
    $script:TrayIconsShownAt = Get-Date
    if (-not (Test-TrayIconsPlaced)) { foreach ($notify in $script:SessionIcons) { $notify.Visible = $true } }
    $script:SessionAnimTimer = New-Object System.Windows.Forms.Timer
    $script:SessionAnimTimer.Interval = 120
    $script:SessionAnimTimer.Add_Tick({ try { Step-SessionIconAnimation } catch { Write-SessionIconError $_ } })
    # Every second: sessions opened or closed, and which ones started or stopped working.
    $script:SessionIconTimer = New-Object System.Windows.Forms.Timer
    $script:SessionIconTimer.Interval = 1000
    $script:SessionIconTimer.Add_Tick({ try { Update-SessionIcons } catch { Write-SessionIconError $_ } })
    try { Update-SessionIcons } catch { Write-SessionIconError $_ }
    $script:SessionIconTimer.Start()
}

# Same error every 3 s is written once.
function Write-SessionIconError($ErrorRecord) {
    $text = "$ErrorRecord | $($ErrorRecord.InvocationInfo.PositionMessage)"
    if ($text -eq $script:SessionIconLastError) { return }
    $script:SessionIconLastError = $text
    try { [IO.File]::AppendAllText((Join-Path $TrayHome 'traysessions.log'), ((Get-Date).ToString('s') + ' ' + $text + "`r`n")) } catch { }
}

# ---------------------------------------------------------------- egg strip
# The eggs off the taskbar (Claude Code > Huevos in the window): a strip stuck to one edge of the main screen's work
# area, so outside the taskbar, in a column on the sides and a row at the top or bottom. Dragged with the mouse it
# only slides along that edge; a click on an egg brings its terminal forward, as on the taskbar.
# shortcut: main screen only; a place per screen if someone wants them on another monitor.
$EggDockFile = Join-Path $TrayHome 'eggs-dock.json'
$EggDockEdges = @('taskbar', 'left', 'right', 'top', 'bottom')
$script:EggDock = $null
$script:EggStrip = $null
$script:EggStripShown = $false
$script:EggStripItems = @()
$script:EggStripOrder = @{}
$script:EggStripHover = -1
$script:EggStripDrag = $null

# Edge and place along it (0 = top or left end, 1 = the other end), read once.
function Get-EggDock {
    if (-not $script:EggDock) {
        $saved = Read-JsonFile $EggDockFile
        $edge = if ($saved -and $EggDockEdges -contains [string]$saved.edge) { [string]$saved.edge } else { 'taskbar' }
        $offset = if ($saved -and $null -ne $saved.offset) { [Math]::Min(1.0, [Math]::Max(0.0, [double]$saved.offset)) } else { 0.5 }
        $script:EggDock = @{ Edge = $edge; Offset = $offset }
    }
    $script:EggDock
}

function Set-EggDock([string]$Edge, $Offset) {
    $dock = Get-EggDock
    if ($Edge) { $dock.Edge = $Edge }
    if ($null -ne $Offset) { $dock.Offset = [double]$Offset }
    Write-JsonFile $EggDockFile ([ordered]@{ edge = $dock.Edge; offset = [Math]::Round($dock.Offset, 4) })
    if ($script:SessionIcons.Count) { try { Update-SessionIcons } catch { Write-SessionIconError $_ } }
}

function Test-EggDockVertical { (Get-EggDock).Edge -eq 'left' -or (Get-EggDock).Edge -eq 'right' }
# Grip: the empty handle before the first egg, to drag the strip without pressing on any egg.
function Get-EggStripMetrics { @{ Cell = (Px 34); Pad = (Px 4); Egg = (Px 26); Grip = (Px 16) } }
function Get-EggStripArea { [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }

# The strip's rectangle: a $Grip handle and $Count cells of $Cell px, $Pad around, against $Edge of $Area,
# $Offset along it.
function Get-EggStripBounds($Area, [string]$Edge, [double]$Offset, [int]$Count, [int]$Cell, [int]$Pad, [int]$Grip = 0) {
    $long = $Grip + $Count * $Cell + 2 * $Pad
    $thick = $Cell + 2 * $Pad
    if ($Edge -eq 'left' -or $Edge -eq 'right') {
        $x = if ($Edge -eq 'left') { $Area.Left } else { $Area.Right - $thick }
        return New-Object System.Drawing.Rectangle($x, ($Area.Top + [int][Math]::Round(($Area.Height - $long) * $Offset)), $thick, $long)
    }
    $y = if ($Edge -eq 'top') { $Area.Top } else { $Area.Bottom - $thick }
    New-Object System.Drawing.Rectangle(($Area.Left + [int][Math]::Round(($Area.Width - $long) * $Offset)), $y, $long, $thick)
}

# The offset that puts the strip's start at $Start along its edge, kept inside the area.
function Get-EggStripOffset($Area, [string]$Edge, [int]$Start, [int]$Long) {
    $vertical = $Edge -eq 'left' -or $Edge -eq 'right'
    $areaStart = if ($vertical) { $Area.Top } else { $Area.Left }
    $free = $(if ($vertical) { $Area.Height } else { $Area.Width }) - $Long
    if ($free -le 0) { return 0.5 }
    [Math]::Min(1.0, [Math]::Max(0.0, ($Start - $areaStart) / $free))
}

# Eggs drawn at the strip's size, each color, frame and state once.
$script:EggBitmapCache = @{}
function Get-SessionEggBitmap([int]$Color, [int]$Frame, [bool]$Speaking, [int]$Size) {
    $key = "$Color/$Frame/$Speaking/$Size"
    if (-not $script:EggBitmapCache.ContainsKey($key)) {
        $hex = $SlotColors[$Color].Hex
        $script:EggBitmapCache[$key] = if ($Speaking) { New-SpeakingIconBitmap $hex $Size $Frame } else { New-SessionIconBitmap $hex $Size $Frame }
    }
    $script:EggBitmapCache[$key]
}

function New-EggStrip {
    Initialize-SessionWindowApi
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.TopMost = $true
    $form.BackColor = $script:Palette.Back
    Enable-DoubleBuffer $form
    $handle = $form.Handle
    # WS_EX_TOOLWINDOW (not in Alt+Tab) | WS_EX_NOACTIVATE: a click does not take the focus from the terminals.
    [void][ClaudeTray.SessionWindow]::SetWindowLong($handle, -20, ([ClaudeTray.SessionWindow]::GetWindowLong($handle, -20) -bor 0x80 -bor 0x8000000))
    Set-RoundedWindow $form $script:Palette.Border
    $script:EggStripTip = New-Object System.Windows.Forms.ToolTip
    $script:EggStripTip.ShowAlways = $true
    $form.Add_Paint({ param($s, $e) try { Draw-EggStrip $e.Graphics } catch { Write-SessionIconError $_ } })
    $form.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $script:EggStripDrag = @{ From = [System.Windows.Forms.Cursor]::Position; Bounds = $script:EggStripBounds; Moved = $false }
    })
    $form.Add_MouseMove({ param($s, $e) try { Move-EggStripMouse $e } catch { Write-SessionIconError $_ } })
    $form.Add_MouseUp({ param($s, $e) try { Complete-EggStripMouse $e } catch { Write-SessionIconError $_ } })
    $form.Add_MouseLeave({ try { Set-EggStripHover -1 } catch { Write-SessionIconError $_ } })
    $form
}

function Get-EggStripCell([int]$K, $M) {
    $along = $M.Pad + $M.Grip + $K * $M.Cell
    if (Test-EggDockVertical) { New-Rect $M.Pad $along $M.Cell $M.Cell } else { New-Rect $along $M.Pad $M.Cell $M.Cell }
}

function Draw-EggStrip($G) {
    $m = Get-EggStripMetrics
    $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # The grip: two rows of three dots across the strip, centered in the handle.
    $dot = [Math]::Max(2, (Px 3)); $step = Px 6
    $mid = $m.Pad + [int](($m.Grip + $m.Pad) / 2)
    $across = $m.Pad + [int]($m.Cell / 2)
    $brush = New-Object System.Drawing.SolidBrush($script:Palette.Faint)
    foreach ($a in -1, 0, 1) {
        foreach ($b in -0.5, 0.5) {
            $u = $across + $a * $step; $v = $mid + [int]($b * $step)
            $x = if (Test-EggDockVertical) { $u } else { $v }; $y = if (Test-EggDockVertical) { $v } else { $u }
            $G.FillEllipse($brush, ($x - [int]($dot / 2)), ($y - [int]($dot / 2)), $dot, $dot)
        }
    }
    $brush.Dispose()
    for ($k = 0; $k -lt $script:EggStripItems.Count; $k++) {
        $i = $script:EggStripItems[$k]
        $cell = Get-EggStripCell $k $m
        if ($k -eq $script:EggStripHover) { Fill-Round $G $cell (Px 6) $script:Palette.SurfaceHover }
        $speaking = $i -eq $script:SessionSpeaking
        $frame = if ($speaking) { $script:SessionSpeakFrame } else { [int]$script:SessionIconFrames[$i] }
        $egg = Get-SessionEggBitmap $script:SessionIconColor[$i] $frame $speaking $m.Egg
        $G.DrawImage($egg, ($cell.X + [int](($cell.Width - $m.Egg) / 2)), ($cell.Y + [int](($cell.Height - $m.Egg) / 2)), $m.Egg, $m.Egg)
    }
}

# Cell under a point of the strip, -1 for none.
function Get-EggStripIndexAt([System.Drawing.Point]$Point) {
    $m = Get-EggStripMetrics
    $along = if (Test-EggDockVertical) { $Point.Y } else { $Point.X }
    $k = [int][Math]::Floor(($along - $m.Pad - $m.Grip) / $m.Cell)
    if ($k -ge 0 -and $k -lt $script:EggStripItems.Count) { $k } else { -1 }
}

function Set-EggStripHover([int]$K) {
    if ($K -eq $script:EggStripHover -or -not $script:EggStrip) { return }
    $script:EggStripHover = $K
    $tip = if ($K -ge 0) { Format-SessionIconTip $script:EggStripOrder[$script:EggStripItems[$K]].Session } else { '' }
    $script:EggStripTip.SetToolTip($script:EggStrip, $tip)
    $script:EggStrip.Invalidate()
}

# Dragging slides the strip along its edge only; a few pixels of slack keep a click a click.
function Move-EggStripMouse($E) {
    $drag = $script:EggStripDrag
    if (-not $drag -or $E.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        $k = Get-EggStripIndexAt $E.Location
        # Off the eggs (the grip): the move cursor along the edge.
        $script:EggStrip.Cursor = if ($k -ge 0) { [System.Windows.Forms.Cursors]::Hand } elseif (Test-EggDockVertical) { [System.Windows.Forms.Cursors]::SizeNS } else { [System.Windows.Forms.Cursors]::SizeWE }
        Set-EggStripHover $k
        return
    }
    $now = [System.Windows.Forms.Cursor]::Position
    $vertical = Test-EggDockVertical
    $delta = if ($vertical) { $now.Y - $drag.From.Y } else { $now.X - $drag.From.X }
    if (-not $drag.Moved -and [Math]::Abs($delta) -lt (Px 4)) { return }
    $drag.Moved = $true
    Move-EggStripBy $drag $delta
}

# The strip at its place when pressed plus $Delta along its edge.
function Move-EggStripBy($Drag, [int]$Delta) {
    $vertical = Test-EggDockVertical
    $b = $Drag.Bounds
    $start = if ($vertical) { $b.Y + $Delta } else { $b.X + $Delta }
    (Get-EggDock).Offset = Get-EggStripOffset (Get-EggStripArea) (Get-EggDock).Edge $start $(if ($vertical) { $b.Height } else { $b.Width })
    Set-EggStripPlace
}

function Complete-EggStripMouse($E) {
    $drag = $script:EggStripDrag
    $script:EggStripDrag = $null
    if (-not $drag -or $E.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($drag.Moved) {
        # Where the mouse let go: the last moves may have been merged away before the release.
        $now = [System.Windows.Forms.Cursor]::Position
        Move-EggStripBy $drag $(if (Test-EggDockVertical) { $now.Y - $drag.From.Y } else { $now.X - $drag.From.X })
        Set-EggDock -Offset (Get-EggDock).Offset
        return
    }
    $k = Get-EggStripIndexAt $E.Location
    if ($k -lt 0) { return }
    $i = $script:EggStripItems[$k]
    $hwnd = [long]$script:EggStripOrder[$i].Session.Hwnd
    Show-SessionWindow $hwnd
    try { Show-SessionGlow $hwnd $SlotColors[$script:SessionIconColor[$i]].Hex } catch { Write-SessionIconError $_ }
}

function Set-EggStripPlace {
    $dock = Get-EggDock
    $m = Get-EggStripMetrics
    $b = Get-EggStripBounds (Get-EggStripArea) $dock.Edge $dock.Offset $script:EggStripItems.Count $m.Cell $m.Pad $m.Grip
    $script:EggStripBounds = $b
    # HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW: again every second, as other topmost windows come and go.
    [void][ClaudeTray.SessionWindow]::SetWindowPos($script:EggStrip.Handle, [IntPtr](-1), $b.X, $b.Y, $b.Width, $b.Height, 0x50)
    $script:EggStripShown = $true
}

function Hide-EggStrip {
    if (-not $script:EggStripShown) { return }
    [void][ClaudeTray.Native]::ShowWindow($script:EggStrip.Handle, 0)
    $script:EggStripShown = $false
}

# Every second, after the icons: which eggs it shows, in the order of their terminals (top to bottom in a column,
# left to right in a row), and where.
function Update-EggStrip($Order) {
    $script:EggStripOrder = $Order
    $vertical = Test-EggDockVertical
    $script:EggStripItems = @($Order.Keys | Sort-Object @{ Expression = { if ($vertical) { $Order[$_].Top } else { $Order[$_].Left } } },
        @{ Expression = { if ($vertical) { $Order[$_].Left } else { $Order[$_].Top } } })
    if ((Get-EggDock).Edge -eq 'taskbar' -or -not $script:EggStripItems.Count) { Hide-EggStrip; return }
    if (-not $script:EggStrip) { $script:EggStrip = New-EggStrip }
    if (-not $script:EggStripDrag) { Set-EggStripPlace }
    $script:EggStrip.Invalidate()
}

function Stop-SessionIcons {
    if ($script:SessionIconTimer) { $script:SessionIconTimer.Stop() }
    if ($script:SessionAnimTimer) { $script:SessionAnimTimer.Stop() }
    Stop-SessionGlow
    if ($script:EggStrip) { $script:EggStrip.Dispose(); $script:EggStrip = $null; $script:EggStripShown = $false }
    foreach ($notify in $script:SessionIcons) { $notify.Visible = $false; $notify.Dispose() }
    $script:SessionIcons = @()
}
