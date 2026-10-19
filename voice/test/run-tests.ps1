# Pruebas sin audio: extraccion del texto, hook de punta a punta en modo dry-run
# e install/uninstall sobre copias temporales (no toca tu ~/.claude).
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1
# Usa su propio %TEMP% para no tocar el estado real (voces asignadas, silencios, log).
$realTemp = $env:TEMP
$env:TEMP = Join-Path $realTemp ('claude-voice-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
. "$PSScriptRoot\..\hooks\common.ps1"

$script:failed = 0
function Check([string]$Name, [bool]$Ok, $Got) {
    if ($Ok) { "  ok    $Name" } else { "  FALLA $Name -> '$Got'"; $script:failed++ }
}

$M = $DefaultMarker
$NL = "`n"
$cfg = [pscustomobject]@{ marker = $M; fallback = 'first-sentence'; maxChars = 300 }

'Get-SpokenText'
$r = Get-SpokenText ("Texto largo.$NL$NL$M **Listo**, todo en ``main``.") $cfg
Check 'extrae la linea del marcador y limpia markdown' ($r -eq 'Listo, todo en main.') $r

$r = Get-SpokenText ("$M primero$NL texto$NL$M segundo") $cfg
Check 'usa la ultima linea con marcador' ($r -eq 'segundo') $r

$r = Get-SpokenText ("## Titulo$NL``````$NL codigo()$NL``````$NL Hice el cambio. Luego otra cosa.") $cfg
Check 'sin marcador: primera frase, sin titulos ni codigo' ($r -eq 'Hice el cambio.') $r

$r = Get-SpokenText 'Mira [la doc](https://x.y/z) y https://a.b/c ya.' $cfg
Check 'quita URLs y deja el texto de los enlaces' ($r -eq 'Mira la doc y ya.') $r

$none = [pscustomobject]@{ marker = $M; fallback = 'none' }
$r = Get-SpokenText 'Sin marcador.' $none
Check 'fallback none no dice nada' ($null -eq $r) $r

$short = [pscustomobject]@{ marker = $M; maxChars = 20 }
$r = Get-SpokenText "$M una frase bastante larga que hay que recortar" $short
Check 'recorta en limite de palabra' ($r -eq 'una frase bastante...') $r

Check 'mensaje vacio' ($null -eq (Get-SpokenText '' $cfg)) ''

'Hook speak.ps1 (dry-run)'
$out = Join-Path $StateDir 'dryrun.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$env:CLAUDEVOICE_DRYRUN = $out
$OutputEncoding = $Utf8  # PS 5.1 enviaria ASCII al proceso hijo; Claude Code envia UTF-8
Get-Content "$PSScriptRoot\stop-event.json" -Raw -Encoding UTF8 |
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\hooks\speak.ps1"
Remove-Item Env:\CLAUDEVOICE_DRYRUN
$r = if (Test-Path $out) { [IO.File]::ReadAllText($out, $Utf8) } else { '' }
Check 'lee stdin UTF-8 y dice "Soy <nombre>, <rol>. <resumen>"' ($r -like '*|Soy *, asistente. Arregl? el login y las pruebas pasan; falta que revises el despliegue.') $r
Check 'conserva tildes' ($r.Contains([string][char]0x00E9)) $r

'Voz y silencio por sesion'
$cfgFile = Get-VoiceConfig
$pool = @(Get-Opt $cfgFile 'edge.voicePool' $DefaultPool)
$v1 = Get-SessionVoice $cfgFile 'aaaa-1111'
$v2 = Get-SessionVoice $cfgFile 'bbbb-2222'
Check 'sesiones distintas reciben voces distintas' ($v1 -ne $v2 -and $pool -contains $v1 -and $pool -contains $v2) "$v1 / $v2"
Check 'la misma sesion conserva su voz' ((Get-SessionVoice $cfgFile 'aaaa-1111') -eq $v1) ''
$env:CLAUDEVOICE_VOICE = 'es-UY-MateoNeural'
Check 'CLAUDEVOICE_VOICE manda' ((Get-SessionVoice $cfgFile 'aaaa-1111') -eq 'es-UY-MateoNeural') ''
Remove-Item Env:\CLAUDEVOICE_VOICE
Check 'session id raro se sanea' ((Get-SessionKey '../x y;z') -eq 'xyz') (Get-SessionKey '../x y;z')

$ctl = "$PSScriptRoot\..\ctl.ps1"
& $ctl session aaaa-1111 off | Out-Null
Check '/voz off silencia solo esa sesion' ((Test-Muted 'aaaa-1111') -and -not (Test-Muted 'bbbb-2222')) ''
& $ctl session aaaa-1111 on | Out-Null
Check '/voz on la reactiva' (-not (Test-Muted 'aaaa-1111')) ''
& $ctl session aaaa-1111 voz gonzalo | Out-Null
Check '/voz voz gonzalo elige es-CO-GonzaloNeural' ((Get-SessionVoice $cfgFile 'aaaa-1111') -eq 'es-CO-GonzaloNeural') ''
$r = (& $ctl session aaaa-1111 voz klingon) -join ' '
Check '/voz con voz desconocida no cambia nada' ($r -match 'no reconozco' -and (Get-SessionVoice $cfgFile 'aaaa-1111') -eq 'es-CO-GonzaloNeural') $r
& $ctl session aaaa-1111 todo-off | Out-Null
Check '/voz todo-off silencia todas' ((Test-Muted 'bbbb-2222') -and (Test-Muted 'cccc')) ''
& $ctl session aaaa-1111 todo-on | Out-Null
Check '/voz todo-on quita el silencio global' (-not (Test-Muted 'bbbb-2222')) ''
$env:CLAUDEVOICE = 'off'
Check 'CLAUDEVOICE=off silencia la sesion' (Test-Muted 'bbbb-2222') ''
Remove-Item Env:\CLAUDEVOICE

Remove-Item $out -ErrorAction SilentlyContinue
$env:CLAUDEVOICE_DRYRUN = $out
& $ctl session bbbb-2222 off | Out-Null
'{"session_id":"bbbb-2222","last_assistant_message":"x"}' |
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\hooks\speak.ps1"
Remove-Item Env:\CLAUDEVOICE_DRYRUN
Check 'el hook respeta el silencio de la sesion' (-not (Test-Path $out)) ''

'Nombre y rol de la sesion'
$e = [string][char]0x00E9; $n = [string][char]0x00F1; $o = [string][char]0x00F3
$r = Get-SessionRole $cfgFile "implementa el endpoint de login y arregla el bug" 'f'
Check 'rol codificadora' ($r -eq 'codificadora') $r
$r = Get-SessionRole $cfgFile "investiga si es viable usar edge-tts y compara alternativas" 'm'
Check 'rol investigador' ($r -eq 'investigador') $r
$r = Get-SessionRole $cfgFile "redacta un correo para el cliente" 'f'
Check 'rol editora' ($r -eq 'editora') $r
$r = Get-SessionRole $cfgFile ("dise" + $n + "a la interfaz de la landing") 'm'
Check 'rol con tildes (disenador)' ($r -eq ("dise" + $n + "ador")) $r
$r = Get-SessionRole $cfgFile ("Investigaci" + $o + "n del mercado") 'f'
Check 'palabra clave con tilde en el prompt' ($r -eq 'investigadora') $r
$r = Get-SessionRole $cfgFile "hola" 'm'
Check 'sin pistas: asistente' ($r -eq 'asistente') $r
$r = Get-SessionRole $cfgFile "resume esto`n<pasted_content id=`"x`">implementa codigo bug fix api test</pasted_content id=`"x`">" 'f'
Check 'ignora el contenido pegado' ($r -eq 'editora') $r

Set-Content -Path (Get-SessionFile 'voice' 'mmmm-1') -Value 'es-CO-GonzaloNeural' -NoNewline
$a = New-SessionName $cfgFile 'mmmm-1' 'revisa el pull request'
Check 'nombre masculino para voz masculina' (@($cfgFile.naming.names.m) -contains $a.name -and $a.gender -eq 'm') $a.name
Check 'titulo con nombre y rol' ($a.title -eq ($a.name + ' ' + [char]0x00B7 + ' revisor')) $a.title
$names = @(1..6 | ForEach-Object {
    Set-Content -Path (Get-SessionFile 'voice' "ffff-$_") -Value 'es-CO-SalomeNeural' -NoNewline
    (New-SessionName $cfgFile "ffff-$_" 'x').name })
Check 'sesiones activas no repiten nombre' (@($names | Select-Object -Unique).Count -eq 6) ($names -join ',')

'Firma musical por sesion'
Set-Content -Path (Get-SessionFile 'voice' 'cccc-1') -Value 'es-CO-GonzaloNeural' -NoNewline
$null = New-SessionName $cfgFile 'cccc-1' 'implementa el endpoint y arregla el bug'
$null = New-SessionName $cfgFile 'cccc-2' 'investiga y compara alternativas'
$c1 = Get-SessionChime $cfgFile 'cccc-1'
$c2 = Get-SessionChime $cfgFile 'cccc-2'
Check 'sesiones activas reciben motivos distintos' ($c1.motif -ne $c2.motif) "$($c1.motif) / $($c2.motif)"
Check 'timbre segun el rol (codigo = marimba, investigacion = cristal)' ($c1.timbre -eq 'marimba' -and $c2.timbre -eq 'cristal') "$($c1.timbre) / $($c2.timbre)"
$bytes = [IO.File]::ReadAllBytes($c1.wav)
$seconds = ($bytes.Length - 44) / (44100 * 2)
Check 'genera un WAV valido de 0,5 a 3 s' ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'RIFF' -and $seconds -gt 0.5 -and $seconds -lt 3) "$seconds s"
Check 'la voz entra antes de que acabe el acorde' ($c1.leadMs -gt 300 -and $c1.leadMs -lt ($seconds * 1000)) $c1.leadMs
Check 'la misma sesion conserva su firma' ((Get-SessionChime $cfgFile 'cccc-1').motif -eq $c1.motif) ''
$c3 = New-SessionChime $cfgFile 'cccc-1' 4
Check '/voz sonido 5 fija el motivo 5' ((Get-SessionChime $cfgFile 'cccc-1').motif -eq 4 -and $c3.chord -eq 'add9') $c3.chord
Check 'sin firma para say/replay' ($null -eq (Get-SessionChime $cfgFile 'manual') -and $null -eq (Get-SessionChime $cfgFile 'replay')) ''
$sigs = @(1..12 | ForEach-Object { $null = New-SessionName $cfgFile "kkkk-$_" 'x'; (Get-SessionChime $cfgFile "kkkk-$_").motif })
Check 'los 12 motivos se reparten sin repetir mientras haya libres' (@($sigs + $c2.motif + 4 | Select-Object -Unique).Count -eq 12) ($sigs -join ',')
Check 'ConvertTo-Midi' ((ConvertTo-Midi 'C4') -eq 60 -and (ConvertTo-Midi 'F#3') -eq 54 -and (ConvertTo-Midi 'Bb3') -eq 58) ''

'Hook on-prompt.ps1'
$hook = "$PSScriptRoot\..\hooks\on-prompt.ps1"
$raw = '{"session_id":"pppp-1","prompt":"implementa el login"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
$raw = "$raw"
Check 'salida solo ASCII' ($raw -notmatch '[^\x00-\x7F]' -and $raw.Length -gt 0) $raw
$j = $raw | ConvertFrom-Json
Check 'devuelve sessionTitle con el rol' ($j.hookSpecificOutput.sessionTitle -like '*codificador*') $raw
Check 'avisa al usuario (systemMessage)' ($j.systemMessage -like '*codificador*') $j.systemMessage
$raw = '{"session_id":"pppp-1","prompt":"otra cosa"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
Check 'segundo prompt: sin salida' ([string]::IsNullOrEmpty("$raw")) $raw
$raw = '{"session_id":"pppp-2","prompt":"hola","session_title":"Mio"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
$j = "$raw" | ConvertFrom-Json
Check 'no pisa un titulo puesto por el usuario' (-not $j.hookSpecificOutput.sessionTitle -and $j.systemMessage) "$raw"

'Sesiones abiertas desde el menu (reservadas)'
$res = New-ReservedSession $cfgFile 'rrrr-1' 'orange'
Check 'reserva nombre y voz antes de arrancar, rol pendiente' ($res.name -and $res.voice -and $res.pendingRole -and $res.title -eq $res.name -and $res.color -eq 'orange') ($res | ConvertTo-Json -Compress)
$res2 = New-ReservedSession $cfgFile 'rrrr-2' 'blue'
Check 'dos reservas no repiten nombre ni voz' ($res.name -ne $res2.name -and $res.voice -ne $res2.voice) "$($res.name)/$($res2.name)"
$raw = '{"session_id":"rrrr-1","prompt":"/voz repetir"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
Check 'un comando /... no decide el rol' ([string]::IsNullOrEmpty("$raw") -and (Get-SessionName 'rrrr-1').pendingRole) "$raw"
$raw = '{"session_id":"rrrr-1","prompt":"arregla el bug del login","session_title":"x"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
$j = "$raw" | ConvertFrom-Json
$after = Get-SessionName 'rrrr-1'
Check 'primer prompt: completa el titulo con el rol aunque ya tenga titulo' ($j.hookSpecificOutput.sessionTitle -eq ($res.name + ' ' + [char]0x00B7 + ' ' + $after.role) -and $after.roleKey -eq 'codigo') "$raw"
Check 'conserva nombre, voz y color' ($after.name -eq $res.name -and $after.voice -eq $res.voice -and $after.color -eq 'orange' -and -not $after.pendingRole) ($after | ConvertTo-Json -Compress)
$raw = '{"session_id":"rrrr-1","prompt":"otra cosa"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
Check 'despues: sin salida' ([string]::IsNullOrEmpty("$raw")) $raw

'Hook on-start.ps1'
$startHook = "$PSScriptRoot\..\hooks\on-start.ps1"
$raw = "$('{"session_id":"rrrr-2","source":"startup"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startHook)"
Check 'salida solo ASCII' ($raw -notmatch '[^\x00-\x7F]' -and $raw.Length -gt 0) $raw
$j = $raw | ConvertFrom-Json
Check 'pone el nombre reservado como titulo' ($j.hookSpecificOutput.sessionTitle -eq $res2.name) $raw
Check 'anade la regla del resumen hablado al contexto' ($j.hookSpecificOutput.additionalContext -like ("*$M*")) $raw
$j = "$('{"session_id":"ssss-9","source":"startup"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startHook)" | ConvertFrom-Json
Check 'sin nombre reservado: solo la regla' (-not $j.hookSpecificOutput.sessionTitle -and $j.hookSpecificOutput.additionalContext) ''

'Historial'
foreach ($i in 1..4) {
    $sess = if ($i -le 2) { 'hhhh-1' } else { 'hhhh-2' }
    Add-History ([pscustomobject]@{ text = "mensaje $i"; voice = 'v'; session = $sess; name = 'N' }) '' $cfgFile
    Start-Sleep -Milliseconds 20
}
$h = @(Get-History 2 '')
Check 'repetir 2: las dos ultimas, en orden' ($h.Count -eq 2 -and $h[0].text -eq 'mensaje 3' -and $h[1].text -eq 'mensaje 4') ($h.text -join ',')
$h = @(Get-History 5 'hhhh-1')
Check 'repetir por sesion' ($h.Count -eq 2 -and $h[1].text -eq 'mensaje 2') ($h.text -join ',')
$small = [pscustomobject]@{ historySize = 3 }
Add-History ([pscustomobject]@{ text = 'mensaje 5'; voice = 'v'; session = 'hhhh-1'; name = 'N' }) '' $small
Check 'historial limitado a historySize' (@(Get-ChildItem $HistoryDir -Filter *.json).Count -eq 3) ''

'Mezclador (bajar musica)'
$ok = $true
try { Import-Native; $null = [ClaudeVoice.Mixer]::Snapshot([int[]]@($PID)) } catch { $ok = $false; $err = "$_" }
Check 'compila y lee las sesiones de audio' $ok $err
Check 'restaurar sin estado no falla' ((Restore-Duck $cfgFile 0) -eq $null) ''

'config.local.json sobre config.json'
$base = '{ "engine": "edge", "edge": { "voice": "a", "rate": "+5%", "voicePool": ["a", "b"] }, "ffplay": "" }' | ConvertFrom-Json
Merge-VoiceConfig $base ('{ "edge": { "exe": "C:/x/edge-tts.exe", "voicePool": ["z"] }, "ffplay": "C:/y/ffplay.exe" }' | ConvertFrom-Json)
Check 'agrega claves anidadas' ($base.edge.exe -eq 'C:/x/edge-tts.exe') $base.edge.exe
Check 'conserva las hermanas' ($base.edge.voice -eq 'a' -and $base.edge.rate -eq '+5%' -and $base.engine -eq 'edge') ($base | ConvertTo-Json -Compress)
Check 'reemplaza listas enteras' ((@($base.edge.voicePool) -join ',') -eq 'z') (@($base.edge.voicePool) -join ',')
Check 'reemplaza valores de primer nivel' ($base.ffplay -eq 'C:/y/ffplay.exe') $base.ffplay
$shipped = [IO.File]::ReadAllText("$PSScriptRoot\..\config.json", $Utf8) | ConvertFrom-Json
Check 'config.json no trae rutas de este PC' (-not $shipped.edge.exe -and -not $shipped.ffplay) "$($shipped.edge.exe) $($shipped.ffplay)"

'install.ps1 sobre copias temporales'
$tmp = Join-Path $StateDir 'install-test'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$s = Join-Path $tmp 'settings.json'
$c = Join-Path $tmp 'CLAUDE.md'
Get-ChildItem $tmp | Remove-Item -Force
[IO.File]::WriteAllText($s, '{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "otro.sh" } ] } ] } }', $Utf8)
[IO.File]::WriteAllText($c, "# Mis reglas$NL", $Utf8)

$install = "$PSScriptRoot\..\install.ps1"
$k = Join-Path $tmp 'skills'
& $install -SettingsPath $s -ClaudeMdPath $c -SkillsDir $k | Out-Null
& $install -SettingsPath $s -ClaudeMdPath $c -SkillsDir $k | Out-Null
Check '/voz instalado con la ruta real de ctl.ps1' ((Get-Content "$k\voz\SKILL.md" -Raw) -match '(ClaudeVoice|voice)/ctl\.ps1 session \$\{CLAUDE_SESSION_ID\}') ''
$j = [IO.File]::ReadAllText($s, $Utf8) | ConvertFrom-Json
Check 'conserva otras opciones' ($j.model -eq 'opus') $j.model
Check 'conserva hooks ajenos y no duplica' (@($j.hooks.Stop).Count -eq 2) @($j.hooks.Stop).Count
Check 'hook async con args' ($j.hooks.Stop[1].hooks[0].async -and @($j.hooks.Stop[1].hooks[0].args).Count -eq 5) ''
Check 'UserPromptSubmit sincrono con timeout' (@($j.hooks.UserPromptSubmit).Count -eq 1 -and -not $j.hooks.UserPromptSubmit[0].hooks[0].async -and $j.hooks.UserPromptSubmit[0].hooks[0].timeout -eq 10) ''
$md = [IO.File]::ReadAllText($c, $Utf8)
Check 'regla en CLAUDE.md una sola vez' (([regex]::Matches($md, 'claudevoice:start')).Count -eq 1 -and $md.StartsWith('# Mis reglas')) $md

& $install -Uninstall -SettingsPath $s -ClaudeMdPath $c -SkillsDir $k | Out-Null
Check 'uninstall quita /voz' (-not (Test-Path "$k\voz")) ''
$j = [IO.File]::ReadAllText($s, $Utf8) | ConvertFrom-Json
Check 'uninstall deja solo el hook ajeno' (@($j.hooks.Stop).Count -eq 1 -and -not $j.hooks.PSObject.Properties['UserPromptSubmit']) ''
$md = [IO.File]::ReadAllText($c, $Utf8)
Check 'uninstall quita la regla' ($md.Trim() -eq '# Mis reglas') $md

'Motores de voz (engines.ps1)'
. "$PSScriptRoot\..\hooks\engines.ps1"
$ecfg = [pscustomobject]@{
    engine = 'elevenlabs'
    edge = [pscustomobject]@{ voicePool = @('es-CO-SalomeNeural', 'es-CO-GonzaloNeural', 'es-MX-DaliaNeural', 'es-MX-JorgeNeural')
        voiceGenders = [pscustomobject]@{ 'es-CO-SalomeNeural' = 'f'; 'es-CO-GonzaloNeural' = 'm'; 'es-MX-DaliaNeural' = 'f'; 'es-MX-JorgeNeural' = 'm' } }
    elevenlabs = [pscustomobject]@{ apiKey = ''; voices = @([pscustomobject]@{ id = 'F1'; gender = 'f' }, [pscustomobject]@{ id = 'F2'; gender = 'f' }, [pscustomobject]@{ id = 'M1'; gender = 'm' }) }
    gemini = [pscustomobject]@{ voices = [pscustomobject]@{ f = @('Kore', 'Aoede'); m = @('Puck') } }
}
$order = @(Get-EngineOrder $ecfg)
Check 'orden: el elegido y luego edge' (($order -join ',') -eq 'elevenlabs,edge') ($order -join ',')
$ecfg.engine = 'sapi'
Check 'sapi: ningun motor con audio' (@(Get-EngineOrder $ecfg).Count -eq 0) ''
$ecfg.engine = 'raro'
Check 'motor desconocido: edge' ((@(Get-EngineOrder $ecfg) -join ',') -eq 'edge') ''
Check 'ElevenLabs: voz del mismo genero (mujer)' ((Get-ElevenVoiceId $ecfg 'es-CO-SalomeNeural') -eq 'F1') (Get-ElevenVoiceId $ecfg 'es-CO-SalomeNeural')
Check 'ElevenLabs: otra mujer, otra voz' ((Get-ElevenVoiceId $ecfg 'es-MX-DaliaNeural') -eq 'F2') (Get-ElevenVoiceId $ecfg 'es-MX-DaliaNeural')
Check 'ElevenLabs: hombre' ((Get-ElevenVoiceId $ecfg 'es-MX-JorgeNeural') -eq 'M1') (Get-ElevenVoiceId $ecfg 'es-MX-JorgeNeural')
Check 'Gemini: voz por genero' ((Get-GeminiVoiceName $ecfg 'es-CO-GonzaloNeural') -eq 'Puck') (Get-GeminiVoiceName $ecfg 'es-CO-GonzaloNeural')
$resp = [pscustomobject]@{ steps = @([pscustomobject]@{ type = 'model_output'; content = @([pscustomobject]@{ type = 'text'; text = 'x' }, [pscustomobject]@{ type = 'audio'; data = 'QUJD' }) }) }
Check 'Gemini: audio de la respuesta' ((Get-GeminiAudioData $resp) -eq 'QUJD') ''
Check 'ElevenLabs sin clave: no genera nada' (-not (New-ElevenAudio $ecfg 'hola' 'es-CO-SalomeNeural' (Join-Path $env:TEMP 'x.mp3'))) ''
Check 'motor sin apartar' (-not (Test-EngineSnoozed 'elevenlabs')) ''
Set-EngineSnooze 'elevenlabs' 10 'prueba'
Check 'motor apartado tras quedarse sin creditos' (Test-EngineSnoozed 'elevenlabs') ''

Remove-Item $tmp -Recurse -Force
Remove-Item $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue
$env:TEMP = $realTemp

''
if ($script:failed) { "$script:failed prueba(s) fallaron"; exit 1 } else { 'Todas las pruebas pasan' }
