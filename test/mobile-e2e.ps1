# Celular end to end on this PC, not in the CI: the real HTTPS server (lib\mobile.cs) on a loopback port with a
# throwaway certificate, a client that pins its SHA-256 like the app, pairing with the code, a token request and
# the refusals. The tray's timer is played by a loop calling Invoke-MobileTick. Leaves no certificate or file behind.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\mobile-e2e.ps1

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CLAUDEMAXXING_LANG = 'es'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\bridge.ps1')
. (Join-Path $TrayRoot 'lib\mobile.ps1')

$script:Failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { $script:Failures++; Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red }
    else { Write-Host "ok   $Name" }
}

# The client: HTTPS that accepts only the pinned certificate, run on a task so this thread can serve meanwhile.
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
public static class MobileTestClient {
    public static Task<string> Send(string url, string method, string token, string body, string pin) {
        return Task.Run(() => {
            var handler = new HttpClientHandler();
            handler.ServerCertificateCustomValidationCallback = (m, cert, chain, errors) => {
                using (var sha = SHA256.Create()) {
                    return BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-", "").ToLowerInvariant() == pin;
                }
            };
            try {
                using (var client = new HttpClient(handler)) {
                    client.Timeout = TimeSpan.FromSeconds(20);
                    var request = new HttpRequestMessage(new HttpMethod(method), url);
                    if (token != "") request.Headers.Add("Authorization", "Bearer " + token);
                    if (body != "") request.Content = new StringContent(body, Encoding.UTF8, "application/json");
                    var response = client.SendAsync(request).Result;
                    return ((int)response.StatusCode) + " " + response.Content.ReadAsStringAsync().Result;
                }
            } catch (Exception e) { return "ERR " + (e.InnerException != null ? e.InnerException.Message : e.Message); }
        });
    }
}
'@

$root = Join-Path ([IO.Path]::GetTempPath()) ('cmx-mobile-e2e-' + [guid]::NewGuid().ToString('N'))
$MobileHome = $root
$MobileSettingsFile = Join-Path $root 'settings.json'
$MobileDevicesFile = Join-Path $root 'devices.json'
$MobileLogFile = Join-Path $root 'mobile.log'
$port = Get-Random -Minimum 47900 -Maximum 48900
$thumb = ''
try {
    Save-MobileSettings ([pscustomobject]@{ Enabled = $true; Port = $port; Thumbprint = '' })
    Start-MobileServer
    $thumb = (Get-MobileSettings).Thumbprint
    $pin = Get-MobileFingerprint $script:Mobile.Cert
    function Call([string]$Method, [string]$Path, [string]$Token = '', [string]$Body = '', [string]$Pin = $pin) {
        $task = [MobileTestClient]::Send("https://127.0.0.1:$port$Path", $Method, $Token, $Body, $Pin)
        $deadline = (Get-Date).AddSeconds(25)
        while (-not $task.IsCompleted -and (Get-Date) -lt $deadline) { Invoke-MobileTick; Start-Sleep -Milliseconds 20 }
        $task.Result
    }
    Assert-Equal $true ((Call 'GET' '/info') -like '200 *"app":"ClaudeMaxxing"*') 'e2e: /info over TLS with the pinned certificate'
    Assert-Equal $true ((Call 'GET' '/info' '' '' ('00' * 32)) -like 'ERR *') 'e2e: another certificate fingerprint is refused by the client'
    Assert-Equal $true ((Call 'GET' '/state') -like '401 *') 'e2e: /state without a token'
    Start-MobilePairing
    $answer = Call 'POST' '/pair' '' ('{"code":"' + $script:Mobile.Pairing.Code + '","device":"e2e"}')
    Assert-Equal $true ($answer -like '200 *"token":*') 'e2e: pairing with the QR code'
    $token = ($answer.Substring(4) | ConvertFrom-Json).token
    Assert-Equal $true ((Call 'GET' '/nope' $token) -like '404 *') 'e2e: a token reaches the routes'
    Assert-Equal $true ((Call 'POST' '/pair' '' ('{"code":"x","device":"e2e"}')) -like '401 *') 'e2e: no second pairing without a new code'
    # The voice notes: the list, then one mp3 as base64, over the real server (a made-up history folder).
    $MobileVoiceDir = Join-Path $root 'history'
    $voiceId = '20261121-093453-400-3cd075fb-fe1c-4104-a081-3c1699aa6a6e'
    Write-JsonFile (Join-Path $MobileVoiceDir "$voiceId.json") ([ordered]@{ time = '2026-11-21T09:34:53'; session = '3cd075fb-fe1c-4104-a081-3c1699aa6a6e'; name = 'Ana'; text = 'Listo.' })
    [IO.File]::WriteAllBytes((Join-Path $MobileVoiceDir "$voiceId.mp3"), [byte[]](1, 2, 3))
    Assert-Equal $true ((Call 'GET' '/voices?after=' $token) -like "200 *`"voices`":``[{*`"id`":`"$voiceId`"*") 'e2e: /voices lists the spoken lines'
    Assert-Equal $true ((Call 'GET' "/voice?id=$voiceId" $token) -like '200 *"audio":"AQID"*') 'e2e: /voice sends the mp3'
    Assert-Equal $true ((Call 'GET' '/voices' '') -like '401 *') 'e2e: the voice notes need a paired phone'
    $big = 'x' * (1024 * 1024 + 10)
    Assert-Equal $true ((Call 'POST' '/prompt' $token $big) -notlike '200 *') 'e2e: a body over 1 MB is refused'
} finally {
    Stop-MobileServer
    if ($thumb) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumb" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:Failures) { Write-Host "$script:Failures failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
