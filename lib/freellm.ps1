# FreeLLMAPI (github.com/tashfeenahmed/freellmapi): a local server that pools the free tiers of many LLM
# providers behind one endpoint, including Anthropic's Messages API. When it is switched on in the
# ClaudeMaxxing window, the sessions open-session.ps1 opens talk to it instead of the Claude plan (for when
# the quota runs out). Only those sessions: nothing global changes (settings.json, the scheduled warm-up
# and the sessions already open keep using the plan).
# The desktop app is installed on demand from the hub (lib\freellm-install.ps1), never by install.ps1.
# Keep this file ASCII.

$FreeLlmFile        = Join-Path $TrayHome 'freellm.json'
$FreeLlmInstallFile = Join-Path $TrayHome 'freellm-install.json'
$FreeLlmDownloadDir = Join-Path $TrayHome 'freellm'
# The version that was tested here, and the sha512 of its installer (from the release's latest.yml).
$FreeLlmVersion     = '0.16.5'
$FreeLlmSetupName   = "FreeLLMAPI-Setup-$FreeLlmVersion.exe"
$FreeLlmSetupUrl    = "https://github.com/tashfeenahmed/freellmapi/releases/download/v$FreeLlmVersion/$FreeLlmSetupName"
$FreeLlmSetupSha512 = 'n23Krjd8ypYgu/3zWJxPR9o6aakvBsPA7q/YowImR//uqBAuCvXvyVfykd6HyqfBiDAysVRB6iWa4H1WaP0kHw=='
# The desktop app listens on 127.0.0.1:31415 and, when that port is taken, on the next free one up to +50;
# the port it ended up on is saved in its config.json.
$FreeLlmDefaultPort = 31415
$FreeLlmConfigFile  = Join-Path $env:APPDATA 'FreeLLMAPI\config.json'

# { enabled; key } from freellm.json.
function Get-FreeLlmSettings {
    $saved = Read-JsonFile $FreeLlmFile
    [pscustomobject]@{
        Enabled = [bool]($saved -and $saved.enabled)
        Key = $(if ($saved -and $saved.key) { [string]$saved.key } else { '' })
    }
}

function Save-FreeLlmSettings([bool]$Enabled, [string]$Key) {
    Write-JsonFile $FreeLlmFile ([ordered]@{ enabled = $Enabled; key = $Key })
}

# The unified key the FreeLLMAPI dashboard shows ("freellmapi-" and 48 hex digits). Only letters, digits,
# '-' and '_' are accepted: the key goes into a cmd.exe command line.
function Test-FreeLlmKeyFormat([string]$Key) {
    [bool]($Key -cmatch '^freellmapi-[A-Za-z0-9_-]{16,128}$')
}

function Get-FreeLlmPort([string]$ConfigPath = $FreeLlmConfigFile) {
    $config = Read-JsonFile $ConfigPath
    $port = 0
    if ($config -and $config.port) { try { $port = [int]$config.port } catch { $port = 0 } }
    if ($port -ge 1 -and $port -le 65535) { return $port }
    $FreeLlmDefaultPort
}

function Get-FreeLlmBaseUrl([int]$Port) { "http://127.0.0.1:$Port" }

# The installed FreeLLMAPI.exe, or $null. The installer is per-user: the usual folder first, then its uninstall
# entry. -Quick skips the registry (about 60 ms), for the hub's periodic refresh.
function Get-FreeLlmExe([switch]$Quick) {
    $usual = Join-Path $env:LOCALAPPDATA 'Programs\freellmapi-desktop\FreeLLMAPI.exe'
    if (Test-Path -LiteralPath $usual -PathType Leaf) { return $usual }
    if ($Quick) { return $null }
    $entries = @(Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { "$($_.DisplayName)" -like 'FreeLLMAPI*' })
    foreach ($props in $entries) {
        $candidates = @()
        if ($props.InstallLocation) { $candidates += Join-Path ([string]$props.InstallLocation).Trim('"') 'FreeLLMAPI.exe' }
        if ($props.DisplayIcon) { $candidates += (([string]$props.DisplayIcon) -replace ',\s*\d+$', '').Trim('"') }
        foreach ($path in $candidates) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    }
    $null
}

# True when something accepts connections on 127.0.0.1:$Port (a refused port answers at once).
function Test-FreeLlmUp([int]$Port, [int]$TimeoutMs = 300) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($connect)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Starts the desktop app if it is not answering and waits for it. Returns the port it answers on, or 0.
function Start-FreeLlm([int]$TimeoutSeconds = 25) {
    $port = Get-FreeLlmPort
    if (Test-FreeLlmUp $port) { return $port }
    $exe = Get-FreeLlmExe
    if (-not $exe) { return 0 }
    Start-Process -FilePath $exe -WindowStyle Minimized | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        # Read again: on its first start the app may have picked another port.
        $port = Get-FreeLlmPort
        if (Test-FreeLlmUp $port) { return $port }
    }
    0
}

# Asks the server for its model list with the key: Ok, Status ('ok', 'no-providers', 'bad-key', 'down',
# 'error') and the model ids. A list with only "auto" means no provider key has been added yet.
function Test-FreeLlmKey([int]$Port, [string]$Key) {
    $result = [pscustomobject]@{ Ok = $false; Status = 'error'; Models = @(); Error = '' }
    if (-not (Test-FreeLlmUp $Port)) { $result.Status = 'down'; return $result }
    try {
        $response = Invoke-RestMethod -Uri ((Get-FreeLlmBaseUrl $Port) + '/v1/models') -Headers @{ Authorization = "Bearer $Key" } -TimeoutSec 5 -UseBasicParsing
        $ids = @($response.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
        $result.Models = $ids
        $result.Ok = $true
        $result.Status = if (@($ids | Where-Object { $_ -ne 'auto' -and $_ -notlike 'auto:*' }).Count) { 'ok' } else { 'no-providers' }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        $result.Status = if ($code -eq 401 -or $code -eq 403) { 'bad-key' } else { 'error' }
        $result.Error = $_.Exception.Message
    }
    $result
}

# cmd.exe prefix that points one Claude Code run at FreeLLMAPI, as its own `freellmapi launch` does: the
# gateway URL (the root: Claude Code appends /v1/messages), the unified key as bearer token, no API key
# (so the real Anthropic credentials never reach the gateway) and model discovery from the gateway.
# Claude model names (opus, sonnet, haiku) map to FreeLLMAPI's "auto" router on the server side.
# Empty when the key or the url is not usable.
# No quotes and no space before '&&': wt.exe drops the quotes of `set "A=B"`, and cmd.exe would keep the
# space in the value. Without quotes the values must be free of cmd.exe metacharacters, hence the checks.
function Format-FreeLlmEnv([string]$BaseUrl, [string]$Key) {
    if ($BaseUrl -notmatch '^https?://[A-Za-z0-9.:/\[\]-]+$' -or -not (Test-FreeLlmKeyFormat $Key)) { return '' }
    $vars = [ordered]@{
        ANTHROPIC_BASE_URL = $BaseUrl
        ANTHROPIC_AUTH_TOKEN = $Key
        ANTHROPIC_API_KEY = ''
        CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
    }
    -join @($vars.Keys | ForEach-Object { 'set {0}={1}&& ' -f $_, $vars[$_] })
}

# What open-session.ps1 needs: Prefix (cmd.exe env, or '' for a normal session) and Notice (why it fell back).
function Get-FreeLlmLaunch {
    $settings = Get-FreeLlmSettings
    $launch = [pscustomobject]@{ Prefix = ''; Notice = ''; Port = 0 }
    if (-not $settings.Enabled) { return $launch }
    if (-not (Test-FreeLlmKeyFormat $settings.Key)) {
        $launch.Notice = Tx 'FreeLLMAPI est\u00e1 activado pero falta su clave: p\u00e9gala en ClaudeMaxxing > Claude Code. Abro la sesi\u00f3n con tu plan.'
        return $launch
    }
    $port = Start-FreeLlm
    if (-not $port) {
        $launch.Notice = Tx 'FreeLLMAPI no responde (\u00bfest\u00e1 instalado y abierto?). Abro la sesi\u00f3n con tu plan.'
        return $launch
    }
    $launch.Port = $port
    $launch.Prefix = Format-FreeLlmEnv (Get-FreeLlmBaseUrl $port) $settings.Key
    $launch
}

# Progress of the hub's "Instalar" button: { state = downloading|installing|done|error; message; at }.
function Get-FreeLlmInstallStatus { Read-JsonFile $FreeLlmInstallFile }
