# Unit tests for the pure helpers (no UI, no Task Scheduler changes).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\usage.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
. (Join-Path $TrayRoot 'lib\statusline.ps1')
. (Join-Path $TrayRoot 'lib\usageapi.ps1')
. (Join-Path $TrayRoot 'lib\sessions.ps1')
. (Join-Path $TrayRoot 'lib\whisper.ps1')

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

# --- week plan (now: Fri 11:48, session resets 13:59, weekly 86 % resets Sun 07:48)
$inv = [Globalization.CultureInfo]::InvariantCulture
$defaults = Get-PlanSettings $null
Assert-Equal 3 $defaults.SessionsPerDay 'plan defaults: 3 sessions a day'
Assert-Equal 4 (Get-MaxSessionsPerDay 7) 'from 7:05 four windows start before midnight'
Assert-Equal 5 (Get-MaxSessionsPerDay 0) 'from 0:05 five windows start before midnight'
$clamped = Get-PlanSettings ('{"sessionsPerDay": 4, "firstHour": 10}' | ConvertFrom-Json)
Assert-Equal 3 $clamped.SessionsPerDay 'saved sessions clamp to what fits after the first hour'
Assert-Equal 10 $clamped.FirstHour 'saved first hour is read (camelCase json)'

$weekPlan = Get-WeekPlan $snapshot $defaults $now
Assert-Equal 'data' $weekPlan.CutoffSource 'cutoff comes from the weekly window'
Assert-Equal 7 $weekPlan.SessionCount 'current window + 2 today + 3 Saturday + 1 Sunday'
Assert-Equal 3 $weekPlan.Days.Count 'plan spans today to the cutoff day'
Assert-Equal 'now,14:05,19:05' (($weekPlan.Days[0].Slots | ForEach-Object { if ($_.Current) { 'now' } else { $_.Start.ToString('HH:mm') } }) -join ',') 'today: current window, then back-to-back after its reset'
Assert-Equal '07:05,12:05,17:05' (($weekPlan.Days[1].Slots | ForEach-Object { $_.Start.ToString('HH:mm') }) -join ',') 'next day follows the first hour'
Assert-Equal '0.14' $weekPlan.Slots[-1].Weight.ToString('0.00', $inv) 'last window only counts the part before the cutoff'
Assert-Equal '0.44' $weekPlan.Slots[0].Weight.ToString('0.00', $inv) 'current window only counts what is left of it'
Assert-Equal '100' $weekPlan.Days[-1].EndPercent.ToString('0', $inv) 'plan ends at 100 % on the cutoff day'
Assert-Equal '2.51' $weekPlan.PerSession.ToString('0.00', $inv) 'remaining 14 % spread over 5.58 windows'

$full = [pscustomobject]@{ rate_limits = [pscustomobject]@{ seven_day = [pscustomobject]@{ used_percentage = 100; resets_at = (To-Unix $now.AddDays(2)) } } }
Assert-Equal 0 (Get-WeekPlan $full $defaults $now).PerSession 'weekly limit used up: nothing left per session'

$old = [pscustomobject]@{ rate_limits = [pscustomobject]@{ seven_day = [pscustomobject]@{ used_percentage = 70; resets_at = (To-Unix $now.AddDays(-1)) } } }
$rolled = Get-WeekPlan $old $defaults $now
Assert-Equal 'rolled' $rolled.CutoffSource 'expired weekly window rolls forward'
Assert-Equal $now.AddDays(6).ToString('s') $rolled.Cutoff.ToString('s') 'rolled cutoff is 7 days after the old one'
Assert-Equal 0 $rolled.UsedPercent 'rolled week starts from 0 %'
Assert-Equal '12:05' $rolled.Slots[0].Start.ToString('HH:mm') 'idle today: first window at the next hour + 5'

$manual = Get-WeekPlan $null $defaults $now
Assert-Equal 'manual' $manual.CutoffSource 'no weekly data: saved cutoff'
Assert-Equal '2026-10-15 14:00' $manual.Cutoff.ToString('yyyy-MM-dd HH:mm') 'manual cutoff: next Thursday 2 p.m.'

$booked = @($weekPlan.Days[1].Slots[0].Start.AddMinutes(15))
Assert-Equal 5 (Get-UnbookedSlots $weekPlan.Slots $booked $now).Count 'unbooked: skips the current window and booked slots'
Assert-Equal 6 (Get-UnbookedSlots $weekPlan.Slots $null $now).Count 'unbooked with nothing scheduled'

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
Assert-Equal '-w new --pos 2560,0 --tabColor #16A34A -d "D:\x" cmd /k claude' (Format-WtArguments 'D:\x' 'claude' $slots[2] (Get-SlotTabColor 2)) 'wt arguments with tab color'
Assert-Equal 'blue #6A9BCC' ('{0} {1}' -f (Get-SlotColor 0).Name, (Get-SlotColor 0).Hex) 'slot 0 is blue, as Claude Code draws it'
Assert-Equal 'orange #D97757' ('{0} {1}' -f (Get-SlotColor 1).Name, (Get-SlotColor 1).Hex) 'slot 1 is orange, as Claude Code draws it'
Assert-Equal '#6A9BCC' (Get-SlotTabColor 8) 'tab colors wrap past eight slots'
Assert-Equal 8 @($SlotColors.Name | Select-Object -Unique).Count 'eight distinct colors'
$colorNames = @('red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan')
Assert-Equal 0 @($SlotColors.Name | Where-Object { $colorNames -notcontains $_ }).Count 'every color name is one /color accepts'
Assert-Equal 'claude --session-id 1111 --plugin-dir "C:\vt\voice\plugin" "/color green"' (Format-ClaudeCommand 'claude' '1111' 'C:\vt\voice\plugin' 'green') 'claude command with session id, plugin and color'
Assert-Equal 'claude "/color red"' (Format-ClaudeCommand 'claude' '' '' 'red') 'claude command without voice plugin'
Assert-Equal '-w new -d "D:\x" cmd /k claude' (Format-WtArguments 'D:\x' 'claude' $odd[0]) 'no --pos for negative coordinates'
Assert-Equal $true ((Format-SessionsFullMessage 4 2).Contains('(2 pantallas)')) 'full message names the monitors'
Assert-Equal $true ((Format-SessionsFullMessage 2 1).Contains('(1 pantalla)')) 'full message, one monitor'

# --- FreeLLMAPI (lib\freellm.ps1): command-line environment for one session, key format, port
. (Join-Path $TrayRoot 'lib\freellm.ps1')
$freeKey = 'freellmapi-' + ('ab12' * 12)
Assert-Equal $true (Test-FreeLlmKeyFormat $freeKey) 'freellm: dashboard key format accepted'
Assert-Equal $false (Test-FreeLlmKeyFormat 'sk-ant-123456789012345678901234') 'freellm: other keys rejected'
Assert-Equal $false (Test-FreeLlmKeyFormat ($freeKey + '" & calc')) 'freellm: key with cmd metacharacters rejected'
Assert-Equal $false (Test-FreeLlmKeyFormat '') 'freellm: empty key rejected'
$freeEnv = Format-FreeLlmEnv 'http://127.0.0.1:31415' $freeKey
Assert-Equal ('set ANTHROPIC_BASE_URL=http://127.0.0.1:31415&& set ANTHROPIC_AUTH_TOKEN=' + $freeKey + '&& set ANTHROPIC_API_KEY=&& set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1&& ') $freeEnv 'freellm: env prefix for cmd.exe (no quotes, no space before &&)'
Assert-Equal '' (Format-FreeLlmEnv 'http://127.0.0.1:31415 & calc' $freeKey) 'freellm: no env for a url with cmd metacharacters'
Assert-Equal '' (Format-FreeLlmEnv 'http://127.0.0.1:31415' 'nope') 'freellm: no env without a usable key'
Assert-Equal '' (Format-FreeLlmEnv '' $freeKey) 'freellm: no env without a url'
Assert-Equal $false ($freeEnv.Contains(';')) 'freellm: env has no ";" (wt.exe would split the command there)'
Assert-Equal ('-w new -d "D:\x" cmd /k ' + $freeEnv + 'claude "/color red"') (Format-WtArguments 'D:\x' ($freeEnv + (Format-ClaudeCommand 'claude' '' '' 'red')) $odd[0]) 'freellm: env goes before claude inside cmd /k'
$freeCfg = Join-Path ([IO.Path]::GetTempPath()) ('cmx-freellm-test-{0}.json' -f [guid]::NewGuid().ToString('N'))
try {
    Assert-Equal 31415 (Get-FreeLlmPort $freeCfg) 'freellm: default port without config'
    [IO.File]::WriteAllText($freeCfg, '{"port":31417,"lanAccess":false}')
    Assert-Equal 31417 (Get-FreeLlmPort $freeCfg) 'freellm: port from the desktop config'
    [IO.File]::WriteAllText($freeCfg, '{"port":"x"}')
    Assert-Equal 31415 (Get-FreeLlmPort $freeCfg) 'freellm: bad port falls back to the default'
} finally { Remove-Item -LiteralPath $freeCfg -Force -ErrorAction SilentlyContinue }
Assert-Equal 'http://127.0.0.1:31415' (Get-FreeLlmBaseUrl 31415) 'freellm: base url is the server root'

# --- Ahorro de tokens (lib\maxx.ps1): context-mode state from Claude Code's own files
. (Join-Path $TrayRoot 'lib\maxx.ps1')
$cmHome = Join-Path ([IO.Path]::GetTempPath()) ('cmx-cm-test-{0}' -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force (Join-Path $cmHome 'plugins') | Out-Null
    Assert-Equal 'False False' ('{0} {1}' -f (Get-ContextModeState $cmHome).Installed, (Get-ContextModeState $cmHome).Enabled) 'context-mode: nothing installed'
    [IO.File]::WriteAllText((Join-Path $cmHome 'plugins\installed_plugins.json'), '{"version":2,"plugins":{"context-mode@context-mode":[{"scope":"user"}]}}')
    [IO.File]::WriteAllText((Join-Path $cmHome 'settings.json'), '{"enabledPlugins":{"context-mode@context-mode":false}}')
    Assert-Equal 'True False' ('{0} {1}' -f (Get-ContextModeState $cmHome).Installed, (Get-ContextModeState $cmHome).Enabled) 'context-mode: installed but disabled'
    [IO.File]::WriteAllText((Join-Path $cmHome 'settings.json'), '{"enabledPlugins":{"context-mode@context-mode":true}}')
    Assert-Equal $true (Get-ContextModeState $cmHome).Enabled 'context-mode: enabled'
} finally { Remove-Item -LiteralPath $cmHome -Recurse -Force -ErrorAction SilentlyContinue }

# --- Consumo (lib\forecast.ps1, prices in lib\stats.cs)
. (Join-Path $TrayRoot 'lib\forecast.ps1')
$js = "const OPUS = [5, 6.25, 10, 0.5, 25];`nconst PRICES = {`n  'claude-opus-5-5': [4, 5, 8, 0.2, 20],`n  'claude-opus-4-8': OPUS,`n  'bad': [1, 2],`n};"
$pt = ConvertFrom-PonytailPrices $js
Assert-Equal 'claude-opus-5-5=4,5,8,0.2,20|claude-opus-4-8=5,6.25,10,0.5,25' (@($pt.Keys | ForEach-Object { $_ + '=' + (($pt[$_] | ForEach-Object { $_.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ',') }) -join '|') 'forecast: Ponytail price rows, named arrays resolved, bad rows skipped'
$fNow = Get-Date -Year 2026 -Month 10 -Day 20 -Hour 10 -Minute 30 -Second 0 -Millisecond 0
$fUsage = [pscustomobject]@{
    days = 10; tokens = 1000000; cost = 100
    hourlyCost = [double[]]@(0,0,0,0,0,0,0,0,0,0,20,20,20,0,0,0,0,0,0,0,0,0,0,0)
    windowCost = [pscustomobject]@{ avg = 10 }
    recentHours = [pscustomobject]@{ '2026-10-20 08' = @(100000, 4); '2026-10-20 09' = @(50000, 2); '2026-10-20 10' = @(50000, 2); '2026-10-19 20' = @(10, 1) }
}
$fc = Get-UsageForecast $fUsage $null $fNow
Assert-Equal '2026-10-20 08:00|8' ('{0}|{1}' -f $fc.Start.ToString('yyyy-MM-dd HH:mm'), $fc.Cost) 'forecast: open window rebuilt from the first hour after the last one ended, spent so far'
Assert-Equal 5 $fc.TypicalRest 'forecast: the rest of the window (10:30 to 13:00) at your usual pace for those hours'
Assert-Equal $true ($fc.ProjectedCost -gt $fc.Cost -and $null -eq $fc.ProjectedPercent) 'forecast: projected above what is spent; no plan, no percent'
$fc = Get-UsageForecast $fUsage ([pscustomobject]@{ Active = $true; Percent = 40; ResetsAt = $fNow.AddHours(2.5) }) $fNow
Assert-Equal '0.2|20' ('{0}|{1}' -f $fc.CostPerPercent.ToString([Globalization.CultureInfo]::InvariantCulture), $fc.Capacity) 'forecast: calibrated with the plan (cost so far / percent)'
$fc = Get-UsageForecast $fUsage ([pscustomobject]@{ Active = $true; Percent = 95; ResetsAt = $fNow.AddHours(2.5) }) $fNow
Assert-Equal $true ($fc.ProjectedPercent -ge 100 -and $fc.LimitAt -gt $fNow -and $fc.LimitAt -lt $fc.End) 'forecast: the hour the limit would be reached'
Assert-Equal $null (Get-UsageForecast $fUsage $null $fNow.AddHours(8)) 'forecast: no open window'
Assert-Equal 'muy parecidas|variables|muy variables' ((Format-UsageSpread 0.1), (Format-UsageSpread 0.7), (Format-UsageSpread 1.5) -join '|') 'forecast: spread in words'

# --- Otros PCs (bridge): config text, pairing, gate
. (Join-Path $TrayRoot 'lib\bridge.ps1')
. (Join-Path $TrayRoot 'lib\bridgenet.ps1')
$keyA = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPa+Sqs0YdEJlbrjplfv/pPL7Qh9n9FJfyg+mzTrzLsO'
$keyB = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBb8gNU32IWHjUGgdvBO6Qj3zWe1r3fYxOKnf3lXwvSh'
Assert-Equal $keyA (Get-BridgeKeyText "$keyA someone@pc") 'key text drops the comment'
Assert-Equal $null (Get-BridgeKeyText 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC') 'only ed25519 keys are accepted'
Assert-Equal $null (Get-BridgeKeyText ($keyA.Substring(0, 60))) 'truncated key is rejected'
Assert-Equal $true (Test-BridgeName 'DESKTOP-4F2' 40) 'computer name is valid'
Assert-Equal $false (Test-BridgeName 'a"b' 40) 'quote in a name is rejected'
Assert-Equal $false (Test-BridgeName ('x' * 41) 40) 'name over the limit is rejected'
Assert-Equal '"C:/Users/John Smith/k"' (Format-SshPath 'C:\Users\John Smith\k') 'ssh path with a space is quoted'
Assert-Equal 'C:/a%%b/k' (Format-SshPath 'C:\a%b\k') 'ssh path doubles percent'
Assert-Equal '~/.claude/usage-tray/bridge/ssh_config' (Format-SshClientPath 'C:\Users\Ana\.claude\usage-tray\bridge\ssh_config' 'C:\Users\Ana') 'client path under the profile uses ~ (Git ssh reads C:/ in Include as relative)'
Assert-Equal '"~/My Files/k"' (Format-SshClientPath 'C:\Users\Ana\My Files\k' 'C:\Users\Ana\') 'client path with a space is quoted'
Assert-Equal 'D:/data/k' (Format-SshClientPath 'D:\data\k' 'C:\Users\Ana') 'client path outside the profile stays absolute'

$peerA = [pscustomobject]@{ id = 'aaaaaaaaaaaa'; name = 'Oficina PC'; user = 'santi'; port = 41022; address = '192.168.1.20'; hostKey = $keyA; clientKey = $keyB }
$peerB = [pscustomobject]@{ id = 'bbbbbbbbbbbb'; name = 'oficina-pc'; user = 'John Smith'; port = 41022; address = '192.168.1.30'; hostKey = $keyB; clientKey = $keyA }
Assert-Equal 'cmx-oficina-pc-aaaa' (Get-PeerAlias $peerA @($peerA, $peerB)) 'alias: same name gets the id appended'
Assert-Equal 'cmx-oficina-pc' (Get-PeerAlias $peerA @($peerA)) 'alias from the computer name'

Assert-Equal '"C:\Users\John Smith\g.exe" aaaaaaaaaaaa' (Format-GateCommand 'C:\Users\John Smith\g.exe' 'aaaaaaaaaaaa') 'gate command: one quoted path and the id'
$threw = $false; try { [void](Format-GateCommand 'C:\Users\a&b\g.exe' 'aaaaaaaaaaaa') } catch { $threw = $true }
Assert-Equal $true $threw 'gate path with & is refused (cmd.exe would split it)'
$line = Format-AuthorizedKeyLine 'C:\x y\g.exe' 'aaaaaaaaaaaa' "$keyB c" @('10.0.0.0/8', '192.168.0.0/16')
Assert-Equal ('restrict,pty,from="10.0.0.0/8,192.168.0.0/16",command="\"C:\x y\g.exe\" aaaaaaaaaaaa" ' + $keyB + ' cmx-aaaaaaaaaaaa') $line 'authorized_keys line'
$ctx = New-BridgeContext -DataDir 'C:\data\bridge' -SshDir 'C:\app\ssh' -SshPort 41022
$keys = Format-AuthorizedKeys $ctx @($peerA, [pscustomobject]@{ id = 'cccccccccccc'; name = 'x'; clientKey = $null }) 'C:\g.exe'
Assert-Equal 2 @($keys.Trim() -split "`n").Count 'authorized_keys: header plus one line per PC with a client key'
Assert-Equal $false ($keys.Contains('127.0.0.1')) 'loopback is not accepted outside tests'
$sshd = Format-SshdConfig $ctx 'C:\app\ssh\sftp-server.exe' @('192.168.1.20', '10.0.0.5')
foreach ($expected in 'Port 41022', 'ListenAddress 192.168.1.20', 'ListenAddress 10.0.0.5', 'PasswordAuthentication no', 'DisableForwarding yes', 'AuthorizedKeysFile C:/data/bridge/authorized_keys', 'Subsystem sftp C:/app/ssh/sftp-server.exe') {
    Assert-Equal $true ($sshd -split "`n" -contains $expected) "sshd_config: $expected"
}
$client = Format-SshClientConfig $ctx @($peerA, $peerB)
Assert-Equal $true ($client.Contains("Host cmx-oficina-pc-bbbb`n    HostName 192.168.1.30`n    Port 41022`n    User `"John Smith`"")) 'ssh_config host block, user with a space quoted'
Assert-Equal $true ($client.Contains('StrictHostKeyChecking yes') -and $client.Contains('HostKeyAlias claudemaxxing-aaaaaaaaaaaa')) 'ssh_config pins the host key under an alias'
Assert-Equal "claudemaxxing-aaaaaaaaaaaa $keyA`nclaudemaxxing-bbbbbbbbbbbb $keyB`n" (Format-KnownHosts @($peerA, $peerB)) 'known_hosts by alias'

$grants = ConvertFrom-GrantsText "aaaaaaaaaaaa 2000`nbbbbbbbbbbbb 900`nnot-an-id 5000`n" 1000
Assert-Equal 'aaaaaaaaaaaa' (@($grants.Keys) -join ',') 'grants: expired and malformed lines dropped'
Assert-Equal "aaaaaaaaaaaa 2000`n" (Format-GrantsText $grants) 'grants text'

foreach ($nl in "`n", "`r`n") {
    $label = if ($nl -eq "`n") { 'LF' } else { 'CRLF' }
    $userConfig = "Host work${nl}    User me${nl}"
    $withBlock = Add-SshIncludeBlock $userConfig 'C:\Users\u\.claude\usage-tray\bridge\ssh_config'
    Assert-Equal $true ($withBlock.StartsWith($SshIncludeStart + $nl + 'Include C:/Users/u/.claude/usage-tray/bridge/ssh_config')) "ssh include goes first ($label)"
    Assert-Equal $withBlock (Add-SshIncludeBlock $withBlock 'C:\Users\u\.claude\usage-tray\bridge\ssh_config') "ssh include added twice is a no-op ($label)"
    Assert-Equal $userConfig (Remove-SshIncludeBlock $withBlock) "ssh include removal restores the file ($label)"
}
Assert-Equal '' (Remove-SshIncludeBlock (Add-SshIncludeBlock '' 'C:\b\ssh_config')) 'include in an empty file removes cleanly'

Assert-Equal '192.168.1.255' (Get-BroadcastAddress '192.168.1.23' 24) 'broadcast /24'
Assert-Equal '10.255.255.255' (Get-BroadcastAddress '10.1.2.3' 8) 'broadcast /8'
Assert-Equal '172.16.7.255' (Get-BroadcastAddress '172.16.4.9' 22) 'broadcast /22'
Assert-Equal $true (Test-PrivateAddress '172.20.0.5') 'private 172.20'
Assert-Equal $false (Test-PrivateAddress '172.32.0.5') 'not private 172.32'
Assert-Equal $false (Test-PrivateAddress '8.8.8.8') 'public address'

$infoA = [ordered]@{ id = 'aaaaaaaaaaaa'; name = 'PC-A'; user = 'santi'; port = 41022; hostKey = $keyA; clientKey = $keyB }
$infoB = [ordered]@{ id = 'bbbbbbbbbbbb'; name = 'PC-B'; user = 'ana'; port = 41022; hostKey = $keyB; clientKey = $keyA }
$hello = ConvertFrom-BridgeDatagram (ConvertTo-BridgeDatagram @{ t = 'hello'; id = 'aaaaaaaaaaaa'; name = 'PC-A'; user = 'santi'; port = 41022; pairing = $false })
Assert-Equal 'PC-A' $hello.name 'hello round trip'
Assert-Equal $null (ConvertFrom-BridgeDatagram ([Text.Encoding]::UTF8.GetBytes('{"app":"cmx","v":1,"t":"hello","id":"zz"}'))) 'hello with a bad id is dropped'
Assert-Equal $null (ConvertFrom-BridgeDatagram ([Text.Encoding]::UTF8.GetBytes('not json'))) 'garbage is dropped'
Assert-Equal $null (ConvertFrom-BridgeDatagram (ConvertTo-BridgeDatagram @{ t = 'pair2'; sid = '0123456789abcdef'; from = $infoB; commit = 'xyz' })) 'pair2 without a valid commit is dropped'

# Full pairing through the state machines, datagrams serialized as on the wire.
function Pass($Msg) { ConvertFrom-BridgeDatagram (ConvertTo-BridgeDatagram $Msg) }
$a = New-PairInitiator $infoA '192.168.1.30' 41021
$b = New-PairResponder $infoB (Pass $a.Out) '192.168.1.20' 41021
Step-Pairing $a (Pass $b.Out)
Assert-Equal 'revealed' $a.Stage 'initiator reveals its nonce after the commit'
Step-Pairing $b (Pass $a.Out)
Assert-Equal 'confirm' $b.Stage 'responder shows the code'
Step-Pairing $a (Pass $b.Out)
Assert-Equal 'confirm' $a.Stage 'initiator checks the commit and shows the code'
Assert-Equal $true ($a.Code -match '^\d{3} \d{3}$') 'code is six digits'
Assert-Equal $a.Code $b.Code 'both screens show the same code'
$dup = $b.Out; Step-Pairing $b (Pass @{ t = 'pair3'; sid = $a.Sid; nonce = $a.Nonce })
Assert-Equal 'pair4' $b.Out.t 'a repeated pair3 gets pair4 again'
Confirm-Pairing $a
Assert-Equal 'confirm' $a.Stage 'one confirmation is not enough'
Step-Pairing $b (Pass $a.Out)
Assert-Equal 'confirm' $b.Stage 'remote ok alone does not finish the responder'
Confirm-Pairing $b
Assert-Equal 'done' $b.Stage 'responder done after both confirm'
Step-Pairing $a (Pass $b.Out)
Assert-Equal 'done' $a.Stage 'initiator done after both confirm'
$record = New-PeerRecord $a
Assert-Equal 'bbbbbbbbbbbb|192.168.1.30|ana' ('{0}|{1}|{2}' -f $record.id, $record.address, $record.user) 'peer record from the pairing'

# A machine in the middle that swaps the responder's keys: the commit no longer matches.
$a2 = New-PairInitiator $infoA '192.168.1.30' 41021
$b2 = New-PairResponder $infoB (Pass $a2.Out) '192.168.1.20' 41021
$forged = Pass $b2.Out
$forged.from.hostKey = $keyA
Step-Pairing $a2 $forged
Step-Pairing $b2 (Pass $a2.Out)
Step-Pairing $a2 (Pass $b2.Out)
Assert-Equal 'failed' $a2.Stage 'swapped keys are caught by the commit'
Assert-Equal $true ((Get-PairCode $infoA $infoB 'n1' 'n2') -ne (Get-PairCode $infoA $infoB 'n1' 'n3')) 'code depends on the nonces'
$c = New-PairInitiator $infoA '192.168.1.30' 41021
$d = New-PairResponder $infoB (Pass $c.Out) '192.168.1.20' 41021
Step-Pairing $c (Pass $d.Out); Step-Pairing $d (Pass $c.Out); Step-Pairing $c (Pass $d.Out)
Stop-Pairing $d
Step-Pairing $c (Pass $d.Out)
Assert-Equal 'cancelled' $c.Stage 'cancel on one PC cancels the other'

# Security checks (see the audit in README, Otros PCs > How it is kept safe).
Assert-Equal $false (Test-BridgeName ('PC' + [char]0x202E + 'cod.exe') 40) 'name with a right-to-left override is rejected'
Assert-Equal $false (Test-BridgeName ('PC' + [char]0x200B + 'B') 40) 'name with a zero-width space is rejected'
Assert-Equal $true (Test-BridgeName ('Jos' + [char]0xE9 + " O'Neil") 64) 'accented and apostrophe user names are fine'
Assert-Equal $false (Test-BridgeName 'a;b' 40) 'separator in a name is rejected'
$padded = Format-CommandPreview ('git status' + (' ' * 80) + '& rd /s /q C:/x')
Assert-Equal 'git status & rd /s /q C:/x' $padded 'command preview collapses padding that would hide the tail'
Assert-Equal $true ((Format-CommandPreview "echo a`r`nformat c:") -match 'salto de l.nea\] format c:') 'command preview shows line breaks'
Assert-Equal $true ((Format-CommandPreview ('a' * 200)) -match '\(\+50 caracteres\)$') 'command preview says how much is cut'
Assert-Equal '[?]x' (Format-CommandPreview ([string][char]0x202E + 'x')) 'command preview shows invisible characters'
Assert-Equal 0 (ConvertFrom-GrantsText "aaaaaaaaaaaa 99999`n" 1000).Count 'a grant longer than an hour is not honored'
Assert-Equal $true ($sshd -split "`n" -contains 'AuthenticationMethods publickey') 'sshd_config: keys only'
foreach ($expected in 'ForwardAgent no', 'ForwardX11 no', 'ClearAllForwardings yes', 'ProxyCommand none', 'PermitLocalCommand no', 'UpdateHostKeys no') {
    Assert-Equal $true ($client -match [regex]::Escape("    $expected")) "ssh_config pins $expected over the user's Host *"
}

# UDP: a flood is read a slice at a time.
$udpPort = Get-Random -Minimum 45000 -Maximum 46000
$udp = Open-BridgeSocket $udpPort '127.0.0.1'
try {
    $hello = @{ t = 'hello'; id = 'aaaaaaaaaaaa'; name = 'PC-A'; user = 'santi'; port = 41022; pairing = $false }
    1..100 | ForEach-Object { Send-BridgeDatagram $udp $hello '127.0.0.1' $udpPort }
    Start-Sleep -Milliseconds 300
    Assert-Equal 64 @(Receive-BridgeDatagrams $udp).Count 'at most 64 datagrams per read'
    Assert-Equal $true (@(Receive-BridgeDatagrams $udp).Count -gt 0) 'the rest is read on the next one'
} finally { $udp.Close() }

# The gate, compiled and run for real (no sshd): command passthrough, grants, approval and denial.
# It also wants the tray alive: tray.pid next to the bridge folder must name a running powershell.exe.
$gateRoot = Join-Path ([IO.Path]::GetTempPath()) ('cmx-gate-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$gateHome = Join-Path $gateRoot 'bridge'
$savedCommand = $env:SSH_ORIGINAL_COMMAND
try {
    $gctx = New-BridgeContext -DataDir $gateHome -SshDir 'C:\none'
    $gate = Import-BridgeGate $gctx
    Write-BridgeText $gctx.GateConf (Format-GateConf 'C:\none\sftp-server.exe' 'PC-TEST' 3)
    $trayPidPath = Join-Path $gateRoot 'tray.pid'
    Write-BridgeText $trayPidPath ([string]$PID)
    function Invoke-Gate([string]$Command, [string]$Answer, [switch]$EmptyFirst) {
        $env:SSH_ORIGINAL_COMMAND = $Command
        $psi = New-Object System.Diagnostics.ProcessStartInfo($gate, 'aaaaaaaaaaaa')
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($Answer) {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not @(Get-ChildItem -LiteralPath $gctx.RequestsDir -Filter '*.json' -ErrorAction SilentlyContinue).Count) { Start-Sleep -Milliseconds 50 }
            $request = Get-ChildItem -LiteralPath $gctx.RequestsDir -Filter '*.json' | Select-Object -First 1
            $script:LastRequest = Get-Content -LiteralPath $request.FullName -Raw | ConvertFrom-Json
            $answerPath = $request.FullName -replace '\.json$', '.answer'
            if ($EmptyFirst) {
                # A write still in progress: the gate must keep waiting, not take it as a "no".
                [IO.File]::WriteAllText($answerPath, '')
                Start-Sleep -Milliseconds 600
            }
            [IO.File]::WriteAllText($answerPath, $Answer)
        }
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        [pscustomobject]@{ Out = $out.Trim(); Err = $errTask.Result.Trim(); Code = $proc.ExitCode }
    }
    $r = Invoke-Gate 'echo gate-ok' 'allow'
    Assert-Equal 'gate-ok|0' "$($r.Out)|$($r.Code)" 'gate runs the command once allowed'
    Assert-Equal 'exec|echo gate-ok|aaaaaaaaaaaa' ('{0}|{1}|{2}' -f $script:LastRequest.kind, $script:LastRequest.command, $script:LastRequest.peer) 'gate request names the PC and the command'
    $r = Invoke-Gate 'exit /b 7' 'allow'
    Assert-Equal 7 $r.Code 'gate passes the exit code through'
    $r = Invoke-Gate 'echo nope' 'deny'
    Assert-Equal "1|False" "$($r.Code)|$($r.Out -match 'nope')" 'denied: nothing runs'
    Assert-Equal $true ($r.Err -match 'no permitio') 'denied: the client is told'
    $r = Invoke-Gate 'echo late' ''
    Assert-Equal $true ($r.Code -eq 1 -and $r.Err -match 'nadie respondio') 'no answer in time: closed'
    $r = Invoke-Gate 'echo after-empty' 'allow' -EmptyFirst
    Assert-Equal 'after-empty' $r.Out 'an empty answer file is a write in progress, not a denial'
    Write-BridgeText $gctx.GrantsFile "aaaaaaaaaaaa $((Get-UnixNow) + 86400)`n"
    $r = Invoke-Gate 'echo forged-grant' ''
    Assert-Equal $true ($r.Code -eq 1 -and $r.Out -notmatch 'forged') 'a grant longer than an hour does not let the PC in'
    Set-BridgeGrant $gctx 'aaaaaaaaaaaa' ((Get-UnixNow) + 60)
    $r = Invoke-Gate 'echo granted' ''
    Assert-Equal 'granted' $r.Out 'a grant lets the PC in without asking'
    Write-BridgeText $trayPidPath '4'
    $r = Invoke-Gate 'echo no-tray' ''
    Assert-Equal $true ($r.Code -eq 1 -and $r.Err -match 'no esta abierta') 'tray.pid naming another process: nobody gets in, grant or not'
    Remove-Item -LiteralPath $trayPidPath
    $r = Invoke-Gate 'echo no-tray' ''
    Assert-Equal $true ($r.Code -eq 1 -and $r.Out -notmatch 'no-tray') 'no tray: nobody gets in, grant or not'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $gctx.RequestsDir, $gctx.SessionsDir -File).Count 'gate leaves no request or session files behind'

    # What sshd and the gate read on every connection is checked against what the tray writes.
    Write-BridgePeers $gctx @($peerA)
    Update-BridgeFiles $gctx $gate
    Assert-Equal 0 @(Get-BridgeTampered $gctx $gate).Count 'freshly written files are intact'
    Add-Content -LiteralPath $gctx.AuthorizedKeys -Value "$keyB extra"
    Assert-Equal 'authorized_keys' ((Get-BridgeTampered $gctx $gate) -join ',') 'a key added outside the tray is noticed'
    Update-BridgeFiles $gctx $gate
    Assert-Equal 0 @(Get-BridgeTampered $gctx $gate).Count 'rewriting restores it'
} finally {
    $env:SSH_ORIGINAL_COMMAND = $savedCommand
    Remove-Item -LiteralPath $gateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- installer: what gets copied to the install folder
. (Join-Path $TrayRoot 'lib\installer.ps1')
$manifest = Get-RuntimeManifest $TrayRoot
Assert-Equal 0 @($manifest | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TrayRoot $_)) }).Count 'every runtime file exists in the repo'
foreach ($needed in 'tray.ps1', 'open-session.ps1', 'uninstall.ps1', 'lib\installer.ps1', 'voice\hooks\speak.ps1', 'voice\plugin\hooks\hooks.json', 'voice\templates\skill-voz.md') {
    Assert-Equal $true ($manifest -contains $needed) "runtime includes $needed"
}
Assert-Equal 0 @($manifest | Where-Object { $_ -like 'voice\plugin\skills\*' -or $_ -like 'test\*' -or $_ -like 'menu\src\*' }).Count 'runtime skips generated, test and source files'
$stale = Get-StaleFiles @('lib\old.ps1', 'lib\common.ps1', 'voice\config.local.json', 'voice\venv\Scripts\edge-tts.exe', 'voice\plugin\skills\voz\SKILL.md', 'assets\Tray-Win32.ico') @('lib\common.ps1')
Assert-Equal 'lib\old.ps1' ($stale -join ',') 'update deletes only files dropped from the repo, never user or generated ones'
Assert-Equal 0 @(Get-StaleFiles @('LIB\Common.ps1') @('lib\common.ps1')).Count 'stale check ignores case'
# The repo may be renamed or deleted after installing: no runtime file may point back into it.
$repoRefs = @($manifest | Where-Object {
    $text = [IO.File]::ReadAllText((Join-Path $TrayRoot $_))
    $text -match [regex]::Escape($TrayRoot) -or $text -match 'C:[\\/]+Users[\\/]+'
})
Assert-Equal '' ($repoRefs -join ', ') 'no runtime file has an absolute path to this PC'

# --- Explorer menu: prebuilt files committed, and the MSIX built from the current manifest
foreach ($file in 'ClaudeCodeMenu.dll', 'ClaudeCodeMenuStub.exe', 'ClaudeCodeMenu.msix') {
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $TrayRoot "menu\bin\$file")) "menu\bin\$file is in the repo"
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $TrayRoot 'menu\bin\ClaudeCodeMenu.msix'))
try {
    $entry = $zip.GetEntry('AppxManifest.xml')
    $reader = New-Object System.IO.StreamReader($entry.Open())
    $packed = $reader.ReadToEnd(); $reader.Dispose()
    Assert-Equal $null $zip.GetEntry('AppxSignature.p7x') 'committed MSIX is unsigned (each PC signs its own copy)'
} finally { $zip.Dispose() }
$source = [IO.File]::ReadAllText((Join-Path $TrayRoot 'menu\package\AppxManifest.xml'))
Assert-Equal ($source.Trim([char]0xFEFF).Trim() -replace '\r\n', "`n") ($packed.Trim([char]0xFEFF).Trim() -replace '\r\n', "`n") 'MSIX manifest matches menu\package\AppxManifest.xml (run menu\package.ps1 after editing it)'

# --- Claude Whisper: settings, questions, echo, keyterms, transcript, stream-json, hotkeys, claude arguments
Add-Type -AssemblyName System.Windows.Forms
$ws = Get-WhisperSettings $null
Assert-Equal 'es' $ws.language 'whisper: default language'
Assert-Equal $true $ws.autoAnswer 'whisper: auto answer on by default'
$ws = Get-WhisperSettings ([pscustomobject]@{ language = 'xx'; model = 'opus'; autoAnswer = $false; profile = 5; version = 2 })
Assert-Equal 'es' $ws.language 'whisper: unknown language falls back'
Assert-Equal 'opus' $ws.model 'whisper: saved model kept'
Assert-Equal $false $ws.autoAnswer 'whisper: saved bool kept'
Assert-Equal '5' $ws.profile 'whisper: text settings are strings'
$ws = Get-WhisperSettings ([pscustomobject]@{ autoAnswer = $false; translate = $false })
Assert-Equal $true ($ws.autoAnswer -and $ws.translate) 'whisper: settings from before version 2 get auto-answer and translation on once'
Assert-Equal 2 $ws.version 'whisper: settings version saved'
$open = @(Get-WhisperOpenQuestions "I've been walking all night. Tell me baby, what is the capital of France? Or is it just a game")
Assert-Equal 'Tell me baby, what is the capital of France?' ($open -join '|') 'whisper: a finished question inside text still being sung'
Assert-Equal 0 @(Get-WhisperOpenQuestions 'what is the capital of France?').Count 'whisper: a question at the very end waits for the final line'
Assert-Equal $true (Test-WhisperSameQuestion 'Tell me baby, what is the capital of France?' 'what is the capital of France') 'whisper: interim and final versions are the same question'
Assert-Equal $false (Test-WhisperSameQuestion 'What is your name?' 'Where do you live now?') 'whisper: different questions'
$interp = ConvertFrom-WhisperInterpretation 'ok {"lines":[{"i":3,"t":"Hola","q":""},{"i":4,"t":"","q":"Pourquoi?"}]} trailing'
Assert-Equal 'Hola|Pourquoi?' ($interp[3].Translation + '|' + $interp[4].Question) 'whisper: interpreter JSON parsed despite text around it'
Assert-Equal 0 (ConvertFrom-WhisperInterpretation 'no json here').Count 'whisper: interpreter garbage ignored'
Assert-Equal "1: hello`n2: bonjour" (New-WhisperInterpretRequest @(@{ Index = 1; Text = 'hello' }, @{ Index = 2; Text = 'bonjour' })) 'whisper: interpreter request numbers the lines'
Assert-Equal $true ((New-WhisperSystemPrompt (Get-WhisperSettings $null)).Contains((Tx 'canci\u00f3n'))) 'whisper: prompt says songs are real input'

Assert-Equal $true (Test-WhisperQuestion (Tx '\u00bfCu\u00e1l es tu experiencia con Kubernetes?')) 'question: question mark'
Assert-Equal $true (Test-WhisperQuestion (Tx 'Cu\u00e9ntame sobre un proyecto dif\u00edcil.')) 'question: cuentame prompt'
Assert-Equal $true (Test-WhisperQuestion 'Tell me about a time you failed.') 'question: tell me'
Assert-Equal $true (Test-WhisperQuestion 'Ok. Walk me through your last project.') 'question: second sentence'
Assert-Equal $false (Test-WhisperQuestion (Tx 'Buenos d\u00edas, gracias por venir a la entrevista.')) 'question: greeting is not'
Assert-Equal $false (Test-WhisperQuestion 'Vale.') 'question: too short'
Assert-Equal $false (Test-WhisperQuestion (Tx 'Como te dec\u00eda, usamos Python en todo el equipo.')) 'question: como without accent is a statement'
Assert-Equal $false (Test-WhisperQuestion (Tx 'Cuando empec\u00e9 en la empresa \u00e9ramos tres.')) 'question: cuando without accent is a statement'

# Call history, as the ClaudeMaxxing window lists it.
$callLog = @(
    (Tx '# Claude Whisper \u00b7 2026-10-17 23:58'), '',
    '**Ellos** 23:58:04 Buenos dias.', (Tx '**Ellos** 23:58:10 \u00bfCu\u00e1l es tu experiencia con Python?'),
    (Tx '### Claude \u00b7 \u00bfCu\u00e1l es tu experiencia con Python?'), '', 'Llevo cuatro anos con Python.', '',
    (Tx '**T\u00fa** 00:03:30 Llevo cuatro a\u00f1os.'), (Tx '### Claude \u00b7 Pantalla')
)
$call = ConvertFrom-WhisperCallLog '20261017-235804' $callLog
Assert-Equal '2026-10-17 23:58:04' $call.Started.ToString('yyyy-MM-dd HH:mm:ss') 'call log: start from the file name'
Assert-Equal '2|1|2' ('{0}|{1}|{2}' -f $call.Them, $call.Me, $call.Answers) 'call log: lines from each side and answers'
Assert-Equal 6 $call.Minutes 'call log: duration across midnight'
Assert-Equal (Tx '\u00bfCu\u00e1l es tu experiencia con Python?') $call.Topic 'call log: topic is the first answered question'
$call = ConvertFrom-WhisperCallLog 'notes' @('**Ellos** 10:00:00 Hola a todos.')
Assert-Equal $null $call.Started 'call log: other file names have no start'
Assert-Equal 'Hola a todos.' $call.Topic 'call log: without answers, the topic is what they said first'
$call = ConvertFrom-WhisperCallLog 'x' @((Tx '### Claude \u00b7 Buenos d\u00edas. \u00bfQu\u00e9 tal el viaje?'))
Assert-Equal (Tx '\u00bfQu\u00e9 tal el viaje?') $call.Topic 'call log: topic starts at the question'
Assert-Equal '<1 min' (Format-CallDuration 0) 'call duration: under a minute'
Assert-Equal '1 h 5 min' (Format-CallDuration 65) 'call duration: hours'
Assert-Equal $false (Test-WhisperQuestion 'Te comento que el equipo es de cinco personas.') 'question: te comento is a statement'
Assert-Equal $false (Test-WhisperQuestion 'When I joined we were only three people.') 'question: english statement'
Assert-Equal $true (Test-WhisperQuestion (Tx 'Qu\u00e9 proyecto te gust\u00f3 m\u00e1s de todos')) 'question: accented interrogative without mark'
Assert-Equal $true (Test-WhisperQuestion 'What would you do differently next time') 'question: english opener pair'
Assert-Equal (Tx '\u00bfQu\u00e9 tal Python?') (Get-WhisperQuestionText @('Hola, bienvenido.', (Tx '\u00bfQu\u00e9 tal Python?'))) 'question text: greeting left out'
Assert-Equal 'Hola. Vale.' (Get-WhisperQuestionText @('Hola.', 'Vale.')) 'question text: everything when no question'

Assert-Equal $true (Test-WhisperEcho (Tx 'cu\u00e1l es tu experiencia con python') @((Tx '\u00bfCu\u00e1l es tu experiencia con Python?'))) 'echo: mic repeats the speakers'
Assert-Equal $false (Test-WhisperEcho 'trabaje cinco anos con django' @((Tx '\u00bfCu\u00e1l es tu experiencia con Python?'))) 'echo: own answer kept'
Assert-Equal $false (Test-WhisperEcho 'hola' @()) 'echo: nothing heard'

$terms = Get-WhisperKeyterms ([pscustomobject]@{ keyterms = 'Acme Corp; GraphQL'; profile = (Tx 'Trabaj\u00e9 con Kubernetes, AWS, C# y .NET en Mercado Libre.'); meeting = 'Puesto: SRE en PayFlow' })
foreach ($t in 'Acme Corp', 'GraphQL', 'AWS', 'C#', '.NET', 'PayFlow', 'SRE') {
    Assert-Equal $true ((',' + $terms + ',').Contains(",$t,")) "keyterms: $t"
}
Assert-Equal $false ($terms -match '[^\x20-\x7E]') 'keyterms: printable ASCII only'

$tr = New-WhisperTranscript
$at = Get-Date
Assert-Equal $null (Update-WhisperTranscript $tr 'them' 'interim' 'Hola qu' $at) 'transcript: interim finishes nothing'
Assert-Equal 'Hola qu' $tr.Open.them 'transcript: interim is the open line'
$line = Update-WhisperTranscript $tr 'them' 'final' ' Hola, que tal ' $at
Assert-Equal 'Hola, que tal' $line.Text 'transcript: final line trimmed'
Assert-Equal '' $tr.Open.them 'transcript: final closes the open line'
[void](Update-WhisperTranscript $tr 'me' 'final' 'Bien' $at)
Assert-Equal $null (Update-WhisperTranscript $tr 'me' 'final' '   ' $at) 'transcript: empty final ignored'
Assert-Equal ("Ellos: Hola, que tal`n" + (Tx 'T\u00fa') + ': Bien') (Format-WhisperTranscript (Pop-WhisperUnsent $tr)) 'transcript: unsent lines formatted'
$rest = Pop-WhisperUnsent $tr
Assert-Equal 0 $rest.Count 'transcript: nothing unsent after a request'

$ev = ConvertFrom-ClaudeLine '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola"}}}'
Assert-Equal 'delta|Hola' "$($ev.Kind)|$($ev.Text)" 'stream-json: text delta'
Assert-Equal $null (ConvertFrom-ClaudeLine '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}}') 'stream-json: thinking is not shown'
$ev = ConvertFrom-ClaudeLine '{"type":"result","subtype":"error_during_execution","is_error":true}'
Assert-Equal 'result||True' "$($ev.Kind)|$($ev.Text)|$($ev.Interrupted)" 'stream-json: interrupted turn is not an error'
$ev = ConvertFrom-ClaudeLine '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"boom"}'
Assert-Equal 'result|boom' "$($ev.Kind)|$($ev.Text)" 'stream-json: failed turn carries its error'
Assert-Equal $null (ConvertFrom-ClaudeLine 'not json') 'stream-json: noise ignored'
$in = ConvertTo-ClaudeInputLine 'mira' 'QUJD' | ConvertFrom-Json
Assert-Equal 'user|image|image/png|QUJD|text|mira' ('{0}|{1}|{2}|{3}|{4}|{5}' -f $in.type, $in.message.content[0].type, $in.message.content[0].source.media_type, $in.message.content[0].source.data, $in.message.content[1].type, $in.message.content[1].text) 'stream-json: image message'
Assert-Equal 'hola' ((ConvertTo-ClaudeInputLine 'hola' '' | ConvertFrom-Json).message.content) 'stream-json: text message'

$hk = ConvertFrom-WhisperHotkey 'Ctrl+Alt+Shift+R'
Assert-Equal '7|82' "$($hk.Mods)|$($hk.Key)" 'hotkey: ctrl+alt+shift+r'
$hk = ConvertFrom-WhisperHotkey 'Win+Ctrl+1'
Assert-Equal '10|49' "$($hk.Mods)|$($hk.Key)" 'hotkey: digit key'
Assert-Equal $null (ConvertFrom-WhisperHotkey 'R') 'hotkey: needs a modifier'
Assert-Equal $null (ConvertFrom-WhisperHotkey 'Ctrl+Nope') 'hotkey: unknown key'

$prompt = New-WhisperSystemPrompt (Get-WhisperSettings ([pscustomobject]@{ language = 'en'; profile = 'Ten years of Go.' }))
Assert-Equal $true ($prompt.Contains('Ten years of Go.') -and $prompt.Contains('English')) 'system prompt: profile and language'
Assert-Equal $false ($prompt.Contains('## ' + (Tx 'Indicaciones del usuario'))) 'system prompt: empty sections left out'
$cargs = Get-ClaudeArguments 'sonnet' 'C:\x\p.txt'
foreach ($flag in '--input-format stream-json', '--tools ""', '--safe-mode', '--setting-sources project', '--no-session-persistence', '--system-prompt-file "C:\x\p.txt"') {
    Assert-Equal $true $cargs.Contains($flag) "claude arguments: $flag"
}
Assert-Equal $true ((Get-ClaudeRemovedEnv) -contains 'ANTHROPIC_API_KEY') 'claude env: API key removed (subscription only)'
Assert-Equal 'Teams,Zoom' ((Get-MeetingApps @('chrome', 'ms-teams', 'Zoom', 'CptHost')) -join ',') 'meeting apps from mic users'

$csTemp = Join-Path $env:TEMP ('whisper-test-{0}.dll' -f [guid]::NewGuid().ToString('N'))
try {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $TrayRoot 'lib\whisper.cs'))) -ReferencedAssemblies System.Web.Extensions, System.Windows.Forms -OutputAssembly $csTemp -OutputType Library
    Add-Type -Path $csTemp
    Assert-Equal 'Kubernetes,C#,Caf' ([ClaudeWhisper.SttStream]::CleanKeyterms((Tx 'Kubernetes, C#,kubernetes,  ,Caf\u00e9'))) 'whisper.cs: compiles; keyterms cleaned like Claude Code'
    Assert-Equal $null ([ClaudeWhisper.SttStream]::ReadToken((Join-Path $env:TEMP 'no-such-credentials.json'))) 'whisper.cs: no credentials, no token'
} catch {
    Assert-Equal '' $_.Exception.Message 'whisper.cs compiles'
}

# --- Agenda automatica (lib\autoplan.ps1)
. (Join-Path $TrayRoot 'lib\autoplan.ps1')
Assert-Equal 'Auto-20261019-1505' (Get-SessionTaskName (Get-Date -Year 2026 -Month 10 -Day 19 -Hour 15 -Minute 5) 'Auto-') 'auto task name'
$autoSettings = Get-AutoPlanSettings ([pscustomobject]@{ enabled = $true; boundary = 30; days = 20 })
Assert-Equal 'True|-1|7' ('{0}|{1}|{2}' -f $autoSettings.enabled, $autoSettings.boundary, $autoSettings.days) 'auto settings: bad boundary means computed, days capped'
# a day from 6:00 to 1:00 with the most use at 14-16
$hourly = @(1200, 0, 0, 0, 0, 0, 1200, 1800, 2400, 3000, 3000, 3000, 3000, 3000, 4200, 4500, 3000, 3000, 2400, 2400, 2400, 1800, 1800, 1200)
$autoProfile = Get-UsageProfile $hourly 3
Assert-Equal 1500 $autoProfile[15] 'auto: profile is the average per active day'
$peak = Get-PeakZone $autoProfile
Assert-Equal '14|16|15' ('{0}|{1}|{2}' -f $peak.Start, $peak.End, $peak.Boundary) 'auto: the busiest 2 hours and their middle'
$span = Get-ActiveSpan $autoProfile
Assert-Equal '6|25' ('{0}|{1}' -f $span.Start, $span.End) 'auto: the active day runs from the end of the night to past midnight'
Assert-Equal '5,10,15,20' ((Get-AutoChain 15 $span) -join ',') 'auto: 5-hour chain through the boundary, from the start of the day'
Assert-Equal '10,15,20,25' ((Get-AutoChain 1 ([pscustomobject]@{ Start = 10; End = 27 })) -join ',') 'auto: a boundary after midnight stays in the same day'
$plan = Get-AutoPlan $hourly 3 -1
Assert-Equal '15|False' ('{0}|{1}' -f $plan.Boundary, $plan.Manual) 'auto: computed boundary'
Assert-Equal '17|True' ('{0}|{1}' -f (Get-AutoPlan $hourly 3 17).Boundary, (Get-AutoPlan $hourly 3 17).Manual) 'auto: a boundary moved by hand wins'
$autoNow = Get-Date -Year 2026 -Month 10 -Day 19 -Hour 12 -Minute 0 -Second 0 -Millisecond 0
$slots = Get-AutoSlots $plan.Starts $autoNow 1
Assert-Equal '19 15:05,19 20:05,20 05:05,20 10:05,20 15:05,20 20:05' (@($slots | ForEach-Object { $_.ToString('dd HH:mm') }) -join ',') 'auto: starts from now through tomorrow'
$slots24 = Get-AutoSlots @(0, 5, 10, 15, 20) $autoNow 1
Assert-Equal '' (@($slots24 | Where-Object { $_.ToString('dd HH:mm') -eq '20 00:05' }) -join ',') 'auto: no start inside the window before it'
$tasks = @(
    [pscustomobject]@{ Name = 'Session-20261019-1520'; At = $autoNow.Date.AddHours(15).AddMinutes(20) },
    [pscustomobject]@{ Name = 'Session-20261020-0705'; At = $autoNow.Date.AddDays(1).AddHours(7).AddMinutes(5) },
    [pscustomobject]@{ Name = 'Auto-20261019-1705'; At = $autoNow.Date.AddHours(17).AddMinutes(5) },
    [pscustomobject]@{ Name = 'Auto-20261019-2005'; At = $autoNow.Date.AddHours(20).AddMinutes(5) }
)
$changes = Get-AutoChanges $slots $tasks $autoNow
Assert-Equal '20 05:05,20 10:05,20 15:05,20 20:05' (@($changes.Add | ForEach-Object { $_.ToString('dd HH:mm') }) -join ',') 'auto: adds what has nothing scheduled near it'
Assert-Equal 'Auto-20261019-1705' (@($changes.Remove | ForEach-Object { $_.Name }) -join ',') 'auto: removes only its own tasks off the plan'
Assert-Equal 'Session-20261020-0705' (@(Get-AutoConflicts $slots $tasks $autoNow 1 | ForEach-Object { $_.Name }) -join ',') 'auto: hand-made tasks that break the chain'
Assert-Equal $true (Test-AutoAligned $autoNow.Date.AddHours(15).AddMinutes(10) $plan.Starts) 'auto: a window ending on a planned change is aligned'
Assert-Equal $false (Test-AutoAligned $autoNow.Date.AddHours(17).AddMinutes(40) $plan.Starts) 'auto: one ending elsewhere is not'
Assert-Equal $false (Get-AutoPlan (@(0) * 24) 1 -1).HasData 'auto: no use, no plan'
$even = @(0) * 24; $even[12] = 1000; $even[13] = 1000; $even[14] = 1020; $even[15] = 1020
Assert-Equal '15|13' ('{0}|{1}' -f (Get-AutoPlan $even 1 -1 -1).Boundary, (Get-AutoPlan $even 1 -1 13).Boundary) 'auto: a near tie keeps the boundary in use'
$even[14] = 1300; $even[15] = 1300
Assert-Equal '15|14' ('{0}|{1}' -f (Get-AutoPlan $even 1 -1 13).Boundary, (Get-AutoPlan $even 1 -1 13).Peak.Start) 'auto: a clearly busier zone moves it'
Assert-Equal 2 (Get-AutoPlanSettings ([pscustomobject]@{ lastBoundary = 2 })).lastBoundary 'auto settings: last boundary kept'

# --- Estadisticas (lib\stats.cs): two sessions at once, a subagent, hook and local-command lines
$statsDir = Join-Path $env:TEMP ('cmx-stats-test-' + [guid]::NewGuid().ToString('N'))
try {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $TrayRoot 'lib\stats.cs'))) -ReferencedAssemblies System.Web.Extensions, System.Core
    $t0 = [DateTime]::UtcNow.AddHours(-2)
    function Get-Stamp([int]$Seconds) { $t0.AddSeconds($Seconds).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    $tail = ',"cwd":"C:\\work\\demo","sessionId":"s"}'
    function New-Prompt([int]$At, [string]$Text, [string]$Extra = '') { '{"parentUuid":null,"isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":"' + $Text + '"}' + $Extra + ',"uuid":"u' + $At + '","timestamp":"' + (Get-Stamp $At) + '"' + $tail }
    function New-Reply([int]$At, [string]$Id, [string]$Model, [string]$Content, [string]$Usage) {
        '{"parentUuid":"x","isSidechain":false,"message":{"model":"' + $Model + '","id":"' + $Id + '","type":"message","role":"assistant","content":[' + $Content + '],"usage":{' + $Usage + '}},"requestId":"r","type":"assistant","uuid":"a' + $At + '","timestamp":"' + (Get-Stamp $At) + '"' + $tail
    }
    $usage1 = '"input_tokens":10,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":20'
    $sessionA = @(
        (New-Prompt 0 'hola'),
        (New-Reply 60 'msg_1' 'claude-opus-5-5' '{"type":"thinking","thinking":"","signature":"x"}' $usage1),
        (New-Reply 60 'msg_1' 'claude-opus-5-5' '{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}' $usage1),
        ('{"parentUuid":"a","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]},"uuid":"u120","timestamp":"' + (Get-Stamp 120) + '"' + $tail),
        (New-Reply 180 'msg_2' 'claude-opus-5-5' '{"type":"text","text":"listo"}' '"input_tokens":1,"output_tokens":5'),
        (New-Prompt 240 'Stop hook' ',"isMeta":true'),
        (New-Prompt 300 '<local-command-stdout>x</local-command-stdout>')
    )
    $sessionB = @((New-Prompt 100 'otra'), (New-Reply 400 'msg_3' 'claude-sonnet-5' '{"type":"text","text":"si"}' '"input_tokens":2,"output_tokens":7'))
    $subagent = @((New-Reply 150 'msg_4' 'claude-haiku-4-5-20251001' '{"type":"tool_use","id":"toolu_2","name":"Read","input":{}}' '"input_tokens":3,"output_tokens":3'))
    $project = Join-Path $statsDir 'projects\C--work-demo'
    New-Item -ItemType Directory -Force -Path (Join-Path $project 'a\subagents') | Out-Null
    [IO.File]::WriteAllLines((Join-Path $project 'a.jsonl'), [string[]]$sessionA)
    [IO.File]::WriteAllLines((Join-Path $project 'b.jsonl'), [string[]]$sessionB)
    [IO.File]::WriteAllLines((Join-Path $project 'a\subagents\agent-1.jsonl'), [string[]]$subagent)
    $cachePath = Join-Path $statsDir 'cache.json'
    $outPath = Join-Path $statsDir 'stats.json'
    $result = [ClaudeMaxxing.Stats]::Scan((Join-Path $statsDir 'projects'), $cachePath, $outPath) | ConvertFrom-Json
    $all = $result.all
    Assert-Equal '2|4|2|1' ('{0}|{1}|{2}|{3}' -f $all.prompts, $all.responses, $all.sessions, $all.subagents) 'stats: prompts (no hook or local-command lines), replies, sessions, subagents'
    Assert-Equal '460|720' ('{0}|{1}' -f $all.seconds, $all.sessionSeconds) 'stats: wall-clock time merges parallel sessions; session time adds them'
    Assert-Equal '35|1000|50' ('{0}|{1}|{2}' -f $all.tokens.output, $all.tokens.cacheRead, $all.tokens.cacheWrite) 'stats: a reply split over several lines counts its tokens once'
    Assert-Equal 'Bash:1,Read:1' (@($all.tools | ForEach-Object { "$($_.name):$($_.count)" } | Sort-Object) -join ',') 'stats: tool uses, subagents included'
    Assert-Equal 'demo|2' ('{0}|{1}' -f $all.projects[0].name, $all.projects[0].sessions) 'stats: project from the working folder'
    Assert-Equal 460 (($all.hourly | Measure-Object -Sum).Sum) 'stats: hours of the day add up to the wall-clock time'
    Assert-Equal 2 $result.recent.prompts 'stats: the last 30 days include today'
    $tk = $all.tokens
    Assert-Equal ([double]($tk.input + $tk.output + $tk.cacheRead + $tk.cacheWrite)) ([double]$all.usage.tokens) 'stats: consumption counts every token of every reply once, subagents included'
    Assert-Equal $true ([double]$all.usage.cost -gt 0) 'stats: consumption has an API-equivalent cost'
    Assert-Equal 1 @($all.usage.windows).Count 'stats: replies close together make one 5-hour window'
    Assert-Equal $true (Test-Path -LiteralPath $outPath) 'stats: result written'
    $again = [ClaudeMaxxing.Stats]::Scan((Join-Path $statsDir 'projects'), $cachePath, $outPath) | ConvertFrom-Json
    Assert-Equal '0|2' ('{0}|{1}' -f $again.filesRead, $again.all.prompts) 'stats: unchanged transcripts come from the cache'
    # Claude Code deletes old transcripts; their days stay in the statistics.
    Remove-Item -LiteralPath (Join-Path $project 'b.jsonl')
    $kept = [ClaudeMaxxing.Stats]::Scan((Join-Path $statsDir 'projects'), $cachePath, $outPath) | ConvertFrom-Json
    Assert-Equal '2|720|2' ('{0}|{1}|{2}' -f $kept.all.prompts, $kept.all.sessionSeconds, $kept.all.sessions) 'stats: a deleted transcript stays in the history'
} catch {
    Assert-Equal '' $_.Exception.Message 'stats.cs compiles and scans'
} finally {
    Remove-Item -LiteralPath $statsDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stats: replies without token counts count with the cost Claude Code recorded
$costDir = Join-Path $env:TEMP ('cmx-stats-cost-' + [guid]::NewGuid().ToString('N'))
try {
    $costProject = Join-Path $costDir 'projects\C--work-cost'
    New-Item -ItemType Directory -Force -Path $costProject | Out-Null
    $c0 = (Get-Date).Date.AddDays(-2).AddHours(10)
    $reply = '{"parentUuid":"x","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_c1","type":"message","role":"assistant","content":[]},"costUSD":0.5,"type":"assistant","uuid":"c1","timestamp":"' + $c0.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '","cwd":"C:\work\cost","sessionId":"c"}'
    $state = '{"type":"cost-state","sessionId":"d","totalCostUSD":1.25,"startTime":' + [DateTimeOffset]::new($c0.AddHours(1)).ToUnixTimeMilliseconds() + '}'
    [IO.File]::WriteAllLines((Join-Path $costProject 'c.jsonl'), [string[]]@($reply))
    [IO.File]::WriteAllLines((Join-Path $costProject 'd.jsonl'), [string[]]@($state))
    $costResult = [ClaudeMaxxing.Stats]::Scan((Join-Path $costDir 'projects'), (Join-Path $costDir 'cache.json'), (Join-Path $costDir 'stats.json')) | ConvertFrom-Json
    $cu = $costResult.recent.usage
    Assert-Equal '1.75|0' ('{0}|{1}' -f ([double]$cu.directCost).ToString([Globalization.CultureInfo]::InvariantCulture), [double]$cu.tokens) 'stats: a reply with only costUSD and a session with only cost-state count with their recorded cost'
    Assert-Equal '1|1.75' ('{0}|{1}' -f $cu.windowCost.count, ([double]$cu.windowCost.avg).ToString([Globalization.CultureInfo]::InvariantCulture)) 'stats: recorded costs land in their hours and their 5-hour window'
    Assert-Equal '0.5|1.25' ('{0}|{1}' -f ([double]$cu.hourlyCost[10]).ToString([Globalization.CultureInfo]::InvariantCulture), ([double]$cu.hourlyCost[11]).ToString([Globalization.CultureInfo]::InvariantCulture)) 'stats: recorded costs by hour of the day'
} catch {
    Assert-Equal '' $_.Exception.Message 'stats: recorded costs'
} finally {
    Remove-Item -LiteralPath $costDir -Recurse -Force -ErrorAction SilentlyContinue
}

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
