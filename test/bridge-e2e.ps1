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

    Check (@(Get-ChildItem -LiteralPath $B.SessionsDir -File).Count -eq 0) 'no session records left behind'
} finally {
    if ($udpA) { $udpA.Close() }
    if ($udpB) { $udpB.Close() }
    $stopped = Stop-BridgeServer $B
    Start-Sleep -Milliseconds 500
    $left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$work*" })
    Check ($left.Count -eq 0) 'stopping the server leaves no process behind' (($left | ForEach-Object { $_.Name }) -join ',')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) { Write-Host "$script:Failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all end-to-end checks passed' -ForegroundColor Green
