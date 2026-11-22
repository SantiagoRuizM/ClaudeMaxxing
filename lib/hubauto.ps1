# Agenda automatica in the tray and in the ClaudeMaxxing window (Uso y agenda): keeps the Auto- tasks of
# lib\autoplan.ps1 in Task Scheduler and draws the card that explains and controls them.
#   - The tray calls Invoke-AutoSchedule from its timer; it does the work at most once an hour, or right away
#     after a change here (-Force). Without stats younger than a day it starts a scan, and the next pass uses it.
#   - Tasks scheduled by hand that would break the chain are only listed; removing them takes a click.
# Needs autoplan.ps1, hubstats.ps1 (stats scan) and the tray's schedule state. Keep this file ASCII.

$script:AutoSyncAt = [datetime]::MinValue
# Hand-made tasks are checked this far ahead (the week plan goes up to the weekly cutoff), not only over
# the days the tray keeps scheduled.
$AutoConflictDays = 14
$script:AutoLastResult = $null

# The newest stats: every scan writes $StatsFile; the open window may hold the same result already parsed.
function Get-AutoState {
    $settings = Get-AutoPlanSettings (Read-JsonFile $AutoPlanFile)
    $stats = Read-JsonFile $StatsFile
    $cached = if ($script:HubDialog -and $script:Hub) { $script:Hub.Cache.Stats } else { $null }
    try { if ($cached -and (-not $stats -or [datetime]$cached.scannedAt -ge [datetime]$stats.scannedAt)) { $stats = $cached } } catch { }
    $plan = $null
    if ($stats -and $stats.recent) { $plan = Get-AutoPlan $stats.recent.hourly ([int]$stats.recent.activeDays) $settings.boundary $settings.lastBoundary }
    @{ Settings = $settings; Plan = $plan; Stats = $stats }
}

function Save-AutoSettings($Settings) {
    try { Write-JsonFile $AutoPlanFile $Settings }
    catch { if ($script:HubDialog -and $script:Hub) { Set-HubMessage ((Tx 'No se pudo guardar la agenda autom\u00e1tica: ') + $_.Exception.Message) } }
}

# Brings Task Scheduler in line with the plan. Hourly from the tray timer; -Force after a change.
function Invoke-AutoSchedule([switch]$Force) {
    if ($Rendering) { return }
    if (-not $Force -and ((Get-Date) - $script:AutoSyncAt).TotalMinutes -lt 60) { return }
    $script:AutoSyncAt = Get-Date
    $state = Get-AutoState
    $hasAuto = @($script:PendingTasks | Where-Object { $_.Name -like "$AutoTaskPrefix*" }).Count -gt 0
    if (-not $state.Settings.enabled -and -not $hasAuto) { return }
    if ($state.Settings.enabled -and (-not $state.Stats -or (Get-StatsAgeMinutes $state.Stats) -gt 1440)) { Start-HubStatsScan }
    # Remember the computed boundary in use, so a near tie later does not move it.
    if ($state.Settings.enabled -and $state.Plan -and $state.Plan.HasData -and -not $state.Plan.Manual -and $state.Settings.lastBoundary -ne $state.Plan.Boundary) {
        $state.Settings.lastBoundary = $state.Plan.Boundary
        Save-AutoSettings $state.Settings
    }
    try {
        Update-ScheduleState
        $script:AutoLastResult = Sync-AutoSessions $state.Plan ([bool]$state.Settings.enabled) $state.Settings.days $script:PendingTasks (Join-Path $TrayRoot 'start-session.ps1') (Get-Date)
        if ($script:AutoLastResult.Added -or $script:AutoLastResult.Removed) { Update-ScheduleState }
    } catch {
        $script:AutoLastResult = @{ Added = 0; Removed = 0; Error = $_.Exception.Message }
    }
}

# What the card shows: the plan, the starts it keeps scheduled, and hand-made tasks in its way.
function Get-HubAutoView {
    $state = Get-AutoState
    $now = Get-Date
    $slots = @()
    $conflicts = @()
    if ($state.Plan -and $state.Plan.HasData) {
        $slots = Get-AutoSlots $state.Plan.Starts $now $state.Settings.days
        $conflicts = Get-AutoConflicts (Get-AutoSlots $state.Plan.Starts $now $AutoConflictDays) $script:PendingTasks $now $AutoConflictDays
    }
    @{ Settings = $state.Settings; Plan = $state.Plan; Slots = @($slots); Conflicts = @($conflicts) }
}

function Update-HubAuto {
    if (-not $script:Hub -or $script:Hub.Preview) { return }
    $script:Hub.Cache.Auto = Get-HubAutoView
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

function Set-AutoEnabled([bool]$On) {
    $settings = Get-AutoPlanSettings (Read-JsonFile $AutoPlanFile)
    $settings.enabled = $On
    Save-AutoSettings $settings
    Invoke-AutoSchedule -Force
    $result = $script:AutoLastResult
    if ($result -and $result.Error) { Set-HubMessage ((L 'No se pudo agendar: ') + $result.Error) }
    elseif ($On) { Set-HubMessage ((Tx '\u2713 Agenda autom\u00e1tica activa') + $(if ($result) { ((L ' ({0} sesiones agendadas)') -f $result.Added) } else { '' })) }
    else { Set-HubMessage ((Tx 'Agenda autom\u00e1tica apagada') + $(if ($result -and $result.Removed) { ((L ' ({0} quitadas)') -f $result.Removed) } else { '' })) }
    Update-HubAuto
}

# Moves the boundary an hour; -Reset goes back to the computed one.
function Step-AutoBoundary([int]$Delta, [switch]$Reset) {
    $state = Get-AutoState
    $settings = $state.Settings
    if ($Reset) { $settings.boundary = -1 }
    elseif ($state.Plan) { $settings.boundary = ($state.Plan.Boundary + $Delta + 24) % 24 }
    Save-AutoSettings $settings
    if ($settings.enabled) { Invoke-AutoSchedule -Force }
    Update-HubAuto
}

# "Limpiar": removes the hand-made tasks that would interrupt the chain (those listed on the card, nothing
# else), whether the automatic agenda is on or not.
function Remove-AutoConflicts {
    $view = $script:Hub.Cache.Auto
    if (-not $view) { return }
    $conflicts = @($view.Conflicts)
    $ask = if ($conflicts.Count -eq 1) { Tx '\u00bfQuitar la sesi\u00f3n agendada a mano que corta la cadena?' } else { (Tx '\u00bfQuitar las {0} sesiones agendadas a mano que cortan la cadena?') -f $conflicts.Count }
    if (-not (Confirm-UiAction $ask $script:HubDialog)) { return }
    $count = 0
    foreach ($task in $conflicts) { if (Remove-SessionTask $task.Name) { $count++ } }
    Update-ScheduleState
    Invoke-AutoSchedule -Force
    $failed = $conflicts.Count - $count
    if ($failed -gt 0) { Set-HubMessage ((L 'No se pudieron quitar {0} de {1}: mira el Programador de tareas.') -f $failed, $conflicts.Count) -Failed }
    else { Set-HubMessage ((Tx '\u2713 ') + $(if ($count -eq 1) { 'Limpiada 1 agendada a mano' } else { ((L 'Limpiadas {0} agendadas a mano') -f $count) })) }
    Update-HubAuto
    Update-HubNow
}

function Format-HourMark([int]$Hour, [int]$Minute = 0) { '{0:00}:{1:00}' -f ($Hour % 24), $Minute }

# ---------------------------------------------------------------- card (Uso y agenda)

function Draw-HubAutoCard($G, $Map, $Hover, [System.Drawing.Rectangle]$Card) {
    $P = $script:Palette
    $F = $script:Fonts
    $view = $script:Hub.Cache.Auto
    Draw-HubCard $G $Card
    $x = $Card.X + (Px 16)
    $w = $Card.Width - (Px 32)
    Draw-Text $G (Tx 'AGENDA AUTOM\u00c1TICA') $F.Caps $P.Muted $x ($Card.Y + (Px 12)) (Px 200) (Px 18)
    if (-not $view) { return }
    $settings = $view.Settings
    $plan = $view.Plan
    $on = [bool]$settings.enabled
    $sx = $Card.Right - (Px 52)
    $hit = New-Rect ($sx - (Px 108)) ($Card.Y + (Px 10)) (Px 144) (Px 20)
    Draw-Text $G $(if ($on) { 'Activa' } else { 'Apagada' }) $F.Small $(if ($on) { $P.Accent } else { $P.Muted }) $hit.X $hit.Y (Px 100) $hit.Height 'Right'
    if ($plan -and $plan.HasData) {
        Draw-HubSwitch $G $Map 'auto-switch' $sx ($Card.Y + (Px 10)) $on ([scriptblock]::Create("Set-AutoEnabled `$$(-not $on)")) $true $hit
    } else {
        Draw-HubSwitch $G $Map 'auto-switch' $sx ($Card.Y + (Px 10)) $on $null $false
        $text = Tx 'Hace falta saber cu\u00e1ndo usas Claude: abre Estad\u00edsticas una vez (lee tus conversaciones de Claude Code) y vuelve aqu\u00ed.'
        Draw-Wrapped $G $text $F.Body $P.Muted $x ($Card.Y + (Px 40)) $w (Px 44)
        return
    }

    $peak = $plan.Peak
    $headline = (Tx 'Tu franja de m\u00e1s uso: ') + (Format-HourMark $peak.Start) + (Tx '\u2013') + (Format-HourMark $peak.End) +
        (Tx '  \u00b7  ') + (Format-HubDuration $peak.Seconds) + (Tx ' de media al d\u00eda')
    Draw-Text $G $headline $F.BodyStrong $P.Text $x ($Card.Y + (Px 32)) $w (Px 22)

    # timeline: average use per hour, the peak zone in the accent, the planned windows under it
    $line = New-Rect $x ($Card.Y + (Px 58)) $w (Px 58)
    $hourW = $line.Width / 24.0
    $barsH = Px 30
    $maxUse = ($plan.Profile | Measure-Object -Maximum).Maximum
    $peakHours = @($peak.Start, (($peak.Start + 1) % 24))
    for ($h = 0; $h -lt 24; $h++) {
        $value = [double]$plan.Profile[$h]
        if ($maxUse -le 0 -or $value -le 0) { continue }
        $bh = [Math]::Max((Px 2), [int]($barsH * $value / $maxUse))
        $bx = $line.X + [int]($h * $hourW) + (Px 1)
        $color = if ($peakHours -contains $h) { $P.Accent } else { $P.Faint }
        Draw-HubBar $G (New-Rect $bx ($line.Y + $barsH - $bh) ([int]$hourW - (Px 2)) $bh) (Px 2) $color
    }
    $bandY = $line.Y + $barsH + (Px 6)
    $bandH = Px 10
    Fill-Round $G (New-Rect $line.X $bandY $line.Width $bandH) (Px 5) $P.Back
    # each window in turn a lighter and a darker shade; one past midnight wraps to the left
    $shades = @((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, $P.Accent))),
        (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, $P.Muted))))
    for ($i = 0; $i -lt $plan.Starts.Count; $i++) {
        $from = ($plan.Starts[$i] % 24) + 5 / 60.0
        $to = $from + 5
        foreach ($segment in @(@($from, $to), @(($from - 24), ($to - 24)))) {
            $a = [Math]::Max(0.0, [double]$segment[0]); $b = [Math]::Min(24.0, [double]$segment[1])
            if ($b -le $a) { continue }
            $G.FillRectangle($shades[$i % 2], [single]($line.X + $a * $hourW), [single]$bandY, [single](($b - $a) * $hourW), [single]$bandH)
        }
    }
    foreach ($brush in $shades) { $brush.Dispose() }
    # the changes between windows, the one in the peak zone in the accent
    $pen = New-Object System.Drawing.Pen($P.Text, [single](1.5 * $script:Scale))
    $accentPen = New-Object System.Drawing.Pen($P.Accent, [single](2.5 * $script:Scale))
    foreach ($start in $plan.Starts) {
        $hour = ($start % 24) + 5 / 60.0
        $cx = [int]($line.X + $hour * $hourW)
        $isBoundary = ($start % 24) -eq $plan.Boundary
        $G.DrawLine($(if ($isBoundary) { $accentPen } else { $pen }), $cx, ($bandY - (Px 3)), $cx, ($bandY + $bandH + (Px 3)))
    }
    $pen.Dispose(); $accentPen.Dispose()
    foreach ($mark in 0, 6, 12, 18, 24) {
        $mx = [int]($line.X + $mark * $hourW)
        $align = if ($mark -eq 0) { 'Left' } elseif ($mark -eq 24) { 'Right' } else { 'Center' }
        $lx = if ($mark -eq 0) { $mx } elseif ($mark -eq 24) { $mx - (Px 40) } else { $mx - (Px 20) }
        Draw-Text $G ('{0:00}' -f ($mark % 24)) $F.Small $P.Faint $lx ($bandY + $bandH + (Px 2)) (Px 40) (Px 14) $align
    }

    # the starts, and the boundary (computed or moved by hand)
    $y = $Card.Y + (Px 120)
    $startsText = (L 'Sesiones a las ') + (@($plan.Starts | ForEach-Object { Format-HourMark $_ 5 }) -join (Tx ' \u00b7 '))
    $pickerW = Px 210
    Draw-Text $G $startsText $F.Body $P.Text $x $y ($w - $pickerW - (Px 8)) (Px 26)
    $box = New-Rect ($Card.Right - (Px 16) - $pickerW) $y $pickerW (Px 26)
    Draw-Text $G 'Cambio en' $F.Small $P.Muted $box.X $box.Y (Px 64) $box.Height
    $stepper = New-Rect ($box.X + (Px 66)) $box.Y (Px 104) $box.Height
    Fill-Round $G $stepper (Px 7) $P.Back
    foreach ($arrow in @(@{ Rect = (New-Rect $stepper.X $stepper.Y (Px 24) $stepper.Height); Id = 'auto-dec'; Glyph = '\u2039'; Delta = -1 },
                         @{ Rect = (New-Rect ($stepper.Right - (Px 24)) $stepper.Y (Px 24) $stepper.Height); Id = 'auto-inc'; Glyph = '\u203a'; Delta = 1 })) {
        if ($Hover -eq $arrow.Id) { Fill-Round $G $arrow.Rect (Px 7) $P.SurfaceHover }
        Draw-Text $G (Tx $arrow.Glyph) $F.Close $(if ($Hover -eq $arrow.Id) { $P.Accent } else { $P.Muted }) $arrow.Rect.X ($arrow.Rect.Y - (Px 2)) $arrow.Rect.Width $arrow.Rect.Height 'Center'
        Add-Hit $Map $arrow.Id $arrow.Rect ([scriptblock]::Create("Step-AutoBoundary $($arrow.Delta)"))
    }
    Draw-Text $G (Format-HourMark $plan.Boundary 5) $F.BodyStrong $P.Text ($stepper.X + (Px 24)) $stepper.Y ($stepper.Width - (Px 48)) $stepper.Height 'Center'
    $modeRect = New-Rect ($stepper.Right + (Px 4)) $box.Y ($box.Right - $stepper.Right - (Px 4)) $box.Height
    if ($plan.Manual) {
        Draw-Text $G 'auto' $F.Small $(if ($Hover -eq 'auto-reset') { $P.AccentHover } else { $P.Accent }) $modeRect.X $modeRect.Y $modeRect.Width $modeRect.Height 'Right'
        Add-Hit $Map 'auto-reset' $modeRect { Step-AutoBoundary 0 -Reset } 'Volver a la hora calculada'
    } else {
        Draw-Text $G 'auto' $F.Small $P.Faint $modeRect.X $modeRect.Y $modeRect.Width $modeRect.Height 'Right'
    }

    # today: does the current window follow the plan, and what is in its way
    $y += Px 32
    $statusText = ''; $statusColor = $P.Muted
    $current = $script:View
    $next = @($view.Slots | Where-Object { $_ -gt (Get-Date) }) | Select-Object -First 1
    $nextText = if ($next) { Format-DialogDateTime $next (Get-Date) } else { '' }
    if (-not $on) {
        $statusText = Tx 'Act\u00edvala y la bandeja agenda sola estas sesiones para los pr\u00f3ximos d\u00edas.'
    } elseif ($current -and $current.HasData -and $current.Session.Active) {
        if (Test-AutoAligned $current.Session.ResetsAt $plan.Starts) {
            $statusText = (Tx '\u2713 La sesi\u00f3n actual sigue el plan: termina a las ') + (Format-Clock $current.Session.ResetsAt) + '.'; $statusColor = $P.Ok
        } else {
            $statusText = (Tx 'La sesi\u00f3n actual termina a las ') + (Format-Clock $current.Session.ResetsAt) + (Tx ', fuera del plan: la cadena sigue en la pr\u00f3xima sesi\u00f3n autom\u00e1tica.'); $statusColor = $P.Warn
        }
    } elseif ($nextText) {
        $statusText = (Tx 'Ninguna sesi\u00f3n en curso: la pr\u00f3xima autom\u00e1tica es ') + $nextText + '.'
    }
    $conflicts = @($view.Conflicts)
    if ($conflicts.Count) {
        # Always a button: they interrupt the chain whether the agenda is on yet or not.
        $label = (L 'Limpiar ') + $conflicts.Count
        $bw = Get-PillWidth $label
        Draw-PillButton $G $Map $Hover 'auto-conflicts' (New-Rect ($Card.Right - (Px 16) - $bw) $y $bw (Px 24)) $label { Remove-AutoConflicts } -Accent
        $times = @($conflicts | Select-Object -First 2 | ForEach-Object { Format-DialogDateTime $_.At (Get-Date) }) -join ', '
        $statusText = "$($conflicts.Count) " + $(if ($conflicts.Count -eq 1) { 'agendada a mano interrumpe' } else { 'agendadas a mano interrumpen' }) + (L ' la cadena (') + $times + $(if ($conflicts.Count -gt 2) { (Tx '\u2026') } else { '' }) + ')'
        $statusColor = $P.Warn
        Draw-Text $G $statusText $F.Small $statusColor $x $y ($w - $bw - (Px 10)) (Px 24)
    } else {
        Draw-Text $G $statusText $F.Small $statusColor $x $y $w (Px 24)
    }
    Draw-Text $G ((Tx 'Calculado con tus \u00faltimos 30 d\u00edas; la bandeja mantiene agendados los pr\u00f3ximos ') + $settings.days + (Tx ' d\u00edas.')) $F.Small $P.Faint $x ($y + (Px 24)) $w (Px 18)
}

# ---------------------------------------------------------------- Planear sesion

# Planear sesion: the automatic agenda told as its idea. A short message opens each 5-hour window at the right
# time, so the hour you use Claude most falls on the change from one window to the next: that hour has the end of
# one window and the start of another to spend. Maxx Judge (put a plan on trial) stays one link away.
function Draw-HubPlanSession($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    if ($script:Hub.PlanJudge -and (Test-HubModule 'judge')) {
        Draw-HubPlanSection $G $Map $Hover $X0 $Inner
        $back = New-Rect $X0 ($script:Hub.H - (Px 40)) (Px 260) (Px 20)
        Draw-Text $G (Tx '\u2039 Volver a planear la sesi\u00f3n') $F.Small $(if ($Hover -eq 'plan-back') { $P.AccentHover } else { $P.Accent }) $back.X $back.Y $back.Width $back.Height
        Add-Hit $Map 'plan-back' $back { $script:Hub.PlanJudge = $false; $script:HubDialog.Invalidate() }
        return
    }
    $view = $script:Hub.Cache.Auto
    $plan = if ($view) { $view.Plan } else { $null }
    $settings = if ($view) { $view.Settings } else { Get-AutoPlanSettings $null }
    $on = [bool]$settings.enabled

    # what it does, in one line, with this PC's numbers
    $y = Px 70
    if ($plan -and $plan.HasData) {
        # The message whose window ends at the peak: five hours before it.
        $first = Format-HourMark (([int]$plan.Boundary + 19) % 24) 5
        $lead = (Tx 'Tu hora de m\u00e1s uso es a las {0}. Un mensaje corto a las {1} abre una ventana de 5 h que acaba justo ah\u00ed: tu pico tiene el final de una ventana y el comienzo de la siguiente.') -f (Format-HourMark $plan.Boundary), $first
    } else {
        $lead = Tx 'Hace falta saber cu\u00e1ndo usas Claude: abre Estad\u00edsticas una vez (lee tus conversaciones de Claude Code) y vuelve aqu\u00ed.'
    }
    Draw-Wrapped $G $lead $F.Body $P.Muted $X0 $y $Inner (Px 40)

    # the day: average use per hour, the 5-hour windows under it and the change at the peak
    $card = New-Rect $X0 (Px 116) $Inner (Px 160)
    Draw-HubCard $G $card
    Draw-Text $G (Tx 'TU D\u00cdA \u00b7 USO MEDIO POR HORA Y VENTANAS DE 5 H') $F.Caps $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 12)) ($card.Width - (Px 32)) (Px 18)
    if ($plan -and $plan.HasData) {
        $line = New-Rect ($card.X + (Px 16)) ($card.Y + (Px 54)) ($card.Width - (Px 32)) (Px 92)
        $hourW = $line.Width / 24.0
        $bandY = $line.Y
        $bandH = Px 62
        # the windows as bands behind the bars, in turn lighter and darker, each with its hours
        for ($i = 0; $i -lt $plan.Starts.Count; $i++) {
            $from = ($plan.Starts[$i] % 24) + 5 / 60.0
            $to = $from + 5
            $tint = New-Object System.Drawing.SolidBrush($(if ($i % 2) { [System.Drawing.Color]::FromArgb(40, $P.Muted) } else { [System.Drawing.Color]::FromArgb(70, $P.Muted) }))
            foreach ($segment in @(@($from, $to), @(($from - 24), ($to - 24)))) {
                $a = [Math]::Max(0.0, [double]$segment[0]); $b = [Math]::Min(24.0, [double]$segment[1])
                if ($b -le $a) { continue }
                $G.FillRectangle($tint, [single]($line.X + $a * $hourW), [single]$bandY, [single](($b - $a) * $hourW), [single]$bandH)
                if ($segment[0] -ge 0 -and ($b - $a) -ge 3) {
                    Draw-Text $G ((Format-HourMark ([int]$plan.Starts[$i]) 5) + (Tx '\u2013') + (Format-HourMark (([int]$plan.Starts[$i] + 5) % 24) 5)) $F.Small $P.Muted ([int]($line.X + $a * $hourW) + (Px 6)) ($bandY + (Px 2)) ([int](($b - $a) * $hourW)) (Px 18)
                }
            }
            $tint.Dispose()
        }
        $maxUse = ($plan.Profile | Measure-Object -Maximum).Maximum
        $barsH = Px 40
        for ($h = 0; $h -lt 24; $h++) {
            $value = [double]$plan.Profile[$h]
            if ($maxUse -le 0 -or $value -le 0) { continue }
            $bh = [Math]::Max((Px 2), [int]($barsH * $value / $maxUse))
            $bx = $line.X + [int]($h * $hourW) + (Px 2)
            $peak = $h -eq $plan.Peak.Start -or $h -eq (($plan.Peak.Start + 1) % 24)
            Draw-HubBar $G (New-Rect $bx ($bandY + $bandH - $bh) ([int]$hourW - (Px 4)) $bh) (Px 2) $(if ($peak) { $P.AccentHover } else { $P.Faint })
        }
        # the change at the peak, in the accent
        $mx = [int]($line.X + ($plan.Boundary + 5 / 60.0) * $hourW)
        $pen = New-HubPen $P.Accent 2
        $G.DrawLine($pen, $mx, $bandY - (Px 14), $mx, $bandY + $bandH)
        $pen.Dispose()
        $mark = (Tx 'pico {0} \u00b7 cambio de ventana') -f (Format-HourMark $plan.Boundary)
        $mw = (Measure-TextWidth $mark $F.Small) + (Px 8)
        Draw-Text $G $mark $F.Small $P.Accent ([Math]::Min($mx + (Px 6), $line.Right - $mw)) ($bandY - (Px 20)) $mw (Px 18)
        $tx = $line.X
        foreach ($hour in 0, 6, 12, 18, 24) {
            Draw-Text $G ('{0:00}' -f $hour) $F.Small $P.Faint ([int]($line.X + $hour * $hourW) - (Px 12)) ($bandY + $bandH + (Px 4)) (Px 24) (Px 16) 'Center'
        }
    }

    # settings (left) and the next messages (right)
    $gap = Px 12
    $leftW = [int](($Inner - $gap) * 0.56)
    $scard = New-Rect $X0 ($card.Bottom + $gap) $leftW (Px 226)
    Draw-HubCard $G $scard
    $rowX = $scard.X + (Px 6)
    $rowW = $scard.Width - (Px 12)
    $hasPlan = $plan -and $plan.HasData
    Draw-HubToggleRow $G $Map $Hover 'plan-auto' (New-Rect $rowX ($scard.Y + (Px 8)) $rowW (Px 42)) 'Abrir las ventanas solo' (Tx 'Un mensaje corto a Claude en cada cambio') $on $(if ($hasPlan) { [scriptblock]::Create("Set-AutoEnabled `$$(-not $on)") } else { $null }) $hasPlan
    $peaks = [ordered]@{ '-1' = $(if ($hasPlan -and -not $plan.Manual) { (Tx 'Autom\u00e1tica ({0})') -f (Format-HourMark $plan.Boundary) } else { Tx 'Autom\u00e1tica' }) }
    for ($h = 0; $h -lt 24; $h++) { $peaks["$h"] = Format-HourMark $h }
    $current = if ($settings.boundary -ge 0) { "$($settings.boundary)" } else { '-1' }
    Draw-HubDropdown $G $Map $Hover 'plan-peak' (New-Rect $rowX ($scard.Y + (Px 56)) $rowW (Px 30)) 'Hora pico' $peaks $current 'Step-HubPlanPeak' $hasPlan
    $days = [ordered]@{}
    for ($d = 1; $d -le 7; $d++) { $days["$d"] = $(if ($d -eq 1) { Tx '1 d\u00eda' } else { (Tx '{0} d\u00edas') -f $d }) }
    Draw-HubDropdown $G $Map $Hover 'plan-days' (New-Rect $rowX ($scard.Y + (Px 90)) $rowW (Px 30)) 'Agendar por delante' $days "$($settings.days)" 'Step-HubPlanDays' $hasPlan
    $fx = $scard.X + (Px 16)
    $fw = $scard.Width - (Px 32)
    Draw-Text $G (Tx 'Desde d\u00f3nde se env\u00eda') $F.Body $P.Text $fx ($scard.Y + (Px 130)) $fw (Px 22)
    Draw-Wrapped $G 'Desde este PC (Programador de tareas): tiene que estar encendido. Con el PC apagado, usa la nube.' $F.Small $P.Muted $fx ($scard.Y + (Px 152)) $fw (Px 36)
    $cloud = New-Rect $fx ($scard.Y + (Px 192)) (Px 220) (Px 20)
    Draw-Text $G (Tx 'Agendar en la nube \u203a') $F.Small $(if ($Hover -eq 'plan-cloud') { $P.AccentHover } else { $P.Accent }) $cloud.X $cloud.Y $cloud.Width $cloud.Height
    Add-Hit $Map 'plan-cloud' $cloud { Open-HubSchedule }

    $ncard = New-Rect ($X0 + $leftW + $gap) $scard.Y ($Inner - $leftW - $gap) $scard.Height
    Draw-HubCard $G $ncard
    $nx = $ncard.X + (Px 16)
    $nw = $ncard.Width - (Px 32)
    Draw-Text $G (Tx 'PR\u00d3XIMOS MENSAJES') $F.Caps $P.Muted $nx ($ncard.Y + (Px 12)) $nw (Px 18)
    $slots = if ($view) { @($view.Slots) } else { @() }
    $ny = $ncard.Y + (Px 36)
    if (-not $on -or -not $slots.Count) {
        Draw-Wrapped $G $(if ($on) { Tx 'Nada que agendar todav\u00eda.' } else { Tx 'Apagado: act\u00edvalo para que ClaudeMaxxing abra cada ventana a su hora.' }) $F.Small $P.Muted $nx $ny $nw (Px 40)
    } else {
        $now = Get-Date
        foreach ($slot in @($slots | Select-Object -First 4)) {
            $at = [datetime]$slot
            Draw-Text $G (Format-DialogDateTime $at $now) $F.Body $P.Text $nx $ny $nw (Px 20)
            Draw-Text $G ((Tx 'abre {0}') -f ((Format-HourMark $at.Hour $at.Minute) + (Tx '\u2013') + (Format-HourMark ($at.Hour + 5) $at.Minute))) $F.Small $P.Muted $nx $ny $nw (Px 20) 'Right'
            $ny += Px 34
        }
    }
    $conflicts = if ($view) { @($view.Conflicts).Count } else { 0 }
    if ($conflicts) {
        $label = 'Limpiar'
        $bw = Get-PillWidth $label
        Draw-Text $G $(if ($conflicts -eq 1) { Tx '1 sesi\u00f3n agendada a mano corta la cadena' } else { (Tx '{0} sesiones agendadas a mano cortan la cadena') -f $conflicts }) $F.Small $P.Warn $nx ($ncard.Bottom - (Px 34)) ($nw - $bw - (Px 8)) (Px 24)
        Draw-PillButton $G $Map $Hover 'plan-clean' (New-Rect ($ncard.Right - (Px 16) - $bw) ($ncard.Bottom - (Px 34)) $bw (Px 24)) $label { Remove-AutoConflicts }
    }

    # Maxx Judge, one link away: put what you want to do today on trial before opening sessions.
    if (Test-HubModule 'judge') {
        $judge = New-Rect $X0 ($scard.Bottom + (Px 12)) $Inner (Px 20)
        Draw-Text $G (Tx 'Antes de empezar, pon a prueba lo que vas a hacer hoy con Maxx Judge \u203a') $F.Small $(if ($Hover -eq 'plan-judge') { $P.AccentHover } else { $P.Accent }) $judge.X $judge.Y $judge.Width $judge.Height
        Add-Hit $Map 'plan-judge' $judge { $script:Hub.PlanJudge = $true; $script:HubDialog.Invalidate() }
    }
}

# Hora pico: '-1' (computed) then each hour; Step-AutoBoundary moves the hour by a delta or resets it.
function Step-HubPlanPeak([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $view = $script:Hub.Cache.Auto
    if (-not $view -or -not $view.Plan) { return }
    $keys = @('-1') + @(0..23 | ForEach-Object { "$_" })
    $current = if ($view.Settings.boundary -ge 0) { "$($view.Settings.boundary)" } else { '-1' }
    $target = $keys[[Math]::Max(0, [Math]::Min($keys.Count - 1, [array]::IndexOf($keys, $current) + $Delta))]
    if ($target -eq '-1') { Step-AutoBoundary 0 -Reset } else { Step-AutoBoundary ([int]$target - [int]$view.Plan.Boundary) }
}

function Step-HubPlanDays([int]$Delta) {
    if ($script:Hub.Preview) { return }
    $settings = Get-AutoPlanSettings (Read-JsonFile $AutoPlanFile)
    $settings.days = [Math]::Max(1, [Math]::Min(7, [int]$settings.days + $Delta))
    Save-AutoSettings $settings
    if ($settings.enabled) { Invoke-AutoSchedule -Force }
    Update-HubAuto
}
