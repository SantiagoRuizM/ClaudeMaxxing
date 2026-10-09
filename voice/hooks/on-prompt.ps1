# Hook UserPromptSubmit (sincrono):
#   - corta el audio de ESTA sesion cuando escribes un mensaje nuevo (las demas siguen);
#   - en el primer prompt de la sesion le pone nombre: nombre aleatorio del genero de su voz
#     + rol segun lo que pediste. Lo devuelve como sessionTitle (igual que /rename) y lo
#     muestra una vez con systemMessage.
#   - si la sesion se abrio desde el menu (open-session.ps1), ya tiene nombre y voz: el primer
#     prompt que no sea un comando (/...) solo decide el rol y completa el titulo.
# Solo escribe JSON en stdout cuando nombra; cualquier otro texto se anadiria al prompt.
. "$PSScriptRoot\common.ps1"

function Get-NamingNotice($Info) {
    $mic = [char]::ConvertFromUtf32(0x1F399)
    $sesion = 'sesi' + [char]0x00F3 + 'n'
    '{0} Esta {1} es {2} ({3}), voz {4}' -f $mic, $sesion, $Info.name, $Info.role, $Info.voice
}

try {
    $evt = Read-HookInput
    if (-not $evt) { exit 0 }
    $cfg = Get-VoiceConfig
    if (Get-Opt $cfg 'stopOnPrompt' $true) { Stop-Playback $evt.session_id }
    if (-not (Get-Opt $cfg 'naming.enabled' $true)) { exit 0 }

    $key = Get-SessionKey $evt.session_id
    $info = Get-SessionName $evt.session_id
    if (-not $info) {
        $info = New-SessionName $cfg $evt.session_id $evt.prompt
        $out = [ordered]@{
            systemMessage      = Get-NamingNotice $info
            hookSpecificOutput = [ordered]@{ hookEventName = 'UserPromptSubmit' }
        }
        # Si ya tiene un titulo propio (--name, /rename) no se pisa.
        if (-not $evt.session_title -and (Get-Opt $cfg 'naming.setTitle' $true)) {
            $out.hookSpecificOutput.sessionTitle = $info.title
        }
        Write-HookOutput $out
        Write-Log ('name {0}: {1}' -f $key.Substring(0, [Math]::Min(8, $key.Length)), $info.title)
    } elseif ($info.pendingRole -and "$($evt.prompt)".TrimStart() -notmatch '^/') {
        # El titulo actual es el nombre que puso SessionStart, asi que se puede completar.
        $info = Complete-SessionRole $cfg $evt.session_id $info $evt.prompt
        $out = [ordered]@{
            systemMessage      = Get-NamingNotice $info
            hookSpecificOutput = [ordered]@{ hookEventName = 'UserPromptSubmit' }
        }
        if (Get-Opt $cfg 'naming.setTitle' $true) { $out.hookSpecificOutput.sessionTitle = $info.title }
        Write-HookOutput $out
        Write-Log ('role {0}: {1}' -f $key.Substring(0, [Math]::Min(8, $key.Length)), $info.title)
    }
} catch {
    Write-Log "on-prompt: $_"
}
exit 0
