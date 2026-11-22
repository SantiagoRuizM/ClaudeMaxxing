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
    # The phone app (lib\mobile.ps1) writes to this session through Claude Code's cross-session inbox: its pipe and
    # token, which only this session's hooks see. Under the user's profile, like the rest of usage-tray.
    $inboxPipe = $env:CLAUDE_CODE_MESSAGING_SOCKET
    if ($inboxPipe -and $env:CLAUDE_CODE_MESSAGING_TOKEN -and "$($evt.session_id)" -match '^[0-9a-fA-F-]{36}$') {
        $inboxDir = Join-Path $env:USERPROFILE '.claude\usage-tray\mobile\inbox'
        if (-not (Test-Path -LiteralPath $inboxDir)) { New-Item -ItemType Directory -Force -Path $inboxDir | Out-Null }
        $inboxJson = ConvertTo-Json -InputObject ([ordered]@{ socket = $inboxPipe; token = $env:CLAUDE_CODE_MESSAGING_TOKEN }) -Compress
        [IO.File]::WriteAllText((Join-Path $inboxDir "$($evt.session_id).json"), $inboxJson, $Utf8)
    }
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
    # Menu sessions: the tab shows the name without Claude Code's spark (after the JSON above).
    Set-SessionTerminalTitle $info
} catch {
    Write-Log "on-start: $_"
}
exit 0
