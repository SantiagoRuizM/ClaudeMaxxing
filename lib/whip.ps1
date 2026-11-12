# Claude Whip: when the Claude plan runs low, Claude Code only reads, plans and hands the work to other agents (Codex,
# Antigravity CLI, OpenCode, Copilot CLI), so the plan lasts. The tray keeps the switch, the threshold and the agents in
# whip.json; the whip\ plugin (loaded in every session through CLAUDE_CODE_PLUGIN_DIRS) reads it with usage.json on
# each prompt and tool call: past the threshold it blocks editing and adds the director note to each prompt.
# Needs common.ps1 only (tests). Keep this file ASCII.

$WhipFile = Join-Path $TrayHome 'whip.json'
# 0 = always on.
$script:WhipThresholds = @(0, 70, 80, 85, 90, 95)
$script:WhipAgents = @(
    @{ Id = 'codex'; Label = 'Codex'; Vendor = 'OpenAI'; Install = 'npm i -g @openai/codex'
        Note = 'Cambios de c\u00f3digo, en el sandbox del proyecto (workspace-write).' },
    @{ Id = 'agy'; Label = 'Antigravity CLI'; Vendor = 'Google'; Install = 'antigravity.google (incluye agy)'
        Note = 'Cambios grandes en muchos archivos y segunda opini\u00f3n.' },
    @{ Id = 'opencode'; Label = 'OpenCode'; Vendor = 'opencode.ai'; Install = 'npm i -g opencode-ai'
        Note = 'Segunda opini\u00f3n, con el modelo que tengas configurado.' },
    @{ Id = 'copilot'; Label = 'Copilot CLI'; Vendor = 'GitHub'; Install = 'npm i -g @github/copilot'
        Note = 'Segunda opini\u00f3n, con tu cuenta de GitHub Copilot.' }
)

# @{ Enabled; Threshold; Agents } with the defaults for a missing or damaged file; unknown agents are dropped.
function Get-WhipSettings([string]$Path = $WhipFile) {
    $saved = Read-JsonFile $Path
    $known = @($script:WhipAgents | ForEach-Object { $_.Id })
    $threshold = 85
    if ($saved -and $null -ne $saved.threshold -and ($script:WhipThresholds -contains [int]$saved.threshold)) { $threshold = [int]$saved.threshold }
    [pscustomobject]@{
        Enabled = [bool]($saved -and $saved.enabled)
        Threshold = $threshold
        Agents = @(@($(if ($saved) { $saved.agents })) | Where-Object { $known -contains $_ } | ForEach-Object { [string]$_ })
    }
}

function Save-WhipSettings($Settings, [string]$Path = $WhipFile) {
    Write-JsonFile $Path ([ordered]@{ enabled = [bool]$Settings.Enabled; threshold = [int]$Settings.Threshold; agents = @($Settings.Agents) })
}

# The agents with whether each CLI is on PATH (a PATH lookup each: called on the window's slow refresh only).
function Get-WhipAgentStates {
    foreach ($agent in $script:WhipAgents) {
        [pscustomobject]@{ Id = $agent.Id; Label = $agent.Label; Vendor = $agent.Vendor; Install = $agent.Install; Note = (Tx $agent.Note)
            Installed = [bool](Get-Command $agent.Id -CommandType Application -ErrorAction SilentlyContinue) }
    }
}

# The threshold $Delta steps away, wrapping around.
function Step-WhipThreshold([int]$Current, [int]$Delta) {
    $list = $script:WhipThresholds
    $i = [Array]::IndexOf($list, $Current)
    if ($i -lt 0) { $i = [Array]::IndexOf($list, 85) }
    $list[($i + $Delta + $list.Count) % $list.Count]
}

function Format-WhipThreshold([int]$Threshold) { if ($Threshold -le 0) { 'Siempre' } else { "Desde $Threshold%" } }

# 'off' (switched off), 'noagent' (on with no agent), 'armed' (on, under the threshold) or 'active': what the plugin
# does now. $Percent is the plan's highest window, as the plugin computes it.
function Get-WhipMode($Settings, [int]$Percent) {
    if (-not $Settings.Enabled) { return 'off' }
    if (-not @($Settings.Agents).Count) { return 'noagent' }
    if ($Percent -ge $Settings.Threshold) { 'active' } else { 'armed' }
}

# A company policy that turns the module off also turns off a switch left on (the plugin only reads whip.json).
function Sync-WhipPolicy([bool]$Allowed, [string]$Path = $WhipFile) {
    if ($Allowed) { return $false }
    $settings = Get-WhipSettings $Path
    if (-not $settings.Enabled) { return $false }
    $settings.Enabled = $false
    Save-WhipSettings $settings $Path
    $true
}
