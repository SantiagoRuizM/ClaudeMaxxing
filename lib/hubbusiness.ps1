# "Empresa" in the ClaudeMaxxing window, only in the business edition (lib\business.ps1): the seat report, the reports
# for the team's shared folder, the company's objectives for Claude Judge and the team kit of plugins. Also the card
# that takes the place of Otros PCs and Claude Whisper in Inicio, and the tray's tick (calibration and weekly report).
# Needs theme.ps1, hub.ps1, hubstats.ps1, hubskills.ps1, forecast.ps1, maxx.ps1 and business.ps1. Keep this file ASCII.

$script:Business = $null
$script:BusinessPreview = $false
$script:BusinessStats = @{ Stamp = 0; Data = $null }

function Test-HubBusiness { [bool]($script:Business -and $script:Business.Business) }
function Test-HubModule([string]$Module) { Test-ModuleAllowed $script:Business $Module }

# The side menu: Empresa only in the business edition, and no section for a module the policy turned off.
function Get-HubVisibleSections {
    $business = Test-HubBusiness
    @($script:HubSections | Where-Object { ($business -or -not $_.Business) -and (-not $_.Module -or (Test-HubModule $_.Module)) })
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

# Every 5 minutes from the tray: calibrate, and send the weekly report when the policy asks for it.
function Invoke-BusinessTick {
    if (-not (Test-HubBusiness)) { return }
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
        Set-HubMessage ('No se pudo guardar el informe: ' + $_.Exception.Message) -Failed
    }
    Update-HubBusiness -Force
}

# Everyone's newest report in the shared folder, as a CSV that opens in Excel.
function Open-HubTeamReport {
    if ($script:Hub.Preview) { return }
    $dir = Get-ReportDir $script:Business.Policy
    $rows = @(Get-TeamReport $dir)
    if (-not $rows.Count) { Set-HubMessage ('No hay informes en ' + $dir) -Failed; return }
    $total = Measure-TeamReport $rows
    try {
        $out = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("$AppName\equipo-" + (Get-Date).ToString('yyyy-MM-dd') + '.csv')
        Start-Process -FilePath (Export-TeamCsv $rows $out)
        $roi = if ($null -ne $total.Roi) { (Tx ' \u00b7 retorno x') + $total.Roi } else { '' }
        Set-HubMessage ("$($total.People) personas" + (Tx ' \u00b7 ') + (Format-Usd $total.ApiCostUsd) + $roi)
    } catch {
        Set-HubMessage ('No se pudo escribir el informe del equipo: ' + $_.Exception.Message) -Failed
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
    $dot = ' ' + (Tx '\u00b7') + ' '
    $hours = if ($r) { ([string]$r.hours).Replace('.', ',') + ' h' } else { '-' }
    $useSub = if ($r) { (Format-Usd $r.apiCostUsd) + ' equivalente API' + $dot + $r.activeDays + (Tx ' d\u00edas') } else { '' }
    Draw-HubStat $G (New-Rect $Area.X $Area.Y $w $Area.Height) (Tx 'USO \u00b7 30 D\u00cdAS') $hours $useSub
    $seatUsd = [double]$script:Business.Policy.seatMonthlyUsd
    if ($r -and $null -ne $r.roi) {
        $value = 'x' + ([string]$r.roi).Replace('.', ',')
        $sub = 'asiento ' + $(if ($r.seatName) { $r.seatName + ' ' } else { '' }) + (Format-Usd $seatUsd) + '/mes'
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
    $dot = '  ' + (Tx '\u00b7') + '  '

    # the edition and its policy
    $card = New-Rect $X0 (Px 72) $Inner (Px 76)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $bw = Get-PillWidth (Tx 'Pol\u00edtica')
    Draw-PillButton $G $Map $Hover 'biz-policy' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 14)) $bw (Px 26)) (Tx 'Pol\u00edtica') { Open-HubPolicy }
    $tw = $card.Width - (Px 42) - $bw
    $title = (Tx 'Edici\u00f3n Empresa') + $(if ($policy.company) { $dot + $policy.company } else { '' })
    Draw-Text $G $title $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) $tw (Px 22)
    Draw-Text $G (Get-HubDisabledText) $F.Small $P.Muted $tx ($card.Y + (Px 36)) ($card.Width - (Px 32)) (Px 18)
    $source = if ($b.Managed) { (Tx 'Pol\u00edtica de TI: ') + $b.Source } elseif ($b.Source) { (Tx 'Pol\u00edtica propia: ') + $b.Source } else { (Tx 'Pol\u00edtica por defecto (pulsa Pol\u00edtica para cambiarla)') }
    Draw-Text $G $source $F.Small $P.Faint $tx ($card.Y + (Px 54)) ($card.Width - (Px 32)) (Px 18)

    Draw-HubBusinessTiles $G (New-Rect $X0 (Px 160) $Inner (Px 78))

    # reports
    $card = New-Rect $X0 (Px 250) $Inner (Px 70)
    Draw-HubCard $G $card
    $right = $card.Right - (Px 16)
    $by = $card.Y + (Px 14)
    if ($policy.reportDir) {
        $bw = Get-PillWidth 'Informe del equipo'
        Draw-PillButton $G $Map $Hover 'biz-team' (New-Rect ($right - $bw) $by $bw (Px 26)) 'Informe del equipo' { Open-HubTeamReport }
        $right -= $bw + (Px 8)
    }
    $bw = Get-PillWidth 'Exportar mi informe'
    Draw-PillButton $G $Map $Hover 'biz-export' (New-Rect ($right - $bw) $by $bw (Px 26)) 'Exportar mi informe' { Export-HubSeatReport } -Accent
    $right -= $bw + (Px 10)
    Draw-Text $G 'Informes' $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) ($right - $tx) (Px 22)
    $where = if ($policy.reportDir) { 'Carpeta del equipo: ' + (Get-ReportDir $policy) } else { 'En ' + (Get-ReportDir $policy) + (Tx ' (pon reportDir en la pol\u00edtica para compartirlos)') }
    Draw-Text $G $where $F.Small $P.Muted $tx ($card.Y + (Px 36)) ($card.Width - (Px 32)) (Px 18)
    $seat = $c.BusinessSeat
    $last = ''
    if ($seat -and $seat.lastReportAt) { try { $last = (Tx '\u00daltimo: ') + (Format-DialogDateTime ([datetime]$seat.lastReportAt) (Get-Date)) } catch { } }
    if ($seat -and $seat.lastReportError) { $lastColor = $P.Error; $last = 'No se pudo enviar: ' + $seat.lastReportError } else { $lastColor = $P.Faint }
    $auto = if ($policy.autoReport) { 'Se exporta solo cada 7 d' + (Tx '\u00ed') + 'as.' } else { 'Se exporta solo cuando lo pulsas.' }
    Draw-Text $G ((@($auto, $last) | Where-Object { $_ }) -join $dot) $F.Small $lastColor $tx ($card.Y + (Px 52)) ($card.Width - (Px 32)) (Px 16)

    # objectives
    $card = New-Rect $X0 (Px 332) $Inner (Px 100)
    Draw-HubCard $G $card
    $label = if ($c.BusinessObjectivesManaged) { 'Ver' } else { 'Editar' }
    $bw = Get-PillWidth $label
    Draw-PillButton $G $Map $Hover 'biz-objectives' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 14)) $bw (Px 26)) $label { Edit-HubObjectives }
    $head = 'Objetivos de la empresa' + $(if ($c.BusinessObjectivesManaged) { $dot + 'de TI' } else { '' })
    Draw-Text $G $head $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) ($card.Width - (Px 42) - $bw) (Px 22)
    $objectives = [string]$c.BusinessObjectives
    if ($objectives) {
        $lines = @($objectives -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^#' } | Select-Object -First 3)
        Draw-Wrapped $G ($lines -join "`n") $F.Small $P.Muted $tx ($card.Y + (Px 38)) ($card.Width - (Px 32)) (Px 56)
    } else {
        Draw-Wrapped $G (Tx 'Sin objetivos. Escr\u00edbelos y Claude Judge (Planear sesi\u00f3n) juzgar\u00e1 cada idea tambi\u00e9n por si mueve alguno.') $F.Small $P.Faint $tx ($card.Y + (Px 38)) ($card.Width - (Px 32)) (Px 40)
    }

    # the team kit
    $kit = @($c.BusinessKit)
    $missing = @($kit | Where-Object { -not $_.Installed -and $_.Valid })
    Draw-HubCaption $G 'KIT DEL EQUIPO' $X0 (Px 444) $Inner $(if ($kit.Count) { "$(@($kit | Where-Object { $_.Installed }).Count) de $($kit.Count) instalados" } else { '' })
    $card = New-Rect $X0 (Px 466) $Inner (Px 140)
    Draw-HubCard $G $card
    $job = $c.MaxxStatus
    $busy = $job -and $job.state -eq 'running'
    if (-not $kit.Count) {
        Draw-Wrapped $G (Tx 'La pol\u00edtica no define plugins. A\u00f1ade "marketplaces" (owner/repo) y "plugins" (nombre@marketplace) y cada persona los instala con un clic: skills, MCP y comandos del equipo.') $F.Small $P.Faint $tx ($card.Y + (Px 14)) ($card.Width - (Px 32)) (Px 60)
        return
    }
    $right = $card.Right - (Px 16)
    if ($busy -and $job.action -eq 'team-install') {
        Draw-Text $G (Tx 'Instalando\u2026') $F.Small $P.Accent ($right - (Px 110)) ($card.Y + (Px 12)) (Px 110) (Px 26) 'Right'
    } elseif ($missing.Count -and -not $busy) {
        $bw = Get-PillWidth 'Instalar lo que falta'
        Draw-PillButton $G $Map $Hover 'biz-kit' (New-Rect ($right - $bw) ($card.Y + (Px 12)) $bw (Px 26)) 'Instalar lo que falta' { Install-HubTeamKit } -Accent
    }
    $y = $card.Y + (Px 14)
    foreach ($item in @($kit | Select-Object -First 5)) {
        $mark = if (-not $item.Valid) { '!' } elseif ($item.Installed) { [string][char]0x2713 } else { [string][char]0x25CB }
        $color = if (-not $item.Valid) { $P.Error } elseif ($item.Installed) { $P.Ok } else { $P.Muted }
        Draw-Text $G $mark $F.BodyStrong $color $tx $y (Px 18) (Px 20)
        $name, $market = ([string]$item.Ref).Split('@', 2)
        Draw-Text $G $name $F.Body $P.Text ($tx + (Px 22)) $y (Px 220) (Px 20)
        Draw-Text $G $(if ($item.Valid) { $market } else { (Tx 'nombre no v\u00e1lido: usa nombre@marketplace') }) $F.Small $P.Faint ($tx + (Px 250)) ($y + (Px 2)) (Px 200) (Px 18)
        $y += Px 22
    }
    if ($job -and $job.action -eq 'team-install' -and $job.state -ne 'running') {
        Draw-Text $G ([string]$job.message) $F.Small $(if ($job.state -eq 'error') { $P.Error } else { $P.Ok }) $tx ($card.Bottom - (Px 24)) ($card.Width - (Px 32)) (Px 18)
    }
}

# ---------------------------------------------------------------- preview (tray.ps1 -RenderHubTo, -HubSection business or home-business)

function Set-BusinessPreview {
    $policy = Merge-BusinessPolicy ([pscustomobject]@{ company = 'Acme'; seatName = 'Premium'; seatMonthlyUsd = 150; reportDir = '\\files\claude\informes'; autoReport = $true
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
}
