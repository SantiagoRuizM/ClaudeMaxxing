# Hook UserPromptSubmit (sincrono):
#   - corta el audio de ESTA sesion cuando escribes un mensaje nuevo (las demas siguen);
#   - en el primer prompt de la sesion le pone nombre: nombre aleatorio del genero de su voz
#     + rol segun lo que pediste. Lo devuelve como sessionTitle (igual que /rename) y lo
#     muestra una vez con systemMessage.
# Solo escribe JSON en stdout la primera vez; cualquier otro texto se anadiria al prompt.
. "$PSScriptRoot\common.ps1"

try {
    $evt = Read-HookInput
    if (-not $evt) { exit 0 }
    $cfg = Get-VoiceConfig
    if (Get-Opt $cfg 'stopOnPrompt' $true) { Stop-Playback $evt.session_id }

    if ((Get-Opt $cfg 'naming.enabled' $true) -and -not (Get-SessionName $evt.session_id)) {
        $info = New-SessionName $cfg $evt.session_id $evt.prompt
        $mic = [char]::ConvertFromUtf32(0x1F399)
        $sesion = 'sesi' + [char]0x00F3 + 'n'
        $out = [ordered]@{
            systemMessage      = '{0} Esta {1} es {2} ({3}), voz {4}' -f $mic, $sesion, $info.name, $info.role, $info.voice
            hookSpecificOutput = [ordered]@{ hookEventName = 'UserPromptSubmit' }
        }
        # Si ya tiene un titulo propio (--name, /rename) no se pisa.
        if (-not $evt.session_title -and (Get-Opt $cfg 'naming.setTitle' $true)) {
            $out.hookSpecificOutput.sessionTitle = $info.title
        }
        Write-HookOutput $out
        $key = Get-SessionKey $evt.session_id
        Write-Log ('name {0}: {1}' -f $key.Substring(0, [Math]::Min(8, $key.Length)), $info.title)
    }
} catch {
    Write-Log "on-prompt: $_"
}
exit 0
