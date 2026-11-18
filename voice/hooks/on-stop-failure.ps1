# StopFailure hook: the turn ended on an API error (usage limit reached, rate limit, overload...) and Stop does not run.
# The tab's title loses its working mark (on-prompt.ps1 set it), so the session's egg stops thinking. When the error is
# the plan's limit, the voice says so and when the plan comes back, instead of the turn ending in silence.
. "$PSScriptRoot\common.ps1"

try {
    $evt = Read-HookInput
    if ($evt) {
        Write-Log "stop failure: $($evt.error)"
        Set-SessionTerminalTitle (Get-SessionName $evt.session_id)
        $cfg = Get-VoiceConfig
        if ("$($evt.error)" -match 'rate_limit' -and (Get-Opt $cfg 'enabled' $true) -and -not (Test-Muted $evt.session_id)) {
            $notice = Get-PlanLimitNotice
            if ($notice) { Start-Utterance $notice $evt.session_id }
        }
    }
} catch {
    Write-Log "stop failure: $_"
}
exit 0
