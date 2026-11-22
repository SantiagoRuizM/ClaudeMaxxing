# Half-screen slots for Claude Code sessions opened from the Explorer menu. Pure helpers, no Win32 calls.
# Rects are physical pixels: work areas are [pscustomobject]@{ Left; Top; Right; Bottom }.

$ScreenOrderFile = Join-Path $TrayHome 'screens.json'

# Monitors in the order sessions fill them: left to right, then top to bottom. $First moves one to the front:
# 'windows' the main one (Windows' primary, whose top-left is the desktop's origin) or an index ('0', '1'...) in that
# left-to-right order. Anything else, or a monitor that is gone, keeps left to right.
function Get-ScreenOrder($Areas, [string]$First = '') {
    $sorted = @($Areas | Sort-Object Left, Top)
    $pick = -1
    if ($First -eq 'windows') {
        # shortcut: the primary is the one holding the point (100, 100); a taskbar on its left or top is narrower
        # than 100 px. Read the monitor flags (MONITORINFOF_PRIMARY) if a layout ever breaks this.
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $a = $sorted[$i]
            if ([int]$a.Left -le 100 -and 100 -lt [int]$a.Right -and [int]$a.Top -le 100 -and 100 -lt [int]$a.Bottom) { $pick = $i; break }
        }
    } elseif ($First -match '^\d+$' -and [int]$First -lt $sorted.Count) { $pick = [int]$First }
    if ($pick -gt 0) { $sorted = @($sorted[$pick]) + @(for ($i = 0; $i -lt $sorted.Count; $i++) { if ($i -ne $pick) { $sorted[$i] } }) }
    , $sorted
}

# Which monitor goes first (Claude Code > Primera pantalla): '' left to right, 'windows' or an index.
function Get-ScreenFirst {
    $saved = Read-JsonFile $ScreenOrderFile
    if ($saved -and $saved.first) { [string]$saved.first } else { '' }
}
function Set-ScreenFirst([string]$First) { Write-JsonFile $ScreenOrderFile @{ first = $First } }

# $PerScreen slots per monitor, monitors in Get-ScreenOrder's order: 1 the whole screen, 2 its left and right halves,
# 4 its quarters (top left, top right, bottom left, bottom right).
function Get-ScreenSlots($WorkAreas, [string]$First = '', [int]$PerScreen = 2) {
    $cols = if ($PerScreen -eq 1) { 1 } else { 2 }
    $rows = if ($PerScreen -eq 4) { 2 } else { 1 }
    $slots = @()
    foreach ($area in (Get-ScreenOrder $WorkAreas $First)) {
        $left = [int]$area.Left
        $top = [int]$area.Top
        $width = [int]$area.Right - $left
        $height = [int]$area.Bottom - $top
        # The first column and row round down; the last ones take the extra pixel.
        $w0 = [int][math]::Floor($width / $cols)
        $h0 = [int][math]::Floor($height / $rows)
        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $cols; $c++) {
                $slots += [pscustomobject]@{
                    X = $left + $c * $w0; Y = $top + $r * $h0
                    Width = $(if ($c -eq $cols - 1) { $width - $c * $w0 } else { $w0 })
                    Height = $(if ($r -eq $rows - 1) { $height - $r * $h0 } else { $h0 })
                }
            }
        }
    }
    , $slots
}

# Where slot $Slot sits, for the window's session list: "pantalla 2", "mitad izquierda de la pantalla 1"...
function Format-SlotPlace([int]$Slot, [int]$PerScreen, [int]$SlotCount) {
    if ($SlotCount -gt 0) { $Slot = $Slot % $SlotCount }
    $screen = [int][Math]::Floor($Slot / $PerScreen) + 1
    $i = $Slot % $PerScreen
    switch ($PerScreen) {
        1 { (L 'pantalla {0}') -f $screen }
        4 { (L 'cuarto {0} de la pantalla {1}') -f (L (@('superior izquierdo', 'superior derecho', 'inferior izquierdo', 'inferior derecho')[$i])), $screen }
        default { (L 'mitad {0} de la pantalla {1}') -f (L (@('izquierda', 'derecha')[$i])), $screen }
    }
}

# Lowest slot index no live session holds, or -1 when there are already as many sessions as slots.
# Sessions left on a slot that no longer exists (a monitor was unplugged) still count.
# -NoLimit: never full; past the last slot it returns $SlotCount and up (the caller places it on slot % count).
function Get-FreeSlot([int]$SlotCount, $Sessions, [bool]$NoLimit = $false) {
    $Sessions = @($Sessions | Where-Object { $_ })
    if (-not $NoLimit -and $Sessions.Count -ge $SlotCount) { return -1 }
    $used = @($Sessions | ForEach-Object { [int]$_.slot })
    for ($i = 0; $NoLimit -or $i -lt $SlotCount; $i++) {
        if ($used -notcontains $i) { return $i }
    }
    return -1
}

# Quotes a path for the wt.exe command line: a bare ';' separates wt commands, and a trailing
# backslash would escape the closing quote ("C:\").
function Format-WtPath([string]$Path) {
    $escaped = $Path -replace ';', '\;'
    if ($escaped.EndsWith('\')) { $escaped += '\' }
    '"' + $escaped + '"'
}

# Color per slot, so each session window is easy to tell apart: the tab gets the hex, and Claude Code's
# prompt box gets the same color by name (/color). The hex values are Claude Code's own for those names
# in its dark theme. The terminal profile and color scheme stay as configured.
$SlotColors = @(
    [pscustomobject]@{ Name = 'blue';   Hex = '#6A9BCC' }
    [pscustomobject]@{ Name = 'orange'; Hex = '#D97757' }
    [pscustomobject]@{ Name = 'green';  Hex = '#16A34A' }
    [pscustomobject]@{ Name = 'purple'; Hex = '#827DBD' }
    [pscustomobject]@{ Name = 'cyan';   Hex = '#0891B2' }
    [pscustomobject]@{ Name = 'red';    Hex = '#DC2626' }
    [pscustomobject]@{ Name = 'yellow'; Hex = '#CA8A04' }
    [pscustomobject]@{ Name = 'pink';   Hex = '#C46686' }
)

function Get-SlotColor([int]$Index) { $SlotColors[$Index % $SlotColors.Count] }

function Get-SlotTabColor([int]$Index) { (Get-SlotColor $Index).Hex }

# Claude Code command line: a fixed session id (so the voice state can be prepared before it starts),
# the voice plugin for this session only, extra settings for this session only (FreeLLMAPI sessions),
# and /color as the first prompt (a local command: no model call). Claude Code takes one first prompt: a
# $Prompt (the ClaudeMaxxing window's "Nueva skill...", say) takes the place of /color; its double quotes go.
function Format-ClaudeCommand([string]$Run, [string]$SessionId, [string]$PluginDir, [string]$ColorName, [string]$SettingsPath, [string]$Prompt) {
    $command = $Run
    if ($SessionId) { $command += ' --session-id ' + $SessionId }
    if ($PluginDir) { $command += ' --plugin-dir ' + (Format-WtPath $PluginDir) }
    if ($SettingsPath) { $command += ' --settings ' + (Format-WtPath $SettingsPath) }
    # wt splits its command line at a bare ';'.
    if ($Prompt) { $command += ' "' + $Prompt.Replace('"', '').Replace(';', '\;') + '"' }
    elseif ($ColorName) { $command += ' "/color ' + $ColorName + '"' }
    $command
}

# Opens a session in $Dir through open-session.ps1 in a hidden console, as the Explorer menu does: on the next free
# half screen, with $Prompt as its first prompt.
function Start-ClaudeCodeSession([string]$Dir, [string]$Prompt) {
    # A trailing backslash ("C:\") would escape the closing quote.
    if ($Dir.EndsWith('\')) { $Dir += '.' }
    $launch = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Dir "{1}"' -f (Join-Path $TrayRoot 'open-session.ps1'), $Dir
    if ($Prompt) { $launch += ' -Prompt "{0}"' -f $Prompt.Replace('"', '').TrimEnd('\') }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $launch -WorkingDirectory $TrayRoot
}

# wt.exe arguments for a new window in $Dir running $Run. --pos only takes non-negative values
# (a leading '-' reads as an option); the window is moved to its exact slot afterwards anyway.
function Format-WtArguments([string]$Dir, [string]$Run, $Slot, [string]$TabColor, [string]$TerminalProfile) {
    $pos = ''
    if ($Slot -and $Slot.X -ge 0 -and $Slot.Y -ge 0) { $pos = '--pos {0},{1} ' -f $Slot.X, $Slot.Y }
    $color = ''
    if ($TabColor) { $color = '--tabColor {0} ' -f $TabColor }
    # -p is a new-tab option: it goes after --pos, a window option (before it, wt rejects --pos and opens nothing).
    $prof = ''
    if ($TerminalProfile) { $prof = '-p "{0}" ' -f $TerminalProfile }
    '-w new {0}{1}{2}-d {3} cmd /k {4}' -f $pos, $prof, $color, (Format-WtPath $Dir), $Run
}

function Format-SessionsFullMessage([int]$Open, [int]$Monitors, [int]$PerScreen = 2) {
    $screens = if ($Monitors -eq 1) { L '1 pantalla' } else { (L '{0} pantallas') -f $Monitors }
    ((Tx 'Ya hay {0} sesiones de Claude Code abiertas desde el men\u00fa: el m\u00e1ximo es {2} por pantalla ({1}).') -f $Open, $screens, $PerScreen) + "`n`n" +
        (Tx 'Cierra una de esas ventanas para abrir otra, o quita el l\u00edmite en ClaudeMaxxing > Claude Code.')
}

# On unless switched off in the ClaudeMaxxing window ($SessionLimitFile, lib\common.ps1).
function Test-SessionLimit {
    $saved = Read-JsonFile $SessionLimitFile
    -not ($saved -and $saved.enabled -eq $false)
}

# Sessions per screen (1, 2 or 4), in the same file; 2 unless changed in the ClaudeMaxxing window.
function Get-SessionsPerScreen {
    $saved = Read-JsonFile $SessionLimitFile
    if ($saved -and @(1, 2, 4) -contains [int]$saved.perScreen) { [int]$saved.perScreen } else { 2 }
}

function Set-SessionLimit([bool]$On) { Write-JsonFile $SessionLimitFile @{ enabled = $On; perScreen = (Get-SessionsPerScreen) } }
function Set-SessionsPerScreen([int]$PerScreen) { Write-JsonFile $SessionLimitFile @{ enabled = (Test-SessionLimit); perScreen = $PerScreen } }

# How much the menu sessions work, for the advice on how many fit a screen: per day, the seconds the sessions were
# open and the seconds they were working, each added up over the sessions. The tray's eggs feed it every second
# (Update-SessionIcons); it is saved once a minute.
$ActivityFile = Join-Path $TrayHome 'activity.json'
$script:ActivityPending = @{ Open = 0.0; Busy = 0.0 }
$script:ActivityTickAt = $null
$script:ActivitySavedAt = $null

function Add-SessionActivity([int]$Open, [int]$Busy, [datetime]$Now = (Get-Date)) {
    $last = $script:ActivityTickAt
    $script:ActivityTickAt = $Now
    if (-not $last) { $script:ActivitySavedAt = $Now; return }
    $seconds = ($Now - $last).TotalSeconds
    # A long gap (sleep, a hung tick) is not time anyone watched the sessions.
    if ($seconds -le 0 -or $seconds -gt 10) { return }
    $script:ActivityPending.Open += $Open * $seconds
    $script:ActivityPending.Busy += $Busy * $seconds
    if (($Now - $script:ActivitySavedAt).TotalSeconds -ge 60) { Save-SessionActivity $Now }
}

function Save-SessionActivity([datetime]$Now = (Get-Date)) {
    $script:ActivitySavedAt = $Now
    $pending = $script:ActivityPending
    if ($pending.Open -le 0) { return }
    $saved = Read-JsonFile $ActivityFile
    $oldest = $Now.Date.AddDays(-30).ToString('yyyy-MM-dd')
    $days = [ordered]@{}
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { if ($p.Name -ge $oldest) { $days[$p.Name] = $p.Value } } }
    $key = $Now.ToString('yyyy-MM-dd')
    $day = $days[$key]
    $days[$key] = [ordered]@{
        open = [Math]::Round([double]$(if ($day) { $day.open } else { 0 }) + $pending.Open)
        busy = [Math]::Round([double]$(if ($day) { $day.busy } else { 0 }) + $pending.Busy)
    }
    Write-JsonFile $ActivityFile $days
    $script:ActivityPending = @{ Open = 0.0; Busy = 0.0 }
}

# Open and working seconds of the last $Days days.
function Get-SessionActivity([int]$Days = 7, [datetime]$Now = (Get-Date)) {
    $saved = Read-JsonFile $ActivityFile
    $from = $Now.Date.AddDays(1 - $Days).ToString('yyyy-MM-dd')
    $open = 0.0
    $busy = 0.0
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { if ($p.Name -ge $from) { $open += [double]$p.Value.open; $busy += [double]$p.Value.busy } } }
    [pscustomobject]@{ Open = $open; Busy = $busy }
}

# Sessions per screen worth having: agents that work half the time or more keep you waiting, so more of them fit (4);
# ones working under a fifth of it wait for you, so fewer and bigger windows (1). $null under an hour of sessions.
function Get-PerScreenAdvice($Activity) {
    if (-not $Activity -or $Activity.Open -lt 3600) { return $null }
    $ratio = $Activity.Busy / $Activity.Open
    $per = if ($ratio -ge 0.5) { 4 } elseif ($ratio -ge 0.2) { 2 } else { 1 }
    [pscustomobject]@{ PerScreen = $per; Percent = [int][Math]::Round(100 * $ratio) }
}
