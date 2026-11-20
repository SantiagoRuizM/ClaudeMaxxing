# "Empresa" in the ClaudeMaxxing window, only in the business edition (lib\business.ps1): the seat report, the reports
# for the team's shared folder, the company's objectives for Claude Judge and the team kit of plugins. Also the card
# that takes the place of Otros PCs and Claude Whisper in Inicio, and the tray's tick (calibration and weekly report).
# Needs theme.ps1, hub.ps1, hubstats.ps1, hubskills.ps1, forecast.ps1, maxx.ps1 and business.ps1. Keep this file ASCII.

$script:Business = $null
$script:BusinessPreview = $false
$script:BusinessStats = @{ Stamp = 0; Data = $null }

function Test-HubBusiness { [bool]($script:Business -and $script:Business.Business) }
function Test-HubModule([string]$Module) { Test-ModuleAllowed $script:Business $Module }

# The side menu (Configuracion has its own button): Empresa only in the business edition, and no section for a module the policy turned off.
function Get-HubVisibleSections {
    $business = Test-HubBusiness
    @($script:HubSections | Where-Object { $_.Nav -ne $false -and ($business -or -not $_.Business) -and (-not $_.Module -or (Test-HubModule $_.Module)) })
}

# stats.json, read again only when it changes.
function Get-BusinessStats {
    $item = Get-Item -LiteralPath $StatsFile -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($script:BusinessStats.Stamp -ne $item.LastWriteTimeUtc.Ticks) {
        $script:BusinessStats = @{ Stamp = $item.LastWriteTimeUtc.Ticks; Data = (Read-JsonFile $StatsFile) }
    }
    $script:BusinessStats.Data
}

# What a full 5-hour window costs, from the open window's forecast once it is at 10 % or more (lower is noisy).
function Update-BusinessCapacity($Seat) {
    $view = $script:View
    $stats = Get-BusinessStats
    if (-not $stats -or -not $view -or -not $view.HasData -or -not $view.Session.Active -or $view.Session.Percent -lt 10) { return $Seat }
    $fc = Get-UsageForecast $stats.recent.usage $view.Session (Get-Date)
    if (-not $fc -or -not $fc.Capacity) { return $Seat }
    $Seat | Add-Member -NotePropertyName capacity -NotePropertyValue ([Math]::Round([double]$fc.Capacity, 2)) -Force
    $Seat | Add-Member -NotePropertyName capacityAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    Save-SeatState $Seat
    $Seat
}

function Get-HubSeatReport($Seat) {
    $view = $script:View
    $weekly = if ($view -and $view.HasData -and $view.Weekly.Active) { [double]$view.Weekly.Percent } else { 0 }
    Get-SeatReport (Get-BusinessStats) $script:Business.Policy ([double]$Seat.capacity) $weekly (Get-Date)
}

# Every 5 minutes from the tray: a policy IT changes while the tray runs applies without a restart. A module turned
# off stops: the Whip switch goes off and the Otros PCs server and discovery close. (Turning one back on, or the
# tray menu's items, wait for the next start.)
function Update-PolicyAtRuntime {
    $script:Business = Get-BusinessState
    [void](Sync-WhipPolicy (Test-HubModule 'whip'))
    if (-not (Test-HubModule 'bridge') -and $script:BridgeTimer -and $script:BridgeTimer.Enabled) {
        $script:BridgeTimer.Stop()
        Stop-BridgeTray
    }
}

# Every 5 minutes from the tray: calibrate, and send the weekly report when the policy asks for it.
function Invoke-BusinessTick {
    if (-not (Test-HubBusiness)) { return }
    $policy = $script:Business.Policy
    if ($policy.reportDir -and $policy.reportPresence) {
        # A share that is not there (off the company network) only skips this tick.
        $percent = if ($script:View -and $script:View.HasData -and $script:View.Session.Active) { [int]$script:View.Session.Percent } else { $null }
        try { Write-TeamPresence (Get-ReportDir $policy) @(Read-JsonFile $SessionsFile | Where-Object { $_ }).Count $percent (Get-Date) } catch { }
    }
    $seat = Update-BusinessCapacity (Get-SeatState)
    if (-not (Test-ReportDue $script:Business $seat (Get-Date))) { return }
    try {
        $path = Export-SeatReport (Get-HubSeatReport $seat) (Get-ReportDir $script:Business.Policy)
        $seat | Add-Member -NotePropertyName lastReport -NotePropertyValue $path -Force
        $seat | Add-Member -NotePropertyName lastReportError -NotePropertyValue '' -Force
    } catch {
        $seat | Add-Member -NotePropertyName lastReportError -NotePropertyValue $_.Exception.Message -Force
    }
    # Also after a failure: a folder that is not there would otherwise be retried every 5 minutes.
    $seat | Add-Member -NotePropertyName lastReportAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    Save-SeatState $seat
}

# Read again while Empresa or Inicio is open (every 10 s), and the policy with it (an edited policy shows at once).
function Update-HubBusiness([switch]$Force) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Preview) { return }
    $c = $hub.Cache
    if (-not $Force -and $hub.Section -notin 'business', 'home') { return }
    if (-not $Force -and $c.BusinessAt -and ((Get-Date) - $c.BusinessAt).TotalSeconds -lt 10) { return }
    $c.BusinessAt = Get-Date
    $script:Business = Get-BusinessState
    if (-not (Test-HubBusiness)) { return }
    $seat = Get-SeatState
    $c.BusinessSeat = $seat
    $c.BusinessReport = Get-HubSeatReport $seat
    $c.BusinessObjectives = Get-BusinessObjectives
    $c.BusinessObjectivesManaged = Test-Path -LiteralPath (Join-Path $MachinePolicyDir 'objetivos.md')
    # The team: everyone's last report and, with reportPresence, who is connected now.
    $policy = $script:Business.Policy
    $c.BusinessTeam = if ($policy.reportDir) { try { @(Get-TeamReport (Get-ReportDir $policy)) } catch { @() } } else { @() }
    $c.BusinessPresence = if ($policy.reportDir -and $policy.reportPresence) { try { Get-TeamPresence (Get-ReportDir $policy) } catch { @{} } } else { @{} }
    $installed = @(Get-ClaudePlugins (Join-Path $env:USERPROFILE '.claude') | Where-Object { -not $_.Project } | ForEach-Object { $_.Key })
    $c.BusinessKit = @(@($script:Business.Policy.plugins) | ForEach-Object { [pscustomobject]@{ Ref = $_; Installed = ($installed -contains $_); Valid = (Test-PluginRef $_) } })
}

# ---------------------------------------------------------------- actions

function Open-HubBusinessFile([string]$Path) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Path + '"') }

# IT's policy opens as it is (only an administrator can save it); otherwise the user's, created from the defaults.
function Open-HubPolicy {
    if ($script:Hub.Preview) { return }
    $path = $script:Business.Source
    if (-not $path) {
        $path = $UserPolicyFile
        Write-JsonFile $path (New-DefaultPolicy)
    }
    Open-HubBusinessFile $path
    Set-HubMessage $(if ($script:Business.Managed) { (Tx 'Pol\u00edtica de TI: solo un administrador puede cambiarla.') } else { (Tx 'Guarda el archivo: los cambios se ven en unos segundos.') })
}

function Edit-HubObjectives {
    if ($script:Hub.Preview) { return }
    $managed = Join-Path $MachinePolicyDir 'objetivos.md'
    if (Test-Path -LiteralPath $managed) { Open-HubBusinessFile $managed; return }
    if (-not (Test-Path -LiteralPath $UserObjectivesFile)) {
        New-Item -ItemType Directory -Force -Path $BusinessHome | Out-Null
        [IO.File]::WriteAllText($UserObjectivesFile, (Get-ObjectivesTemplate), (New-Object System.Text.UTF8Encoding($false)))
    }
    Open-HubBusinessFile $UserObjectivesFile
}

# A shared folder means other people read it: ask first. A local one does not.
function Export-HubSeatReport {
    if ($script:Hub.Preview) { return }
    $policy = $script:Business.Policy
    $dir = Get-ReportDir $policy
    if ($policy.reportDir) {
        $what = if ($policy.reportProjects) { 'horas, consumo y los nombres de tus proyectos' } else { 'horas y consumo' }
        if (-not (Confirm-UiAction ((Tx 'Tu informe de los \u00faltimos 30 d\u00edas (') + $what + (Tx ') se guarda en ') + $dir + (Tx ', donde lo ve tu equipo. \u00bfSeguir?')) $script:HubDialog)) { return }
    }
    try {
        $seat = Get-SeatState
        $path = Export-SeatReport (Get-HubSeatReport $seat) $dir
        $seat | Add-Member -NotePropertyName lastReportAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
        $seat | Add-Member -NotePropertyName lastReport -NotePropertyValue $path -Force
        $seat | Add-Member -NotePropertyName lastReportError -NotePropertyValue '' -Force
        Save-SeatState $seat
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $path + '"')
        Set-HubMessage ((Tx '\u2713 Informe guardado: ') + (Split-Path -Leaf $path))
    } catch {
        Set-HubMessage ((L 'No se pudo guardar el informe: ') + $_.Exception.Message) -Failed
    }
    Update-HubBusiness -Force
}

# Everyone's newest report in the shared folder, as a CSV that opens in Excel.
function Open-HubTeamReport {
    if ($script:Hub.Preview) { return }
    $dir = Get-ReportDir $script:Business.Policy
    $rows = @(Get-TeamReport $dir)
    if (-not $rows.Count) { Set-HubMessage ((L 'No hay informes en ') + $dir) -Failed; return }
    $total = Measure-TeamReport $rows
    try {
        $out = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("$AppName\equipo-" + (Get-Date).ToString('yyyy-MM-dd') + '.csv')
        Start-Process -FilePath (Export-TeamCsv $rows $out)
        $roi = if ($null -ne $total.Roi) { (Tx ' \u00b7 retorno x') + $total.Roi } else { '' }
        Set-HubMessage (((L '{0} personas') -f $total.People) + (Tx ' \u00b7 ') + (Format-Usd $total.ApiCostUsd) + $roi)
    } catch {
        Set-HubMessage ((L 'No se pudo escribir el informe del equipo: ') + $_.Exception.Message) -Failed
    }
}

function Install-HubTeamKit {
    if ($script:Hub.Preview) { return }
    $job = $script:Hub.Cache.MaxxStatus
    if ($job -and $job.state -eq 'running') { Set-HubMessage (Tx 'Espera: hay otra instalaci\u00f3n en curso.'); return }
    Start-MaxxJob 'team-install'
    Set-HubMessage 'Instalando el kit del equipo...'
    Update-HubNow
}

# ---------------------------------------------------------------- drawing

# Use, return on the seat and whether it fits: three tiles in a row.
function Draw-HubBusinessTiles($G, [System.Drawing.Rectangle]$Area) {
    $P = $script:Palette
    $r = $script:Hub.Cache.BusinessReport
    $gap = Px 12
    $w = [int](($Area.Width - 2 * $gap) / 3)
    $dot = (Tx ' \u00b7 ')
    $hours = if ($r) { ([string]$r.hours).Replace('.', ',') + ' h' } else { '-' }
    $useSub = if ($r) { (Format-Usd $r.apiCostUsd) + (L ' equivalente API') + $dot + $r.activeDays + (Tx ' d\u00edas') } else { '' }
    Draw-HubStat $G (New-Rect $Area.X $Area.Y $w $Area.Height) (Tx 'USO \u00b7 30 D\u00cdAS') $hours $useSub
    $seatUsd = [double]$script:Business.Policy.seatMonthlyUsd
    if ($r -and $null -ne $r.roi) {
        $value = 'x' + ([string]$r.roi).Replace('.', ',')
        $sub = (L 'asiento ') + $(if ($r.seatName) { $r.seatName + ' ' } else { '' }) + (Format-Usd $seatUsd) + '/mes'
        $color = if ([double]$r.roi -ge 1) { $P.Ok } else { $P.Warn }
    } else {
        $value = '-'; $sub = (Tx 'Pon seatMonthlyUsd en la pol\u00edtica'); $color = $P.Faint
    }
    Draw-HubStat $G (New-Rect ($Area.X + $w + $gap) $Area.Y $w $Area.Height) 'RETORNO DEL ASIENTO' $value $sub $color
    $rec = if ($r) { [string]$r.recommendation } else { '' }
    $color = switch ($rec) { 'up' { $P.Warn } 'down' { $P.Accent } 'fit' { $P.Ok } default { $P.Faint } }
    Draw-HubStat $G (New-Rect ($Area.X + 2 * ($w + $gap)) $Area.Y ($Area.Width - 2 * ($w + $gap)) $Area.Height) 'ASIENTO' (Format-SeatAdvice $rec) $(if ($r) { [string]$r.reason } else { '' }) $color
}

function Get-HubDisabledText {
    $off = @(@($script:Business.Policy.disabled) | Where-Object { $script:BusinessModules.Contains($_) } | ForEach-Object { $script:BusinessModules[$_] })
    if (-not $off.Count) { return (Tx 'La pol\u00edtica no apaga ning\u00fan m\u00f3dulo.') }
    $list = if ($off.Count -eq 1) { $off[0] } else { ($off[0..($off.Count - 2)] -join ', ') + ' y ' + $off[-1] }
    (Tx 'Apagado por la pol\u00edtica: ') + $list + '.'
}

# Inicio in the business edition: the tiles and the objectives, where Otros PCs and Claude Whisper go otherwise.
function Draw-HubBusinessHome($G, $Map, $Hover, [System.Drawing.Rectangle]$Area) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    Draw-HubBusinessTiles $G (New-Rect $Area.X $Area.Y $Area.Width (Px 78))
    $card = New-Rect $Area.X ($Area.Y + (Px 90)) $Area.Width ($Area.Height - (Px 90))
    Draw-HubCard $G $card
    $tx = $card.X + (Px 14)
    $tw = $card.Width - (Px 28)
    $company = [string]$script:Business.Policy.company
    Draw-Text $G ('EMPRESA' + $(if ($company) { (Tx ' \u00b7 ') + $company.ToUpper() } else { '' })) $F.Caps $P.Muted $tx ($card.Y + (Px 10)) $tw (Px 18)
    Draw-Text $G 'Objetivos para Claude Judge' $F.BodyStrong $P.Text $tx ($card.Y + (Px 30)) $tw (Px 20)
    $objectives = [string]$c.BusinessObjectives
    if ($objectives) {
        $lines = @($objectives -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^#' } | Select-Object -First 4)
        Draw-Wrapped $G ($lines -join "`n") $F.Small $P.Muted $tx ($card.Y + (Px 54)) $tw (Px 80)
    } else {
        Draw-Wrapped $G (Tx 'Sin objetivos todav\u00eda: escr\u00edbelos en Empresa y Planear sesi\u00f3n juzgar\u00e1 cada idea tambi\u00e9n contra ellos.') $F.Small $P.Faint $tx ($card.Y + (Px 54)) $tw (Px 40)
    }
    $more = New-Rect ($card.Right - (Px 130)) ($card.Bottom - (Px 28)) (Px 116) (Px 20)
    Draw-Text $G (Tx 'Ver Empresa \u203a') $F.Small $(if ($Hover -eq 'home-business-more') { $P.AccentHover } else { $P.Accent }) $more.X $more.Y $more.Width $more.Height 'Right'
    Add-Hit $Map 'home-business-more' $more { Set-HubSection 'business' }
}

# A module the policy turned off, where its card would be.
function Draw-HubPolicyNote($G, [System.Drawing.Rectangle]$Card, [string]$Title, [string]$Text) {
    $P = $script:Palette
    $F = $script:Fonts
    Draw-HubCard $G $Card
    Draw-Text $G $Title $F.BodyStrong $P.Muted ($Card.X + (Px 16)) ($Card.Y + (Px 12)) ($Card.Width - (Px 32)) (Px 22)
    Draw-Wrapped $G $Text $F.Small $P.Faint ($Card.X + (Px 16)) ($Card.Y + (Px 38)) ($Card.Width - (Px 32)) ($Card.Height - (Px 44))
}

function Draw-HubBusinessSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    if ($null -eq $c.BusinessReport) { try { Update-HubBusiness -Force } catch { } }
    $b = $script:Business
    $policy = $b.Policy
    $now = Get-Date
    $gap = Px 12

    # The team: last report of each person, with who is connected now when the policy shares presence.
    $presence = if ($c.BusinessPresence) { $c.BusinessPresence } else { @{} }
    $byKey = [ordered]@{}
    foreach ($r in @($c.BusinessTeam)) { $byKey[([string]$r.computer + '\' + [string]$r.user).ToLowerInvariant()] = @{ Report = $r; Presence = $null } }
    foreach ($key in @($presence.Keys)) {
        if ($byKey.Contains($key)) { $byKey[$key].Presence = $presence[$key] } else { $byKey[$key] = @{ Report = $null; Presence = $presence[$key] } }
    }
    # Not $p: PowerShell names ignore case, and $P is the palette.
    $people = @(foreach ($entry in $byKey.Values) {
        $r = $entry.Report; $seen = $entry.Presence
        $source = if ($r) { $r } else { $seen }
        $online = Test-PresenceOnline $seen $now
        $last = if ($seen -and $seen.at) { [string]$seen.at } elseif ($r) { [string]$r.at } else { '' }
        [pscustomobject]@{
            User = [string]$source.user; Computer = [string]$source.computer; Me = ([string]$source.user -eq $env:USERNAME -and [string]$source.computer -eq $env:COMPUTERNAME)
            Online = $online; Sessions = $(if ($online) { [int]$seen.sessions } else { 0 }); Percent = $(if ($online -and $null -ne $seen.sessionPercent) { [int]$seen.sessionPercent } else { $null })
            Tokens = $(if ($r -and $r.tokens) { [double]$r.tokens } else { 0 }); Cost = $(if ($r) { [double]$r.apiCostUsd } else { 0 }); Last = $last
            Rec = $(if ($r) { [string]$r.recommendation } else { '' }); Seat = $(if ($r) { [string]$r.seatName } else { '' }); SeatUsd = $(if ($r) { [double]$r.seatMonthlyUsd } else { 0 })
        }
    })
    $people = @($people | Sort-Object @{ Expression = { $_.Online }; Descending = $true }, @{ Expression = { $_.Tokens }; Descending = $true })

    # numbers of the team (or, without a team folder, of this seat)
    $tiles = New-Rect $X0 (Px 72) $Inner (Px 78)
    if ($people.Count) {
        $w = [int](($Inner - 3 * $gap) / 4)
        $online = @($people | Where-Object { $_.Online })
        $tokens = ($people | Measure-Object -Property Tokens -Sum).Sum
        $cost = ($people | Measure-Object -Property Cost -Sum).Sum
        $seats = ($people | Measure-Object -Property SeatUsd -Sum).Sum
        $up = @($people | Where-Object { $_.Rec -eq 'up' }).Count
        $down = @($people | Where-Object { $_.Rec -eq 'down' }).Count
        if ($policy.reportPresence) {
            Draw-HubStat $G (New-Rect $tiles.X $tiles.Y $w $tiles.Height) 'CONECTADOS AHORA' ((L '{0} de {1}') -f $online.Count, $people.Count) ((L '{0} sesiones abiertas') -f (($online | Measure-Object -Property Sessions -Sum).Sum + 0))
        } else {
            Draw-HubStat $G (New-Rect $tiles.X $tiles.Y $w $tiles.Height) 'PERSONAS' ([string]$people.Count) 'con informe en la carpeta'
        }
        Draw-HubStat $G (New-Rect ($tiles.X + $w + $gap) $tiles.Y $w $tiles.Height) (Tx 'TOKENS \u00b7 30 D\u00cdAS') $(if ($tokens) { Format-HubTokens $tokens } else { [string][char]0x2013 }) 'de todo el equipo'
        Draw-HubStat $G (New-Rect ($tiles.X + 2 * ($w + $gap)) $tiles.Y $w $tiles.Height) 'VALOR EN LA API' (Format-Usd $cost) $(if ($seats) { (L '{0}/mes en asientos') -f (Format-Usd $seats) } else { '' })
        Draw-HubStat $G (New-Rect ($tiles.X + 3 * ($w + $gap)) $tiles.Y ($Inner - 3 * ($w + $gap)) $tiles.Height) 'ASIENTOS' $(if ($up) { (L '{0} cortos') -f $up } else { 'Bien' }) $(if ($down -eq 1) { L '1 sobra' } else { (L '{0} sobran') -f $down }) $(if ($up) { $P.Warn } else { $P.Ok })
    } else {
        Draw-HubBusinessTiles $G $tiles
    }

    # the team, one row per person
    $y = $tiles.Bottom + (Px 14)
    Draw-HubCaption $G 'EQUIPO' $X0 $y $Inner $(if ($people.Count -gt 6) { (Tx '+{0} m\u00e1s en el informe del equipo') -f ($people.Count - 6) } else { '' })
    $card = New-Rect $X0 ($y + (Px 22)) $Inner (Px 222)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $tw = $card.Width - (Px 32)
    if (-not $people.Count) {
        $text = if ($policy.reportDir) { Tx 'Todav\u00eda no hay informes en la carpeta del equipo: cada persona aparece al exportar el suyo.' } else { Tx 'Pon reportDir en la pol\u00edtica (una carpeta compartida) para ver aqu\u00ed al equipo: qui\u00e9n est\u00e1 conectado, sus tokens y su \u00faltima conexi\u00f3n.' }
        Draw-Wrapped $G $text $F.Small $P.Muted $tx ($card.Y + (Px 14)) $tw (Px 40)
    } else {
        $cols = @(@{ T = 'PERSONA'; X = 0.0 }, @{ T = 'ESTADO'; X = 0.17 }, @{ T = (Tx 'SESI\u00d3N'); X = 0.36 }, @{ T = 'TOKENS 30 D'; X = 0.52 }, @{ T = (Tx '\u00daLTIMA CONEXI\u00d3N'); X = 0.64 }, @{ T = 'ASIENTO'; X = 0.82 })
        foreach ($col in $cols) { Draw-Text $G $col.T $F.Caps $P.Muted ($tx + [int]($tw * $col.X)) ($card.Y + (Px 10)) (Px 150) (Px 18) }
        $ry = $card.Y + (Px 34)
        foreach ($person in @($people | Select-Object -First 6)) {
            $pen = New-HubPen $P.Border 1
            $G.DrawLine($pen, $tx, $ry, $tx + $tw, $ry)
            $pen.Dispose()
            $cy = $ry + (Px 4)
            $colX = { param($i) $tx + [int]($tw * $cols[$i].X) }
            $colW = { param($i) $(if ($i -lt $cols.Count - 1) { [int]($tw * ($cols[$i + 1].X - $cols[$i].X)) - (Px 8) } else { [int]($tw * (1 - $cols[$i].X)) }) }
            Draw-Text $G ($person.User + $(if ($person.Me) { (Tx ' \u00b7 t\u00fa') } else { '' })) $F.BodyStrong $P.Text (& $colX 0) $cy (& $colW 0) (Px 22)
            Draw-HubDot $G (& $colX 1) ($cy + (Px 7)) (Px 8) $(if ($person.Online) { $P.Ok } else { $P.Faint })
            $state = if ($person.Online) { $(if ($person.Sessions -eq 1) { Tx '1 sesi\u00f3n' } elseif ($person.Sessions) { (Tx '{0} sesiones') -f $person.Sessions } else { 'sin sesiones' }) } else { 'desconectado' }
            Draw-Text $G $state $F.Small $(if ($person.Online) { $P.Text } else { $P.Muted }) ((& $colX 1) + (Px 14)) $cy ((& $colW 1) - (Px 14)) (Px 22)
            if ($null -ne $person.Percent) {
                $bar = New-Rect (& $colX 2) ($cy + (Px 8)) (Px 44) (Px 6)
                Fill-Round $G $bar (Px 3) $P.Track
                if ($person.Percent -gt 0) { Fill-Round $G (New-Rect $bar.X $bar.Y ([Math]::Max((Px 6), [int]($bar.Width * [Math]::Min(100, $person.Percent) / 100))) $bar.Height) (Px 3) $P[(Get-UsageLevel $person.Percent)] }
                Draw-Text $G "$($person.Percent) %" $F.Small $P.Text ($bar.Right + (Px 6)) $cy (Px 40) (Px 22)
            } else { Draw-Text $G ([string][char]0x2013) $F.Small $P.Faint (& $colX 2) $cy (Px 20) (Px 22) }
            Draw-Text $G $(if ($person.Tokens) { Format-HubTokens $person.Tokens } else { [string][char]0x2013 }) $F.Small $P.Text (& $colX 3) $cy (& $colW 3) (Px 22)
            $last = if ($person.Online) { L 'ahora' } elseif ($person.Last) { try { Format-DialogDateTime ([datetime]$person.Last) $now } catch { '' } } else { '' }
            Draw-Text $G $last $F.Small $P.Muted (& $colX 4) $cy (& $colW 4) (Px 22)
            $recColor = switch ($person.Rec) { 'up' { $P.Warn } 'down' { $P.Ok } default { $P.Muted } }
            Draw-Text $G (Format-SeatAdvice $person.Rec) $F.Small $recColor (& $colX 5) $cy (& $colW 5) (Px 22)
            $ry += Px 30
        }
    }

    # reports, the team kit and the policy, side by side
    $by = $card.Bottom + $gap
    # Reports gets the most room: its two buttons side by side.
    $w0 = [int](($Inner - 2 * $gap) * 0.38)
    $w1 = [int](($Inner - 2 * $gap) * 0.29)
    $bh = Px 92
    foreach ($i in 0, 1, 2) {
        $bxs = @($X0, ($X0 + $w0 + $gap), ($X0 + $w0 + $w1 + 2 * $gap))
        $box = New-Rect $bxs[$i] $by $(if ($i -eq 0) { $w0 } elseif ($i -eq 1) { $w1 } else { $Inner - $w0 - $w1 - 2 * $gap }) $bh
        Draw-HubCard $G $box
        $bx = $box.X + (Px 14)
        $bw = $box.Width - (Px 28)
        switch ($i) {
            0 {
                Draw-Text $G 'Informes' $F.BodyStrong $P.Text $bx ($box.Y + (Px 10)) $bw (Px 22)
                $seat = $c.BusinessSeat
                $sub = if ($seat -and $seat.lastReportError) { (L 'No se pudo enviar: ') + $seat.lastReportError } elseif ($seat -and $seat.lastReportAt) { try { (Tx '\u00daltimo: ') + (Format-DialogDateTime ([datetime]$seat.lastReportAt) $now) } catch { '' } } else { Tx 'Sin enviar todav\u00eda' }
                Draw-Text $G $sub $F.Small $(if ($seat -and $seat.lastReportError) { $P.Error } else { $P.Muted }) $bx ($box.Y + (Px 32)) $bw (Px 18)
                $label = 'Exportar mi informe'
                $pw = Get-PillWidth $label
                Draw-PillButton $G $Map $Hover 'biz-export' (New-Rect $bx ($box.Bottom - (Px 36)) $pw (Px 26)) $label { Export-HubSeatReport } -Accent
                if ($policy.reportDir) {
                    $tw2 = Get-PillWidth 'Equipo'
                    Draw-PillButton $G $Map $Hover 'biz-team' (New-Rect ($bx + $pw + (Px 6)) ($box.Bottom - (Px 36)) $tw2 (Px 26)) 'Equipo' { Open-HubTeamReport }
                }
            }
            1 {
                $kit = @($c.BusinessKit)
                $missing = @($kit | Where-Object { -not $_.Installed -and $_.Valid })
                Draw-Text $G 'Kit del equipo' $F.BodyStrong $P.Text $bx ($box.Y + (Px 10)) $bw (Px 22)
                $job = $c.MaxxStatus
                $busy = $job -and $job.state -eq 'running'
                $sub = if (-not $kit.Count) { (Tx 'La pol\u00edtica no define plugins.') } elseif ($missing.Count) { (L 'Falta {0}: {1}') -f $missing.Count, ((@($missing | ForEach-Object { ([string]$_.Ref).Split('@')[0] })) -join ', ') } else { (L '{0} de {0} instalados') -f $kit.Count }
                Draw-Text $G $sub $F.Small $(if ($missing.Count) { $P.Warn } else { $P.Muted }) $bx ($box.Y + (Px 32)) $bw (Px 18)
                if ($busy -and $job.action -eq 'team-install') { Draw-Text $G (Tx 'Instalando\u2026') $F.Small $P.Accent $bx ($box.Bottom - (Px 36)) $bw (Px 26) }
                elseif ($missing.Count) {
                    $pw = Get-PillWidth 'Instalar lo que falta'
                    Draw-PillButton $G $Map $Hover 'biz-kit' (New-Rect $bx ($box.Bottom - (Px 36)) $pw (Px 26)) 'Instalar lo que falta' { Install-HubTeamKit }
                }
            }
            2 {
                $off = @($policy.disabled | Where-Object { $script:BusinessModules.Contains([string]$_) })
                Draw-Text $G $(if ($off.Count) { (Tx 'TI apag\u00f3 {0} m\u00f3dulos') -f $off.Count } else { 'Todo encendido' }) $F.BodyStrong $P.Text $bx ($box.Y + (Px 10)) $bw (Px 22)
                Draw-Text $G ((@($off | ForEach-Object { $script:BusinessModules[[string]$_] })) -join ', ') $F.Small $P.Muted $bx ($box.Y + (Px 32)) $bw (Px 18)
                $pw = Get-PillWidth (Tx 'Pol\u00edtica')
                Draw-PillButton $G $Map $Hover 'biz-policy' (New-Rect $bx ($box.Bottom - (Px 36)) $pw (Px 26)) (Tx 'Pol\u00edtica') { Open-HubPolicy }
                $ow = Get-PillWidth 'Objetivos'
                Draw-PillButton $G $Map $Hover 'biz-objectives' (New-Rect ($bx + $pw + (Px 6)) ($box.Bottom - (Px 36)) $ow (Px 26)) 'Objetivos' { Edit-HubObjectives }
            }
        }
    }
}


# ---------------------------------------------------------------- preview (tray.ps1 -RenderHubTo, -HubSection business or home-business)

function Set-BusinessPreview {
    $policy = Merge-BusinessPolicy ([pscustomobject]@{ company = 'Acme'; seatName = 'Premium'; seatMonthlyUsd = 150; reportDir = '\\files\claude\informes'; autoReport = $true; reportPresence = $true
        marketplaces = @('acme/claude-kit'); plugins = @('acme-standards@acme-kit', 'jira-mcp@acme-kit', 'skill-creator@claude-plugins-official') })
    $script:Business = [pscustomobject]@{ Edition = 'business'; Business = $true; Policy = $policy; Source = 'C:\ProgramData\ClaudeMaxxing\policy.json'; Managed = $true }
    $c = $script:Hub.Cache
    $now = Get-Date
    $c.MaxxStatus = $null
    $c.BusinessSeat = [pscustomobject]@{ capacity = 48.5; capacityAt = $now.ToString('o'); lastReportAt = $now.AddDays(-2).ToString('o'); lastReportError = '' }
    $c.BusinessReport = [pscustomobject]@{ hours = 96.4; activeDays = 21; apiCostUsd = 1840.25; seatName = 'Premium'; seatMonthlyUsd = 150; roi = 12.3
        recommendation = 'up'; reason = '9 de las 30 ventanas recientes llegaron al 90 % del plan.' }
    $c.BusinessObjectives = Tx "# Objetivos de la empresa`n- Q1: bajar el tiempo de respuesta a clientes de 24 h a 4 h.`n- Q1: lanzar la app m\u00f3vil para el 31 de marzo.`n- Reducir a la mitad los incidentes en producci\u00f3n."
    $c.BusinessObjectivesManaged = $true
    $c.BusinessKit = @([pscustomobject]@{ Ref = 'acme-standards@acme-kit'; Installed = $true; Valid = $true }, [pscustomobject]@{ Ref = 'jira-mcp@acme-kit'; Installed = $false; Valid = $true },
        [pscustomobject]@{ Ref = 'skill-creator@claude-plugins-official'; Installed = $true; Valid = $true })
    # The team: six reports, four people connected now (this PC is one of them).
    $team = @(
        @('ana', $env:COMPUTERNAME, 31.2e6, 1840, 'up', 2, 37, 0), @('luis', 'PC-LUIS', 44.8e6, 2410, 'up', 3, 88, 0), @('marta', 'PC-MARTA', 22.5e6, 1210, 'fit', 1, 12, 0),
        @('diego', 'PC-DIEGO', 18.0e6, 960, 'fit', 0, $null, 0), @('paula', 'PC-PAULA', 27.1e6, 1490, 'fit', -1, $null, 0.4), @('sara', 'PC-SARA', 2.4e6, 130, 'down', -1, $null, 9))
    $c.BusinessTeam = @(foreach ($t in $team) {
        $user = if ($t[1] -eq $env:COMPUTERNAME) { $env:USERNAME } else { $t[0] }
        [pscustomobject]@{ user = $user; computer = $t[1]; at = $now.AddDays(-$t[7] - 1).ToString('o'); tokens = $t[2]; apiCostUsd = $t[3]; recommendation = $t[4]; seatName = 'Premium'; seatMonthlyUsd = 150 } })
    $c.BusinessPresence = @{}
    foreach ($t in $team) {
        $user = if ($t[1] -eq $env:COMPUTERNAME) { $env:USERNAME } else { $t[0] }
        $at = if ($t[5] -ge 0) { $now.AddMinutes(-2) } else { $now.AddDays(-$t[7]).AddHours(-3) }
        $c.BusinessPresence[($t[1] + '\' + $user).ToLowerInvariant()] = [pscustomobject]@{ user = $user; computer = $t[1]; at = $at.ToString('o'); sessions = [Math]::Max(0, $t[5]); sessionPercent = $t[6] }
    }
}
