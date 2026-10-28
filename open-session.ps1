# Opens Claude Code in $Dir in a new Windows Terminal window placed on the next free half-screen slot.
# With n monitors there are 2n slots (left and right half of each, monitors left to right); when all are
# taken it says so and opens nothing. Launched by the "Abrir con Claude Code" Explorer menu entry, which
# reads this command from HKCU\Software\ClaudeCodeMenu\Launcher (written by install.ps1).
# Each session gets its slot's color (tab and Claude Code prompt box) and, from the voice part, a name
# and a voice picked before Claude Code starts; the voice plugin (voice\plugin) loads for that session
# only and completes the title with the role on the first prompt.
# With FreeLLMAPI switched on in the ClaudeMaxxing window (lib\freellm.ps1), the session talks to it instead
# of the Claude plan; if it cannot be reached, the session opens on the plan and says why.
# -Run and -StatePath are for testing: run another command, keep a separate session list.
param([string]$Dir, [string]$Run = 'claude', [string]$StatePath)

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\sessions.ps1')
. (Join-Path $TrayRoot 'lib\winapi.ps1')
. (Join-Path $TrayRoot 'lib\freellm.ps1')
# wt.exe hands its caller's environment to the new window. Started from a Claude Code shell (a test
# run), that environment turns colors off and changes git prompts; the Explorer menu starts clean.
if ($env:CLAUDECODE) {
    foreach ($name in 'NO_COLOR', 'GIT_EDITOR', 'GIT_TERMINAL_PROMPT', 'GIT_ASKPASS') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
}
Clear-ClaudeSessionEnv
if ($StatePath) { $SessionsFile = $StatePath }

# Windows Terminal windows; a plain console if wt.exe is missing.
$TerminalClasses = [string[]]@('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass')
$Caption = 'Claude Code'

function Write-SessionLog([string]$Message) {
    if (-not (Test-Path -LiteralPath $TrayHome)) { New-Item -ItemType Directory -Force -Path $TrayHome | Out-Null }
    Add-Content -LiteralPath $SessionLogFile -Value ((Get-Date).ToString('s') + ' ' + $Message) -Encoding UTF8
}

function Show-Notice([string]$Text) {
    if ('ClaudeTrayWin' -as [type]) { [ClaudeTrayWin]::Notify($Text, $Caption); return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Caption)
}

# Name and voice for the session, from voice\hooks\common.ps1. It is loaded in a child scope because it
# defines functions and variables with the same names as lib\common.ps1.
function Register-VoiceSession([string]$SessionId, [string]$ColorName) {
    $voiceLib = Join-Path $TrayRoot 'voice\hooks\common.ps1'
    if (-not (Test-Path -LiteralPath $voiceLib)) { return $null }
    & {
        . $voiceLib
        $cfg = Get-VoiceConfig
        if (-not (Get-Opt $cfg 'naming.enabled' $true)) { return $null }
        New-ReservedSession $cfg $SessionId $ColorName
    }
}

function Wait-NewWindow([long[]]$Before, [int]$TimeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $new = @([ClaudeTrayWin]::GetVisibleWindows($TerminalClasses) | Where-Object { $Before -notcontains $_ })
        if ($new.Count -gt 0) { return $new[0] }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# One launcher at a time, from reading the session list until the new window is recorded,
# so two quick clicks never take the same slot.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeTraySessions')
try { $owned = $mutex.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
try {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { throw "no existe la carpeta $Dir" }
    Import-WinApi

    $areas = @(Get-WorkAreas)
    $slots = Get-HalfSlots $areas
    $sessions = @(Read-JsonFile $SessionsFile | Where-Object { $_ -and [ClaudeTrayWin]::IsLiveWindow([long]$_.hwnd, $TerminalClasses) })
    $slot = Get-FreeSlot $slots.Count $sessions
    if ($slot -lt 0) {
        Write-JsonFile $SessionsFile $sessions
        Write-SessionLog "full: $($sessions.Count) sessions, $($areas.Count) monitors; not opening $Dir"
        Show-Notice (Format-SessionsFullMessage $sessions.Count $areas.Count)
        return
    }

    $rect = $slots[$slot]
    $color = Get-SlotColor $slot
    $sessionId = [guid]::NewGuid().ToString()
    $identity = $null
    try {
        $identity = Register-VoiceSession $sessionId $color.Name
    } catch {
        Write-SessionLog "voice name not reserved: $($_.Exception.Message)"
    }
    $pluginDir = Join-Path $TrayRoot 'voice\plugin'
    if (-not (Test-Path -LiteralPath (Join-Path $pluginDir '.claude-plugin\plugin.json'))) { $pluginDir = '' }
    $command = Format-ClaudeCommand $Run $sessionId $pluginDir $color.Name
    $backend = 'plan'
    try {
        $free = Get-FreeLlmLaunch
        $freeNotice = $free.Notice
        if ($free.Prefix) { $command = $free.Prefix + (Format-ClaudeCommand $Run $sessionId $pluginDir $color.Name $free.Settings); $backend = 'freellm' }
    } catch {
        Write-SessionLog "freellm: $($_.Exception.Message)"
    }

    $before = [long[]]@([ClaudeTrayWin]::GetVisibleWindows($TerminalClasses))
    try {
        Start-Process -FilePath 'wt.exe' -ArgumentList (Format-WtArguments $Dir $command $rect $color.Hex) -WorkingDirectory $Dir -ErrorAction Stop
    } catch {
        Write-SessionLog "wt.exe failed ($($_.Exception.Message)); using cmd.exe"
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/k $command" -WorkingDirectory $Dir -ErrorAction Stop
    }

    $hwnd = Wait-NewWindow $before 15000
    if (-not $hwnd) {
        Write-JsonFile $SessionsFile $sessions
        Write-SessionLog "slot ${slot}: no new terminal window appeared for $Dir"
        return
    }
    # Recorded before placing, so the slot is taken even if placing fails.
    $sessions += [pscustomobject]@{
        slot = $slot; hwnd = [long]$hwnd; dir = $Dir; at = (Get-Date).ToString('o')
        sessionId = $sessionId; color = $color.Name; name = "$($identity.name)"; backend = $backend
    }
    Write-JsonFile $SessionsFile $sessions

    $frame = [ClaudeTrayWin]::Place($hwnd, $rect.X, $rect.Y, $rect.Width, $rect.Height, 12)
    [ClaudeTrayWin]::Activate($hwnd)
    Write-SessionLog ("slot {0} hwnd {1}: target {2},{3} {4}x{5}, frame {6},{7} {8}x{9}, {10} {11} {12}, {13}, {14}" -f $slot, $hwnd,
        $rect.X, $rect.Y, $rect.Width, $rect.Height, $frame[0], $frame[1], ($frame[2] - $frame[0]), ($frame[3] - $frame[1]),
        $color.Name, $sessionId, $identity.name, $Dir, $backend)
} catch {
    Write-SessionLog "error: $($_.Exception.Message)"
    Show-Notice "No se pudo abrir Claude Code: $($_.Exception.Message)"
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
}
# After releasing the lock: the notice waits for a click.
if ($freeNotice) { Show-Notice $freeNotice }
