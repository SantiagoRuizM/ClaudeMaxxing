# Hook SessionStart (sincrono), solo en las sesiones abiertas desde el menu del Explorador (lo carga
# el plugin de voice\plugin con --plugin-dir):
#   - anade la regla del resumen hablado (templates\claude-md-rule.md) al contexto de la sesion,
#     en lugar de escribirla en un CLAUDE.md;
#   - si la sesion ya tiene nombre (reservado por open-session.ps1, o de antes si se reanuda),
#     lo pone como titulo: aparece en la caja del prompt, la pestana y /resume.
. "$PSScriptRoot\common.ps1"

try {
    $evt = Read-HookInput
    if (-not $evt) { exit 0 }
    $cfg = Get-VoiceConfig
    if (-not (Get-Opt $cfg 'enabled' $true)) { exit 0 }

    $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart' } }
    $rule = Join-Path $Root 'templates\claude-md-rule.md'
    if (Test-Path -LiteralPath $rule) {
        $out.hookSpecificOutput.additionalContext = [IO.File]::ReadAllText($rule, $Utf8).Trim()
    }
    $info = Get-SessionName $evt.session_id
    if ($info -and (Get-Opt $cfg 'naming.enabled' $true) -and (Get-Opt $cfg 'naming.setTitle' $true)) {
        $out.hookSpecificOutput.sessionTitle = "$($info.title)"
    }
    Write-HookOutput $out
} catch {
    Write-Log "on-start: $_"
}
exit 0
