# Downloads and installs the FreeLLMAPI desktop app (the pinned version in lib\freellm.ps1), then starts it.
# Started hidden by the "Instalar" button in the ClaudeMaxxing window; reports progress in
# freellm-install.json, which the window reads. Keep this file ASCII.

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\freellm.ps1')

function Set-Status([string]$State, [string]$Message) {
    Write-JsonFile $FreeLlmInstallFile ([ordered]@{ state = $State; message = $Message; version = $FreeLlmVersion; at = (Get-Date).ToString('o') })
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeTrayFreeLlmInstall')
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }
try {
    if (-not (Test-Path -LiteralPath $FreeLlmDownloadDir)) { New-Item -ItemType Directory -Force -Path $FreeLlmDownloadDir | Out-Null }
    $setup = Join-Path $FreeLlmDownloadDir $FreeLlmSetupName
    Set-Status 'downloading' (Tx "Descargando FreeLLMAPI $FreeLlmVersion (unos 110 MB)\u2026")
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $partial = "$setup.part"
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($FreeLlmSetupUrl, $partial) } finally { $client.Dispose() }

    $sha = [System.Security.Cryptography.SHA512]::Create()
    $stream = [IO.File]::OpenRead($partial)
    try { $hash = [Convert]::ToBase64String($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }
    if ($hash -ne $FreeLlmSetupSha512) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw 'el instalador descargado no coincide con el de la version probada'
    }
    Move-Item -LiteralPath $partial -Destination $setup -Force
    Unblock-File -LiteralPath $setup -ErrorAction SilentlyContinue

    Set-Status 'installing' (Tx "Instalando FreeLLMAPI $FreeLlmVersion\u2026")
    # Per-user NSIS installer (electron-builder): /S installs silently, without admin rights.
    $process = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "el instalador termino con codigo $($process.ExitCode)" }
    $exe = $null
    for ($i = 0; $i -lt 20 -and -not $exe; $i++) { $exe = Get-FreeLlmExe; if (-not $exe) { Start-Sleep -Milliseconds 500 } }
    if (-not $exe) { throw 'no se encuentra FreeLLMAPI.exe despues de instalar' }
    Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue

    Start-Process -FilePath $exe | Out-Null
    Set-Status 'done' (Tx "FreeLLMAPI $FreeLlmVersion instalado. Crea tu cuenta en su ventana y a\u00f1ade claves de proveedores.")
} catch {
    Set-Status 'error' ('No se pudo instalar FreeLLMAPI: ' + $_.Exception.Message)
} finally {
    $mutex.ReleaseMutex()
}
