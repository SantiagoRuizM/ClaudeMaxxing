# Background job for "Planear sesion del dia" (lib\judge.ps1): puts the idea in idea.txt on trial with the court
# skill through claude -p, and reports in status.json. Started hidden from the ClaudeMaxxing window.
# Every run leaves a log in logs\ (its path is in status.json): checks, command, Claude's answer, stderr, files.
# For tests: -WorkDir runs in another folder, -ClaudePath / -Python use fakes, -Model a cheaper model,
# -TimeoutSeconds a short limit.
param([int]$Jury = 6, [string]$WorkDir, [string]$Model = 'sonnet', [string]$ClaudePath, [string]$Python = 'python3',
    [int]$TimeoutSeconds = 3600)

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\judge.ps1')
Clear-ClaudeSessionEnv
if ($WorkDir) {
    $JudgeHome = $WorkDir
    $JudgeStatusFile = Join-Path $WorkDir 'status.json'; $JudgeIdeaFile = Join-Path $WorkDir 'idea.txt'; $JudgeLogDir = Join-Path $WorkDir 'logs'
}
# court.py reads and writes Spanish text (cp1252 by default on Windows); the voice hooks stay quiet.
$env:PYTHONUTF8 = '1'
$env:CLAUDEVOICE = 'off'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$latestFile = Join-Path $JudgeHome '.court\LATEST'
$previous = if (Test-Path -LiteralPath $latestFile) { [IO.File]::ReadAllText($latestFile).Trim() } else { '' }
New-Item -ItemType Directory -Force $JudgeLogDir | Out-Null
$logFile = Join-Path $JudgeLogDir ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
# Only the last 20 logs are kept.
Get-ChildItem -LiteralPath $JudgeLogDir -Filter *.log | Sort-Object Name -Descending | Select-Object -Skip 19 | Remove-Item -Force -ErrorAction SilentlyContinue

function Write-Log([string]$Text) { [IO.File]::AppendAllText($logFile, ((Get-Date).ToString('HH:mm:ss') + ' ' + $Text + "`r`n"), $Utf8NoBom) }

function Set-Status([string]$State, [string]$Message, [string]$Run = '') {
    Write-JsonFile $JudgeStatusFile ([ordered]@{ state = $State; message = $Message; run = $Run; previous = $previous; jury = $Jury; pid = $PID; log = $logFile; at = (Get-Date).ToString('o') })
}

# Two trials in one folder would both move .court\LATEST.
$mutex = New-Object System.Threading.Mutex($false, ('Local\ClaudeTrayJudge-' + ($JudgeHome.ToLowerInvariant() -replace '[^a-z0-9]', '_')))
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }
try {
    Set-Status 'running' ''
    Write-Log "Claude Judge: jury $Jury, model $Model, folder $JudgeHome"

    # ---- checks, before spending any of the plan
    if (Test-JudgeProtectedPath $JudgeHome) { throw "La carpeta de los juicios ($JudgeHome) est$(Tx '\u00e1') dentro de una carpeta protegida de Claude Code (.claude, .git...): Claude no puede escribir ah$(Tx '\u00ed')." }
    if (-not (Test-Path -LiteralPath $JudgeIdeaFile)) { throw 'No hay idea que juzgar (falta idea.txt).' }
    $idea = [IO.File]::ReadAllText($JudgeIdeaFile, [Text.Encoding]::UTF8).Trim()
    if (-not $idea) { throw "La idea est$(Tx '\u00e1') vac$(Tx '\u00ed')a." }
    Write-Log "idea: $($idea.Length) characters"
    $pythonVersion = try { (& $Python --version 2>&1 | Out-String).Trim() } catch { '' }
    if ($LASTEXITCODE -ne 0 -or -not $pythonVersion) { throw "Falta Python 3 (no funciona el comando $Python)." }
    Write-Log "python: $pythonVersion"
    $claude = Resolve-JudgeClaude $ClaudePath
    if (-not $claude) { throw "No encuentro Claude Code (claude.exe o claude.cmd). Rev$(Tx '\u00ed')salo con: claude --version" }
    Write-Log "claude: $claude"
    $probe = Join-Path $JudgeHome '.write-test'
    try { [IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force } catch { throw "No se puede escribir en $JudgeHome : $($_.Exception.Message)" }
    $source = Join-Path $TrayRoot "claudeJudge\.claude\skills\$JudgeSkillName"
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) { throw "Falta la skill de Claude Judge en $source. Vuelve a ejecutar install.ps1." }

    # The skill is loaded from the trial folder's .claude\skills (a fresh copy of the installed one each time).
    $skill = Join-Path $JudgeHome ".claude\skills\$JudgeSkillName"
    if (Test-Path -LiteralPath $skill) { Remove-Item -LiteralPath $skill -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path -Parent $skill) | Out-Null
    Copy-Item -LiteralPath $source -Destination $skill -Recurse

    # The case file is the idea exactly as written: left to Claude it may translate it (Haiku did, to English), and
    # every sub-agent answers in the case file's language.
    New-Item -ItemType Directory -Force (Join-Path $JudgeHome '.court') | Out-Null
    [IO.File]::WriteAllText((Join-Path $JudgeHome '.court\case.md'), $idea + "`n", $Utf8NoBom)

    # ---- the trial
    $prompt = "Use the court skill with --jury $Jury. The case file is already written at .court/case.md: it is the user's " +
        'own words, so skip step 2 (never rewrite, shorten or translate it) and start at step 3 with that file. This runs ' +
        'unattended: never ask the user anything, go straight through every phase to court.py render.'
    # --setting-sources project: not the user's settings, hooks or plugins (voice, advisor); the skill is a
    # project skill of this folder. acceptEdits lets the sub-agents write their files under .court.
    $arguments = ('-p "{0}" --model {1} --setting-sources project --permission-mode acceptEdits ' +
        '--allowedTools "Bash(python3:*)" --output-format json --no-session-persistence') -f $prompt, $Model
    Write-Log "command: `"$claude`" $arguments"
    $outFile = Join-Path $JudgeLogDir 'last-stdout.txt'
    $errFile = Join-Path $JudgeLogDir 'last-stderr.txt'
    $started = Get-Date
    # Files, not a pipe: PowerShell would decode Claude's UTF-8 with the console code page.
    $process = Start-Process -FilePath $claude -ArgumentList $arguments -WorkingDirectory $JudgeHome -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    [void]$process.Handle  # keeps the exit code readable after the process ends
    Write-Log "claude started (pid $($process.Id)), limit $TimeoutSeconds s"
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        Write-Log 'time limit reached: stopping claude and its sub-processes'
        & taskkill.exe /T /F /PID $process.Id *> $null
        $exitCode = -1
    } else { $exitCode = $process.ExitCode }
    $stdout = if (Test-Path -LiteralPath $outFile) { [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) } else { '' }
    $stderr = if (Test-Path -LiteralPath $errFile) { [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8) } else { '' }
    Write-Log ("claude ended: exit $exitCode after {0:N0} s" -f ((Get-Date) - $started).TotalSeconds)
    $answer = $null
    try { if ($stdout.Trim()) { $answer = $stdout | ConvertFrom-Json } } catch { Write-Log "stdout is not JSON: $($_.Exception.Message)" }
    if ($answer) {
        Write-Log ("answer: is_error={0} subtype={1} turns={2} cost_usd={3} denials={4}" -f $answer.is_error, $answer.subtype, $answer.num_turns, $answer.total_cost_usd, @($answer.permission_denials | Where-Object { $_ }).Count)
        foreach ($d in @($answer.permission_denials | Where-Object { $_ })) { Write-Log ('denied: ' + ($d | ConvertTo-Json -Compress -Depth 4)) }
        Write-Log ('result: ' + [string]$answer.result)
    } else { Write-Log ('stdout: ' + $stdout) }
    if ($stderr.Trim()) { Write-Log ('stderr: ' + $stderr.Trim()) }

    # ---- the verdict
    $latest = if (Test-Path -LiteralPath $latestFile) { [IO.File]::ReadAllText($latestFile).Trim() } else { '' }
    $run = if ($latest -and $latest -ne $previous) { Join-Path $JudgeHome $latest } else { '' }
    if ($run -and (Test-Path -LiteralPath $run)) {
        $files = @(Get-ChildItem -LiteralPath $run -Recurse -File | Where-Object { $_.DirectoryName -notlike '*\briefs' } | ForEach-Object { $_.FullName.Substring($run.Length + 1) })
        Write-Log ("trial folder $run`: " + ($files -join ', '))
        Write-Log ('progress: ' + (Get-JudgeProgress $run))
    } else { Write-Log 'no new trial folder in .court' }
    if ($run -and (Get-JudgeTrial $run).Done) {
        # The trial keeps the idea as the user wrote it: its title and the text to edit in "Rejuzgar con cambios".
        Copy-Item -LiteralPath $JudgeIdeaFile -Destination (Join-Path $run 'idea.txt') -Force
        Write-Log 'verdict ready'
        Set-Status 'done' 'Veredicto listo.' $run
    } else {
        throw (Get-JudgeFailure $answer $stderr $exitCode $timedOut ([int][Math]::Ceiling($TimeoutSeconds / 60)))
    }
} catch {
    $message = $_.Exception.Message
    Write-Log ('FAILED: ' + $message)
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
    Set-Status 'error' $message
} finally {
    $mutex.ReleaseMutex()
}
