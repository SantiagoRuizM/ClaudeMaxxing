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
    try { Write-JsonFile $AutoPlanFile $Settings } catch { }
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
    if ($result -and $result.Error) { Set-HubMessage ('No se pudo agendar: ' + $result.Error) }
    elseif ($On) { Set-HubMessage ((Tx '\u2713 Agenda autom\u00e1tica activa') + $(if ($result) { " ($($result.Added) sesiones agendadas)" } else { '' })) }
    else { Set-HubMessage ((Tx 'Agenda autom\u00e1tica apagada') + $(if ($result -and $result.Removed) { " ($($result.Removed) quitadas)" } else { '' })) }
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
    $ask = if ($conflicts.Count -eq 1) { Tx '\u00bfQuitar la sesi\u00f3n agendada a mano que corta la cadena?' } else { Tx "\u00bfQuitar las $($conflicts.Count) sesiones agendadas a mano que cortan la cadena?" }
    if (-not (Confirm-UiAction $ask $script:HubDialog)) { return }
    $count = 0
    foreach ($task in $conflicts) { if (Remove-SessionTask $task.Name) { $count++ } }
    Update-ScheduleState
    Invoke-AutoSchedule -Force
    $failed = $conflicts.Count - $count
    if ($failed -gt 0) { Set-HubMessage "No se pudieron quitar $failed de $($conflicts.Count): mira el Programador de tareas." -Error }
    else { Set-HubMessage ((Tx '\u2713 ') + $(if ($count -eq 1) { 'Limpiada 1 agendada a mano' } else { "Limpiadas $count agendadas a mano" })) }
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
    $headline = 'Tu franja de m' + (Tx '\u00e1') + 's uso: ' + (Format-HourMark $peak.Start) + (Tx '\u2013') + (Format-HourMark $peak.End) +
        '  ' + (Tx '\u00b7') + '  ' + (Format-HubDuration $peak.Seconds) + ' de media al d' + (Tx '\u00ed') + 'a'
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
    $startsText = 'Sesiones a las ' + (@($plan.Starts | ForEach-Object { Format-HourMark $_ 5 }) -join (Tx ' \u00b7 '))
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
            $statusText = (Tx '\u2713 La ventana actual sigue el plan: cambia a las ') + (Format-Clock $current.Session.ResetsAt) + '.'; $statusColor = $P.Ok
        } else {
            $statusText = 'La ventana actual cambia a las ' + (Format-Clock $current.Session.ResetsAt) + ', fuera del plan: se reengancha en la siguiente sesi' + (Tx '\u00f3') + 'n.'; $statusColor = $P.Warn
        }
    } elseif ($nextText) {
        $statusText = 'Sin ventana abierta: la pr' + (Tx '\u00f3') + 'xima sesi' + (Tx '\u00f3') + 'n autom' + (Tx '\u00e1') + 'tica es ' + $nextText + '.'
    }
    $conflicts = @($view.Conflicts)
    if ($conflicts.Count) {
        # Always a button: they interrupt the chain whether the agenda is on yet or not.
        $label = 'Limpiar ' + $conflicts.Count
        $bw = Get-PillWidth $label
        Draw-PillButton $G $Map $Hover 'auto-conflicts' (New-Rect ($Card.Right - (Px 16) - $bw) $y $bw (Px 24)) $label { Remove-AutoConflicts } -Accent
        $times = @($conflicts | Select-Object -First 2 | ForEach-Object { Format-DialogDateTime $_.At (Get-Date) }) -join ', '
        $statusText = "$($conflicts.Count) " + $(if ($conflicts.Count -eq 1) { 'agendada a mano interrumpe' } else { 'agendadas a mano interrumpen' }) + ' la cadena (' + $times + $(if ($conflicts.Count -gt 2) { (Tx '\u2026') } else { '' }) + ')'
        $statusColor = $P.Warn
        Draw-Text $G $statusText $F.Small $statusColor $x $y ($w - $bw - (Px 10)) (Px 24)
    } else {
        Draw-Text $G $statusText $F.Small $statusColor $x $y $w (Px 24)
    }
    Draw-Text $G ((Tx 'Calculado con tus \u00faltimos 30 d\u00edas; la bandeja mantiene agendados los pr\u00f3ximos ') + $settings.days + (Tx ' d\u00edas.')) $F.Small $P.Faint $x ($y + (Px 24)) $w (Px 18)
}
