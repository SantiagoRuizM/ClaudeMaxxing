# Unit tests for the pure helpers (no UI, no Task Scheduler changes).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\usage.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
. (Join-Path $TrayRoot 'lib\statusline.ps1')
. (Join-Path $TrayRoot 'lib\usageapi.ps1')
. (Join-Path $TrayRoot 'lib\sessions.ps1')

$script:Failures = 0
$script:Count = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    $script:Count++
    if ($Expected -ne $Actual) {
        $script:Failures++
        Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red
    } else {
        Write-Host "ok   $Name"
    }
}
function To-Unix([datetime]$Value) { [DateTimeOffset]::new($Value).ToUnixTimeSeconds() }

$now = Get-Date -Year 2026 -Month 10 -Day 9 -Hour 11 -Minute 48 -Second 0 -Millisecond 0

# --- windows
$active = [pscustomobject]@{ used_percentage = 72.4; resets_at = (To-Unix $now.AddHours(2).AddMinutes(11)) }
$view = Get-WindowView $active $now
Assert-Equal $true $view.Active 'active window is active'
Assert-Equal 72 $view.Percent 'percent rounds'

$expired = [pscustomobject]@{ used_percentage = 90; resets_at = (To-Unix $now.AddMinutes(-1)) }
$view = Get-WindowView $expired $now
Assert-Equal $false $view.Active 'expired window is inactive'
Assert-Equal 0 $view.Percent 'expired window shows 0'

Assert-Equal $false (Get-WindowView $null $now).Active 'missing window is inactive'
Assert-Equal 100 (Get-WindowView ([pscustomobject]@{ used_percentage = 104; resets_at = (To-Unix $now.AddHours(1)) }) $now).Percent 'percent clamps to 100'

# --- full view
$snapshot = [pscustomobject]@{
    rate_limits = [pscustomobject]@{
        five_hour = $active
        seven_day = [pscustomobject]@{ used_percentage = 86; resets_at = (To-Unix $now.AddDays(1).AddHours(20)) }
    }
    updated_at = (To-Unix $now.AddMinutes(-3))
}
$usage = Get-UsageView $snapshot $now
Assert-Equal $true $usage.HasData 'snapshot has data'
Assert-Equal $true $usage.Fresh 'snapshot 3 minutes old is fresh'
Assert-Equal 86 $usage.Weekly.Percent 'weekly percent'

$stale = [pscustomobject]@{ rate_limits = $snapshot.rate_limits; updated_at = (To-Unix $now.AddMinutes(-30)) }
Assert-Equal $false (Get-UsageView $stale $now).Fresh 'snapshot 30 minutes old is not fresh'
Assert-Equal $false (Get-UsageView $null $now).HasData 'no snapshot means no data'
Assert-Equal $false (Get-UsageView ([pscustomobject]@{ updated_at = 1 }) $now).HasData 'snapshot without rate_limits means no data'

# --- formatting
Assert-Equal '2h 11m' (Format-Remaining (New-TimeSpan -Hours 2 -Minutes 11)) 'hours and minutes'
Assert-Equal '1d 20h' (Format-Remaining (New-TimeSpan -Days 1 -Hours 20 -Minutes 5)) 'days and hours'
Assert-Equal '45m' (Format-Remaining (New-TimeSpan -Minutes 45)) 'minutes only'
Assert-Equal '<1m' (Format-Remaining (New-TimeSpan -Seconds 20)) 'under a minute'

$sameDay = Get-Date -Year 2026 -Month 10 -Day 9 -Hour 13 -Minute 59 -Second 0 -Millisecond 0
Assert-Equal '1:59 PM (2h 11m)' (Format-ResetText $sameDay $now) 'reset text today'
$otherDay = Get-Date -Year 2026 -Month 10 -Day 11 -Hour 7 -Minute 59 -Second 0 -Millisecond 0
Assert-Equal 'Oct 11, 2026 7:59 AM (1d 20h)' (Format-ResetText $otherDay $now) 'reset text other day'

Assert-Equal 'low' (Get-UsageLevel 30) 'level low'
Assert-Equal 'medium' (Get-UsageLevel 72) 'level medium'
Assert-Equal 'high' (Get-UsageLevel 86) 'level high'

Assert-Equal 'Claude PRO - Session 72% - Weekly 86%' (Format-TrayTooltip $usage 'PRO') 'tooltip'
Assert-Equal $true ((Format-TrayTooltip $usage ('X' * 80)).Length -le 63) 'tooltip stays within 63 chars'
Assert-Equal 'Updated 3m ago' (Format-Age 3.4) 'age text'
Assert-Equal 'Agendar sesi' (Tx 'Agendar sesi\u00f3n').Substring(0, 12) 'Tx decodes escapes'
Assert-Equal 243 ([int](Tx 'Agendar sesi\u00f3n')[12]) 'Tx produces the accented char'

# --- schedule
$prompt = Format-CloudSchedulePrompt (Get-Date -Year 2026 -Month 10 -Day 10 -Hour 7 -Minute 7)
Assert-Equal $true ($prompt.StartsWith('/schedule one-off run at 2026-10-10 07:07 (UTC')) 'cloud prompt has time and offset'
$okOut = Get-CloudScheduleOutcome "Rutina creada.`nROUTINE_ID=trig_01FYv7uf6Za94Pn7NPyGDRGh`n"
Assert-Equal 'scheduled' $okOut.Status 'cloud outcome: success line'
Assert-Equal 'trig_01FYv7uf6Za94Pn7NPyGDRGh' $okOut.RoutineId 'cloud outcome: routine id'
$failOut = Get-CloudScheduleOutcome 'FAILED=routines disabled for this org'
Assert-Equal 'routines disabled for this org' $failOut.Error 'cloud outcome: failure reason'
Assert-Equal 'failed' (Get-CloudScheduleOutcome 'something else').Status 'cloud outcome: no marker means failed'
Assert-Equal $false ((Format-CloudSchedulePrompt $now) -match '<|>') 'cloud prompt has no shell redirection characters'
Assert-Equal 'Session-20261010-0707' (Get-SessionTaskName (Get-Date -Year 2026 -Month 10 -Day 10 -Hour 7 -Minute 7)) 'task name'

# --- statusline block
foreach ($nl in "`n", "`r`n") {
    $label = if ($nl -eq "`n") { 'LF' } else { 'CRLF' }
    $original = "#!/usr/bin/env bash${nl}input=`$(cat)${nl}jq() { `"`$JQ_BIN`" `"`$@`"; }${nl}echo hi${nl}"
    $patched = Add-StatuslineBlock $original
    Assert-Equal $true ($patched.Contains('# >>> ClaudeTray')) "block added ($label)"
    Assert-Equal $patched (Add-StatuslineBlock $patched) "adding twice is a no-op ($label)"
    Assert-Equal $original (Remove-StatuslineBlockText $patched) "remove restores original ($label)"
    if ($nl -eq "`n") { Assert-Equal $false ($patched.Contains("`r")) 'LF file stays LF' }
}

# --- session planning
$w = Get-ProjectedWindow (Get-Date -Year 2026 -Month 10 -Day 10 -Hour 7 -Minute 40 -Second 30)
Assert-Equal '07:40-12:40' ($w.Start.ToString('HH:mm') + '-' + $w.End.ToString('HH:mm')) 'projected window is 5h from the minute'

$busy = Get-UsageView $snapshot $now      # session resets at 13:59
Assert-Equal '14:05' (Get-DefaultScheduleTime $busy $now).ToString('HH:mm') 'suggestion: 5 past the hour after the reset'
$idle = Get-UsageView $null $now          # now is 11:48
Assert-Equal '12:05' (Get-DefaultScheduleTime $idle $now).ToString('HH:mm') 'suggestion when idle: next hour + 5'
$onHour = $now.Date.AddHours(9)
Assert-Equal '09:05' (Get-DefaultScheduleTime $idle $onHour).ToString('HH:mm') 'suggestion at 9:00 sharp is 9:05'

Assert-Equal $true (Test-InsideCurrentSession $busy $now.AddHours(1)) 'time before reset is inside session'
Assert-Equal $false (Test-InsideCurrentSession $busy $now.AddHours(3)) 'time after reset is outside session'
Assert-Equal $false (Test-InsideCurrentSession $idle $now.AddHours(1)) 'idle session never contains a time'
$fraction = Get-SessionElapsedFraction $busy $now
Assert-Equal '0.56' $fraction.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) 'elapsed fraction'

# --- schedule rows
$pc = @([pscustomobject]@{ Name = 'Session-A'; At = $now.AddHours(5) }, [pscustomobject]@{ Name = 'Session-B'; At = $now.AddHours(2) })
$cloud = @([pscustomobject]@{ at = $now.AddHours(3).ToString('o') }, [pscustomobject]@{ at = $now.AddDays(-5).ToString('o') })
$hist = @([pscustomobject]@{ at = $now.AddHours(-1).ToString('o'); ok = $true }, [pscustomobject]@{ at = $now.AddHours(-30).ToString('o'); ok = $false })
$rows = Get-ScheduleRows $pc $cloud $hist $now 10
Assert-Equal 'pending,requested,pending,ok,failed' (($rows | ForEach-Object State) -join ',') 'rows: upcoming soonest first, then past newest first'
Assert-Equal 'Session-B' $rows[0].TaskName 'first row is the soonest PC task'
Assert-Equal 2 @(Get-ScheduleRows $pc $cloud $hist $now 2).Count 'rows respect max'
Assert-Equal 0 @(Get-ScheduleRows $null $null $null $now).Count 'no data, no rows'
$cloudStates = @([pscustomobject]@{ at = $now.AddHours(1).ToString('o'); status = 'scheduled' }, [pscustomobject]@{ at = $now.AddHours(2).ToString('o'); status = 'failed' }, [pscustomobject]@{ at = $now.AddHours(3).ToString('o') }, [pscustomobject]@{ at = $now.AddHours(-3).ToString('o'); status = 'failed' })
Assert-Equal 'cloud-ok,cloud-failed,requested' ((Get-ScheduleRows $null $cloudStates $null $now 10 | ForEach-Object State) -join ',') 'cloud rows by status; past failed hidden'

# --- history file keeps arrays (one entry) and trims
$tmpHistory = Join-Path ([IO.Path]::GetTempPath()) ("claudetray-test-{0}.json" -f [guid]::NewGuid())
try {
    Add-JsonArrayEntry $tmpHistory ([ordered]@{ at = $now.ToString('o'); ok = $true }) 3
    Assert-Equal 1 @(Read-JsonFile $tmpHistory).Count 'history with one entry stays an array'
    1..5 | ForEach-Object { Add-JsonArrayEntry $tmpHistory ([ordered]@{ at = $now.AddMinutes($_).ToString('o'); ok = $true }) 3 }
    $kept = @(Read-JsonFile $tmpHistory)
    Assert-Equal 3 $kept.Count 'history trims to keep'
    Assert-Equal $now.AddMinutes(5).ToString('o') ([string]$kept[2].at) 'history keeps the newest'
} finally {
    if (Test-Path -LiteralPath $tmpHistory) { [IO.File]::Delete($tmpHistory) }
}

# --- day labels
Assert-Equal 'Hoy' (Get-DayLabel $now $now) 'day label today'
Assert-Equal (Tx 'Ma\u00f1ana') (Get-DayLabel $now.AddDays(1) $now) 'day label tomorrow'
Assert-Equal 'Ayer' (Get-DayLabel $now.AddDays(-1) $now) 'day label yesterday'

# --- usage endpoint mapping
$apiJson = '{"five_hour":{"utilization":5.0,"resets_at":"2026-10-09T22:50:00.211921+00:00"},"seven_day":{"utilization":1.0,"resets_at":"2026-10-15T19:00:00+00:00"},"seven_day_opus":null}'
$snap = ConvertFrom-UsageApi $apiJson 1791567000.5
Assert-Equal 5 $snap.rate_limits.five_hour.used_percentage 'api five_hour percent'
Assert-Equal ([DateTimeOffset]::Parse('2026-10-09T22:50:00+00:00').ToUnixTimeSeconds()) $snap.rate_limits.five_hour.resets_at 'api resets_at to unix seconds'
Assert-Equal 'api' $snap.source 'api snapshot is tagged'
$apiView = Get-UsageView ($snap | ConvertTo-Json -Depth 5 | ConvertFrom-Json) ([DateTimeOffset]::FromUnixTimeSeconds(1791567000).LocalDateTime)
Assert-Equal 5 $apiView.Session.Percent 'api snapshot feeds the same view'
Assert-Equal 1 $apiView.Weekly.Percent 'api weekly percent in view'
$partial = ConvertFrom-UsageApi '{"five_hour":null,"seven_day":{"utilization":40,"resets_at":"2026-10-15T19:00:00+00:00"}}' 1
Assert-Equal $false ($partial.rate_limits.Contains('five_hour')) 'missing window is skipped'
$threw = $false; try { [void](ConvertFrom-UsageApi '{"five_hour":null,"seven_day":null}' 1) } catch { $threw = $true }
Assert-Equal $true $threw 'response without windows throws'
Assert-Equal ([DateTimeOffset]::Parse('2026-10-09T22:50:00+00:00').ToUnixTimeSeconds()) (ConvertTo-UnixSeconds '2026-10-09T22:49:59.98+00:00') 'resets_at rounds to the nearest second'

# --- extras: extra usage and limit reset
$none = ConvertFrom-UsageExtras '{"extra_usage":{"is_enabled":false,"used_credits":null},"juniper_tide":null}' 100
Assert-Equal $null $none.extra_usage 'disabled extra usage is not stored'
Assert-Equal $null $none.limit_reset 'no limit reset is not stored'
$both = ConvertFrom-UsageExtras '{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"utilization":24.8,"currency":"USD"},"juniper_tide":{"eligible":true,"available":true,"resets_per_week":1}}' 100
Assert-Equal 1240 $both.extra_usage.used_minor 'extra usage used credits'
Assert-Equal 1 $both.limit_reset.resets_per_week 'limit reset per week'
$notAvail = ConvertFrom-UsageExtras '{"juniper_tide":{"eligible":true,"available":false}}' 100
Assert-Equal $null $notAvail.limit_reset 'unavailable reset is not stored'

Assert-Equal '$12.40' (Format-Money 1240 'USD') 'money USD from cents'
Assert-Equal '12.40 EUR' (Format-Money 1240 'EUR') 'money other currency'

$extrasNow = [DateTimeOffset]::FromUnixTimeSeconds(1000).LocalDateTime
$ev = Get-ExtrasView ($both | ConvertTo-Json -Depth 5 | ConvertFrom-Json) $extrasNow.AddSeconds(-900)
Assert-Equal 25 $ev.ExtraUsage.Percent 'extra usage percent rounds'
Assert-Equal '$12.40 of $50.00 this month' $ev.ExtraUsage.AmountText 'extra usage amount text'
Assert-Equal 'Limit reset available' $ev.LimitReset.Title 'limit reset title'
$old = Get-ExtrasView ($both | ConvertTo-Json -Depth 5 | ConvertFrom-Json) $extrasNow.AddHours(13)
Assert-Equal $null $old.ExtraUsage 'stale extras are hidden'
Assert-Equal $null (Get-ExtrasView $null $now).LimitReset 'no extras file, nothing shown'

# --- session slots
function Area($Left, $Top, $Right, $Bottom) { [pscustomobject]@{ Left = $Left; Top = $Top; Right = $Right; Bottom = $Bottom } }
function Format-Slot($Slot) { '{0},{1} {2}x{3}' -f $Slot.X, $Slot.Y, $Slot.Width, $Slot.Height }
# Listed out of order: the 1920x1080 monitor right of the primary, then the primary.
$slots = Get-HalfSlots @((Area 2560 0 4480 1020), (Area 0 0 2560 1392))
Assert-Equal 4 $slots.Count 'two slots per monitor'
Assert-Equal '0,0 1280x1392' (Format-Slot $slots[0]) 'slot 0 is left half of leftmost monitor'
Assert-Equal '1280,0 1280x1392' (Format-Slot $slots[1]) 'slot 1 is its right half'
Assert-Equal '2560,0 960x1020' (Format-Slot $slots[2]) 'slot 2 is left half of next monitor'
Assert-Equal '3520,0 960x1020' (Format-Slot $slots[3]) 'slot 3 is its right half'
$odd = Get-HalfSlots @((Area -1365 0 0 728))
Assert-Equal 2 $odd.Count 'one monitor gives two slots'
Assert-Equal '-1365,0 682x728' (Format-Slot $odd[0]) 'odd width: left half rounds down, negative x kept'
Assert-Equal '-683,0 683x728' (Format-Slot $odd[1]) 'odd width: right half takes the extra pixel'

function Session($Slot) { [pscustomobject]@{ slot = $Slot; hwnd = 1000 + $Slot } }
Assert-Equal 0 (Get-FreeSlot 4 @()) 'no sessions: first slot'
Assert-Equal 0 (Get-FreeSlot 4 $null) 'missing session list: first slot'
Assert-Equal 2 (Get-FreeSlot 4 @((Session 0), (Session 1))) 'next slot after two'
Assert-Equal 0 (Get-FreeSlot 4 @((Session 1), (Session 2))) 'closed slot 0 is reused first'
Assert-Equal 1 (Get-FreeSlot 4 @((Session 0))) 'single session'
Assert-Equal -1 (Get-FreeSlot 4 @((Session 0), (Session 1), (Session 2), (Session 3))) 'four sessions on two monitors: full'
Assert-Equal -1 (Get-FreeSlot 2 @((Session 2), (Session 3))) 'sessions left on an unplugged monitor still count'
Assert-Equal 0 (Get-FreeSlot 2 @((Session 3))) 'a slot beyond the monitors does not block a free one'

Assert-Equal '"C:\\"' (Format-WtPath 'C:\') 'trailing backslash doubled'
Assert-Equal '"C:\a\;b"' (Format-WtPath 'C:\a;b') 'semicolon escaped for wt'
Assert-Equal '-w new --pos 2560,0 -d "D:\x" cmd /k claude' (Format-WtArguments 'D:\x' 'claude' $slots[2]) 'wt arguments with position'
Assert-Equal '-w new -d "D:\x" cmd /k claude' (Format-WtArguments 'D:\x' 'claude' $odd[0]) 'no --pos for negative coordinates'
Assert-Equal $true ((Format-SessionsFullMessage 4 2).Contains('(2 pantallas)')) 'full message names the monitors'
Assert-Equal $true ((Format-SessionsFullMessage 2 1).Contains('(1 pantalla)')) 'full message, one monitor'

# --- every script parses and is ASCII
foreach ($file in Get-ChildItem -LiteralPath $TrayRoot -Recurse -Filter *.ps1) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 $errors.Count "parses: $($file.Name)"
    # A bare + between command arguments (e.g. Draw-Text $g 'a' + 'b' ...) shifts every later argument.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $bare = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.StringConstantType -eq 'BareWord' -and $n.Value -in '+', '-', '*', '/' -and
        $n.Parent -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal 0 $bare.Count "no bare operators as arguments: $($file.Name)"
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    Assert-Equal 0 @($bytes | Where-Object { $_ -gt 127 }).Count "ascii: $($file.Name)"
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures of $script:Count tests failed" -ForegroundColor Red
    exit 1
}
Write-Host "all $script:Count tests passed" -ForegroundColor Green
