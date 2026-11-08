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
    'plugin ' + $Plugin.Name + $(if ($Plugin.Project) { ' (' + $Plugin.Project + ')' } else { '' })
}

# Each row once, by name and source (a plugin installed for several projects, a skill synced twice).
function Select-UniqueRows($Rows) {
    $seen = @{}
    @($Rows | Where-Object { $_ } | Where-Object { $key = $_.Name + '|' + $_.Source; if ($seen.ContainsKey($key)) { $false } else { $seen[$key] = $true; $true } })
}

# Every skill: yours (~/.claude/skills), the plugins', and claude.ai's synced ones; yours first.
function Get-SkillList([string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')) {
    $skills = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Dir, [string]$Source)
        $file = Join-Path $Dir 'SKILL.md'
        if (-not (Test-Path -LiteralPath $file)) { return }
        $head = Read-SkillHeader $file
        $skills.Add([pscustomobject]@{ Name = $(if ($head.Name) { $head.Name } else { Split-Path -Leaf $Dir }); Description = $head.Description; Source = $Source; Path = $Dir })
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
        foreach ($skill in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) { & $add $skill.FullName (Format-PluginSource $plugin) }
    }
    $order = @{ Expression = { if ($_.Source -eq 'tuyas') { 0 } elseif ($_.Source -like 'plugin *') { 1 } else { 2 } } }
    @(Select-UniqueRows ($skills | Sort-Object $order, Source, Name))
}

# The rows of an "mcpServers" object: name, kind (stdio, http, sse) and what it runs or reaches.
function Get-McpServerRows($Servers, [string]$Source) {
    if (-not $Servers -or $Servers -is [string]) { return @() }
    foreach ($prop in $Servers.PSObject.Properties) {
        $server = $prop.Value
        if ($server -isnot [pscustomobject]) { continue }
        $kind = if ($server.type) { [string]$server.type } elseif ($server.url) { 'http' } else { 'stdio' }
        $target = if ($server.url) { try { ([uri][string]$server.url).Host } catch { [string]$server.url } }
            elseif ($server.command) { [IO.Path]::GetFileName([string]$server.command) } else { '' }
        [pscustomobject]@{ Name = $prop.Name; Kind = $kind; Target = $target; Source = $Source }
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
            foreach ($project in $config.projects.PSObject.Properties) { $rows += @(Get-McpServerRows $project.Value.mcpServers ('proyecto ' + (Split-Path -Leaf $project.Name))) }
        }
    }
    foreach ($plugin in @(Get-ClaudePlugins $ClaudeHome)) {
        $source = Format-PluginSource $plugin
        $file = Read-JsonFile (Join-Path $plugin.Path '.mcp.json')
        if ($file) { $rows += @(Get-McpServerRows $(if ($file.mcpServers) { $file.mcpServers } else { $file }) $source) }
        $manifest = Read-JsonFile (Join-Path $plugin.Path '.claude-plugin\plugin.json')
        if ($manifest) { $rows += @(Get-McpServerRows $manifest.mcpServers $source) }
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

# Read again while the section is open: every 20 s, and as soon as a package install ends.
function Update-HubSkills([switch]$Force) {
    $hub = $script:Hub
    if (-not $hub -or $hub.Preview) { return }
    $c = $hub.Cache
    $job = $c.MaxxStatus
    $jobEnded = $job -and $job.action -eq 'pack-install' -and $job.state -ne 'running' -and [string]$job.at -ne [string]$c.SkillsJobSeen
    if (-not $Force -and -not $jobEnded) {
        if ($hub.Section -ne 'skills') { return }
        if ($c.SkillsAt -and ((Get-Date) - $c.SkillsAt).TotalSeconds -lt 20) { return }
    }
    if ($job) { $c.SkillsJobSeen = [string]$job.at }
    $c.Skills = @(Get-SkillList)
    $c.Mcp = @(Get-McpList)
    $c.Packs = @(Get-SkillPackState)
    $c.SkillsAt = Get-Date
}

function Install-HubSkillPack([string]$Id) {
    if ($script:Hub.Preview) { return }
    $job = $script:Hub.Cache.MaxxStatus
    if ($job -and $job.state -eq 'running') { Set-HubMessage (Tx 'Espera: hay otra instalaci\u00f3n en curso.'); return }
    $pack = @($script:SkillPacks | Where-Object { $_.Id -eq $Id })[0]
    Start-MaxxJob 'pack-install' -Plugin $pack.Plugin
    Set-HubMessage ('Instalando ' + $pack.Id + '...')
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
    # A trailing backslash ("C:\") would escape the closing quote.
    if ($dir.EndsWith('\')) { $dir += '.' }
    $launch = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Dir "{1}" -Prompt "{2}"' -f (Join-Path $TrayRoot 'open-session.ps1'), $dir, $prompt
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $launch -WorkingDirectory $TrayRoot
    Set-HubMessage ('Abriendo Claude Code en ' + (Split-Path -Leaf $dir.TrimEnd('.', '\')) + '...')
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
    $dot = '  ' + (Tx '\u00b7') + '  '

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

    # the lists: tabs, then a page of rows
    $y += Px 6
    $skills = @($c.Skills)
    $servers = @($c.Mcp)
    $tabs = @(@{ Id = 'skills'; Label = "Skills ($($skills.Count))" }, @{ Id = 'mcp'; Label = "Servidores MCP ($($servers.Count))" })
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
    $rows = if ($hub.SkillsTab -eq 'mcp') { $servers } else { $skills }
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
    if ($hub.SkillsTab -eq 'skills') {
        $bw = Get-PillWidth 'Abrir carpeta'
        Draw-PillButton $G $Map $Hover 'skills-folder' (New-Rect ($right - $bw) ($y + (Px 2)) $bw (Px 24)) 'Abrir carpeta' {
            $dir = Join-Path $env:USERPROFILE '.claude\skills'
            if (Test-Path -LiteralPath $dir) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"') }
        }
    }
    $y += Px 38
    if (-not $rows.Count) {
        $empty = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $empty (Px 8) $P.Surface
        $text = if ($hub.SkillsTab -eq 'mcp') { 'Ning\u00fan servidor MCP configurado.' } else { 'Ninguna skill instalada.' }
        Draw-Text $G (Tx $text) $F.Body $P.Muted ($X0 + (Px 14)) $y ($Inner - (Px 28)) (Px 44)
    }
    foreach ($item in @($rows | Select-Object -Skip ($page * $script:SkillsPageRows) -First $script:SkillsPageRows)) {
        $row = New-Rect $X0 $y $Inner (Px 44)
        Fill-Round $G $row (Px 8) $P.Surface
        $sourceW = [Math]::Min([int]($Inner * 0.35), (Measure-TextWidth $item.Source $F.Small) + (Px 4))
        $tx = $row.X + (Px 14)
        $tw = $row.Right - (Px 14) - $tx
        Draw-Text $G $item.Name $F.BodyStrong $P.Text $tx ($row.Y + (Px 4)) ($tw - $sourceW - (Px 10)) (Px 20)
        Draw-Text $G $item.Source $F.Small $P.Faint ($row.Right - (Px 14) - $sourceW) ($row.Y + (Px 4)) $sourceW (Px 20) 'Right'
        $detail = if ($hub.SkillsTab -eq 'mcp') { $item.Kind + $(if ($item.Target) { $dot + $item.Target } else { '' }) } else { $item.Description }
        Draw-Text $G $detail $F.Small $P.Muted $tx ($row.Y + (Px 23)) $tw (Px 18)
        $y += Px 48
    }
    Draw-Wrapped $G (Tx 'Se leen de tu PC, sin arrancar nada. Las de un proyecto solo cargan en ese proyecto; los conectores de claude.ai no salen aqu\u00ed.') $F.Small $P.Faint $X0 (Px 598) $Inner (Px 34)
}
