# End-to-end check of Claude Judge ("Planear sesion del dia") with the real claude and python: one small trial,
# run by the worker exactly as the window starts it. Uses the Claude plan (Haiku, 3 jurors: about 8 calls and
# 5-10 minutes), so it is not in the CI; test\run-tests.ps1 covers the worker with a fake claude.
# It runs next to the real trials folder (%LOCALAPPDATA%), not in %TEMP%, so a folder Claude Code refuses to write
# to fails here too.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\judge-e2e.ps1 [-Installed] [-Model sonnet] [-Jury 6] [-Keep]
# -Installed runs the installed copy (%LOCALAPPDATA%\ClaudeMaxxing) instead of this repo. -Keep leaves the folder
# (a failed run always keeps it, with its log).
# Keep this file ASCII.
param([switch]$Installed, [string]$Model = 'haiku', [int]$Jury = 3, [switch]$Keep)

$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $Repo 'lib\common.ps1')
$Root = if ($Installed) { $DefaultInstallDir } else { $Repo }
. (Join-Path $Root 'lib\judge.ps1')
$worker = Join-Path $Root 'lib\judge-worker.ps1'
$dir = Join-Path (Split-Path -Parent $JudgeHome) 'ClaudeJudge-e2e'
$failures = 0
function Check([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:failures++ }
}

Write-Host "worker: $worker"
Write-Host "folder: $dir"
Check (Test-Path -LiteralPath $worker) 'worker exists'
Check (-not (Test-JudgeProtectedPath $JudgeHome)) "trials folder is writable by Claude Code ($JudgeHome)"
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $dir | Out-Null
$idea = 'Dedicar las ma' + [char]0x00F1 + 'anas a grabar un curso de Claude Code en espa' + [char]0x00F1 + 'ol y venderlo a 20 USD. Tengo 800 seguidores y 3 horas al d' + [char]0x00ED + 'a.'
[IO.File]::WriteAllText((Join-Path $dir 'idea.txt'), $idea, (New-Object System.Text.UTF8Encoding($false)))

$started = Get-Date
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -WorkDir $dir -Jury $Jury -Model $Model
$minutes = ((Get-Date) - $started).TotalMinutes
$status = Read-JsonFile (Join-Path $dir 'status.json')
Write-Host ("finished in {0:N1} min: {1} {2}" -f $minutes, $status.state, $status.message)
Write-Host "log: $($status.log)"
Check ($status.state -eq 'done') 'the trial ends with a verdict'
if ($status.state -eq 'done') {
    $trial = Get-JudgeTrial $status.run
    Check ($trial.Title -eq $idea) 'the trial keeps the idea as written (idea.txt)'
    Check ($trial.Tally.verdict -in 'GUILTY', 'NOT GUILTY', 'HUNG JURY') "verdict: $(Format-JudgeScore $trial.Tally)"
    Check (@($trial.Tally.jurors | Where-Object { $_.vote -ne 'NO VOTE' }).Count -eq $Jury) "all $Jury jurors voted"
    # Spanish answers: common Spanish words in every statement, vote reason and the judgment.
    $texts = @(Get-ChildItem -LiteralPath $status.run -Recurse -Filter *.md | Where-Object { $_.DirectoryName -match '\\(opening|rebuttal|judge)$' } |
        ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) + @($trial.Tally.jurors | ForEach-Object { [string]$_.reason })
    $english = @($texts | Where-Object { $_ -notmatch '\b(que|los|las|del|para|una|sin)\b' })
    Check ($english.Count -eq 0) "every answer is in Spanish ($($english.Count) of $($texts.Count) look English)"
    Check ((Format-JudgeFeedback $trial).Length -gt 200) 'the feedback for the window builds'
}
# A failed run keeps its folder: the log is in it.
if (-not $Keep -and -not $failures) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "kept: $dir" }
if ($failures) { Write-Host "$failures checks failed (see the log above)" -ForegroundColor Red; exit 1 }
Write-Host 'Claude Judge works end to end' -ForegroundColor Green
