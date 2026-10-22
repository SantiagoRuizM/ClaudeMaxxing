# Pure helpers: turn the statusline snapshot into what the popup shows. No UI here, so tests can cover it.

$script:EnUs = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')

# Snapshot older than this means no Claude Code session is reporting right now.
$script:FreshMinutes = 10

function ConvertFrom-UnixTime([double]$Seconds) {
    [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor($Seconds)).LocalDateTime
}

# One rate-limit window (five_hour or seven_day). Claude Code drops a window once it resets,
# but the snapshot file keeps the last values, so an expired window is treated as inactive here.
function Get-WindowView($Window, [datetime]$Now) {
    if ($null -eq $Window -or $null -eq $Window.resets_at) {
        return [pscustomobject]@{ Active = $false; Percent = 0; ResetsAt = $null }
    }
    $resetsAt = ConvertFrom-UnixTime ([double]$Window.resets_at)
    if ($Now -ge $resetsAt) {
        return [pscustomobject]@{ Active = $false; Percent = 0; ResetsAt = $null }
    }
    $pct = [Math]::Round([double]$Window.used_percentage)
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    [pscustomobject]@{ Active = $true; Percent = [int]$pct; ResetsAt = $resetsAt }
}

function Get-UsageView($Snapshot, [datetime]$Now) {
    $limits = $null
    $ageMinutes = $null
    if ($null -ne $Snapshot) {
        $limits = $Snapshot.rate_limits
        if ($null -ne $Snapshot.updated_at) {
            $ageMinutes = ($Now - (ConvertFrom-UnixTime ([double]$Snapshot.updated_at))).TotalMinutes
        }
    }
    [pscustomobject]@{
        HasData    = ($null -ne $limits)
        Session    = Get-WindowView $(if ($limits) { $limits.five_hour }) $Now
        Weekly     = Get-WindowView $(if ($limits) { $limits.seven_day }) $Now
        AgeMinutes = $ageMinutes
        Fresh      = ($null -ne $ageMinutes -and $ageMinutes -lt $script:FreshMinutes)
    }
}

function Format-Remaining([timespan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return '<1m' }
    $days = [int][Math]::Floor($Span.TotalDays)
    if ($days -ge 1) { return ('{0}d {1}h' -f $days, $Span.Hours) }
    if ($Span.Hours -ge 1) { return ('{0}h {1}m' -f $Span.Hours, $Span.Minutes) }
    return ('{0}m' -f $Span.Minutes)
}

# "Hoy \u00b7 1:59 p. m. (en 2h 11m)"; day and clock come from Format-DialogDateTime (lib\schedule.ps1).
function Format-ResetText([datetime]$ResetsAt, [datetime]$Now) {
    (Format-DialogDateTime $ResetsAt $Now) + ' (en ' + (Format-Remaining ($ResetsAt - $Now)) + ')'
}

# How old the usage data is.
function Format-Age($AgeMinutes) {
    if ($null -eq $AgeMinutes) { return 'Sin datos' }
    $minutes = [int][Math]::Floor($AgeMinutes)
    if ($minutes -lt 1) { return 'Actualizado ahora' }
    if ($minutes -lt 60) { return "Actualizado hace $minutes min" }
    'Actualizado hace {0} h' -f [int][Math]::Floor($minutes / 60)
}

# Where the popup goes: in the corner next to the taskbar's clock, wherever the taskbar is (bottom, top or left;
# right is like bottom). $Work is the screen's working area and $Bounds the whole screen.
function Get-PopupLocation($Work, $Bounds, [int]$Width, [int]$Height, [int]$Margin) {
    $x = $Work.Right - $Width - $Margin
    $y = $Work.Bottom - $Height - $Margin
    if ($Work.Top -gt $Bounds.Top) { $y = $Work.Top + $Margin }
    if ($Work.Left -gt $Bounds.Left) { $x = $Work.Left + $Margin }
    @($x, $y)
}

function Get-UsageLevel([double]$Percent) {
    if ($Percent -ge 80) { return 'high' }
    if ($Percent -ge 50) { return 'medium' }
    'low'
}

# Tooltip text; NotifyIcon.Text throws above 63 characters on .NET Framework.
function Format-TrayTooltip($View, [string]$Plan) {
    $head = 'Claude'
    if ($Plan) { $head = "Claude $Plan" }
    if (-not $View.HasData) { return "$head - sin datos de uso" }
    $s = if ($View.Session.Active) { "$($View.Session.Percent)%" } else { 'sin empezar' }
    $w = if ($View.Weekly.Active) { "$($View.Weekly.Percent)%" } else { '-' }
    $text = "$head - " + (Tx 'Sesi\u00f3n') + " $s - Semanal $w"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $text
}

# Plan name from the credentials file. Only subscriptionType is read; tokens are never touched.
function Get-PlanName([string]$CredentialsPath) {
    if (-not (Test-Path -LiteralPath $CredentialsPath)) { return '' }
    try {
        $creds = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
        $plan = [string]$creds.claudeAiOauth.subscriptionType
        return $plan.ToUpperInvariant()
    } catch { return '' }
}

# ---------------------------------------------------------------- session planning

# A window lasts 5 hours from the first message. The server may round the start (the statusline
# has reported hh:00 resets, the usage endpoint hh:50), so the dialog labels this as approximate.
function Get-ProjectedWindow([datetime]$At) {
    $start = $At.Date.AddHours($At.Hour).AddMinutes($At.Minute)
    [pscustomobject]@{ Start = $start; End = $start.AddHours(5) }
}

# Suggested start: 5 minutes past the hour right after the current window ends, or after now when idle.
function Get-DefaultScheduleTime($View, [datetime]$Now) {
    $base = if ($View -and $View.Session.Active) { $View.Session.ResetsAt } else { $Now }
    $at = $base.Date.AddHours($base.Hour).AddMinutes(5)
    if ($at -le $base) { $at = $at.AddHours(1) }
    $at
}

# A message sent before the current window resets lands in that window and moves nothing.
function Test-InsideCurrentSession($View, [datetime]$At) {
    [bool]($View -and $View.Session.Active -and $At -lt $View.Session.ResetsAt)
}

# Fraction of the current 5-hour window already elapsed (0..1), for the status bar in the dialog.
function Get-SessionElapsedFraction($View, [datetime]$Now) {
    if (-not ($View -and $View.Session.Active)) { return 0 }
    $remaining = ($View.Session.ResetsAt - $Now).TotalHours
    # Double literals: with 0 / 1 PowerShell would pick the integer overloads and round.
    [Math]::Max([double]0, [Math]::Min([double]1, (5 - $remaining) / 5))
}

# ---------------------------------------------------------------- week plan

# Back-to-back 5-hour windows get the most out of the weekly limit. The plan places SessionsPerDay
# windows a day, 5 hours apart from FirstHour:05, up to the weekly cutoff, and spreads what is left of
# the weekly limit over them. The share per session is a target: nothing reports how much of the weekly
# limit one window uses. CutoffWeekday / CutoffHour only matter when there is no weekly data at all.
$script:WeekPlanDefaults = [ordered]@{ SessionsPerDay = 3; FirstHour = 7; CutoffWeekday = 4; CutoffHour = 14 }

# Windows that start before midnight when the first one starts at FirstHour:05.
function Get-MaxSessionsPerDay([int]$FirstHour) {
    [int][Math]::Floor((1440 - ($FirstHour * 60 + 5) - 1) / 300) + 1
}

function Get-PlanSettings($Saved) {
    $settings = [ordered]@{}
    foreach ($key in $script:WeekPlanDefaults.Keys) {
        $value = $script:WeekPlanDefaults[$key]
        if ($Saved -and $null -ne $Saved.$key) { try { $value = [int]$Saved.$key } catch { } }
        $settings[$key] = $value
    }
    $settings.FirstHour = [Math]::Max(0, [Math]::Min(23, $settings.FirstHour))
    $settings.SessionsPerDay = [Math]::Max(1, [Math]::Min((Get-MaxSessionsPerDay $settings.FirstHour), $settings.SessionsPerDay))
    $settings.CutoffWeekday = [Math]::Max(0, [Math]::Min(6, $settings.CutoffWeekday))
    $settings.CutoffHour = [Math]::Max(0, [Math]::Min(23, $settings.CutoffHour))
    $settings
}

# When the weekly limit resets. From the snapshot while its window is active; an expired window is
# rolled forward in 7-day steps (usage starts again from 0); with no weekly data, the saved weekday/hour.
function Get-WeekCutoff($Snapshot, $Settings, [datetime]$Now) {
    $weekly = $null
    if ($Snapshot -and $Snapshot.rate_limits) { $weekly = $Snapshot.rate_limits.seven_day }
    if ($weekly -and $null -ne $weekly.resets_at) {
        $resetsAt = ConvertFrom-UnixTime ([double]$weekly.resets_at)
        if ($resetsAt -gt $Now) {
            $used = [Math]::Max([double]0, [Math]::Min([double]100, [double]$weekly.used_percentage))
            return [pscustomobject]@{ At = $resetsAt; Source = 'data'; Used = $used }
        }
        $weeks = [Math]::Floor(($Now - $resetsAt).TotalDays / 7) + 1
        return [pscustomobject]@{ At = $resetsAt.AddDays(7 * $weeks); Source = 'rolled'; Used = [double]0 }
    }
    $at = $Now.Date.AddHours($Settings.CutoffHour)
    while ([int]$at.DayOfWeek -ne $Settings.CutoffWeekday -or $at -le $Now) { $at = $at.AddDays(1) }
    [pscustomobject]@{ At = $at; Source = 'manual'; Used = [double]0 }
}

# Slots: the current window (if any) and the planned ones before the cutoff. Weight is the part of a
# window that falls before the cutoff (1 = full 5 hours); Target is its share of the weekly limit and
# EndPercent the weekly usage the plan expects once it is over. Days groups the slots by start date
# (the current window counts for today).
function Get-WeekPlan($Snapshot, $Settings, [datetime]$Now) {
    $view = Get-UsageView $Snapshot $Now
    $cutoff = Get-WeekCutoff $Snapshot $Settings $Now
    $slots = New-Object System.Collections.ArrayList
    if ($view.Session.Active) {
        $end = if ($view.Session.ResetsAt -lt $cutoff.At) { $view.Session.ResetsAt } else { $cutoff.At }
        [void]$slots.Add([pscustomobject]@{ Start = $view.Session.ResetsAt.AddHours(-5); End = $view.Session.ResetsAt; Day = $Now.Date
            Weight = [Math]::Max([double]0, ($end - $Now).TotalHours / 5); Current = $true; Target = [double]0; EndPercent = [double]0 })
    }
    $free = Get-DefaultScheduleTime $view $Now
    for ($day = $Now.Date; $day -lt $cutoff.At; $day = $day.AddDays(1)) {
        $at = $day.AddHours($Settings.FirstHour).AddMinutes(5)
        if ($at -lt $free) { $at = $free }
        $taken = if ($day -eq $Now.Date -and $view.Session.Active) { 1 } else { 0 }
        while ($taken -lt $Settings.SessionsPerDay -and $at -lt $day.AddDays(1)) {
            # A window starting in the last half hour before the cutoff is not worth a session.
            $useful = [Math]::Min([double]5, ($cutoff.At - $at).TotalHours)
            if ($useful -lt 0.5) { break }
            [void]$slots.Add([pscustomobject]@{ Start = $at; End = $at.AddHours(5); Day = $day
                Weight = $useful / 5; Current = $false; Target = [double]0; EndPercent = [double]0 })
            $taken++
            $at = $at.AddHours(5)
            $free = $at
        }
    }

    $remaining = [Math]::Max([double]0, 100 - $cutoff.Used)
    $totalWeight = [double]0
    foreach ($slot in $slots) { $totalWeight += $slot.Weight }
    $perSession = if ($totalWeight -gt 0) { $remaining / $totalWeight } else { [double]0 }
    $running = $cutoff.Used
    foreach ($slot in $slots) {
        $slot.Target = $perSession * $slot.Weight
        $running += $slot.Target
        $slot.EndPercent = [Math]::Min([double]100, $running)
    }
    $days = foreach ($group in @($slots | Group-Object { $_.Day.ToString('yyyy-MM-dd') })) {
        $daySlots = @($group.Group)
        [pscustomobject]@{ Date = $daySlots[0].Day; Slots = $daySlots; EndPercent = $daySlots[-1].EndPercent }
    }
    $elapsed = 1 - ($cutoff.At - $Now).TotalDays / 7
    [pscustomobject]@{
        Cutoff = $cutoff.At; CutoffSource = $cutoff.Source; UsedPercent = $cutoff.Used; RemainingPercent = $remaining
        PerSession = $perSession; SessionCount = $slots.Count; WeekElapsed = [Math]::Max([double]0, [Math]::Min([double]1, $elapsed))
        Slots = @($slots); Days = @($days)
    }
}

# Planned windows still to start that have nothing scheduled within 30 minutes of them.
function Get-UnbookedSlots($Slots, $Booked, [datetime]$Now) {
    @($Slots | Where-Object {
        $slot = $_
        -not $slot.Current -and $slot.Start -gt $Now.AddMinutes(1) -and
            -not @($Booked | Where-Object { $_ -and [Math]::Abs(($_ - $slot.Start).TotalMinutes) -lt 30 }).Count
    })
}

# ---------------------------------------------------------------- extras (extra usage, limit reset)

# Extras only come from the live refresh; after this long without one they are hidden.
$script:ExtrasMaxAgeHours = 12

function Format-Money($Minor, [string]$Currency) {
    $amount = [double]$Minor / 100
    if (-not $Currency -or $Currency -eq 'USD') { return $amount.ToString('C2', $script:EnUs) }
    $amount.ToString('N2', $script:EnUs) + ' ' + $Currency
}

function Get-ExtrasView($Extras, [datetime]$Now) {
    $view = [pscustomobject]@{ ExtraUsage = $null; LimitReset = $null }
    if ($null -eq $Extras -or $null -eq $Extras.updated_at) { return $view }
    if (($Now - (ConvertFrom-UnixTime ([double]$Extras.updated_at))).TotalHours -gt $script:ExtrasMaxAgeHours) { return $view }

    $extra = $Extras.extra_usage
    if ($extra) {
        $pct = $null
        if ($null -ne $extra.utilization) { $pct = [int][Math]::Max(0, [Math]::Min(100, [Math]::Round([double]$extra.utilization))) }
        $amount = ''
        if ($null -ne $extra.used_minor -and $null -ne $extra.limit_minor) {
            $amount = (Format-Money $extra.used_minor $extra.currency) + ' de ' + (Format-Money $extra.limit_minor $extra.currency) + ' este mes'
        } elseif ($null -ne $extra.used_minor) {
            $amount = (Format-Money $extra.used_minor $extra.currency) + ' usados este mes'
        }
        $view.ExtraUsage = [pscustomobject]@{ Percent = $pct; AmountText = $amount }
    }

    $reset = $Extras.limit_reset
    if ($reset) {
        $detail = Tx 'Deja un l\u00edmite a cero; recl\u00e1malo en claude.ai'
        if ($reset.resets_per_week) { $detail = "$($reset.resets_per_week) " + (Tx 'por semana; recl\u00e1malo en claude.ai') }
        $view.LimitReset = [pscustomobject]@{ Title = (Tx 'Reinicio de l\u00edmite disponible'); Detail = $detail }
    }
    $view
}
