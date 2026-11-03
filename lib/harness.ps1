# Ambientes: the work environments of YourHarness (a separate tool on this PC: env.js and environments\*.json)
# as one dot each in the ClaudeMaxxing window. Turning one on or off runs `node env.js <id> on|off --yes --job`
# hidden; its progress comes back through YourHarness's run\job.json and the environment that is on through
# run\active.json. Reading those files is cheap, so the hub timer can call Get-HarnessState every tick.
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

# Per PC: where YourHarness lives ({ "dir": "..." }). Chosen from the window; never a path in the repo.
$HarnessSettingsFile = Join-Path $TrayHome 'harness.json'

function Test-HarnessDir([string]$Dir) {
    $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'env.js')) -and (Test-Path -LiteralPath (Join-Path $Dir 'environments'))
}

function Get-HarnessDir {
    $saved = Read-JsonFile $HarnessSettingsFile
    if ($saved -and (Test-HarnessDir ([string]$saved.dir))) { return [string]$saved.dir }
    $null
}

function Set-HarnessDir([string]$Dir) {
    if (-not (Test-HarnessDir $Dir)) { return $false }
    Write-JsonFile $HarnessSettingsFile ([ordered]@{ dir = $Dir })
    $true
}

function Test-HarnessPidAlive($ProcessId) {
    if (-not $ProcessId) { return $false }
    [bool](Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
}

# Environments (id, name, focus), the one that is on and the last change. A job whose process died
# mid-way is reported as interrupted, so a dot never stays busy forever.
function Get-HarnessState([string]$Dir = (Get-HarnessDir)) {
    if (-not $Dir) { return @{ Dir = $null; Envs = @(); Active = $null; Job = $null } }
    $envs = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'environments') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $def = Read-JsonFile $file.FullName
        $envs += [pscustomobject]@{ Id = $file.BaseName.ToLowerInvariant(); Name = $(if ($def -and $def.name) { [string]$def.name } else { $file.BaseName }); Focus = $(if ($def) { [string]$def.focus } else { '' }) }
    }
    $run = Join-Path $Dir 'run'
    $active = Read-JsonFile (Join-Path $run 'active.json')
    $job = Read-JsonFile (Join-Path $run 'job.json')
    if ($job -and $job.state -eq 'running' -and -not (Test-HarnessPidAlive $job.pid)) {
        # Add-Member: the file may lack "message", and a missing property cannot be assigned.
        $job | Add-Member -NotePropertyName state -NotePropertyValue 'error' -Force
        $job | Add-Member -NotePropertyName message -NotePropertyValue (Tx 'el proceso se interrumpi\u00f3') -Force
    }
    @{ Dir = $Dir; Envs = $envs; Active = $active; Job = $job }
}

function Get-HarnessNode {
    $cmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cmd.Source } else { $null }
}

# Starts the change in the background. Returns an error text, or $null when it started.
function Start-HarnessJob([string]$Dir, [string]$Id, [ValidateSet('on', 'off')][string]$Action) {
    if (-not (Test-HarnessDir $Dir)) { return Tx 'No encuentro YourHarness (env.js) en la carpeta elegida.' }
    if ($Id -notmatch '^[a-z0-9_-]+$') { return (Tx 'Ambiente con nombre no v\u00e1lido: ') + $Id }
    $node = Get-HarnessNode
    if (-not $node) { return Tx 'No encuentro Node.js: inst\u00e1lalo para usar los ambientes.' }
    $current = (Get-HarnessState $Dir).Job
    if ($current -and $current.state -eq 'running') { return "Ya hay un cambio en curso: $($current.action) $($current.name)" }
    $entry = Join-Path $Dir 'env.js'
    Start-Process -FilePath $node -ArgumentList ('"{0}" {1} {2} --yes --job' -f $entry, $Id, $Action) -WorkingDirectory $Dir -WindowStyle Hidden
    $null
}
