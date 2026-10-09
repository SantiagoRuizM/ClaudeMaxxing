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

# "1:59 PM (2h 11m)" when the reset is today, "Oct 11, 2026 7:59 AM (1d 20h)" otherwise.
function Format-ResetText([datetime]$ResetsAt, [datetime]$Now) {
    $remaining = Format-Remaining ($ResetsAt - $Now)
    if ($ResetsAt.Date -eq $Now.Date) {
        $when = $ResetsAt.ToString('h:mm tt', $script:EnUs)
    } else {
        $when = $ResetsAt.ToString('MMM d, yyyy h:mm tt', $script:EnUs)
    }
    "$when ($remaining)"
}

function Format-Age($AgeMinutes) {
    if ($null -eq $AgeMinutes) { return 'No data yet' }
    if ($AgeMinutes -lt 1) { return 'Updated just now' }
    'Updated ' + (Format-Remaining ([timespan]::FromMinutes($AgeMinutes))) + ' ago'
}

function Format-ShortDateTime([datetime]$Value) {
    $Value.ToString('MMM d h:mm tt', $script:EnUs)
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
    if (-not $View.HasData) { return "$head - no usage data yet" }
    $s = if ($View.Session.Active) { "$($View.Session.Percent)%" } else { 'idle' }
    $w = if ($View.Weekly.Active) { "$($View.Weekly.Percent)%" } else { '-' }
    $text = "$head - Session $s - Weekly $w"
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
            $amount = (Format-Money $extra.used_minor $extra.currency) + ' of ' + (Format-Money $extra.limit_minor $extra.currency) + ' this month'
        } elseif ($null -ne $extra.used_minor) {
            $amount = (Format-Money $extra.used_minor $extra.currency) + ' used this month'
        }
        $view.ExtraUsage = [pscustomobject]@{ Percent = $pct; AmountText = $amount }
    }

    $reset = $Extras.limit_reset
    if ($reset) {
        $detail = 'Restores a limit to full; claim it on claude.ai'
        if ($reset.resets_per_week) { $detail = "$($reset.resets_per_week) per week; claim it on claude.ai" }
        $view.LimitReset = [pscustomobject]@{ Title = 'Limit reset available'; Detail = $detail }
    }
    $view
}
