# "Planear sesion del dia" in the ClaudeMaxxing window: an idea goes on trial before Claude Judge, the court skill
# (github.com/alexyc9381/court-skill, MIT) shipped in claudeJudge\.claude\skills\court. lib\judge-worker.ps1 runs the
# trial hidden with claude -p in $JudgeHome and reports in its status.json; every trial stays in $JudgeHome\.court.
# Each run writes a log in $JudgeHome\logs (checks, the exact command, Claude's JSON answer, stderr, files made).
# Shared by the tray (lib\hubplan.ps1) and the worker. Keep this file ASCII.

# Not under ~/.claude: Claude Code treats every file in a .claude folder as sensitive and refuses to write it
# even in acceptEdits, so no trial could save its case file there.
$JudgeHome       = Join-Path $env:LOCALAPPDATA 'ClaudeJudge'
$JudgeStatusFile = Join-Path $JudgeHome 'status.json'
$JudgeIdeaFile   = Join-Path $JudgeHome 'idea.txt'
$JudgeLogDir     = Join-Path $JudgeHome 'logs'
$JudgeSkillName  = 'court'
# Folders where Claude Code asks before every write (acceptEdits does not cover them).
$JudgeProtectedFolders = @('.claude', '.git', '.vscode', '.idea')

function Test-JudgeProtectedPath([string]$Path) {
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ })
    [bool](@($parts | Where-Object { $JudgeProtectedFolders -contains $_.ToLowerInvariant() }).Count)
}

# The claude command line to run: the one the installer recorded, else claude.exe or claude.cmd on PATH. Only real
# programs: an npm claude.ps1 shim may point at an exe that no longer exists.
function Resolve-JudgeClaude([string]$Preferred) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Preferred) { $candidates.Add($Preferred) }
    $config = Read-JsonFile $ConfigFile
    if ($config -and $config.claudePath) { $candidates.Add([string]$config.claudePath) }
    foreach ($name in 'claude.exe', 'claude.cmd') {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) { $candidates.Add($cmd.Source) }
    }
    $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
    foreach ($path in $candidates) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    $null
}

# What went wrong, in one line for the window, from what claude -p left: its JSON answer ($null when there was none),
# stderr, the exit code and whether it ran out of time. The log keeps the full text.
function Get-JudgeFailure($Answer, [string]$StdErr, [int]$ExitCode, [bool]$TimedOut, [int]$TimeoutMinutes) {
    $clip = { param([string]$s, [int]$n) $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }
    if ($TimedOut) { return ('Claude no termin' + (Tx '\u00f3') + " en $TimeoutMinutes min y se detuvo.") }
    $denials = @($Answer.permission_denials | Where-Object { $_ })
    if ($Answer -and $denials.Count) {
        $first = $denials[0]
        $target = [string]$first.tool_input.file_path
        if (-not $target) { $target = [string]$first.tool_input.command }
        $more = if ($denials.Count -gt 1) { " (y $($denials.Count - 1) m" + (Tx '\u00e1') + 's)' } else { '' }
        return ('Claude no tuvo permiso para ' + $first.tool_name + ' ' + (& $clip $target 120) + $more + '.')
    }
    if ($Answer -and $Answer.is_error) { return ('Claude devolvi' + (Tx '\u00f3') + " un error ($($Answer.subtype)): " + (& $clip ([string]$Answer.result) 200)) }
    if (-not $Answer) {
        $line = @($StdErr -split "`r?`n" | Where-Object { $_.Trim() })[0]
        if ($line) { return ('Claude no arranc' + (Tx '\u00f3') + ': ' + (& $clip $line 200)) }
        return ('Claude no respondi' + (Tx '\u00f3') + " (c" + (Tx '\u00f3') + "digo $ExitCode).")
    }
    'Claude termin' + (Tx '\u00f3') + ' sin veredicto: ' + (& $clip ([string]$Answer.result) 200)
}

# Names from claudeJudge\.claude\skills\court\jurors.json.
$script:JudgeJurors = @{
    'The Accountant' = 'El contador'; 'The First-Time Customer' = 'El cliente nuevo'; 'The Competitor' = 'El competidor'
    'The Retired Judge' = 'La jueza retirada'; 'The Teenager' = 'El adolescente'; 'The Engineer' = 'La ingeniera'
    'The Small-Business Owner' = (Tx 'El due\u00f1o de negocio'); 'The Statistician' = (Tx 'La estad\u00edstica'); 'The Parent' = 'La madre'
    'The Investor' = 'El inversionista'; 'The Designer' = (Tx 'La dise\u00f1adora'); 'The Lawyer' = 'El abogado'
}

function Test-JudgeProcess([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# The worker's last report: @{ state = running|done|error; message; run; previous; jury; pid; at }. A running
# state whose worker is gone is a trial that died (a 12-juror trial can take more than 10 minutes).
function Get-JudgeStatus([string]$Path = $JudgeStatusFile) {
    $status = Read-JsonFile $Path
    if ($status -and $status.state -eq 'running' -and -not (Test-JudgeProcess ([int]$status.pid))) {
        $status.state = 'error'
        $status | Add-Member -NotePropertyName message -NotePropertyValue ('El juicio se interrumpi' + (Tx '\u00f3') + '.') -Force
    }
    $status
}

function Format-JudgeVerdict([string]$Verdict) {
    switch ($Verdict) {
        'GUILTY'     { 'Culpable' }
        'NOT GUILTY' { 'No culpable' }
        'HUNG JURY'  { 'Jurado dividido' }
        default      { 'Sin veredicto' }
    }
}

# "Culpable, 4 a 2": the larger side first, like court.py.
function Format-JudgeScore($Tally) {
    if (-not $Tally) { return 'Sin veredicto' }
    $g = [int]$Tally.guilty; $n = [int]$Tally.not_guilty
    $big, $small = if ($Tally.verdict -eq 'NOT GUILTY') { $n, $g } else { $g, $n }
    '{0}, {1} a {2}' -f (Format-JudgeVerdict $Tally.verdict), $big, $small
}

function Get-JudgeRunDate([string]$Name) {
    $at = [datetime]::MinValue
    if ([datetime]::TryParseExact($Name, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$at)) { return $at }
    $null
}

# One trial folder (.court\<yyyyMMdd-HHmmss>): the idea in the user's words (idea.txt, copied by the worker; else
# the case file Claude wrote), its count and whether the judge has ruled.
function Get-JudgeTrial([string]$Dir) {
    $case = ''
    foreach ($name in 'idea.txt', 'case.md') {
        $file = Join-Path $Dir $name
        if (Test-Path -LiteralPath $file) { $case = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8).Trim(); break }
    }
    $tally = Read-JsonFile (Join-Path $Dir 'tally.json')
    $judgeFile = Join-Path $Dir 'judge\judge.md'
    [pscustomobject]@{
        Dir     = $Dir
        At      = Get-JudgeRunDate (Split-Path -Leaf $Dir)
        Title   = (@($case -split "`r?`n")[0] -replace '^#+\s*', '').Trim()
        Case    = $case
        Tally   = $tally
        Done    = [bool]($tally -and (Test-Path -LiteralPath $judgeFile) -and (Get-Item -LiteralPath $judgeFile).Length -gt 0)
    }
}

# Finished trials, newest first.
function Get-JudgeTrials([string]$Root = $JudgeHome, [int]$Count = 20) {
    $court = Join-Path $Root '.court'
    if (-not (Test-Path -LiteralPath $court)) { return @() }
    $dirs = @(Get-ChildItem -LiteralPath $court -Directory | Where-Object { Get-JudgeRunDate $_.Name } | Sort-Object Name -Descending)
    # The hub calls this every 2 seconds: stop reading once there are enough.
    $trials = New-Object System.Collections.Generic.List[object]
    foreach ($d in $dirs) {
        if ($trials.Count -ge $Count) { break }
        $t = Get-JudgeTrial $d.FullName
        if ($t.Done) { $trials.Add($t) }
    }
    , $trials.ToArray()
}

# Where a running trial is, from the files on disk: "Jurado: 3 de 6".
function Get-JudgeProgress([string]$RunDir) {
    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { return 'Preparando el caso...' }
    $count = { param($sub) @(Get-ChildItem -LiteralPath (Join-Path $RunDir $sub) -Filter *.md -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 }).Count }
    $state = Read-JsonFile (Join-Path $RunDir 'state.json')
    $size = if ($state -and $state.jury) { @($state.jury).Count } else { 0 }
    if ((& $count 'opening') -lt 2) { return 'Alegatos de apertura: fiscal y defensa' }
    if ((& $count 'rebuttal') -lt 2) { return (Tx 'R\u00e9plicas') }
    $jury = & $count 'jury'
    if ($jury -lt $size) { return ('Jurado: {0} de {1} votos' -f $jury, $size) }
    if ((& $count 'judge') -ge 1) { return 'Sentencia lista' }
    'El juez redacta la sentencia'
}

# The feedback shown in the window: verdict, every juror's vote and the judge's text (court.py's VERDICT.md has
# English headings).
function Format-JudgeFeedback($Trial) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('VEREDICTO: ' + (Format-JudgeScore $Trial.Tally).ToUpper())
    $lines.Add('')
    $lines.Add('LA IDEA')
    $lines.Add($Trial.Case)
    $lines.Add('')
    $lines.Add((Tx 'C\u00d3MO VOT\u00d3 EL JURADO'))
    foreach ($j in @($Trial.Tally.jurors)) {
        $name = if ($script:JudgeJurors.ContainsKey([string]$j.juror)) { $script:JudgeJurors[[string]$j.juror] } else { [string]$j.juror }
        $vote = Format-JudgeVerdict $j.vote
        $lines.Add(('- {0} ({1}): {2}' -f $name, $vote, $j.reason).TrimEnd(': '))
        if ($j.flip) { $lines.Add('    Cambiar' + (Tx '\u00ed') + 'a su voto si: ' + $j.flip) }
    }
    $lines.Add('')
    $lines.Add('SENTENCIA DEL JUEZ')
    $judge = [IO.File]::ReadAllText((Join-Path $Trial.Dir 'judge\judge.md'), [Text.Encoding]::UTF8).Trim()
    $lines.Add(($judge -replace '(?m)^#+\s*', '' -replace '\*\*', ''))
    ($lines -join "`r`n")
}

# Starts lib\judge-worker.ps1 hidden. The idea goes through idea.txt (UTF-8): a command line or a pipe to a
# native exe would mangle accents and quotes.
function Start-JudgeJob([string]$Idea, [int]$Jury, [string]$Root = $TrayRoot) {
    New-Item -ItemType Directory -Force $JudgeHome | Out-Null
    [IO.File]::WriteAllText($JudgeIdeaFile, $Idea.Trim(), (New-Object System.Text.UTF8Encoding($false)))
    Write-JsonFile $JudgeStatusFile ([ordered]@{ state = 'running'; message = ''; run = ''; previous = ''; jury = $Jury; pid = 0; at = (Get-Date).ToString('o') })
    $worker = Join-Path $Root 'lib\judge-worker.ps1'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Jury {1}' -f $worker, $Jury) -WindowStyle Hidden -PassThru
    # The worker writes its own pid too; this covers the moment before it starts.
    $status = Read-JsonFile $JudgeStatusFile
    if ($status -and [int]$status.pid -eq 0) { $status.pid = $process.Id; Write-JsonFile $JudgeStatusFile $status }
}
