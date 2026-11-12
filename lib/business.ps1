# ClaudeMaxxing for companies. install.ps1 picks the edition (-Personal, the default, or -Business) and keeps it in
# edition.json; a policy that IT puts in %ProgramData%\ClaudeMaxxing\policy.json makes the PC business whatever the
# flag says. The business edition adds the Empresa section (lib\hubbusiness.ps1): the seat report (use, API-equivalent
# cost against the seat price, and whether the seat fits), reports for a shared folder and the team's summary, the
# company's objectives for Claude Judge, and the team kit of plugins. Its policy can switch modules off.
# Needs common.ps1 only (tests); the tray, open-session.ps1, whisper.ps1 and lib\maxx-worker.ps1 load it.
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

$BusinessHome       = Join-Path $TrayHome 'business'
$EditionFile        = Join-Path $TrayHome 'edition.json'
$UserPolicyFile     = Join-Path $BusinessHome 'policy.json'
$UserObjectivesFile = Join-Path $BusinessHome 'objetivos.md'
# The last calibrated window capacity and the last report sent (the tray writes it).
$SeatStateFile      = Join-Path $BusinessHome 'seat.json'
$MachinePolicyDir   = Join-Path $env:ProgramData $AppName

# What a policy can switch off, with its name in the window.
$script:BusinessModules = [ordered]@{ freellm = 'FreeLLMAPI'; bridge = 'Otros PCs'; whisper = 'Claude Whisper'; whip = 'Claude Whip' }
$script:ObjectivesMarker = '--- Objetivos de la empresa ---'

# ---------------------------------------------------------------- edition and policy

# Off by default for a company: FreeLLMAPI sends prompts to free third-party providers (some train on them), Otros
# PCs runs an SSH server that gives a shell as the user, Claude Whisper sends calls to an undocumented service and
# Claude Whip hands the code to other companies' agents (Codex, Gemini...).
function New-DefaultPolicy {
    [pscustomobject][ordered]@{
        company = ''
        disabled = @('freellm', 'bridge', 'whisper', 'whip')
        seatName = ''
        seatMonthlyUsd = 0
        reportDir = ''
        autoReport = $false
        reportProjects = $true
        marketplaces = @()
        plugins = @()
    }
}

# The defaults with every field the file sets; unknown fields are ignored, lists stay lists.
function Merge-BusinessPolicy($Override) {
    $policy = New-DefaultPolicy
    if (-not $Override) { return $policy }
    foreach ($name in @($policy.PSObject.Properties.Name)) {
        $prop = $Override.PSObject.Properties[$name]
        if (-not $prop -or $null -eq $prop.Value) { continue }
        $policy.$name = if ($policy.$name -is [array]) { @($prop.Value | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
            elseif ($policy.$name -is [bool]) { [bool]$prop.Value }
            elseif ($policy.$name -is [int]) { [double]$prop.Value }
            else { [string]$prop.Value }
    }
    $policy
}

# The edition to install: IT's policy wins, then the flag, then what the last install chose.
function Resolve-Edition([bool]$Business, [bool]$Personal, [string]$Saved, [bool]$Managed) {
    if ($Business -and $Personal) { throw 'Choose one edition: -Personal or -Business.' }
    if ($Managed -or $Business) { return 'business' }
    if ($Personal) { return 'personal' }
    if ($Saved -eq 'business') { 'business' } else { 'personal' }
}

# @{ Edition; Business; Policy; Source (the policy file, '' for the defaults); Managed (IT's file) }. A damaged policy
# file gives the defaults, which keep every module that a company may not want off.
function Get-BusinessState([string]$MachineDir = $MachinePolicyDir, [string]$EditionPath = $EditionFile, [string]$UserPolicy = $UserPolicyFile) {
    $machineFile = Join-Path $MachineDir 'policy.json'
    $managed = Test-Path -LiteralPath $machineFile
    $saved = Read-JsonFile $EditionPath
    $edition = if ($managed -or ($saved -and $saved.edition -eq 'business')) { 'business' } else { 'personal' }
    $source = if ($managed) { $machineFile } elseif (Test-Path -LiteralPath $UserPolicy) { $UserPolicy } else { '' }
    $policy = Merge-BusinessPolicy $(if ($source) { Read-JsonFile $source } else { $null })
    [pscustomobject]@{ Edition = $edition; Business = ($edition -eq 'business'); Policy = $policy; Source = $source; Managed = $managed }
}

function Test-ModuleAllowed($State, [string]$Module) {
    if (-not $State -or -not $State.Business) { return $true }
    @($State.Policy.disabled) -notcontains $Module
}

# "name@marketplace" and "owner/repo" or an https URL: what the team kit hands to claude plugin.
function Test-PluginRef([string]$Ref) { $Ref -match '^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$' }
function Test-MarketplaceSource([string]$Source) { ($Source -match '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$') -or ($Source -match '^https://[^\s"]+$') }

# ---------------------------------------------------------------- objectives for Claude Judge

# IT's objectives (ProgramData) first, else the user's; HTML comments (the template's hints) do not count.
function Get-BusinessObjectives([string]$MachineDir = $MachinePolicyDir, [string]$UserFile = $UserObjectivesFile) {
    foreach ($file in (Join-Path $MachineDir 'objetivos.md'), $UserFile) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $text = ([regex]::Replace([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8), '(?s)<!--.*?-->', '')).Trim()
        # Headings alone (the template's title) are not objectives.
        if (@($text -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }).Count) { return $text }
    }
    ''
}

# The idea with the objectives after it, so the jury weighs them too. A retrial passes the old text, which already
# has a block: it is replaced, never repeated.
function Add-JudgeObjectives([string]$Idea, [string]$Objectives) {
    $at = $Idea.IndexOf($script:ObjectivesMarker)
    if ($at -ge 0) { $Idea = $Idea.Substring(0, $at) }
    $Idea = $Idea.TrimEnd()
    if (-not $Objectives.Trim()) { return $Idea }
    $note = Tx 'Juzga tambi\u00e9n si la idea mueve alguno de estos objetivos de la empresa: si no mueve ninguno, cuenta en contra.'
    $Idea + "`r`n`r`n" + $script:ObjectivesMarker + "`r`n" + $note + "`r`n`r`n" + $Objectives.Trim()
}

function Get-ObjectivesTemplate {
    Tx @'
# Objetivos de la empresa

<!-- Claude Judge (Planear sesi\u00f3n) juzga cada idea tambi\u00e9n contra estos objetivos. Escribe uno por l\u00ednea,
     con su resultado medible, debajo de esta nota (la nota no cuenta). Ejemplos:
- Q1: bajar el tiempo de respuesta a clientes de 24 h a 4 h.
- Q1: lanzar la app m\u00f3vil para el 31 de marzo.
-->
'@
}

# ---------------------------------------------------------------- seat report

# One person's last 30 days, from Estadisticas (stats.json's "recent") and the plan: hours, the API-equivalent cost
# against the seat price, and whether the seat fits. $Capacity is what a full 5-hour window costs (the forecast's
# calibration, 0 when unknown); $Weekly the weekly limit's percent now.
function Get-SeatReport($Stats, $Policy, [double]$Capacity, [double]$Weekly, [datetime]$Now) {
    $r = if ($Stats) { $Stats.recent } else { $null }
    $u = if ($r) { $r.usage } else { $null }
    $cost = if ($u) { [double]$u.cost } else { 0.0 }
    $seat = [double]$Policy.seatMonthlyUsd
    $costs = @(@(if ($u) { $u.windows }) | Where-Object { $_ } | ForEach-Object { [double]$_.cost } | Sort-Object)
    $near = if ($Capacity -gt 0) { @($costs | Where-Object { $_ -ge 0.9 * $Capacity }).Count } else { 0 }
    $rec = 'unknown'
    $reason = Tx 'Se calibra cuando una ventana de 5 h llega al 10 % de uso.'
    if ($Weekly -ge 95) { $rec = 'up'; $reason = Tx 'Llegaste al 95 % del l\u00edmite semanal.' }
    elseif (-not $r) { $reason = Tx 'Sin estad\u00edsticas todav\u00eda: abre Estad\u00edsticas una vez.' }
    elseif ($Capacity -gt 0 -and $costs.Count -lt 5) { $reason = Tx 'Hacen falta al menos 5 ventanas de 5 h para decidir.' }
    elseif ($Capacity -gt 0) {
        $p90 = $costs[[Math]::Max(0, [int][Math]::Ceiling(0.9 * $costs.Count) - 1)]
        if ($near / $costs.Count -ge 0.25) { $rec = 'up'; $reason = "$near de las $($costs.Count) ventanas recientes llegaron al 90 % del plan." }
        elseif ($p90 -lt 0.35 * $Capacity) { $rec = 'down'; $reason = Tx '9 de cada 10 ventanas usan menos del 35 % del plan.' }
        else { $rec = 'fit'; $reason = Tx 'El uso cabe en el plan sin quedarse corto.' }
    }
    $report = [ordered]@{
        user = $env:USERNAME; computer = $env:COMPUTERNAME; company = [string]$Policy.company; at = $Now.ToString('o')
        statsAt = $(if ($Stats) { [string]$Stats.scannedAt } else { '' }); days = 30
        hours = $(if ($r) { [Math]::Round([double]$r.seconds / 3600, 1) } else { 0 })
        activeDays = $(if ($r) { [int]$r.activeDays } else { 0 })
        prompts = $(if ($r) { [int]$r.prompts } else { 0 })
        sessions = $(if ($r) { [int]$r.sessions } else { 0 })
        apiCostUsd = [Math]::Round($cost, 2)
        seatName = [string]$Policy.seatName; seatMonthlyUsd = $seat
        roi = $(if ($seat -gt 0) { [Math]::Round($cost / $seat, 1) } else { $null })
        windows = $costs.Count; windowsNearLimit = $near; weeklyPercent = [Math]::Round($Weekly)
        recommendation = $rec; reason = $reason
        projects = @()
    }
    if ($Policy.reportProjects -and $r) {
        $report.projects = @(@($r.projects) | Where-Object { $_ } | Select-Object -First 10 | ForEach-Object {
            [ordered]@{ name = [string]$_.name; hours = [Math]::Round([double]$_.seconds / 3600, 1); prompts = [int]$_.prompts } })
    }
    [pscustomobject]$report
}

function Format-SeatAdvice([string]$Recommendation) {
    switch ($Recommendation) {
        'up'   { Tx 'Se queda corto' }
        'down' { Tx 'Sobra asiento' }
        'fit'  { 'Encaja' }
        default { 'Sin calibrar' }
    }
}

# The shared folder from the policy (environment variables allowed), else Documents\ClaudeMaxxing\informes.
function Get-ReportDir($Policy) {
    if ($Policy.reportDir) { return [Environment]::ExpandEnvironmentVariables([string]$Policy.reportDir) }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) "$AppName\informes"
}

# <dir>\<yyyy-MM-dd>_<PC>_<user>.json; the same day overwrites. Returns the path.
function Export-SeatReport($Report, [string]$Dir) {
    $who = ([string]$Report.computer + '_' + [string]$Report.user) -replace '[^A-Za-z0-9._-]', '_'
    $path = Join-Path $Dir ('{0}_{1}.json' -f ([datetime]$Report.at).ToString('yyyy-MM-dd'), $who)
    Write-JsonFile $path $Report
    $path
}

function Get-SeatState { $s = Read-JsonFile $SeatStateFile; if ($s) { $s } else { [pscustomobject]@{ capacity = 0; capacityAt = ''; lastReportAt = '' } } }

function Save-SeatState($State) { Write-JsonFile $SeatStateFile $State }

# Every 7 days when the policy asks for it.
function Test-ReportDue($Business, $Seat, [datetime]$Now) {
    if (-not $Business -or -not $Business.Business -or -not $Business.Policy.autoReport) { return $false }
    $last = [datetime]::MinValue
    if ($Seat -and $Seat.lastReportAt) { try { $last = [datetime]$Seat.lastReportAt } catch { } }
    ($Now - $last).TotalDays -ge 7
}

# ---------------------------------------------------------------- team report

# The newest report of each person (PC and user) in a folder of reports, most expensive first.
function Get-TeamReport([string]$Dir) {
    $latest = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $r = Read-JsonFile $file.FullName
        if (-not $r -or -not $r.user -or -not $r.at) { continue }
        $key = ([string]$r.computer + '\' + [string]$r.user).ToLowerInvariant()
        if (-not $latest.ContainsKey($key) -or [string]$r.at -gt [string]$latest[$key].at) { $latest[$key] = $r }
    }
    # Unrolled: callers wrap it in @().
    @($latest.Values | Sort-Object @{ Expression = { [double]$_.apiCostUsd }; Descending = $true })
}

# Totals of the team: people, hours, API-equivalent cost, seats and how many seats fall short or have room.
function Measure-TeamReport($Rows) {
    $rows = @($Rows)
    $cost = ($rows | Measure-Object -Property apiCostUsd -Sum).Sum
    $seats = ($rows | Measure-Object -Property seatMonthlyUsd -Sum).Sum
    [pscustomobject]@{
        People = $rows.Count
        Hours = [Math]::Round([double](($rows | Measure-Object -Property hours -Sum).Sum), 1)
        ApiCostUsd = [Math]::Round([double]$cost, 2)
        SeatsUsd = [double]$seats
        Roi = $(if ($seats -gt 0) { [Math]::Round([double]$cost / $seats, 1) } else { $null })
        Up = @($rows | Where-Object { $_.recommendation -eq 'up' }).Count
        Down = @($rows | Where-Object { $_.recommendation -eq 'down' }).Count
    }
}

# A CSV for Excel (the list separator of this PC's culture), one row per person.
function Export-TeamCsv($Rows, [string]$Path) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @($Rows) | ForEach-Object {
        [pscustomobject][ordered]@{ Persona = $_.user; PC = $_.computer; Horas = $_.hours; DiasActivos = $_.activeDays; Prompts = $_.prompts
            CosteApiUsd = $_.apiCostUsd; Asiento = $_.seatName; AsientoUsd = $_.seatMonthlyUsd; Retorno = $_.roi
            VentanasAlLimite = $_.windowsNearLimit; Ventanas = $_.windows; Recomendacion = (Format-SeatAdvice $_.recommendation); Motivo = $_.reason; Fecha = $_.at }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -UseCulture
    $Path
}
