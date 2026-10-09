# Half-screen slots for Claude Code sessions opened from the Explorer menu. Pure helpers, no Win32 calls.
# Rects are physical pixels: work areas are [pscustomobject]@{ Left; Top; Right; Bottom }.

# Two slots per monitor (left half, right half), monitors ordered left to right, then top to bottom.
function Get-HalfSlots($WorkAreas) {
    $slots = @()
    foreach ($area in @($WorkAreas | Sort-Object Left, Top)) {
        $left = [int]$area.Left
        $top = [int]$area.Top
        $width = [int]$area.Right - $left
        $height = [int]$area.Bottom - $top
        $half = [int][math]::Floor($width / 2)
        $slots += [pscustomobject]@{ X = $left; Y = $top; Width = $half; Height = $height }
        $slots += [pscustomobject]@{ X = $left + $half; Y = $top; Width = $width - $half; Height = $height }
    }
    , $slots
}

# Lowest slot index no live session holds, or -1 when there are already as many sessions as slots.
# Sessions left on a slot that no longer exists (a monitor was unplugged) still count.
function Get-FreeSlot([int]$SlotCount, $Sessions) {
    $Sessions = @($Sessions | Where-Object { $_ })
    if ($Sessions.Count -ge $SlotCount) { return -1 }
    $used = @($Sessions | ForEach-Object { [int]$_.slot })
    for ($i = 0; $i -lt $SlotCount; $i++) {
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

# Tab color per slot, so each session window is easy to tell apart. Only the tab is colored: the
# terminal profile, color scheme and everything Claude Code draws stay as configured.
$SlotTabColors = @('#3B82F6', '#F97316', '#22C55E', '#A855F7', '#06B6D4', '#EF4444', '#EAB308', '#EC4899')

function Get-SlotTabColor([int]$Index) { $SlotTabColors[$Index % $SlotTabColors.Count] }

# wt.exe arguments for a new window in $Dir running $Run. --pos only takes non-negative values
# (a leading '-' reads as an option); the window is moved to its exact slot afterwards anyway.
function Format-WtArguments([string]$Dir, [string]$Run, $Slot, [string]$TabColor) {
    $pos = ''
    if ($Slot -and $Slot.X -ge 0 -and $Slot.Y -ge 0) { $pos = '--pos {0},{1} ' -f $Slot.X, $Slot.Y }
    $color = ''
    if ($TabColor) { $color = '--tabColor {0} ' -f $TabColor }
    '-w new {0}{1}-d {2} cmd /k {3}' -f $pos, $color, (Format-WtPath $Dir), $Run
}

function Format-SessionsFullMessage([int]$Open, [int]$Monitors) {
    $screens = if ($Monitors -eq 1) { '1 pantalla' } else { "$Monitors pantallas" }
    Tx ("Ya hay $Open sesiones de Claude Code abiertas desde el men\u00fa: el m\u00e1ximo es 2 por pantalla ($screens).`n`n" +
        "Cierra una de esas ventanas para abrir otra.")
}
