# Motores de voz: generan el audio de un texto. Los carga play.ps1 despues de common.ps1.
#   edge        Microsoft Edge (edge-tts): gratis y sin clave. El de siempre.
#   elevenlabs  ElevenLabs: la mas natural. Necesita clave; la cuenta gratis trae unos 10.000 creditos al mes.
#   gemini      Google Gemini TTS: muy natural, con clave de Google AI Studio (capa gratuita con limites).
#   sapi        La voz de Windows: sin internet, la menos natural.
# El motor elegido ('engine' en la config) se intenta primero; si falla (sin clave, sin creditos, sin red)
# se usa edge y, si tambien falla, play.ps1 usa SAPI. Un motor que se queda sin creditos o rechaza la clave
# se aparta un rato (engine-off-<motor>.json) para no esperar su error en cada frase.
# Las claves viven en config.local.json de la instalacion y nunca se escriben en el log.

$EngineNames = @('edge', 'elevenlabs', 'gemini', 'sapi')

function Get-EngineOrder($Config) {
    $engine = [string](Get-Opt $Config 'engine' 'edge')
    if ($EngineNames -notcontains $engine) { $engine = 'edge' }
    if ($engine -eq 'sapi') { return }
    @($engine, 'edge') | Select-Object -Unique
}

function Get-EngineSnoozeFile([string]$Engine) { Join-Path $StateDir "engine-off-$Engine.json" }

function Test-EngineSnoozed([string]$Engine) {
    $info = Read-JsonFile (Get-EngineSnoozeFile $Engine)
    if (-not $info -or -not $info.until) { return $false }
    try { return [datetime]$info.until -gt (Get-Date) } catch { return $false }
}

function Set-EngineSnooze([string]$Engine, [int]$Minutes, [string]$Why) {
    Write-JsonFile (Get-EngineSnoozeFile $Engine) ([pscustomobject]@{ until = (Get-Date).AddMinutes($Minutes).ToString('s'); why = $Why })
    Write-Log "voz: $Engine apartado $Minutes min ($Why)"
}

# La voz del motor premium para una sesion: la misma persona siempre (por su voz de edge) y del mismo
# genero. $Voices: lista de @{ id; gender } (ElevenLabs) o de nombres por genero (Gemini).
function Select-EngineVoice($Config, [string]$EdgeVoice, $Female, $Male) {
    $gender = Get-VoiceGender $Config $EdgeVoice
    $pool = @(if ($gender -eq 'm') { $Male } else { $Female })
    if (-not $pool.Count) { $pool = @(@($Female) + @($Male) | Where-Object { $_ }) }
    if (-not $pool.Count) { return $null }
    $edgePool = @(Get-Opt $Config 'edge.voicePool' $DefaultPool | Where-Object { (Get-VoiceGender $Config $_) -eq $gender })
    $index = [array]::IndexOf($edgePool, $EdgeVoice)
    if ($index -lt 0) { $index = 0; foreach ($ch in $EdgeVoice.ToCharArray()) { $index += [int]$ch } }
    $pool[$index % $pool.Count]
}

function Get-ElevenVoiceId($Config, [string]$EdgeVoice) {
    $voices = @(Get-Opt $Config 'elevenlabs.voices' @())
    $f = @($voices | Where-Object { $_.gender -eq 'f' } | ForEach-Object { $_.id })
    $m = @($voices | Where-Object { $_.gender -eq 'm' } | ForEach-Object { $_.id })
    $other = @($voices | Where-Object { $_.gender -notin 'f', 'm' } | ForEach-Object { $_.id })
    Select-EngineVoice $Config $EdgeVoice (@($f) + @($other)) (@($m) + @($other))
}

function Get-GeminiVoiceName($Config, [string]$EdgeVoice) {
    Select-EngineVoice $Config $EdgeVoice @(Get-Opt $Config 'gemini.voices.f' @('Kore')) @(Get-Opt $Config 'gemini.voices.m' @('Puck'))
}

function Set-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Codigo HTTP y cuerpo de un error de Invoke-WebRequest (PowerShell 5.1).
function Get-HttpFailure($ErrorRecord) {
    $code = 0; $body = ''
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    try {
        $reader = New-Object IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Dispose()
    } catch {}
    if (-not $body -and $ErrorRecord.ErrorDetails) { $body = [string]$ErrorRecord.ErrorDetails.Message }
    [pscustomobject]@{ Code = $code; Body = $body }
}

function New-EdgeAudio($Cfg, [string]$Text, [string]$Voice, [string]$Out) {
    # La copia propia (install.ps1 la mantiene al dia) antes que otra en el PATH, que puede estar vieja.
    $own = Join-Path (Split-Path -Parent $PSScriptRoot) 'venv\Scripts\edge-tts.exe'
    $configured = Get-Opt $Cfg 'edge.exe' ''
    if (-not $configured -and (Test-Path -LiteralPath $own)) { $configured = $own }
    $edge = Find-Exe $configured 'edge-tts'
    if (-not $edge) { Write-Log 'edge: no encuentro edge-tts'; return $false }
    $txt = [IO.Path]::ChangeExtension($Out, '.txt')
    [IO.File]::WriteAllText($txt, $Text, $Utf8)
    $rate = Get-Opt $Cfg 'edge.rate' '+0%'
    $null = & $edge --voice $Voice "--rate=$rate" --file $txt --write-media $Out 2>&1
    $ok = $LASTEXITCODE -eq 0 -and (Test-Path $Out)
    Remove-Item $txt -Force -ErrorAction SilentlyContinue
    if (-not $ok) { Write-Log "edge-tts fallo con $Voice (exit $LASTEXITCODE)" }
    return $ok
}

function New-ElevenAudio($Cfg, [string]$Text, [string]$EdgeVoice, [string]$Out) {
    $key = [string](Get-Opt $Cfg 'elevenlabs.apiKey' '')
    if (-not $key) { Write-Log 'elevenlabs: sin clave'; return $false }
    $voiceId = Get-ElevenVoiceId $Cfg $EdgeVoice
    if (-not $voiceId) { Write-Log 'elevenlabs: sin voces (vuelve a pegar la clave en ClaudeMaxxing > Voz)'; return $false }
    $body = [ordered]@{ text = $Text; model_id = [string](Get-Opt $Cfg 'elevenlabs.model' 'eleven_flash_v2_5') }
    $settings = Get-Opt $Cfg 'elevenlabs.voiceSettings' $null
    if ($settings) { $body.voice_settings = $settings }
    $json = ConvertTo-Json -InputObject $body -Compress -Depth 4
    Set-Tls12
    try {
        Invoke-WebRequest -Method Post -UseBasicParsing -TimeoutSec 25 -OutFile $Out `
            -Uri ("https://api.elevenlabs.io/v1/text-to-speech/{0}?output_format=mp3_44100_128" -f [Uri]::EscapeDataString($voiceId)) `
            -Headers @{ 'xi-api-key' = $key; Accept = 'audio/mpeg' } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    } catch {
        $fail = Get-HttpFailure $_
        $why = if ($fail.Body -match 'quota_exceeded') { 'sin cr' + [char]0xE9 + 'ditos' } elseif ($fail.Code -eq 401) { 'clave rechazada' } elseif ($fail.Code -eq 429) { 'demasiadas peticiones' } else { "HTTP $($fail.Code)" }
        Write-Log "elevenlabs: fallo ($why)"
        if ($fail.Body -match 'quota_exceeded') { Set-EngineSnooze 'elevenlabs' 360 $why }
        elseif ($fail.Code -in 401, 402) { Set-EngineSnooze 'elevenlabs' 60 $why }
        elseif ($fail.Code -eq 429) { Set-EngineSnooze 'elevenlabs' 5 $why }
        Remove-Item $Out -Force -ErrorAction SilentlyContinue
        return $false
    }
    return (Test-Path $Out) -and (Get-Item $Out).Length -gt 200
}

function New-GeminiAudio($Cfg, [string]$Text, [string]$EdgeVoice, [string]$Out) {
    $key = [string](Get-Opt $Cfg 'gemini.apiKey' '')
    if (-not $key) { Write-Log 'gemini: sin clave'; return $false }
    $voice = Get-GeminiVoiceName $Cfg $EdgeVoice
    $style = [string](Get-Opt $Cfg 'gemini.style' '')
    $content = [ordered]@{ type = 'text'; text = $Text }
    if ($style) { $content.annotations = @([ordered]@{ type = 'speech_metadata'; style = $style }) }
    $body = [ordered]@{
        model = [string](Get-Opt $Cfg 'gemini.model' 'gemini-3.8-flash-tts')
        input = @([ordered]@{ type = 'user_input'; content = @($content) })
        response_format = [ordered]@{ type = 'audio' }
        generation_config = [ordered]@{ speech_config = @([ordered]@{ voice = $voice }) }
    }
    $json = ConvertTo-Json -InputObject $body -Compress -Depth 8
    Set-Tls12
    try {
        $response = Invoke-RestMethod -Method Post -UseBasicParsing -TimeoutSec 30 `
            -Uri 'https://generativelanguage.googleapis.com/v1beta/interactions' `
            -Headers @{ 'x-goog-api-key' = $key } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json))
    } catch {
        $fail = Get-HttpFailure $_
        $why = if ($fail.Code -eq 429) { 'l' + [char]0xED + 'mite de la capa gratuita' } elseif ($fail.Code -in 400, 401, 403) { 'clave o petici' + [char]0xF3 + 'n rechazada' } else { "HTTP $($fail.Code)" }
        Write-Log "gemini: fallo ($why)"
        if ($fail.Code -eq 429) { Set-EngineSnooze 'gemini' 30 $why }
        elseif ($fail.Code -in 401, 403 -or $fail.Body -match 'API_KEY_INVALID') { Set-EngineSnooze 'gemini' 60 $why }
        return $false
    }
    $data = Get-GeminiAudioData $response
    if (-not $data) { Write-Log 'gemini: la respuesta no trae audio'; return $false }
    [IO.File]::WriteAllBytes($Out, [Convert]::FromBase64String($data))
    return (Get-Item $Out).Length -gt 200
}

# steps[].content[] de tipo audio: el ultimo bloque trae el WAV en base64.
function Get-GeminiAudioData($Response) {
    $data = $null
    foreach ($step in @($Response.steps)) {
        foreach ($block in @($step.content)) { if ($block -and $block.type -eq 'audio' -and $block.data) { $data = [string]$block.data } }
    }
    $data
}

# El audio de un texto con el primer motor que funcione, o '' (play.ps1 usa entonces SAPI).
# $Base: ruta sin extension para el archivo.
function New-SpeechAudio($Cfg, [string]$Text, [string]$EdgeVoice, [string]$Base) {
    foreach ($engine in (Get-EngineOrder $Cfg)) {
        if ($engine -ne 'edge' -and (Test-EngineSnoozed $engine)) { continue }
        $out = switch ($engine) { 'gemini' { "$Base.wav" } default { "$Base.mp3" } }
        $ok = switch ($engine) {
            'elevenlabs' { New-ElevenAudio $Cfg $Text $EdgeVoice $out }
            'gemini'     { New-GeminiAudio $Cfg $Text $EdgeVoice $out }
            default      { New-EdgeAudio $Cfg $Text $EdgeVoice $out }
        }
        if ($ok) { return $out }
    }
    ''
}
