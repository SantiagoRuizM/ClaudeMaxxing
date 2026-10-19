# Proceso reproductor: lo lanza Start-VoiceJob en segundo plano con una lista de cosas que decir.
#   1. Prepara el audio de cada item: el mp3 guardado (repeticiones) o uno nuevo con edge-tts.
#      Esto ocurre en paralelo con otras sesiones.
#   2. Espera su turno en un mutex compartido para no hablar encima de otra sesion.
#   3. Baja la musica y, por cada item, toca la firma musical de su sesion y la voz (ffplay, o
#      SAPI si no hay mp3). Luego vuelve a subir la musica.
# Matar este proceso con taskkill /T corta el audio; Stop-Playback restaura la musica.
param([Parameter(Mandatory = $true)][string]$JobFile)

. "$PSScriptRoot\common.ps1"

function New-EdgeAudio($Cfg, [string]$Text, [string]$Voice, [string]$Mp3) {
    # La copia propia (install.ps1 la mantiene al dia) antes que otra en el PATH, que puede estar vieja.
    $own = Join-Path (Split-Path -Parent $PSScriptRoot) 'venv\Scripts\edge-tts.exe'
    $configured = Get-Opt $Cfg 'edge.exe' ''
    if (-not $configured -and (Test-Path -LiteralPath $own)) { $configured = $own }
    $edge = Find-Exe $configured 'edge-tts'
    if (-not $edge) { Write-Log 'edge: no encuentro edge-tts, uso SAPI'; return $false }
    $txt = [IO.Path]::ChangeExtension($Mp3, '.txt')
    [IO.File]::WriteAllText($txt, $Text, $Utf8)
    $rate = Get-Opt $Cfg 'edge.rate' '+0%'
    $null = & $edge --voice $Voice "--rate=$rate" --file $txt --write-media $Mp3 2>&1
    $ok = $LASTEXITCODE -eq 0 -and (Test-Path $Mp3)
    Remove-Item $txt -Force -ErrorAction SilentlyContinue
    if (-not $ok) { Write-Log "edge-tts fallo con $Voice (exit $LASTEXITCODE), uso SAPI" }
    return $ok
}

function Invoke-Sapi($Cfg, [string]$Text) {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $sapiVoice = Get-Opt $Cfg 'sapi.voice' ''
        if ($sapiVoice) {
            try { $synth.SelectVoice($sapiVoice) } catch {
                # En otro PC puede no estar esa voz: cualquier voz en espanol antes que la de por defecto.
                $spanish = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'es' }) |
                    Select-Object -First 1
                if ($spanish) { $synth.SelectVoice($spanish.VoiceInfo.Name) }
                Write-Log "sapi: la voz '$sapiVoice' no existe; uso '$($synth.Voice.Name)'"
            }
        }
        $synth.Rate = [int](Get-Opt $Cfg 'sapi.rate' 0)
        $synth.SetOutputToDefaultAudioDevice()
        $synth.Speak($Text)
    } finally {
        $synth.Dispose()
    }
}

$cfg    = Get-VoiceConfig
$job    = Read-JsonFile $JobFile
$temps  = New-Object System.Collections.ArrayList
$mutex  = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoicePlayer')
$owned  = $false
$ducked = $false
try {
    $ffplay  = Find-Exe (Get-Opt $cfg 'ffplay' '') 'ffplay'
    $useEdge = (Get-Opt $cfg 'engine' 'edge') -eq 'edge' -and $ffplay

    # 1. Preparar audio
    $plan = foreach ($item in @($job.items)) {
        $audio = ''
        if ($ffplay -and $item.audio -and (Test-Path $item.audio)) {
            $audio = $item.audio
        } elseif ($useEdge) {
            $mp3 = Join-Path $StateDir ('job-{0}-{1}.mp3' -f $job.key, [guid]::NewGuid().ToString('N'))
            [void]$temps.Add($mp3)
            if (New-EdgeAudio $cfg $item.text $item.voice $mp3) { $audio = $mp3 }
        }
        if ($job.history) { Add-History $item $audio $cfg }
        $chime = $null
        try { $chime = Get-SessionChime $cfg $item.session } catch { Write-Log "chime: $_" }
        [pscustomobject]@{ text = $item.text; audio = $audio; chime = $chime }
    }

    # 2. Turno. Si un reproductor murio con el mutex tomado (taskkill), WaitOne lanza
    #    AbandonedMutexException pero igual nos lo entrega.
    $wait = [int](Get-Opt $cfg 'queueTimeoutSeconds' 90)
    try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds($wait)) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log "cola: $($job.key) espero mas de $wait s, descartado"; return }

    # 3. Bajar musica (o heredarla ya baja del anterior en la cola), hablar, subir musica
    #    salvo que otro reproductor espere turno: entonces se queda baja para el siguiente.
    if (Get-Opt $cfg 'duck.enabled' $true) { $ducked = (Receive-Duck) -or (Invoke-Duck $cfg) }
    else { Restore-StaleDuck $cfg }
    $players = New-Object System.Collections.ArrayList  # referencias vivas mientras suena el acorde
    foreach ($p in $plan) {
        # Firma de la sesion: el acorde suena en este proceso y la voz entra mientras se apaga.
        if ($p.chime -and (Test-Path $p.chime.wav)) {
            $sp = New-Object System.Media.SoundPlayer $p.chime.wav
            [void]$players.Add($sp)
            $sp.Play()
            Start-Sleep -Milliseconds ([int]$p.chime.leadMs)
        }
        if ($p.audio) { $null = & $ffplay -nodisp -autoexit -loglevel quiet $p.audio 2>&1 }
        else { Invoke-Sapi $cfg $p.text }
    }
} catch {
    Write-Log "play: $_"
} finally {
    $waiting = Test-QueueWaiting
    if ($ducked) { if ($waiting) { Send-Duck } else { Restore-Duck $cfg } }
    elseif (-not $waiting) { Restore-StaleDuck $cfg }  # p. ej. se descarto por la cola con musica heredada
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Remove-Item (@($JobFile) + @($temps)) -Force -ErrorAction SilentlyContinue
    $pidFile = Join-Path $StateDir "player-$($job.key).json"
    $info = Read-JsonFile $pidFile
    if ($info -and [int]$info.pid -eq $PID) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
}
