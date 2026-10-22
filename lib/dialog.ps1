# Claude-style session dialog with two tabs. "Agendar": current-session status, quick time choices,
# where to run, and the list of scheduled / past sessions. "Semana": a plan of 5-hour windows up to the
# weekly cutoff, with the share of the weekly limit to spend in each, and a button that schedules them.
# Fully owner-drawn on a borderless form (pickers are steppers: click the arrows or use the mouse wheel).
# Needs theme.ps1, usage.ps1, schedule.ps1.

$script:CloudCardHeight = 106
# The tab strip pushes the "Agendar" body down by this much (logical px).
$script:TabStripHeight = 38

function Show-ScheduleDialog([string]$RenderPath, [string]$PreviewCloud, [string]$Tab = 'schedule') {
    $P = $script:Palette
    $F = $script:Fonts
    $openedAt = Get-Date
    $snapshot = Read-JsonFile $UsageFile
    $view = Get-UsageView $snapshot $openedAt
    $startScript = Join-Path $TrayRoot 'start-session.ps1'

    $W = 440
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude'
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.BackColor = $P.Back
    $dlg.KeyPreview = $true
    $dlg.TopMost = $true
    if ($script:Notify -and $script:Notify.Icon) { $dlg.Icon = $script:Notify.Icon }
    Enable-DoubleBuffer $dlg
    $dlg.Tag = New-HitMap
    Register-HitMap $dlg

    $state = @{ Choice = 'suggested'; Where = 'pc'; Message = ''; MessageKind = 'ok'; Rows = @(); Day = 0; Hour = 0; Minute = 0; Cloud = $null
        Tab = $(if ($Tab -eq 'plan') { 'plan' } else { 'schedule' }); PlanSettings = (Get-PlanSettings (Read-JsonFile $PlanFile))
        WeekPlan = $null; Booked = @(); Unbooked = @() }

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
    function Py([int]$Value) { Px ($Value + $script:TabStripHeight) }

    # ---- week plan: sessions per day 1..what fits, first hour 0..23; cutoff weekday/hour without weekly data
    function Step-PlanField([string]$Field, [int]$Delta) {
        $settings = $state.PlanSettings
        switch ($Field) {
            'sessions'  { $settings.SessionsPerDay = $settings.SessionsPerDay + $Delta }
            'firsthour' { $settings.FirstHour = ($settings.FirstHour + $Delta + 24) % 24 }
            'cutday'    { $settings.CutoffWeekday = ($settings.CutoffWeekday + $Delta + 7) % 7 }
            'cuthour'   { $settings.CutoffHour = ($settings.CutoffHour + $Delta + 24) % 24 }
        }
        $state.PlanSettings = Get-PlanSettings $settings
        if (-not $RenderPath) { try { Write-JsonFile $PlanFile $state.PlanSettings } catch { } }
        $state.Message = ''
        Update-WeekPlan
        Update-Size
    }
    function Update-WeekPlan {
        $now = Get-Date
        $state.WeekPlan = Get-WeekPlan $snapshot $state.PlanSettings $now
        $state.Unbooked = @(Get-UnbookedSlots $state.WeekPlan.Slots $state.Booked $now)
    }
    function Get-PlanFooterY { 314 + [Math]::Max(1, $state.WeekPlan.Days.Count) * 36 + 14 }
    function Update-Size {
        if ($state.Tab -eq 'plan') {
            $height = (Get-PlanFooterY) + 36 + 22
        } else {
            $rowsHeight = [Math]::Max(1, $state.Rows.Count) * 36
            $cloudHeight = if ($state.Cloud) { $script:CloudCardHeight + 14 } else { 0 }
            $height = 404 + $script:TabStripHeight + $rowsHeight + 14 + $cloudHeight + 36 + 22
        }
        $dlg.ClientSize = New-Object System.Drawing.Size((Px $W), (Px $height))
        # Grown downward from where it opened: pull it back up so the buttons stay on screen.
        $area = [System.Windows.Forms.Screen]::FromControl($dlg).WorkingArea
        if ($dlg.Bottom -gt $area.Bottom) { $dlg.Top = [Math]::Max($area.Top, $area.Bottom - $dlg.Height) }
        $dlg.Invalidate()
    }
    # Scheduled rows that fit on this screen (at 150 % five rows and the cloud card are taller than a laptop's).
    function Get-RowsThatFit {
        $area = [System.Windows.Forms.Screen]::FromControl($dlg).WorkingArea
        $cloudHeight = if ($state.Cloud) { $script:CloudCardHeight + 14 } else { 0 }
        $fixed = 404 + $script:TabStripHeight + 14 + $cloudHeight + 36 + 22 + 16
        [Math]::Max(1, [int][Math]::Floor(($area.Height / $script:Scale - $fixed) / 36))
    }
    function Set-Tab([string]$Id) {
        $state.Tab = $Id
        $state.Message = ''
        Update-Size
    }
    function Update-Rows {
        $now = Get-Date
        $tasks = Get-SessionTasks
        $requests = Read-JsonFile $CloudFile
        $rows = @(Get-ScheduleRows $tasks $requests (Read-JsonFile $HistoryFile) $now)
        $fit = Get-RowsThatFit
        $state.HiddenRows = [Math]::Max(0, $rows.Count - $fit)
        $state.Rows = @($rows | Select-Object -First $fit)
        $state.Booked = @(Get-ScheduleRows $tasks $requests $null $now 500 |
            Where-Object { $_.State -in 'pending', 'requested', 'creating', 'cloud-ok' } | ForEach-Object { $_.At })
        Update-WeekPlan
        Update-Size
    }
    # Arrows on both sides of a value; registers the box for the mouse wheel. $StepCommand gets (field, delta).
    function Draw-Stepper($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Box, [string]$Text, [string]$StepCommand, $Fill) {
        $state.Fields[$Id] = $Box
        Fill-Round $G $Box (Px 8) $Fill
        $dec = New-Rect $Box.X $Box.Y (Px 28) $Box.Height
        $inc = New-Rect ($Box.Right - (Px 28)) $Box.Y (Px 28) $Box.Height
        foreach ($arrow in @(@{ Rect = $dec; Id = "$Id-dec"; Glyph = '\u2039'; Delta = -1 }, @{ Rect = $inc; Id = "$Id-inc"; Glyph = '\u203a'; Delta = 1 })) {
            if ($Hover -eq $arrow.Id) { Fill-Round $G $arrow.Rect (Px 8) $P.SurfaceHover }
            $arrowColor = if ($Hover -eq $arrow.Id) { $P.Accent } else { $P.Muted }
            Draw-Text $G (Tx $arrow.Glyph) $F.Close $arrowColor $arrow.Rect.X ($arrow.Rect.Y - (Px 2)) $arrow.Rect.Width $arrow.Rect.Height 'Center'
            Add-Hit $Map $arrow.Id $arrow.Rect ([scriptblock]::Create("$StepCommand '$Id' $($arrow.Delta)"))
        }
        Draw-Text $G $Text $F.Body $P.Text ($dec.Right) $Box.Y ($inc.X - $dec.Right) $Box.Height 'Center'
    }
    $state.Fields = @{}
    Set-PickTime $suggested

    $dlg.Add_MouseWheel({
        param($sender, $e)
        foreach ($name in @($state.Fields.Keys)) {
            if (-not $state.Fields[$name].Contains($e.Location)) { continue }
            if ($name -in 'day', 'hour', 'minute') { Step-Pick $name ([Math]::Sign($e.Delta)) } else { Step-PlanField $name ([Math]::Sign($e.Delta)) }
            return
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

    # Task Scheduler tasks for every planned window that has nothing scheduled near it.
    $schedulePlan = {
        $todo = @(Get-UnbookedSlots $state.WeekPlan.Slots $state.Booked (Get-Date))
        $made = 0
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            foreach ($slot in $todo) { New-SessionTask $slot.Start $startScript; $made++ }
            $state.Message = (Tx '\u2713 ') + "$made agendadas en este PC"; $state.MessageKind = 'ok'
        } catch {
            $state.Message = "Agendadas $made; error: $($_.Exception.Message)"; $state.MessageKind = 'error'
        } finally {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        Update-Rows
    }

    function Draw-PlanTab($G, $Map, $Hover, [datetime]$Now, [int]$Left, [int]$Inner) {
        $weekPlan = $state.WeekPlan
        $settings = $state.PlanSettings
        $culture = [System.Globalization.CultureInfo]::CurrentCulture

        # week card: cutoff, usage so far and how much of the week has gone by (the tick on the bar)
        $card = New-Rect $Left (Px 100) $Inner (Px 72)
        Fill-Round $G $card (Px 10) $P.Surface
        Draw-Text $G 'SEMANA' $F.Caps $P.Muted (Px 40) (Px 110) (Px 200) (Px 18)
        if ($weekPlan.CutoffSource -eq 'manual') {
            Draw-Text $G (Tx 'Sin datos: elige el d\u00eda y la hora del corte') $F.Small $P.Muted (Px 40) (Px 110) (Px ($W - 80)) (Px 18) 'Right'
            $dayName = $culture.DateTimeFormat.DayNames[$settings.CutoffWeekday]
            $dayName = $dayName.Substring(0, 1).ToUpper() + $dayName.Substring(1)
            Draw-Stepper $G $Map $Hover 'cutday' (New-Rect (Px 40) (Px 132) (Px 200) (Px 30)) $dayName 'Step-PlanField' $P.Back
            $hourText = $Now.Date.AddHours($settings.CutoffHour).ToString('h tt', $culture)
            Draw-Stepper $G $Map $Hover 'cuthour' (New-Rect (Px 248) (Px 132) (Px ($W - 288)) (Px 30)) $hourText 'Step-PlanField' $P.Back
        } else {
            $elapsedText = [string][Math]::Round(100 * $weekPlan.WeekElapsed) + (Tx ' % del tiempo')
            $usedText = if ($weekPlan.CutoffSource -eq 'rolled') { 'Semana nueva' } else { [string][Math]::Round($weekPlan.UsedPercent) + ' % usado' }
            Draw-Text $G ($usedText + (Tx ' \u00b7 ') + $elapsedText) $F.Small $P.Muted (Px 40) (Px 110) (Px ($W - 80)) (Px 18) 'Right'
            $cutoffPrefix = if ($weekPlan.CutoffSource -eq 'rolled') { 'Corte aprox. ' } else { 'Corte ' }
            Draw-Text $G ($cutoffPrefix + (Format-DialogDateTime $weekPlan.Cutoff $Now)) $F.BodyStrong $P.Text (Px 40) (Px 130) (Px 280) (Px 22)
            Draw-Text $G ('en ' + (Format-Remaining ($weekPlan.Cutoff - $Now))) $F.BodyStrong $P.Accent (Px 40) (Px 130) (Px ($W - 80)) (Px 22) 'Right'
            $track = New-Rect (Px 40) (Px 158) (Px ($W - 80)) (Px 4)
            Fill-Round $G $track (Px 2) $P.Track
            $usedWidth = [int]($track.Width * $weekPlan.UsedPercent / 100)
            if ($usedWidth -gt 0) { Fill-Round $G (New-Rect $track.X $track.Y ([Math]::Max((Px 4), $usedWidth)) $track.Height) (Px 2) $P.Accent }
            $tickX = $track.X + [int]($track.Width * $weekPlan.WeekElapsed)
            Fill-Round $G (New-Rect ($tickX - (Px 1)) ($track.Y - (Px 4)) (Px 2) (Px 12)) (Px 1) $P.Muted
        }

        # sessions per day and when the first one starts
        Draw-Text $G (Tx 'SESIONES POR D\u00cdA') $F.Caps $P.Muted $Left (Px 184) (Px 200) (Px 18)
        $sessionsText = if ($settings.SessionsPerDay -eq 1) { Tx '1 sesi\u00f3n' } else { "$($settings.SessionsPerDay) sesiones" }
        Draw-Stepper $G $Map $Hover 'sessions' (New-Rect (Px 24) (Px 206) (Px 184) (Px 32)) $sessionsText 'Step-PlanField' $P.Surface
        $firstText = 'Desde las ' + (Format-Clock $Now.Date.AddHours($settings.FirstHour).AddMinutes(5))
        Draw-Stepper $G $Map $Hover 'firsthour' (New-Rect (Px 216) (Px 206) (Px 200) (Px 32)) $firstText 'Step-PlanField' $P.Surface

        # summary
        if ($weekPlan.RemainingPercent -le 0) {
            $line1 = Tx 'Ya usaste todo el l\u00edmite semanal.'; $line1Color = $P.Warn
            $line2 = 'Se renueva ' + (Format-DialogDateTime $weekPlan.Cutoff $Now) + '.'
        } elseif ($weekPlan.SessionCount -eq 0) {
            $line1 = 'No quedan sesiones antes del corte con este horario.'; $line1Color = $P.Warn
            $line2 = Tx 'Empieza m\u00e1s temprano o suma sesiones por d\u00eda.'
        } else {
            $withCurrent = if (@($weekPlan.Slots | Where-Object { $_.Current }).Count) { ' (con la actual)' } else { '' }
            $sessionWord = if ($weekPlan.SessionCount -eq 1) { Tx 'sesi\u00f3n' } else { 'sesiones' }
            $line1 = "Quedan $($weekPlan.SessionCount) $sessionWord de 5 h hasta el corte$withCurrent."; $line1Color = $P.Text
            $line2 = 'Para gastarlo todo: ~' + $weekPlan.PerSession.ToString('0.#', $culture) + (Tx ' % del semanal por sesi\u00f3n.')
        }
        Draw-Text $G $line1 $F.Small $line1Color $Left (Px 244) $Inner (Px 18)
        Draw-Text $G $line2 $F.Small $P.Muted $Left (Px 262) $Inner (Px 18)

        # day by day: window start times (current one, scheduled ones with a check) and the weekly usage to reach
        Draw-Text $G 'PLAN' $F.Caps $P.Muted $Left (Px 292) (Px 200) (Px 18)
        Draw-Text $G (Tx 'USO AL CERRAR EL D\u00cdA') $F.Caps $P.Muted $Left (Px 292) $Inner (Px 18) 'Right'
        $top = Px 314
        if ($weekPlan.Days.Count -eq 0) {
            $row = New-Rect $Left $top $Inner (Px 32)
            Fill-Round $G $row (Px 8) $P.Surface
            Draw-Text $G 'Nada que planear antes del corte.' $F.Body $P.Muted ($Left + (Px 14)) $top ($Inner - (Px 28)) (Px 32)
        }
        $unbookedTicks = @($state.Unbooked | ForEach-Object { $_.Start.Ticks })
        for ($i = 0; $i -lt $weekPlan.Days.Count; $i++) {
            $day = $weekPlan.Days[$i]
            $row = New-Rect $Left ($top + $i * (Px 36)) $Inner (Px 32)
            Fill-Round $G $row (Px 8) $P.Surface
            Draw-Text $G (Get-DayLabel $day.Date $Now) $F.Body $P.Text ($row.X + (Px 14)) $row.Y (Px 92) $row.Height
            $x = $row.X + (Px 106)
            $limit = $row.Right - (Px 64)
            $parts = New-Object System.Collections.ArrayList
            foreach ($slot in $day.Slots) {
                if ($parts.Count) { [void]$parts.Add(@{ Text = (Tx '\u00b7'); Color = $P.Faint }) }
                if ($slot.Current) {
                    [void]$parts.Add(@{ Text = 'ahora'; Color = $P.Accent })
                } elseif ($unbookedTicks -contains $slot.Start.Ticks) {
                    [void]$parts.Add(@{ Text = $slot.Start.ToString('H:mm'); Color = $P.Text })
                } else {
                    [void]$parts.Add(@{ Text = (Tx '\u2713') + $slot.Start.ToString('H:mm'); Color = $P.Ok })
                }
            }
            if ($day.Date -eq $weekPlan.Cutoff.Date) {
                [void]$parts.Add(@{ Text = (Tx '\u00b7'); Color = $P.Faint })
                [void]$parts.Add(@{ Text = 'corte ' + $weekPlan.Cutoff.ToString('H:mm'); Color = $P.Faint })
            }
            foreach ($part in $parts) {
                $partW = Measure-TextWidth $part.Text $F.Small
                if ($x + $partW -gt $limit) { break }
                Draw-Text $G $part.Text $F.Small $part.Color $x $row.Y $partW $row.Height
                $x += $partW + (Px 3)
            }
            $last = ($i -eq $weekPlan.Days.Count - 1)
            $targetColor = if ($last) { $P.Accent } else { $P.Text }
            Draw-Text $G ([string][Math]::Round($day.EndPercent) + ' %') $F.BodyStrong $targetColor $row.X $row.Y ($row.Width - (Px 14)) $row.Height 'Right'
        }
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

        $state.Fields = @{}

        # header and tabs
        if ($logo) { $g.DrawImage($logo, $left, (Px 19)) }
        $title = if ($state.Tab -eq 'plan') { 'Plan semanal' } else { Tx 'Agendar sesi\u00f3n' }
        Draw-Text $g $title $F.Title $P.Text (Px 56) (Px 14) (Px 300) (Px 32)
        $close = New-Rect (Px ($W - 52)) (Px 16) (Px 30) (Px 30)
        if ($hover -eq 'close') { Fill-Round $g $close (Px 6) $P.SurfaceHover }
        Draw-Text $g (Tx '\u00d7') $F.Close $P.Muted $close.X $close.Y $close.Width $close.Height 'Center'
        Add-Hit $map 'close' $close { $dlg.Close() } 'Cerrar (Esc)'

        $divider = New-Object System.Drawing.Pen($P.Border)
        $g.DrawLine($divider, $left, (Px 89), $left + $inner, (Px 89))
        $divider.Dispose()
        $tabX = $left
        foreach ($tab in @(@{ Id = 'schedule'; Label = 'Agendar' }, @{ Id = 'plan'; Label = 'Semana' })) {
            $active = ($state.Tab -eq $tab.Id)
            $tabFont = if ($active) { $F.BodyStrong } else { $F.Body }
            $tabRect = New-Rect $tabX (Px 56) ((Measure-TextWidth $tab.Label $tabFont) + (Px 20)) (Px 32)
            $hitId = "tab-$($tab.Id)"
            if (-not $active -and $hover -eq $hitId) { Fill-Round $g (New-Rect $tabRect.X ($tabRect.Y + (Px 2)) $tabRect.Width ($tabRect.Height - (Px 6))) (Px 6) $P.SurfaceHover }
            $tabColor = if ($active -or $hover -eq $hitId) { $P.Text } else { $P.Muted }
            Draw-Text $g $tab.Label $tabFont $tabColor $tabRect.X $tabRect.Y $tabRect.Width $tabRect.Height 'Center'
            if ($active) { Fill-Round $g (New-Rect ($tabRect.X + (Px 6)) (Px 87) ($tabRect.Width - (Px 12)) (Px 3)) (Px 1) $P.Accent }
            else { Add-Hit $map $hitId $tabRect ([scriptblock]::Create("Set-Tab '$($tab.Id)'")) }
            $tabX += $tabRect.Width + (Px 4)
        }

        if ($state.Tab -eq 'plan') {
            Draw-PlanTab $g $map $hover $now $left $inner
            $footerY = Px (Get-PlanFooterY)
        } else {
            # current session card
            $card = New-Rect $left (Py 62) $inner (Px 72)
            Fill-Round $g $card (Px 10) $P.Surface
            Draw-Text $g (Tx 'SESI\u00d3N ACTUAL') $F.Caps $P.Muted (Px 40) (Py 72) (Px 200) (Px 18)
            if ($view.Session.Active) {
                Draw-Text $g ("$($view.Session.Percent) % usado") $F.Small $P.Muted (Px 40) (Py 72) (Px ($W - 80)) (Px 18) 'Right'
                Draw-Text $g ('Termina a las ' + (Format-Clock $view.Session.ResetsAt)) $F.BodyStrong $P.Text (Px 40) (Py 92) (Px 260) (Px 22)
                Draw-Text $g ('en ' + (Format-Remaining ($view.Session.ResetsAt - $now))) $F.BodyStrong $P.Accent (Px 40) (Py 92) (Px ($W - 80)) (Px 22) 'Right'
                $track = New-Rect (Px 40) (Py 120) (Px ($W - 80)) (Px 4)
                Fill-Round $g $track (Px 2) $P.Track
                $fraction = Get-SessionElapsedFraction $view $now
                if ($fraction -gt 0) { Fill-Round $g (New-Rect $track.X $track.Y ([Math]::Max((Px 4), [int]($track.Width * $fraction))) $track.Height) (Px 2) $P.Accent }
            } else {
                Draw-Text $g 'Sin empezar' $F.BodyStrong $P.Text (Px 40) (Py 92) (Px 200) (Px 22)
                Draw-Text $g 'Empieza con el primer mensaje' $F.Small $P.Muted (Px 40) (Py 92) (Px ($W - 80)) (Px 22) 'Right'
                Draw-Text $g ('La ventana dura unas 5 h desde el primer mensaje.') $F.Small $P.Faint (Px 40) (Py 112) (Px ($W - 80)) (Px 16)
            }

            # when
            Draw-Text $g (Tx 'CU\u00c1NDO') $F.Caps $P.Muted $left (Py 146) (Px 200) (Px 18)
            $x = $left
            foreach ($choice in $choices) {
                $chipW = (Measure-TextWidth $choice.Label $F.Body) + (Px 26)
                $chip = New-Rect $x (Py 168) $chipW (Px 30)
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
                Draw-Stepper $g $map $hover $field.Id (New-Rect (Px $field.X) (Py 208) (Px $field.W) (Px 32)) $field.Text 'Step-Pick' $P.Surface
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
            Draw-Text $g $preview $F.Small $previewColor $left (Py 246) $inner (Px 20)

            # where
            Draw-Text $g (Tx 'D\u00d3NDE') $F.Caps $P.Muted $left (Py 274) (Px 200) (Px 18)
            $cardW = [int](($inner - (Px 12)) / 2)
            $places = @(
                @{ Id = 'pc'; Title = 'En este PC'; Line1 = 'Programador de tareas'; Line2 = (Tx 'Aunque est\u00e9 suspendido') },
                @{ Id = 'cloud'; Title = 'En la nube'; Line1 = 'Rutina en claude.ai'; Line2 = (Tx 'Aunque est\u00e9 apagado') }
            )
            for ($i = 0; $i -lt $places.Count; $i++) {
                $place = $places[$i]
                $box = New-Rect ($left + $i * ($cardW + (Px 12))) (Py 296) $cardW (Px 76)
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
            Draw-Text $g 'AGENDADAS' $F.Caps $P.Muted $left (Py 384) (Px 200) (Px 18)
            if ($state.HiddenRows -gt 0) { Draw-Text $g (Tx "+$($state.HiddenRows) m\u00e1s (no caben en la pantalla)") $F.Small $P.Muted $left (Py 384) $inner (Px 18) 'Right' }
            $y = Py 404
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
                    Add-Hit $map $removeId $remove ([scriptblock]::Create("if (Remove-SessionTask '$($item.TaskName)') { `$state.Message = (Tx 'Sesi\u00f3n quitada.'); `$state.MessageKind = 'ok' } else { `$state.Message = (Tx 'No se pudo quitar: mira el Programador de tareas.'); `$state.MessageKind = 'error' }; Update-Rows")) 'Quitar esta sesi\u00f3n agendada'
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
        }

        # footer
        if ($state.Tab -eq 'plan') {
            $okLabel = if ($state.Unbooked.Count) { "Agendar plan ($($state.Unbooked.Count))" } else { 'Todo agendado' }
            $okAction = if ($state.Unbooked.Count) { $schedulePlan } else { $null }
        } else {
            $okLabel = 'Agendar'; $okAction = $schedule
        }
        $okW = [Math]::Max((Px 104), (Measure-TextWidth $okLabel $F.Button) + (Px 32))
        $ok = New-Rect ($left + $inner - $okW) $footerY $okW (Px 36)
        $cancel = New-Rect ($ok.X - (Px 100)) $footerY (Px 92) (Px 36)
        if ($hover -eq 'cancel') { Fill-Round $g $cancel (Px 8) $P.Surface }
        Draw-Text $g 'Cerrar' $F.Button $P.Text $cancel.X $cancel.Y $cancel.Width $cancel.Height 'Center'
        Add-Hit $map 'cancel' $cancel { $dlg.Close() }
        if ($okAction) {
            Fill-Round $g $ok (Px 8) $(if ($hover -eq 'ok') { $P.AccentHover } else { $P.Accent })
            Draw-Text $g $okLabel $F.Button $P.AccentText $ok.X $ok.Y $ok.Width $ok.Height 'Center'
            Add-Hit $map 'ok' $ok $okAction
        } else {
            Fill-Round $g $ok (Px 8) $P.Surface
            Draw-Text $g $okLabel $F.Button $P.Muted $ok.X $ok.Y $ok.Width $ok.Height 'Center'
        }
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
