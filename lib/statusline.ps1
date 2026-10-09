# Adds/removes the block in the user's bash statusline script that snapshots rate limits to usage.json.

$script:BlockStart = '# >>> ClaudeTray'
$script:BlockEnd = '# <<< ClaudeTray'

# Bash block: writes only to the snapshot file (never stdout) and skips when jq or rate_limits is missing.
$script:StatuslineBlock = @'
# >>> ClaudeTray: snapshot plan rate limits for the tray widget (file only, never stdout)
tray_jq="${JQ_BIN:-$(command -v jq 2>/dev/null)}"
if [ -n "$tray_jq" ]; then
  tray_dir="$HOME/.claude/usage-tray"
  mkdir -p "$tray_dir" 2>/dev/null
  if printf '%s' "$input" | "$tray_jq" -c 'select(.rate_limits != null) | {rate_limits: .rate_limits, updated_at: now}' > "$tray_dir/usage.json.tmp" 2>/dev/null && [ -s "$tray_dir/usage.json.tmp" ]; then
    mv -f "$tray_dir/usage.json.tmp" "$tray_dir/usage.json" 2>/dev/null
  else
    rm -f "$tray_dir/usage.json.tmp" 2>/dev/null
  fi
fi
# <<< ClaudeTray
'@

function Get-StatuslineScriptPath {
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    $settings = Read-JsonFile $settingsPath
    if (-not $settings -or -not $settings.statusLine -or -not $settings.statusLine.command) { return $null }
    $match = [regex]::Match([string]$settings.statusLine.command, '(\S+\.sh)')
    if (-not $match.Success) { return $null }
    $path = $match.Groups[1].Value -replace '^~', $env:USERPROFILE
    $path = $path -replace '/', '\'
    if (Test-Path -LiteralPath $path) { return $path }
    $null
}

function Read-TextFile([string]$Path) {
    [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Inserts the block right after the line that reads stdin (input=$(cat)), keeping the file's line endings.
function Add-StatuslineBlock([string]$Text) {
    if ($Text.Contains($script:BlockStart)) { return $Text }
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = ($script:StatuslineBlock -replace "`r`n", "`n") -replace "`n", $nl
    $lines = $Text -split "`r?`n", -1
    $anchor = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*jq\(\)\s*\{') { $anchor = $i; break }
    }
    if ($anchor -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*input=\$\(cat\)') { $anchor = $i; break }
        }
    }
    if ($anchor -lt 0) { throw 'statusline script does not read stdin into $input; add the block manually' }
    $before = $lines[0..$anchor] -join $nl
    $after = if ($anchor + 1 -lt $lines.Count) { $lines[($anchor + 1)..($lines.Count - 1)] -join $nl } else { '' }
    $before + $nl + $nl + $block + $nl + $after
}

function Remove-StatuslineBlockText([string]$Text) {
    $pattern = '(\r?\n)?' + [regex]::Escape($script:BlockStart) + '[\s\S]*?' + [regex]::Escape($script:BlockEnd) + '\r?\n'
    [regex]::Replace($Text, $pattern, '')
}

function Install-StatuslineBlock([string]$Path) {
    $text = Read-TextFile $Path
    if ($text.Contains($script:BlockStart)) { return 'already installed' }
    $backup = "$Path.bak-claudetray"
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $Path -Destination $backup }
    Write-TextFile $Path (Add-StatuslineBlock $text)
    "installed, backup at $backup"
}

function Uninstall-StatuslineBlock([string]$Path) {
    $text = Read-TextFile $Path
    if (-not $text.Contains($script:BlockStart)) { return 'not installed' }
    Write-TextFile $Path (Remove-StatuslineBlockText $text)
    'removed'
}
