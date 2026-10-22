# Stand-in for `claude -p` in the Claude Judge worker tests (test\run-tests.ps1): costs nothing and needs no
# network. $env:FAKE_CLAUDE_MODE picks what a real run could leave behind:
#   verdict  a finished trial in .court and a success answer (with an accented word, to check UTF-8 decoding)
#   deny     the answer of a run whose writes were refused (what happens under ~/.claude)
#   error    an is_error answer (max turns)
#   crash    no answer, a message on stderr and exit code 3
#   hang     never answers (the worker must stop it at its time limit)
# Every call leaves fake-claude-called.txt with its arguments in the current folder. Keep this file ASCII.
[IO.File]::WriteAllText((Join-Path (Get-Location) 'fake-claude-called.txt'), ($args -join ' '))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$out = [Console]::OpenStandardOutput()
function Send([string]$Json) { $bytes = $utf8.GetBytes($Json); $out.Write($bytes, 0, $bytes.Length); $out.Flush() }
$o = [char]0x00F3

switch ($env:FAKE_CLAUDE_MODE) {
    'verdict' {
        $run = Join-Path '.court' '20261020-090000'
        foreach ($d in 'opening', 'rebuttal', 'jury', 'judge') { New-Item -ItemType Directory -Force (Join-Path $run $d) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $run 'case.md'), "# El caso`nVender velas en Etsy.")
        [IO.File]::WriteAllText((Join-Path $run 'state.json'), '{"jury":[{"name":"The Accountant"}]}')
        foreach ($f in 'opening\prosecution', 'opening\defense', 'rebuttal\prosecution', 'rebuttal\defense') { [IO.File]::WriteAllText((Join-Path $run "$f.md"), 'x') }
        [IO.File]::WriteAllText((Join-Path $run 'jury\juror-01.md'), "VOTE: GUILTY`nREASON: No hay margen.")
        [IO.File]::WriteAllText((Join-Path $run 'tally.json'), '{"verdict":"GUILTY","guilty":1,"not_guilty":0,"jurors":[{"juror":"The Accountant","vote":"GUILTY","reason":"No hay margen.","flip":""}]}')
        [IO.File]::WriteAllText((Join-Path $run 'judge\judge.md'), '## Charges that stuck')
        [IO.File]::WriteAllText((Join-Path '.court' 'LATEST'), $run)
        Send ('{"type":"result","subtype":"success","is_error":false,"num_turns":9,"total_cost_usd":0.4,"result":"Veredicto listo en la sesi' + $o + 'n.","permission_denials":[]}')
    }
    'deny' {
        $path = (Join-Path (Get-Location) '.court\20261020-090000\case.md') -replace '\\', '\\'
        Send ('{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.1,"result":"No puedo escribir ning' + [char]0x00FA + 'n archivo.","permission_denials":[' +
            '{"tool_name":"Write","tool_use_id":"t1","tool_input":{"file_path":"' + $path + '","content":"x"}},' +
            '{"tool_name":"Write","tool_use_id":"t2","tool_input":{"file_path":"probe.txt","content":"x"}}]}')
    }
    'error' { Send '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":50,"result":"Reached the maximum number of turns","permission_denials":[]}' }
    'crash' { [Console]::Error.WriteLine('boom: the fake claude crashed'); exit 3 }
    'hang'  { Start-Sleep -Seconds 60 }
}
exit 0
