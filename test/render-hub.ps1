# Draws every section of the ClaudeMaxxing window (and the other windows) with their sample data, as the previews do,
# and fails when one does not draw: a paint error is caught and written at the bottom of the window, so without this
# a broken section never fails CI.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\render-hub.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tray = Join-Path $root 'tray.ps1'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$out = Join-Path ([IO.Path]::GetTempPath()) ('cmx-render-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $out | Out-Null

$sections = @('home', 'home-business', 'business', 'plan', 'plan-running', 'plan-error', 'plan-empty', 'envs', 'envs-busy',
    'envs-error', 'envs-none', 'envs-empty', 'envs-lists', 'self', 'usage', 'stats', 'stats-usage', 'stats-hours', 'stats-projects', 'stats-models-all',
    'code', 'code-help', 'whip', 'skills', 'skills-mcp', 'pcs', 'whisper', 'mobile', 'voice', 'home-full', 'stats-full')
$jobs = @(foreach ($s in $sections) { @{ Name = "hub $s"; Args = @('-RenderHubTo', (Join-Path $out "hub-$s.png"), '-HubSection', $s); Png = (Join-Path $out "hub-$s.png") } })
$jobs += @{ Name = 'popup'; Args = @('-RenderTo', (Join-Path $out 'popup.png')); Png = (Join-Path $out 'popup.png') }
$jobs += @{ Name = 'Otros PCs'; Args = @('-RenderBridgeTo', (Join-Path $out 'bridge.png')); Png = (Join-Path $out 'bridge.png') }
$jobs += @{ Name = 'approval'; Args = @('-RenderApprovalTo', (Join-Path $out 'approval.png')); Png = (Join-Path $out 'approval.png') }

$failed = 0
try {
    foreach ($job in $jobs) {
        $err = Join-Path $out 'stderr.txt'
        $p = Start-Process -FilePath $powershell -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$tray`"") + $job.Args) `
            -NoNewWindow -PassThru -Wait -RedirectStandardError $err -RedirectStandardOutput (Join-Path $out 'stdout.txt')
        $stderr = if (Test-Path $err) { ([IO.File]::ReadAllText($err)).Trim() } else { '' }
        $ok = $p.ExitCode -eq 0 -and (Test-Path $job.Png) -and (Get-Item $job.Png).Length -gt 1000 -and $stderr -notmatch 'paint'
        if ($ok) { "ok   render: $($job.Name)" } else { "FAIL render: $($job.Name) (exit $($p.ExitCode)) $stderr"; $failed++ }
    }
} finally {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
''
if ($failed) { "$failed of $($jobs.Count) renders failed"; exit 1 }
"all $($jobs.Count) renders drew"
