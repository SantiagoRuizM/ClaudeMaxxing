# Helpers for install.ps1 and uninstall.ps1: which files make up the installed runtime, copying them to the
# install folder, and stopping the processes a previous install left running. Needs common.ps1.

# Everything the installed tray, menu launcher and voice need; nothing else from the repo is copied.
$script:RuntimeFiles = @(
    'tray.ps1', 'whisper.ps1', 'open-session.ps1', 'start-session.ps1', 'cloud-schedule.ps1', 'uninstall.ps1',
    'menu\uninstall.ps1', 'voice\config.json', 'voice\ctl.ps1', 'voice\install.ps1'
)
# Folders copied whole. Files in them that are no longer in the repo are deleted from the install folder.
$script:RuntimeDirs = @('lib', 'voice\hooks', 'voice\plugin', 'voice\templates')
# Generated or user-owned, never deleted by an update: /voz of the plugin, the user's voice settings,
# the Python environment for edge-tts and the icons copied from the Claude app.
$script:PreservedPaths = @('voice\plugin\skills', 'voice\config.local.json', 'voice\venv', 'voice\.claude', 'assets')

# Relative paths of every runtime file in $Root.
function Get-RuntimeManifest([string]$Root) {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($file in $script:RuntimeFiles) { $files.Add($file) }
    foreach ($dir in $script:RuntimeDirs) {
        $full = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -File) {
            $relative = $item.FullName.Substring($Root.TrimEnd('\').Length + 1)
            if (-not (Test-PreservedPath $relative)) { $files.Add($relative) }
        }
    }
    , $files.ToArray()
}

function Test-PreservedPath([string]$Relative) {
    foreach ($keep in $script:PreservedPaths) {
        if ($Relative -eq $keep -or $Relative.StartsWith($keep + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# Files under the runtime folders of the install that the new manifest no longer has.
function Get-StaleFiles([string[]]$Installed, [string[]]$Manifest) {
    $wanted = @{}
    foreach ($file in $Manifest) { $wanted[$file.ToLowerInvariant()] = $true }
    @($Installed | Where-Object { -not $wanted.ContainsKey($_.ToLowerInvariant()) -and -not (Test-PreservedPath $_) })
}

# Copies the runtime over the install folder: files are overwritten in place (open sessions keep running
# hooks from there), then files dropped from the repo are deleted.
function Sync-Runtime([string]$Source, [string]$Target) {
    $manifest = Get-RuntimeManifest $Source
    foreach ($file in $manifest) {
        $from = Join-Path $Source $file
        if (-not (Test-Path -LiteralPath $from)) { throw "runtime file missing from the repo: $file" }
        $to = Join-Path $Target $file
        $dir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
    $installed = @()
    foreach ($dir in $script:RuntimeDirs) {
        $full = Join-Path $Target $dir
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $installed += @(Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object { $_.FullName.Substring($Target.TrimEnd('\').Length + 1) })
    }
    foreach ($stale in (Get-StaleFiles $installed $manifest)) { Remove-Item -LiteralPath (Join-Path $Target $stale) -Force -ErrorAction SilentlyContinue }
    # A ZIP downloaded from GitHub marks every file as coming from the internet.
    Get-ChildItem -LiteralPath $Target -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $manifest.Count
}

# Stops the tray recorded in tray.pid (wherever it was started from), after checking it really is tray.ps1,
# and the "Otros PCs" SSH server it started (killing the tray skips its own cleanup).
function Stop-RecordedTray {
    if (Get-Command Stop-BridgeServer -ErrorAction SilentlyContinue) {
        $serverPid = Stop-BridgeServer (New-BridgeContext)
        if ($serverPid) { Write-Host "Otros PCs SSH server stopped (PID $serverPid)" }
    }
    if (-not (Test-Path -LiteralPath $TrayPidFile)) { return $null }
    $trayPid = 0
    [void][int]::TryParse(([IO.File]::ReadAllText($TrayPidFile)).Trim(), [ref]$trayPid)
    Remove-Item -LiteralPath $TrayPidFile -ErrorAction SilentlyContinue
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $trayPid" -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.CommandLine -notlike '*tray.ps1*') { return $null }
    # The conhost --headless host that started it goes too.
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ParentProcessId)" -ErrorAction SilentlyContinue
    Stop-Process -Id $trayPid -Force -ErrorAction SilentlyContinue
    if ($parent -and $parent.Name -eq 'conhost.exe' -and $parent.CommandLine -like '*tray.ps1*') {
        Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $trayPid
}

# Stops the Claude Whisper window recorded in whisper.pid, after checking it really is whisper.ps1, with its
# claude process (the tree of that one PID).
function Stop-RecordedWhisper {
    $pidFile = Join-Path $TrayHome 'whisper\whisper.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $whisperPid = 0
    [void][int]::TryParse(([IO.File]::ReadAllText($pidFile)).Trim(), [ref]$whisperPid)
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $whisperPid" -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.CommandLine -notlike '*whisper.ps1*') { return $null }
    # The conhost --headless host that started it goes too.
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ParentProcessId)" -ErrorAction SilentlyContinue
    & taskkill.exe /PID $whisperPid /T /F 2>$null | Out-Null
    if ($parent -and $parent.Name -eq 'conhost.exe' -and $parent.CommandLine -like '*whisper.ps1*') {
        Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $whisperPid
}

function Get-TrayLaunch([string]$InstallDir) {
    @{
        File = Join-Path $env:WINDIR 'System32\conhost.exe'
        # conhost --headless keeps the PowerShell console hidden.
        Arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f (Join-Path $InstallDir 'tray.ps1')
    }
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory, [string]$Description) {
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.Arguments = $Arguments
    $link.WorkingDirectory = $WorkingDirectory
    $link.Description = $Description
    $link.Save()
}

# ---------------------------------------------------------------- voice dependencies

function New-Note([string]$Text, [switch]$Warn) { [pscustomobject]@{ Text = $Text; Warn = [bool]$Warn } }

function Test-Winget { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

function Invoke-Winget([string]$Id) {
    & winget.exe install --id $Id --exact --silent --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
        Out-Null
}

# A Python 3.8+ that really runs. On a clean Windows, the python.exe on PATH is a Store alias that only opens
# the Store, so each candidate is run.
function Find-Python {
    $candidates = New-Object System.Collections.Generic.List[object]
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { $candidates.Add(@($py.Source, '-3')) }
    foreach ($name in 'python.exe', 'python3.exe') {
        foreach ($cmd in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            if ($cmd.Source -notlike '*\WindowsApps\*') { $candidates.Add(@($cmd.Source)) }
        }
    }
    foreach ($dir in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python') -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $candidates.Add(@(Join-Path $dir.FullName 'python.exe'))
    }
    foreach ($candidate in $candidates) {
        $exe = $candidate[0]
        $pyArgs = @($candidate | Select-Object -Skip 1)
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        try {
            $ok = & $exe @pyArgs -c 'import sys; print(sys.version_info >= (3, 8))' 2>$null
            if ($LASTEXITCODE -eq 0 -and "$ok".Trim() -eq 'True') { return , $candidate }
        } catch { }
    }
    $null
}

function Find-Ffplay {
    $onPath = Get-Command ffplay.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffplay.exe'
    if (Test-Path -LiteralPath $link) { return $link }
    Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'ffplay.exe' -ErrorAction SilentlyContinue } |
        Select-Object -First 1 -ExpandProperty FullName
}

# Sets one key of voice\config.local.json (the per-PC settings Get-VoiceConfig puts over config.json).
function Set-LocalVoiceSetting([string]$VoiceDir, [string]$Section, [string]$Key, $Value) {
    $path = Join-Path $VoiceDir 'config.local.json'
    $config = $null
    if (Test-Path -LiteralPath $path) { try { $config = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $config = $null } }
    if (-not $config) { $config = New-Object PSObject }
    $target = $config
    if ($Section) {
        if (-not $config.PSObject.Properties[$Section]) { $config | Add-Member -NotePropertyName $Section -NotePropertyValue (New-Object PSObject) }
        $target = $config.$Section
    }
    $target | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LocalVoiceSetting([string]$VoiceDir, [string]$Section, [string]$Key) {
    $path = Join-Path $VoiceDir 'config.local.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $config = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
    if ($Section) { $config = $config.$Section }
    if ($config) { $config.$Key } else { $null }
}

# edge-tts (neural voices) goes in a Python environment of its own inside the install folder; ffplay comes from
# FFmpeg. What is missing is installed with winget and pip; whatever cannot be installed leaves the voice on the
# Windows voice (SAPI). Returns notes for the installer to print.
function Install-VoiceDependencies([string]$VoiceDir) {
    $notes = New-Object System.Collections.Generic.List[object]

    # edge-tts, always in our own Python environment and always the latest release: Microsoft changes the
    # service's token every few months and older versions get 403 (another app's copy on PATH may be stale).
    $venvEdge = Join-Path $VoiceDir 'venv\Scripts\edge-tts.exe'
    $venvPython = Join-Path $VoiceDir 'venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) {
        $python = Find-Python
        if (-not $python -and (Test-Winget)) {
            Write-Host 'installing Python with winget...'
            Invoke-Winget 'Python.Python.3.12'
            $python = Find-Python
        }
        if ($python) {
            Write-Host 'creating the voice Python environment...'
            $pyArgs = @($python | Select-Object -Skip 1)
            & $python[0] @pyArgs -m venv (Join-Path $VoiceDir 'venv') 2>&1 | Out-Null
        }
    }
    if (Test-Path -LiteralPath $venvPython) {
        Write-Host 'installing or updating edge-tts...'
        & $venvPython -m pip install --disable-pip-version-check --quiet --upgrade edge-tts 2>&1 | Out-Null
    }
    if (Test-Path -LiteralPath $venvEdge) {
        Set-LocalVoiceSetting $VoiceDir 'edge' 'exe' $venvEdge
        $notes.Add((New-Note "edge-tts: $venvEdge"))
    } else {
        $notes.Add((New-Note -Warn 'edge-tts could not be installed (needs Python 3.8+ and internet): the voice uses the Windows voice (SAPI) until you run install.ps1 again.'))
    }

    # ffplay
    $ffplay = Get-LocalVoiceSetting $VoiceDir '' 'ffplay'
    if (-not ($ffplay -and (Test-Path -LiteralPath $ffplay))) {
        $ffplay = Find-Ffplay
        if (-not $ffplay -and (Test-Winget)) {
            Write-Host 'installing FFmpeg (ffplay) with winget...'
            Invoke-Winget 'Gyan.FFmpeg'
            $ffplay = Find-Ffplay
        }
        # winget only adds it to PATH for programs started later, so the hooks get the full path.
        if ($ffplay) { Set-LocalVoiceSetting $VoiceDir '' 'ffplay' $ffplay }
    }
    if ($ffplay) {
        $notes.Add((New-Note "ffplay: $ffplay"))
    } else {
        $notes.Add((New-Note -Warn 'ffplay (FFmpeg) not found and winget could not install it: the voice uses the Windows voice (SAPI). Install it with: winget install Gyan.FFmpeg'))
    }

    # The Windows voice is the fallback; without a Spanish one it reads Spanish with an English accent.
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $spanish = @($synth.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'es' })
        $synth.Dispose()
        if (-not $spanish.Count) {
            $notes.Add((New-Note -Warn 'No Spanish Windows voice: the offline fallback (SAPI) will sound English. Add one in Settings > Time & language > Speech.'))
        }
    } catch { }
    $notes.ToArray()
}

# Entry in Settings > Apps > Installed apps, for the current user.
function Register-AppEntry([string]$InstallDir) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $UninstallKey)) { New-Item -Path $UninstallKey -Force | Out-Null }
    $size = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB)
    $values = [ordered]@{
        DisplayName     = $AppName
        DisplayVersion  = $AppVersion
        Publisher       = $AppName
        InstallLocation = $InstallDir
        DisplayIcon     = Join-Path $env:LOCALAPPDATA 'ClaudeCodeMenu\Assets\claude.ico'
        UninstallString = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $powershell, (Join-Path $InstallDir 'uninstall.ps1')
    }
    foreach ($name in $values.Keys) { Set-ItemProperty -LiteralPath $UninstallKey -Name $name -Value $values[$name] }
    foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty -LiteralPath $UninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -LiteralPath $UninstallKey -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null
}
