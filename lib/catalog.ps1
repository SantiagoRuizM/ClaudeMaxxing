# The catalog of "Skills y MCP": third-party skills (catalog\skills, copied by tools\vendor-catalog.ps1 from their
# repos at pinned commits, text only, listed in catalog\index.json) and MCP servers (catalog\mcp.json), all off until
# switched on in the window. On is per target: "*" (always: every session, ~/.claude/skills and claude mcp -s user)
# or an Ambiente (only the sessions in its folder, claude.dir or else folder: <dir>\.claude\skills and claude mcp
# -s local run there). A skill on is a copy of its folder with a .maxx-catalog marker; off deletes marked copies only,
# so a skill of yours with the same name is never touched. MCP servers are added and removed by lib\maxx-worker.ps1
# (catalog-mcp), which records what it added in catalog-applied.json and only ever removes those.
# Needs common.ps1 only (tests). Keep this file ASCII.

$CatalogFile = Join-Path $TrayHome 'catalog.json'
$CatalogAppliedFile = Join-Path $TrayHome 'catalog-applied.json'
$CatalogMarker = '.maxx-catalog'
$CatalogEverywhere = '*'

# Every item: Kind (skill|mcp), Name, Label, Source (anthropic, superpowers, wshobson, ecc or mcp), Description, Auth.
function Get-CatalogItems([string]$CatalogDir) {
    $items = New-Object System.Collections.Generic.List[object]
    $index = Read-JsonFile (Join-Path $CatalogDir 'index.json')
    foreach ($skill in @($(if ($index) { $index.skills }))) {
        $items.Add([pscustomobject]@{ Kind = 'skill'; Name = [string]$skill.name; Label = [string]$skill.name; Source = [string]$skill.source
            Description = [string]$skill.description; Auth = ''; Config = $null })
    }
    $mcp = Read-JsonFile (Join-Path $CatalogDir 'mcp.json')
    foreach ($server in @($(if ($mcp) { $mcp.servers }))) {
        $items.Add([pscustomobject]@{ Kind = 'mcp'; Name = [string]$server.name; Label = [string]$server.label; Source = 'mcp'
            Description = [string]$server.description; Auth = [string]$server.auth; Config = $server.config })
    }
    $items.ToArray()
}

# @{ skills = @{ name = [string[]] targets }; mcp = @{ ... } }; a missing or damaged file is all off.
function Get-CatalogSettings([string]$Path = $CatalogFile) {
    $saved = Read-JsonFile $Path
    $settings = @{ skills = @{}; mcp = @{} }
    foreach ($kind in 'skills', 'mcp') {
        if (-not $saved -or $saved.$kind -isnot [pscustomobject]) { continue }
        foreach ($prop in $saved.$kind.PSObject.Properties) {
            [string[]]$targets = @($prop.Value | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($targets.Count) { $settings[$kind][$prop.Name] = $targets }
        }
    }
    $settings
}

function Save-CatalogSettings($Settings, [string]$Path = $CatalogFile) { Write-JsonFile $Path $Settings }

function Get-CatalogKey([string]$Kind) { if ($Kind -eq 'mcp') { 'mcp' } else { 'skills' } }

function Test-CatalogOn($Settings, [string]$Kind, [string]$Name, [string]$Target) {
    $map = $Settings[(Get-CatalogKey $Kind)]
    [bool]($map.ContainsKey($Name) -and @($map[$Name]) -contains $Target)
}

function Set-CatalogItem($Settings, [string]$Kind, [string]$Name, [string]$Target, [bool]$On) {
    $map = $Settings[(Get-CatalogKey $Kind)]
    [string[]]$targets = @(@($(if ($map.ContainsKey($Name)) { $map[$Name] })) | Where-Object { $_ -and $_ -ne $Target })
    if ($On) { $targets += $Target }
    if ($targets.Count) { $map[$Name] = $targets } else { $map.Remove($Name) }
}

# "*" and each Ambiente with an existing folder: Id, Name, Dir ('' for "*"), Skills (the skills folder), Scope.
function Get-CatalogTargets([string]$EnvDir = (Join-Path $TrayHome 'harness\environments'), [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $targets = [ordered]@{}
    $targets[$CatalogEverywhere] = [pscustomobject]@{ Id = $CatalogEverywhere; Name = 'Siempre'; Dir = ''; Skills = (Join-Path $ClaudeHome 'skills'); Scope = 'user' }
    foreach ($file in @(Get-ChildItem -LiteralPath $EnvDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $def = Read-JsonFile $file.FullName
        if (-not $def) { continue }
        $dir = if ($def.claude -and $def.claude.dir) { [string]$def.claude.dir } else { [string]$def.folder }
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $id = $file.BaseName.ToLowerInvariant()
        $targets[$id] = [pscustomobject]@{ Id = $id; Name = $(if ($def.name) { [string]$def.name } else { $file.BaseName }); Dir = $dir
            Skills = (Join-Path $dir '.claude\skills'); Scope = 'local' }
    }
    $targets
}

# A marked copy, deleted without following a link (a junction's target is not ours).
function Remove-CatalogCopy([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path) }
    else { Remove-Item -LiteralPath $Path -Recurse -Force }
}

# The project's .git\info\exclude lists the copies in that folder, so git status stays clean.
function Update-CatalogGitExclude([string]$Dir, [string[]]$Names) {
    $git = Join-Path $Dir '.git'
    if (-not (Test-Path -LiteralPath $git -PathType Container)) { return }
    $file = Join-Path $git 'info\exclude'
    $begin = '# >>> ClaudeMaxxing catalog'
    $end = '# <<< ClaudeMaxxing catalog'
    $lines = @(if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllLines($file) })
    $kept = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $lines) {
        if ($line -eq $begin) { $inside = $true; continue }
        if ($line -eq $end) { $inside = $false; continue }
        if (-not $inside) { $kept.Add($line) }
    }
    if ($Names.Count) {
        $kept.Add($begin)
        foreach ($name in $Names) { $kept.Add('/.claude/skills/' + $name + '/') }
        $kept.Add($end)
    }
    if ((@($kept) -join "`n") -eq ($lines -join "`n")) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    [IO.File]::WriteAllText($file, ((@($kept) -join "`n") + "`n"))
}

# Makes every target's skills folder match the settings: copies what is on and missing (all again with -Refresh,
# after an update), deletes marked copies that are off. Returns the names left alone because a folder of the user's
# already has them.
function Sync-CatalogSkills($Settings, $Targets, [string]$CatalogDir, [switch]$Refresh) {
    $sources = @{}
    foreach ($item in @(Get-CatalogItems $CatalogDir | Where-Object { $_.Kind -eq 'skill' })) {
        $sources[$item.Name] = Join-Path $CatalogDir ('skills\' + $item.Source + '\' + $item.Name)
    }
    $conflicts = @()
    foreach ($target in @($Targets.Values)) {
        $wanted = @($Settings.skills.Keys | Where-Object { @($Settings.skills[$_]) -contains $target.Id -and $sources.ContainsKey($_) })
        $root = $target.Skills
        $ours = @()
        if (Test-Path -LiteralPath $root) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName $CatalogMarker))) { continue }
                if ($Refresh -or $wanted -notcontains $dir.Name) { Remove-CatalogCopy $dir.FullName } else { $ours += $dir.Name }
            }
        }
        foreach ($name in $wanted) {
            $to = Join-Path $root $name
            if (Test-Path -LiteralPath $to) {
                if ($ours -notcontains $name) { $conflicts += $name }
                continue
            }
            if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
            Copy-Item -LiteralPath $sources[$name] -Destination $to -Recurse
            [IO.File]::WriteAllText((Join-Path $to $CatalogMarker), 'Copied by ClaudeMaxxing from its catalog. Switch it off in ClaudeMaxxing > Skills y MCP > Catalogo.')
            $ours += $name
        }
        if ($target.Dir) { Update-CatalogGitExclude $target.Dir ([string[]]@($ours | Sort-Object)) }
    }
    , @($conflicts | Select-Object -Unique)
}

# What ClaudeMaxxing added, per target id: @{ '*' = [string[]]; '<env>' = ... }.
function Get-CatalogApplied([string]$Path = $CatalogAppliedFile) {
    $saved = Read-JsonFile $Path
    $applied = @{}
    if ($saved -is [pscustomobject]) { foreach ($prop in $saved.PSObject.Properties) { $applied[$prop.Name] = [string[]]@($prop.Value | Where-Object { $_ }) } }
    $applied
}

# The claude mcp calls that bring the targets to the settings: Action (add|remove), Name, Target, Server.
# A target that is gone (its Ambiente deleted or its folder missing) is left as it is.
function Get-CatalogMcpPlan($Settings, $Targets, $Applied, $Items) {
    $servers = @{}
    foreach ($item in @($Items | Where-Object { $_.Kind -eq 'mcp' })) { $servers[$item.Name] = $item }
    foreach ($target in @($Targets.Values)) {
        $have = @($(if ($Applied.ContainsKey($target.Id)) { $Applied[$target.Id] }))
        $wanted = @($Settings.mcp.Keys | Where-Object { @($Settings.mcp[$_]) -contains $target.Id -and $servers.ContainsKey($_) })
        foreach ($name in @($have | Where-Object { $wanted -notcontains $_ })) { [pscustomobject]@{ Action = 'remove'; Name = $name; Target = $target; Server = $null } }
        foreach ($name in @($wanted | Where-Object { $have -notcontains $_ })) { [pscustomobject]@{ Action = 'add'; Name = $name; Target = $target; Server = $servers[$name] } }
    }
}

# The claude arguments of one step. Flags, not add-json: Windows PowerShell 5.1 strips the quotes of a JSON argument.
function Get-CatalogMcpArgs($Step) {
    $scope = $Step.Target.Scope
    if ($Step.Action -eq 'remove') { return , @('mcp', 'remove', '-s', $scope, $Step.Name) }
    $config = $Step.Server.Config
    if ($config.url) {
        $transport = if ($config.type) { [string]$config.type } else { 'http' }
        return , @('mcp', 'add', '--transport', $transport, '-s', $scope, $Step.Name, [string]$config.url)
    }
    , (@('mcp', 'add', '-s', $scope, $Step.Name, '--', [string]$config.command) + @($config.args | ForEach-Object { [string]$_ }))
}

# Runs the plan with $Claude (a scriptblock taking the argument array and returning @{ Ok; Output }), in each
# target's folder, recording each step in catalog-applied.json as it succeeds. Returns the error lines.
function Invoke-CatalogMcpSync([scriptblock]$Claude, $Settings, $Targets, $Items, [string]$AppliedPath = $CatalogAppliedFile) {
    $applied = Get-CatalogApplied $AppliedPath
    $errors = @()
    foreach ($step in @(Get-CatalogMcpPlan $Settings $Targets $applied $Items)) {
        $id = $step.Target.Id
        Push-Location -LiteralPath $(if ($step.Target.Dir) { $step.Target.Dir } else { $env:USERPROFILE })
        try { $r = & $Claude (Get-CatalogMcpArgs $step) } finally { Pop-Location }
        # Gone already (removed by hand with /mcp or claude mcp remove): nothing left to undo.
        $ok = $r.Ok -or ($step.Action -eq 'remove' -and $r.Output -match 'not found|No MCP server')
        if (-not $ok) { $errors += ($step.Name + ': ' + (($r.Output -split "`n")[0])); continue }
        $now = @($(if ($applied.ContainsKey($id)) { $applied[$id] }) | Where-Object { $_ -ne $step.Name })
        if ($step.Action -eq 'add') { $now += $step.Name }
        $applied[$id] = [string[]]$now
        Write-JsonFile $AppliedPath $applied
    }
    , $errors
}
