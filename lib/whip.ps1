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

# @{ Enabled; Threshold; Agents; Forecast } with the defaults for a missing or damaged file; unknown agents are dropped.
function Get-WhipSettings([string]$Path = $WhipFile) {
    $saved = Read-JsonFile $Path
    $known = @($script:WhipAgents | ForEach-Object { $_.Id })
    $threshold = 85
    if ($saved -and $null -ne $saved.threshold -and ($script:WhipThresholds -contains [int]$saved.threshold)) { $threshold = [int]$saved.threshold }
    [pscustomobject]@{
        Enabled = [bool]($saved -and $saved.enabled)
        Threshold = $threshold
        # Also on before the threshold when the window is on pace to run out: off unless switched on.
        Forecast = [bool]($saved -and $saved.forecast)
        Agents = @(@($(if ($saved) { $saved.agents })) | Where-Object { $known -contains $_ } | ForEach-Object { [string]$_ })
    }
}

function Save-WhipSettings($Settings, [string]$Path = $WhipFile) {
    Write-JsonFile $Path ([ordered]@{ enabled = [bool]$Settings.Enabled; threshold = [int]$Settings.Threshold; agents = @($Settings.Agents); forecast = [bool]$Settings.Forecast })
}

# The agents with whether each CLI is on PATH and its account (a PATH lookup and a few small files each: called on the
# window's slow refresh only).
function Get-WhipAgentStates([string]$HomeDir = $env:USERPROFILE) {
    foreach ($agent in $script:WhipAgents) {
        [pscustomobject]@{ Id = $agent.Id; Label = $agent.Label; Vendor = $agent.Vendor; Install = $agent.Install; Note = (Tx $agent.Note)
            Installed = [bool](Get-Command $agent.Id -CommandType Application -ErrorAction SilentlyContinue)
            Account = (Get-WhipAgentAccount $agent.Id $HomeDir) }
    }
}

$WhipCopilotFile = Join-Path $TrayHome 'whip-copilot.json'

function New-WhipAccount([string]$Text, [string]$Tone = 'muted') { [pscustomobject]@{ Text = (Tx $Text); Tone = $Tone } }

function Format-WhipDay($Value) { ([datetime]$Value).ToString('d MMM', $UiCulture).TrimEnd('.') }

# A JWT's claims, or $null.
function ConvertFrom-WhipJwt([string]$Token) {
    try {
        $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $part += '=' * ((4 - $part.Length % 4) % 4)
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    } catch { $null }
}

# Each agent's login as its own CLI keeps it: account, plan and until when, with Tone ok|warn|muted. Only local files,
# except Copilot's plan: a hidden `gh api` refreshed every 6 hours into $CopilotCache, read on the next refresh.
# shortcut: the default homes only (no CODEX_HOME, XDG_DATA_HOME), add them if someone moves them.
function Get-WhipAgentAccount([string]$Id, [string]$HomeDir = $env:USERPROFILE, [string]$CopilotCache = $WhipCopilotFile, [datetime]$Now = (Get-Date)) {
    switch ($Id) {
        'codex' {
            $auth = Read-JsonFile (Join-Path $HomeDir '.codex\auth.json')
            if (-not $auth) { return New-WhipAccount 'Sin sesi\u00f3n: ejecuta codex login' 'warn' }
            if (-not $auth.tokens -or -not $auth.tokens.id_token) { return New-WhipAccount 'Con clave de API (pago por uso)' }
            $claims = ConvertFrom-WhipJwt $auth.tokens.id_token
            $sub = if ($claims) { $claims.'https://api.openai.com/auth' }
            $plan = if ($sub -and $sub.chatgpt_plan_type) { [string]$sub.chatgpt_plan_type } else { '' }
            $text = @([string]$claims.email, $(if ($plan) { (L 'ChatGPT ') + (Get-Culture).TextInfo.ToTitleCase($plan) }) | Where-Object { $_ }) -join ' \u00b7 '
            if (-not $sub -or -not $sub.chatgpt_subscription_active_until -or $plan -eq 'free') { return New-WhipAccount $text $(if ($plan -eq 'free') { 'warn' } else { 'muted' }) }
            $until = [datetime]$sub.chatgpt_subscription_active_until
            if ($until -lt $Now) { return New-WhipAccount ((Tx '{0} \u00b7 venci\u00f3 el {1}') -f $text, (Format-WhipDay $until)) 'warn' }
            return New-WhipAccount ((Tx '{0} \u00b7 hasta el {1}') -f $text, (Format-WhipDay $until)) 'ok'
        }
        'agy' {
            # agy keeps its token in the Credential Manager; the Google account it signed in with is in ~/.gemini.
            $accounts = Read-JsonFile (Join-Path $HomeDir '.gemini\google_accounts.json')
            if (-not $accounts -or -not $accounts.active) { return New-WhipAccount 'Sin sesi\u00f3n: abre agy e inicia sesi\u00f3n' 'warn' }
            return New-WhipAccount ((Tx '{0} \u00b7 el plan solo se ve en agy') -f $accounts.active)
        }
        'opencode' {
            $auth = Read-JsonFile (Join-Path $HomeDir '.local\share\opencode\auth.json')
            $providers = @(if ($auth) { $auth.PSObject.Properties | ForEach-Object { if ($_.Value.type -eq 'oauth') { (L '{0} (cuenta)') -f $_.Name } else { (L '{0} (clave)') -f $_.Name } } })
            if (-not $providers.Count) { return New-WhipAccount 'Sin cuentas: solo modelos gratis (opencode auth login)' }
            return New-WhipAccount ((L 'Conectado a ') + ($providers -join ', ')) 'ok'
        }
        'copilot' {
            $configFile = Join-Path $HomeDir '.copilot\config.json'
            $login = $null
            # config.json starts with // comments.
            if (Test-Path -LiteralPath $configFile) { try { $login = ((Get-Content -LiteralPath $configFile -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json).lastLoggedInUser.login } catch { } }
            if (-not $login) { return New-WhipAccount 'Sin sesi\u00f3n: abre copilot y usa /login' 'warn' }
            $cache = Read-JsonFile $CopilotCache
            $fresh = (Test-Path -LiteralPath $CopilotCache) -and ($Now - (Get-Item -LiteralPath $CopilotCache).LastWriteTime).TotalHours -lt 6
            if (-not $fresh -and (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
                try { Start-Process gh -ArgumentList 'api', '/copilot_internal/user' -RedirectStandardOutput $CopilotCache -RedirectStandardError "$CopilotCache.err" -WindowStyle Hidden | Out-Null } catch { }
            }
            # gh's account may not be the one Copilot CLI signed in with: the plan is shown only when they match.
            if (-not $cache -or $cache.login -ne $login) { return New-WhipAccount "@$login" }
            # shortcut: SKU names seen so far (free_limited_copilot, *_subscriber); an unknown individual one reads as Pro.
            $sku = [string]$cache.access_type_sku
            $plan = if ($cache.copilot_plan -match 'business|enterprise') { (Get-Culture).TextInfo.ToTitleCase([string]$cache.copilot_plan) }
                elseif ($sku -match 'free_limited') { 'Free' } elseif ($sku -match 'plus') { 'Pro+' } elseif ($sku -match 'educ') { 'Pro (educativo)' } else { 'Pro' }
            $text = "@$login \u00b7 Copilot $plan"
            if ($cache.quota_reset_date) { $text += (Tx ' \u00b7 la cuota se renueva el {0}') -f (Format-WhipDay $cache.quota_reset_date) }
            return New-WhipAccount $text $(if ($plan -eq 'Free') { 'warn' } else { 'ok' })
        }
    }
    New-WhipAccount ''
}

# The threshold $Delta steps away, wrapping around.
function Step-WhipThreshold([int]$Current, [int]$Delta) {
    $list = $script:WhipThresholds
    $i = [Array]::IndexOf($list, $Current)
    if ($i -lt 0) { $i = [Array]::IndexOf($list, 85) }
    $list[($i + $Delta + $list.Count) % $list.Count]
}

function Format-WhipThreshold([int]$Threshold) { if ($Threshold -le 0) { 'Siempre' } else { (L 'Desde {0}%') -f $Threshold } }

# The open window's forecast for the plugin (whip-forecast.json): it turns the whip on before the threshold when the
# window is on pace to hit its limit. Same rule as forecastHit in whip\hooks\rules.ts: from half the plan, while fresh.
$WhipForecastFile = Join-Path $TrayHome 'whip-forecast.json'
$WhipForecastFloor = 50
$WhipForecastMaxAge = 15 * 60

# $Forecast: Get-UsageForecast's result (lib\forecast.ps1), or $null to remove it.
function Save-WhipForecast($Forecast, [datetime]$Now, [string]$Path = $WhipForecastFile) {
    if (-not $Forecast -or $null -eq $Forecast.ProjectedPercent) { Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue; return }
    Write-JsonFile $Path ([ordered]@{
        projectedPercent = [int][Math]::Round([double]$Forecast.ProjectedPercent)
        limitAt = $(if ($Forecast.LimitAt) { ([datetime]$Forecast.LimitAt).ToString('HH:mm') } else { '' })
        at = ([DateTimeOffset]$Now).ToUnixTimeSeconds()
    })
}

function Test-WhipForecastHit($Forecast, [int]$Percent, [datetime]$Now) {
    if (-not $Forecast -or $null -eq $Forecast.projectedPercent -or $null -eq $Forecast.at) { return $false }
    [int]$Forecast.projectedPercent -ge 100 -and $Percent -ge $WhipForecastFloor -and
        (([DateTimeOffset]$Now).ToUnixTimeSeconds() - [long]$Forecast.at) -le $WhipForecastMaxAge
}

# 'off' (switched off), 'noagent' (on with no agent), 'armed' (on, under the threshold), 'active', or 'forecast'
# (under the threshold, on pace to hit the limit): what the plugin does now. $Percent is the plan's highest window,
# as the plugin computes it; $Forecast what Read-JsonFile gives for whip-forecast.json.
function Get-WhipMode($Settings, [int]$Percent, $Forecast = $null, [datetime]$Now = (Get-Date)) {
    if (-not $Settings.Enabled) { return 'off' }
    if (-not @($Settings.Agents).Count) { return 'noagent' }
    if ($Percent -ge $Settings.Threshold) { return 'active' }
    if ($Settings.Forecast -and (Test-WhipForecastHit $Forecast $Percent $Now)) { 'forecast' } else { 'armed' }
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
