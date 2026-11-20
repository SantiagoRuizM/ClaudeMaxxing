# Win+Alt+C (lib\snip.ps1): the screen frozen under a 60 % black veil with a toolbar like the Windows snipping
# tool's, at the top of the screen with the mouse:
#   foto | video    rectangle, window, full screen or freeform (video: no freeform)
#   dibujar         a pen on the frozen screen (colors, undo, clear); what is drawn goes in the snip
#   color           a magnifier under the pointer; a click copies the color as #RRGGBB
#   texto           the dragged rectangle is read with the Windows OCR and its text copied
#   cerrar
# A photo snip is copied to the clipboard, like Windows does, and the prompt panel opens next to it (Enviar, Copiar,
# Guardar). A video area starts the recorder (lib\sniprecord.ps1). Everything works in physical pixels: the capture
# keeps the thread per-monitor DPI aware while it is open (restored in Register-SnipForm).

$script:SnipPenColors = @('#E8453C', '#F5C518', '#3FB950', '#3B82F6', '#FFFFFF')
# Stroke widths (before scaling): fine, medium, thick; the highlighter is four times as wide.
$script:SnipPenSizes = @(2.5, 5, 10)
$script:SnipShapes = [ordered]@{
    rect = @('F407', 'Rect\u00e1ngulo')
    window = @('E737', 'Ventana')
    screen = @('E740', 'Pantalla completa')
    free = @('F408', 'Forma libre')
}

# Flat x, y, w, h (and more per item, $Stride) from lib\snip.cs, as rectangles in the overlay's coordinates.
function ConvertFrom-SnipRects([int[]]$Flat, [int]$Stride, [System.Drawing.Point]$Origin) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i + $Stride -le $Flat.Count; $i += $Stride) {
        $rects = @()
        for ($j = $i; $j -lt $i + $Stride; $j += 4) { $rects += New-Rect ($Flat[$j] - $Origin.X) ($Flat[$j + 1] - $Origin.Y) $Flat[$j + 2] $Flat[$j + 3] }
        [void]$list.Add($rects)
    }
    , $list
}

function Start-SnipCapture {
    if ($script:SnipBox) { $script:SnipBox.Close() }
    if (-not (Get-SnipSettings).Enabled) { return }
    # Per-monitor pixels until the overlay closes: the screen shot, the windows and every mouse event in between.
    $old = [ClaudeTray.Native]::SetThreadDpiAwarenessContext([IntPtr]-4)
    try {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $shot = [ClaudeTray.SnipCanvas]::FromScreen($vs.X, $vs.Y, $vs.Width, $vs.Height)
        $titles = $null
        $handles = $null
        $windows = ConvertFrom-SnipRects ([ClaudeTray.SnipDesktop]::Windows([ref]$titles, [ref]$handles)) 4 $vs.Location
        for ($i = 0; $i -lt $windows.Count; $i++) { $windows[$i] = @($windows[$i][0], $handles[$i]) }
        $screens = ConvertFrom-SnipRects ([ClaudeTray.SnipDesktop]::Screens()) 8 $vs.Location
        $cursor = [System.Windows.Forms.Cursor]::Position
        $cursor = New-Object System.Drawing.Point(($cursor.X - $vs.X), ($cursor.Y - $vs.Y))
        Show-SnipCapture $shot $vs.Location $screens $windows $cursor -DpiOld $old
    } catch {
        if ($old -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::SetThreadDpiAwarenessContext($old) }
        throw
    }
}

# The screen (bounds and work area) holding $Point, else the first one.
function Get-SnipScreenAt($State, [System.Drawing.Point]$Point) {
    foreach ($screen in $State.Screens) { if ($screen[0].Contains($Point)) { return $screen } }
    $State.Screens[0]
}

# The topmost window under the pointer: @(its frame, its handle), or $null.
function Get-SnipWindowAt($State, [System.Drawing.Point]$Point) {
    foreach ($window in $State.Windows) { if ($window[0].Contains($Point)) { return , $window } }
    $null
}

# What a click would snip in window or full-screen mode: the topmost window under the pointer (the screen when there
# is none), or the screen.
function Get-SnipHoverRect($State, [System.Drawing.Point]$Point) {
    $all = New-Rect 0 0 $State.Bright.Width $State.Bright.Height
    if ($State.Shape -eq 'window') {
        $window = Get-SnipWindowAt $State $Point
        if ($window) { return [System.Drawing.Rectangle]::Intersect($window[0], $all) }
    }
    (Get-SnipScreenAt $State $Point)[0]
}

# ---------------------------------------------------------------- the toolbar

# The toolbar's buttons where they go, with the shape menu and the pen colors when they are open.
function Get-SnipToolbar($State) {
    $screen = $State.ToolbarScreen
    $btn = Px 40
    $gap = Px 4
    $sep = Px 13
    $pad = Px 6
    $photo = $State.Kind -eq 'photo'
    $shape = $script:SnipShapes[$State.Shape]
    $spec = @(
        @{ Id = 'photo'; Glyph = 'E722'; Tip = (L 'Recorte'); Active = $photo }
        @{ Id = 'video'; Glyph = 'E714'; Tip = (Tx 'Grabar v\u00eddeo'); Active = (-not $photo) }
        @{ Id = '|' }
        @{ Id = 'shape'; Glyph = $shape[0]; Tip = ((L 'Forma: ') + (L (Ux $shape[1]))); Wide = $true; Active = [bool]$State.Menu }
        @{ Id = 'pen'; Glyph = 'E70F'; Tip = (L 'Dibujar en la pantalla'); Active = ($State.Tool -eq 'pen'); Enabled = $photo }
        @{ Id = '|' }
        @{ Id = 'color'; Glyph = 'EF3C'; Tip = (L 'Selector de color'); Active = ($State.Tool -eq 'color'); Enabled = $photo }
        @{ Id = 'text'; Glyph = 'E8AC'; Tip = (L 'Extraer texto'); Active = ($State.Tool -eq 'text'); Enabled = $photo }
        @{ Id = '|' }
        @{ Id = 'close'; Glyph = 'E711'; Tip = (L 'Cerrar (Esc)') }
    )
    $width = 2 * $pad
    foreach ($item in $spec) { $width += $(if ($item.Id -eq '|') { $sep } elseif ($item.Wide) { $btn + (Px 18) + $gap } else { $btn + $gap }) }
    $width -= $gap
    $bar = New-Rect ($screen.X + [int](($screen.Width - $width) / 2)) ($screen.Y + (Px 14)) $width ($btn + 2 * $pad)
    $items = New-Object System.Collections.ArrayList
    $seps = New-Object System.Collections.ArrayList
    $x = $bar.X + $pad
    foreach ($item in $spec) {
        if ($item.Id -eq '|') { [void]$seps.Add($x + [int](($sep - $gap) / 2) - (Px 2)); $x += $sep - $gap; continue }
        $w = if ($item.Wide) { $btn + (Px 18) } else { $btn }
        $item.Rect = New-Rect $x ($bar.Y + $pad) $w $btn
        if ($null -eq $item.Enabled) { $item.Enabled = $true }
        [void]$items.Add($item)
        $x += $w + $gap
    }
    $result = @{ Bar = $bar; Items = $items; Seps = $seps; Menu = $null; Pens = $null }
    if ($State.Menu) {
        $anchor = @($items | Where-Object { $_.Id -eq 'shape' })[0].Rect
        $rowH = Px 36
        $menuItems = New-Object System.Collections.ArrayList
        $menu = New-Rect $anchor.X ($bar.Bottom + (Px 6)) (Px 220) ($rowH * 4 + (Px 8))
        $y = $menu.Y + (Px 4)
        foreach ($key in $script:SnipShapes.Keys) {
            $enabled = -not ($key -eq 'free' -and -not $photo)
            [void]$menuItems.Add(@{ Id = "shape:$key"; Glyph = $script:SnipShapes[$key][0]; Label = (L (Ux $script:SnipShapes[$key][1])); Rect = (New-Rect ($menu.X + (Px 4)) $y ($menu.Width - (Px 8)) $rowH); Active = ($State.Shape -eq $key); Enabled = $enabled })
            $y += $rowH
        }
        $result.Menu = @{ Rect = $menu; Items = $menuItems }
    }
    if ($State.Tool -eq 'pen') {
        $size = Px 32
        $penItems = New-Object System.Collections.ArrayList
        $count = $script:SnipPenColors.Count + $script:SnipPenSizes.Count + 3
        $pens = New-Rect 0 ($bar.Bottom + (Px 6)) ($count * ($size + $gap) - $gap + 2 * $pad + (Px 18)) ($size + 2 * $pad)
        $pens.X = $bar.X + [int](($bar.Width - $pens.Width) / 2)
        $x = $pens.X + $pad
        for ($i = 0; $i -lt $script:SnipPenColors.Count; $i++) {
            [void]$penItems.Add(@{ Id = "pen:$i"; Color = $script:SnipPenColors[$i]; Rect = (New-Rect $x ($pens.Y + $pad) $size $size); Active = ($State.PenColor -eq $script:SnipPenColors[$i]); Enabled = $true; Tip = '' })
            $x += $size + $gap
        }
        $x += Px 9
        for ($i = 0; $i -lt $script:SnipPenSizes.Count; $i++) {
            [void]$penItems.Add(@{ Id = "size:$i"; Size = $script:SnipPenSizes[$i]; Rect = (New-Rect $x ($pens.Y + $pad) $size $size); Active = ($State.PenSize -eq $i); Enabled = $true; Tip = (L @('Fino', 'Medio', 'Grueso')[$i]) })
            $x += $size + $gap
        }
        $x += Px 9
        [void]$penItems.Add(@{ Id = 'marker'; Glyph = 'E7E6'; Rect = (New-Rect $x ($pens.Y + $pad) $size $size); Enabled = $true; Active = [bool]$State.Marker; Tip = (L 'Resaltador') })
        $x += $size + $gap
        [void]$penItems.Add(@{ Id = 'undo'; Glyph = 'E7A7'; Rect = (New-Rect $x ($pens.Y + $pad) $size $size); Enabled = ($State.Strokes.Count -gt 0); Tip = (L 'Deshacer (Ctrl+Z)') })
        $x += $size + $gap
        [void]$penItems.Add(@{ Id = 'clear'; Glyph = 'E74D'; Rect = (New-Rect $x ($pens.Y + $pad) $size $size); Enabled = ($State.Strokes.Count -gt 0); Tip = (L 'Borrar todo') })
        $result.Pens = @{ Rect = $pens; Items = $penItems }
    }
    $result
}

# The toolbar item under $Point; 'bar' over the toolbar's background (no snipping starts there); $null elsewhere.
function Find-SnipToolbarHit($Toolbar, [System.Drawing.Point]$Point) {
    foreach ($group in $Toolbar.Menu, $Toolbar.Pens) {
        if (-not $group) { continue }
        foreach ($item in $group.Items) { if ($item.Rect.Contains($Point)) { return $item } }
        if ($group.Rect.Contains($Point)) { return 'bar' }
    }
    foreach ($item in $Toolbar.Items) { if ($item.Rect.Contains($Point)) { return $item } }
    if ($Toolbar.Bar.Contains($Point)) { return 'bar' }
    $null
}

# Text with GDI+, not GDI: the toolbar is drawn once into a see-through image (Get-SnipToolbarImage), and GDI text
# would leave holes in its alpha channel.
function Draw-SnipLabel($G, [string]$Text, $Font, [System.Drawing.Color]$Color, [System.Drawing.Rectangle]$Rect, [string]$Align = 'Near') {
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = $Align
    $format.LineAlignment = 'Center'
    $format.FormatFlags = 'NoWrap'
    $format.Trimming = 'EllipsisCharacter'
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $G.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $G.DrawString($Text, $Font, $brush, [System.Drawing.RectangleF]$Rect, $format)
    $brush.Dispose()
    $format.Dispose()
}

function Draw-SnipGlyph($G, [string]$Glyph, $Font, [System.Drawing.Color]$Color, [System.Drawing.Rectangle]$Rect) {
    Draw-SnipLabel $G ([string][char][Convert]::ToInt32($Glyph, 16)) $Font $Color $Rect 'Center'
}

function Draw-SnipToolbar($G, $State) {
    $P = $script:Palette
    $tb = Get-SnipToolbarLayout $State
    $icon = $State.IconFont
    $back = New-Rgb 32 32 32
    $hover = New-Rgb 52 52 52
    $border = New-Rgb 70 70 70
    $text = New-Rgb 240 240 240
    $off = New-Rgb 110 110 110
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Fill-Round $G $tb.Bar (Px 10) $back
    Stroke-Round $G $tb.Bar (Px 10) $border
    # Foto and Video as one segmented control.
    $pair = [System.Drawing.Rectangle]::Union($tb.Items[0].Rect, $tb.Items[1].Rect)
    Fill-Round $G $pair (Px 6) (New-Rgb 40 40 40)
    $pen = New-Object System.Drawing.Pen($border)
    foreach ($x in $tb.Seps) { $G.DrawLine($pen, $x, ($tb.Bar.Y + (Px 12)), $x, ($tb.Bar.Bottom - (Px 12))) }
    $pen.Dispose()
    foreach ($item in $tb.Items) {
        $r = $item.Rect
        if ($item.Enabled -and ($item.Active -or $State.HoverId -eq $item.Id)) { Fill-Round $G $r (Px 6) $(if ($item.Active) { New-Rgb 58 58 58 } else { $hover }) }
        $color = if (-not $item.Enabled) { $off } else { $text }
        if ($item.Id -eq 'shape') {
            Draw-SnipGlyph $G $item.Glyph $icon $color (New-Rect $r.X $r.Y ($r.Width - (Px 18)) $r.Height)
            Draw-SnipGlyph $G 'E70D' $State.SmallIconFont $color (New-Rect ($r.Right - (Px 22)) $r.Y (Px 18) $r.Height)
        } else { Draw-SnipGlyph $G $item.Glyph $icon $color $r }
        if ($item.Active -and $item.Id -ne 'shape') { Fill-Round $G (New-Rect ($r.X + (Px 12)) ($r.Bottom - (Px 5)) ($r.Width - (Px 24)) (Px 3)) (Px 2) $P.Accent }
    }
    if ($tb.Menu) {
        Fill-Round $G $tb.Menu.Rect (Px 8) $back
        Stroke-Round $G $tb.Menu.Rect (Px 8) $border
        foreach ($item in $tb.Menu.Items) {
            $r = $item.Rect
            if ($item.Enabled -and ($State.HoverId -eq $item.Id -or $item.Active)) { Fill-Round $G $r (Px 6) $(if ($State.HoverId -eq $item.Id) { $hover } else { New-Rgb 44 44 44 }) }
            $color = if ($item.Enabled) { $text } else { $off }
            Draw-SnipGlyph $G $item.Glyph $State.SmallIconFont $color (New-Rect ($r.X + (Px 6)) $r.Y (Px 28) $r.Height)
            Draw-SnipLabel $G $item.Label $script:Fonts.Body $color (New-Rect ($r.X + (Px 40)) $r.Y ($r.Width - (Px 44)) $r.Height)
            if ($item.Active) { Fill-Round $G (New-Rect ($r.X + (Px 1)) ($r.Y + (Px 10)) (Px 3) ($r.Height - (Px 20))) (Px 2) $P.Accent }
        }
    }
    if ($tb.Pens) {
        Fill-Round $G $tb.Pens.Rect (Px 10) $back
        Stroke-Round $G $tb.Pens.Rect (Px 10) $border
        foreach ($item in $tb.Pens.Items) {
            $r = $item.Rect
            if ($item.Size) {
                if ($item.Active -or $State.HoverId -eq $item.Id) { Fill-Round $G $r (Px 6) $(if ($item.Active) { New-Rgb 58 58 58 } else { $hover }) }
                $d = [Math]::Max(3, (Px $item.Size)) + 2
                $dotBrush = New-Object System.Drawing.SolidBrush($(if ($item.Active) { $script:Palette.Accent } else { $text }))
                $G.FillEllipse($dotBrush, ($r.X + ($r.Width - $d) / 2), ($r.Y + ($r.Height - $d) / 2), $d, $d)
                $dotBrush.Dispose()
            } elseif ($item.Color) {
                if ($item.Active -or $State.HoverId -eq $item.Id) { Fill-Round $G $r (Px 6) $hover }
                $swatch = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($item.Color))
                $dot = New-Rect ($r.X + (Px 8)) ($r.Y + (Px 8)) ($r.Width - (Px 16)) ($r.Height - (Px 16))
                $G.FillEllipse($swatch, $dot)
                $swatch.Dispose()
                if ($item.Active) { $ring = New-Object System.Drawing.Pen($text, 2); $G.DrawEllipse($ring, ($dot.X - 3), ($dot.Y - 3), ($dot.Width + 6), ($dot.Height + 6)); $ring.Dispose() }
            } else {
                if ($item.Enabled -and ($item.Active -or $State.HoverId -eq $item.Id)) { Fill-Round $G $r (Px 6) $(if ($item.Active) { New-Rgb 58 58 58 } else { $hover }) }
                Draw-SnipGlyph $G $item.Glyph $State.SmallIconFont $(if (-not $item.Enabled) { $off } elseif ($item.Active) { $script:Palette.Accent } else { $text }) $r
            }
        }
    }
    # The tooltip of the button under the pointer, under the toolbar (or the pen colors).
    $tip = $null
    foreach ($item in @($tb.Items) + @(if ($tb.Pens) { $tb.Pens.Items })) { if ($item.Id -eq $State.HoverId -and $item.Tip) { $tip = $item } }
    if ($tip -and -not $tb.Menu) {
        $w = [int]$G.MeasureString($tip.Tip, $script:Fonts.Small).Width + (Px 16)
        $top = $(if ($tb.Pens) { $tb.Pens.Rect.Bottom } else { $tb.Bar.Bottom }) + (Px 6)
        $box = New-Rect ($tip.Rect.X + [int](($tip.Rect.Width - $w) / 2)) $top $w (Px 24)
        Fill-Round $G $box (Px 5) $back
        Stroke-Round $G $box (Px 5) $border
        Draw-SnipLabel $G $tip.Tip $script:Fonts.Small $text $box 'Center'
    }
}

# The toolbar's layout, worked out again only when something it shows changes: PowerShell takes about 10 ms for it,
# and the hit test runs on every mouse move.
function Get-SnipToolbarLayout($State) {
    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $State.Kind, $State.Shape, $State.Tool, $State.Menu, $State.PenColor, $State.PenSize, $State.Marker, ($State.Strokes.Count -gt 0)
    if ($State.LayoutKey -ne $key) { $State.Layout = Get-SnipToolbar $State; $State.LayoutKey = $key }
    $State.Layout
}

# The toolbar (with its menu, pen bar and tooltip) drawn once into an image and reused on every paint: drawing it
# takes PowerShell about 50 ms, too slow to repeat while the mouse drags.
function Get-SnipToolbarImage($State) {
    [void](Get-SnipToolbarLayout $State)
    $key = '{0}|{1}' -f $State.LayoutKey, $State.HoverId
    if ($State.ToolbarImage -and $State.ToolbarImage.Key -eq $key) { return $State.ToolbarImage }
    if ($State.ToolbarImage) { $State.ToolbarImage.Bitmap.Dispose() }
    $area = Get-SnipToolbarArea $State
    $bitmap = New-Object System.Drawing.Bitmap($area.Width, $area.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.TranslateTransform(-$area.X, -$area.Y)
    Draw-SnipToolbar $g $State
    $g.Dispose()
    $State.ToolbarImage = @{ Key = $key; Area = $area; Bitmap = $bitmap }
    $State.ToolbarImage
}

# The area the toolbar, its menu, the pen bar and the tooltip can paint on (repainted when they change).
function Get-SnipToolbarArea($State) {
    $tb = Get-SnipToolbarLayout $State
    $area = $tb.Bar
    if ($tb.Menu) { $area = [System.Drawing.Rectangle]::Union($area, $tb.Menu.Rect) }
    if ($tb.Pens) { $area = [System.Drawing.Rectangle]::Union($area, $tb.Pens.Rect) }
    $area.Inflate((Px 120), (Px 4))
    $area.Height += Px 40
    $area
}

function Invoke-SnipToolbarItem([System.Windows.Forms.Form]$Form, [string]$Id) {
    $s = $Form.Tag
    switch -Regex ($Id) {
        '^photo$' { if ($s.Kind -ne 'photo') { $s.Kind = 'photo'; Reset-SnipSelection $Form } }
        '^video$' {
            if ($s.Kind -ne 'video') {
                $s.Kind = 'video'; $s.Tool = $null
                if ($s.Shape -eq 'free') { $s.Shape = 'rect' }
                Reset-SnipSelection $Form
            }
        }
        '^shape$' { $s.Menu = -not $s.Menu }
        '^shape:' {
            $shape = $Id.Substring(6)
            if ($shape -eq 'free' -and $s.Kind -eq 'video') { return }
            $s.Shape = $shape; $s.Menu = $false
            if ($s.Tool -ne 'pen') { $s.Tool = $null }
            Reset-SnipSelection $Form
        }
        '^(pen|color|text)$' {
            if ($s.Kind -ne 'photo') { return }
            $s.Tool = $(if ($s.Tool -eq $Id) { $null } else { $Id })
            $s.Loupe = $null
            if ($Id -ne 'pen') { Reset-SnipSelection $Form }
        }
        '^pen:' { $s.PenColor = $script:SnipPenColors[[int]$Id.Substring(4)] }
        '^marker$' { $s.Marker = -not $s.Marker }
        '^size:' { $s.PenSize = [int]$Id.Substring(5) }
        '^undo$' { if ($s.Strokes.Count) { $s.Strokes.RemoveAt($s.Strokes.Count - 1) }; Update-SnipCopied $Form }
        '^clear$' { $s.Strokes.Clear(); Update-SnipCopied $Form }
        '^close$' { $Form.Close(); return }
    }
    if ($Id -ne 'shape') { $s.Menu = $false }
    $Form.Invalidate()
}

# ---------------------------------------------------------------- the selection

# Back to choosing: no selection, no panel.
function Reset-SnipSelection([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    $s.Region = [System.Drawing.Rectangle]::Empty
    $s.Free = $null
    $s.Hover = [System.Drawing.Rectangle]::Empty
    $s.OcrText = $null
    if ($s.WindowShot) { $s.WindowShot.Dispose() }
    $s.WindowShot = $null
    $s.WindowRect = $null
    if ($s.Panel) { $Form.Controls.Remove($s.Panel); $s.Panel.Dispose(); $s.Panel = $null }
    $s.Text = $null; $s.Combo = $null; $s.Hint = $null
    if ($s.Image) { $s.Image.Dispose(); $s.Image = $null }
}

# The freeform outline as a closed path, moved by ($DX, $DY).
function New-SnipFreePath($Points, [int]$DX = 0, [int]$DY = 0) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddPolygon($Points.ToArray())
    if ($DX -or $DY) {
        $move = New-Object System.Drawing.Drawing2D.Matrix
        $move.Translate($DX, $DY)
        $path.Transform($move)
        $move.Dispose()
    }
    $path
}

function Draw-SnipStrokes($G, $Strokes) {
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    foreach ($stroke in $Strokes) {
        $color = [System.Drawing.Color]::FromArgb($(if ($stroke.Alpha) { $stroke.Alpha } else { 255 }), [System.Drawing.ColorTranslator]::FromHtml($stroke.Color))
        $points = $stroke.Points.ToArray()
        if ($points.Count -lt 2) {
            $brush = New-Object System.Drawing.SolidBrush($color)
            $G.FillEllipse($brush, ($points[0].X - $stroke.Width / 2), ($points[0].Y - $stroke.Width / 2), $stroke.Width, $stroke.Width)
            $brush.Dispose()
            continue
        }
        $pen = New-Object System.Drawing.Pen($color, $stroke.Width)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $G.DrawLines($pen, $points)
        $pen.Dispose()
    }
}

# The selection as an image: the frozen screen inside it (transparent outside a freeform outline) with what was drawn.
# A window is its own image (CaptureWindow), whole even where others covered it or it went past the screen's edge.
function Update-SnipCaptureImage([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    $r = $s.Region
    if ($r.Width -lt 1 -or $r.Height -lt 1) { return }
    if ($s.Image) { $s.Image.Dispose() }
    if ($s.WindowShot) {
        $w = $s.WindowRect
        $image = New-Object System.Drawing.Bitmap($w.Width, $w.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($image)
        $g.DrawImage($s.WindowShot, 0, 0, $w.Width, $w.Height)
        $g.TranslateTransform(-$w.X, -$w.Y)
        Draw-SnipStrokes $g $s.Strokes
        $g.Dispose()
        $s.Image = $image
        return
    }
    $image = New-Object System.Drawing.Bitmap($r.Width, $r.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($image)
    if ($s.Free) {
        $path = New-SnipFreePath $s.Free (-$r.X) (-$r.Y)
        $g.SetClip($path)
        $path.Dispose()
    }
    $g.DrawImage($s.Bright, (New-Rect 0 0 $r.Width $r.Height), $r, [System.Drawing.GraphicsUnit]::Pixel)
    $g.TranslateTransform(-$r.X, -$r.Y)
    Draw-SnipStrokes $g $s.Strokes
    $g.Dispose()
    $s.Image = $image
}

# After drawing on a snip already taken: the clipboard gets the new version.
function Update-SnipCopied([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    if (-not $s.Panel -or $s.OcrText -or $s.Kind -ne 'photo') { return }
    Update-SnipCaptureImage $Form
    try { [System.Windows.Forms.Clipboard]::SetImage($s.Image); $script:SnipSeq = [ClaudeTray.Native]::GetClipboardSequenceNumber() } catch { }
}

# A rectangle, window, screen or outline was chosen.
function Complete-SnipCapture([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    $all = New-Rect 0 0 $s.Bright.Width $s.Bright.Height
    $s.Region = [System.Drawing.Rectangle]::Intersect($s.Region, $all)
    if ($s.Region.Width -lt 4 -or $s.Region.Height -lt 4) { Reset-SnipSelection $Form; $Form.Invalidate(); return }
    if ($s.Kind -eq 'video') {
        $area = $s.Region
        $area.Offset($s.Origin)
        $Form.Hide()
        Start-SnipRecording $area
        $Form.Close()
        return
    }
    Update-SnipCaptureImage $Form
    $ocr = $null
    if ($s.Tool -eq 'text') {
        try { $ocr = Get-SnipText $s.Image } catch { Write-SnipLog $_.Exception.Message; $ocr = '' }
        $s.OcrText = $ocr
    }
    try {
        if ($s.Tool -eq 'text') { if ($ocr) { [System.Windows.Forms.Clipboard]::SetText($ocr) } }
        else { [System.Windows.Forms.Clipboard]::SetImage($s.Image) }
        $script:SnipSeq = [ClaudeTray.Native]::GetClipboardSequenceNumber()
    } catch { }
    if ($s.Tool -ne 'text') { [void](Save-SnipToLibrary $s.Image) }
    Show-SnipCapturePanel $Form
    $Form.Invalidate()
}

# The prompt panel next to the selection, inside its screen's work area.
function Show-SnipCapturePanel([System.Windows.Forms.Form]$Form) {
    $s = $Form.Tag
    if ($s.Panel) { $Form.Controls.Remove($s.Panel); $s.Panel.Dispose() }
    $panel = New-Object System.Windows.Forms.Panel
    $pw = Px 420
    $panel.BackColor = $script:Palette.Back
    $panel.Cursor = [System.Windows.Forms.Cursors]::Default
    $panel.Add_Paint({
        param($sender, $e)
        $pen = New-Object System.Drawing.Pen($script:Palette.Border)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $pen.Dispose()
    })
    if ($s.Tool -eq 'text') {
        $title = if ($s.OcrText) { Tx 'TEXTO EXTRA\u00cdDO  \u00b7  COPIADO' } else { Tx 'TEXTO EXTRA\u00cdDO' }
        $fields = Add-SnipFields $panel $pw (Px 40) $title $s.OcrText -NoText:(-not $s.OcrText)
    } else {
        $fields = Add-SnipFields $panel $pw (Px 40) (Tx 'CAPTURA COPIADA  \u00b7  PARA CLAUDE CODE')
    }
    $panel.Size = New-Object System.Drawing.Size($pw, ($fields.Bottom + (Px 10)))
    $work = (Get-SnipScreenAt $s (New-Object System.Drawing.Point(($s.Region.X + [int]($s.Region.Width / 2)), ($s.Region.Y + [int]($s.Region.Height / 2)))))[1]
    $panel.Location = Get-SnipPanelPosition $s.Region $work $panel.Width $panel.Height (Px 12)
    $Form.Controls.Add($panel)
    $s.Panel = $panel
    $s.Text = $fields.Text; $s.Combo = $fields.Combo; $s.Hint = $fields.Hint
    if (-not $s.FolderCache) { $s.FolderCache = Get-SnipFormFolders }
    Set-SnipFolderList $s $s.FolderCache
    if ($Form.Visible) { Set-SnipCue $s.Text; [void]$s.Text.Focus() }
}

# ---------------------------------------------------------------- painting

function Draw-SnipLoupe($G, $State) {
    $p = $State.Loupe
    if ($null -eq $p) { return }
    $cells = 11
    $zoom = [Math]::Max(8, (Px 10))
    $size = $cells * $zoom
    $screen = (Get-SnipScreenAt $State $p)[0]
    $x = $p.X + (Px 22); $y = $p.Y + (Px 22)
    if ($x + $size -gt $screen.Right) { $x = $p.X - (Px 22) - $size }
    if ($y + $size + (Px 34) -gt $screen.Bottom) { $y = $p.Y - (Px 22) - $size - (Px 34) }
    $box = New-Rect $x $y $size $size
    $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $G.DrawImage($State.Bright, $box, (New-Rect ($p.X - 5) ($p.Y - 5) $cells $cells), [System.Drawing.GraphicsUnit]::Pixel)
    $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Default
    $white = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
    $G.DrawRectangle($white, $box)
    $G.DrawRectangle($white, ($box.X + 5 * $zoom), ($box.Y + 5 * $zoom), $zoom, $zoom)
    $white.Dispose()
    $c = $State.Bright.GetPixel([Math]::Max(0, [Math]::Min($State.Bright.Width - 1, $p.X)), [Math]::Max(0, [Math]::Min($State.Bright.Height - 1, $p.Y)))
    $label = New-Rect $x ($y + $size + (Px 6)) $size (Px 28)
    Fill-Round $G $label (Px 5) (New-Rgb 32 32 32)
    $swatch = New-Object System.Drawing.SolidBrush($c)
    $G.FillRectangle($swatch, ($label.X + (Px 8)), ($label.Y + (Px 7)), (Px 14), (Px 14))
    $swatch.Dispose()
    Draw-Text $G ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) $script:Fonts.BodyStrong (New-Rgb 240 240 240) ($label.X + (Px 28)) $label.Y ($label.Width - (Px 32)) $label.Height
}

function Get-SnipLoupeArea($State, $Point) {
    if ($null -eq $Point) { return [System.Drawing.Rectangle]::Empty }
    $size = 11 * [Math]::Max(8, (Px 10)) + (Px 80)
    New-Rect ($Point.X - $size) ($Point.Y - $size) (2 * $size) (2 * $size)
}

function Draw-SnipCapture($G, $State, [System.Drawing.Rectangle]$Clip) {
    $State.Canvas.Draw($G, $Clip, $false)
    $accent = New-Object System.Drawing.Pen($script:Palette.Accent, 2)
    if ($State.Free -and $State.Free.Count -gt 2) {
        $path = New-SnipFreePath $State.Free
        $G.SetClip($path)
        $G.DrawImage($State.Bright, $Clip, $Clip, [System.Drawing.GraphicsUnit]::Pixel)
        $G.ResetClip()
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $G.DrawPath($accent, $path)
        $path.Dispose()
    } else {
        $r = if ($State.Region.Width -gt 0) { $State.Region } else { $State.Hover }
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
            $clear = [System.Drawing.Rectangle]::Intersect($r, $Clip)
            if (-not $clear.IsEmpty) { $State.Canvas.Draw($G, $clear, $true) }
            $G.DrawRectangle($accent, ($r.X + 1), ($r.Y + 1), ($r.Width - 2), ($r.Height - 2))
        }
    }
    $accent.Dispose()
    if ($State.Strokes.Count) { Draw-SnipStrokes $G $State.Strokes }
    $toolbar = Get-SnipToolbarImage $State
    if ($Clip.IntersectsWith($toolbar.Area)) {
        $G.DrawImage($toolbar.Bitmap, $toolbar.Area, (New-Rect 0 0 $toolbar.Area.Width $toolbar.Area.Height), [System.Drawing.GraphicsUnit]::Pixel)
    }
    if ($State.Tool -eq 'color') { Draw-SnipLoupe $G $State }
}

# ---------------------------------------------------------------- the overlay

# $Shot: all the screens from $Origin (a ClaudeTray.SnipCanvas, or a picture for previews and tests); $Screens and $Windows (ConvertFrom-SnipRects) in the shot's coordinates;
# $Cursor: where the toolbar goes. $Render: @{ Path; Region; Tool; Shape; Kind; Menu; Strokes; Ocr; Loupe; Hover }.
function Show-SnipCapture($Shot, [System.Drawing.Point]$Origin, $Screens, $Windows, [System.Drawing.Point]$Cursor, [IntPtr]$DpiOld = [IntPtr]::Zero, $Render) {
    $form = New-SnipForm
    Enable-DoubleBuffer $form
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Cursor = [System.Windows.Forms.Cursors]::Cross
    $form.Location = $Origin
    $canvas = if ($Shot -is [ClaudeTray.SnipCanvas]) { $Shot } else { New-Object ClaudeTray.SnipCanvas($Shot); $Shot.Dispose() }
    $form.ClientSize = New-Object System.Drawing.Size($canvas.Width, $canvas.Height)
    $state = @{
        Bright = $canvas.Clear; Canvas = $canvas; Origin = $Origin; DpiOld = $DpiOld
        Screens = $Screens; Windows = $Windows; Kind = 'photo'; Shape = 'rect'; Tool = $null; Menu = $false
        Region = [System.Drawing.Rectangle]::Empty; Hover = [System.Drawing.Rectangle]::Empty; Free = $null; Drag = $null
        Strokes = New-Object System.Collections.ArrayList; PenColor = $script:SnipPenColors[0]; PenSize = 1; Marker = $false; Loupe = $null; HoverId = $null
        IconFont = (Get-SnipIconFont 13); SmallIconFont = (Get-SnipIconFont 10)
        Panel = $null; Image = $null; Text = $null; Combo = $null; Hint = $null; Folders = $null; Index = 0; Busy = $false
    }
    $state.ToolbarScreen = (Get-SnipScreenAt $state $Cursor)[0]
    $form.Tag = $state

    $form.Add_Paint({
        param($sender, $e)
        try { Draw-SnipCapture $e.Graphics $sender.Tag $e.ClipRectangle } catch { Write-SnipLog $_.Exception.Message }
    })
    $form.Add_MouseDown({
        param($sender, $e)
        try { Invoke-SnipMouseDown $sender $e } catch { Write-SnipLog $_.Exception.Message }
    })
    $form.Add_MouseMove({
        param($sender, $e)
        try { Invoke-SnipMouseMove $sender $e } catch { Write-SnipLog $_.Exception.Message }
    })
    $form.Add_MouseUp({
        param($sender, $e)
        try { Invoke-SnipMouseUp $sender $e } catch { Write-SnipLog $_.Exception.Message }
    })
    $form.Add_KeyDown({
        param($sender, $e)
        $s = $sender.Tag
        if ($e.KeyCode -eq 'Escape' -and $s.Menu) { $s.Menu = $false; $sender.Invalidate(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'Z' -and $s.Strokes.Count -and -not ($s.Text -and $s.Text.Focused)) {
            Invoke-SnipToolbarItem $sender 'undo'; $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })

    if ($Render) {
        foreach ($key in $Render.Keys) { if ($key -ne 'Path') { $state[$key] = $Render[$key] } }
        if ($state.Region.Width -gt 0) {
            Update-SnipCaptureImage $form
            if ($state.Tool -eq 'text') { $state.OcrText = $Render.Ocr }
            Show-SnipCapturePanel $form
        }
        Save-SnipRender $form $Render.Path
        return
    }
    # Esc as a global hotkey while the capture is open: it leaves even when Windows kept the keyboard focus on the
    # window in front (the snipping tool's Esc works the same way).
    $state.EscKey = New-Object ClaudeTray.SnipHotkey(0, 0x1B)
    if ($state.EscKey.Registered) { $state.EscKey.add_Pressed({ try { Invoke-SnipEscape } catch { Write-SnipLog $_.Exception.Message } }) }
    Register-SnipForm $form $false
}

# Esc: closes the shape menu if it is open, else the capture.
function Invoke-SnipEscape {
    $box = $script:SnipBox
    if (-not $box -or -not $box.Tag.Canvas) { return }
    if ($box.Tag.Menu) { $box.Tag.Menu = $false; $box.Invalidate(); return }
    $box.Close()
}

function Invoke-SnipMouseDown([System.Windows.Forms.Form]$Form, $E) {
    $s = $Form.Tag
    if ($E.Button -ne 'Left') { return }
    $hit = Find-SnipToolbarHit (Get-SnipToolbarLayout $s) $E.Location
    if ($s.Menu -and -not ($hit -is [hashtable] -and $hit.Id -like 'shape*')) {
        $s.Menu = $false
        $Form.Invalidate()
        if ($null -eq $hit) { return }
    }
    if ($hit -is [hashtable]) { if ($hit.Enabled) { Invoke-SnipToolbarItem $Form $hit.Id }; return }
    if ($hit) { return }
    if ($s.Tool -eq 'pen') {
        # The highlighter: a wide, see-through stroke.
        $width = [Math]::Max(2, (Px $script:SnipPenSizes[$s.PenSize]))
        $stroke = @{ Color = $s.PenColor; Width = $(if ($s.Marker) { 4 * $width } else { $width }); Alpha = $(if ($s.Marker) { 110 } else { 255 }); Points = (New-Object 'System.Collections.Generic.List[System.Drawing.Point]') }
        $stroke.Points.Add($E.Location)
        [void]$s.Strokes.Add($stroke)
        $s.Drag = 'pen'
        $Form.Invalidate((New-Rect ($E.X - 10) ($E.Y - 10) 20 20))
        return
    }
    if ($s.Tool -eq 'color') {
        $c = $s.Bright.GetPixel($E.X, $E.Y)
        $hex = '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
        try { [System.Windows.Forms.Clipboard]::SetText($hex); $script:SnipSeq = [ClaudeTray.Native]::GetClipboardSequenceNumber() } catch { }
        if ($script:Notify) { $script:Notify.ShowBalloonTip(3000, 'ClaudeMaxxing', ((L 'Color {0} copiado al portapapeles') -f $hex), [System.Windows.Forms.ToolTipIcon]::Info) }
        $Form.Close()
        return
    }
    Reset-SnipSelection $Form
    if ($s.Tool -ne 'text' -and $s.Shape -in 'window', 'screen') {
        $s.Region = Get-SnipHoverRect $s $E.Location
        $window = if ($s.Shape -eq 'window' -and $s.Kind -eq 'photo') { Get-SnipWindowAt $s $E.Location } else { $null }
        if ($window -and $window[1]) {
            try { $s.WindowShot = [ClaudeTray.SnipDesktop]::CaptureWindow($window[1]) } catch { $s.WindowShot = $null }
            if ($s.WindowShot) { $s.WindowRect = $window[0] }
        }
        Complete-SnipCapture $Form
        return
    }
    $s.DragStart = $E.Location
    if ($s.Tool -ne 'text' -and $s.Shape -eq 'free') {
        $s.Free = New-Object 'System.Collections.Generic.List[System.Drawing.Point]'
        $s.Free.Add($E.Location)
        $s.Region = New-Rect $E.X $E.Y 1 1
        $s.Drag = 'free'
    } else { $s.Drag = 'rect' }
    $Form.Invalidate()
}

function Invoke-SnipMouseMove([System.Windows.Forms.Form]$Form, $E) {
    $s = $Form.Tag
    $p = $E.Location
    switch ($s.Drag) {
        'pen' {
            $points = $s.Strokes[$s.Strokes.Count - 1].Points
            $last = $points[$points.Count - 1]
            if ($last -eq $p) { return }
            $points.Add($p)
            $dirty = Get-SnipRect $last $p
            $dirty.Inflate(12, 12)
            $Form.Invalidate($dirty)
            return
        }
        'rect' {
            $old = $s.Region
            $s.Region = Get-SnipRect $s.DragStart $p
            $dirty = [System.Drawing.Rectangle]::Union($old, $s.Region)
            $dirty.Inflate(4, 4)
            $Form.Invalidate($dirty)
            return
        }
        'free' {
            $last = $s.Free[$s.Free.Count - 1]
            if ([Math]::Abs($last.X - $p.X) + [Math]::Abs($last.Y - $p.Y) -lt 2) { return }
            $s.Free.Add($p)
            $old = $s.Region
            $s.Region = [System.Drawing.Rectangle]::Union($s.Region, (New-Rect $p.X $p.Y 1 1))
            $dirty = [System.Drawing.Rectangle]::Union($old, $s.Region)
            $dirty.Inflate(6, 6)
            $Form.Invalidate($dirty)
            return
        }
    }
    # Not dragging: the toolbar's hover, the pointer, the magnifier and what a click would snip.
    $hit = Find-SnipToolbarHit (Get-SnipToolbarLayout $s) $p
    $id = if ($hit -is [hashtable]) { $hit.Id } else { $null }
    if ($id -ne $s.HoverId) { $s.HoverId = $id; $Form.Invalidate((Get-SnipToolbarArea $s)) }
    $cursor = if ($hit) { [System.Windows.Forms.Cursors]::Default } else { [System.Windows.Forms.Cursors]::Cross }
    if ($Form.Cursor -ne $cursor) { $Form.Cursor = $cursor }
    if ($s.Tool -eq 'color') {
        $old = $s.Loupe
        $s.Loupe = if ($hit) { $null } else { $p }
        $Form.Invalidate((Get-SnipLoupeArea $s $old))
        $Form.Invalidate((Get-SnipLoupeArea $s $s.Loupe))
        return
    }
    if (-not $hit -and -not $s.Panel -and $s.Tool -ne 'pen' -and $s.Tool -ne 'text' -and $s.Shape -in 'window', 'screen') {
        $hover = Get-SnipHoverRect $s $p
        if ($hover -ne $s.Hover) {
            $old = $s.Hover
            $s.Hover = $hover
            $dirty = [System.Drawing.Rectangle]::Union($old, $hover)
            $dirty.Inflate(4, 4)
            $Form.Invalidate($dirty)
        }
    }
}

function Invoke-SnipMouseUp([System.Windows.Forms.Form]$Form, $E) {
    $s = $Form.Tag
    $drag = $s.Drag
    $s.Drag = $null
    switch ($drag) {
        'pen' { Update-SnipCopied $Form; $Form.Invalidate((Get-SnipToolbarArea $s)) }
        'rect' { Complete-SnipCapture $Form }
        'free' {
            if ($s.Free.Count -lt 3) { Reset-SnipSelection $Form; $Form.Invalidate(); return }
            Complete-SnipCapture $Form
        }
    }
}
