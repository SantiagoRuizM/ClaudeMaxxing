# One side of a debate (lib\debate.ps1), started hidden by the tray: the host opens it on the other PC, both write
# turn0 blind and then reply, and the host's moderator writes the result. Each turn is a claude -p on this PC that
# can only read the folder its person picked. Reports in <debate>\status.json, writes <debate>\transcript.md (what
# lib\debate-view.ps1 shows) and a log in <debate>\debate.log.
# For tests: -ClaudePath uses a fake, -Me names this side (two fake PCs share one computer name), -WaitSeconds and
# -TurnTimeoutSeconds shorten the limits.
param([Parameter(Mandatory = $true)][string]$Dir, [string]$BridgeDir, [string]$SshDir, [string]$Model = 'sonnet',
    [string]$ClaudePath, [string]$Me = $env:COMPUTERNAME, [int]$TurnTimeoutSeconds = 600, [int]$WaitSeconds = 1200)

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\bridge.ps1')
. (Join-Path $TrayRoot 'lib\judge.ps1')
. (Join-Path $TrayRoot 'lib\debate.ps1')
Clear-ClaudeSessionEnv
$env:CLAUDEVOICE = 'off'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ctxArgs = @{}
if ($BridgeDir) { $ctxArgs.DataDir = $BridgeDir }
if ($SshDir) { $ctxArgs.SshDir = $SshDir }
$Ctx = New-BridgeContext @ctxArgs
$id = Split-Path -Leaf $Dir
$info = Read-DebateInfo $Dir
$logFile = Join-Path $Dir 'debate.log'
$transcript = Join-Path $Dir 'transcript.md'
$peerName = 'el otro PC'
$topic = ''
# Whether the other PC holds this debate (so a close can reach it) and whether it already ended it.
$script:Opened = $false
$script:PeerClosed = $false
$script:Calls = 0

function Write-Log([string]$Text) { [IO.File]::AppendAllText($logFile, ((Get-Date).ToString('HH:mm:ss') + ' ' + $Text + "`r`n"), $Utf8NoBom) }
function Add-Transcript([string]$Text) { [IO.File]::AppendAllText($transcript, $Text + "`r`n`r`n", $Utf8NoBom) }
function Set-Status([string]$State, [string]$Message) {
    Write-JsonFile (Join-Path $Dir 'status.json') ([ordered]@{ state = $State; message = $Message; pid = $PID; role = [string]$info.role; peer = $peerName; topic = $topic; at = (Get-Date).ToString('o') })
}

# Waits for in\<name>.json from the other PC (the gate moves it in whole). A close from them ends this side too.
function Wait-DebateMessage([string]$Name) {
    $inbox = Join-Path $Dir 'in'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $closeFile = Join-Path $inbox 'close.json'
        if (Test-Path -LiteralPath $closeFile) {
            $script:PeerClosed = $true
            $why = (Read-DebateMessage $closeFile $id).Text
            throw ("$peerName cerr" + (Tx '\u00f3') + " el debate: $why")
        }
        $file = Join-Path $inbox "$Name.json"
        if (Test-Path -LiteralPath $file) {
            $m = Read-DebateMessage $file $id
            if (-not $m) { throw ("Lleg" + (Tx '\u00f3') + " un mensaje ilegible de $peerName ($Name).") }
            Write-Log "received $Name ($($m.Text.Length) characters)"
            return $m
        }
        Start-Sleep -Milliseconds 500
    }
    throw ("$peerName no respondi" + (Tx '\u00f3') + " en $([int]($WaitSeconds / 60)) min.")
}

function Send-Debate([string]$Name, [string]$Text, [hashtable]$Extra) {
    $r = Send-DebateMessage $Ctx $script:Peer $Dir $Name (New-DebateMessage $id $Name $Me $Text $Extra)
    Write-Log "sent $Name`: $(if ($r.Ok) { 'ok' } else { $r.Error })"
    $r
}

# One claude -p: the prompt goes in on stdin from a file (UTF-8; a command line would mangle it). Returns its text.
function Invoke-DebateClaude([string]$Prompt, [string]$WorkDir, [switch]$Moderator) {
    $script:Calls++
    $base = Join-Path $Dir ('call-{0}' -f $script:Calls)
    [IO.File]::WriteAllText("$base.prompt.txt", $Prompt, $Utf8NoBom)
    $arguments = Get-DebateClaudeArguments $Model -Moderator:$Moderator
    Write-Log "claude: `"$script:Claude`" $arguments (in $WorkDir)"
    $process = Start-Process -FilePath $script:Claude -ArgumentList $arguments -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
        -RedirectStandardInput "$base.prompt.txt" -RedirectStandardOutput "$base.out.json" -RedirectStandardError "$base.err.txt"
    [void]$process.Handle
    $timedOut = -not $process.WaitForExit($TurnTimeoutSeconds * 1000)
    if ($timedOut) { & taskkill.exe /T /F /PID $process.Id *> $null; $exitCode = -1 } else { $exitCode = $process.ExitCode }
    $stdout = Read-SharedText "$base.out.json"
    $stderr = Read-SharedText "$base.err.txt"
    $answer = $null
    try { if ($stdout.Trim()) { $answer = $stdout | ConvertFrom-Json } } catch { Write-Log "stdout is not JSON: $($_.Exception.Message)" }
    if ($answer) {
        Write-Log ("answer: is_error={0} turns={1} cost_usd={2} denials={3}" -f $answer.is_error, $answer.num_turns, $answer.total_cost_usd, @($answer.permission_denials | Where-Object { $_ }).Count)
        foreach ($d in @($answer.permission_denials | Where-Object { $_ })) { Write-Log ('denied: ' + ($d | ConvertTo-Json -Compress -Depth 4)) }
    }
    if ($stderr.Trim()) { Write-Log ('stderr: ' + $stderr.Trim()) }
    $text = if ($answer -and -not $answer.is_error) { ([string]$answer.result).Trim() } else { '' }
    # A denied read is fine (the .env rule, a file outside the folder): only an empty answer is a failure.
    if (-not $text) { throw (Get-JudgeFailure ([pscustomobject]@{ is_error = $true; subtype = [string]$answer.subtype; result = [string]$answer.result }) $stderr $exitCode $timedOut ([int][Math]::Ceiling($TurnTimeoutSeconds / 60))) }
    $text
}

function Get-RoundTitle([int]$Turn) {
    switch ($Turn) {
        0 { 'Ronda 1: postura inicial (a ciegas)' }
        { $_ -eq $DebateTurns - 1 } { "Ronda $($Turn + 1): r" + (Tx '\u00e9') + 'plica final' }
        default { "Ronda $($Turn + 1): r" + (Tx '\u00e9') + 'plica' }
    }
}

try {
    if (-not $info -or -not (Test-DebateId $id)) { throw 'Falta debate.json.' }
    $script:Peer = Read-BridgePeers $Ctx | Where-Object { $_.id -eq $info.peer } | Select-Object -First 1
    if (-not $script:Peer) { throw ('Ese PC ya no est' + (Tx '\u00e1') + ' emparejado.') }
    $peerName = [string]$script:Peer.name
    $folder = [string]$info.folder
    Write-Log "debate $id, $($info.role) with $peerName, model $Model, folder [$folder]"
    Set-Status 'running' 'Preparando...'

    if ($info.role -eq 'guest') {
        # The gate stored the host's open just before the tray started this worker.
        $script:Opened = $true
        $topic = (Wait-DebateMessage 'open').Topic
        if (-not $folder) {
            Send-Debate 'close' ('no acept' + (Tx '\u00f3') + ' el debate') | Out-Null
            $script:PeerClosed = $true
            throw 'Rechazaste el debate.'
        }
    } else {
        $topic = [string]$info.topic
        Set-Status 'running' "Esperando que $peerName acepte el debate..."
        $r = Send-Debate 'open' '' @{ topic = $topic; turns = $DebateTurns }
        if (-not $r.Ok) { throw ("$peerName no abri" + (Tx '\u00f3') + " el debate: $($r.Error)") }
        $script:Opened = $true
    }
    if (-not $topic) { throw 'El debate no tiene tema.' }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "La carpeta $folder no existe." }
    if (Test-DebateFolderTooBroad $folder) { throw ("La carpeta $folder es demasiado amplia: elige la de un proyecto.") }
    $script:Claude = Resolve-JudgeClaude $ClaudePath
    if (-not $script:Claude) { throw ("No encuentro Claude Code (claude.exe o claude.cmd). Rev" + (Tx '\u00ed') + 'salo con: claude --version') }

    Add-Transcript "# Debate: $topic"
    Add-Transcript ("$Me y $peerName " + (Tx '\u00b7') + ' ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' ' + (Tx '\u00b7') + (Tx ' cada Claude ley\u00f3 solo la carpeta de su persona'))

    $history = New-Object System.Collections.Generic.List[object]
    for ($turn = 0; $turn -lt $DebateTurns; $turn++) {
        $title = Get-RoundTitle $turn
        Set-Status 'running' "$title`: tu Claude escribe..."
        $mine = Invoke-DebateClaude (Format-DebateTurnPrompt $topic $Me $peerName $turn $history.ToArray()) $folder
        $clean = Remove-DebateSecrets $mine
        $r = Send-Debate "turn$turn" $clean.Text
        if (-not $r.Ok) { throw "No se pudo enviar la ronda a $peerName`: $($r.Error)" }
        $note = if ($clean.Count) { "`r`n`r`n_(Se ocultaron $($clean.Count) posibles secretos antes de enviarlo.)_" } else { '' }
        Add-Transcript ("## $title " + (Tx '\u00b7') + " $Me`r`n`r`n" + $clean.Text + $note)
        Set-Status 'running' "$title`: esperando a $peerName..."
        $theirs = Wait-DebateMessage "turn$turn"
        Add-Transcript ("## $title " + (Tx '\u00b7') + " $peerName`r`n`r`n" + $theirs.Text)
        $history.Add([pscustomobject]@{ Author = $Me; Turn = $turn; Text = $clean.Text })
        $history.Add([pscustomobject]@{ Author = $peerName; Turn = $turn; Text = $theirs.Text })
    }

    if ($info.role -eq 'host') {
        Set-Status 'running' 'El moderador redacta el resultado...'
        $result = (Remove-DebateSecrets (Invoke-DebateClaude (Format-DebateModeratorPrompt $topic $Me $peerName $history.ToArray()) $Dir -Moderator)).Text
        $r = Send-Debate 'final' $result
        if (-not $r.Ok) { Write-Log "the result did not reach $peerName`: $($r.Error)" }
    } else {
        Set-Status 'running' "El moderador de $peerName redacta el resultado..."
        $result = (Wait-DebateMessage 'final').Text
    }
    Add-Transcript ("## Resultado`r`n`r`n" + $result + "`r`n`r`n_Las IAs recomiendan; deciden ustedes._")
    Set-Status 'done' 'Resultado listo.'
    Write-Log 'done'
} catch {
    $message = $_.Exception.Message
    Write-Log ('FAILED: ' + $message)
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
    Add-Transcript ("**Debate detenido:** $message")
    Set-Status 'error' $message
    if ($script:Opened -and -not $script:PeerClosed -and $script:Peer) { Send-Debate 'close' $message | Out-Null }
} finally {
    # This PC's gate takes nothing more for this debate.
    [IO.File]::WriteAllText((Join-Path $Dir 'closed'), (Get-Date).ToString('o'))
}
