# Background job for "Ahorro de tokens" (lib\maxx.ps1): installs, enables or disables context-mode with the
# claude CLI, and installs the skill and MCP creation packages of "Skills y MCP" (pack-install -Plugin, from
# Anthropic's official marketplace) and the team kit of the business edition (team-install: the marketplaces and
# plugins of the company policy, lib\business.ps1); reports in maxx-status.json. Started hidden from the window.
param([Parameter(Mandatory = $true)][ValidateSet('contextmode-on', 'contextmode-off', 'pack-install', 'team-install')][string]$Action,
    [ValidatePattern('^[a-z0-9-]+@claude-plugins-official$')][string]$Plugin)

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\maxx.ps1')
Clear-ClaudeSessionEnv

function Set-Status([string]$State, [string]$Message) {
    Write-JsonFile $MaxxStatusFile ([ordered]@{ action = $Action; plugin = $Plugin; state = $State; message = $Message; at = (Get-Date).ToString('o') })
}

function Invoke-Claude([string[]]$Arguments) {
    $config = Read-JsonFile $ConfigFile
    $claude = if ($config -and $config.claudePath -and (Test-Path -LiteralPath $config.claudePath)) { [string]$config.claudePath } else { 'claude' }
    $output = & $claude @Arguments 2>&1 | Out-String
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = $output.Trim() }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeTrayMaxx')
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }
try {
    if ($Action -eq 'team-install') {
        # Read here, not passed in: only what the policy file says gets installed.
        . (Join-Path $TrayRoot 'lib\business.ps1')
        $policy = (Get-BusinessState).Policy
        foreach ($source in @($policy.marketplaces)) {
            if (-not (Test-MarketplaceSource $source)) { throw "marketplace no v$([char]0x00E1)lido en la pol$([char]0x00ED)tica: $source" }
            $r = Invoke-Claude @('plugin', 'marketplace', 'add', $source)
            if (-not $r.Ok -and $r.Output -notmatch 'already') { throw "marketplace $source`: $($r.Output)" }
        }
        $count = 0
        foreach ($ref in @($policy.plugins)) {
            if (-not (Test-PluginRef $ref)) { throw "plugin no v$([char]0x00E1)lido en la pol$([char]0x00ED)tica: $ref" }
            $r = Invoke-Claude @('plugin', 'install', $ref)
            if (-not $r.Ok -and $r.Output -match 'already') { $r = Invoke-Claude @('plugin', 'enable', $ref) }
            if (-not $r.Ok -and $r.Output -notmatch 'already') { throw "$ref`: $($r.Output)" }
            $count++
        }
        Set-Status 'done' "Kit del equipo: $count plugin(s) listos para las sesiones nuevas."
        return
    }
    if ($Action -eq 'pack-install') {
        if (-not $Plugin) { throw 'no plugin given' }
        $r = Invoke-Claude @('plugin', 'marketplace', 'add', 'anthropics/claude-plugins-official')
        if (-not $r.Ok -and $r.Output -notmatch 'already') { throw "marketplace: $($r.Output)" }
        $r = Invoke-Claude @('plugin', 'install', $Plugin)
        if (-not $r.Ok -and $r.Output -match 'already') { $r = Invoke-Claude @('plugin', 'enable', $Plugin) }
        if (-not $r.Ok -and $r.Output -notmatch 'already') { throw "install: $($r.Output)" }
        Set-Status 'done' ($Plugin.Split('@')[0] + ' instalado: se usa en las sesiones nuevas.')
        return
    }
    $state = Get-ContextModeState
    if ($Action -eq 'contextmode-on') {
        if (-not $state.Installed) {
            $r = Invoke-Claude @('plugin', 'marketplace', 'add', $ContextModeRepo)
            if (-not $r.Ok -and $r.Output -notmatch 'already') { throw "marketplace: $($r.Output)" }
            $r = Invoke-Claude @('plugin', 'install', $ContextModePlugin)
            if (-not $r.Ok) { throw "install: $($r.Output)" }
        } elseif (-not $state.Enabled) {
            $r = Invoke-Claude @('plugin', 'enable', $ContextModePlugin)
            if (-not $r.Ok) { throw "enable: $($r.Output)" }
        }
        Set-Status 'done' 'context-mode activado: se aplica en las sesiones nuevas.'
    } else {
        if ($state.Enabled) {
            $r = Invoke-Claude @('plugin', 'disable', $ContextModePlugin)
            if (-not $r.Ok) { throw "disable: $($r.Output)" }
        }
        Set-Status 'done' 'context-mode desactivado para las sesiones nuevas.'
    }
} catch {
    $message = $_.Exception.Message
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }
    $what = if ($Action -eq 'pack-install') { 'instalar ' + $Plugin.Split('@')[0] } elseif ($Action -eq 'team-install') { 'instalar el kit del equipo' } else { 'cambiar context-mode' }
    Set-Status 'error' ('No se pudo ' + $what + ': ' + $message)
} finally {
    $mutex.ReleaseMutex()
}
