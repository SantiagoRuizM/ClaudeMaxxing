# Consumption forecast for Estadisticas > Consumo: how much the open 5-hour window will have spent when it
# closes, from what it has spent so far, the pace of the last hour and what you usually spend at those hours
# (lib\stats.cs gives the history). Consumption is measured as the API-equivalent cost (tokens times the
# price of each model), which follows the plan's limits better than raw tokens: a cache read costs a tenth
# of an input token and Opus several times Haiku. When the plan's own percentage is known (usage.json), the
# forecast is calibrated with it: cost so far / percent used = what 1 % of your window is worth.
# Prices: the table of the installed Ponytail plugin (github.com/DietrichGebert/ponytail, MIT), kept up to
# date by Ponytail itself; lib\stats.cs has a copy for when it is not installed. Keep this file ASCII.

# Ponytail's band importer, newest installed copy first: the plugin cache, then its marketplace clone.
function Find-PonytailBandImport([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $found = @()
    $cache = Join-Path $ClaudeHome 'plugins\cache\ponytail'
    if (Test-Path -LiteralPath $cache) {
        $found += @(Get-ChildItem -LiteralPath $cache -Recurse -Filter 'ponytail-band-import.js' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    }
    $market = Join-Path $ClaudeHome 'plugins\marketplaces\ponytail\hooks\ponytail-band-import.js'
    if (Test-Path -LiteralPath $market) { $found += Get-Item -LiteralPath $market }
    if ($found.Count) { return $found[0].FullName }
    $null
}

# The PRICES table of ponytail-band-import.js as model -> 5 numbers (USD per million tokens: input, 5-minute
# cache write, 1-hour cache write, cache read, output). Rows that point at a named array (OPUS) resolve it.
function ConvertFrom-PonytailPrices([string]$Js) {
    $table = [ordered]@{}
    if (-not $Js) { return $table }
    $named = @{}
    foreach ($m in [regex]::Matches($Js, 'const\s+([A-Z_0-9]+)\s*=\s*\[([^\]]+)\]')) { $named[$m.Groups[1].Value] = $m.Groups[2].Value }
    $block = [regex]::Match($Js, 'const\s+PRICES\s*=\s*\{([\s\S]*?)\};')
    if (-not $block.Success) { return $table }
    foreach ($m in [regex]::Matches($block.Groups[1].Value, "'([^']+)'\s*:\s*(\[[^\]]+\]|[A-Z_0-9]+)")) {
        $value = $m.Groups[2].Value
        $list = if ($value.StartsWith('[')) { $value.Trim('[', ']') } elseif ($named.ContainsKey($value)) { $named[$value] } else { $null }
        if (-not $list) { continue }
        $numbers = @($list -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($numbers.Count -ne 5) { continue }
        try { $table[$m.Groups[1].Value] = [double[]]@($numbers | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }) } catch { }
    }
    $table
}

# @{ Json; Source } for [ClaudeMaxxing.Stats]::SetPrices, or $null without Ponytail.
function Get-PonytailPrices([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $file = Find-PonytailBandImport $ClaudeHome
    if (-not $file) { return $null }
    $table = ConvertFrom-PonytailPrices ([IO.File]::ReadAllText($file))
    if ($table.Count -eq 0) { return $null }
    $version = ''
    $dir = Split-Path -Parent (Split-Path -Parent $file)
    $manifest = Read-JsonFile (Join-Path $dir 'plugin.json')
    if ($manifest -and $manifest.version) { $version = ' ' + $manifest.version }
    elseif ((Split-Path -Leaf $dir) -match '^\d+\.\d+') { $version = ' ' + (Split-Path -Leaf $dir) }
    @{ Json = (ConvertTo-Json -InputObject $table -Compress -Depth 3); Source = "Ponytail$version" }
}

# recentHours ("yyyy-MM-dd HH" -> [tokens, cost]) as a hashtable.
function ConvertTo-HourTable($RecentHours) {
    $table = @{}
    if ($null -eq $RecentHours) { return $table }
    if ($RecentHours -is [System.Collections.IDictionary]) { foreach ($k in $RecentHours.Keys) { $table[[string]$k] = @($RecentHours[$k]) } }
    else { foreach ($p in $RecentHours.PSObject.Properties) { $table[$p.Name] = @($p.Value) } }
    $table
}

# When the 5-hour window that is open now started: from the plan when it is known, otherwise rebuilt the way
# Claude starts them (on the hour of the first activity after the previous window ended). $null: none open.
function Get-OpenWindowStart($Hours, $Session, [datetime]$Now) {
    if ($Session -and $Session.Active -and $Session.ResetsAt -and $Session.ResetsAt -gt $Now) { return $Session.ResetsAt.AddHours(-5) }
    $start = $null
    $end = [datetime]::MinValue
    foreach ($key in @($Hours.Keys | Sort-Object)) {
        $at = [datetime]::ParseExact($key, 'yyyy-MM-dd HH', [Globalization.CultureInfo]::InvariantCulture)
        if ($at -gt $Now) { continue }
        if ($at -ge $end) { $start = $at; $end = $at.AddHours(5) }
    }
    if ($start -and $end -gt $Now) { return $start }
    $null
}

# What the open window has spent: @{ Cost; Tokens } from $Start to $Now.
function Measure-WindowSoFar($Hours, [datetime]$Start, [datetime]$Now) {
    $cost = 0.0; $tokens = 0.0
    $from = $Start.ToString('yyyy-MM-dd HH')
    $to = $Now.ToString('yyyy-MM-dd HH')
    foreach ($key in $Hours.Keys) {
        if ([string]::CompareOrdinal($key, $from) -lt 0 -or [string]::CompareOrdinal($key, $to) -gt 0) { continue }
        $tokens += [double]$Hours[$key][0]; $cost += [double]$Hours[$key][1]
    }
    @{ Cost = $cost; Tokens = $tokens }
}

# The forecast for the open window. $Usage: a range's "usage" from stats.json; $Session: the usage view's
# 5-hour window (Active, Percent, ResetsAt), or $null. Returns $null when no window is open.
function Get-UsageForecast($Usage, $Session, [datetime]$Now) {
    if (-not $Usage) { return $null }
    $hours = ConvertTo-HourTable $Usage.recentHours
    $start = Get-OpenWindowStart $hours $Session $Now
    if (-not $start) { return $null }
    $end = $start.AddHours(5)
    $sofar = Measure-WindowSoFar $hours $start $Now
    $elapsed = [Math]::Max(0.0, ($Now - $start).TotalHours)
    $remaining = [Math]::Max(0.0, ($end - $Now).TotalHours)

    # The pace of the last 60 minutes: this clock hour so far and the part of the previous one still inside.
    $fraction = $Now.Minute / 60.0
    $current = $hours[$Now.ToString('yyyy-MM-dd HH')]
    $previous = $hours[$Now.AddHours(-1).ToString('yyyy-MM-dd HH')]
    $lastHour = 0.0
    if ($current) { $lastHour += [double]$current[1] }
    if ($previous -and $Now.AddHours(-1) -ge $start) { $lastHour += [double]$previous[1] * (1 - $fraction) }
    # What you usually spend in each clock hour on a day you use Claude.
    $days = [Math]::Max(1, [int]$Usage.days)
    $hourly = @($Usage.hourlyCost)
    $typical = 0.0
    $t = $Now
    while ($t -lt $end) {
        $next = [datetime]::new($t.Year, $t.Month, $t.Day, $t.Hour, 0, 0).AddHours(1)
        if ($next -gt $end) { $next = $end }
        if ($hourly.Count -eq 24) { $typical += [double]$hourly[$t.Hour] / $days * ($next - $t).TotalHours }
        $t = $next
    }
    # In the first hour $lastHour covers only the time since the window opened: make it a rate per hour.
    $lastHour = $lastHour / [Math]::Max([Math]::Min(1.0, $elapsed), 1.0 / 12)
    # Early in the window the last hour says little; after an hour it weighs half.
    $weight = 0.5 * [Math]::Min(1.0, $elapsed)
    $projected = $sofar.Cost + $weight * $lastHour * $remaining + (1 - $weight) * $typical
    $perToken = if ($sofar.Cost -gt 0 -and $sofar.Tokens -gt 0) { $sofar.Tokens / $sofar.Cost } elseif ([double]$Usage.cost -gt 0) { [double]$Usage.tokens / [double]$Usage.cost } else { 0 }

    $forecast = [ordered]@{
        Start = $start; End = $end; Elapsed = $elapsed; Remaining = $remaining
        Cost = $sofar.Cost; Tokens = $sofar.Tokens; LastHourCost = $lastHour; TypicalRest = $typical
        ProjectedCost = $projected; ProjectedTokens = $projected * $perToken
        Average = $(if ($Usage.windowCost) { [double]$Usage.windowCost.avg } else { 0 })
        Percent = $null; ProjectedPercent = $null; CostPerPercent = $null; Capacity = $null; LimitAt = $null
    }
    $forecast.VsAverage = if ($forecast.Average -gt 0) { $projected / $forecast.Average } else { $null }
    # Calibrated with the plan: only with a real percentage and some spending behind it.
    if ($Session -and $Session.Active -and [double]$Session.Percent -ge 2 -and $sofar.Cost -gt 0.05) {
        $perPercent = $sofar.Cost / [double]$Session.Percent
        $forecast.Percent = [double]$Session.Percent
        $forecast.CostPerPercent = $perPercent
        $forecast.Capacity = $perPercent * 100
        $forecast.ProjectedPercent = [Math]::Min(999, $projected / $perPercent)
        $rate = if ($remaining -gt 0) { ($projected - $sofar.Cost) / $remaining } else { 0 }
        if ($forecast.ProjectedPercent -ge 100 -and $rate -gt 0) {
            $forecast.LimitAt = $Now.AddHours((100 - [double]$Session.Percent) * $perPercent / $rate)
        }
    }
    [pscustomobject]$forecast
}

# With no window open: what one started now would spend. The average of the windows that started at this
# hour when there are at least 3 of them, otherwise the average of all. @{ Cost; Basis }.
function Get-NextWindowEstimate($Usage, [datetime]$Now) {
    $byHour = @($Usage.windowsByStartHour)
    $counts = @($Usage.windowsByStartHourCount)
    if ($byHour.Count -eq 24 -and $counts.Count -eq 24 -and [int]$counts[$Now.Hour] -ge 3) {
        return @{ Cost = [double]$byHour[$Now.Hour]; Basis = ('media de ' + [int]$counts[$Now.Hour] + ' que empezaron a esta hora') }
    }
    @{ Cost = $(if ($Usage.windowCost) { [double]$Usage.windowCost.avg } else { 0 }); Basis = 'tu media' }
}

# How alike the windows (or sessions) are, from their coefficient of variation.
function Format-UsageSpread([double]$Cv) {
    if ($Cv -le 0) { return 'sin datos' }
    if ($Cv -lt 0.25) { return 'muy parecidas' }
    if ($Cv -lt 0.5) { return 'parecidas' }
    if ($Cv -lt 0.9) { return 'variables' }
    'muy variables'
}

# "$25,95" (es-ES digits), "$0,04", "-".
function Format-Usd($Value) {
    if ($null -eq $Value) { return '-' }
    $v = [double]$Value
    $culture = [Globalization.CultureInfo]::GetCultureInfo('es-ES')
    if ($v -ge 100) { return '$' + $v.ToString('N0', $culture) }
    '$' + $v.ToString('N2', $culture)
}
