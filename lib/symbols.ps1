# The symbol that stands for each session (the egg, or another of symbols\<id>): one for the whole PC, chosen in
# Configuracion on the PC or on the phone. Each folder has still.png, thinking.gif (9 frames), filled.png (the
# shape with no holes, for speaking), symbol.ttf (the statusline's glyphs) and symbol.json (its name in Spanish).
# font\add_symbol.py makes one from an image. Needs common.ps1.

$SymbolFile = Join-Path $TrayHome 'symbol.json'
$DefaultSymbol = 'egg'
$SymbolNote = Ux 'Cambia al momento en la barra de tareas y el celular. Las sesiones abiertas conservan el suyo en la pesta\u00f1a y la statusline; las nuevas salen con este.'

# id -> name of the symbols under $Root, the default first.
function Get-SessionSymbols([string]$Root) {
    $found = [ordered]@{ $DefaultSymbol = 'Huevo' }
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $Root 'symbols') -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $info = Read-JsonFile (Join-Path $dir.FullName 'symbol.json')
        if ($dir.Name -cmatch '^[a-z][a-z0-9_]*$' -and $info -and $info.name) { $found[$dir.Name] = [string]$info.name }
    }
    $found
}

# The chosen one; the default when none was chosen or it is no longer there.
function Get-SavedSymbol([string]$Root) {
    $saved = Read-JsonFile $SymbolFile
    if ($saved -and (Get-SessionSymbols $Root).Contains([string]$saved.id)) { [string]$saved.id } else { $DefaultSymbol }
}

# Every symbol has the same code points (U+E100...) in a font of its own, so the statusline prints the same
# whichever it is and its terminal profile decides what that looks like.
function Get-SymbolFontFamily([string]$Id) {
    if ($Id -eq $DefaultSymbol) { 'ClaudeMaxxing Eggs' } else { "ClaudeMaxxing Symbol $Id" }
}

# The profile a session opens with, for good: that is how an open session keeps its symbol when another is chosen.
# The egg's keep their name from before the symbols (Windows Terminal knows a profile of a fragment by its name).
function Get-SessionProfileName([string]$ColorName, [string]$Id = $DefaultSymbol) {
    if ($Id -eq $DefaultSymbol) { "ClaudeMaxxing $ColorName" } else { "ClaudeMaxxing $ColorName $Id" }
}

# Windows Terminal profiles for the menu sessions: one per symbol and color, from the icons drawn in
# $IconRoot\<id>\<color>.png (tray.ps1 -RenderEggsTo), hidden from the new-tab menu.
# A fragment: Windows Terminal reads it beside the user's settings.json, which stays untouched.
function Install-TerminalProfiles([string]$IconRoot, [string[]]$Ids = @($DefaultSymbol)) {
    $profiles = @(foreach ($id in $Ids) {
        foreach ($icon in @(Get-ChildItem -LiteralPath (Join-Path $IconRoot $id) -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            # The symbol's font after the main one: the statusline's glyphs (U+E100...) come from it.
            # shortcut: assumes Windows Terminal's default face; a user who changed theirs gets Cascadia Mono in these tabs.
            [ordered]@{ name = (Get-SessionProfileName $icon.BaseName $id); commandline = '%SystemRoot%\System32\cmd.exe'; icon = $icon.FullName; hidden = $true
                font = [ordered]@{ face = 'Cascadia Mono, ' + (Get-SymbolFontFamily $id) } }
        }
    })
    if (-not $profiles.Count) { return 'terminal profiles: no eggs drawn (tabs keep the cmd icon)' }
    Write-JsonFile $TerminalFragmentFile ([ordered]@{ profiles = $profiles })
    # A running Windows Terminal reads fragments only when it reloads its settings: a new timestamp (content
    # untouched) makes it reload now, so the next menu session already finds its profile.
    foreach ($settings in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal*\LocalState\settings.json') -ErrorAction SilentlyContinue)) {
        try { $settings.LastWriteTime = Get-Date } catch { }
    }
    "terminal profiles: $TerminalFragmentFile"
}
