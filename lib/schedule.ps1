# Scheduling helpers: one-shot Task Scheduler tasks that start a Claude session at a given time,
# plus the prompt used to create a cloud routine through /schedule.

$script:SessionTaskPath = '\ClaudeMaxxing\'
# Folder used before the rename; only cleaned up.
$script:LegacySessionTaskPath = '\ClaudeTray\'

# Prefix: Session- for the ones you schedule, Auto- for the automatic agenda (libutoplan.ps1).
function Get-SessionTaskName([datetime]$At, [string]$Prefix = 'Session-') {
    $Prefix + $At.ToString('yyyyMMdd-HHmm')
}

function New-SessionTask([datetime]$At, [string]$ScriptPath, [string]$Prefix = 'Session-') {
    $arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At $At
    # Lets the expired task delete itself; a late start (StartWhenAvailable) still fits in 12 hours.
    $trigger.EndBoundary = $At.AddHours(12).ToString('s')
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -DeleteExpiredTaskAfter (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName (Get-SessionTaskName $At $Prefix) -TaskPath $script:SessionTaskPath `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'ClaudeMaxxing: start a Claude usage session' -Force | Out-Null
}

function Get-SessionTasks {
    $tasks = @(Get-ScheduledTask -TaskPath $script:SessionTaskPath -ErrorAction SilentlyContinue)
    $now = Get-Date
    $items = foreach ($task in $tasks) {
        if (-not $task.Triggers -or -not $task.Triggers[0].StartBoundary) { continue }
        $at = [DateTimeOffset]::Parse($task.Triggers[0].StartBoundary).LocalDateTime
        if ($at -le $now) { continue }
        [pscustomobject]@{ Name = $task.TaskName; At = $at }
    }
    @($items | Sort-Object At)
}

# $true when the task is gone, so callers only report what really happened.
function Remove-SessionTask([string]$Name) {
    try { Unregister-ScheduledTask -TaskName $Name -TaskPath $script:SessionTaskPath -Confirm:$false -ErrorAction Stop; $true } catch { $false }
}

# Returns how many tasks were removed. -LegacyOnly: only the ones in the old folder, whose action points
# at a start-session.ps1 that may no longer exist.
function Remove-AllSessionTasks([switch]$LegacyOnly) {
    $paths = if ($LegacyOnly) { @($script:LegacySessionTaskPath) } else { @($script:SessionTaskPath, $script:LegacySessionTaskPath) }
    $removed = 0
    foreach ($path in $paths) {
        foreach ($task in @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
            $removed++
        }
    }
    $removed
}

function Format-UtcOffset([datetime]$At) {
    $offset = [TimeZoneInfo]::Local.GetUtcOffset($At)
    $sign = if ($offset -lt [timespan]::Zero) { '-' } else { '+' }
    '{0}{1:hh\:mm}' -f $sign, $offset.Duration()
}

# Routine the user sees and confirms in the schedule dialog; the dialog shows the same details
# while Claude Code creates it (no terminal window).
$script:CloudRoutine = @{ Name = 'Usage window warm-up'; Prompt = 'Reply with only the word ok.'; Model = 'Haiku' }

function Format-CloudSchedulePrompt([datetime]$At) {
    $when = $At.ToString('yyyy-MM-dd HH:mm')
    $offset = Format-UtcOffset $At
    "/schedule one-off run at $when (UTC$offset). Routine name: $($script:CloudRoutine.Name). " +
    "Routine prompt: $($script:CloudRoutine.Prompt) Purpose: start my 5-hour usage window early. " +
    "Model: $($script:CloudRoutine.Model). No repositories. Remove all connectors: create it with an " +
    "explicitly empty connector list (mcp_connections: []). I clicked Agendar in the " +
    "ClaudeMaxxing dialog after reviewing exactly these details, and that dialog is showing the progress " +
    "of this request, so please create it without follow-up questions. End your reply with one line: " +
    "ROUTINE_ID=trig_... with the new routine id, or FAILED=short reason."
}

# The last ROUTINE_ID= / FAILED= line printed by the Claude Code run.
function Get-CloudScheduleOutcome([string]$Output) {
    $id = [regex]::Matches($Output, 'ROUTINE_ID=(trig_[A-Za-z0-9]+)') | Select-Object -Last 1
    if ($id) { return @{ Status = 'scheduled'; RoutineId = $id.Groups[1].Value } }
    $fail = [regex]::Matches($Output, 'FAILED=(.+)') | Select-Object -Last 1
    $reason = if ($fail) { $fail.Groups[1].Value.Trim() } else { (Tx 'Claude Code no devolvi\u00f3 el id de la rutina') }
    if ($reason.Length -gt 120) { $reason = $reason.Substring(0, 120) }
    @{ Status = 'failed'; Error = $reason }
}

# ---------------------------------------------------------------- history and list rows

function ConvertTo-LocalTime([string]$Text) { [DateTimeOffset]::Parse($Text).LocalDateTime }

# Appends to a JSON array file, keeping the newest $Keep entries.
function Add-JsonArrayEntry([string]$Path, $Entry, [int]$Keep = 20) {
    $items = @(Read-JsonFile $Path | Where-Object { $_ })
    $items = @($items) + @($Entry)
    if ($items.Count -gt $Keep) { $items = $items[($items.Count - $Keep)..($items.Count - 1)] }
    Write-JsonFile $Path $items
}

function Add-ScheduleHistory($Entry) { Add-JsonArrayEntry $HistoryFile $Entry }

# Cloud requests: status goes creating -> scheduled (with routineId) or failed (with error).
function Add-CloudRequest([datetime]$At) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    Add-JsonArrayEntry $CloudFile ([ordered]@{ id = $id; at = $At.ToString('o'); requestedAt = (Get-Date).ToString('o'); status = 'creating' })
    $id
}

function Get-CloudRequest([string]$Id) {
    @(Read-JsonFile $CloudFile | Where-Object { $_ -and $_.id -eq $Id }) | Select-Object -First 1
}

function Set-CloudRequestResult([string]$Id, [string]$Status, [string]$RoutineId, [string]$ErrorText) {
    $items = @(Read-JsonFile $CloudFile | Where-Object { $_ })
    foreach ($item in $items) {
        if ($item.id -ne $Id) { continue }
        $item | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force
        if ($RoutineId) { $item | Add-Member -NotePropertyName routineId -NotePropertyValue $RoutineId -Force }
        if ($ErrorText) { $item | Add-Member -NotePropertyName error -NotePropertyValue $ErrorText -Force }
    }
    Write-JsonFile $CloudFile $items
}

# Rows for the "scheduled" list: upcoming first (soonest on top), then past runs (newest on top).
# State: pending (PC task); requested / cloud-ok / cloud-failed (cloud routine);
# ok / failed (PC run); sent (past cloud).
function Get-ScheduleRows($PcTasks, $CloudRequests, $History, [datetime]$Now, [int]$Max = 5) {
    $upcoming = New-Object System.Collections.ArrayList
    $past = New-Object System.Collections.ArrayList
    foreach ($task in @($PcTasks | Where-Object { $_ })) {
        if ($task.At -gt $Now) {
            [void]$upcoming.Add([pscustomobject]@{ At = $task.At; Kind = 'pc'; State = 'pending'; TaskName = $task.Name })
        }
    }
    foreach ($request in @($CloudRequests | Where-Object { $_ -and $_.at })) {
        $at = ConvertTo-LocalTime $request.at
        if ($at -gt $Now) {
            $state = switch ($request.status) { 'scheduled' { 'cloud-ok' } 'failed' { 'cloud-failed' } 'creating' { 'creating' } default { 'requested' } }
            [void]$upcoming.Add([pscustomobject]@{ At = $at; Kind = 'cloud'; State = $state; TaskName = $null })
        } elseif ($request.status -ne 'failed' -and $at -gt $Now.AddDays(-2)) {
            [void]$past.Add([pscustomobject]@{ At = $at; Kind = 'cloud'; State = 'sent'; TaskName = $null })
        }
    }
    foreach ($run in @($History | Where-Object { $_ -and $_.at })) {
        $state = if ($run.ok) { 'ok' } else { 'failed' }
        [void]$past.Add([pscustomobject]@{ At = (ConvertTo-LocalTime $run.at); Kind = 'pc'; State = $state; TaskName = $null })
    }
    $rows = @($upcoming | Sort-Object At) + @($past | Sort-Object At -Descending)
    @($rows | Select-Object -First $Max)
}

# ---------------------------------------------------------------- dialog formatting (current culture)

function Get-DayLabel([datetime]$Date, [datetime]$Now) {
    $days = ($Date.Date - $Now.Date).Days
    if ($days -eq 0) { return 'Hoy' }
    if ($days -eq 1) { return (Tx 'Ma\u00f1ana') }
    if ($days -eq -1) { return 'Ayer' }
    $text = $Date.ToString('ddd d MMM', [System.Globalization.CultureInfo]::CurrentCulture).TrimEnd('.')
    $text.Substring(0, 1).ToUpper() + $text.Substring(1)
}

function Format-Clock([datetime]$Value) {
    $Value.ToString('h:mm tt', [System.Globalization.CultureInfo]::CurrentCulture)
}

function Format-DialogDateTime([datetime]$Value, [datetime]$Now) {
    (Get-DayLabel $Value $Now) + ' ' + (Tx '\u00b7') + ' ' + (Format-Clock $Value)
}
