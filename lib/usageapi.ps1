# Live refresh from the endpoint Claude Code's /usage command reads. It is not a documented API,
# so everything here fails soft: on any error the tray keeps the statusline snapshot.
# The OAuth token is read from the local credentials file and only sent to api.anthropic.com.

$script:UsageApiUrl = 'https://api.anthropic.com/api/oauth/usage'

function Get-OAuthToken([string]$CredentialsPath) {
    if (-not (Test-Path -LiteralPath $CredentialsPath)) { return $null }
    try {
        $creds = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
        $oauth = $creds.claudeAiOauth
        if (-not $oauth -or -not $oauth.accessToken) { return $null }
        $expired = $oauth.expiresAt -and ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt) -lt [DateTimeOffset]::UtcNow)
        return [pscustomobject]@{ Token = [string]$oauth.accessToken; Expired = [bool]$expired }
    } catch { return $null }
}

function ConvertTo-UnixSeconds([string]$IsoTime) {
    # Rounded: the endpoint sends fractions like 22:49:59.98 for a 22:50 reset.
    $ms = [DateTimeOffset]::Parse($IsoTime, [System.Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
    [long][Math]::Round($ms / 1000.0)
}

# Maps the endpoint's JSON to the snapshot shape the statusline writes, so both feed the same view.
function ConvertFrom-UsageApi([string]$Json, [double]$NowUnix) {
    $data = $Json | ConvertFrom-Json
    $limits = [ordered]@{}
    foreach ($pair in @(@('five_hour', $data.five_hour), @('seven_day', $data.seven_day))) {
        $window = $pair[1]
        if ($null -eq $window -or $null -eq $window.resets_at -or $null -eq $window.utilization) { continue }
        $limits[$pair[0]] = [ordered]@{
            used_percentage = [double]$window.utilization
            resets_at       = ConvertTo-UnixSeconds ([string]$window.resets_at)
        }
    }
    if ($limits.Count -eq 0) { throw 'usage response has no rate-limit windows' }
    [ordered]@{ rate_limits = $limits; updated_at = $NowUnix; source = 'api' }
}

# Optional account extras from the same response, kept in their own file because the statusline
# snapshot does not carry them. Only what is active is stored, so the popup shows nothing otherwise.
#   extra_usage : overage credits; amounts are minor units of the currency (cents for USD).
#   juniper_tide: Claude Code's internal name for the "limit reset" offer (Settings > Usage > Resets).
function ConvertFrom-UsageExtras([string]$Json, [double]$NowUnix) {
    $data = $Json | ConvertFrom-Json
    $result = [ordered]@{ updated_at = $NowUnix; extra_usage = $null; limit_reset = $null }
    $extra = $data.extra_usage
    if ($extra -and $extra.is_enabled -eq $true) {
        $result.extra_usage = [ordered]@{
            utilization = $extra.utilization
            used_minor  = $extra.used_credits
            limit_minor = $extra.monthly_limit
            currency    = $extra.currency
        }
    }
    $reset = $data.juniper_tide
    if ($reset -and $reset.available -eq $true) {
        $result.limit_reset = [ordered]@{
            resets_per_week   = $reset.resets_per_week
            next_available_at = $reset.next_available_at
        }
    }
    $result
}
# Starts the request without blocking the UI thread; poll .IsCompleted on the returned task.
function Start-UsageRequest([string]$Token) {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $script:UsageApiUrl)
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    [void]$request.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
    [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'ClaudeTray')
    [pscustomobject]@{ Client = $client; Task = $client.SendAsync($request) }
}

# Turns a finished request into @{ Ok; Snapshot; Error }. Error texts are shown in the popup.
function Complete-UsageRequest($Pending) {
    try {
        if ($Pending.Task.IsFaulted -or $Pending.Task.IsCanceled) {
            return @{ Ok = $false; Error = 'No connection' }
        }
        $response = $Pending.Task.Result
        $status = [int]$response.StatusCode
        if ($status -eq 401) { return @{ Ok = $false; Error = 'Login expired: open Claude Code' } }
        if ($status -ne 200) { return @{ Ok = $false; Error = "Usage service error ($status)" } }
        $json = $response.Content.ReadAsStringAsync().Result
        $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
        $snapshot = ConvertFrom-UsageApi $json $nowUnix
        return @{ Ok = $true; Snapshot = $snapshot; Extras = (ConvertFrom-UsageExtras $json $nowUnix) }
    } catch {
        return @{ Ok = $false; Error = 'Unexpected usage response' }
    } finally {
        $Pending.Client.Dispose()
    }
}
