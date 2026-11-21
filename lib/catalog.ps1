# The catalog of "Skills y MCP": third-party skills (catalog\skills, copied by tools\vendor-catalog.ps1 from their
# repos at pinned commits, text only, listed in catalog\index.json) and MCP servers (catalog\mcp.json), all off until
# switched on in the window. On is per target: "*" (always: every session, ~/.claude/skills and claude mcp -s user)
# or an Ambiente (only the sessions in its folder, claude.dir or else folder: <dir>\.claude\skills and claude mcp
# -s local run there). A skill on is a copy of its folder with a .maxx-catalog marker; off deletes marked copies only,
# so a skill of yours with the same name is never touched. MCP servers are added and removed by lib\maxx-worker.ps1
# (catalog-mcp), which records what it added in catalog-applied.json and only ever removes those.
# Your own skills and servers are switched in the same list: a skill off in Siempre is "off" in skillOverrides of
# ~/.claude/settings.json; one of your MCP servers off in Siempre is kept in catalog-stash.json and removed with
# claude mcp, then added back like a catalog server. An Ambiente with its own list ("limited") gets exactly that
# list: <dir>\.claude\settings.local.json turns every other skill off (skillOverrides) and blocks every other
# server (deniedMcpServers); catalog-overrides.json records those entries, the only ones ever changed there.
# Needs common.ps1 only (tests). Keep this file ASCII.

$CatalogFile = Join-Path $TrayHome 'catalog.json'
$CatalogAppliedFile = Join-Path $TrayHome 'catalog-applied.json'
$CatalogMarker = '.maxx-catalog'
$CatalogEverywhere = '*'
$CatalogStashFile = Join-Path $TrayHome 'catalog-stash.json'
$CatalogOverridesFile = Join-Path $TrayHome 'catalog-overrides.json'
$ClaudeSettingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'

# Every item: Kind (skill|mcp), Name, Label, Source (anthropic, superpowers, wshobson, ecc, mcp, or tuyos for a
# server of yours switched off in Siempre), Description, Auth, Config.
function Get-CatalogItems([string]$CatalogDir, [string]$StashPath = $CatalogStashFile) {
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
    $stash = Read-JsonFile $StashPath
    if ($stash -is [pscustomobject]) {
        foreach ($prop in $stash.PSObject.Properties) {
            $items.Add([pscustomobject]@{ Kind = 'mcp'; Name = $prop.Name; Label = $prop.Name; Source = 'tuyos'; Description = ''; Auth = ''; Config = $prop.Value })
        }
    }
    $items.ToArray()
}

# @{ skills = @{ name = [string[]] targets }; mcp = @{ ... }; limited = [string[]] the Ambientes with their own list };
# a missing or damaged file is all off. A skill of a plugin goes by "plugin:skill", a server of one by "plugin:p:server".
function Get-CatalogSettings([string]$Path = $CatalogFile) {
    $saved = Read-JsonFile $Path
    $settings = @{ skills = @{}; mcp = @{}; limited = [string[]]@($(if ($saved) { $saved.limited }) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
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
function Update-CatalogGitExclude([string]$Dir, [string[]]$Entries) {
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
    if ($Entries.Count) {
        $kept.Add($begin)
        foreach ($entry in $Entries) { $kept.Add($entry) }
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
        # A skill on always is already loaded in an Ambiente's folder: not copied there again.
        $wanted = @($Settings.skills.Keys | Where-Object { @($Settings.skills[$_]) -contains $target.Id -and $sources.ContainsKey($_) -and
            ($target.Id -eq $CatalogEverywhere -or @($Settings.skills[$_]) -notcontains $CatalogEverywhere) })
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
        if ($target.Dir) {
            $lines = @($ours | Sort-Object | ForEach-Object { '/.claude/skills/' + $_ + '/' })
            if (@($Settings.limited) -contains $target.Id) { $lines += '/.claude/settings.local.json' }
            Update-CatalogGitExclude $target.Dir ([string[]]$lines)
        }
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
        $wanted = @($Settings.mcp.Keys | Where-Object { @($Settings.mcp[$_]) -contains $target.Id -and $servers.ContainsKey($_) -and
            ($target.Id -eq $CatalogEverywhere -or @($Settings.mcp[$_]) -notcontains $CatalogEverywhere) })
        foreach ($name in @($have | Where-Object { $wanted -notcontains $_ })) { [pscustomobject]@{ Action = 'remove'; Name = $name; Target = $target; Server = $null } }
        foreach ($name in @($wanted | Where-Object { $have -notcontains $_ })) { [pscustomobject]@{ Action = 'add'; Name = $name; Target = $target; Server = $servers[$name] } }
    }
}

# The claude arguments of one step. Flags, not add-json: Windows PowerShell 5.1 strips the quotes of a JSON argument.
function Get-CatalogMcpArgs($Step) {
    $scope = $Step.Target.Scope
    if ($Step.Action -eq 'remove') { return , @('mcp', 'remove', '-s', $scope, $Step.Name) }
    $config = $Step.Server.Config
    # A server of yours brings its env and headers; -e and -H take several values, so -s after them ends the list.
    $opts = @()
    if ($config.env) { foreach ($p in $config.env.PSObject.Properties) { $opts += '-e', ($p.Name + '=' + [string]$p.Value) } }
    if ($config.headers) { foreach ($p in $config.headers.PSObject.Properties) { $opts += '-H', ($p.Name + ': ' + [string]$p.Value) } }
    if ($config.url) {
        $transport = if ($config.type) { [string]$config.type } else { 'http' }
        return , (@('mcp', 'add', '--transport', $transport) + $opts + @('-s', $scope, $Step.Name, [string]$config.url))
    }
    , (@('mcp', 'add') + $opts + @('-s', $scope, $Step.Name, '--', [string]$config.command) + @($config.args | ForEach-Object { [string]$_ }))
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

# ---------------------------------------------------------------- your own skills and servers, and the lists

# The JSON text with its top-level key $Name set to $Value (written compact) or, with $null, removed. Edited as
# text, so the rest of a settings file keeps its formatting. The value it replaces must be flat (an object of plain
# values, or an array of those). $null when the result would not parse.
function Set-JsonKeyText([string]$Text, [string]$Name, $Value) {
    if (-not $Text.Trim()) { $Text = '{}' }
    $json = if ($null -eq $Value) { '' } else { ConvertTo-Json -InputObject $Value -Compress -Depth 4 }
    $found = ([regex]('(\s*)"' + [regex]::Escape($Name) + '"\s*:\s*(\{[^{}]*\}|\[[^\[\]]*\])')).Match($Text)
    if ($found.Success) {
        $before = $Text.Substring(0, $found.Index)
        $after = $Text.Substring($found.Index + $found.Length)
        if ($json) { $new = $before + $found.Groups[1].Value + '"' + $Name + '": ' + $json + $after }
        elseif ($after -match '^\s*,') { $new = $before + ($after -replace '^\s*,', '') }
        else { $new = ($before -replace ',\s*$', '') + $after }
    } elseif ($json) {
        $open = $Text.IndexOf('{')
        if ($open -lt 0) { return $null }
        $rest = $Text.Substring($open + 1)
        $new = $Text.Substring(0, $open + 1) + "`n  `"$Name`": " + $json + $(if ($rest -match '^\s*\}') { "`n" } else { ',' }) + $rest
    } else { return $Text }
    try { $null = $new | ConvertFrom-Json; $new } catch { $null }
}

function Write-SettingsText([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# The skills switched off in Siempre: the "off" entries of skillOverrides (also the ones set with /skills).
function Get-CatalogSkillOff([string]$SettingsPath = $ClaudeSettingsFile) {
    $saved = Read-JsonFile $SettingsPath
    if (-not $saved -or $saved.skillOverrides -isnot [pscustomobject]) { return , [string[]]@() }
    , [string[]]@($saved.skillOverrides.PSObject.Properties | Where-Object { $_.Value -eq 'off' } | ForEach-Object { $_.Name })
}

function Set-CatalogSkillOff([string]$Key, [bool]$Off, [string]$SettingsPath = $ClaudeSettingsFile) {
    $text = if (Test-Path -LiteralPath $SettingsPath) { [IO.File]::ReadAllText($SettingsPath) } else { '{}' }
    try { $saved = $text | ConvertFrom-Json } catch { throw "$SettingsPath is not valid JSON" }
    $map = [ordered]@{}
    if ($saved -and $saved.skillOverrides -is [pscustomobject]) { foreach ($p in $saved.skillOverrides.PSObject.Properties) { if ($p.Name -ne $Key) { $map[$p.Name] = $p.Value } } }
    if ($Off) { $map[$Key] = 'off' }
    $new = Set-JsonKeyText $text 'skillOverrides' $(if ($map.Count) { $map })
    if ($null -eq $new) { throw "could not edit $SettingsPath" }
    if ($new -ne $text) { Write-SettingsText $SettingsPath $new }
}

# One of your user-scope MCP servers switched off in Siempre: its config is kept in the stash and it counts as added
# by ClaudeMaxxing, so the next catalog-mcp run removes it (claude mcp remove -s user) and can add it back later.
function Save-CatalogStash([string]$Name, [string]$ClaudeJson = (Join-Path $env:USERPROFILE '.claude.json'), [string]$StashPath = $CatalogStashFile, [string]$AppliedPath = $CatalogAppliedFile) {
    $config = Read-JsonFile $ClaudeJson
    $server = if ($config -and $config.mcpServers) { $config.mcpServers.PSObject.Properties[$Name] } else { $null }
    if (-not $server) { throw "$Name is not in your MCP servers" }
    $stash = @{}
    $saved = Read-JsonFile $StashPath
    if ($saved -is [pscustomobject]) { foreach ($p in $saved.PSObject.Properties) { $stash[$p.Name] = $p.Value } }
    $stash[$Name] = $server.Value
    Write-JsonFile $StashPath $stash
    $applied = Get-CatalogApplied $AppliedPath
    $applied[$CatalogEverywhere] = [string[]](@(@($applied[$CatalogEverywhere]) | Where-Object { $_ -and $_ -ne $Name }) + $Name)
    Write-JsonFile $AppliedPath $applied
}

# The Ambientes' lists in their folders. $SkillKeys and $McpKeys: everything Claude Code loads in every folder
# (your skills, the plugins', claude.ai's, the catalog's on always; your user-scope servers and the plugins').
# A limited Ambiente turns each of those skills off or on as its list says and blocks the servers not on it; an
# entry of yours with the same key is left as it is. One that is no longer limited gets its entries taken out.
function Sync-CatalogOverrides($Settings, $Targets, [string[]]$SkillKeys, [string[]]$McpKeys, [string]$OursPath = $CatalogOverridesFile) {
    $ours = @{}
    $saved = Read-JsonFile $OursPath
    if ($saved -is [pscustomobject]) { foreach ($p in $saved.PSObject.Properties) { $ours[$p.Name] = $p.Value } }
    $record = @{}
    foreach ($id in @($ours.Keys)) { if (-not $Targets.Contains($id)) { $record[$id] = $ours[$id] } }
    foreach ($target in @($Targets.Values | Where-Object { $_.Dir })) {
        $id = $target.Id
        $prevSkills = @($(if ($ours[$id]) { $ours[$id].skills }) | Where-Object { $_ })
        $prevMcp = @($(if ($ours[$id]) { $ours[$id].mcp }) | Where-Object { $_ })
        $limited = @($Settings.limited) -contains $id
        if (-not $limited -and -not $prevSkills.Count -and -not $prevMcp.Count) { continue }
        $file = Join-Path $target.Dir '.claude\settings.local.json'
        $text = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '{}' }
        try { $local = $text | ConvertFrom-Json } catch { $record[$id] = $ours[$id]; continue }
        $overrides = [ordered]@{}
        if ($local -and $local.skillOverrides -is [pscustomobject]) {
            foreach ($p in $local.skillOverrides.PSObject.Properties) { if ($prevSkills -notcontains $p.Name) { $overrides[$p.Name] = $p.Value } }
        }
        $denied = @(@($(if ($local) { $local.deniedMcpServers })) | Where-Object { $_ -and $prevMcp -notcontains [string]$_.serverName })
        $mineSkills = @(); $mineMcp = @()
        if ($limited) {
            foreach ($key in $SkillKeys) {
                if ($overrides.Contains($key)) { continue }
                $overrides[$key] = if (@($Settings.skills[$key]) -contains $id) { 'on' } else { 'off' }
                $mineSkills += $key
            }
            foreach ($key in $McpKeys) {
                if (@($Settings.mcp[$key]) -contains $id -or @($denied | Where-Object { [string]$_.serverName -eq $key }).Count) { continue }
                $denied += [pscustomobject]@{ serverName = $key }
                $mineMcp += $key
            }
        }
        $new = Set-JsonKeyText $text 'skillOverrides' $(if ($overrides.Count) { $overrides })
        if ($null -ne $new) { $new = Set-JsonKeyText $new 'deniedMcpServers' $(if ($denied.Count) { , $denied }) }
        if ($null -eq $new) { $record[$id] = $ours[$id]; continue }
        if ($new -ne $text) { Write-SettingsText $file $new }
        if ($mineSkills.Count -or $mineMcp.Count) { $record[$id] = @{ skills = [string[]]$mineSkills; mcp = [string[]]$mineMcp } }
    }
    $json = ConvertTo-Json -InputObject $record -Depth 4
    if (-not (Test-Path -LiteralPath $OursPath) -or [IO.File]::ReadAllText($OursPath) -ne $json) { Write-JsonFile $OursPath $record }
}
