# Adds/removes the block in the user's bash statusline script that snapshots rate limits to usage.json.

$script:BlockStart = '# >>> ClaudeTray'
$script:BlockEnd = '# <<< ClaudeTray'

# Bash block: writes only to its files (never stdout): the plan snapshot when rate_limits come, and each session's line.
$script:StatuslineBlock = @'
# >>> ClaudeTray: snapshot plan rate limits for the tray widget (file only, never stdout)
tray_jq="${JQ_BIN:-$(command -v jq 2>/dev/null)}"
if [ -n "$tray_jq" ]; then
  tray_dir="$HOME/.claude/usage-tray"
  mkdir -p "$tray_dir" 2>/dev/null
  # One jq for both lines: the plan's rate limits (empty without them) and this session's line for the phone.
  tray_out=$(printf '%s' "$input" | "$tray_jq" -r '(if .rate_limits != null then ({rate_limits: .rate_limits, updated_at: now} | tojson) else "" end),
    ({id: (.session_id // ""), model: (.model.display_name // ""), effort: (.effort.level // ""), dir: (.workspace.current_dir // .cwd // ""),
      context: (.context_window.used_percentage // null | if . == null then null else floor end),
      cost: (.cost.total_cost_usd // null | if . == null then null else (. * 100 | round) / 100 end),
      start: (.cost.total_duration_ms // null | if . == null then null else ((now - . / 1000) / 60 | floor) * 60 end)} | tojson)' 2>/dev/null)
  tray_snap="${tray_out%%$'\n'*}"
  tray_line="${tray_out#*$'\n'}"; [ "$tray_line" = "$tray_out" ] && tray_line=""
  if [ -n "$tray_snap" ]; then
    # Rewritten only when the limits change or the copy is a minute old: a statusline can run every second in
    # every session and each write is a Defender scan (a pile of them can hang Defender, and PowerShell with it).
    tray_old=""; [ -f "$tray_dir/usage.json" ] && IFS= read -r -d '' tray_old < "$tray_dir/usage.json"
    tray_at="${tray_old##*\"updated_at\":}"; tray_at="${tray_at%%[.\}]*}"
    [[ "$tray_at" =~ ^[0-9]+$ ]] || tray_at=0
    printf -v tray_now '%(%s)T' -1
    # Each session reports the limits of its own last reply, so an idle one keeps sending old numbers. Within a
    # window usage only grows: a lower percentage for the same reset, or an older reset, is stale and not written.
    tray_stale=0
    for tray_w in five_hour seven_day; do
      tray_ru="\"$tray_w\"[[:space:]]*:[[:space:]]*\{[^}]*\"used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+)"
      tray_rr="\"$tray_w\"[[:space:]]*:[[:space:]]*\{[^}]*\"resets_at\"[[:space:]]*:[[:space:]]*([0-9]+)"
      [[ "$tray_snap" =~ $tray_ru ]] || continue; tray_nu=${BASH_REMATCH[1]}
      [[ "$tray_snap" =~ $tray_rr ]] || continue; tray_nr=${BASH_REMATCH[1]}
      [[ "$tray_old" =~ $tray_ru ]] || continue; tray_ou=${BASH_REMATCH[1]}
      [[ "$tray_old" =~ $tray_rr ]] || continue; tray_or=${BASH_REMATCH[1]}
      # One window's reset can differ by seconds between sources; the next window resets hours later.
      if (( tray_nr < tray_or - 600 || (tray_nr <= tray_or + 600 && tray_nu < tray_ou) )); then tray_stale=1; fi
    done
    if (( tray_stale )); then
      :
    elif [ "${tray_old%,\"updated_at\"*}" != "${tray_snap%,\"updated_at\"*}" ] || (( tray_now - tray_at >= 60 )); then
      printf '%s' "$tray_snap" > "$tray_dir/usage.json.tmp.$$" 2>/dev/null && mv -f "$tray_dir/usage.json.tmp.$$" "$tray_dir/usage.json" 2>/dev/null
    fi
  fi
  # This session's line (model, effort, folder, context, cost, start), shown on the phone (lib\mobile.ps1): one small
  # file per session, rewritten only when it changes (the start is kept to the minute, so not on every run).
  tray_sid="${tray_line#*\"id\":\"}"; tray_sid="${tray_sid%%\"*}"; tray_sid="${tray_sid//[^A-Za-z0-9-]/}"
  if [ -n "$tray_line" ] && [ -n "$tray_sid" ]; then
    mkdir -p "$tray_dir/status" 2>/dev/null
    tray_old=""; [ -f "$tray_dir/status/$tray_sid.json" ] && IFS= read -r -d '' tray_old < "$tray_dir/status/$tray_sid.json"
    if [ "$tray_old" != "$tray_line" ]; then
      printf '%s' "$tray_line" > "$tray_dir/status/$tray_sid.json.tmp.$$" 2>/dev/null && mv -f "$tray_dir/status/$tray_sid.json.tmp.$$" "$tray_dir/status/$tray_sid.json" 2>/dev/null
    fi
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
    if ($text.Contains($script:BlockStart)) {
        # An update brings a newer block: swap the old one for it in place (the script may have changed around it
        # since it was added), so a fix in the block reaches installed PCs.
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $block = ($script:StatuslineBlock -replace "`r`n", "`n") -replace "`n", $nl
        $pattern = [regex]::Escape($script:BlockStart) + '[\s\S]*?' + [regex]::Escape($script:BlockEnd)
        $updated = [regex]::Replace($text, $pattern, { param($m) $block.TrimEnd("`r", "`n") }, 'None')
        if ($updated -eq $text) { return 'already installed' }
        Write-TextFile $Path $updated
        return 'updated'
    }
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
