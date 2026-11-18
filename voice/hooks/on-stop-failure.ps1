# StopFailure hook: the turn ended on an API error (usage limit reached, rate limit, overload...) and Stop does not run.
# The tab's title loses its working mark (on-prompt.ps1 set it), so the session's egg stops thinking.
. "$PSScriptRoot\common.ps1"

try {
    $evt = Read-HookInput
    if ($evt) {
        Write-Log "stop failure: $($evt.error)"
        Set-SessionTerminalTitle (Get-SessionName $evt.session_id)
    }
} catch {
    Write-Log "stop failure: $_"
}
exit 0
