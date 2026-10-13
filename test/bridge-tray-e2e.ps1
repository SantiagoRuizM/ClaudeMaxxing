# End-to-end check of the tray side of Otros PCs (lib\bridgeui.ps1) on one machine: two fake PCs on 127.0.0.1
# discover each other, pair through the tray functions, B's tray starts its server, A connects, B's approval
# dialog appears and is answered, the 1-hour grant and session tracking work, and forgetting A stops it all.
# Not part of run-tests.ps1 (needs the portable OpenSSH, opens local ports and a window).
# Run: powershell -NoProfile -STA -ExecutionPolicy Bypass -File test\bridge-tray-e2e.ps1 [-SshDir <folder with sshd.exe>]
param([string]$SshDir)
$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. "$TrayRoot\lib\common.ps1"
. "$TrayRoot\lib\bridge.ps1"
. "$TrayRoot\lib\bridgenet.ps1"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. "$TrayRoot\lib\theme.ps1"
. "$TrayRoot\lib\bridgeui.ps1"
$script:Palette = Get-ClaudePalette $false
$script:Notify = $null
$fail = 0
if (-not $SshDir) { $SshDir = Join-Path $DefaultInstallDir 'ssh' }
if (-not (Test-Path -LiteralPath (Join-Path $SshDir 'sshd.exe'))) { throw "no sshd.exe in $SshDir (run install.ps1 or pass -SshDir)" }
function Check([bool]$Ok, [string]$Name, [string]$Detail = '') { if ($Ok) { "ok   $Name" } else { $script:fail++; "FAIL $Name $Detail" } }

$work = Join-Path $env:TEMP ('cmx-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
# The gates refuse everyone unless the tray of their PC runs: this script plays that tray (tray.pid next to the
# fake PCs' folders names this PowerShell).
New-Item -ItemType Directory -Force -Path $work | Out-Null
[IO.File]::WriteAllText((Join-Path $work 'tray.pid'), [string]$PID)
function New-Pc([string]$Name, [int]$Ssh, [int]$Udp) {
    $b = New-BridgeState $SshDir
    $b.Ctx = New-BridgeContext -DataDir (Join-Path $work $Name) -SshDir $SshDir -SshPort $Ssh -UdpPort $Udp -ListenAddress 127.0.0.1 -AllowLoopback
    $b.Identity = Get-BridgeIdentity $b.Ctx
    $b.Identity.name = $Name
    $b.Keys = Initialize-BridgeKeys $b.Ctx
    $b.Gate = Import-BridgeGate $b.Ctx
    $b.Settings = Read-BridgeSettings $b.Ctx
    $b.Peers = @()
    Update-BridgeFiles $b.Ctx $b.Gate
    $b.Ready = $true; $b.FirewallOk = $true
    $b.Udp = Open-BridgeSocket $Udp
    $b.Networks = @([pscustomobject]@{ Name = 'loopback'; Address = '127.0.0.1'; Prefix = 8; Broadcast = '127.0.0.1' })
    $b.NetworksAt = Get-Date
    $b
}
$A = New-Pc 'PC-A' 41222 41221
$B = New-Pc 'PC-B' 41232 41231
function As($Pc, [scriptblock]$Do) { $script:Bridge = $Pc; & $Do }
function Tick-Both { foreach ($pc in $A, $B) { $script:Bridge = $pc; Receive-BridgeMessages; Update-PairingProgress; Update-BridgeRequests; Update-BridgeSessions } }

try {
    # discovery: both windows open; A probes B's port
    $A.PairingMode = $true; $B.PairingMode = $true
    $A.PairingModeAt = Get-Date; $B.PairingModeAt = (Get-Date).AddMinutes(-11)
    As $A { Send-BridgeHello -Probe -To '127.0.0.1' -Port 41231 }
    for ($i = 0; $i -lt 20; $i++) { Tick-Both; Start-Sleep -Milliseconds 50 }
    Check ($A.Discovered.ContainsKey($B.Identity.id)) 'A discovered B through a probe'
    Check ($B.Discovered.ContainsKey($A.Identity.id)) 'B learned about A from its hello'

    # B's window has been open for 11 minutes: it no longer answers pairing requests.
    As $A { Start-BridgePairing $B.Identity.id }
    for ($i = 0; $i -lt 20; $i++) { Tick-Both; Start-Sleep -Milliseconds 50 }
    Check (-not $B.Pairing) 'a window open for too long ignores pairing requests'
    As $A { Stop-BridgePairing }
    $B.PairingModeAt = Get-Date
    As $A { Start-BridgePairing $B.Identity.id }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Tick-Both
        if ($A.Pairing.Stage -eq 'confirm' -and $B.Pairing -and $B.Pairing.Stage -eq 'confirm') { break }
        Start-Sleep -Milliseconds 50
    }
    Check ($A.Pairing.Code -and $A.Pairing.Code -eq $B.Pairing.Code) "codes match ($($A.Pairing.Code) / $($B.Pairing.Code))"
    As $A { Confirm-BridgePairing }
    As $B { Confirm-BridgePairing }
    for ($i = 0; $i -lt 40 -and -not ($A.Pairing.Stage -eq 'done' -and $B.Pairing.Stage -eq 'done'); $i++) { Tick-Both; Start-Sleep -Milliseconds 50 }
    Check ($A.Peers.Count -eq 1 -and $B.Peers.Count -eq 1) 'both saved the other' "($($A.Peers.Count)/$($B.Peers.Count))"
    # the loopback test needs each side to reach the other's own ssh port
    Check ($A.Peers[0].port -eq 41232) "A knows B's ssh port ($($A.Peers[0].port))"

    As $B { Update-BridgeServer }
    Start-Sleep -Seconds 2
    Check ($B.Server -and -not $B.Server.HasExited) 'B server started by the tray logic' (Get-BridgeServerError $B.Ctx)

    $alias = Get-PeerAlias $A.Peers[0] $A.Peers
    # Two requests at once (one harmless, one not): Permitir lets in only the one on screen.
    $sshExe = Join-Path $SshDir 'ssh.exe'
    $twoOut = Join-Path $work 'two'
    $p1 = Start-Process -FilePath $sshExe -ArgumentList @('-F', "`"$($A.Ctx.SshConfig)`"", '-o', 'BatchMode=yes', $alias, 'echo first') -NoNewWindow -PassThru -RedirectStandardOutput "$twoOut.1" -RedirectStandardError "$twoOut.1e"
    $p2 = Start-Process -FilePath $sshExe -ArgumentList @('-F', "`"$($A.Ctx.SshConfig)`"", '-o', 'BatchMode=yes', $alias, 'echo second') -NoNewWindow -PassThru -RedirectStandardOutput "$twoOut.2" -RedirectStandardError "$twoOut.2e"
    $null = $p1.Handle; $null = $p2.Handle
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and $B.Requests.Count -lt 2) { As $B { Update-BridgeRequests }; Start-Sleep -Milliseconds 100 }
    Check ($B.Requests.Count -eq 2) 'both requests wait'
    $shown = As $B { Get-ApprovalRequest }
    As $B { Send-BridgeAnswer $shown.Id 'allow'; Update-BridgeRequests }
    Check ($B.Requests.Count -eq 1) 'Permitir answers only the request on screen'
    Check ([bool]$script:ApprovalForm) 'the other request keeps the dialog open'
    $other = As $B { Get-ApprovalRequest }
    As $B { Send-BridgeAnswer $other.Id 'deny'; Update-BridgeRequests }
    $p1.WaitForExit(15000) | Out-Null; $p2.WaitForExit(15000) | Out-Null
    $ran = @("$twoOut.1", "$twoOut.2" | ForEach-Object { (Get-Content $_ -Raw) } | Where-Object { $_ -and $_.Trim() })
    Check ($ran.Count -eq 1 -and $ran[0].Trim() -eq $shown.Command.Replace('echo ', '')) "only the allowed command ran ($($ran -join '|'))"
    Check (-not $script:ApprovalForm) 'dialog closes when nothing is left'

    $ssh = Join-Path $SshDir 'ssh.exe'
    $out = Join-Path $work 'out.txt'
    $p = Start-Process -FilePath $ssh -ArgumentList @('-F', "`"$($A.Ctx.SshConfig)`"", '-o', 'BatchMode=yes', $alias, 'echo smoke-ok') -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and $B.Requests.Count -eq 0) { As $B { Update-BridgeRequests }; Start-Sleep -Milliseconds 100 }
    Check ($B.Requests.Count -eq 1) 'B sees the request'
    Check ([bool]$script:ApprovalForm) 'B shows the approval dialog'
    $req = @($B.Requests.Values)[0]
    Check ($req.Peer.name -eq 'PC-A' -and $req.Command -eq 'echo smoke-ok') "request names PC-A and the command ($($req.Peer.name): $($req.Command))"
    As $B { Send-BridgeAnswer $req.Id 'allow' -ForAnHour; Update-BridgeRequests }
    Check (-not $script:ApprovalForm) 'dialog closes once answered'
    $p.WaitForExit(15000) | Out-Null
    Check ($p.ExitCode -eq 0 -and (Get-Content $out -Raw).Trim() -eq 'smoke-ok') 'command ran on B' ("code $($p.ExitCode) " + (Get-Content "$out.err" -Raw))
    Check ((Read-BridgeGrants $B.Ctx).ContainsKey($A.Identity.id)) '1 hour grant written'

    # with the grant, a terminal-like long session is let in directly and tracked
    $p2 = Start-Process -FilePath $ssh -ArgumentList @('-F', "`"$($A.Ctx.SshConfig)`"", '-o', 'BatchMode=yes', $alias, 'ping -n 4 127.0.0.1 >nul & echo done') -NoNewWindow -PassThru -RedirectStandardOutput "$out.2" -RedirectStandardError "$out.2.err"
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and $B.Sessions.Count -eq 0) { As $B { Update-BridgeSessions }; Start-Sleep -Milliseconds 100 }
    Check ($B.Sessions.Count -eq 1) 'session tracked while it runs'
    Check ($B.Requests.Count -eq 0) 'no request with an active grant'
    $p2.WaitForExit(15000) | Out-Null
    Start-Sleep -Milliseconds 300
    As $B { Update-BridgeSessions }
    Check ($B.Sessions.Count -eq 0) 'session gone after it ends'

    # A key added to authorized_keys outside the tray (as an allowed session could do) is gone at the next check.
    Add-Content -LiteralPath $B.Ctx.AuthorizedKeys -Value "$($A.Keys.hostKey) rogue"
    As $B { Repair-BridgeTampering }
    Check (-not (Get-Content -LiteralPath $B.Ctx.AuthorizedKeys -Raw).Contains('rogue')) 'a key added outside the tray is removed'
    Check ((Get-Content -LiteralPath $B.Ctx.Log -Raw) -match 'restored after an outside change: authorized_keys') 'and the change is logged'

    # forgetting A on B removes its key: A can no longer log in
    As $B { Remove-BridgePeer $A.Identity.id }
    Check (-not ((Get-Content $B.Ctx.AuthorizedKeys -Raw) -match 'cmx-' + $A.Identity.id)) 'forgotten PC leaves authorized_keys'
    Start-Sleep -Milliseconds 500
    Check (-not (Get-BridgeServerProcess $B.Ctx)) 'server stops with no paired PCs left'
} finally {
    foreach ($pc in $A, $B) { $script:Bridge = $pc; Stop-BridgeTray }
    if ($script:ApprovalForm) { $script:ApprovalForm.Close() }
    Start-Sleep -Milliseconds 500
    $left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$work*" })
    Check ($left.Count -eq 0) 'no processes left' (($left | ForEach-Object Name) -join ',')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all tray end-to-end checks passed' -ForegroundColor Green
