# Helpers for install.ps1 and uninstall.ps1: which files make up the installed runtime, copying them to the
# install folder, and stopping the processes a previous install left running. Needs common.ps1.

# Everything the installed tray, menu launcher and voice need; nothing else from the repo is copied.
$script:RuntimeFiles = @(
    'tray.ps1', 'whisper.ps1', 'open-session.ps1', 'start-session.ps1', 'cloud-schedule.ps1', 'uninstall.ps1', 'logo.png',
    # The egg of each session in the notification area (lib\traysessions.ps1): still, and the thinking animation.
    'egg_logo.png', 'egg_logo_gift_thinking.gif',
    'menu\uninstall.ps1', 'voice\config.json', 'voice\ctl.ps1', 'voice\install.ps1', 'harness\env.js', 'harness\tabs.js',
    # Peek: the plugin Claude Code loads (its tests, README and the sample paths in them stay in the repo).
    'peek\LICENSE', 'peek\.claude-plugin\plugin.json', 'peek\hooks\hooks.json', 'peek\hooks\register.tsx', 'peek\hooks\paths.ts',
    'peek\hooks\code.ts', 'peek\hooks\markdown.ts', 'peek\hooks\link.tsx', 'peek\hooks\window.ts', 'peek\windows\preview.ps1',
    'peek\windows\reveal.ps1',
    # Claude Whip: the plugin that holds a session to reading and planning when the plan runs low (lib\whip.ps1).
    'whip\.claude-plugin\plugin.json', 'whip\hooks\hooks.json', 'whip\hooks\register.ts', 'whip\hooks\rules.ts',
    'whip\skills\claude-whip\SKILL.md', 'whip\bin\whip-run.sh', 'whip\bin\whip-check.sh'
)
# Folders copied whole. Files in them that are no longer in the repo are deleted from the install folder.
# claudeJudge\.claude: the court skill that lib\judge-worker.ps1 copies next to each trial. harness\: Ambientes
# (env.js, the Chrome extension loaded unpacked from the install folder and its native messaging host).
$script:RuntimeDirs = @('lib', 'voice\hooks', 'voice\plugin', 'voice\templates', 'claudeJudge\.claude', 'harness\host', 'harness\extension', 'theme')
# Generated or user-owned, never deleted by an update: /voz of the plugin, the user's voice settings,
# the Python environment for edge-tts, the icons copied from the Claude app and the native host files that
# Register-HarnessHost writes (Chrome may be running that launcher) and the extension's icons (install.ps1 draws them).
$script:PreservedPaths = @('voice\plugin\skills', 'voice\config.local.json', 'voice\venv', 'voice\.claude', 'assets',
    'harness\host\yourharness-host.bat', 'harness\host\com.yourharness.bridge.json', 'harness\extension\icons')

# Relative paths of every runtime file in $Root.
function Get-RuntimeManifest([string]$Root) {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($file in $script:RuntimeFiles) { $files.Add($file) }
    foreach ($dir in $script:RuntimeDirs) {
        $full = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $full)) { continue }
        # Git Bash leaves *.stackdump crash dumps in whatever folder it ran in: never part of the runtime.
        foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -File | Where-Object { $_.Extension -ne '.stackdump' }) {
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
        # The jellyfish, drawn by tray.ps1 -RenderLogoTo with the extension's icons.
        DisplayIcon     = Join-Path $InstallDir 'harness\extension\icons\logo.ico'
        # -Pause: the console Settings opens stays until Enter, so its messages can be read.
        UninstallString = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Pause' -f $powershell, (Join-Path $InstallDir 'uninstall.ps1')
    }
    foreach ($name in $values.Keys) { Set-ItemProperty -LiteralPath $UninstallKey -Name $name -Value $values[$name] }
    foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty -LiteralPath $UninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -LiteralPath $UninstallKey -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null
}

# Ambientes: Chrome starts harness\host\host.js through a native messaging host. Its launcher and manifest hold
# this PC's node path, so they are written into the install folder here and registered for the current user.
# The host name and the extension id (from "key" in harness\extension\manifest.json) are the ones YourHarness used.
$HarnessHostName = 'com.yourharness.bridge'
$HarnessHostKey = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HarnessHostName"
$HarnessExtensionId = 'fmmpaipmfhkkghcljocefmmbhimeonkm'

function Register-HarnessHost([string]$InstallDir) {
    $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { return 'skipped: Node.js is not installed (Ambientes needs it)' }
    $hostDir = Join-Path $InstallDir 'harness\host'
    $launcher = Join-Path $hostDir 'yourharness-host.bat'
    [IO.File]::WriteAllText($launcher, ("@echo off`r`n`"{0}`" `"%~dp0host.js`" %*`r`n" -f $node.Source), [Text.Encoding]::ASCII)
    $manifest = Join-Path $hostDir "$HarnessHostName.json"
    $json = [ordered]@{ name = $HarnessHostName; description = 'ClaudeMaxxing Ambientes: Chrome tabs for env.js'; path = $launcher
        type = 'stdio'; allowed_origins = @("chrome-extension://$HarnessExtensionId/") } | ConvertTo-Json
    [IO.File]::WriteAllText($manifest, $json, (New-Object Text.UTF8Encoding $false))  # Chrome rejects a BOM
    New-Item -Path $HarnessHostKey -Force | Out-Null
    Set-ItemProperty -Path $HarnessHostKey -Name '(default)' -Value $manifest
    "native host: $manifest"
}

function Unregister-HarnessHost { Remove-Item -Path $HarnessHostKey -Force -ErrorAction SilentlyContinue }

# The extension's icons are drawn into the install (from logo.png, not kept as PNGs in the repo), so only the
# installed manifest names them: the repo copy stays loadable in Chrome, with its default icon.
function Add-HarnessManifestIcons([string]$InstallDir) {
    $extension = Join-Path $InstallDir 'harness\extension'
    $icons = [ordered]@{}
    foreach ($size in 16, 32, 48, 128) {
        if (Test-Path -LiteralPath (Join-Path $extension "icons\$size.png")) { $icons["$size"] = "icons/$size.png" }
    }
    if (-not $icons.Count) { return 'extension icons: none drawn (Chrome shows its default icon)' }
    $file = Join-Path $extension 'manifest.json'
    $manifest = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName icons -NotePropertyValue $icons -Force
    $manifest.action | Add-Member -NotePropertyName default_icon -NotePropertyValue $icons -Force
    [IO.File]::WriteAllText($file, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))  # Chrome rejects a BOM
    "extension icons: $(Join-Path $extension 'icons')"
}

# Windows Terminal profiles for the menu sessions: one per egg drawn in $EggDir (<color>.png, tray.ps1 -RenderEggsTo),
# hidden from the new-tab menu, with that egg as the tab icon. Named like Get-SessionProfileName (lib\sessions.ps1).
# A fragment: Windows Terminal reads it beside the user's settings.json, which stays untouched.
function Install-TerminalProfiles([string]$EggDir) {
    $eggs = @(Get-ChildItem -LiteralPath $EggDir -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $eggs.Count) { return 'terminal profiles: no eggs drawn (tabs keep the cmd icon)' }
    $profiles = @($eggs | ForEach-Object {
        # The eggs font after the main one: the statusline's egg glyphs (U+E100...) come from it (Install-EggFont).
        # shortcut: assumes Windows Terminal's default face; a user who changed theirs gets Cascadia Mono in these tabs.
        [ordered]@{ name = 'ClaudeMaxxing ' + $_.BaseName; commandline = '%SystemRoot%\System32\cmd.exe'; icon = $_.FullName; hidden = $true
            font = [ordered]@{ face = 'Cascadia Mono, ' + $EggFontFamily } }
    })
    Write-JsonFile $TerminalFragmentFile ([ordered]@{ profiles = $profiles })
    # A running Windows Terminal reads fragments only when it reloads its settings: a new timestamp (content
    # untouched) makes it reload now, so the next menu session already finds its profile.
    foreach ($settings in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal*\LocalState\settings.json') -ErrorAction SilentlyContinue)) {
        try { $settings.LastWriteTime = Get-Date } catch { }
    }
    "terminal profiles: $TerminalFragmentFile"
}

# The eggs font (font\ClaudeMaxxingEggs.ttf, built by font\build_eggs_font.py): the session egg and its animation
# frames as glyphs, for the statusline. Installed for this user only (no admin): copied under a name with its hash
# (a running terminal may hold the previous file), registered in HKCU and announced to running programs.
$script:EggFontFamily = 'ClaudeMaxxing Eggs'
$script:EggFontValue = 'ClaudeMaxxing Eggs (TrueType)'
$script:UserFontsKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
function Install-EggFont([string]$Source) {
    if (-not (Test-Path -LiteralPath $Source)) { return 'eggs font: not found' }
    $fonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path -LiteralPath $fonts)) { New-Item -ItemType Directory -Force -Path $fonts | Out-Null }
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA1).Hash.Substring(0, 8)
    $target = Join-Path $fonts "ClaudeMaxxingEggs-$hash.ttf"
    if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $Source -Destination $target }
    if (-not (Test-Path -LiteralPath $script:UserFontsKey)) { New-Item -Path $script:UserFontsKey -Force | Out-Null }
    New-ItemProperty -Path $script:UserFontsKey -Name $script:EggFontValue -Value $target -PropertyType String -Force | Out-Null
    foreach ($old in @(Get-ChildItem -LiteralPath $fonts -Filter 'ClaudeMaxxingEggs-*.ttf' | Where-Object { $_.FullName -ne $target })) {
        try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { }
    }
    Send-FontChange $target
    "eggs font: $target"
}

function Uninstall-EggFont {
    Remove-ItemProperty -Path $script:UserFontsKey -Name $script:EggFontValue -ErrorAction SilentlyContinue
    $fonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    foreach ($file in @(Get-ChildItem -LiteralPath $fonts -Filter 'ClaudeMaxxingEggs-*.ttf' -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { }
    }
    'eggs font removed'
}

# Loads the font in this session and tells running programs (WM_FONTCHANGE), so a new terminal finds it at once.
function Send-FontChange([string]$Path) {
    if (-not ('ClaudeMaxxing.FontChange' -as [type])) {
        Add-Type -Namespace ClaudeMaxxing -Name FontChange -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
'@
    }
    [void][ClaudeMaxxing.FontChange]::AddFontResource($Path)
    $result = [IntPtr]::Zero
    # HWND_BROADCAST, WM_FONTCHANGE, SMTO_ABORTIFHUNG, 1 s per window.
    [void][ClaudeMaxxing.FontChange]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$result)
}

function Uninstall-TerminalProfiles {
    $dir = Split-Path -Parent $TerminalFragmentFile
    if (-not (Test-Path -LiteralPath $dir)) { return 'terminal profiles: none' }
    Remove-Item -LiteralPath $dir -Recurse -Force
    'terminal profiles removed (open session tabs keep theirs until closed)'
}

# Peek (peek\): Claude Code loads the installed folder in every session through CLAUDE_CODE_PLUGIN_DIRS in the "env"
# block of ~/.claude/settings.json, and runs its hooks module only with CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 (mods
# are early access). The file is edited as text, so the rest keeps its formatting, and written only if the result
# parses. Uninstalling removes the folder from the list and leaves the switch: other plugins' mods may need it.
$PeekDirsVar = 'CLAUDE_CODE_PLUGIN_DIRS'
$PeekHooksVar = 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS'

function ConvertTo-JsonText([string]$Value) { '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"' }

function Test-JsonText([string]$Text) { try { $null = $Text | ConvertFrom-Json; $true } catch { $false } }

function Get-SettingsEnvValue([string]$Text, [string]$Name) {
    $settings = $Text | ConvertFrom-Json
    if ($settings -and $settings.env -and $settings.env.PSObject.Properties[$Name]) { return [string]$settings.env.$Name }
    $null
}

# The settings text with env.$Name set to $Value; the "env" block is made when there is none.
function Set-SettingsEnvText([string]$Text, [string]$Name, [string]$Value) {
    $entry = (ConvertTo-JsonText $Name) + ': ' + (ConvertTo-JsonText $Value)
    $existing = [regex]('("' + [regex]::Escape($Name) + '"\s*:\s*)"(?:[^"\\]|\\.)*"')
    $found = $existing.Match($Text)
    if ($found.Success) { return $Text.Substring(0, $found.Index) + $found.Groups[1].Value + (ConvertTo-JsonText $Value) + $Text.Substring($found.Index + $found.Length) }
    $block = ([regex]'"env"\s*:\s*\{').Match($Text)
    if ($block.Success) {
        $at = $block.Index + $block.Length
        $rest = $Text.Substring($at)
        return $Text.Substring(0, $at) + "`n    " + $entry + $(if ($rest -match '^\s*\}') { "`n  " } else { ',' }) + $rest
    }
    $open = $Text.IndexOf('{')
    if ($open -lt 0) { return "{`n  `"env`": {`n    $entry`n  }`n}`n" }
    $rest = $Text.Substring($open + 1)
    $Text.Substring(0, $open + 1) + "`n  `"env`": {`n    $entry`n  }" + $(if ($rest -match '^\s*\}') { "`n" } else { ',' }) + $rest
}

# The settings text without env.$Name; a comma it leaves before the closing brace goes too.
function Remove-SettingsEnvText([string]$Text, [string]$Name) {
    $found = ([regex]('\s*"' + [regex]::Escape($Name) + '"\s*:\s*"(?:[^"\\]|\\.)*"\s*,?')).Match($Text)
    if (-not $found.Success) { return $Text }
    $before = $Text.Substring(0, $found.Index)
    $after = $Text.Substring($found.Index + $found.Length)
    if ($after -match '^\s*\}') { $before = $before -replace ',(\s*)$', '$1' }
    $before + $after
}

function Format-PeekDir([string]$Path) { ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant() }

function Install-PeekSettings([string]$SettingsPath, [string]$PeekDir) {
    $text = if (Test-Path -LiteralPath $SettingsPath) { [IO.File]::ReadAllText($SettingsPath) } else { '{}' }
    if (-not (Test-JsonText $text)) { return "skipped: $SettingsPath is not valid JSON" }
    $dir = $PeekDir -replace '\\', '/'
    $dirs = @(([string](Get-SettingsEnvValue $text $PeekDirsVar)) -split ';' | Where-Object { $_.Trim() })
    $new = $text
    if (-not ($dirs | Where-Object { (Format-PeekDir $_) -eq (Format-PeekDir $dir) })) { $new = Set-SettingsEnvText $new $PeekDirsVar ((@($dirs) + $dir) -join ';') }
    if ((Get-SettingsEnvValue $new $PeekHooksVar) -ne '1') { $new = Set-SettingsEnvText $new $PeekHooksVar '1' }
    if ($new -eq $text) { return 'already on' }
    if (-not (Test-JsonText $new)) { return "skipped: could not edit $SettingsPath (left as it was)" }
    $backup = "$SettingsPath.bak-claudemaxxing"
    if ((Test-Path -LiteralPath $SettingsPath) -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $SettingsPath -Destination $backup }
    [IO.File]::WriteAllText($SettingsPath, $new, (New-Object Text.UTF8Encoding $false))
    "on in every session ($PeekDirsVar, $PeekHooksVar)"
}

function Uninstall-PeekSettings([string]$SettingsPath, [string]$PeekDir) {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return 'not installed' }
    $text = [IO.File]::ReadAllText($SettingsPath)
    if (-not (Test-JsonText $text)) { return "skipped: $SettingsPath is not valid JSON" }
    $current = Get-SettingsEnvValue $text $PeekDirsVar
    if (-not $current) { return 'not installed' }
    $dirs = @($current -split ';' | Where-Object { $_.Trim() -and (Format-PeekDir $_) -ne (Format-PeekDir $PeekDir) })
    $new = if ($dirs.Count) { Set-SettingsEnvText $text $PeekDirsVar ($dirs -join ';') } else { Remove-SettingsEnvText $text $PeekDirsVar }
    if ($new -eq $text) { return 'not installed' }
    if (-not (Test-JsonText $new)) { return "skipped: could not edit $SettingsPath (left as it was)" }
    [IO.File]::WriteAllText($SettingsPath, $new, (New-Object Text.UTF8Encoding $false))
    'removed'
}

# Theme (theme\): a plugin with two custom themes, loaded like Peek through CLAUDE_CODE_PLUGIN_DIRS. They repaint
# userMessageBackground, the bar Claude Code pins at the top of the transcript with the prompt being answered
# (and each prompt in it). Themes are a documented setting, so a Claude Code update keeps them. Picked with the
# top-level "theme" setting as custom:maxx-theme:light|dark after the built-in theme it replaces; a custom theme
# the user picked is left alone.
$ThemePrefix = 'custom:maxx-theme:'

function Get-SettingsTheme([string]$Text) {
    $settings = $Text | ConvertFrom-Json
    if ($settings -and $settings.PSObject.Properties['theme']) { return [string]$settings.theme }
    ''
}

# The settings text with the top-level "theme" set to $Value (made when there is none).
function Set-SettingsThemeText([string]$Text, [string]$Value) {
    $found = ([regex]'("theme"\s*:\s*)"(?:[^"\\]|\\.)*"').Match($Text)
    if ($found.Success) { return $Text.Substring(0, $found.Index) + $found.Groups[1].Value + (ConvertTo-JsonText $Value) + $Text.Substring($found.Index + $found.Length) }
    $open = $Text.IndexOf('{')
    $rest = $Text.Substring($open + 1)
    $Text.Substring(0, $open + 1) + "`n  `"theme`": " + (ConvertTo-JsonText $Value) + $(if ($rest -match '^\s*\}') { "`n" } else { ',' }) + $rest
}

function Write-SettingsTheme([string]$SettingsPath, [string]$Text, [string]$Value) {
    $new = Set-SettingsThemeText $Text $Value
    # The regex could hit a nested "theme": written only when the top-level one is the one that changed.
    if (-not (Test-JsonText $new) -or (Get-SettingsTheme $new) -ne $Value) { return $false }
    [IO.File]::WriteAllText($SettingsPath, $new, (New-Object Text.UTF8Encoding $false))
    $true
}

function Install-ThemeSettings([string]$SettingsPath, [string]$ThemeDir) {
    $dirs = Install-PeekSettings $SettingsPath $ThemeDir
    if ($dirs -like 'skipped*') { return $dirs }
    $text = [IO.File]::ReadAllText($SettingsPath)
    $current = Get-SettingsTheme $text
    if ($current.StartsWith($ThemePrefix)) { return "on ($current)" }
    if ($current.StartsWith('custom:')) { return "kept your theme $current (pick ClaudeMaxxing in /theme)" }
    $want = $ThemePrefix + $(if ($current -like 'light*') { 'light' } else { 'dark' })
    if (-not (Write-SettingsTheme $SettingsPath $text $want)) { return "skipped: could not edit $SettingsPath (left as it was)" }
    "on ($want)"
}

function Uninstall-ThemeSettings([string]$SettingsPath, [string]$ThemeDir) {
    $dirs = Uninstall-PeekSettings $SettingsPath $ThemeDir
    if ($dirs -like 'skipped*' -or -not (Test-Path -LiteralPath $SettingsPath)) { return $dirs }
    $text = [IO.File]::ReadAllText($SettingsPath)
    $current = Get-SettingsTheme $text
    if (-not $current.StartsWith($ThemePrefix)) { return $dirs }
    $back = $current.Substring($ThemePrefix.Length)
    if (-not (Write-SettingsTheme $SettingsPath $text $back)) { return "skipped: could not edit $SettingsPath (left as it was)" }
    "removed (theme back to $back)"
}
