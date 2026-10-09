# Instala ClaudeVoice para todas las sesiones de Claude Code:
#   - hooks Stop y UserPromptSubmit en ~/.claude/settings.json
#   - regla del resumen hablado en ~/.claude/CLAUDE.md (entre marcadores claudevoice)
#   - comando /voz en ~/.claude/skills/voz/SKILL.md
# Hace copia de seguridad de settings.json y CLAUDE.md y es idempotente.
#   .\install.ps1              instala o actualiza
#   .\install.ps1 -Uninstall   quita hooks, regla y /voz
#   .\install.ps1 -SkipClaudeMd  sin la regla (se pone a mano o por proyecto)
# Siempre regenera tambien .claude/skills/voz/SKILL.md de esta carpeta con la ruta actual.
param(
    [switch]$Uninstall,
    [switch]$SkipClaudeMd,
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$ClaudeMdPath = (Join-Path $env:USERPROFILE '.claude\CLAUDE.md'),
    [string]$SkillsDir    = (Join-Path $env:USERPROFILE '.claude\skills')
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\hooks\common.ps1"

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$begin  = '<!-- claudevoice:start -->'
$end    = '<!-- claudevoice:end -->'
# Stop es async (no bloquea a Claude); UserPromptSubmit es sincrono porque devuelve el
# titulo de la sesion (la salida de un hook async se ignora).
$events = @{ Stop = 'speak.ps1'; UserPromptSubmit = 'on-prompt.ps1' }

function Backup([string]$Path) {
    if (Test-Path $Path) {
        Copy-Item $Path "$Path.bak-$stamp"
        "Copia de seguridad: $Path.bak-$stamp"
    }
}

function New-HookEntry([string]$Script) {
    $path = (Join-Path $PSScriptRoot "hooks\$Script").Replace('\', '/')
    [pscustomobject]@{
        hooks = @($(if ($Script -eq 'speak.ps1') {
            [pscustomobject]@{ type = 'command'; async = $true; command = 'powershell.exe'
                               args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) }
        } else {
            [pscustomobject]@{ type = 'command'; timeout = 10; command = 'powershell.exe'
                               args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) }
        }))
    }
}

function Test-OurEntry($Entry) {
    foreach ($h in @($Entry.hooks)) {
        if ((("$($h.command) " + (@($h.args) -join ' ')) -match 'ClaudeVoice')) { return $true }
    }
    return $false
}

# --- settings.json ---
New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath), (Split-Path $ClaudeMdPath) | Out-Null
Backup $SettingsPath
$settings = if (Test-Path $SettingsPath) { [IO.File]::ReadAllText($SettingsPath, $Utf8) | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member hooks ([pscustomobject]@{}) }

foreach ($event in $events.Keys) {
    $kept = @()
    if ($settings.hooks.PSObject.Properties[$event]) {
        $kept = @($settings.hooks.$event | Where-Object { -not (Test-OurEntry $_) })
    }
    if (-not $Uninstall) { $kept += New-HookEntry $events[$event] }

    if ($kept.Count -gt 0) { $settings.hooks | Add-Member -Force $event $kept }
    else { $settings.hooks.PSObject.Properties.Remove($event) }
}
if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }

[IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 32), $Utf8)
"Hooks {0} en $SettingsPath" -f $(if ($Uninstall) { 'eliminados' } else { 'instalados' })

# --- CLAUDE.md ---
if (-not $SkipClaudeMd) {
    Backup $ClaudeMdPath
    $content = if (Test-Path $ClaudeMdPath) { [IO.File]::ReadAllText($ClaudeMdPath, $Utf8) } else { '' }
    $block = '(?s)\s*' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\s*'
    $content = [regex]::Replace($content, $block, "`n`n").TrimEnd()
    if (-not $Uninstall) {
        $rule = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\claude-md-rule.md'), $Utf8).Trim()
        $content = ($content + "`n`n$begin`n$rule`n$end").TrimStart()
    }
    [IO.File]::WriteAllText($ClaudeMdPath, $content + "`n", $Utf8)
    "Regla {0} en $ClaudeMdPath" -f $(if ($Uninstall) { 'eliminada' } else { 'instalada' })
}

# --- comando /voz ---
$ctl = (Join-Path $PSScriptRoot 'ctl.ps1').Replace('\', '/')
$skill = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\skill-voz.md'), $Utf8).Replace('{{CTL}}', $ctl)
function Write-Skill([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dir 'SKILL.md'), $skill, $Utf8)
}
Write-Skill (Join-Path $PSScriptRoot '.claude\skills\voz')
$globalSkill = Join-Path $SkillsDir 'voz'
if ($Uninstall) {
    if (Test-Path (Join-Path $globalSkill 'SKILL.md')) {
        if ((Get-Content (Join-Path $globalSkill 'SKILL.md') -Raw) -match 'ClaudeVoice') { Remove-Item $globalSkill -Recurse -Force; "Comando /voz eliminado de $SkillsDir" }
    }
} else {
    Write-Skill $globalSkill
    "Comando /voz instalado en $globalSkill"
}

if (-not $Uninstall) { 'Listo. Abre una sesion nueva de Claude Code (los hooks se leen al iniciar).' }
