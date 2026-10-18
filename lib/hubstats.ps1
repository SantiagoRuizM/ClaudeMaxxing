# "Estadisticas" in the ClaudeMaxxing window: when and how much you work with Claude Code, from its own
# transcripts. lib\stats.cs reads them on a background thread (cached per file in $StatsCacheFile) and writes
# $StatsFile; this file starts that scan, keeps the result in $script:Hub.Cache.Stats and draws it in four
# tabs: Resumen, Horarios, Proyectos, Modelos y herramientas. Charts are one hue (the accent): bars for
# amounts, a light-to-dark heatmap for day x hour; hovering a bar or a cell reads its value out.
# Drawing a tab takes a few hundred ms in PowerShell, too slow to redo on every mouse move: the tab body is
# drawn once into a bitmap (again when the data, tab or range change) and each paint copies it and draws only
# the hovered bar or cell and its value on top ($script:Hub.StatsOverlay).
# Needs hub.ps1. Keep this file ASCII.

$script:StatsTask = $null
$StatsMaxAgeMinutes = 10
$script:HubWeekdays = @('Lun', 'Mar', (Tx 'Mi\u00e9'), 'Jue', 'Vie', (Tx 'S\u00e1b'), 'Dom')
$script:HubWeekdayNames = @('lunes', 'martes', (Tx 'mi\u00e9rcoles'), 'jueves', 'viernes', (Tx 's\u00e1bado'), 'domingo')
$script:HubMonths = @('ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic')
$script:HubCulture = [Globalization.CultureInfo]::GetCultureInfo('es-ES')
$script:StatsTabs = @(
    @{ Id = 'summary'; Label = 'Resumen' },
    @{ Id = 'hours'; Label = 'Horarios' },
    @{ Id = 'projects'; Label = 'Proyectos' },
    @{ Id = 'models'; Label = 'Modelos y herramientas' }
)

# ---------------------------------------------------------------- formatting

function Format-HubDuration([double]$Seconds) {
    $minutes = [int][Math]::Round($Seconds / 60)
    if ($minutes -lt 60) { return "$minutes min" }
    $hours = [int][Math]::Floor($minutes / 60)
    if ($hours -ge 10) { return "$hours h" }
    $rest = $minutes % 60
    if ($rest) { return "$hours h $rest min" }
    "$hours h"
}

function Format-HubNumber($Value) { ([double]$Value).ToString('N0', $script:HubCulture) }

function Format-HubTokens($Value) {
    $v = [double]$Value
    if ($v -ge 1e9) { return ($v / 1e9).ToString('0.0', $script:HubCulture) + ' mil M' }
    if ($v -ge 1e6) { return ($v / 1e6).ToString('0.0', $script:HubCulture) + ' M' }
    if ($v -ge 1e3) { return ($v / 1e3).ToString('0.0', $script:HubCulture) + ' k' }
    [string][int]$v
}

# "2026-09-28" -> "28 sep"
function Format-HubDay([string]$Day) {
    try {
        $date = [datetime]::ParseExact($Day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        return '{0} {1}' -f $date.Day, $script:HubMonths[$date.Month - 1]
    } catch { $Day }
}

function Format-HubWeekdayDay([string]$Day) {
    try {
        $date = [datetime]::ParseExact($Day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        return $script:HubWeekdays[([int]$date.DayOfWeek + 6) % 7] + ' ' + (Format-HubDay $Day)
    } catch { $Day }
}

# "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5"
function Format-ModelName([string]$Model) {
    if ($Model -match '^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$') {
        $name = $Matches[1].Substring(0, 1).ToUpper() + $Matches[1].Substring(1) + ' ' + $Matches[2]
        if ($Matches[3]) { $name += '.' + $Matches[3] }
        return $name
    }
    $Model
}

function Format-HubPercent([double]$Part, [double]$Total) {
    if ($Total -le 0) { return '0 %' }
    [string][int][Math]::Round(100 * $Part / $Total) + ' %'
}

# ---------------------------------------------------------------- data

function Import-StatsNative {
    if ('ClaudeMaxxing.Stats' -as [type]) { return }
    $text = [IO.File]::ReadAllText((Join-Path $TrayRoot 'lib\stats.cs'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $BinDir "ClaudeMaxxingStats-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
        # Compile to a private name first so a concurrent run never loads a half-written file.
        $tmp = Join-Path $BinDir "ClaudeMaxxingStats-$hash-$PID.dll"
        Add-Type -TypeDefinition $text -ReferencedAssemblies System.Web.Extensions, System.Core -OutputAssembly $tmp -OutputType Library
        try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $BinDir -Filter 'ClaudeMaxxingStats-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    Add-Type -Path $dll
}

function Get-StatsAgeMinutes($Stats) {
    try { return ((Get-Date) - [datetime]$Stats.scannedAt).TotalMinutes } catch { return [double]::MaxValue }
}

# Shows the last result right away and scans again when it is older than $StatsMaxAgeMinutes (or on -Force).
function Update-HubStats([switch]$Force) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Preview) { return }
    if (-not $hub.Cache.Stats -and (Test-Path -LiteralPath $StatsFile)) { $hub.Cache.Stats = Read-JsonFile $StatsFile }
    $hub.Cache.ToolStats = Get-HubToolStats
    if ($Force -or -not $hub.Cache.Stats -or (Get-StatsAgeMinutes $hub.Cache.Stats) -ge $StatsMaxAgeMinutes) { Start-HubStatsScan }
}

function Start-HubStatsScan {
    if ($script:StatsTask -and -not $script:StatsTask.IsCompleted) { return }
    $script:Hub.StatsError = ''
    try {
        Import-StatsNative
        $projects = Join-Path $env:USERPROFILE '.claude\projects'
        $script:StatsTask = [ClaudeMaxxing.Stats]::ScanAsync($projects, $StatsCacheFile, $StatsFile)
    } catch {
        $script:Hub.StatsError = $_.Exception.Message
    }
    if ($script:HubDialog) { $script:HubDialog.Invalidate() }
}

# Called from the window's timer: takes the result of a finished scan.
function Complete-HubStatsScan {
    $task = $script:StatsTask
    if (-not $task -or -not $task.IsCompleted) { return }
    $script:StatsTask = $null
    if ($task.IsFaulted) {
        $script:Hub.StatsError = $task.Exception.GetBaseException().Message
        return
    }
    try { $script:Hub.Cache.Stats = $task.Result | ConvertFrom-Json } catch { $script:Hub.StatsError = $_.Exception.Message }
}

# Counts from the other tools, read from their own files.
function Get-HubToolStats {
    $calls = Get-WhisperCalls 1000
    $minutes = 0; $answers = 0
    foreach ($call in $calls) { $minutes += $call.Minutes; $answers += $call.Answers }
    $runs = @(); $opens = 0
    try { if (Test-Path -LiteralPath $RunLogFile) { $runs = @([IO.File]::ReadAllLines($RunLogFile) | Where-Object { $_.Trim() }) } } catch { }
    try { if (Test-Path -LiteralPath $SessionLogFile) { $opens = @([IO.File]::ReadAllLines($SessionLogFile) | Where-Object { $_ -match '^\S+ slot \d+ hwnd ' }).Count } } catch { }
    @{
        Calls = $calls.Count; CallMinutes = $minutes; CallAnswers = $answers
        Runs = $runs.Count; RunsOk = @($runs | Where-Object { $_ -match 'ok=True' }).Count
        MenuOpens = $opens
        Paired = $(if ($script:Bridge) { @($script:Bridge.Peers).Count } else { 0 })
    }
}

# ---------------------------------------------------------------- drawing helpers

# One hue in four steps, from faint to the full accent (nothing: the background), so the levels read apart.
function Get-HubShade([double]$Fraction) {
    $P = $script:Palette
    if ($Fraction -le 0) { return $P.Back }
    $level = [Math]::Max(1, [Math]::Min(4, [int][Math]::Ceiling(4 * $Fraction)))
    $t = 0.22 + 0.78 * ($level - 1) / 3
    $a = $P.Back; $b = $P.Accent
    [System.Drawing.Color]::FromArgb([int]($a.R + ($b.R - $a.R) * $t), [int]($a.G + ($b.G - $a.G) * $t), [int]($a.B + ($b.B - $a.B) * $t))
}

# A number with its label above and a note below.
function Draw-HubStat($G, [System.Drawing.Rectangle]$Rect, [string]$Label, [string]$Value, [string]$Sub, $SubColor = $null) {
    $P = $script:Palette
    $F = $script:Fonts
    Draw-HubCard $G $Rect
    $x = $Rect.X + (Px 14)
    $w = $Rect.Width - (Px 28)
    Draw-Text $G $Label $F.Caps $P.Muted $x ($Rect.Y + (Px 10)) $w (Px 18)
    Draw-Text $G $Value $F.Number $P.Text $x ($Rect.Y + (Px 28)) $w (Px 26)
    if ($Sub) { Draw-Text $G $Sub $F.Small $(if ($SubColor) { $SubColor } else { $P.Muted }) $x ($Rect.Y + (Px 54)) $w (Px 16) }
}

# Vertical bars on a baseline, rounded only at the top. Hovering a bar shows its tip in $Readout.
function Draw-HubBars($G, $Map, [string]$Id, [System.Drawing.Rectangle]$Rect, [double[]]$Values, [string[]]$Labels, [string[]]$Tips, [System.Drawing.Rectangle]$Readout) {
    $P = $script:Palette
    $F = $script:Fonts
    $n = $Values.Count
    if ($n -eq 0) { return $null }
    $max = ($Values | Measure-Object -Maximum).Maximum
    $labelH = Px 16
    $plotH = $Rect.Height - $labelH - (Px 4)
    $base = $Rect.Y + $plotH
    $slot = $Rect.Width / $n
    $gap = [Math]::Max((Px 2), [int]($slot * 0.22))
    $barW = [Math]::Max(1, [int]($slot - $gap))
    $radius = [Math]::Min((Px 4), [int]($barW / 2))
    for ($i = 0; $i -lt $n; $i++) {
        $x = $Rect.X + [int]($i * $slot) + [int]($gap / 2)
        $hitId = "$Id-$i"
        $bar = $null
        if ($max -gt 0 -and $Values[$i] -gt 0) {
            $h = [Math]::Max((Px 3), [int]($plotH * $Values[$i] / $max))
            $bar = New-Rect $x ($base - $h) $barW $h
            Draw-HubBar $G $bar $radius $P.Accent
        }
        $script:Hub.StatsOverlay[$hitId] = @{ Bar = $bar; Radius = $radius; Tip = $Tips[$i]; Readout = $Readout }
        if ($Labels -and $Labels[$i]) {
            $lw = Px 60
            Draw-Text $G $Labels[$i] $F.Small $P.Faint ($x + [int]($barW / 2) - [int]($lw / 2)) ($base + (Px 3)) $lw $labelH 'Center'
        }
        Add-Hit $Map $hitId (New-Rect ($x - [int]($gap / 2)) $Rect.Y ([int][Math]::Ceiling($slot)) $plotH) {}
    }
    $pen = New-Object System.Drawing.Pen($P.Border)
    $G.DrawLine($pen, $Rect.X, $base, $Rect.Right, $base)
    $pen.Dispose()
}

# A bar rounded at the top and square on its baseline.
function Draw-HubBar($G, [System.Drawing.Rectangle]$Bar, [int]$Radius, [System.Drawing.Color]$Color) {
    Fill-Round $G $Bar $Radius $Color
    if ($Bar.Height -gt $Radius) {
        $brush = New-Object System.Drawing.SolidBrush($Color)
        $G.FillRectangle($brush, $Bar.X, $Bar.Bottom - $Radius, $Bar.Width, $Radius)
        $brush.Dispose()
    }
}

# What a hovered bar or heatmap cell adds on top of the cached tab: its highlight and its value.
function Draw-StatsOverlay($G, $Overlay) {
    $P = $script:Palette
    if ($Overlay.Bar) { Draw-HubBar $G $Overlay.Bar $Overlay.Radius $P.AccentHover }
    if ($Overlay.Cell) { Stroke-Round $G $Overlay.Cell (Px 3) $P.Text 1.5 }
    if ($Overlay.Tip -and $Overlay.Readout) {
        $r = $Overlay.Readout
        $brush = New-Object System.Drawing.SolidBrush($P.Surface)
        $G.FillRectangle($brush, $r)
        $brush.Dispose()
        Draw-Text $G $Overlay.Tip $script:Fonts.Small $P.Text $r.X $r.Y $r.Width $r.Height 'Right'
    }
}

# A horizontal bar with a name and its value, for ranked lists.
function Draw-HubRankRow($G, $Map, $Hover, [string]$Id, [System.Drawing.Rectangle]$Row, [string]$Name, [string]$Value, [double]$Fraction, [string]$Sub) {
    $P = $script:Palette
    $F = $script:Fonts
    $nameW = [int]($Row.Width * 0.42)
    Draw-Text $G $Name $F.Body $P.Text ($Row.X + (Px 8)) $Row.Y ($nameW - (Px 12)) $(if ($Sub) { (Px 20) } else { $Row.Height })
    if ($Sub) { Draw-Text $G $Sub $F.Small $P.Muted ($Row.X + (Px 8)) ($Row.Y + (Px 18)) ($nameW - (Px 12)) (Px 16) }
    $valueW = Px 92
    $track = New-Rect ($Row.X + $nameW) ($Row.Y + [int]($Row.Height / 2) - (Px 4)) ($Row.Width - $nameW - $valueW - (Px 8)) (Px 8)
    if ($Fraction -gt 0) {
        Fill-Round $G (New-Rect $track.X $track.Y ([Math]::Max((Px 4), [int]($track.Width * [Math]::Min(1.0, $Fraction)))) $track.Height) (Px 4) $P.Accent
    }
    Draw-Text $G $Value $F.Small $P.Text ($Row.Right - $valueW) $Row.Y ($valueW - (Px 8)) $Row.Height 'Right'
}

# ---------------------------------------------------------------- section

function Draw-HubStatsSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $hub = $script:Hub
    if (-not $hub.StatsTab) { $hub.StatsTab = 'summary' }
    if (-not $hub.StatsRange) { $hub.StatsRange = 'recent' }

    # tabs and the range switch
    $x = $X0
    foreach ($tab in $script:StatsTabs) {
        $active = $hub.StatsTab -eq $tab.Id
        $font = if ($active) { $F.BodyStrong } else { $F.Body }
        $rect = New-Rect $x (Px 66) ((Measure-TextWidth $tab.Label $font) + (Px 20)) (Px 28)
        $hitId = "stab-$($tab.Id)"
        if ($active) { Fill-Round $G $rect (Px 14) $P.AccentTint } elseif ($Hover -eq $hitId) { Fill-Round $G $rect (Px 14) $P.SurfaceHover }
        Draw-Text $G $tab.Label $font $(if ($active) { $P.Accent } else { $P.Text }) $rect.X $rect.Y $rect.Width $rect.Height 'Center'
        if (-not $active) { Add-Hit $Map $hitId $rect ([scriptblock]::Create("`$script:Hub.StatsTab = '$($tab.Id)'; `$script:HubDialog.Invalidate()")) }
        $x += $rect.Width + (Px 4)
    }
    $right = $X0 + $Inner
    foreach ($range in @(@{ Id = 'all'; Label = 'Todo' }, @{ Id = 'recent'; Label = (Tx '30 d\u00edas') })) {
        $active = $hub.StatsRange -eq $range.Id
        $rect = New-Rect ($right - (Measure-TextWidth $range.Label $F.Small) - (Px 18)) (Px 68) ((Measure-TextWidth $range.Label $F.Small) + (Px 18)) (Px 24)
        $hitId = "srange-$($range.Id)"
        Fill-Round $G $rect (Px 12) $(if ($active) { $P.Accent } elseif ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
        Draw-Text $G $range.Label $F.Small $(if ($active) { $P.AccentText } else { $P.Text }) $rect.X $rect.Y $rect.Width $rect.Height 'Center'
        if (-not $active) { Add-Hit $Map $hitId $rect ([scriptblock]::Create("`$script:Hub.StatsRange = '$($range.Id)'; `$script:HubDialog.Invalidate()")) }
        $right = $rect.X - (Px 4)
    }

    # footer: when it was computed, and recompute
    $stats = $hub.Cache.Stats
    $scanning = $script:StatsTask -and -not $script:StatsTask.IsCompleted
    $footY = Px 598
    if ($scanning) {
        $footer = Tx 'Leyendo tus conversaciones de Claude Code\u2026'
    } elseif ($hub.StatsError) {
        $footer = 'No se pudo calcular: ' + $hub.StatsError
    } elseif ($stats) {
        $footer = 'Calculado a las ' + (Format-Clock ([datetime]$stats.scannedAt)) + '  ' + (Tx '\u00b7') + '  ' + (Format-HubNumber $stats.files) +
            ' conversaciones (' + (Format-HubNumber $stats.filesRead) + ' le' + (Tx '\u00ed') + 'das en ' + ([double]$stats.seconds).ToString('0.0', $script:HubCulture) + ' s)'
    } else { $footer = '' }
    Draw-Text $G $footer $F.Small $(if ($hub.StatsError) { $P.Error } else { $P.Faint }) $X0 $footY ($Inner - (Px 110)) (Px 18)
    if (-not $scanning) {
        $link = New-Rect ($X0 + $Inner - (Px 100)) $footY (Px 100) (Px 18)
        Draw-Text $G (Tx 'Recalcular \u21bb') $F.Small $(if ($Hover -eq 'stats-rescan') { $P.AccentHover } else { $P.Accent }) $link.X $link.Y $link.Width $link.Height 'Right'
        Add-Hit $Map 'stats-rescan' $link { Update-HubStats -Force }
    }

    if (-not $stats) {
        $card = New-Rect $X0 (Px 110) $Inner (Px 90)
        Draw-HubCard $G $card
        $text = if ($scanning) { Tx 'Calculando tus estad\u00edsticas. La primera vez lee todas tus conversaciones y tarda unos segundos; despu\u00e9s solo lee lo nuevo.' }
                elseif ($hub.StatsError) { $hub.StatsError } else { Tx 'Sin datos todav\u00eda: usa Claude Code y vuelve aqu\u00ed.' }
        Draw-Wrapped $G $text $F.Body $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 16)) ($card.Width - (Px 32)) (Px 60)
        return
    }
    $form = $script:HubDialog
    $ts = $hub.Cache.ToolStats
    $signature = '{0}|{1}|{2}|{3}x{4}|{5}|{6}' -f $hub.StatsTab, $hub.StatsRange, $stats.scannedAt, $form.ClientSize.Width, $form.ClientSize.Height,
        $(if ($ts) { "$($ts.Calls),$($ts.Runs),$($ts.MenuOpens),$($ts.Paired)" } else { '' }), (Get-Date).ToString('yyyyMMddHH')
    $body = New-Rect $X0 (Px 100) $Inner ($footY - (Px 100) - (Px 4))
    if ($hub.StatsSignature -ne $signature -or -not $hub.StatsBitmap) {
        if ($hub.StatsBitmap) { $hub.StatsBitmap.Dispose() }
        $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        $bg = [System.Drawing.Graphics]::FromImage($bitmap)
        $bg.Clear($P.Back)
        $bg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bodyMap = New-HitMap
        $hub.StatsOverlay = @{}
        $data = if ($hub.StatsRange -eq 'all') { $stats.all } else { $stats.recent }
        switch ($hub.StatsTab) {
            'hours'    { Draw-StatsHours $bg $bodyMap $null $X0 $Inner $data }
            'projects' { Draw-StatsProjects $bg $bodyMap $null $X0 $Inner $data }
            'models'   { Draw-StatsModels $bg $bodyMap $null $X0 $Inner $data }
            default    { Draw-StatsSummary $bg $bodyMap $null $X0 $Inner $data $stats.all }
        }
        $bg.Dispose()
        $hub.StatsBitmap = $bitmap
        $hub.StatsHits = @($bodyMap.Items)
        $hub.StatsSignature = $signature
    }
    $G.DrawImage($hub.StatsBitmap, $body, $body, [System.Drawing.GraphicsUnit]::Pixel)
    foreach ($hit in $hub.StatsHits) { [void]$Map.Items.Add($hit) }
    if ($Hover -and $hub.StatsOverlay.ContainsKey($Hover)) { Draw-StatsOverlay $G $hub.StatsOverlay[$Hover] }
}

function Get-PeakIndex($Values) {
    $best = -1; $max = 0
    for ($i = 0; $i -lt @($Values).Count; $i++) { if ([double]$Values[$i] -gt $max) { $max = [double]$Values[$i]; $best = $i } }
    $best
}

# ---- Resumen: the headline numbers, when you work most, and day by day
function Draw-StatsSummary($G, $Map, $Hover, [int]$X0, [int]$Inner, $D, $All) {
    $P = $script:Palette
    $F = $script:Fonts
    $gap = Px 10
    $w = [int](($Inner - 3 * $gap) / 4)
    $tiles = @(
        @(('HORAS CON CLAUDE'), (Format-HubDuration $D.seconds), ('en ' + (Format-HubNumber $D.activeDays) + (Tx ' d\u00edas activos'))),
        @('RACHA', ("$($All.streak) " + $(if ($All.streak -eq 1) { (Tx 'd\u00eda') } else { (Tx 'd\u00edas') })), ('la mejor: ' + $All.bestStreak)),
        @('PROMPTS', (Format-HubNumber $D.prompts), ((Format-HubNumber $D.responses) + ' respuestas')),
        @('SESIONES', (Format-HubNumber $D.sessions), ('+' + (Format-HubNumber $D.subagents) + ' subagentes'))
    )
    for ($i = 0; $i -lt 4; $i++) {
        Draw-HubStat $G (New-Rect ($X0 + $i * ($w + $gap)) (Px 104) $w (Px 74)) $tiles[$i][0] $tiles[$i][1] $tiles[$i][2]
    }
    $perDay = if ([double]$D.avgSecondsPerActiveDay -gt 0) { Format-HubDuration $D.avgSecondsPerActiveDay } else { '-' }
    $parallel = ([double]$D.parallel).ToString('0.00', $script:HubCulture) + ([string][char]0x00D7)
    $week = [double]$All.thisWeek.seconds; $lastWeek = [double]$All.lastWeek.seconds
    $weekSub = if ($lastWeek -gt 0) {
        $delta = [int][Math]::Round(100 * ($week - $lastWeek) / $lastWeek)
        $(if ($delta -ge 0) { "+$delta %" } else { "$delta %" }) + ' vs la anterior'
    } else { 'sin datos de la anterior' }
    $tiles = @(
        @((Tx 'POR D\u00cdA ACTIVO'), $perDay, ('hoy: ' + (Format-HubDuration $All.today.seconds))),
        @('ESTA SEMANA', (Format-HubDuration $week), $weekSub),
        @('EN PARALELO', $parallel, ((Format-HubDuration $D.sessionSeconds) + (Tx ' de sesi\u00f3n'))),
        @('HERRAMIENTAS', (Format-HubNumber $D.toolCalls), ('usos de ' + $D.toolKinds + ' distintas'))
    )
    for ($i = 0; $i -lt 4; $i++) {
        Draw-HubStat $G (New-Rect ($X0 + $i * ($w + $gap)) (Px 186) $w (Px 74)) $tiles[$i][0] $tiles[$i][1] $tiles[$i][2]
    }

    # when you work most
    $card = New-Rect $X0 (Px 270) $Inner (Px 70)
    Draw-HubCard $G $card
    Draw-Text $G (Tx 'CU\u00c1NDO TRABAJAS M\u00c1S') $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 10)) (Px 300) (Px 18)
    $hourly = @($D.hourly)
    $peakHour = Get-PeakIndex $hourly
    $peakDay = Get-PeakIndex @($D.weekday)
    $bands = @(@('madrugada', 0, 5), @((Tx 'ma\u00f1ana'), 6, 11), @('tarde', 12, 18), @('noche', 19, 23))
    $bandSums = @($bands | ForEach-Object { $sum = 0; for ($h = $_[1]; $h -le $_[2]; $h++) { $sum += [double]$hourly[$h] }; $sum })
    $peakBand = Get-PeakIndex $bandSums
    $total = ($hourly | Measure-Object -Sum).Sum
    $facts = @(
        @('Hora pico', $(if ($peakHour -ge 0) { '{0:00}:00' -f $peakHour + (Tx '\u2013') + ('{0:00}:00' -f (($peakHour + 1) % 24)) } else { '-' })),
        @((Tx 'D\u00eda pico'), $(if ($peakDay -ge 0) { $script:HubWeekdayNames[$peakDay].Substring(0, 1).ToUpper() + $script:HubWeekdayNames[$peakDay].Substring(1) } else { '-' })),
        @('Franja', $(if ($peakBand -ge 0) { $bands[$peakBand][0].Substring(0, 1).ToUpper() + $bands[$peakBand][0].Substring(1) + ' ' + (Format-HubPercent $bandSums[$peakBand] $total) } else { '-' })),
        @((Tx 'D\u00eda r\u00e9cord'), $(if ($D.busiestDay) { (Format-HubDay $D.busiestDay.day) + ' ' + (Tx '\u00b7') + ' ' + (Format-HubDuration $D.busiestDay.seconds) } else { '-' }))
    )
    $fw = [int](($card.Width - (Px 28)) / 4)
    for ($i = 0; $i -lt 4; $i++) {
        $fx = $card.X + (Px 14) + $i * $fw
        Draw-Text $G $facts[$i][0] $F.Small $P.Muted $fx ($card.Y + (Px 30)) ($fw - (Px 8)) (Px 16)
        Draw-Text $G $facts[$i][1] $F.BodyStrong $P.Text $fx ($card.Y + (Px 46)) ($fw - (Px 8)) (Px 20)
    }

    # day by day (30 days) or week by week (all)
    $chart = New-Rect $X0 (Px 350) $Inner (Px 238)
    Draw-HubCard $G $chart
    $plot = New-Rect ($chart.X + (Px 14)) ($chart.Y + (Px 36)) ($chart.Width - (Px 28)) ($chart.Height - (Px 46))
    if ($script:Hub.StatsRange -eq 'all') {
        $title = 'HORAS POR SEMANA'
        $items = @($D.weekly)
        $values = [double[]]@($items | ForEach-Object { [double]$_.seconds })
        $every = [Math]::Max(1, [int][Math]::Ceiling($items.Count / 7))
        $labels = [string[]]@(for ($i = 0; $i -lt $items.Count; $i++) { if (($items.Count - 1 - $i) % $every -eq 0) { Format-HubDay $items[$i].week } else { '' } })
        $tips = [string[]]@($items | ForEach-Object { 'Semana del ' + (Format-HubDay $_.week) + ': ' + (Format-HubDuration $_.seconds) + ', ' + (Format-HubNumber $_.prompts) + ' prompts' })
    } else {
        $title = (Tx 'HORAS POR D\u00cdA')
        $items = @($D.daily)
        $values = [double[]]@($items | ForEach-Object { [double]$_.seconds })
        $labels = [string[]]@(for ($i = 0; $i -lt $items.Count; $i++) { if (($items.Count - 1 - $i) % 7 -eq 0) { Format-HubDay $items[$i].day } else { '' } })
        $tips = [string[]]@($items | ForEach-Object { (Format-HubWeekdayDay $_.day) + ': ' + (Format-HubDuration $_.seconds) + ', ' + (Format-HubNumber $_.prompts) + ' prompts' })
    }
    $readout = New-Rect ($chart.X + (Px 160)) ($chart.Y + (Px 10)) ($chart.Width - (Px 174)) (Px 18)
    Draw-HubBars $G $Map 'sday' $plot $values $labels $tips $readout
    Draw-Text $G $title $F.Caps $P.Muted ($chart.X + (Px 14)) ($chart.Y + (Px 10)) (Px 200) (Px 18)
    $max = ($values | Measure-Object -Maximum).Maximum
    Draw-Text $G ((Tx 'm\u00e1x. ') + (Format-HubDuration $max) + (Tx '  \u00b7  pasa el rat\u00f3n por una barra')) $F.Small $P.Faint $readout.X $readout.Y $readout.Width $readout.Height 'Right'
}

# ---- Horarios: day of week x hour, by hour, and the share of each part of the day
function Draw-StatsHours($G, $Map, $Hover, [int]$X0, [int]$Inner, $D) {
    $P = $script:Palette
    $F = $script:Fonts
    $heat = @($D.heat)
    $max = ($heat | Measure-Object -Maximum).Maximum
    $card = New-Rect $X0 (Px 104) $Inner (Px 236)
    Draw-HubCard $G $card
    Draw-Text $G (Tx 'D\u00cdA \u00d7 HORA (TIEMPO CON CLAUDE)') $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 10)) (Px 260) (Px 18)
    $labelW = Px 34
    $totalW = Px 74
    $gx = $card.X + (Px 14) + $labelW
    $cellW = [int](($card.Width - (Px 28) - $labelW - $totalW) / 24)
    $cellH = Px 22
    $gy = $card.Y + (Px 36)
    # cells and bars read their value out in the hour chart's title line
    $readout = New-Rect ($X0 + (Px 174)) (Px 360) ($Inner - (Px 188)) (Px 18)
    $weekday = @($D.weekday)
    $dayMax = ($weekday | Measure-Object -Maximum).Maximum
    # (not $d: PowerShell names ignore case, and $D is the data)
    for ($row = 0; $row -lt 7; $row++) {
        $y = $gy + $row * ($cellH + (Px 3))
        Draw-Text $G $script:HubWeekdays[$row] $F.Small $P.Muted ($card.X + (Px 14)) $y $labelW $cellH
        for ($h = 0; $h -lt 24; $h++) {
            $value = [double]$heat[$row * 24 + $h]
            $cell = New-Rect ($gx + $h * $cellW) $y ($cellW - (Px 3)) $cellH
            $hitId = "heat-$row-$h"
            $fraction = if ($max -gt 0) { $value / $max } else { 0 }
            Fill-Round $G $cell (Px 3) (Get-HubShade $fraction)
            $script:Hub.StatsOverlay[$hitId] = @{ Cell = $cell; Readout = $readout
                Tip = (Tx $script:HubWeekdayNames[$row]) + (' {0:00}:00' -f $h) + (Tx '\u2013') + ('{0:00}:00' -f (($h + 1) % 24)) + ': ' + (Format-HubDuration $value) + ' en total' }
            Add-Hit $Map $hitId $cell {}
        }
        # the day's total, as a bar after its row
        $bx = $gx + 24 * $cellW + (Px 8)
        $bw = $totalW - (Px 8)
        $fraction = if ($dayMax -gt 0) { [double]$weekday[$row] / $dayMax } else { 0 }
        if ($fraction -gt 0) { Fill-Round $G (New-Rect $bx ($y + (Px 7)) ([Math]::Max((Px 3), [int]($bw * $fraction * 0.6))) (Px 8)) (Px 4) $P.Accent }
        Draw-Text $G (Format-HubDuration $weekday[$row]) $F.Small $P.Muted $bx $y $bw $cellH 'Right'
    }
    $ly = $gy + 7 * ($cellH + (Px 3))
    foreach ($h in 0, 6, 12, 18, 23) {
        Draw-Text $G ('{0:00}' -f $h) $F.Small $P.Faint ($gx + $h * $cellW - (Px 4)) $ly (Px 30) (Px 16)
    }
    # scale
    $sx = $card.Right - (Px 14) - (Px 150)
    Draw-Text $G 'menos' $F.Small $P.Faint ($sx - (Px 44)) ($card.Y + (Px 10)) (Px 40) (Px 18) 'Right'
    for ($i = 0; $i -lt 5; $i++) { Fill-Round $G (New-Rect ($sx + $i * (Px 16)) ($card.Y + (Px 13)) (Px 13) (Px 12)) (Px 3) (Get-HubShade ($i / 4)) }
    Draw-Text $G (Tx 'm\u00e1s') $F.Small $P.Faint ($sx + (Px 84)) ($card.Y + (Px 10)) (Px 40) (Px 18)

    # by hour of the day
    $chart = New-Rect $X0 (Px 350) $Inner (Px 150)
    Draw-HubCard $G $chart
    $hourly = @($D.hourly)
    $prompts = @($D.hourlyPrompts)
    $values = [double[]]@($hourly | ForEach-Object { [double]$_ })
    $labels = [string[]]@(for ($h = 0; $h -lt 24; $h++) { if ($h % 3 -eq 0) { '{0:00}' -f $h } else { '' } })
    $tips = [string[]]@(for ($h = 0; $h -lt 24; $h++) { ('{0:00}:00' -f $h) + (Tx '\u2013') + ('{0:00}:00' -f (($h + 1) % 24)) + ': ' + (Format-HubDuration $hourly[$h]) + ', ' + (Format-HubNumber $prompts[$h]) + ' prompts' })
    Draw-HubBars $G $Map 'shour' (New-Rect ($chart.X + (Px 14)) ($chart.Y + (Px 34)) ($chart.Width - (Px 28)) ($chart.Height - (Px 42))) $values $labels $tips $readout
    Draw-Text $G (Tx 'POR HORA DEL D\u00cdA') $F.Caps $P.Muted ($chart.X + (Px 14)) ($chart.Y + (Px 10)) (Px 200) (Px 18)
    Draw-Text $G (Tx 'Pasa el rat\u00f3n por una celda o una barra') $F.Small $P.Faint $readout.X $readout.Y $readout.Width $readout.Height 'Right'

    # parts of the day
    $bands = @(@('MADRUGADA', 0, 5), @((Tx 'MA\u00d1ANA'), 6, 11), @('TARDE', 12, 18), @('NOCHE', 19, 23))
    $total = ($hourly | Measure-Object -Sum).Sum
    $gap = Px 10
    $w = [int](($Inner - 3 * $gap) / 4)
    for ($i = 0; $i -lt 4; $i++) {
        $sum = 0
        for ($h = $bands[$i][1]; $h -le $bands[$i][2]; $h++) { $sum += [double]$hourly[$h] }
        $range = ('{0:00}' -f $bands[$i][1]) + (Tx '\u2013') + ('{0:00}' -f ($bands[$i][2] + 1)) + ' h  ' + (Tx '\u00b7') + '  ' + (Format-HubDuration $sum)
        Draw-HubStat $G (New-Rect ($X0 + $i * ($w + $gap)) (Px 510) $w (Px 76)) $bands[$i][0] (Format-HubPercent $sum $total) $range
    }
}

# ---- Proyectos: where the time goes, and how long sessions are
function Draw-StatsProjects($G, $Map, $Hover, [int]$X0, [int]$Inner, $D) {
    $P = $script:Palette
    $F = $script:Fonts
    $projects = @($D.projects)
    $card = New-Rect $X0 (Px 104) $Inner (Px 392)
    Draw-HubCard $G $card
    Draw-Text $G 'PROYECTOS (CARPETAS)' $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 10)) (Px 260) (Px 18)
    Draw-Text $G ("$($D.projectCount) en total  " + (Tx '\u00b7') + (Tx '  tiempo de sesi\u00f3n')) $F.Small $P.Faint ($card.X + (Px 14)) ($card.Y + (Px 10)) ($card.Width - (Px 28)) (Px 18) 'Right'
    $max = if ($projects.Count) { [double]$projects[0].seconds } else { 0 }
    $y = $card.Y + (Px 34)
    if (-not $projects.Count) { Draw-Text $G 'Sin proyectos en este periodo.' $F.Body $P.Muted ($card.X + (Px 14)) $y (Px 300) (Px 24) }
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $project = $projects[$i]
        $sub = (Format-HubNumber $project.prompts) + ' prompts  ' + (Tx '\u00b7') + '  ' + (Format-HubNumber $project.sessions) + $(if ($project.sessions -eq 1) { (Tx ' sesi\u00f3n') } else { ' sesiones' })
        Draw-HubRankRow $G $Map $Hover "sproj-$i" (New-Rect ($card.X + (Px 6)) $y ($card.Width - (Px 12)) (Px 40)) $project.name (Format-HubDuration $project.seconds) $(if ($max -gt 0) { [double]$project.seconds / $max } else { 0 }) $sub
        $y += Px 44
    }

    $gap = Px 10
    $w = [int](($Inner - 3 * $gap) / 4)
    $longest = $D.longestSession
    $tiles = @(
        @((Tx 'SESI\u00d3N MEDIA'), (Format-HubDuration $D.avgSessionSeconds), ('mediana ' + (Format-HubDuration $D.medianSessionSeconds))),
        @((Tx 'LA M\u00c1S LARGA'), $(if ($longest) { Format-HubDuration $longest.seconds } else { '-' }), $(if ($longest) { $longest.project } else { '' })),
        @((Tx 'PROMPTS POR SESI\u00d3N'), ([double]$D.avgPromptsPerSession).ToString('0.#', $script:HubCulture), ((Format-HubNumber $D.prompts) + ' en total')),
        @('PROYECTOS', (Format-HubNumber $D.projectCount), ((Format-HubNumber $D.sessions) + ' sesiones'))
    )
    for ($i = 0; $i -lt 4; $i++) {
        Draw-HubStat $G (New-Rect ($X0 + $i * ($w + $gap)) (Px 506) $w (Px 80)) $tiles[$i][0] $tiles[$i][1] $tiles[$i][2]
    }
}

# ---- Modelos y herramientas: tokens by model, tools Claude used, and the other ClaudeMaxxing tools
function Draw-StatsModels($G, $Map, $Hover, [int]$X0, [int]$Inner, $D) {
    $P = $script:Palette
    $F = $script:Fonts
    $gap = Px 12
    $leftW = [int](($Inner - $gap) / 2)
    $rightX = $X0 + $leftW + $gap
    $rightW = $Inner - $leftW - $gap

    # models
    $card = New-Rect $X0 (Px 104) $leftW (Px 300)
    Draw-HubCard $G $card
    Draw-Text $G 'MODELOS' $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 10)) (Px 200) (Px 18)
    Draw-Text $G 'respuestas' $F.Small $P.Faint ($card.X + (Px 14)) ($card.Y + (Px 10)) ($card.Width - (Px 28)) (Px 18) 'Right'
    $models = @($D.models)
    $maxMessages = if ($models.Count) { ($models | ForEach-Object { [double]$_.messages } | Measure-Object -Maximum).Maximum } else { 0 }
    $y = $card.Y + (Px 34)
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $sub = (Format-HubTokens $m.output) + ' de salida'
        Draw-HubRankRow $G $Map $Hover "smodel-$i" (New-Rect ($card.X + (Px 6)) $y ($card.Width - (Px 12)) (Px 40)) (Format-ModelName $m.name) (Format-HubNumber $m.messages) $(if ($maxMessages -gt 0) { [double]$m.messages / $maxMessages } else { 0 }) $sub
        $y += Px 43
    }

    # tokens
    $t = $D.tokens
    $inputTotal = [double]$t.input + [double]$t.cacheRead + [double]$t.cacheWrite
    $tcard = New-Rect $X0 (Px 414) $leftW (Px 82)
    Draw-HubCard $G $tcard
    Draw-Text $G 'TOKENS' $F.Caps $P.Muted ($tcard.X + (Px 14)) ($tcard.Y + (Px 10)) (Px 200) (Px 18)
    Draw-Text $G ((Format-HubTokens ($inputTotal + [double]$t.output)) + ' procesados') $F.BodyStrong $P.Text ($tcard.X + (Px 14)) ($tcard.Y + (Px 30)) ($tcard.Width - (Px 28)) (Px 22)
    Draw-Text $G ((Format-HubTokens $t.output) + ' escritos por Claude  ' + (Tx '\u00b7') + '  ' + (Format-HubPercent $t.cacheRead $inputTotal) + (Tx ' le\u00eddos de cach\u00e9')) $F.Small $P.Muted ($tcard.X + (Px 14)) ($tcard.Y + (Px 54)) ($tcard.Width - (Px 28)) (Px 18)

    # tools
    $card = New-Rect $rightX (Px 104) $rightW (Px 392)
    Draw-HubCard $G $card
    Draw-Text $G 'HERRAMIENTAS DE CLAUDE' $F.Caps $P.Muted ($card.X + (Px 14)) ($card.Y + (Px 10)) (Px 220) (Px 18)
    Draw-Text $G 'usos' $F.Small $P.Faint ($card.X + (Px 14)) ($card.Y + (Px 10)) ($card.Width - (Px 28)) (Px 18) 'Right'
    $tools = @($D.tools)
    $maxUses = if ($tools.Count) { [double]$tools[0].count } else { 0 }
    $y = $card.Y + (Px 34)
    for ($i = 0; $i -lt $tools.Count; $i++) {
        Draw-HubRankRow $G $Map $Hover "stool-$i" (New-Rect ($card.X + (Px 6)) $y ($card.Width - (Px 12)) (Px 34)) $tools[$i].name (Format-HubNumber $tools[$i].count) $(if ($maxUses -gt 0) { [double]$tools[$i].count / $maxUses } else { 0 }) ''
        $y += Px 35
    }

    # the other ClaudeMaxxing tools (all time)
    $ts = $script:Hub.Cache.ToolStats
    if (-not $ts) { $ts = @{ Calls = 0; CallMinutes = 0; CallAnswers = 0; Runs = 0; RunsOk = 0; MenuOpens = 0; Paired = 0 } }
    $gap = Px 10
    $w = [int](($Inner - 3 * $gap) / 4)
    $tiles = @(
        @('LLAMADAS WHISPER', (Format-HubNumber $ts.Calls), ((Format-HubDuration (60 * $ts.CallMinutes)) + ' en llamadas')),
        @('SESIONES AGENDADAS', (Format-HubNumber $ts.Runs), ("$($ts.RunsOk) bien  " + (Tx '\u00b7') + "  $($ts.Runs - $ts.RunsOk) con error")),
        @((Tx 'APERTURAS DEL MEN\u00da'), (Format-HubNumber $ts.MenuOpens), 'en media pantalla'),
        @('PCS EMPAREJADOS', (Format-HubNumber $ts.Paired), 'en tu red local')
    )
    for ($i = 0; $i -lt 4; $i++) {
        Draw-HubStat $G (New-Rect ($X0 + $i * ($w + $gap)) (Px 506) $w (Px 80)) $tiles[$i][0] $tiles[$i][1] $tiles[$i][2]
    }
}
