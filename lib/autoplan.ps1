# Agenda automatica: sessions scheduled so the hours you use Claude the most fall on the change between two
# 5-hour windows, and so windows follow each other through your day with no gap.
#   - The usage profile is the average time with Claude per hour of the day over the last 30 days
#     (Estadisticas, lib\stats.cs).
#   - The peak zone is the 2-hour stretch with the most average use; its middle is the boundary: one window
#     ends there and the next starts, so the busiest part of the day is split between two windows' limits.
#   - From the boundary the chain goes back and forth in 5-hour steps over the active part of the day (from
#     the end of the longest quiet stretch, usually the night, to its start). Each start is HH:05, like the
#     week plan, so the previous window has reset.
#   - The tray keeps Task Scheduler tasks (named Auto-...) for those starts over the next days, and removes
#     the ones that no longer fit when the plan changes. Tasks scheduled by hand are never touched.
# A window only starts where none is running: if you start one at another time, the chain picks up again
# at the next start that falls after it ends. Pure helpers except Sync-AutoSessions. Keep this file ASCII.

$AutoPlanFile = Join-Path $TrayHome 'autoplan.json'
$AutoTaskPrefix = 'Auto-'
$AutoPeakWidth = 2
$AutoQuietRatio = 0.15
# A new peak zone replaces the one in use only when it beats it by more than this: with an even profile the
# boundary would otherwise jump between days, and moving it mid-day breaks the chain already running.
$AutoKeepMargin = 0.10

function Get-AutoPlanSettings($Saved) {
    # boundary: moved by hand (-1: computed). lastBoundary: the computed one in use, kept unless clearly beaten.
    $settings = [ordered]@{ enabled = $false; boundary = -1; days = 2; lastBoundary = -1 }
    if ($Saved) {
        if ($null -ne $Saved.lastBoundary) { try { $settings.lastBoundary = [int]$Saved.lastBoundary } catch { } }
        if ($null -ne $Saved.enabled) { $settings.enabled = [bool]$Saved.enabled }
        if ($null -ne $Saved.boundary) { try { $settings.boundary = [int]$Saved.boundary } catch { } }
        if ($null -ne $Saved.days) { try { $settings.days = [int]$Saved.days } catch { } }
    }
    if ($settings.boundary -lt -1 -or $settings.boundary -gt 23) { $settings.boundary = -1 }
    if ($settings.lastBoundary -lt -1 -or $settings.lastBoundary -gt 23) { $settings.lastBoundary = -1 }
    $settings.days = [Math]::Max(1, [Math]::Min(7, $settings.days))
    $settings
}

# Average seconds with Claude per hour of the day: the hourly totals over the active days.
function Get-UsageProfile($Hourly, [int]$ActiveDays) {
    $days = [Math]::Max(1, $ActiveDays)
    [double[]]@(for ($h = 0; $h -lt 24; $h++) { [double]@($Hourly)[$h] / $days })
}

# The $Width-hour stretch (it can cross midnight) with the most average use. Boundary is its middle.
function Get-PeakZone([double[]]$Profile, [int]$Width = $AutoPeakWidth) {
    $best = -1; $bestSum = -1.0
    for ($start = 0; $start -lt 24; $start++) {
        $sum = 0.0
        for ($i = 0; $i -lt $Width; $i++) { $sum += $Profile[($start + $i) % 24] }
        if ($sum -gt $bestSum) { $bestSum = $sum; $best = $start }
    }
    [pscustomobject]@{
        Start = $best; End = ($best + $Width) % 24; Boundary = ($best + [int][Math]::Floor($Width / 2)) % 24
        Seconds = $bestSum
    }
}

# The active part of the day: from the end of the longest run of quiet hours (under $Ratio of the busiest
# hour) to its start. End is exclusive and can pass 24 (the day runs past midnight).
function Get-ActiveSpan([double[]]$Profile, [double]$Ratio = $AutoQuietRatio) {
    $max = ($Profile | Measure-Object -Maximum).Maximum
    if ($max -le 0) { return [pscustomobject]@{ Start = 0; End = 24 } }
    $quiet = @(for ($h = 0; $h -lt 24; $h++) { $Profile[$h] -lt $max * $Ratio })
    $bestStart = -1; $bestLength = 0
    for ($start = 0; $start -lt 24; $start++) {
        if (-not $quiet[$start] -or $quiet[($start + 23) % 24]) { continue }
        $length = 0
        while ($length -lt 24 -and $quiet[($start + $length) % 24]) { $length++ }
        if ($length -gt $bestLength) { $bestLength = $length; $bestStart = $start }
    }
    if ($bestLength -eq 0) { return [pscustomobject]@{ Start = 0; End = 24 } }
    $begin = ($bestStart + $bestLength) % 24
    [pscustomobject]@{ Start = $begin; End = $begin + 24 - $bestLength }
}

# Window start hours for one day: 5 hours apart through $Boundary, from the last one at or before the start
# of the active span until the span ends. Hours can pass 24 (a start after midnight belongs to the same day).
function Get-AutoChain([int]$Boundary, $Span) {
    # A boundary after midnight inside a day that runs past it counts as hour 24 and up.
    if ($Boundary -lt $Span.Start -and $Boundary + 24 -lt $Span.End) { $Boundary += 24 }
    $first = $Boundary
    while ($first -gt $Span.Start) { $first -= 5 }
    while ($first + 5 -le $Span.Start) { $first += 5 }
    $starts = @()
    for ($h = $first; $h -lt $Span.End; $h += 5) { $starts += $h }
    # The boundary itself is always a start, even when the profile puts it outside the active span.
    if (@($starts | Where-Object { $_ -eq $Boundary }).Count -eq 0) { $starts += $Boundary; $starts = @($starts | Sort-Object) }
    , [int[]]$starts
}

# Average use inside each window of the chain.
function Get-ChainLoads([double[]]$Profile, [int[]]$Starts) {
    , [double[]]@(foreach ($start in $Starts) { $sum = 0.0; for ($i = 0; $i -lt 5; $i++) { $sum += $Profile[($start + $i) % 24] }; $sum })
}

# Everything the window shows and the tray schedules, from the stats' hourly totals. $Previous: the computed
# boundary in use, kept while the best zone does not beat its zone by more than $AutoKeepMargin.
function Get-AutoPlan($Hourly, [int]$ActiveDays, [int]$BoundaryOverride = -1, [int]$Previous = -1) {
    $usageProfile = Get-UsageProfile $Hourly $ActiveDays
    $peak = Get-PeakZone $usageProfile
    if ($Previous -ge 0 -and $Previous -ne $peak.Boundary) {
        $half = [int][Math]::Floor($AutoPeakWidth / 2)
        $start = ($Previous - $half + 24) % 24
        $sum = 0.0
        for ($i = 0; $i -lt $AutoPeakWidth; $i++) { $sum += $usageProfile[($start + $i) % 24] }
        if ($peak.Seconds -le $sum * (1 + $AutoKeepMargin)) {
            $peak = [pscustomobject]@{ Start = $start; End = ($start + $AutoPeakWidth) % 24; Boundary = $Previous; Seconds = $sum }
        }
    }
    $boundary = if ($BoundaryOverride -ge 0) { $BoundaryOverride } else { $peak.Boundary }
    $span = Get-ActiveSpan $usageProfile
    $starts = Get-AutoChain $boundary $span
    [pscustomobject]@{
        Profile = $usageProfile; Peak = $peak; Boundary = $boundary; Manual = ($BoundaryOverride -ge 0); Span = $span
        Starts = $starts; Loads = (Get-ChainLoads $usageProfile $starts); HasData = (($usageProfile | Measure-Object -Sum).Sum -gt 0)
    }
}

# Start times for today and the next days, each at HH:05, later than now, and none inside the window before it.
function Get-AutoSlots([int[]]$Starts, [datetime]$Now, [int]$Days) {
    $slots = New-Object System.Collections.Generic.List[datetime]
    $lastEnd = [datetime]::MinValue
    for ($d = -1; $d -le $Days; $d++) {
        $day = $Now.Date.AddDays($d)
        foreach ($start in $Starts) {
            $at = $day.AddHours($start).AddMinutes(5)
            if ($at -lt $lastEnd) { continue }
            $lastEnd = $at.AddHours(5)
            if ($at -gt $Now.AddMinutes(2) -and $at -lt $Now.Date.AddDays($Days + 1)) { $slots.Add($at) }
        }
    }
    , $slots.ToArray()
}

# Whether today's current window ends on the plan (within 20 minutes of a planned change).
function Test-AutoAligned([datetime]$ResetsAt, [int[]]$Starts) {
    foreach ($d in -1, 0, 1) {
        foreach ($start in $Starts) {
            $change = $ResetsAt.Date.AddDays($d).AddHours($start).AddMinutes(5)
            if ([Math]::Abs(($change - $ResetsAt).TotalMinutes) -le 20) { return $true }
        }
    }
    $false
}

# What to change in Task Scheduler: Add = wanted starts with nothing scheduled within 30 minutes; Remove =
# Auto- tasks still to come that the plan no longer has.
function Get-AutoChanges([datetime[]]$Wanted, $Tasks, [datetime]$Now) {
    # (piping an empty list would send one $null through)
    $Wanted = @($Wanted | Where-Object { $_ })
    $tasks = @($Tasks | Where-Object { $_ -and $_.At -gt $Now })
    $add = @($Wanted | Where-Object { $at = $_; -not @($tasks | Where-Object { [Math]::Abs(($_.At - $at).TotalMinutes) -lt 30 }).Count })
    $remove = @($tasks | Where-Object { $_.Name -like "$AutoTaskPrefix*" } | Where-Object {
        $task = $_; -not @($Wanted | Where-Object { [Math]::Abs(($_ - $task.At).TotalMinutes) -lt 1 }).Count })
    [pscustomobject]@{ Add = $add; Remove = $remove }
}

# Applies the plan (or, disabled, removes the Auto- tasks still to come). Returns @{ Added; Removed }.
function Sync-AutoSessions($Plan, [bool]$Enabled, [int]$Days, $Tasks, [string]$ScriptPath, [datetime]$Now) {
    $wanted = @()
    if ($Enabled -and $Plan -and $Plan.HasData) { $wanted = Get-AutoSlots $Plan.Starts $Now $Days }
    $changes = Get-AutoChanges $wanted $Tasks $Now
    $added = 0; $removed = 0
    foreach ($task in $changes.Remove) { Remove-SessionTask $task.Name; $removed++ }
    foreach ($at in $changes.Add) { New-SessionTask $at $ScriptPath $AutoTaskPrefix; $added++ }
    @{ Added = $added; Removed = $removed }
}

# Tasks scheduled by hand over the next days that would open a window off the plan: not within 30 minutes
# of a planned start. Each one starts its own window and moves every change after it.
function Get-AutoConflicts([datetime[]]$Wanted, $Tasks, [datetime]$Now, [int]$Days) {
    $Wanted = @($Wanted | Where-Object { $_ })
    if (-not $Wanted.Count) { return @() }
    $until = $Now.Date.AddDays($Days + 1)
    @($Tasks | Where-Object { $_ -and $_.Name -notlike "$AutoTaskPrefix*" -and $_.At -gt $Now -and $_.At -lt $until } | Where-Object {
        $task = $_; -not @($Wanted | Where-Object { [Math]::Abs(($_ - $task.At).TotalMinutes) -lt 30 }).Count })
}
