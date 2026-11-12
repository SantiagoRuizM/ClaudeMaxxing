# Proceso reproductor: lo lanza Start-VoiceJob en segundo plano con una lista de cosas que decir.
#   1. Prepara el audio de cada item: el guardado (repeticiones) o uno nuevo con el motor de voz
#      configurado (engines.ps1: ElevenLabs, Gemini o edge-tts).
#      Esto ocurre en paralelo con otras sesiones.
#   2. Espera su turno en un mutex compartido para no hablar encima de otra sesion.
#   3. Baja la musica y, por cada item, toca la firma musical de su sesion y la voz (ffplay, o
#      SAPI si no hay mp3). Luego vuelve a subir la musica.
# Matar este proceso con taskkill /T corta el audio; Stop-Playback restaura la musica.
param([Parameter(Mandatory = $true)][string]$JobFile)

. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\engines.ps1"

function Invoke-Sapi($Cfg, [string]$Text) {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        # La voz configurada si habla el idioma del texto; si no, la primera instalada de ese idioma, y si no
        # hay ninguna, la configurada (o la de por defecto).
        $sapiVoice = Get-Opt $Cfg 'sapi.voice' ''
        $lang = Get-TextLanguage $Text
        $installed = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo })
        $configured = $installed | Where-Object { $_.Name -eq $sapiVoice } | Select-Object -First 1
        if ($sapiVoice -and -not $configured) { Write-Log "sapi: la voz '$sapiVoice' no existe en este PC" }
        $pick = if ($configured -and $configured.Culture.TwoLetterISOLanguageName -eq $lang) { $configured }
                else { $installed | Where-Object { $_.Culture.TwoLetterISOLanguageName -eq $lang } | Select-Object -First 1 }
        if (-not $pick) { $pick = $configured }
        if ($pick) { $synth.SelectVoice($pick.Name) }
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

    # 1. Preparar audio
    $plan = foreach ($item in @($job.items)) {
        $audio = ''
        if ($ffplay -and $item.audio -and (Test-Path $item.audio)) {
            $audio = $item.audio
        } elseif ($ffplay) {
            # ElevenLabs, Gemini o edge segun la config (engines.ps1); '' si ninguno pudo: SAPI.
            $base = Join-Path $StateDir ('job-{0}-{1}' -f $job.key, [guid]::NewGuid().ToString('N'))
            $audio = New-SpeechAudio $cfg $item.text $item.voice $base
            if ($audio) { [void]$temps.Add($audio) } else { Write-Log 'voz: ningun motor genero audio, uso SAPI' }
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
    # Quien habla ahora, para la bandeja (su huevo se ilumina). Se borra al soltar el turno.
    $me = Get-Process -Id $PID
    Write-JsonFile $SpeakingFile ([pscustomobject]@{ key = $job.key; pid = $PID; start = [string]$me.StartTime.Ticks })

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
    if ($owned) {
        $speaking = Read-JsonFile $SpeakingFile
        if ($speaking -and [int]$speaking.pid -eq $PID) { Remove-Item $SpeakingFile -Force -ErrorAction SilentlyContinue }
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
    Remove-Item (@($JobFile) + @($temps)) -Force -ErrorAction SilentlyContinue
    $pidFile = Join-Path $StateDir "player-$($job.key).json"
    $info = Read-JsonFile $pidFile
    if ($info -and [int]$info.pid -eq $PID) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
}
