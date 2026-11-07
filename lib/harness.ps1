# Ambientes: the work environments of harness\ (env.js and its Chrome extension, formerly YourHarness) as a graph
# in the ClaudeMaxxing window. Turning one on or off runs `node harness\env.js <id> on|off --yes --job` hidden; its
# progress comes back through run\job.json and the environment that is on through run\active.json, both under
# $HarnessHome. Reading those files is cheap, so the hub timer can call Get-HarnessState every tick.
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

# Per PC, never in the repo: environments\*.json (they name this PC's profiles, folders and URLs), run\ (state,
# history, detection, Chrome hosts) and .env (the Jev key). env.js defaults to the same folder.
$HarnessHome = Join-Path $TrayHome 'harness'

function Test-HarnessDir([string]$Dir) { $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'env.js')) }

# harness\ next to this tray: the install folder, or the repo when the tray runs from source.
function Get-HarnessDir {
    $dir = Join-Path $TrayRoot 'harness'
    if (Test-HarnessDir $dir) { $dir } else { $null }
}

function Test-HarnessPidAlive($ProcessId) {
    if (-not $ProcessId) { return $false }
    [bool](Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
}

# Environments (id, name, focus), the one that is on and the last change. A job whose process died
# mid-way is reported as interrupted, so a dot never stays busy forever.
function Get-HarnessState([string]$Dir = (Get-HarnessDir), [string]$DataDir = $HarnessHome) {
    if (-not $Dir) { return @{ Dir = $null; Envs = @(); Active = $null; Job = $null } }
    $envs = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'environments') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $def = Read-JsonFile $file.FullName
        $envs += [pscustomobject]@{ Id = $file.BaseName.ToLowerInvariant(); Name = $(if ($def -and $def.name) { [string]$def.name } else { $file.BaseName }); Focus = $(if ($def) { [string]$def.focus } else { '' }) }
    }
    $run = Join-Path $DataDir 'run'
    $active = Read-JsonFile (Join-Path $run 'active.json')
    $job = Read-JsonFile (Join-Path $run 'job.json')
    if ($job -and $job.state -eq 'running' -and -not (Test-HarnessPidAlive $job.pid)) {
        # Add-Member: the file may lack "message", and a missing property cannot be assigned.
        $job | Add-Member -NotePropertyName state -NotePropertyValue 'error' -Force
        $job | Add-Member -NotePropertyName message -NotePropertyValue (Tx 'el proceso se interrumpi\u00f3') -Force
    }
    # history.json: the switches and time per environment; detect.json: the last "which one am I in?" verdict;
    # focus.json: what the environment on would close and the dev servers listening (SelfHarness).
    @{ Dir = $Dir; DataDir = $DataDir; Envs = $envs; Active = $active; Job = $job; History = (Read-JsonFile (Join-Path $run 'history.json')); Detect = (Read-JsonFile (Join-Path $run 'detect.json'))
        Focus = (Read-JsonFile (Join-Path $run 'focus.json')) }
}

# The graph from history.json: seconds per environment (today and in total, the one on counting until now)
# and one edge per direction with how many times you switched that way.
function Get-HarnessGraph($State, [datetime]$Now = (Get-Date)) {
    $today = $Now.ToString('yyyy-MM-dd')
    $weekStart = $Now.Date.AddDays(-6).ToString('yyyy-MM-dd')  # the last 7 days, today included
    $time = @{}
    foreach ($e in @($State.Envs)) { $time[$e.Id] = @{ Today = 0.0; Week = 0.0; Total = 0.0; Entries = 0 } }
    $hist = $State.History
    if ($hist -and $hist.time) {
        foreach ($day in $hist.time.PSObject.Properties) {
            foreach ($entry in $day.Value.PSObject.Properties) {
                if (-not $time.ContainsKey($entry.Name)) { continue }
                $time[$entry.Name].Total += [double]$entry.Value
                if ($day.Name -eq $today) { $time[$entry.Name].Today += [double]$entry.Value }
                # ISO dates compare as text.
                if ([string]::CompareOrdinal($day.Name, $weekStart) -ge 0) { $time[$entry.Name].Week += [double]$entry.Value }
            }
        }
    }
    $active = $State.Active
    if ($active -and $active.since -and $time.ContainsKey([string]$active.id)) {
        # The same 12-hour cap as env.js: the PC may have slept with it on.
        try { $since = [datetime]$active.since } catch { $since = $null }
        if ($since) {
            $running = [Math]::Min(12 * 3600, [Math]::Max(0, ($Now - $since).TotalSeconds))
            $time[[string]$active.id].Total += $running
            if ($since.ToString('yyyy-MM-dd') -eq $today) { $time[[string]$active.id].Today += $running }
            if ([string]::CompareOrdinal($since.ToString('yyyy-MM-dd'), $weekStart) -ge 0) { $time[[string]$active.id].Week += $running }
        }
    }
    $edges = @()
    if ($hist -and $hist.edges) {
        foreach ($edge in $hist.edges.PSObject.Properties) {
            $from, $to = $edge.Name -split '>', 2
            if ($time.ContainsKey($from) -and $time.ContainsKey($to) -and [int]$edge.Value -gt 0) {
                $edges += [pscustomobject]@{ From = $from; To = $to; Count = [int]$edge.Value }
                $time[$to].Entries += [int]$edge.Value
            }
        }
    }
    # Focus span: the time per stint. Stints are entries by a switch; the very first one has no edge into it.
    foreach ($t in $time.Values) { $t.Mean = if ($t.Total -gt 0) { $t.Total / [Math]::Max(1, $t.Entries) } else { 0.0 } }
    $top = @($edges | Sort-Object Count -Descending | Select-Object -First 1)
    @{ Time = $time; Edges = $edges; Switches = [int](@($edges | ForEach-Object { $_.Count }) + 0 | Measure-Object -Sum).Sum; Top = $(if ($top.Count) { $top[0] } else { $null }) }
}

function Get-HarnessNode {
    $cmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cmd.Source } else { $null }
}

# Starts the change in the background. Returns an error text, or $null when it started.
function Start-HarnessJob([string]$Dir, [string]$Id, [ValidateSet('on', 'off')][string]$Action) {
    if (-not (Test-HarnessDir $Dir)) { return 'Falta harness\env.js: vuelve a ejecutar install.ps1.' }
    if ($Id -notmatch '^[a-z0-9_-]+$') { return (Tx 'Ambiente con nombre no v\u00e1lido: ') + $Id }
    $node = Get-HarnessNode
    if (-not $node) { return Tx 'No encuentro Node.js: inst\u00e1lalo para usar los ambientes.' }
    $current = (Get-HarnessState $Dir).Job
    if ($current -and $current.state -eq 'running') { return "Ya hay un cambio en curso: $($current.action) $($current.name)" }
    $entry = Join-Path $Dir 'env.js'
    Start-Process -FilePath $node -ArgumentList ('"{0}" {1} {2} --yes --job' -f $entry, $Id, $Action) -WorkingDirectory $Dir -WindowStyle Hidden
    $null
}

# "Which environment am I in?": `node env.js detect` hidden (with -Force, it asks even when nothing changed).
# Returns the process, or $null when it could not start.
function Start-HarnessDetect([string]$Dir, [switch]$Force) {
    if (-not (Test-HarnessDir $Dir)) { return $null }
    $node = Get-HarnessNode
    if (-not $node) { return $null }
    $arguments = '"{0}" detect{1}' -f (Join-Path $Dir 'env.js'), $(if ($Force) { ' --force' } else { '' })
    Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
}

# SelfHarness: the watcher's settings, per PC. Values missing from the file, or not among the choices the window
# offers, fall back to the defaults (3 minutes, 60 %, quiet while Gaming is on: a game may be full screen).
$SelfHarnessFile = Join-Path $TrayHome 'selfharness.json'
$SelfHarnessMinutes = @(1, 2, 3, 5, 10, 15, 30)
$SelfHarnessConfidences = @(0.5, 0.6, 0.7, 0.8, 0.9)

function Get-SelfHarnessSettings($Saved = (Read-JsonFile $SelfHarnessFile)) {
    $s = [ordered]@{ detect = $true; minutes = 3; minConfidence = 0.6; quiet = @('gaming') }
    if ($Saved) {
        if ($null -ne $Saved.detect) { $s.detect = [bool]$Saved.detect }
        if ($SelfHarnessMinutes -contains [int]$Saved.minutes) { $s.minutes = [int]$Saved.minutes }
        if ($SelfHarnessConfidences -contains [double]$Saved.minConfidence) { $s.minConfidence = [double]$Saved.minConfidence }
        if ($null -ne $Saved.quiet) { $s.quiet = @($Saved.quiet | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[a-z0-9_-]+$' }) }
    }
    $s
}

function Set-SelfHarnessSetting([string]$Name, $Value) {
    $s = Get-SelfHarnessSettings
    $s[$Name] = $Value
    Write-JsonFile $SelfHarnessFile $s
}

# Whether a verdict from detect.json should be offered now: another environment fits with at least the minimum
# confidence, it is about the environment that is on now (not one from before a switch), it is fresh, it was not
# asked already and the environment on is not a quiet one.
function Test-HarnessOffer($State, [string]$Asked, [datetime]$Now = (Get-Date), [double]$MinConfidence = 0.6, [string[]]$Quiet = @()) {
    $d = $State.Detect
    if (-not $d -or -not $d.suggestion -or [string]$d.at -eq $Asked -or [double]$d.confidence -lt $MinConfidence) { return $false }
    if ($State.Job -and $State.Job.state -eq 'running') { return $false }
    $activeId = if ($State.Active) { [string]$State.Active.id } else { '' }
    if ($Quiet -contains $activeId) { return $false }
    if ([string]$d.suggestion -eq $activeId -or [string]$d.active -ne $activeId) { return $false }
    if (-not @($State.Envs | Where-Object { $_.Id -eq [string]$d.suggestion }).Count) { return $false }
    try { $at = [datetime]$d.at } catch { return $false }
    ($Now - $at).TotalMinutes -lt 10
}

# Tray timer: a detection every few minutes (SelfHarness settings); when it finds you in another environment, a
# question in your face (topmost, on the active desktop). One question per verdict: "No" is remembered until what
# is open changes. In a quiet environment there is no detection at all (it also costs CPU).
$script:HarnessWatch = @{ Process = $null; LastRun = [datetime]::MinValue; Asked = $null; Asking = $false; Hidden = @{} }

function Invoke-HarnessWatch {
    $w = $script:HarnessWatch
    if ($w.Asking) { return }  # the question is open: this timer still ticks inside its message loop
    $dir = Get-HarnessDir
    if (-not $dir) { return }
    $state = Get-HarnessState $dir
    $settings = Get-SelfHarnessSettings
    # A verdict that was already there when the tray started is not asked.
    if ($null -eq $w.Asked) { $w.Asked = if ($state.Detect) { [string]$state.Detect.at } else { '' } }
    if (-not $settings.detect -or ($state.Active -and $settings.quiet -contains [string]$state.Active.id)) { return }
    $idle = -not ($state.Job -and $state.Job.state -eq 'running') -and -not ($w.Process -and -not $w.Process.HasExited)
    if ($idle -and ((Get-Date) - $w.LastRun).TotalMinutes -ge $settings.minutes) {
        $w.LastRun = Get-Date
        $w.Process = Start-HarnessDetect $dir
    }
    if (-not (Test-HarnessOffer $state $w.Asked (Get-Date) $settings.minConfidence $settings.quiet)) { return }
    $d = $state.Detect
    $w.Asked = [string]$d.at
    $w.Asking = $true
    try { $yes = Show-HarnessOffer $d $state } finally { $w.Asking = $false }
    if (-not $yes) { return }
    $failed = Start-HarnessJob $dir ([string]$d.suggestion) 'on'
    if ($failed -and $script:Notify) { $script:Notify.ShowBalloonTip(6000, 'Ambientes', $failed, [System.Windows.Forms.ToolTipIcon]::Warning) }
    if ($script:HubDialog) { try { Update-HubNow } catch { } }
}

# SelfHarness: closes tabs by id through harness\tabs.js, hidden (a closed tab comes back with Ctrl+Shift+T).
# Returns an error text, or $null when it started.
function Close-HarnessTabs([string]$Dir, [long[]]$Ids) {
    $node = Get-HarnessNode
    if (-not $node -or -not (Test-HarnessDir $Dir)) { return 'Falta Node.js o harness\tabs.js.' }
    if (-not $Ids.Count) { return $null }
    Start-Process -FilePath $node -ArgumentList ('"{0}" close {1}' -f (Join-Path $Dir 'tabs.js'), ($Ids -join ' ')) -WorkingDirectory $Dir -WindowStyle Hidden
    $null
}

# SelfHarness: stops a dev server the user picked, only if that process still listens on that port (a PID may have
# been reused since the last detection), with its whole tree (npm -> node). Returns an error text, or $null.
function Stop-HarnessServer([int]$Port, [int]$ProcessId) {
    $owner = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.OwningProcess })
    if ($owner -notcontains $ProcessId) { return "El puerto $Port ya no es de ese proceso: nada que apagar." }
    & taskkill.exe /PID $ProcessId /T /F *> $null
    if ($LASTEXITCODE -ne 0) { return "No se pudo apagar el proceso $ProcessId." }
    $null
}

# Who judged, as a name: jev -> Jev, claude -> Claude.
function Format-HarnessJudge([string]$Judge) { if ($Judge) { $Judge.Substring(0, 1).ToUpper() + $Judge.Substring(1) } else { '' } }

function Show-HarnessOffer($Detect, $State) {
    # Tx only on literal text: names and reasons may hold backslashes, which Tx would try to decode.
    $text = (Tx '\u00bfQuieres pasarte a ') + $Detect.name + '?' + "`n`n" +
        'Lo que tienes abierto parece ' + $Detect.name + (Tx ' (seg\u00fan ') + (Format-HarnessJudge $Detect.judge) + ', ' + [int]([double]$Detect.confidence * 100) + ' %).'
    if ($Detect.reason) { $text += "`n" + $Detect.reason }
    if ($State.Active) { $text += "`n`n" + (Tx 'Ahora est\u00e1s en ') + $State.Active.name + '.' }
    $text += ' ' + (Tx 'S\u00ed lo enciende: cierra lo que no es suyo, con apagado suave, y abre lo suyo.')
    # DefaultDesktopOnly: topmost and in front even when ClaudeMaxxing has no window open.
    $answer = [System.Windows.Forms.MessageBox]::Show($text, 'ClaudeMaxxing - Ambientes', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button1, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}
