# The symbol that stands for each session (the egg, or another of symbols\<id>): one for the whole PC, chosen in
# Configuracion on the PC or on the phone. Each folder has still.png, thinking.gif (9 frames), filled.png (the
# shape with no holes, for speaking), symbol.ttf (the statusline's glyphs) and symbol.json (its name in Spanish).
# font\add_symbol.py makes one from an image. Needs common.ps1.

$SymbolFile = Join-Path $TrayHome 'symbol.json'
$DefaultSymbol = 'egg'

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

# Every symbol has the same code points (U+E100...) in a font of its own: changing the profiles' font changes the
# symbol in the terminals already open, with no statusline to run again.
function Get-SymbolFontFamily([string]$Id) {
    if ($Id -eq $DefaultSymbol) { 'ClaudeMaxxing Eggs' } else { "ClaudeMaxxing Symbol $Id" }
}

# Windows Terminal profiles for the menu sessions: one per icon drawn in $IconDir (<color>.png, tray.ps1
# -RenderEggsTo), hidden from the new-tab menu. Named like Get-SessionProfileName (lib\sessions.ps1).
# A fragment: Windows Terminal reads it beside the user's settings.json, which stays untouched.
function Install-TerminalProfiles([string]$IconDir, [string]$Family = (Get-SymbolFontFamily $DefaultSymbol)) {
    $icons = @(Get-ChildItem -LiteralPath $IconDir -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $icons.Count) { return 'terminal profiles: no eggs drawn (tabs keep the cmd icon)' }
    $profiles = @($icons | ForEach-Object {
        # The symbol's font after the main one: the statusline's glyphs (U+E100...) come from it.
        # shortcut: assumes Windows Terminal's default face; a user who changed theirs gets Cascadia Mono in these tabs.
        [ordered]@{ name = 'ClaudeMaxxing ' + $_.BaseName; commandline = '%SystemRoot%\System32\cmd.exe'; icon = $_.FullName; hidden = $true
            font = [ordered]@{ face = 'Cascadia Mono, ' + $Family } }
    })
    Write-JsonFile $TerminalFragmentFile ([ordered]@{ profiles = $profiles })
    # A running Windows Terminal reads fragments only when it reloads its settings: a new timestamp (content
    # untouched) makes it reload now, and that repaints the open tabs' icon and font too.
    foreach ($settings in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal*\LocalState\settings.json') -ErrorAction SilentlyContinue)) {
        try { $settings.LastWriteTime = Get-Date } catch { }
    }
    "terminal profiles: $TerminalFragmentFile"
}
