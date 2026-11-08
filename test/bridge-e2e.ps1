# End-to-end check of Otros PCs on one machine: two fake PCs (A and B) with their own folders and ports on
# 127.0.0.1 pair over real UDP, B runs its sshd, and A logs in with every ssh client found (the portable one,
# Windows' own, and Git's, which Claude Code's Bash tool uses) through an Include of A's generated config.
# B's tray is simulated: requests are answered by this script. Not part of run-tests.ps1 (it needs the
# portable OpenSSH and opens local ports).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\bridge-e2e.ps1 [-SshDir <folder with sshd.exe>]
param([string]$SshDir)

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $Root 'lib\common.ps1')
. (Join-Path $Root 'lib\bridge.ps1')
. (Join-Path $Root 'lib\bridgenet.ps1')
if (-not $SshDir) { $SshDir = Join-Path $DefaultInstallDir 'ssh' }
if (-not (Test-Path -LiteralPath (Join-Path $SshDir 'sshd.exe'))) { throw "no sshd.exe in $SshDir (run install.ps1 or pass -SshDir)" }

$script:Failures = 0
function Check([bool]$Ok, [string]$Name, [string]$Detail = '') {
    if ($Ok) { Write-Host "ok   $Name" } else { $script:Failures++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('cmx-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# The gates refuse everyone unless the tray of their PC runs: this script plays that tray (tray.pid next to the
# fake PCs' folders names this PowerShell).
New-Item -ItemType Directory -Force -Path $work | Out-Null
[IO.File]::WriteAllText((Join-Path $work 'tray.pid'), [string]$PID)
$A = New-BridgeContext -DataDir (Join-Path $work 'A') -SshDir $SshDir -SshPort 41122 -UdpPort 41121 -ListenAddress 127.0.0.1 -AllowLoopback
$B = New-BridgeContext -DataDir (Join-Path $work 'B') -SshDir $SshDir -SshPort 41132 -UdpPort 41131 -ListenAddress 127.0.0.1 -AllowLoopback
$udpA = $null; $udpB = $null
try {
    # ---- identities, keys, pairing over UDP
    $infoA = Get-BridgeInfo (Get-BridgeIdentity $A) (Initialize-BridgeKeys $A); $infoA.name = 'PC-A'
    $infoB = Get-BridgeInfo (Get-BridgeIdentity $B) (Initialize-BridgeKeys $B); $infoB.name = 'PC-B'
    $udpA = Open-BridgeSocket $A.UdpPort
    $udpB = Open-BridgeSocket $B.UdpPort
    $initiator = New-PairInitiator $infoA '127.0.0.1' $B.UdpPort
    $responder = $null
    Send-BridgeDatagram $udpA $initiator.Out '127.0.0.1' $B.UdpPort
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not ($initiator.Stage -eq 'done' -and $responder -and $responder.Stage -eq 'done')) {
        foreach ($d in (Receive-BridgeDatagrams $udpB)) {
            if (-not $responder -and $d.Message.t -eq 'pair1') { $responder = New-PairResponder $infoB $d.Message $d.Address $d.Port }
            elseif ($responder) { Step-Pairing $responder $d.Message }
            if ($responder.Out) { Send-BridgeDatagram $udpB $responder.Out $d.Address $d.Port }
        }
        foreach ($d in (Receive-BridgeDatagrams $udpA)) {
            Step-Pairing $initiator $d.Message
            if ($initiator.Out) { Send-BridgeDatagram $udpA $initiator.Out $d.Address $d.Port }
        }
        # Both users read the same code and confirm.
        if ($initiator.Stage -eq 'confirm' -and -not $initiator.LocalOk) { Confirm-Pairing $initiator; Send-BridgeDatagram $udpA $initiator.Out '127.0.0.1' $B.UdpPort }
        if ($responder -and $responder.Stage -eq 'confirm' -and -not $responder.LocalOk) { Confirm-Pairing $responder; Send-BridgeDatagram $udpB $responder.Out '127.0.0.1' $A.UdpPort }
        Start-Sleep -Milliseconds 50
    }
    Check ($initiator.Stage -eq 'done' -and $responder.Stage -eq 'done') 'paired over UDP' "($($initiator.Stage)/$($responder.Stage))"
    Check ($initiator.Code -eq $responder.Code) "same code on both ($($initiator.Code))"

    $recordB = New-PeerRecord $initiator; $recordB.port = $B.SshPort
    $recordA = New-PeerRecord $responder; $recordA.port = $A.SshPort
    Write-BridgePeers $A @($recordB)
    Write-BridgePeers $B @($recordA)
    Update-BridgeFiles $A $null

    # ---- B's server
    $gateB = Import-BridgeGate $B
    $server = Start-BridgeServer $B $gateB
    Start-Sleep -Seconds 2
    Check (-not $server.HasExited) 'B server running' (Get-BridgeServerError $B)
    $alias = Get-PeerAlias $recordB @($recordB)
    $include = Join-Path $work 'user_config'
    [IO.File]::WriteAllText($include, "Include $(Format-SshClientPath $A.SshConfig)`n")

    # Runs a client and plays B's tray: every request gets $Answer.
    function Invoke-Client([string]$Exe, [string[]]$Arguments, [string]$Answer) {
        $out = Join-Path $work ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        $err = $out + '.err'
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle  # without it, ExitCode stays empty after the process exits
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
            foreach ($req in @(Get-ChildItem -LiteralPath $B.RequestsDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $answerFile = $req.FullName -replace '\.json$', '.answer'
                if (-not (Test-Path -LiteralPath $answerFile)) { [IO.File]::WriteAllText($answerFile, $Answer) }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        [pscustomobject]@{ Code = $p.ExitCode; Out = ([IO.File]::ReadAllText($out)).Trim(); Err = ([IO.File]::ReadAllText($err)).Trim() }
    }

    $clients = [ordered]@{ portable = Join-Path $SshDir 'ssh.exe'; windows = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe' }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    # git.exe is in <Git>\cmd or <Git>\mingw64\bin; its ssh is <Git>\usr\bin\ssh.exe.
    $dir = if ($git) { Split-Path $git.Source } else { $null }
    while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'usr\bin\ssh.exe'))) { $dir = Split-Path $dir }
    if ($dir) { $clients['git-bash'] = Join-Path $dir 'usr\bin\ssh.exe' }
    foreach ($name in @($clients.Keys)) {
        $exe = $clients[$name]
        if (-not (Test-Path -LiteralPath $exe)) { Write-Host "skip $name client (not found)"; continue }
        $config = if ($name -eq 'git-bash') { $include.Replace('\', '/') } else { $include }
        $r = Invoke-Client $exe @('-F', "`"$config`"", '-o', 'BatchMode=yes', $alias, 'echo e2e-%USERNAME%') 'allow'
        Check ($r.Code -eq 0 -and $r.Out -eq "e2e-$env:USERNAME") "$name client: command through the gate" "code $($r.Code) out [$($r.Out)] err [$($r.Err)]"
    }

    $r = Invoke-Client $clients.portable @('-F', "`"$include`"", '-o', 'BatchMode=yes', $alias, 'echo denied-run') 'deny'
    Check ($r.Code -ne 0 -and $r.Out -notmatch 'denied-run' -and $r.Err -match 'no permitio') 'denied connection runs nothing' "code $($r.Code) err [$($r.Err)]"

    # sftp both ways, binary intact.
    $payload = Join-Path $work 'payload.bin'
    [IO.File]::WriteAllBytes($payload, [byte[]](0..255 + 13, 10, 26, 0))
    $remote = (Join-Path $work 'remote.bin').Replace('\', '/')
    $back = Join-Path $work 'back.bin'
    $batch = Join-Path $work 'sftp.txt'
    [IO.File]::WriteAllText($batch, "put `"$($payload.Replace('\', '/'))`" `"$remote`"`nget `"$remote`" `"$($back.Replace('\', '/'))`"`n")
    $r = Invoke-Client (Join-Path $SshDir 'sftp.exe') @('-F', "`"$include`"", '-b', "`"$batch`"", $alias) 'allow'
    $same = (Test-Path -LiteralPath $back) -and ((Get-FileHash $payload).Hash -eq (Get-FileHash $back).Hash)
    Check ($r.Code -eq 0 -and $same) 'sftp put and get, bytes intact' "code $($r.Code) err [$($r.Err)]"

    # A wrong host key is refused (pinned under the alias), whatever address the beacons claim.
    $forged = Get-Content -LiteralPath $A.KnownHosts -Raw
    [IO.File]::WriteAllText($A.KnownHosts, ($forged -replace [regex]::Escape((Get-BridgeKeyText $infoB.hostKey)), (Get-BridgeKeyText $infoA.hostKey)))
    $r = Invoke-Client $clients.portable @('-F', "`"$include`"", '-o', 'BatchMode=yes', $alias, 'echo should-not') 'allow'
    Check ($r.Code -ne 0 -and $r.Err -match 'HOST IDENTIFICATION|host key') 'changed host key is refused' "code $($r.Code) err [$($r.Err)]"
    [IO.File]::WriteAllText($A.KnownHosts, $forged)

    # ---- debates (lib\debate.ps1): the gate's mailbox mode, then a whole debate between two workers on A and B
    . (Join-Path $Root 'lib\judge.ps1')
    . (Join-Path $Root 'lib\debate.ps1')
    $gateA = Import-BridgeGate $A
    $serverA = Start-BridgeServer $A $gateA
    Start-Sleep -Seconds 2
    Check (-not $serverA.HasExited) 'A server running' (Get-BridgeServerError $A)
    function Get-Base64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
    $post = Get-Base64 '{"debate":"x","name":"turn0","text":"hola"}'
    $sshTo = @('-n', '-F', "`"$include`"", '-o', 'BatchMode=yes', $alias)
    $fakeId = New-DebateId
    $r = Invoke-Client $clients.portable ($sshTo + "cmx-debate $fakeId turn0 $post") 'allow'
    Check ($r.Code -ne 0 -and $r.Err -match 'no hay un debate abierto' -and -not (Test-Path -LiteralPath (Join-Path $B.Home "debates\$fakeId"))) 'debate: a message for a debate B does not hold is refused' "code $($r.Code) err [$($r.Err)]"
    $r = Invoke-Client $clients.portable ($sshTo + "`"cmx-debate $fakeId turn0 $post & echo pwned`"") 'allow'
    Check ($r.Code -ne 0 -and $r.Out -notmatch 'pwned' -and $r.Err -match 'invalido') 'debate: a malformed debate command is refused, never run' "code $($r.Code) out [$($r.Out)] err [$($r.Err)]"
    $r = Invoke-Client $clients.portable ($sshTo + "cmx-debate $fakeId open $post") 'deny'
    Check ($r.Code -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $B.Home "debates\$fakeId"))) 'debate: a denied open leaves nothing' "code $($r.Code) err [$($r.Err)]"
    $r = Invoke-Client $clients.portable ($sshTo + "cmx-debate $fakeId open $(Get-Base64 ('x' * 17000))") 'allow'
    Check ($r.Code -ne 0 -and $r.Err -match '16 KB' -and -not (Test-Path -LiteralPath (Join-Path $B.Home "debates\$fakeId"))) 'debate: a message over 16 KB is refused before asking' "code $($r.Code) err [$($r.Err)]"

    # Plays B's tray: allows the debate's open and starts the guest worker with $GuestFolder ('' declines), like
    # Complete-DebateAccept. Returns once both sides stopped running.
    function Invoke-Debate([string]$GuestFolder) {
        $fake = '-ClaudePath "{0}" -WaitSeconds 60 -TurnTimeoutSeconds 60' -f (Join-Path $Root 'test\fakes\claude.cmd')
        $dirA = Join-Path (Get-DebateRoot $A) (New-DebateId)
        $env:FAKE_CLAUDE_MODE = 'debate'
        [void](Start-DebateWorker $A $dirA 'host' $recordB.id 'Redis o Postgres para la cola de notificaciones' $folderA $Root ($fake + ' -Me PC-A'))
        $kinds = @(); $dirB = $null; $request = $null; $sa = $null; $sb = $null
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            foreach ($req in @(Get-ChildItem -LiteralPath $B.RequestsDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $answerFile = $req.FullName -replace '\.json$', '.answer'
                if (Test-Path -LiteralPath $answerFile) { continue }
                $record = Read-JsonFile $req.FullName
                if (-not $record) { continue }
                $kinds += [string]$record.kind
                [IO.File]::WriteAllText($answerFile, 'allow')
                $request = [pscustomobject]@{ Command = [string]$record.command; Message = [string]$record.message }
            }
            if ($request -and -not $dirB) {
                $dirB = Join-Path (Get-DebateRoot $B) (Get-DebateIdFromCommand $request.Command)
                $openBy = (Get-Date).AddSeconds(10)
                while (-not (Test-Path -LiteralPath (Join-Path $dirB 'in\open.json')) -and (Get-Date) -lt $openBy) { Start-Sleep -Milliseconds 100 }
                [void](Start-DebateWorker $B $dirB 'guest' $recordA.id (Get-DebateTopic $request) $GuestFolder $Root ($fake + ' -Me PC-B'))
            }
            $sa = Get-DebateStatus $dirA
            $sb = if ($dirB) { Get-DebateStatus $dirB } else { $null }
            if ($sa -and $sb -and $sa.state -ne 'running' -and $sb.state -ne 'running') { break }
            Start-Sleep -Milliseconds 200
        }
        Remove-Item Env:FAKE_CLAUDE_MODE
        [pscustomobject]@{ A = $sa; B = $sb; DirA = $dirA; DirB = $dirB; Kinds = ($kinds -join ',') }
    }
    function Read-Utf8([string]$Path) { if ($Path -and (Test-Path -LiteralPath $Path)) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) } else { '' } }
    $folderA = Join-Path $work 'proyecto-a'; $folderB = Join-Path $work 'proyecto-b'
    New-Item -ItemType Directory -Force $folderA, $folderB | Out-Null
    $d = Invoke-Debate $folderB
    $logs = (Read-Utf8 (Join-Path $d.DirA 'debate.log')) + "`n" + $(if ($d.DirB) { Read-Utf8 (Join-Path $d.DirB 'debate.log') })
    Check ($d.Kinds -eq 'debate') 'debate: the open asks B once, as a debate' "[$($d.Kinds)]"
    Check ("$($d.A.state)/$($d.B.state)" -eq 'done/done') 'debate: both sides finish' "$($d.A.state): $($d.A.message) / $($d.B.state): $($d.B.message)`n$logs"
    $ta = Read-Utf8 (Join-Path $d.DirA 'transcript.md')
    $tb = if ($d.DirB) { Read-Utf8 (Join-Path $d.DirB 'transcript.md') } else { '' }
    $accent = 'acci' + [char]0x00F3 + 'n'
    Check ($ta.Contains('Ronda 3') -and $ta.Contains("Postura de proyecto-b con $accent") -and $ta.Contains('## Resultado')) 'debate: A has every round, the words of B (accents intact) and the result'
    Check ($tb.Contains("Postura de proyecto-a con $accent") -and $tb.Contains('Resultado de ')) 'debate: B has the words of A and the result of the moderator'
    $sent = @(foreach ($dir in @($d.DirA, $d.DirB | Where-Object { $_ })) { Get-ChildItem -LiteralPath (Join-Path $dir 'in') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllText($_.FullName) } })
    Check ($sent.Count -eq 8 -and -not ($sent -match 'sk-fake') -and $ta.Contains('[oculto]')) 'debate: 8 messages crossed and no key left either PC' "$($sent.Count) messages"
    $prompts = @((Read-Utf8 (Join-Path $folderA 'fake-claude-prompts.txt')) -split '=====')
    Check ($prompts.Count -ge 3 -and -not $prompts[0].Contains('<debate_history>') -and $prompts[1].Contains('Postura de proyecto-b')) 'debate: the first round is blind, the next ones see the other side'
    $turnArgs = Read-Utf8 (Join-Path $folderA 'fake-claude-called.txt')
    $modArgs = Read-Utf8 (Join-Path $d.DirA 'fake-claude-called.txt')
    Check ($turnArgs.Contains('--restricted') -and $turnArgs.Contains('--strict-mcp-config') -and $turnArgs.Contains('Read,Glob,Grep') -and $modArgs.Contains('--restricted') -and -not $modArgs.Contains('Read,Glob')) 'debate: turns read only, the moderator gets no tools' "turn [$turnArgs] moderator [$modArgs]"
    $r = Invoke-Client $clients.portable ($sshTo + "cmx-debate $(if ($d.DirB) { Split-Path -Leaf $d.DirB } else { $fakeId }) close $post") 'allow'
    Check ($r.Code -ne 0 -and $r.Err -match 'no hay un debate abierto') 'debate: a finished debate takes nothing more' "code $($r.Code) err [$($r.Err)]"

    $d = Invoke-Debate ''
    Check ($d.A.state -eq 'error' -and $d.A.message -like '*no acept*' -and $d.B.state -eq 'error') 'debate: when B declines, A stops and says so' "$($d.A.state): $($d.A.message)"

    Check (@(Get-ChildItem -LiteralPath $B.SessionsDir -File).Count -eq 0) 'no session records left behind'
} finally {
    if ($udpA) { $udpA.Close() }
    if ($udpB) { $udpB.Close() }
    $stopped = Stop-BridgeServer $B
    [void](Stop-BridgeServer $A)
    Start-Sleep -Milliseconds 500
    $left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$work*" })
    Check ($left.Count -eq 0) 'stopping the server leaves no process behind' (($left | ForEach-Object { $_.Name }) -join ',')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) { Write-Host "$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all end-to-end checks passed' -ForegroundColor Green
