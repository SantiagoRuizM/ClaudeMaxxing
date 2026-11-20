# Screen recording for Win+Alt+C in video mode (lib\snipcapture.ps1), like the Windows snipping tool: a frame
# around the area and a bar with Iniciar (a 3, 2, 1 countdown, then recording), Pausa, Detener and Descartar. Both
# stay out of the video (WDA_EXCLUDEFROMCAPTURE) and the frame lets clicks through. The recorder is
# ClaudeTray.SnipRecorder (lib\snip.cs): H.264 in MP4 with the pointer, plus a few frames as PNG for Claude. Detener
# (or the hotkey again) opens the corner box with the video for the prompt.

$script:SnipRecording = $null

# $Area: physical screen pixels; called with the thread per-monitor DPI aware (the capture is still open).
function Start-SnipRecording([System.Drawing.Rectangle]$Area) {
    Initialize-SnipDir
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $video = Join-Path $SnipDir "video-$stamp.mp4"
    $recorder = New-Object ClaudeTray.SnipRecorder($Area.X, $Area.Y, $Area.Width, $Area.Height, $video, (Join-Path $SnipDir "video-$stamp"), 24)
    $rec = @{ Recorder = $recorder; Area = $Area; State = 'ready'; Count = 0 }
    $script:SnipRecording = $rec
    $rec.Frame = New-SnipRecordFrame $Area
    $rec.Bar = New-SnipRecordBar $Area
    $rec.Timer = New-Object System.Windows.Forms.Timer
    $rec.Timer.Interval = 250
    $rec.Timer.Add_Tick({ try { Update-SnipRecording } catch { Write-SnipLog $_.Exception.Message } })
    $rec.Frame.Show()
    $rec.Bar.Show()
    [ClaudeTray.SnipWindow]::ClickThrough($rec.Frame.Handle)
    [ClaudeTray.SnipWindow]::HideFromCapture($rec.Frame.Handle)
    [ClaudeTray.SnipWindow]::HideFromCapture($rec.Bar.Handle)
    Set-RoundedWindow $rec.Bar $script:Palette.Border
    Set-SnipForeground $rec.Bar
    Update-SnipRecordBar
}

# A see-through window with the accent frame around the area (and the countdown in its middle).
function New-SnipRecordFrame([System.Drawing.Rectangle]$Area) {
    $form = New-SnipForm
    $key = [System.Drawing.Color]::FromArgb(255, 0, 255)
    $form.BackColor = $key
    $form.TransparencyKey = $key
    $edge = 3
    $form.Location = New-Object System.Drawing.Point(($Area.X - $edge), ($Area.Y - $edge))
    $form.ClientSize = New-Object System.Drawing.Size(($Area.Width + 2 * $edge), ($Area.Height + 2 * $edge))
    $form.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $rec = $script:SnipRecording
        $color = if ($rec -and $rec.State -eq 'recording' -and -not $rec.Recorder.Paused) { New-Rgb 232 69 60 } else { $script:Palette.Accent }
        $pen = New-Object System.Drawing.Pen($color, 2)
        $g.DrawRectangle($pen, 1, 1, ($sender.ClientSize.Width - 3), ($sender.ClientSize.Height - 3))
        $pen.Dispose()
        if ($rec -and $rec.State -eq 'countdown') {
            # No antialiasing: the transparency key would leave a pink fringe.
            $size = 120
            $box = New-Rect ([int](($sender.ClientSize.Width - $size) / 2)) ([int](($sender.ClientSize.Height - $size) / 2)) $size $size
            $brush = New-Object System.Drawing.SolidBrush((New-Rgb 32 32 32))
            $g.FillRectangle($brush, $box)
            $brush.Dispose()
            $font = New-UiFont 'Segoe UI Semibold' 40
            $flags = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPadding'
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
            [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$rec.Count, $font, $box, [System.Drawing.Color]::White, $flags)
            $font.Dispose()
        }
    })
    $form
}

function New-SnipBarButton([string]$Glyph, [string]$Tip, [scriptblock]$Click, [int]$X) {
    $button = New-SnipGlyphButton $Glyph $Tip $Click (Px 36)
    $button.Font = Get-SnipIconFont 12
    $button.ForeColor = $script:Palette.Text
    $button.Add_MouseLeave({ $this.ForeColor = $(if ($this.Enabled) { $script:Palette.Text } else { $script:Palette.Faint }) })
    $button.Location = New-Object System.Drawing.Point($X, (Px 6))
    $button
}

# The bar: the time, the microphone and the speakers (chosen before Iniciar), Iniciar or Pausa, Detener and
# Descartar. Above the area, else below it, else inside it.
function New-SnipRecordBar([System.Drawing.Rectangle]$Area) {
    $form = New-SnipForm
    $w = Px 324
    $h = Px 48
    $form.ClientSize = New-Object System.Drawing.Size($w, $h)
    $screens = ConvertFrom-SnipRects ([ClaudeTray.SnipDesktop]::Screens()) 8 (New-Object System.Drawing.Point(0, 0))
    $work = $screens[0][1]
    foreach ($screen in $screens) { if ($screen[0].Contains((New-Object System.Drawing.Point(($Area.X + [int]($Area.Width / 2)), ($Area.Y + [int]($Area.Height / 2)))))) { $work = $screen[1] } }
    $x = [Math]::Max($work.X, [Math]::Min($work.Right - $w, $Area.X + [int](($Area.Width - $w) / 2)))
    $y = if ($Area.Y - $h - (Px 12) -ge $work.Y) { $Area.Y - $h - (Px 12) } elseif ($Area.Bottom + (Px 12) + $h -le $work.Bottom) { $Area.Bottom + (Px 12) } else { $Area.Y + (Px 12) }
    $form.Location = New-Object System.Drawing.Point($x, $y)

    $time = New-Object System.Windows.Forms.Label
    $time.Font = $script:Fonts.BodyStrong
    $time.ForeColor = $script:Palette.Text
    $time.TextAlign = 'MiddleLeft'
    $time.SetBounds((Px 14), 0, (Px 86), $h)
    $mic = New-SnipBarButton 'E720' (Tx 'Micr\u00f3fono') { Switch-SnipAudio 'microphone' } (Px 96)
    $speakers = New-SnipBarButton 'E767' (L 'Sonido del sistema') { Switch-SnipAudio 'systemAudio' } (Px 136)
    $main = New-SnipBarButton 'E768' (L 'Iniciar') { Switch-SnipRecording } (Px 192)
    $stop = New-SnipBarButton 'E71A' (L 'Detener') { Stop-SnipRecording } (Px 234)
    $discard = New-SnipBarButton 'E74D' (L 'Descartar') { Stop-SnipRecording -Discard } (Px 276)
    $line = New-Object System.Windows.Forms.Label
    $line.BackColor = $script:Palette.Border
    $line.SetBounds((Px 181), (Px 14), 1, ($h - (Px 28)))
    $form.Controls.AddRange(@($time, $mic, $speakers, $line, $main, $stop, $discard))
    $form.Tag = @{ Time = $time; Main = $main; Stop = $stop; Mic = $mic; Speakers = $speakers }
    $form.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { Stop-SnipRecording -Discard } })
    $form
}

# The microphone or the speakers on or off for the next recording (remembered in snip.json).
function Switch-SnipAudio([string]$Name) {
    $rec = $script:SnipRecording
    if (-not $rec -or $rec.State -ne 'ready') { return }
    $settings = Get-SnipSettings
    $on = if ($Name -eq 'microphone') { -not $settings.Microphone } else { -not $settings.SystemAudio }
    Set-SnipSetting $Name $on
    Update-SnipRecordBar
}

function Update-SnipRecordBar {
    $rec = $script:SnipRecording
    if (-not $rec) { return }
    $bar = $rec.Bar.Tag
    $tips = Get-SnipTips
    # The audio choices: lit when on, struck through when off; fixed once recording.
    $settings = Get-SnipSettings
    $ready = $rec.State -eq 'ready'
    $bar.Mic.Text = [string][char]$(if ($settings.Microphone) { 0xE720 } else { 0xEC54 })
    $bar.Speakers.Text = [string][char]$(if ($settings.SystemAudio) { 0xE767 } else { 0xE74F })
    foreach ($pair in @(@($bar.Mic, $settings.Microphone), @($bar.Speakers, $settings.SystemAudio))) {
        $pair[0].ForeColor = $(if (-not $ready) { $script:Palette.Faint } elseif ($pair[1]) { $script:Palette.Accent } else { $script:Palette.Muted })
        $pair[0].Cursor = $(if ($ready) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default })
    }
    $tips.SetToolTip($bar.Mic, $(if ($settings.Microphone) { Tx 'Micr\u00f3fono: s\u00ed' } else { Tx 'Micr\u00f3fono: no' }))
    $tips.SetToolTip($bar.Speakers, $(if ($settings.SystemAudio) { Tx 'Sonido del sistema: s\u00ed' } else { L 'Sonido del sistema: no' }))
    $red = New-Rgb 232 69 60
    switch ($rec.State) {
        'ready' { $bar.Time.Text = L 'Listo'; $bar.Time.ForeColor = $script:Palette.Text; $bar.Main.Text = [string][char]0xE768; $tips.SetToolTip($bar.Main, (L 'Iniciar')) }
        'countdown' { $bar.Time.Text = [string]$rec.Count; $bar.Time.ForeColor = $script:Palette.Accent }
        'recording' {
            $bar.Time.Text = ([string][char]0x25CF) + '  ' + (Format-SnipDuration $rec.Recorder.Elapsed)
            $bar.Time.ForeColor = $(if ($rec.Recorder.Paused) { $script:Palette.Muted } else { $red })
            $bar.Main.Text = [string][char]$(if ($rec.Recorder.Paused) { 0xE768 } else { 0xE769 })
            $tips.SetToolTip($bar.Main, $(if ($rec.Recorder.Paused) { L 'Reanudar' } else { L 'Pausa' }))
        }
    }
}

function Update-SnipRecording {
    $rec = $script:SnipRecording
    if (-not $rec) { return }
    if ($rec.State -eq 'countdown') {
        $rec.Count--
        if ($rec.Count -le 0) {
            $rec.State = 'recording'
            $rec.Timer.Interval = 250
            $settings = Get-SnipSettings
            $rec.Recorder.SystemAudio = $settings.SystemAudio
            $rec.Recorder.Microphone = $settings.Microphone
            $rec.Recorder.Start()
        }
        $rec.Frame.Invalidate()
    } elseif ($rec.State -eq 'recording' -and $rec.Recorder.Error) {
        Write-SnipLog ('recording failed: ' + $rec.Recorder.Error)
        Stop-SnipRecording
        return
    }
    Update-SnipRecordBar
}

# Iniciar (the countdown), then Pausa and Reanudar.
function Switch-SnipRecording {
    $rec = $script:SnipRecording
    if (-not $rec) { return }
    switch ($rec.State) {
        'ready' {
            $rec.State = 'countdown'
            $rec.Count = 3
            $rec.Timer.Interval = 1000
            $rec.Timer.Start()
            $rec.Frame.Invalidate()
        }
        'recording' { $rec.Recorder.Pause(-not $rec.Recorder.Paused); $rec.Frame.Invalidate() }
    }
    Update-SnipRecordBar
}

# Detener: the video goes to the corner box with its last frame. -Discard: nothing is kept.
function Stop-SnipRecording([switch]$Discard) {
    $rec = $script:SnipRecording
    if (-not $rec) { return }
    $script:SnipRecording = $null
    $rec.Timer.Stop()
    $rec.Timer.Dispose()
    $recorded = $rec.State -eq 'recording'
    $ok = $true
    if ($recorded) { $ok = $rec.Recorder.Stop() }
    $rec.Frame.Close()
    $rec.Bar.Close()
    $frames = @($rec.Recorder.Frames)
    if ($Discard -or -not $recorded -or -not $ok) {
        foreach ($file in @($rec.Recorder.OutputPath) + $frames) { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
        if ($recorded -and -not $ok) {
            Write-SnipLog ('recording failed: ' + $rec.Recorder.Error)
            if ($script:Notify) { $script:Notify.ShowBalloonTip(5000, 'ClaudeMaxxing', ((Tx 'No se pudo grabar el v\u00eddeo: ') + $rec.Recorder.Error), [System.Windows.Forms.ToolTipIcon]::Error) }
        }
        return
    }
    $thumb = if ($frames.Count) { Read-SnipBitmap $frames[-1] } else { $null }
    $video = @{ Path = $rec.Recorder.OutputPath; Frames = $frames; Duration = $rec.Recorder.Elapsed }
    [void](Save-SnipToLibrary -VideoPath $video.Path)
    Write-SnipLog ('recorded {0} ({1}, {2} frames)' -f $video.Path, (Format-SnipDuration $video.Duration), $frames.Count)
    Show-SnipBox $thumb -Video $video
    if ($rec.Recorder.AudioError -and $script:SnipBox) { Set-SnipHint $script:SnipBox.Tag ((L 'Sin audio: ') + $rec.Recorder.AudioError) }
}
