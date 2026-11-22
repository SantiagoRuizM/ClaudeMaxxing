# Updates of the installed ClaudeMaxxing: asks GitHub for the latest release without blocking the tray, and installs
# it in a window of its own (lib\update-run.ps1, which runs the installed get.ps1 and so its SHA-256 check).
# Needs common.ps1. Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

$script:UpdateApiUrl = 'https://api.github.com/repos/SantiagoRuizM/ClaudeMaxxing/releases/latest'
$InstallOptionsFile = Join-Path $TrayHome 'install.json'

# The release's version when it is newer than $Current, else ''. Only X.Y.Z counts (VERSIONING.md).
function Get-NewerVersion([string]$Tag, [string]$Current) {
    $pattern = '^v?([0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6})\z'
    $new = [regex]::Match($Tag, $pattern)
    $old = [regex]::Match($Current, $pattern)
    if (-not $new.Success -or -not $old.Success) { return '' }
    if ([version]$new.Groups[1].Value -gt [version]$old.Groups[1].Value) { return $new.Groups[1].Value }
    ''
}

# What an update must not turn back on: get.ps1's switches for what this install does without.
function Get-UpdateOptions([bool]$HasMenu, [bool]$HasHotkeys, $Saved) {
    $options = @{}
    if (-not $HasMenu) { $options.SkipMenu = $true }
    if (-not $HasHotkeys) { $options.NoHotkeys = $true }
    if ($Saved -and $Saved.skipVoiceDeps) { $options.SkipVoiceDeps = $true }
    $options
}

function Start-UpdateRequest {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'ClaudeMaxxing-update')
    [pscustomobject]@{ Client = $client; Task = $client.GetAsync($script:UpdateApiUrl) }
}

# @{ State = 'new' | 'current' | 'none' | 'error'; Version } of a finished request.
function Complete-UpdateRequest($Pending, [string]$Current) {
    try {
        if ($Pending.Task.IsFaulted -or $Pending.Task.IsCanceled) { return @{ State = 'error' } }
        $response = $Pending.Task.Result
        $status = [int]$response.StatusCode
        if ($status -eq 404) { return @{ State = 'none' } }
        if ($status -ne 200) { return @{ State = 'error' } }
        $version = Get-NewerVersion ([string]($response.Content.ReadAsStringAsync().Result | ConvertFrom-Json).tag_name) $Current
        if ($version) { return @{ State = 'new'; Version = $version } }
        return @{ State = 'current' }
    } catch {
        return @{ State = 'error' }
    } finally {
        $Pending.Client.Dispose()
    }
}

# Visible on purpose: the installer may ask for UAC and lists its warnings at the end.
function Start-AppUpdate([string]$Root) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}"' -f (Join-Path $Root 'lib\update-run.ps1'), $Root.TrimEnd('\')
    Start-Process -FilePath $powershell -ArgumentList $arguments
}
