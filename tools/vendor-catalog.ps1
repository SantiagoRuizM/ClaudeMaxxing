# Copies the third-party skills of the catalog (catalog\skills) from their repos, at the pinned commits below.
# Maintainer tool, not installed. Nothing downloaded is run: each repo is fetched with git into its own folder
# and only skill folders made of text (plus fonts, images and PDFs) are copied. A skill with any script,
# allowed-tools, hooks or a listed name stays out. At the end it lists lines that read like prompt injection,
# to check by hand before committing.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\vendor-catalog.ps1 [-CacheDir <folder>]
# Keep this file ASCII.
param([string]$CacheDir = (Join-Path $env:TEMP 'claudemaxxing-catalog-src'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out = Join-Path $repo 'catalog\skills'

# The order is the priority: a name already taken by an earlier source is skipped.
$sources = @(
    @{ Id = 'anthropic'; Repo = 'anthropics/skills'; Commit = 'e4bb5d960d87126ff3b3a8af1a104b7db67560ba'; License = 'Apache-2.0'
        Roots = @('skills'); Notices = @('THIRD_PARTY_NOTICES.md'); Exclude = @{} },
    @{ Id = 'superpowers'; Repo = 'obra/superpowers'; Commit = '22f0b463e7a5e579904dd6211a520321035526f7'; License = 'MIT'
        Roots = @('skills'); Notices = @('LICENSE')
        Exclude = @{ 'using-superpowers' = 'bootstrap of the superpowers plugin (its SessionStart hook)'; 'diagnosing-superpowers' = 'debugs the superpowers plugin install' } },
    @{ Id = 'wshobson'; Repo = 'wshobson/agents'; Commit = '42203085cfc5736204bf0f6d436dff7e1da0bf3f'; License = 'MIT'
        Roots = @('plugins\*\skills'); Notices = @('LICENSE')
        ExcludePlugins = @('protect-mcp', 'review-agent-governance', 'block-no-verify', 'hermes-tweet', 'social-publishing', 'signed-audit-trails')
        Exclude = @{} },
    @{ Id = 'ecc'; Repo = 'affaan-m/ECC'; Commit = '4adeee6732a12d1540f49a4d50a38ce8c97f9a53'; License = 'MIT'
        Roots = @('skills'); Notices = @('LICENSE'); Exclude = @{} }
)
$ecc = @{
    'needs the ECC plugin, its hooks or its tools' = 'configure-ecc ecc-guide ecc-recipes ecc-tools-cost-audit gateguard hookify-rules plan-canvas council devfleet dmux-workflows nanoclaw-repl orch-add-feature orch-build-mvp orch-change-feature orch-fix-defect orch-pipeline orch-refine-code plan-orchestrate skill-host-compat hermes-imports deepseek-harness-setup ralphinho-rfc-pipeline unified-memory agent-sort email-ops messages-ops terminal-ops plankton-code-quality team-builder token-card'
    'sponsor, payments or trading' = 'agent-payment-x402 roundhouse-x402 ito-inference ito-training nutrient-document-processing prediction-market-oracle-research prediction-market-risk-review'
    'acts on your accounts, outreach, scraping or OSINT' = 'social-publisher x-api crosspost short-video-distribution investor-outreach lead-intelligence connections-optimizer osint-investigation data-scraper-agent'
    'needs a paid third-party API' = 'exa-search fal-ai-media mailtrap-email-integration codehealth-mcp deep-research'
}
foreach ($reason in $ecc.Keys) { foreach ($name in $ecc[$reason].Split(' ')) { ($sources | Where-Object { $_.Id -eq 'ecc' }).Exclude[$name] = $reason } }
# Names Claude Code (or ClaudeMaxxing) already uses for a command or skill.
$taken = @('security-review', 'code-review', 'review', 'simplify', 'init', 'loop', 'schedule', 'batch', 'run', 'claude-api',
    'plugin-authoring', 'update-config', 'keybindings-help', 'fewer-permission-prompts', 'skill-creator', 'pdf-markdown', 'claude-whip', 'voz')
$inert = '.md', '.txt', '.ttf', '.otf', '.png', '.jpg', '.jpeg', '.gif', '.pdf', '.svg'

function Get-Source($Source) {
    $dir = Join-Path $CacheDir $Source.Id
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        $head = (& git -C $dir rev-parse HEAD).Trim()
        if ($head -eq $Source.Commit) { return $dir }
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # No hooks from the template run in a fetch; checkout runs none either with hooksPath empty.
    & git -C $dir init -q
    & git -C $dir -c core.hooksPath=NUL fetch -q --depth 1 ("https://github.com/" + $Source.Repo) $Source.Commit
    & git -C $dir -c core.hooksPath=NUL -c core.autocrlf=false checkout -q FETCH_HEAD
    if ($LASTEXITCODE) { throw "could not fetch $($Source.Repo)" }
    $dir
}

function Get-FrontMatter([string]$File) {
    $text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8)
    if ($text -match '(?s)^---\r?\n(.*?)\r?\n---') { $Matches[1] } else { '' }
}

if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$seen = @{}
$manifest = @()
foreach ($source in $sources) {
    $root = Get-Source $source
    $target = Join-Path $out $source.Id
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($notice in $source.Notices) { Copy-Item -LiteralPath (Join-Path $root $notice) -Destination $target }
    $kept = 0
    $skipped = [ordered]@{}
    foreach ($pattern in $source.Roots) {
        foreach ($skillsDir in @(Resolve-Path -Path (Join-Path $root $pattern) -ErrorAction SilentlyContinue)) {
            $plugin = Split-Path -Leaf (Split-Path -Parent $skillsDir.Path)
            foreach ($dir in @(Get-ChildItem -LiteralPath $skillsDir.Path -Directory)) {
                $skillFile = Join-Path $dir.FullName 'SKILL.md'
                if (-not (Test-Path -LiteralPath $skillFile)) { continue }
                $front = Get-FrontMatter $skillFile
                $name = if ($front -match '(?m)^name:\s*(.+)$') { $Matches[1].Trim().Trim('"', "'") } else { $dir.Name }
                $files = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force)
                $reason = $null
                if ($source.ExcludePlugins -and $source.ExcludePlugins -contains $plugin) { $reason = 'plugin ' + $plugin + ' ships hooks or posts for you' }
                elseif ($source.Exclude.ContainsKey($name)) { $reason = $source.Exclude[$name] }
                elseif ($taken -contains $name) { $reason = 'name taken by Claude Code or ClaudeMaxxing' }
                elseif ($seen.ContainsKey($name)) { $reason = 'also in ' + $seen[$name] }
                elseif ($name -notmatch '^[a-z0-9][a-z0-9-]*$' -or $name -ne $dir.Name) { $reason = 'name does not match its folder' }
                elseif ($front -notmatch '(?m)^description:') { $reason = 'no description' }
                elseif ($front -match '(?m)^(allowed-tools|hooks):') { $reason = 'grants tools or registers hooks' }
                else {
                    $code = @($files | Where-Object { $inert -notcontains $_.Extension.ToLowerInvariant() -and $_.Name -notmatch '^LICENSE' })
                    if ($code.Count) { $reason = 'ships scripts (' + (($code | ForEach-Object { $_.Name } | Select-Object -First 3) -join ', ') + ')' }
                }
                if ($reason) { $skipped[$name] = $reason; continue }
                Copy-Item -LiteralPath $dir.FullName -Destination (Join-Path $target $name) -Recurse
                $seen[$name] = $source.Id
                $kept++
            }
        }
    }
    $manifest += [ordered]@{ id = $source.Id; repo = $source.Repo; commit = $source.Commit; license = $source.License; skills = $kept; excluded = $skipped }
    Write-Host ('{0}: {1} skills, {2} left out' -f $source.Id, $kept, $skipped.Count)
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $repo 'catalog\sources.json'), (ConvertTo-Json @{ sources = $manifest } -Depth 5), $utf8)
# The window's list (lib\catalog.ps1) reads this index, not 400 SKILL.md files.
. (Join-Path $repo 'lib\common.ps1')
. (Join-Path $repo 'lib\hubskills.ps1')
$index = foreach ($name in @($seen.Keys | Sort-Object)) {
    $head = Read-SkillHeader (Join-Path $out ($seen[$name] + '\' + $name + '\SKILL.md'))
    $text = $head.Description
    if ($text.Length -gt 300) { $text = $text.Substring(0, 297) + '...' }
    [ordered]@{ name = $name; source = $seen[$name]; description = $text }
}
[IO.File]::WriteAllText((Join-Path $repo 'catalog\index.json'), (ConvertTo-Json @{ skills = @($index) } -Depth 4), $utf8)

# Lines to read by hand: they could be instructions aimed at Claude rather than at the task.
$suspect = 'ignore (all |any )?(previous|prior|above) (instructions|prompts)|disregard (the|your|all) |exfiltrat|curl [^\n]*\|\s*(ba)?sh|iwr [^\n]*\|\s*iex|[A-Za-z0-9+/]{200,}={0,2}|do not (tell|inform) the user|without (telling|asking) the user'
$hits = Get-ChildItem -LiteralPath $out -Recurse -File -Include *.md, *.txt | Select-String -Pattern $suspect
foreach ($hit in $hits) { Write-Host ('CHECK {0}:{1}: {2}' -f $hit.Path.Substring($out.Length + 1), $hit.LineNumber, $hit.Line.Trim().Substring(0, [Math]::Min(160, $hit.Line.Trim().Length))) }
Write-Host ('{0} lines to check by hand' -f @($hits).Count)
