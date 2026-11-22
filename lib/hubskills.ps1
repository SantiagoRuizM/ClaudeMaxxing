# "Skills y MCP" in the ClaudeMaxxing window: the skills and MCP servers Claude Code loads for this user, read
# from disk (nothing is started), and the packages that create them: Anthropic's official plugins skill-creator,
# mcp-server-dev and plugin-dev, installed with claude plugin by lib\maxx-worker.ps1 (pack-install). A package
# installed opens a Claude Code session that uses it ("Nueva skill...").
# The reading needs common.ps1 only (tests); the section, theme.ps1, hub.ps1 and maxx.ps1. Keep this file ASCII.

$script:SkillPacks = @(
    @{ Id = 'skill-creator'; Plugin = 'skill-creator@claude-plugins-official'; Kind = 'skill'
        Label = 'Crear skills'; Button = 'Nueva skill...'; Text = 'skill-creator: crea, mejora y mide skills.' },
    @{ Id = 'mcp-server-dev'; Plugin = 'mcp-server-dev@claude-plugins-official'; Kind = 'mcp'
        Label = 'Crear servidores MCP'; Button = 'Nuevo MCP...'; Text = 'mcp-server-dev: dise\u00f1a y construye servidores MCP, remotos o locales.' },
    @{ Id = 'plugin-dev'; Plugin = 'plugin-dev@claude-plugins-official'; Kind = 'plugin'
        Label = 'Crear plugins'; Button = 'Nuevo plugin...'; Text = 'plugin-dev: hooks, comandos, agentes e integraci\u00f3n MCP en un plugin.' }
)
$script:SkillsPageRows = 6

# ---------------------------------------------------------------- reading

# A SKILL.md's name and description, from its front matter (a folded "description: >" too).
function Read-SkillHeader([string]$Path) {
    $head = [pscustomobject]@{ Name = ''; Description = '' }
    try { $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) } catch { return $head }
    if (-not $lines.Count -or $lines[0].Trim() -ne '---') { return $head }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { break }
        if ($lines[$i] -notmatch '^(name|description):\s*(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value -in '>', '|', '>-', '|-') {
            $parts = @()
            while ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s+\S') { $i++; $parts += $lines[$i].Trim() }
            $value = $parts -join ' '
        }
        $value = $value.Trim([char[]]@('"', "'"))
        if ($key -eq 'name') { $head.Name = $value } else { $head.Description = $value }
    }
    $head
}

# The plugins Claude Code loads: user-scope ones not switched off in settings.json, and project-scope ones
# (which load in that project only).
function Get-ClaudePlugins([string]$ClaudeHome) {
    $installed = Read-JsonFile (Join-Path $ClaudeHome 'plugins\installed_plugins.json')
    $settings = Read-JsonFile (Join-Path $ClaudeHome 'settings.json')
    $plugins = @()
    if (-not $installed -or -not $installed.plugins) { return $plugins }
    foreach ($prop in $installed.plugins.PSObject.Properties) {
        $flag = if ($settings -and $settings.enabledPlugins) { $settings.enabledPlugins.PSObject.Properties[$prop.Name] } else { $null }
        foreach ($entry in @($prop.Value)) {
            if (-not $entry.installPath -or -not (Test-Path -LiteralPath ([string]$entry.installPath))) { continue }
            $user = [string]$entry.scope -eq 'user'
            if ($user -and $flag -and -not $flag.Value) { continue }
            $plugins += [pscustomobject]@{ Key = $prop.Name; Name = $prop.Name.Split('@')[0]; Path = [string]$entry.installPath
                Project = $(if ($user -or -not $entry.projectPath) { '' } else { Split-Path -Leaf ([string]$entry.projectPath) }) }
        }
    }
    $plugins
}

function Format-PluginSource($Plugin) {
    (L 'plugin ') + $Plugin.Name + $(if ($Plugin.Project) { ' (' + $Plugin.Project + ')' } else { '' })
}

# Each row once, by name and source (a plugin installed for several projects, a skill synced twice).
function Select-UniqueRows($Rows) {
    $seen = @{}
    @($Rows | Where-Object { $_ } | Where-Object { $key = $_.Name + '|' + $_.Source; if ($seen.ContainsKey($key)) { $false } else { $seen[$key] = $true; $true } })
}

# Every skill: yours (~/.claude/skills), the plugins', and claude.ai's synced ones; yours first.
function Get-SkillList([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $skills = New-Object System.Collections.Generic.List[object]
    # Key: the name skillOverrides takes ("plugin:skill" for a plugin's). Catalog: a copy of the catalog's (.maxx-catalog).
    $add = {
        param([string]$Dir, [string]$Source, [string]$Plugin)
        $file = Join-Path $Dir 'SKILL.md'
        if (-not (Test-Path -LiteralPath $file)) { return }
        $head = Read-SkillHeader $file
        $name = if ($head.Name) { $head.Name } else { Split-Path -Leaf $Dir }
        $skills.Add([pscustomobject]@{ Name = $name; Description = $head.Description; Source = $Source; Path = $Dir
            Key = $(if ($Plugin) { $Plugin + ':' + $name } else { $name }); Catalog = (Test-Path -LiteralPath (Join-Path $Dir '.maxx-catalog')) })
    }
    $root = Join-Path $ClaudeHome 'skills'
    if (Test-Path -LiteralPath $root) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') -and $_.Name -ne 'synced' })) {
            & $add $dir.FullName 'tuyas'
        }
        $synced = Join-Path $root 'synced'
        if (Test-Path -LiteralPath $synced) {
            foreach ($bucket in @(Get-ChildItem -LiteralPath $synced -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })) {
                foreach ($dir in @(Get-ChildItem -LiteralPath $bucket.FullName -Directory -ErrorAction SilentlyContinue)) { & $add $dir.FullName 'claude.ai' }
            }
        }
    }
    foreach ($plugin in @(Get-ClaudePlugins $ClaudeHome)) {
        $dir = Join-Path $plugin.Path 'skills'
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($skill in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) { & $add $skill.FullName (Format-PluginSource $plugin) $plugin.Name }
    }
    $order = @{ Expression = { if ($_.Source -eq 'tuyas') { 0 } elseif ($_.Source -like 'plugin *') { 1 } else { 2 } } }
    @(Select-UniqueRows ($skills | Sort-Object $order, Source, Name))
}

# The rows of an "mcpServers" object: name, kind (stdio, http, sse) and what it runs or reaches. Key: the name
# deniedMcpServers takes ("plugin:<plugin>:<server>" for a plugin's).
function Get-McpServerRows($Servers, [string]$Source, [string]$Plugin) {
    if (-not $Servers -or $Servers -is [string]) { return @() }
    foreach ($prop in $Servers.PSObject.Properties) {
        $server = $prop.Value
        if ($server -isnot [pscustomobject]) { continue }
        $kind = if ($server.type) { [string]$server.type } elseif ($server.url) { 'http' } else { 'stdio' }
        $target = if ($server.url) { try { ([uri][string]$server.url).Host } catch { [string]$server.url } }
            elseif ($server.command) { [IO.Path]::GetFileName([string]$server.command) } else { '' }
        [pscustomobject]@{ Name = $prop.Name; Kind = $kind; Target = $target; Source = $Source; Key = $(if ($Plugin) { "plugin:${Plugin}:$($prop.Name)" } else { $prop.Name }) }
    }
}

# Every MCP server: yours (~/.claude.json), each project's, and the plugins' (.mcp.json, in either shape, or
# plugin.json's mcpServers). claude.ai's connectors live in the account, not on disk: they are not listed.
function Get-McpList([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'), [string]$ClaudeJson = (Join-Path $env:USERPROFILE '.claude.json')) {
    $rows = @()
    $config = Read-JsonFile $ClaudeJson
    if ($config) {
        $rows += @(Get-McpServerRows $config.mcpServers 'tuyos')
        if ($config.projects) {
            foreach ($project in $config.projects.PSObject.Properties) { $rows += @(Get-McpServerRows $project.Value.mcpServers ((L 'proyecto ') + (Split-Path -Leaf $project.Name))) }
        }
    }
    foreach ($plugin in @(Get-ClaudePlugins $ClaudeHome)) {
        $source = Format-PluginSource $plugin
        $file = Read-JsonFile (Join-Path $plugin.Path '.mcp.json')
        if ($file) { $rows += @(Get-McpServerRows $(if ($file.mcpServers) { $file.mcpServers } else { $file }) $source $plugin.Name) }
        $manifest = Read-JsonFile (Join-Path $plugin.Path '.claude-plugin\plugin.json')
        if ($manifest) { $rows += @(Get-McpServerRows $manifest.mcpServers $source $plugin.Name) }
    }
    $order = @{ Expression = { if ($_.Source -eq 'tuyos') { 0 } elseif ($_.Source -like 'plugin *') { 1 } else { 2 } } }
    @(Select-UniqueRows ($rows | Sort-Object $order, Source, Name))
}

# Which creation packages are installed for the user (a project-scope install loads in that project only).
function Get-SkillPackState([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $user = @(Get-ClaudePlugins $ClaudeHome | Where-Object { -not $_.Project } | ForEach-Object { $_.Key })
    foreach ($pack in $script:SkillPacks) { [pscustomobject]@{ Id = $pack.Id; Installed = ($user -contains $pack.Plugin) } }
}

# ---------------------------------------------------------------- section

# Read again while the section is open: every 20 s, and as soon as a package install or an MCP run ends. Each read
# also brings the Ambientes' lists up to date, so a skill or a plugin installed since is off where a list lacks it.
function Update-HubSkills([switch]$Force) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Preview) { return }
    $c = $hub.Cache
    $job = $c.MaxxStatus
    $jobEnded = $job -and $job.action -in 'pack-install', 'catalog-mcp' -and $job.state -ne 'running' -and [string]$job.at -ne [string]$c.SkillsJobSeen
    if (-not $Force -and -not $jobEnded) {
        if ($hub.Section -ne 'skills') { return }
        if ($c.SkillsAt -and ((Get-Date) - $c.SkillsAt).TotalSeconds -lt 20) { return }
    }
    if ($job) { $c.SkillsJobSeen = [string]$job.at }
    $c.Skills = @(Get-SkillList)
    $c.Mcp = @(Get-McpList)
    $c.Packs = @(Get-SkillPackState)
    if ($null -eq $c.Catalog) { $c.Catalog = @(Get-CatalogItems (Join-Path $TrayRoot 'catalog')) }
    $c.CatalogSettings = Get-CatalogSettings
    $c.CatalogTargets = Get-CatalogTargets
    $c.CatalogApplied = Get-CatalogApplied
    $c.SkillOff = Get-CatalogSkillOff
    $c.SkillsAt = Get-Date
    Update-HubSkillRows
    try { Sync-HubSkillLists } catch { }
    # A switch flipped while the MCP job was running is picked up by one more run.
    if ($jobEnded -and $job.action -eq 'catalog-mcp' -and $job.state -eq 'done' -and
        @(Get-CatalogMcpPlan $c.CatalogSettings $c.CatalogTargets $c.CatalogApplied $c.Catalog).Count) { Start-MaxxJob 'catalog-mcp' }
}

# ---------------------------------------------------------------- one list: yours and the catalog's

$script:SkillSources = [ordered]@{ all = 'Todas'; on = (Ux 'Activadas aqu\u00ed'); installed = 'Instaladas'; anthropic = 'Anthropic'
    superpowers = 'Superpowers'; wshobson = 'wshobson/agents'; ecc = 'ECC' }
$script:McpSources = [ordered]@{ all = 'Todos'; on = (Ux 'Activados aqu\u00ed'); installed = 'Instalados'; mcp = (Ux 'Cat\u00e1logo') }
$script:SkillsPageRows = 5

# The rows of both tabs, yours first: Kind, Key (the name catalog.json, skillOverrides and deniedMcpServers take),
# Label, Sub, Group (the Fuente it falls under), Catalog (switched through catalog.json in Siempre too), Fixed (a
# server of one project: no switch) and NoGlobal (a plugin's server: no switch in Siempre, it goes with its plugin).
function Update-HubSkillRows {
    $c = $script:Hub.Cache
    $dot = Tx '  \u00b7  '
    $rows = @{ skill = (New-Object System.Collections.Generic.List[object]); mcp = (New-Object System.Collections.Generic.List[object]) }
    foreach ($s in @($c.Skills | Where-Object { $_ -and -not $_.Catalog })) {
        $rows.skill.Add([pscustomobject]@{ Kind = 'skill'; Key = [string]$s.Key; Label = $s.Name; Sub = (L $s.Source) + $dot + $s.Description
            Group = 'installed'; Catalog = $false; Fixed = $false; NoGlobal = $false })
    }
    # A server ClaudeMaxxing added for you (from the catalog or the stash) is shown once, as the catalog's.
    $added = @($(if ($c.CatalogApplied) { $c.CatalogApplied[$CatalogEverywhere] }))
    foreach ($m in @($c.Mcp | Where-Object { $_ -and -not ($_.Source -eq 'tuyos' -and $added -contains $_.Name) })) {
        $plugin = ([string]$m.Key).StartsWith('plugin:')
        $rows.mcp.Add([pscustomobject]@{ Kind = 'mcp'; Key = [string]$m.Key; Label = $m.Name
            Sub = (L $m.Source) + $dot + $m.Kind + $(if ($m.Target) { $dot + $m.Target } else { '' })
            Group = 'installed'; Catalog = $false; Fixed = (-not $plugin -and $m.Source -ne 'tuyos'); NoGlobal = $plugin })
    }
    foreach ($item in @($c.Catalog | Where-Object { $_ })) {
        $label = $item.Label
        if ($item.Auth -eq 'oauth') { $label += $dot + (Tx 'inicia sesi\u00f3n con /mcp') }
        $sub = if ($item.Source -eq 'tuyos') { Tx 'tuyo, guardado por ClaudeMaxxing al apagarlo en Siempre' } elseif ($item.Kind -eq 'mcp') { L $item.Description } else { $item.Description }
        $rows[$item.Kind].Add([pscustomobject]@{ Kind = $item.Kind; Key = $item.Name; Label = $label; Sub = $sub
            Group = $(if ($item.Source -eq 'tuyos') { 'installed' } else { $item.Source }); Catalog = $true; Fixed = $false; NoGlobal = $false })
    }
    $c.SkillRows = @{ skill = $rows.skill.ToArray(); mcp = $rows.mcp.ToArray() }
}

# On in Siempre ("*") or in an Ambiente. One with its own list has exactly that list; one without it, what Siempre
# has plus what was switched on only there.
function Test-HubSkillOn($Row, [string]$Scope, $Settings = $script:Hub.Cache.CatalogSettings) {
    $targets = @($Settings[(Get-CatalogKey $Row.Kind)][$Row.Key])
    if ($Scope -ne $CatalogEverywhere) {
        if (@($Settings.limited) -contains $Scope) { return ($targets -contains $Scope) }
        if ($targets -contains $Scope) { return $true }
    }
    if ($Row.Catalog) { return ($targets -contains $CatalogEverywhere) }
    if ($Row.Kind -eq 'skill') { return (@($script:Hub.Cache.SkillOff) -notcontains $Row.Key) }
    $true
}

function Get-HubSkillView {
    $hub = $script:Hub
    $kind = if ($hub.SkillsTab -eq 'mcp') { 'mcp' } else { 'skill' }
    $source = [string]$hub.SkillsSource
    $query = [WildcardPattern]::Escape([string]$hub.SkillsQuery)
    @(@($hub.Cache.SkillRows[$kind]) | Where-Object {
        ($source -in '', 'all' -or $_.Group -eq $source -or ($source -eq 'on' -and (Test-HubSkillOn $_ $hub.CatalogScope))) -and
        (-not $query -or $_.Label -like "*$query*" -or $_.Key -like "*$query*" -or $_.Sub -like "*$query*")
    })
}

# Everything Claude Code loads in every folder, for the Ambientes' lists in theirs.
function Sync-HubSkillLists {
    $c = $script:Hub.Cache
    $settings = $c.CatalogSettings
    [string[]]$skillKeys = @(@($c.Skills | Where-Object { $_ -and -not $_.Catalog } | ForEach-Object { $_.Key }) +
        @($settings.skills.Keys | Where-Object { @($settings.skills[$_]) -contains $CatalogEverywhere }) | Select-Object -Unique)
    [string[]]$mcpKeys = @($c.Mcp | Where-Object { $_ -and ($_.Source -eq 'tuyos' -or ([string]$_.Key).StartsWith('plugin:')) } | ForEach-Object { $_.Key } | Select-Object -Unique)
    Sync-CatalogOverrides $settings $c.CatalogTargets $skillKeys $mcpKeys
}

function Get-HubCatalogScopes {
    $scopes = [ordered]@{}
    foreach ($target in @($script:Hub.Cache.CatalogTargets.Values)) { $scopes[$target.Id] = $(if ($target.Id -eq $CatalogEverywhere) { 'Siempre' } else { $target.Name }) }
    $scopes
}

function Step-HubSkillsOption([string]$Field, $Options, [int]$Delta) {
    $keys = @($Options.Keys)
    $i = [array]::IndexOf($keys, [string]$script:Hub[$Field])
    $script:Hub[$Field] = $keys[[Math]::Max(0, [Math]::Min($keys.Count - 1, $i + $Delta))]
    $script:Hub.SkillsPage = 0
    $script:HubDialog.Invalidate()
}

function Get-HubSkillSources { if ($script:Hub.SkillsTab -eq 'mcp') { $script:McpSources } else { $script:SkillSources } }
function Step-HubSkillsSource([int]$Delta) { Step-HubSkillsOption 'SkillsSource' (Get-HubSkillSources) $Delta }
function Step-HubCatalogScope([int]$Delta) { Step-HubSkillsOption 'CatalogScope' (Get-HubCatalogScopes) $Delta }

# Typing while the section is open goes to its search box: Backspace, Esc empties it, Ctrl+V pastes.
function Send-HubSkillsKey([char]$Char) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Section -ne 'skills') { return $false }
    $query = [string]$hub.SkillsQuery
    $code = [int]$Char
    if ($code -eq 8) { if ($query) { $query = $query.Substring(0, $query.Length - 1) } }
    elseif ($code -eq 27 -or $code -eq 127) { $query = '' }
    elseif ($code -eq 22) { $query += ([System.Windows.Forms.Clipboard]::GetText() -replace '\s+', ' ') }
    elseif ($code -lt 32) { return $false }
    else { $query += $Char }
    $hub.SkillsQuery = $(if ($query.Length -gt 60) { $query.Substring(0, 60) } else { $query })
    $hub.SkillsPage = 0
    $script:HubDialog.Invalidate()
    $true
}

# One switch, in the scope picked. In Siempre: a catalog item through catalog.json, a skill of yours through
# skillOverrides, a server of yours into the stash. In an Ambiente: its list (made on its first change).
function Switch-HubSkillItem([string]$Kind, [string]$Key) {
    $hub = $script:Hub
    if ($hub.Preview) { return }
    $c = $hub.Cache
    $row = @(@($c.SkillRows[$Kind]) | Where-Object { $_.Key -eq $Key })[0]
    if (-not $row) { return }
    $job = $c.MaxxStatus
    $running = $job -and $job.state -eq 'running'
    $scope = $hub.CatalogScope
    $global = $scope -eq $CatalogEverywhere
    $stash = $global -and $Kind -eq 'mcp' -and -not $row.Catalog
    if ($Kind -eq 'mcp' -and $running -and ($stash -or $job.action -ne 'catalog-mcp')) { Set-HubMessage (Tx 'Espera: hay otra instalaci\u00f3n en curso.'); return }
    $settings = Get-CatalogSettings
    $c.CatalogSettings = $settings
    $on = -not (Test-HubSkillOn $row $scope $settings)
    try {
        if (-not $global -and @($settings.limited) -notcontains $scope) {
            # The first change gives the Ambiente its own list: what it had until now.
            foreach ($r in @($c.SkillRows['skill']) + @($c.SkillRows['mcp'])) {
                if (-not $r.Fixed -and (Test-HubSkillOn $r $scope $settings)) { Set-CatalogItem $settings $r.Kind $r.Key $scope $true }
            }
            $settings.limited = [string[]](@($settings.limited) + $scope)
        }
        if ($global -and $Kind -eq 'skill' -and -not $row.Catalog) { Set-CatalogSkillOff $Key (-not $on) }
        elseif ($stash) { Save-CatalogStash $Key }
        else { Set-CatalogItem $settings $Kind $Key $scope $on }
        Save-CatalogSettings $settings
    } catch { Set-HubMessage ((L 'No se pudo guardar: ') + $_.Exception.Message) -Failed; return }
    $conflict = $false
    if ($Kind -eq 'skill' -and $row.Catalog) {
        try { $conflict = @(Sync-CatalogSkills $settings $c.CatalogTargets (Join-Path $TrayRoot 'catalog')) -contains $Key }
        catch { Set-HubMessage ((L 'No se pudo copiar la skill: ') + $_.Exception.Message) -Failed; return }
    }
    if ($stash) { $c.Catalog = $null }
    Update-HubSkills -Force
    if ($Kind -eq 'mcp' -and -not $running) { Start-MaxxJob 'catalog-mcp' }
    $where = L ((Get-HubCatalogScopes)[$scope])
    if ($conflict) { Set-HubMessage ((Tx 'Ya tienes una skill {0} propia: no se toc\u00f3.') -f $Key) -Failed }
    elseif ($on) { Set-HubMessage ((L '{0} activado en {1}: se usa en las sesiones nuevas.') -f $Key, $where) }
    else { Set-HubMessage ((L '{0} apagado en {1}.') -f $Key, $where) }
    Update-HubNow
}

# Ambientes > Skills y MCP: a card per Ambiente with a folder, with what its sessions load there.
function Draw-HubEnvLists($G, $Map, $Hover, [int]$X0, [int]$Inner, [int]$OffsetY = 0) {
    $P = $script:Palette
    $F = $script:Fonts
    $c = $script:Hub.Cache
    if ($null -eq $c.SkillRows) { try { Update-HubSkills -Force } catch { } }
    if ($null -eq $c.SkillRows) { return }
    $dot = Tx ' \u00b7 '
    $y = (Px 72) + $OffsetY
    Draw-HubCaption $G 'CADA AMBIENTE CON SU LISTA' $X0 $y $Inner (Tx 'lo dem\u00e1s se apaga en su carpeta')
    $y += Px 28
    $settings = $c.CatalogSettings
    $targets = @($c.CatalogTargets.Values | Where-Object { $_.Dir })
    if (-not $targets.Count) {
        $card = New-Rect $X0 $y $Inner (Px 64)
        Draw-HubCard $G $card
        Draw-Wrapped $G (Tx 'Ning\u00fan ambiente tiene carpeta (claude.dir o folder en su JSON): la lista se aplica en la carpeta del ambiente.') $F.Small $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 14)) ($card.Width - (Px 32)) (Px 36)
        return
    }
    # What Siempre gives, read once for every Ambiente without a list.
    $always = @{}
    foreach ($kind in 'skill', 'mcp') { $always[$kind] = @(@($c.SkillRows[$kind]) | Where-Object { -not $_.Fixed -and (Test-HubSkillOn $_ $CatalogEverywhere) } | ForEach-Object { $_.Key }) }
    # shortcut: up to 7 cards (the window's height); page them if anyone has more Ambientes with a folder.
    foreach ($t in @($targets | Select-Object -First 7)) {
        $card = New-Rect $X0 $y $Inner (Px 62)
        Draw-HubCard $G $card
        $limited = @($settings.limited) -contains $t.Id
        $names = @{}
        foreach ($kind in 'skill', 'mcp') {
            $byKey = $settings[(Get-CatalogKey $kind)]
            $mine = @($byKey.Keys | Where-Object { @($byKey[$_]) -contains $t.Id })
            $names[$kind] = @(@(if ($limited) { $mine } else { @($always[$kind]) + $mine | Select-Object -Unique }) | Sort-Object)
        }
        $bw = Get-PillWidth 'Editar lista'
        Draw-PillButton $G $Map $Hover "envlist-$($t.Id)" (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 18)) $bw (Px 26)) 'Editar lista' ([scriptblock]::Create("Edit-HubEnvList '$($t.Id)'"))
        $tw = $card.Width - $bw - (Px 48)
        $count = (L '{0} skills, {1} MCP') -f $names.skill.Count, $names.mcp.Count
        Draw-Text $G ($t.Name + $dot + $count) $F.BodyStrong $P.Text ($card.X + (Px 16)) ($card.Y + (Px 10)) $tw (Px 22)
        # The servers first: they cost the most tokens.
        $list = (@($names.mcp) + @($names.skill) | ForEach-Object { ($_ -split ':')[-1] }) -join ', '
        $sub = if ($limited) { $(if ($list) { $list } else { Tx 'Nada: sus sesiones no cargan skills ni MCP.' }) } else { (Tx 'Sin lista propia: usa lo de Siempre. ') + $list }
        Draw-Text $G $sub $F.Small $(if ($limited) { $P.Muted } else { $P.Faint }) ($card.X + (Px 16)) ($card.Y + (Px 34)) $tw (Px 18)
        $y += Px 68
    }
}

function Edit-HubEnvList([string]$Id) {
    $hub = $script:Hub
    $hub.CatalogScope = $Id
    $hub.SkillsSource = 'on'
    $hub.SkillsQuery = ''
    $hub.SkillsPage = 0
    Set-HubSection 'skills'
}

function Install-HubSkillPack([string]$Id) {
    if ($script:Hub.Preview) { return }
    $job = $script:Hub.Cache.MaxxStatus
    if ($job -and $job.state -eq 'running') { Set-HubMessage (Tx 'Espera: hay otra instalaci\u00f3n en curso.'); return }
    $pack = @($script:SkillPacks | Where-Object { $_.Id -eq $Id })[0]
    Start-MaxxJob 'pack-install' -Plugin $pack.Plugin
    Set-HubMessage ((L 'Instalando ') + $pack.Id + '...')
    Update-HubNow
}

# A Claude Code session that starts by using the package: a skill in ~/.claude/skills, an MCP server or a
# plugin in the folder picked.
function New-HubCreation([string]$Kind) {
    if ($script:Hub.Preview) { return }
    if ($Kind -eq 'skill') {
        $dir = Join-Path $env:USERPROFILE '.claude\skills'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    } else {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = if ($Kind -eq 'mcp') { 'Carpeta del servidor MCP nuevo' } else { 'Carpeta del plugin nuevo' }
        if ($picker.ShowDialog($script:HubDialog) -ne 'OK' -or -not $picker.SelectedPath) { return }
        $dir = $picker.SelectedPath
    }
    $prompt = switch ($Kind) {
        'skill' { Tx 'Usa la skill skill-creator para crear una skill nueva en esta carpeta. Primero preg\u00fantame qu\u00e9 quiero que haga.' }
        'mcp' { Tx 'Usa las skills de mcp-server-dev para crear un servidor MCP nuevo en esta carpeta. Primero preg\u00fantame qu\u00e9 debe hacer y c\u00f3mo se va a usar.' }
        default { Tx 'Usa las skills de plugin-dev para crear un plugin de Claude Code nuevo en esta carpeta. Primero preg\u00fantame qu\u00e9 debe hacer.' }
    }
    Start-ClaudeCodeSession $dir $prompt
    Set-HubMessage ((L 'Abriendo Claude Code en ') + (Split-Path -Leaf $dir) + '...')
}

function Set-HubSkillsTab([string]$Tab) {
    $script:Hub.SkillsTab = $Tab
    $script:Hub.SkillsPage = 0
    $script:HubDialog.Invalidate()
}

function Move-HubSkillsPage([int]$Delta, [int]$Pages) {
    $script:Hub.SkillsPage = [Math]::Max(0, [Math]::Min($Pages - 1, [int]$script:Hub.SkillsPage + $Delta))
    $script:HubDialog.Invalidate()
}

function Draw-HubSkillsSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $hub = $script:Hub
    $c = $hub.Cache
    if ($null -eq $c.Skills) { try { Update-HubSkills -Force } catch { } }
    if (-not $hub.SkillsTab) { $hub.SkillsTab = 'skills' }
    $job = $c.MaxxStatus
    $busy = $job -and $job.state -eq 'running'
    $dot = (Tx '  \u00b7  ')

    # the creation packages
    Draw-HubCaption $G 'PAQUETES PARA CREAR' $X0 (Px 66) $Inner 'plugins oficiales de Anthropic'
    $y = Px 88
    foreach ($pack in $script:SkillPacks) {
        $row = New-Rect $X0 $y $Inner (Px 46)
        Draw-HubCard $G $row
        $state = @($c.Packs | Where-Object { $_.Id -eq $pack.Id })[0]
        $failed = $job -and $job.state -eq 'error' -and $job.plugin -eq $pack.Plugin
        $right = $row.Right - (Px 12)
        $by = $row.Y + (Px 10)
        $sub = Tx $pack.Text
        if ($state -and $state.Installed) {
            $bw = Get-PillWidth $pack.Button
            Draw-PillButton $G $Map $Hover "pack-new-$($pack.Id)" (New-Rect ($right - $bw) $by $bw (Px 26)) $pack.Button ([scriptblock]::Create("New-HubCreation '$($pack.Kind)'")) -Accent
            $right -= $bw + (Px 10)
            $sub = (Tx '\u2713 Instalado. ') + $sub
        } elseif ($busy -and $job.plugin -eq $pack.Plugin) {
            Draw-Text $G (Tx 'Instalando\u2026') $F.Small $P.Accent ($right - (Px 110)) $row.Y (Px 110) $row.Height 'Right'
            $right -= Px 120
        } elseif (-not $busy) {
            $label = if ($failed) { 'Reintentar' } else { 'Instalar' }
            $bw = Get-PillWidth $label
            Draw-PillButton $G $Map $Hover "pack-install-$($pack.Id)" (New-Rect ($right - $bw) $by $bw (Px 26)) $label ([scriptblock]::Create("Install-HubSkillPack '$($pack.Id)'")) -Accent
            $right -= $bw + (Px 10)
            if ($failed) { $sub = [string]$job.message }
        }
        $tw = $right - $row.X - (Px 24)
        Draw-Text $G $pack.Label $F.BodyStrong $P.Text ($row.X + (Px 14)) ($row.Y + (Px 4)) $tw (Px 20)
        Draw-Text $G $sub $F.Small $(if ($failed) { $P.Error } else { $P.Muted }) ($row.X + (Px 14)) ($row.Y + (Px 24)) $tw (Px 18)
        $y += Px 52
    }

    # the lists: tabs, the search box and the pages; then the filters and a page of switches
    $y += Px 6
    if (-not $hub.SkillsTab -or $hub.SkillsTab -notin 'skills', 'mcp') { $hub.SkillsTab = 'skills' }
    if ($null -eq $c.SkillRows) { Update-HubSkillRows }
    $sources = Get-HubSkillSources
    if (-not $hub.SkillsSource -or -not $sources.Contains([string]$hub.SkillsSource)) { $hub.SkillsSource = 'all' }
    $scopes = Get-HubCatalogScopes
    if (-not $hub.CatalogScope -or -not $scopes.Contains($hub.CatalogScope)) { $hub.CatalogScope = $CatalogEverywhere }
    $tabs = @(@{ Id = 'skills'; Label = "Skills ($(@($c.SkillRows.skill).Count))" }, @{ Id = 'mcp'; Label = "MCP ($(@($c.SkillRows.mcp).Count))" })
    $x = $X0
    foreach ($tab in $tabs) {
        $active = $hub.SkillsTab -eq $tab.Id
        $font = if ($active) { $F.BodyStrong } else { $F.Body }
        $rect = New-Rect $x $y ((Measure-TextWidth $tab.Label $font) + (Px 20)) (Px 28)
        $hitId = "sktab-$($tab.Id)"
        if ($active) { Fill-Round $G $rect (Px 14) $P.AccentTint } elseif ($Hover -eq $hitId) { Fill-Round $G $rect (Px 14) $P.SurfaceHover }
        Draw-Text $G $tab.Label $font $(if ($active) { $P.Accent } else { $P.Text }) $rect.X $rect.Y $rect.Width $rect.Height 'Center'
        if (-not $active) { Add-Hit $Map $hitId $rect ([scriptblock]::Create("Set-HubSkillsTab '$($tab.Id)'")) }
        $x += $rect.Width + (Px 4)
    }
    $rows = Get-HubSkillView
    $pages = [Math]::Max(1, [int][Math]::Ceiling($rows.Count / $script:SkillsPageRows))
    $page = [Math]::Min([int]$hub.SkillsPage, $pages - 1)
    $right = $X0 + $Inner
    if ($pages -gt 1) {
        $next = New-Rect ($right - (Px 28)) ($y + (Px 2)) (Px 28) (Px 24)
        Draw-PillButton $G $Map $Hover 'skpage-next' $next (Tx '\u203a') ([scriptblock]::Create("Move-HubSkillsPage 1 $pages"))
        Draw-Text $G ('{0} / {1}' -f ($page + 1), $pages) $F.Small $P.Muted ($next.X - (Px 64)) $y (Px 58) (Px 28) 'Center'
        $prev = New-Rect ($next.X - (Px 96)) ($y + (Px 2)) (Px 28) (Px 24)
        Draw-PillButton $G $Map $Hover 'skpage-prev' $prev (Tx '\u2039') ([scriptblock]::Create("Move-HubSkillsPage -1 $pages"))
        $right = $prev.X - (Px 10)
    }
    # The search box: whatever is typed while the section is open lands here.
    $box = New-Rect ($x + (Px 8)) $y ($right - $x - (Px 8)) (Px 28)
    $query = [string]$hub.SkillsQuery
    Fill-Round $G $box (Px 7) $P.Back
    Stroke-Round $G $box (Px 7) $(if ($query) { $P.Accent } else { $P.Border })
    if ($query) {
        Draw-Text $G ($query + '|') $F.Body $P.Text ($box.X + (Px 10)) $box.Y ($box.Width - (Px 40)) $box.Height
        $clear = New-Rect ($box.Right - (Px 28)) $box.Y (Px 28) $box.Height
        Draw-Text $G (Tx '\u00d7') $F.Body $(if ($Hover -eq 'sk-search-clear') { $P.Text } else { $P.Muted }) $clear.X $clear.Y $clear.Width $clear.Height 'Center'
        Add-Hit $Map 'sk-search-clear' $clear { $script:Hub.SkillsQuery = ''; $script:Hub.SkillsPage = 0; $script:HubDialog.Invalidate() }
    } else {
        Draw-Text $G (Tx 'Escribe para buscar skills o MCP\u2026') $F.Body $P.Faint ($box.X + (Px 10)) $box.Y ($box.Width - (Px 20)) $box.Height
    }
    $y += Px 38
    $half = [int]($Inner / 2)
    Draw-HubDropdown $G $Map $Hover 'sk-source' (New-Rect ($X0 - (Px 10)) $y ($half + (Px 4)) (Px 30)) 'Fuente' $sources $hub.SkillsSource 'Step-HubSkillsSource'
    Draw-HubDropdown $G $Map $Hover 'sk-scope' (New-Rect ($X0 + $half) $y $half (Px 30)) 'Activar en' $scopes $hub.CatalogScope 'Step-HubCatalogScope'
    $y += Px 38
    if (-not $rows.Count) {
        $empty = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $empty (Px 8) $P.Surface
        Draw-Text $G 'Nada con este filtro.' $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 44)
    }
    $global = $hub.CatalogScope -eq $CatalogEverywhere
    foreach ($item in @($rows | Select-Object -Skip ($page * $script:SkillsPageRows) -First $script:SkillsPageRows)) {
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 8) $P.Surface
        $on = Test-HubSkillOn $item $hub.CatalogScope
        $enabled = -not $item.Fixed -and -not ($global -and $item.NoGlobal)
        $sub = $item.Sub
        if ($item.Fixed) { $sub = (Tx 'solo en su proyecto  \u00b7  ') + $sub } elseif (-not $enabled) { $sub = (Tx 'va con su plugin; ap\u00e1galo en un ambiente  \u00b7  ') + $sub }
        $key = $item.Key -replace "'", "''"
        Draw-HubToggleRow $G $Map $Hover "sk-$($item.Kind)-$($item.Key)" $row $item.Label $sub $on ([scriptblock]::Create("Switch-HubSkillItem '$($item.Kind)' '$key'")) $enabled
        $y += Px 48
    }
    $note = if ($global) { Tx 'Siempre: en todas tus sesiones. Un ambiente con su lista: solo esa en su carpeta, lo dem\u00e1s se apaga. Se aplica en las sesiones nuevas.' }
        elseif (@($c.CatalogSettings.limited) -contains $hub.CatalogScope) { Tx 'Este ambiente tiene su lista: en su carpeta solo carga lo activado aqu\u00ed. Los MCP gastan m\u00e1s tokens que las skills.' }
        else { Tx 'Este ambiente a\u00fan usa lo de Siempre: el primer cambio le da su propia lista, y lo que no est\u00e9 en ella se apaga en su carpeta.' }
    $noteW = $Inner
    if ($hub.SkillsTab -eq 'skills') {
        $bw = Get-PillWidth 'Abrir carpeta'
        Draw-PillButton $G $Map $Hover 'skills-folder' (New-Rect ($X0 + $Inner - $bw) (Px 602) $bw (Px 24)) 'Abrir carpeta' {
            $dir = Join-Path $env:USERPROFILE '.claude\skills'
            if (Test-Path -LiteralPath $dir) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"') }
        }
        $noteW -= $bw + (Px 12)
    }
    Draw-Wrapped $G $note $F.Small $P.Faint $X0 (Px 598) $noteW (Px 34)
}
