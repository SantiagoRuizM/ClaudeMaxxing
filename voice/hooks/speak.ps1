# Hook Stop de Claude Code: toma last_assistant_message, extrae la linea de resumen
# y la lee en voz alta con la voz de esta sesion: firma musical + "Soy <nombre>, <rol>. <mensaje>".
# Sale de inmediato; el audio corre en otro proceso (play.ps1).
. "$PSScriptRoot\common.ps1"

try {
    $evt = Read-HookInput
    # The turn is over: the tab's title loses its working mark (on-prompt.ps1 set it), voice or not.
    try { Set-SessionTerminalTitle (Get-SessionName $evt.session_id) } catch { Write-Log "title: $_" }
    $cfg = Get-VoiceConfig
    if (-not (Get-Opt $cfg 'enabled' $true) -or (Test-Muted $evt.session_id)) { exit 0 }

    $text = Get-SpokenText $evt.last_assistant_message $cfg
    if (-not $text) { exit 0 }

    $info = Get-SessionName $evt.session_id
    if (-not $info -and (Get-Opt $cfg 'naming.enabled' $true) -and (Get-SessionKey $evt.session_id) -ne 'manual') {
        # Sesion que empezo antes de instalar el hook de nombres: nombre sin rol conocido.
        $info = New-SessionName $cfg $evt.session_id ''
    }
    # announceFormat: "Soy {name}, {role}. {text}" (tambien {project}). Sin nombre, solo el texto.
    $format = Get-Opt $cfg 'announceFormat' '{text}'
    if ($info) {
        $project = if ($evt.cwd) { Split-Path -Leaf $evt.cwd } else { '' }
        # Sesion del menu que aun no tuvo un prompt normal (solo comandos /...): rol por defecto.
        $role = "$($info.role)"
        if (-not $role) { $role = "$((Get-Opt $cfg 'naming.defaultRole' ([pscustomobject]@{ f = 'asistente'; m = 'asistente' })).("$($info.gender)"))" }
        $text = $format.Replace('{name}', "$($info.name)").Replace('{role}', $role).Replace('{project}', $project).Replace('{text}', $text)
    }
    # Antes de hablar: la bandeja busca el huevo de esta ventana por su id de origen (cambia con /clear).
    try { Save-SessionOrigin $evt.session_id } catch { Write-Log "origin: $_" }
    Start-Utterance $text $evt.session_id
} catch {
    Write-Log "speak: $_"
}
exit 0
