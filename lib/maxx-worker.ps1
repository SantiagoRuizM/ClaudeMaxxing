# Background job for "Ahorro de tokens" (lib\maxx.ps1): installs, enables or disables context-mode with the
# claude CLI, and reports in maxx-status.json. Started hidden from the ClaudeMaxxing window.
param([Parameter(Mandatory = $true)][ValidateSet('contextmode-on', 'contextmode-off')][string]$Action)

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\maxx.ps1')
Clear-ClaudeSessionEnv

function Set-Status([string]$State, [string]$Message) {
    Write-JsonFile $MaxxStatusFile ([ordered]@{ action = $Action; state = $State; message = $Message; at = (Get-Date).ToString('o') })
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
    Set-Status 'error' ('No se pudo cambiar context-mode: ' + $message)
} finally {
    $mutex.ReleaseMutex()
}
