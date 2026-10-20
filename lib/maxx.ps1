# "Ahorro de tokens" in ClaudeMaxxing > Claude Code: tools that make the plan last longer.
#   context-mode (github.com/mksglu/context-mode, Elastic License 2.0): a Claude Code plugin that keeps big
#   tool outputs out of the context window and remembers the session across compactions. Installed from
#   its own marketplace with `claude plugin`, never copied into this repo. Its optional statusline is not
#   used: the statusline belongs to the usage snapshot.
# The plugin commands run in lib\maxx-worker.ps1 (hidden), which reports in maxx-status.json.
# Keep this file ASCII.

$ContextModePlugin = 'context-mode@context-mode'
$ContextModeRepo   = 'mksglu/context-mode'
$MaxxStatusFile    = Join-Path $TrayHome 'maxx-status.json'

# Installed (in ~/.claude/plugins/installed_plugins.json) and enabled (~/.claude/settings.json).
function Get-ContextModeState([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $installed = $false
    $list = Read-JsonFile (Join-Path $ClaudeHome 'plugins\installed_plugins.json')
    if ($list -and $list.plugins -and $list.plugins.PSObject.Properties[$ContextModePlugin]) { $installed = $true }
    $enabled = $false
    $settings = Read-JsonFile (Join-Path $ClaudeHome 'settings.json')
    if ($installed -and $settings -and $settings.enabledPlugins) {
        $prop = $settings.enabledPlugins.PSObject.Properties[$ContextModePlugin]
        $enabled = [bool]($prop -and $prop.Value)
    }
    [pscustomobject]@{ Installed = $installed; Enabled = $enabled }
}

# The background job's last report: @{ action; state = running|done|error; message; at }. A running state
# older than 10 minutes is from a worker that died.
function Get-MaxxStatus {
    $status = Read-JsonFile $MaxxStatusFile
    if ($status -and $status.state -eq 'running') {
        try { if (((Get-Date) - [datetime]$status.at).TotalMinutes -gt 10) { $status.state = 'error'; $status.message = 'Se interrumpio.' } } catch { }
    }
    $status
}

# Runs lib\maxx-worker.ps1 hidden. Actions: contextmode-on, contextmode-off.
function Start-MaxxJob([string]$Action, [string]$Root = $TrayRoot) {
    Write-JsonFile $MaxxStatusFile ([ordered]@{ action = $Action; state = 'running'; message = ''; at = (Get-Date).ToString('o') })
    $worker = Join-Path $Root 'lib\maxx-worker.ps1'
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $worker, $Action) -WindowStyle Hidden
}
