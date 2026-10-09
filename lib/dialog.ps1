# Claude-style "Agendar sesion" dialog: current-session status, quick time choices, where to run,
# and the list of scheduled / past sessions. Fully owner-drawn on a borderless form (the date and
# time pickers are steppers: click the arrows or use the mouse wheel). Needs theme.ps1, usage.ps1, schedule.ps1.

$script:CloudCardHeight = 106

function Show-ScheduleDialog([string]$RenderPath, [string]$PreviewCloud) {
    $P = $script:Palette
    $F = $script:Fonts
    $openedAt = Get-Date
    $view = Get-UsageView (Read-JsonFile $UsageFile) $openedAt
    $startScript = Join-Path $TrayRoot 'start-session.ps1'

    $W = 440
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = Tx 'Agendar sesi\u00f3n'
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.BackColor = $P.Back
    $dlg.KeyPreview = $true
    $dlg.TopMost = $true
    if ($script:Notify -and $script:Notify.Icon) { $dlg.Icon = $script:Notify.Icon }
    Enable-DoubleBuffer $dlg
    $dlg.Tag = New-HitMap
    Register-HitMap $dlg

    $state = @{ Choice = 'suggested'; Where = 'pc'; Message = ''; MessageKind = 'ok'; Rows = @(); Day = 0; Hour = 0; Minute = 0; Cloud = $null }

    # ---- quick choices
    $suggested = Get-DefaultScheduleTime $view $openedAt
    $inOneHour = $openedAt.AddMinutes(60 + (5 - $openedAt.Minute % 5))
    $inOneHour = $inOneHour.Date.AddHours($inOneHour.Hour).AddMinutes($inOneHour.Minute)
    $tomorrow = $openedAt.Date.AddDays(1).AddHours(7).AddMinutes(5)
    $suggestedLabel = if ($view.Session.Active) { 'Al terminar la actual' } else { Tx 'Pr\u00f3xima hora' }
    $choices = @(
        @{ Id = 'suggested'; Label = $suggestedLabel; At = $suggested },
        @{ Id = 'hour'; Label = 'En 1 hora'; At = $inOneHour },
        @{ Id = 'tomorrow'; Label = (Tx 'Ma\u00f1ana ') + $tomorrow.ToString('h:mm'); At = $tomorrow }
    )

    # ---- date/time steppers: day offset 0..7, hour 0..23, minute in 5-minute steps 0..11
    function Set-PickTime([datetime]$At) {
        $state.Day = [Math]::Max(0, [Math]::Min(7, ($At.Date - $openedAt.Date).Days))
        $state.Hour = $At.Hour
        $state.Minute = [int][Math]::Floor($At.Minute / 5)
    }
    function Get-PickTime {
        $openedAt.Date.AddDays($state.Day).AddHours($state.Hour).AddMinutes(5 * $state.Minute)
    }
    function Step-Pick([string]$Field, [int]$Delta) {
        switch ($Field) {
            'day'    { $state.Day = [Math]::Max(0, [Math]::Min(7, $state.Day + $Delta)) }
            'hour'   { $state.Hour = ($state.Hour + $Delta + 24) % 24 }
            'minute' { $state.Minute = ($state.Minute + $Delta + 12) % 12 }
        }
        $state.Choice = 'custom'; $state.Message = ''
        $dlg.Invalidate()
    }
    function Update-Rows {
        $state.Rows = @(Get-ScheduleRows (Get-SessionTasks) (Read-JsonFile $CloudFile) (Read-JsonFile $HistoryFile) (Get-Date))
        $rowsHeight = [Math]::Max(1, $state.Rows.Count) * 36
        $cloudHeight = if ($state.Cloud) { $script:CloudCardHeight + 14 } else { 0 }
        $dlg.ClientSize = New-Object System.Drawing.Size((Px $W), (Px (404 + $rowsHeight + 14 + $cloudHeight + 36 + 22)))
        $dlg.Invalidate()
    }
    $state.Fields = @{}
    Set-PickTime $suggested

    $dlg.Add_MouseWheel({
        param($sender, $e)
        foreach ($name in @($state.Fields.Keys)) {
            if ($state.Fields[$name].Contains($e.Location)) { Step-Pick $name ([Math]::Sign($e.Delta)); return }
        }
    })
    # ---- cloud routine progress: the worker updates cloud.json; poll it while the dialog is open
    $cloudTimer = New-Object System.Windows.Forms.Timer
    $cloudTimer.Interval = 400
    $cloudTimer.Add_Tick({
        $cloud = $state.Cloud
        if (-not $cloud) { $cloudTimer.Stop(); return }
        $request = Get-CloudRequest $cloud.Id
        if ($request -and $request.status -ne 'creating') {
            $cloud.Status = [string]$request.status
            $cloud.RoutineId = [string]$request.routineId
            $cloud.Error = [string]$request.error
            $cloudTimer.Stop()
            Update-Rows
        }
        $dlg.Invalidate()
    })
    $dlg.Add_FormClosed({ $cloudTimer.Stop(); $cloudTimer.Dispose() })

    # ---- actions
    $schedule = {
        $at = Get-PickTime
        if ($at -le (Get-Date).AddMinutes(1)) {
            $state.Message = 'Elige una hora en el futuro.'; $state.MessageKind = 'error'; $dlg.Invalidate(); return
        }
        try {
            if ($state.Where -eq 'pc') {
                New-SessionTask $at $startScript
                $state.Message = (Tx '\u2713 Agendada: ') + (Format-DialogDateTime $at (Get-Date))
            } else {
                if ($state.Cloud -and $state.Cloud.Status -eq 'creating') {
                    $state.Message = 'Espera a que termine la rutina en curso.'; $state.MessageKind = 'error'; $dlg.Invalidate(); return
                }
                $id = Add-CloudRequest $at
                if (-not (Test-Path -LiteralPath $RunsDir)) { New-Item -ItemType Directory -Force -Path $RunsDir | Out-Null }
                $worker = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -At {1} -Id {2}' -f `
                    (Join-Path $TrayRoot 'cloud-schedule.ps1'), $at.ToString('yyyy-MM-ddTHH:mm'), $id
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $worker -WorkingDirectory $RunsDir
                $state.Cloud = @{ Id = $id; At = $at; StartedAt = (Get-Date); Status = 'creating'; RoutineId = $null; Error = $null }
                $cloudTimer.Start()
                $state.Message = ''
            }
            $state.MessageKind = 'ok'
        } catch {
            $state.Message = "No se pudo agendar: $($_.Exception.Message)"; $state.MessageKind = 'error'
        }
        Update-Rows
    }

    $dlg.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.Close() } })

    # Drag the window by its header.
    $dlg.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Y -gt (Px 56)) { return }
        if (Find-Hit $sender.Tag $e.Location) { return }
        [void][ClaudeTray.Native]::ReleaseCapture()
        [void][ClaudeTray.Native]::SendMessage($sender.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    })

    $dlg.Add_HandleCreated({ param($sender, $e) Set-RoundedWindow $sender $script:Palette.Border })

    $logo = New-TintedLogo $P.Accent (Px 22)

    $dlg.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $map = $sender.Tag
        $map.Items.Clear()
        $hover = $map.Hover
        $now = Get-Date
        $left = Px 24
        $inner = Px ($W - 48)

        # header
        if ($logo) { $g.DrawImage($logo, $left, (Px 19)) }
        Draw-Text $g (Tx 'Agendar sesi\u00f3n') $F.Title $P.Text (Px 56) (Px 14) (Px 300) (Px 32)
        $close = New-Rect (Px ($W - 52)) (Px 16) (Px 30) (Px 30)
        if ($hover -eq 'close') { Fill-Round $g $close (Px 6) $P.SurfaceHover }
        Draw-Text $g (Tx '\u00d7') $F.Close $P.Muted $close.X $close.Y $close.Width $close.Height 'Center'
        Add-Hit $map 'close' $close { $dlg.Close() }

        # current session card
        $card = New-Rect $left (Px 62) $inner (Px 72)
        Fill-Round $g $card (Px 10) $P.Surface
        Draw-Text $g (Tx 'SESI\u00d3N ACTUAL') $F.Caps $P.Muted (Px 40) (Px 72) (Px 200) (Px 18)
        if ($view.Session.Active) {
            Draw-Text $g ("$($view.Session.Percent) % usado") $F.Small $P.Muted (Px 40) (Px 72) (Px ($W - 80)) (Px 18) 'Right'
            Draw-Text $g ('Termina a las ' + (Format-Clock $view.Session.ResetsAt)) $F.BodyStrong $P.Text (Px 40) (Px 92) (Px 260) (Px 22)
            Draw-Text $g ('en ' + (Format-Remaining ($view.Session.ResetsAt - $now))) $F.BodyStrong $P.Accent (Px 40) (Px 92) (Px ($W - 80)) (Px 22) 'Right'
            $track = New-Rect (Px 40) (Px 120) (Px ($W - 80)) (Px 4)
            Fill-Round $g $track (Px 2) $P.Track
            $fraction = Get-SessionElapsedFraction $view $now
            if ($fraction -gt 0) { Fill-Round $g (New-Rect $track.X $track.Y ([Math]::Max((Px 4), [int]($track.Width * $fraction))) $track.Height) (Px 2) $P.Accent }
        } else {
            Draw-Text $g 'Sin empezar' $F.BodyStrong $P.Text (Px 40) (Px 92) (Px 200) (Px 22)
            Draw-Text $g 'Empieza con el primer mensaje' $F.Small $P.Muted (Px 40) (Px 92) (Px ($W - 80)) (Px 22) 'Right'
            Draw-Text $g ('La ventana dura unas 5 h desde el primer mensaje.') $F.Small $P.Faint (Px 40) (Px 112) (Px ($W - 80)) (Px 16)
        }

        # when
        Draw-Text $g (Tx 'CU\u00c1NDO') $F.Caps $P.Muted $left (Px 146) (Px 200) (Px 18)
        $x = $left
        foreach ($choice in $choices) {
            $chipW = (Measure-TextWidth $choice.Label $F.Body) + (Px 26)
            $chip = New-Rect $x (Px 168) $chipW (Px 30)
            $selected = ($state.Choice -eq $choice.Id)
            if ($selected) {
                Fill-Round $g $chip (Px 15) $P.AccentTint
                Stroke-Round $g $chip (Px 15) $P.Accent
                $textColor = $P.Accent
            } else {
                $fill = if ($hover -eq $choice.Id) { $P.SurfaceHover } else { $P.Surface }
                Fill-Round $g $chip (Px 15) $fill
                $textColor = $P.Text
            }
            Draw-Text $g $choice.Label $F.Body $textColor $chip.X $chip.Y $chip.Width $chip.Height 'Center'
            $choiceId = $choice.Id
            $choiceAt = $choice.At
            Add-Hit $map $choiceId $chip ([scriptblock]::Create("`$state.Choice = '$choiceId'; `$state.Message = ''; Set-PickTime ([datetime]'$($choiceAt.ToString('s'))'); `$dlg.Invalidate()"))
            $x += $chipW + (Px 8)
        }

        # date/time steppers
        $pickAt = Get-PickTime
        $culture = [System.Globalization.CultureInfo]::CurrentCulture
        $fields = @(
            @{ Id = 'day'; X = 24; W = 184; Text = (Get-DayLabel $pickAt $now) },
            @{ Id = 'hour'; X = 216; W = 108; Text = $pickAt.ToString('h tt', $culture) },
            @{ Id = 'minute'; X = 332; W = 84; Text = $pickAt.ToString(':mm') }
        )
        foreach ($field in $fields) {
            $box = New-Rect (Px $field.X) (Px 208) (Px $field.W) (Px 32)
            $state.Fields[$field.Id] = $box
            Fill-Round $g $box (Px 8) $P.Surface
            $dec = New-Rect $box.X $box.Y (Px 28) $box.Height
            $inc = New-Rect ($box.Right - (Px 28)) $box.Y (Px 28) $box.Height
            foreach ($arrow in @(@{ Rect = $dec; Id = "$($field.Id)-dec"; Glyph = '\u2039'; Delta = -1 }, @{ Rect = $inc; Id = "$($field.Id)-inc"; Glyph = '\u203a'; Delta = 1 })) {
                if ($hover -eq $arrow.Id) { Fill-Round $g $arrow.Rect (Px 8) $P.SurfaceHover }
                $arrowColor = if ($hover -eq $arrow.Id) { $P.Accent } else { $P.Muted }
                Draw-Text $g (Tx $arrow.Glyph) $F.Close $arrowColor $arrow.Rect.X ($arrow.Rect.Y - (Px 2)) $arrow.Rect.Width $arrow.Rect.Height 'Center'
                Add-Hit $map $arrow.Id $arrow.Rect ([scriptblock]::Create("Step-Pick '$($field.Id)' $($arrow.Delta)"))
            }
            Draw-Text $g $field.Text $F.Body $P.Text ($dec.Right) $box.Y ($inc.X - $dec.Right) $box.Height 'Center'
        }

        # preview of the resulting window
        $at = Get-PickTime
        $window = Get-ProjectedWindow $at
        if ($at -le $now) {
            $preview = 'Esa hora ya pas' + (Tx '\u00f3') + '.'; $previewColor = $P.Error
        } elseif (Test-InsideCurrentSession $view $at) {
            $preview = 'Cae dentro de la sesi' + (Tx '\u00f3') + 'n actual (termina ' + (Format-Clock $view.Session.ResetsAt) + '): no adelanta nada.'
            $previewColor = $P.Warn
        } else {
            $preview = 'Nueva ventana aprox. de ' + (Format-Clock $window.Start) + ' a ' + (Format-Clock $window.End)
            $previewColor = $P.Muted
        }
        Draw-Text $g $preview $F.Small $previewColor $left (Px 246) $inner (Px 20)

        # where
        Draw-Text $g (Tx 'D\u00d3NDE') $F.Caps $P.Muted $left (Px 274) (Px 200) (Px 18)
        $cardW = [int](($inner - (Px 12)) / 2)
        $places = @(
            @{ Id = 'pc'; Title = 'En este PC'; Line1 = 'Programador de tareas'; Line2 = (Tx 'Aunque est\u00e9 suspendido') },
            @{ Id = 'cloud'; Title = 'En la nube'; Line1 = 'Rutina en claude.ai'; Line2 = (Tx 'Aunque est\u00e9 apagado') }
        )
        for ($i = 0; $i -lt $places.Count; $i++) {
            $place = $places[$i]
            $box = New-Rect ($left + $i * ($cardW + (Px 12))) (Px 296) $cardW (Px 76)
            $selected = ($state.Where -eq $place.Id)
            if ($selected) {
                Fill-Round $g $box (Px 10) $P.AccentTint
                Stroke-Round $g $box (Px 10) $P.Accent 1.5
            } else {
                $fill = if ($hover -eq $place.Id) { $P.SurfaceHover } else { $P.Surface }
                Fill-Round $g $box (Px 10) $fill
            }
            $dot = New-Rect ($box.X + (Px 14)) ($box.Y + (Px 14)) (Px 14) (Px 14)
            if ($selected) {
                $g.FillEllipse((New-Object System.Drawing.SolidBrush($P.Accent)), $dot)
                $g.FillEllipse((New-Object System.Drawing.SolidBrush($P.AccentTint)), (New-Rect ($dot.X + (Px 4)) ($dot.Y + (Px 4)) (Px 6) (Px 6)))
            } else {
                $g.DrawEllipse((New-Object System.Drawing.Pen($P.Faint, [single](1.5 * $script:Scale))), $dot)
            }
            Draw-Text $g $place.Title $F.BodyStrong $P.Text ($box.X + (Px 36)) ($box.Y + (Px 8)) ($box.Width - (Px 44)) (Px 22)
            Draw-Text $g $place.Line1 $F.Small $P.Muted ($box.X + (Px 36)) ($box.Y + (Px 30)) ($box.Width - (Px 44)) (Px 18)
            Draw-Text $g $place.Line2 $F.Small $P.Muted ($box.X + (Px 36)) ($box.Y + (Px 48)) ($box.Width - (Px 44)) (Px 18)
            Add-Hit $map $place.Id $box ([scriptblock]::Create("`$state.Where = '$($place.Id)'; `$state.Message = ''; `$dlg.Invalidate()"))
        }

        # scheduled list
        Draw-Text $g 'AGENDADAS' $F.Caps $P.Muted $left (Px 384) (Px 200) (Px 18)
        $y = Px 404
        if ($state.Rows.Count -eq 0) {
            $row = New-Rect $left $y $inner (Px 32)
            Fill-Round $g $row (Px 8) $P.Surface
            Draw-Text $g (Tx 'Nada agendado todav\u00eda.') $F.Body $P.Muted ($left + (Px 14)) $y ($inner - (Px 28)) (Px 32)
        }
        for ($i = 0; $i -lt $state.Rows.Count; $i++) {
            $item = $state.Rows[$i]
            $row = New-Rect $left ($y + $i * (Px 36)) $inner (Px 32)
            Fill-Round $g $row (Px 8) $P.Surface
            $kind = if ($item.Kind -eq 'pc') { 'PC' } else { 'NUBE' }
            $pill = New-Rect ($row.X + (Px 10)) ($row.Y + (Px 8)) (Px 42) (Px 16)
            $upcoming = $item.State -in 'pending', 'requested', 'creating', 'cloud-ok', 'cloud-failed'
            Fill-Round $g $pill (Px 8) $(if ($upcoming) { $P.AccentTint } else { $P.Track })
            $pillText = if ($upcoming) { $P.Accent } else { $P.Muted }
            Draw-Text $g $kind $F.Badge $pillText $pill.X $pill.Y $pill.Width $pill.Height 'Center'
            $textColor = if ($upcoming) { $P.Text } else { $P.Muted }
            Draw-Text $g (Format-DialogDateTime $item.At $now) $F.Body $textColor ($row.X + (Px 62)) $row.Y (Px 200) $row.Height

            switch ($item.State) {
                'pending'   { $status = 'Pendiente'; $statusColor = $P.Muted }
                'requested' { $status = 'Por confirmar'; $statusColor = $P.Muted }
                'creating'  { $status = (Tx 'Creando\u2026'); $statusColor = $P.Accent }
                'cloud-ok'  { $status = Tx '\u2713 En la nube'; $statusColor = $P.Ok }
                'cloud-failed' { $status = 'No se pudo crear'; $statusColor = $P.Error }
                'ok'        { $status = Tx '\u2713 Hecha'; $statusColor = $P.Ok }
                'failed'    { $status = Tx 'Fall\u00f3'; $statusColor = $P.Error }
                default     { $status = 'Enviada a la nube'; $statusColor = $P.Muted }
            }
            $statusRight = $row.Right - (Px 12)
            if ($item.State -eq 'pending') {
                $remove = New-Rect ($row.Right - (Px 30)) ($row.Y + (Px 4)) (Px 24) (Px 24)
                $removeId = "remove-$i"
                if ($hover -eq $removeId) { Fill-Round $g $remove (Px 6) $P.SurfaceHover }
                Draw-Text $g (Tx '\u00d7') $F.BodyStrong $P.Muted $remove.X $remove.Y $remove.Width $remove.Height 'Center'
                Add-Hit $map $removeId $remove ([scriptblock]::Create("Remove-SessionTask '$($item.TaskName)'; `$state.Message = 'Sesi' + (Tx '\u00f3') + 'n quitada.'; `$state.MessageKind = 'ok'; Update-Rows"))
                $statusRight = $remove.X - (Px 6)
            }
            Draw-Text $g $status $F.Small $statusColor ($row.X + (Px 200)) $row.Y ($statusRight - $row.X - (Px 200)) $row.Height 'Right'
        }

        # cloud routine progress card
        $footerY = $y + [Math]::Max(1, $state.Rows.Count) * (Px 36) + (Px 14)
        $cloud = $state.Cloud
        if ($cloud) {
            $card = New-Rect $left $footerY $inner (Px $script:CloudCardHeight)
            $cardFill = switch ($cloud.Status) { 'scheduled' { $P.AccentTint } 'failed' { $P.Surface } default { $P.Surface } }
            Fill-Round $g $card (Px 10) $cardFill
            if ($cloud.Status -eq 'creating') { Stroke-Round $g $card (Px 10) $P.Border }
            $cx = $card.X + (Px 16)
            $cw = $card.Width - (Px 32)
            switch ($cloud.Status) {
                'scheduled' { $title = 'Rutina creada en claude.ai'; $titleColor = $P.Text }
                'failed'    { $title = 'No se pudo crear la rutina'; $titleColor = $P.Error }
                default     { $title = (Tx 'Creando rutina en claude.ai\u2026'); $titleColor = $P.Text }
            }
            if ($cloud.Status -eq 'creating') {
                $phase = [int][Math]::Floor(((Get-Date) - $cloud.StartedAt).TotalMilliseconds / 400) % 3
                for ($d = 0; $d -lt 3; $d++) {
                    $dotColor = if ($d -eq $phase) { $P.Accent } else { $P.Track }
                    $g.FillEllipse((New-Object System.Drawing.SolidBrush($dotColor)), ($cx + $d * (Px 9)), ($card.Y + (Px 19)), (Px 6), (Px 6))
                }
                $titleX = $cx + (Px 32)
                $elapsed = [int]((Get-Date) - $cloud.StartedAt).TotalSeconds
                Draw-Text $g "$elapsed s" $F.Small $P.Muted $cx ($card.Y + (Px 10)) $cw (Px 24) 'Right'
            } else {
                $glyph = if ($cloud.Status -eq 'scheduled') { Tx '\u2713' } else { '!' }
                $glyphColor = if ($cloud.Status -eq 'scheduled') { $P.Ok } else { $P.Error }
                Draw-Text $g $glyph $F.BodyStrong $glyphColor $cx ($card.Y + (Px 10)) (Px 20) (Px 24)
                $titleX = $cx + (Px 22)
            }
            Draw-Text $g $title $F.BodyStrong $titleColor $titleX ($card.Y + (Px 10)) ($cw - ($titleX - $cx) - (Px 40)) (Px 24)

            $spec1 = (Format-DialogDateTime $cloud.At $now) + '  ' + (Tx '\u00b7') + '  Modelo ' + $script:CloudRoutine.Model + '  ' + (Tx '\u00b7') + '  Mensaje: ' + (Tx '\u201c') + 'ok' + (Tx '\u201d')
            Draw-Text $g $spec1 $F.Small $P.Muted $cx ($card.Y + (Px 36)) $cw (Px 18)
            Draw-Text $g ('Sin repositorios ni conectores ' + (Tx '\u00b7') + ' solo la herramienta de rutinas') $F.Small $P.Faint $cx ($card.Y + (Px 54)) $cw (Px 18)

            $lineY = $card.Y + (Px 76)
            switch ($cloud.Status) {
                'scheduled' {
                    Draw-Text $g $cloud.RoutineId $F.Small $P.Muted $cx $lineY $cw (Px 20)
                    $link = New-Rect ($card.Right - (Px 130)) $lineY (Px 114) (Px 20)
                    $linkColor = if ($hover -eq 'routines') { $P.AccentHover } else { $P.Accent }
                    Draw-Text $g (Tx 'Ver en claude.ai \u203a') $F.Small $linkColor $link.X $link.Y $link.Width $link.Height 'Right'
                    Add-Hit $map 'routines' $link { Start-Process 'https://claude.ai/code/routines' }
                }
                'failed' { Draw-Text $g $cloud.Error $F.Small $P.Error $cx $lineY $cw (Px 20) }
                default {
                    $note = if (((Get-Date) - $cloud.StartedAt).TotalMinutes -ge 3) { (Tx 'Est\u00e1 tardando; revisa claude.ai si no termina.') } else { (Tx 'Claude Code trabaja en segundo plano; puedes cerrar esta ventana.') }
                    Draw-Text $g $note $F.Small $P.Muted $cx $lineY $cw (Px 20)
                }
            }
            $footerY += (Px ($script:CloudCardHeight + 14))
        }

        # footer
        $ok = New-Rect ($left + $inner - (Px 104)) $footerY (Px 104) (Px 36)
        $cancel = New-Rect ($ok.X - (Px 100)) $footerY (Px 92) (Px 36)
        if ($hover -eq 'cancel') { Fill-Round $g $cancel (Px 8) $P.Surface }
        Draw-Text $g 'Cerrar' $F.Button $P.Text $cancel.X $cancel.Y $cancel.Width $cancel.Height 'Center'
        Add-Hit $map 'cancel' $cancel { $dlg.Close() }
        Fill-Round $g $ok (Px 8) $(if ($hover -eq 'ok') { $P.AccentHover } else { $P.Accent })
        Draw-Text $g 'Agendar' $F.Button $P.AccentText $ok.X $ok.Y $ok.Width $ok.Height 'Center'
        Add-Hit $map 'ok' $ok $schedule
        if ($state.Message) {
            $messageColor = if ($state.MessageKind -eq 'error') { $P.Error } else { $P.Ok }
            Draw-Text $g $state.Message $F.Small $messageColor $left $footerY ($cancel.X - $left - (Px 8)) (Px 36)
        }

        $border = New-Object System.Drawing.Pen($P.Border)
        $g.DrawRectangle($border, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1)
        $border.Dispose()
    })

    if ($PreviewCloud) {
        $state.Where = 'cloud'
        $state.Cloud = @{ Id = 'preview'; At = (Get-PickTime); StartedAt = (Get-Date).AddSeconds(-12); Status = $PreviewCloud;
            RoutineId = 'trig_01PREVIEW0000000000000000'; Error = 'Routines are not available for this account' }
    }
    Update-Rows

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
    }
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    if ($logo) { $logo.Dispose() }
}
