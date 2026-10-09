# Installs ClaudeTray for the current user:
#   1. finds a working claude executable (for scheduled sessions),
#   2. copies the Claude tray icons as a fallback,
#   3. adds a snapshot block to the Claude Code statusline script (backup kept),
#   4. installs or updates the "Abrir con Claude Code" Explorer menu (menu\install.ps1) and points it
#      at open-session.ps1 (half-screen slots),
#   5. adds a startup shortcut and starts the tray.
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\statusline.ps1')

if (-not (Test-Path -LiteralPath $TrayHome)) { New-Item -ItemType Directory -Force -Path $TrayHome | Out-Null }

# 1. claude executable: the first one on PATH may be a stale shim, so each candidate is run.
$candidates = @()
foreach ($name in 'claude.cmd', 'claude.exe') {
    $candidates += @(Get-Command $name -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
}
$candidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
$claude = $null
foreach ($path in ($candidates | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try {
        $version = & $path --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) { $claude = @{ Path = $path; Version = ([string]$version).Trim() }; break }
    } catch { }
}
if ($claude) {
    Write-JsonFile $ConfigFile @{ claudePath = $claude.Path }
    Write-Host "claude: $($claude.Path) ($($claude.Version))"
} else {
    Write-Warning 'No working claude executable found; scheduled sessions will fail until install.ps1 runs again.'
}

# 2. Fallback icons (the tray prefers the ones inside the installed Claude app).
$assets = Join-Path $TrayRoot 'assets'
if (-not (Test-Path -LiteralPath $assets)) { New-Item -ItemType Directory -Force -Path $assets | Out-Null }
$package = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($package) {
    foreach ($icon in 'Tray-Win32.ico', 'Tray-Win32-Dark.ico') {
        $src = Join-Path $package.InstallLocation "app\resources\$icon"
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $assets -Force }
    }
}

# 3. Statusline snapshot block.
$script = Get-StatuslineScriptPath
if ($script) {
    $status = Install-StatuslineBlock $script
    Write-Host "statusline: $status ($script)"
} else {
    Write-Warning 'No bash statusline script found in ~/.claude/settings.json; usage data will not be written.'
}

# 4. Explorer menu entry (menu\install.ps1) and its launcher. The menu DLL runs the launcher command, with
#    %1 replaced by the quoted folder, and falls back to plain wt.exe when the value is missing.
try {
    & (Join-Path $TrayRoot 'menu\install.ps1')
} catch {
    Write-Warning "Explorer menu not installed or updated: $($_.Exception.Message)"
}
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Dir %1' -f $powershell, (Join-Path $TrayRoot 'open-session.ps1')
if (-not (Test-Path -LiteralPath $MenuKey)) { New-Item -Path $MenuKey -Force | Out-Null }
Set-ItemProperty -LiteralPath $MenuKey -Name Launcher -Value $launcher
Write-Host "menu launcher: $launcher"

# 5. Startup shortcut. conhost --headless keeps the PowerShell console hidden.
$trayScript = Join-Path $TrayRoot 'tray.ps1'
$launchArgs = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $trayScript
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $startup 'ClaudeTray.lnk'))
$link.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
$link.Arguments = $launchArgs
$link.WorkingDirectory = $TrayRoot
$link.Description = 'ClaudeTray - Claude usage in the notification area'
$link.Save()
Write-Host "startup shortcut: $(Join-Path $startup 'ClaudeTray.lnk')"

if (-not $NoStart) {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $launchArgs -WorkingDirectory $TrayRoot
    Write-Host 'tray started'
}
