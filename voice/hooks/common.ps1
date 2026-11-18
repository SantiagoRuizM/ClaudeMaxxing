# Funciones compartidas por los hooks, ctl.ps1 e install.ps1.
# Mantener los .ps1 en ASCII: Windows PowerShell 5.1 lee los archivos sin BOM como ANSI
# y rompe tildes y emojis. Los textos con acentos (nombres, roles) viven en config.json.
# Las variables de PowerShell no distinguen mayusculas: no reutilizar estos nombres globales.

$Root          = Split-Path -Parent $PSScriptRoot
$StateDir      = Join-Path $env:TEMP 'claude-voice'
$HistoryDir    = Join-Path $StateDir 'history'
$MuteFile      = Join-Path $StateDir 'muted'
$LogFile       = Join-Path $StateDir 'claude-voice.log'
$DuckFile      = Join-Path $StateDir 'duck.json'
$SpeakingFile  = Join-Path $StateDir 'speaking.json'  # el reproductor que tiene el turno (play.ps1); lo lee la bandeja
$Utf8          = New-Object System.Text.UTF8Encoding($false)
$DefaultMarker = [char]::ConvertFromUtf32(0x1F50A)  # altavoz
$DefaultPool   = @('es-CO-SalomeNeural', 'es-CO-GonzaloNeural', 'es-US-PalomaNeural', 'es-US-AlonsoNeural',
                   'es-MX-DaliaNeural', 'es-MX-JorgeNeural', 'es-PE-CamilaNeural', 'es-PE-AlexNeural')

New-Item -ItemType Directory -Force -Path $StateDir, $HistoryDir | Out-Null

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8)
    } catch {}
}

# config.json trae los valores por defecto (se reemplaza al reinstalar); config.local.json, si existe,
# tiene lo propio de este PC (rutas de edge-tts y ffplay, cambios del usuario) y se aplica encima.
function Get-VoiceConfig {
    $path = Join-Path $Root 'config.json'
    $config = if (Test-Path $path) { [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json } else { New-Object PSObject }
    $localPath = Join-Path $Root 'config.local.json'
    if (Test-Path $localPath) {
        try { Merge-VoiceConfig $config ([IO.File]::ReadAllText($localPath, $Utf8) | ConvertFrom-Json) }
        catch { Write-Log "config.local.json ignorado: $($_.Exception.Message)" }
    }
    return $config
}

# Copia las claves de $Override sobre $Base; los objetos se mezclan clave a clave, lo demas (listas
# incluidas) se reemplaza.
function Merge-VoiceConfig($Base, $Override) {
    if ($null -eq $Override) { return }
    foreach ($prop in $Override.PSObject.Properties) {
        $current = $Base.PSObject.Properties[$prop.Name]
        if ($current -and $current.Value -is [System.Management.Automation.PSCustomObject] -and
            $prop.Value -is [System.Management.Automation.PSCustomObject]) {
            Merge-VoiceConfig $current.Value $prop.Value
        } else {
            $Base | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }
}

# Lee una opcion anidada ('edge.voice') con valor por defecto si falta o esta vacia.
function Get-Opt($Config, [string]$Path, $Default) {
    $node = $Config
    foreach ($key in $Path.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $key)) { return $Default }
        $node = $node.$key
    }
    if ($null -eq $node -or ($node -is [string] -and $node -eq '')) { return $Default }
    return $node
}

function Find-Exe([string]$Configured, [string]$Name) {
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Read-JsonFile([string]$Path) {
    try { return [IO.File]::ReadAllText($Path, $Utf8) | ConvertFrom-Json } catch { return $null }
}

# An API key from config.local.json: "dpapi:<base64>" (lib\common.ps1, Protect-Secret) or a plain one saved before.
function Unprotect-Secret([string]$Value) {
    if (-not $Value.StartsWith('dpapi:')) { return $Value }
    Add-Type -AssemblyName System.Security
    try { [Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value.Substring(6)), $null, 'CurrentUser')) }
    catch { '' }
}

# -InputObject keeps a one-item array an array. Written to a temporary file and renamed over the old one, so another
# session's hook never reads it half written (in place when a reader blocks the rename).
function Write-JsonFile([string]$Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 6
    $tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [IO.File]::WriteAllText($tmp, $json, $Utf8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($Path, $json, $Utf8)
    }
}

# Lee el JSON del evento desde stdin como bytes UTF-8. No usa [Console]::InputEncoding
# porque el hook puede correr sin consola adjunta y esa propiedad lanza excepcion.
function Read-HookInput {
    $stdin  = [Console]::OpenStandardInput()
    $buffer = New-Object IO.MemoryStream
    $stdin.CopyTo($buffer)
    $raw = $Utf8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# Escribe JSON de salida del hook con todo lo no-ASCII escapado (\uXXXX): asi la codificacion
# de la consola de PowerShell no puede romper tildes ni emojis.
function Write-HookOutput($Value) {
    $json = $Value | ConvertTo-Json -Compress -Depth 6
    $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    [Console]::Out.Write($json)
}

# Ejecuta $Body con un candado entre procesos: dos sesiones que terminan a la vez preparan su
# audio en paralelo y sin esto podrian elegir la misma voz, nombre o firma. Es reentrante
# (un Mutex de .NET lo es para el mismo hilo), asi que se puede anidar.
function Use-StateLock([scriptblock]$Body) {
    $lock = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoiceState')
    $owned = $false
    try {
        try { $owned = $lock.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        & $Body
    } finally {
        if ($owned) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}

# ---------- sesiones: voz, nombre, silencio ----------

# El session_id se usa en nombres de archivo: solo letras, numeros y guiones.
function Get-SessionKey([string]$SessionId) {
    $key = [regex]::Replace("$SessionId", '[^A-Za-z0-9-]', '')
    if ($key) { return $key } else { return 'manual' }
}

function Get-SessionFile([string]$Kind, [string]$SessionId) {
    Join-Path $StateDir ('{0}-{1}' -f $Kind, (Get-SessionKey $SessionId))
}

# Titulo de la pestana en las sesiones del menu: open-session.ps1 las abre con CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
# (sin el asterisco ni el spinner de Claude Code delante) y los hooks escriben "Nombre - rol" en la consola del
# claude de la sesion. -Busy le anade un espacio de ancho cero al final mientras trabaja: la bandeja lo lee para
# animar el huevo (Test-SessionTitleBusy en lib\traysessions.ps1). Va al final del hook, ya escrito su JSON.
function Set-SessionTerminalTitle($Info, [switch]$Busy) {
    if ("$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE" -ne '1' -or -not $Info -or -not "$($Info.title)") { return }
    Import-Native
    $claudePid = [ClaudeVoice.Title]::FindAncestor($PID, 'claude', 6)
    if (-not $claudePid) { return }
    $text = "$($Info.title)"
    if ($Busy) { $text += [char]0x200B }
    [void][ClaudeVoice.Title]::Set($claudePid, $text)
}

# El id con que el menu abrio esta ventana: claude conserva su --session-id en la linea de comandos aunque /clear
# le de otro id a la conversacion. Se guarda una vez por sesion en origin-<clave> (vacio si no lo hay); la bandeja
# encuentra por el el huevo de quien habla. $ParentId: el proceso desde donde subir (el que lanzo el hook).
function Save-SessionOrigin([string]$SessionId, [int]$ParentId = $PID) {
    $file = Get-SessionFile 'origin' $SessionId
    if ((Get-SessionKey $SessionId) -eq 'manual' -or (Test-Path -LiteralPath $file)) { return }
    $origin = ''
    $procId = $ParentId
    for ($depth = 0; $depth -lt 8 -and $procId -gt 0; $depth++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        if ("$($proc.CommandLine)" -match '--session-id\s+"?([0-9A-Fa-f-]{36})') { $origin = Get-SessionKey $Matches[1]; break }
        $procId = [int]$proc.ParentProcessId
    }
    Write-JsonFile $file ([pscustomobject]@{ origin = $origin })
}

# The transcript of the turn that just started, in turn-<origin key> (the id the menu opened the window with, the
# tray's key for its egg; the current id when there is none). The tray reads its tail: Claude Code runs no hook when
# the user interrupts a turn (Test-SessionTurnEnded in lib\traysessions.ps1).
function Save-SessionTurn([string]$SessionId, [string]$TranscriptPath) {
    if ((Get-SessionKey $SessionId) -eq 'manual') { return }
    Save-SessionOrigin $SessionId
    $origin = Read-JsonFile (Get-SessionFile 'origin' $SessionId)
    $key = if ($origin -and "$($origin.origin)") { "$($origin.origin)" } else { Get-SessionKey $SessionId }
    Write-JsonFile (Join-Path $StateDir "turn-$key") ([pscustomobject]@{ transcript = $TranscriptPath })
}

# Archivos de un tipo (voice-*, name-*) usados en las ultimas horas = sesiones activas.
function Get-ActiveStateFiles($Config, [string]$Kind) {
    $hours = [int](Get-Opt $Config 'sessionActiveHours' 12)
    Get-ChildItem $StateDir -Filter "$Kind-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$hours) }
}

# Claude Whisper (whisper.ps1) tiene este mutex mientras escucha: una voz bajaria el volumen de la llamada
# y Whisper la transcribiria como si fuera la otra parte.
function Test-WhisperListening {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\ClaudeWhisperListening', [ref]$m)) { $m.Dispose(); return $true }
    $false
}

# Silenciado si: CLAUDEVOICE=off en el entorno de la sesion, Claude Whisper escuchando una llamada,
# silencio global o silencio de la sesion.
function Test-Muted([string]$SessionId) {
    if ("$env:CLAUDEVOICE" -eq 'off') { return $true }
    if (Test-WhisperListening) { return $true }
    if (Test-Path $MuteFile) { return $true }
    return Test-Path (Get-SessionFile 'muted' $SessionId)
}

# Voz de la sesion, por prioridad: CLAUDEVOICE_VOICE > elegida con /voz > asignada del pool
# (la primera que no use otra sesion activa) > edge.voice.
function Get-SessionVoice($Config, [string]$SessionId) {
    if ($env:CLAUDEVOICE_VOICE) { return $env:CLAUDEVOICE_VOICE }
    $fallback = Get-Opt $Config 'edge.voice' 'es-CO-SalomeNeural'
    $file = Get-SessionFile 'voice' $SessionId
    if (Test-Path $file) {
        (Get-Item $file).LastWriteTime = Get-Date
        return [IO.File]::ReadAllText($file, $Utf8).Trim()
    }
    if (-not (Get-Opt $Config 'perSessionVoice' $true) -or (Get-SessionKey $SessionId) -eq 'manual') { return $fallback }

    Use-StateLock {
        if (Test-Path $file) { return [IO.File]::ReadAllText($file, $Utf8).Trim() }  # otra llamada gano
        $recent = Get-ActiveStateFiles $Config 'voice' | ForEach-Object { [IO.File]::ReadAllText($_.FullName, $Utf8).Trim() }
        $pool  = @(Get-Opt $Config 'edge.voicePool' $DefaultPool)
        $voice = $pool | Where-Object { $recent -notcontains $_ } | Select-Object -First 1
        if (-not $voice) { $voice = $pool[@($recent).Count % $pool.Count] }
        [IO.File]::WriteAllText($file, $voice, $Utf8)
        return $voice
    }
}

function Get-VoiceGender($Config, [string]$Voice) {
    $g = Get-Opt $Config "edge.voiceGenders.$Voice" ''
    if ($g -in 'f', 'm') { return $g }
    return 'f'
}

function Get-SessionName([string]$SessionId) {
    $file = Get-SessionFile 'name' $SessionId
    if (-not (Test-Path $file)) { return $null }
    (Get-Item $file).LastWriteTime = Get-Date
    return Read-JsonFile $file
}

# Quita tildes y pasa a minusculas para comparar palabras clave.
function ConvertTo-Folded([string]$Text) {
    $d = "$Text".ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    return [regex]::Replace($d, '\p{Mn}', '')
}

# Rol segun el primer prompt: el de naming.roles con mas palabras clave presentes.
# Devuelve el objeto del rol (key, f, m, keywords).
function Find-SessionRole($Config, [string]$Prompt) {
    # El contenido pegado no describe la tarea; solo cuenta lo que escribio el usuario.
    $own = [regex]::Replace("$Prompt", '(?s)<pasted_content[^>]*>.*?</pasted_content[^>]*>', ' ')
    $text = ' ' + (ConvertTo-Folded $own.Substring(0, [Math]::Min(2000, $own.Length))) + ' '
    $best = $null; $bestScore = 0
    foreach ($role in @(Get-Opt $Config 'naming.roles' @())) {
        $score = 0
        foreach ($kw in @($role.keywords)) {
            $pattern = '(?<![a-z0-9])' + [regex]::Escape((ConvertTo-Folded $kw))
            $score += [regex]::Matches($text, $pattern).Count
        }
        if ($score -gt $bestScore) { $best = $role; $bestScore = $score }
    }
    if (-not $best) { $best = Get-Opt $Config 'naming.defaultRole' ([pscustomobject]@{ key = 'asistente'; f = 'asistente'; m = 'asistente' }) }
    return $best
}

function Get-SessionRole($Config, [string]$Prompt, [string]$Gender) {
    return (Find-SessionRole $Config $Prompt).$Gender
}

# Crea el nombre de la sesion: nombre aleatorio del genero de su voz (sin repetir el de otra
# sesion activa) + rol segun el primer prompt. Lo guarda en name-<sesion>.
function New-SessionName($Config, [string]$SessionId, [string]$Prompt) {
    $voice    = Get-SessionVoice $Config $SessionId
    $gender   = Get-VoiceGender $Config $voice
    $roleInfo = Find-SessionRole $Config $Prompt
    $role     = $roleInfo.$gender
    $format   = Get-Opt $Config 'naming.titleFormat' '{name} - {role}'
    Use-StateLock {
        $name = Get-FreeName $Config $gender
        $info = [pscustomobject]@{
            name    = $name
            role    = $role
            roleKey = "$($roleInfo.key)"
            gender  = $gender
            voice   = $voice
            title   = $format.Replace('{name}', $name).Replace('{role}', $role)
        }
        Write-JsonFile (Get-SessionFile 'name' $SessionId) $info
        return $info
    }
}

# Nombre aleatorio del genero dado que no use otra sesion activa. Llamar dentro de Use-StateLock.
function Get-FreeName($Config, [string]$Gender) {
    $taken = Get-ActiveStateFiles $Config 'name' | ForEach-Object { (Read-JsonFile $_.FullName).name }
    $names = @(Get-Opt $Config "naming.names.$Gender" @('Claude'))
    $free  = @($names | Where-Object { $taken -notcontains $_ })
    if ($free.Count) { $free | Get-Random } else { $names | Get-Random }
}

# Sesion abierta desde el menu del Explorador (open-session.ps1): la voz y el nombre se eligen antes
# de arrancar Claude Code, con el session_id que luego recibe (--session-id). El titulo es solo el
# nombre hasta el primer prompt, que decide el rol (Complete-SessionRole). $Color es el de /color.
function New-ReservedSession($Config, [string]$SessionId, [string]$Color) {
    $voice  = Get-SessionVoice $Config $SessionId
    $gender = Get-VoiceGender $Config $voice
    Use-StateLock {
        $name = Get-FreeName $Config $gender
        $info = [pscustomobject]@{
            name        = $name
            role        = ''
            roleKey     = ''
            gender      = $gender
            voice       = $voice
            title       = $name
            color       = $Color
            pendingRole = $true
        }
        Write-JsonFile (Get-SessionFile 'name' $SessionId) $info
        return $info
    }
}

# Primer prompt de una sesion reservada: rol segun el prompt y titulo "<nombre> . <rol>".
function Complete-SessionRole($Config, [string]$SessionId, $Info, [string]$Prompt) {
    $roleInfo = Find-SessionRole $Config $Prompt
    $role     = $roleInfo.("$($Info.gender)")
    $format   = Get-Opt $Config 'naming.titleFormat' '{name} - {role}'
    $done = [pscustomobject]@{
        name        = "$($Info.name)"
        role        = $role
        roleKey     = "$($roleInfo.key)"
        gender      = "$($Info.gender)"
        voice       = "$($Info.voice)"
        title       = $format.Replace('{name}', "$($Info.name)").Replace('{role}', $role)
        color       = "$($Info.color)"
        pendingRole = $false
    }
    Write-JsonFile (Get-SessionFile 'name' $SessionId) $done
    return $done
}

# What the voice says when a turn ends on the plan's limit: the window that is full (from the statusline's usage.json)
# and when it comes back. Empty when no window is full (a passing rate limit) or another session said it in the last
# 10 minutes: several sessions hit the same limit together.
function Get-PlanLimitNotice([datetime]$Now = (Get-Date),
        [string]$TrayDir = (Join-Path $env:USERPROFILE '.claude\usage-tray')) {
    $usage = Read-JsonFile (Join-Path $TrayDir 'usage.json')
    if (-not $usage -or -not $usage.rate_limits) { return '' }
    $nowSec = ([DateTimeOffset]$Now).ToUnixTimeSeconds()
    $reset = $null
    foreach ($w in @($usage.rate_limits.five_hour, $usage.rate_limits.seven_day)) {
        if (-not $w -or $null -eq $w.used_percentage -or [double]$w.used_percentage -lt 99 -or [long]$w.resets_at -le $nowSec) { continue }
        $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$w.resets_at).LocalDateTime
        if (-not $reset -or $at -gt $reset) { $reset = $at }
    }
    if (-not $reset) { return '' }
    $mark = Join-Path $StateDir 'limit-notice'
    $last = 0L
    if (Test-Path -LiteralPath $mark) { [void][long]::TryParse(([IO.File]::ReadAllText($mark)).Trim(), [ref]$last) }
    if ($nowSec - $last -lt 600 -and $nowSec -ge $last) { return '' }
    [IO.File]::WriteAllText($mark, [string]$nowSec)
    $es = [Globalization.CultureInfo]::GetCultureInfo('es-ES')
    $when = if ($reset.Date -eq $Now.Date) { 'a las ' + $reset.ToString('H:mm') }
        elseif ($reset.Date -eq $Now.Date.AddDays(1)) { 'ma' + [char]0x00F1 + 'ana a las ' + $reset.ToString('H:mm') }
        else { 'el ' + $reset.ToString('dddd', $es) + ' a las ' + $reset.ToString('H:mm') }
    'Se acab' + [char]0x00F3 + " el plan de Claude. Vuelve $when."
}

# Context for a session's first prompt: the other menu sessions still open (sessions.json from open-session.ps1,
# kept to the ones the tray shows as live in eggs.json), with their name, role and folder, so this one knows who
# else is working and leaves their changes alone. Empty when there are none or the tray is not running.
function Get-OtherSessionsNote([string]$SessionId, [string]$Cwd,
        [string]$TrayDir = (Join-Path $env:USERPROFILE '.claude\usage-tray'), [int]$ParentId = $PID) {
    # eggs.json outlives a tray that was killed: it only counts while the tray in tray.pid is running.
    $trayPid = 0
    $pidFile = Join-Path $TrayDir 'tray.pid'
    if (Test-Path -LiteralPath $pidFile) { [void][int]::TryParse(([IO.File]::ReadAllText($pidFile)).Trim(), [ref]$trayPid) }
    if (-not $trayPid -or -not (Get-Process -Id $trayPid -ErrorAction SilentlyContinue)) { return '' }
    $live = Read-JsonFile (Join-Path $TrayDir 'eggs.json')
    if (-not $live) { return '' }
    $liveKeys = @($live.PSObject.Properties.Name)
    $own = Get-SessionKey $SessionId
    # After /clear this is a new id with no origin yet (Save-SessionTurn runs later): without it, this window's own
    # menu session would be listed as another one.
    Save-SessionOrigin $SessionId $ParentId
    $ownOrigin = Read-JsonFile (Get-SessionFile 'origin' $SessionId)
    # Assigned first: PowerShell 5.1's ConvertFrom-Json sends a JSON array down the pipeline as one object.
    $all = Read-JsonFile (Join-Path $TrayDir 'sessions.json')
    $lines = foreach ($s in @($all)) {
        if (-not $s -or -not $s.sessionId) { continue }
        $key = Get-SessionKey $s.sessionId
        if ($liveKeys -notcontains $s.sessionId -or $key -eq $own -or ($ownOrigin -and $key -eq "$($ownOrigin.origin)")) { continue }
        $info = Read-JsonFile (Get-SessionFile 'name' $s.sessionId)
        $who = if ($info -and $info.title) { "$($info.title)" } else { "$($s.name)" }
        $same = if ($Cwd -and "$($s.dir)".TrimEnd('\') -eq $Cwd.TrimEnd('\')) { ', tu misma carpeta' } else { '' }
        '- {0}: {1}{2}' -f $who, $s.dir, $same
    }
    if (-not @($lines).Count) { return '' }
    "Otras sesiones de Claude Code abiertas en este PC (nombre: carpeta):`n" + (@($lines) -join "`n") +
        "`nLas que trabajan en tu carpeta pueden tener cambios sin commitear: no los toques ni los commitees. No las saludes ni les escribas salvo que el usuario lo pida."
}

# Borra estado de sesiones viejas para que %TEMP% no crezca sin limite.
function Remove-StaleState {
    Get-ChildItem $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(voice|muted|name|chime|origin|turn|engine-off)-' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Native-<hash>.dll from older hook versions: the newest is the one in use (a loaded one is locked anyway).
    Get-ChildItem $StateDir -Filter 'Native-*.dll' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 1 | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- texto ----------

function ConvertTo-PlainText([string]$Text) {
    $t = [regex]::Replace($Text, '(?s)```.*?```', ' ')          # bloques de codigo
    $t = [regex]::Replace($t, '(?m)^\s*#+\s.*$', ' ')            # titulos
    $t = [regex]::Replace($t, '(?m)^\s*\|.*$', ' ')              # tablas
    $t = [regex]::Replace($t, '(?m)^\s*([-+*]|\d+\.)\s+', ' ')   # vinetas
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]+\)', '$1')     # [texto](url) -> texto
    $t = [regex]::Replace($t, 'https?://\S+', ' ')
    $t = [regex]::Replace($t, '\*\*|__|[`*>|]', '')
    return [regex]::Replace($t, '\s+', ' ').Trim()
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Text.Substring(0, $Max)
    $i = $cut.LastIndexOf(' ')
    if ($i -gt $Max / 2) { $cut = $cut.Substring(0, $i) }
    return $cut.TrimEnd(',', ';', ':', ' ') + '...'
}

# Devuelve lo que se debe decir en voz alta: la ultima linea que empieza con el marcador
# o, si Claude no la escribio, lo que indique 'fallback' (first-sentence | full | none).
function Get-SpokenText([string]$Message, $Config) {
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    $marker = Get-Opt $Config 'marker' $DefaultMarker
    $max    = [int](Get-Opt $Config 'maxChars' 300)

    $pattern = '(?m)^[\s>*_]*' + [regex]::Escape($marker) + '[\s:*_]*(.+?)\s*$'
    $found = [regex]::Matches($Message, $pattern)
    if ($found.Count -gt 0) {
        $text = ConvertTo-PlainText $found[$found.Count - 1].Groups[1].Value
        if ($text) { return Limit-Text $text $max }
    }

    $plain = ConvertTo-PlainText $Message
    if (-not $plain) { return $null }
    switch (Get-Opt $Config 'fallback' 'first-sentence') {
        'none'  { return $null }
        'full'  { return Limit-Text $plain $max }
        default {
            $m = [regex]::Match($plain, '^.+?[.!?](?=\s|$)')
            if ($m.Success) { return Limit-Text $m.Value $max }
            return Limit-Text $plain $max
        }
    }
}

# ---------- historial (para repetir) ----------

function Add-History($Item, [string]$Mp3, $Config) {
    $base = Join-Path $HistoryDir ('{0:yyyyMMdd-HHmmss-fff}-{1}' -f (Get-Date), $Item.session)
    $audio = ''
    if ($Mp3 -and (Test-Path $Mp3)) { Copy-Item $Mp3 "$base.mp3"; $audio = "$base.mp3" }
    Write-JsonFile "$base.json" ([pscustomobject]@{
        time = (Get-Date).ToString('s'); session = $Item.session; name = $Item.name
        voice = $Item.voice; text = $Item.text; audio = $audio
    })
    $keep = [int](Get-Opt $Config 'historySize' 30)
    Get-ChildItem $HistoryDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip $keep |
        ForEach-Object { Remove-Item $_.FullName, ([IO.Path]::ChangeExtension($_.FullName, '.mp3')) -Force -ErrorAction SilentlyContinue }
}

# Ultimas $Count entradas (de una sesion o de todas), de la mas vieja a la mas nueva.
function Get-History([int]$Count = 1, [string]$SessionId = '') {
    $filter = if ($SessionId) { '*-' + (Get-SessionKey $SessionId) + '.json' } else { '*.json' }
    $items = @(Get-ChildItem $HistoryDir -Filter $filter -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First $Count | ForEach-Object { Read-JsonFile $_.FullName })
    [array]::Reverse($items)
    return $items
}

# ---------- bajar la musica ----------

# Compila Mixer.cs (volumen por app), Chime.cs (firma musical) y Title.cs (titulo de la pestana) a una
# DLL, una sola vez por version de las fuentes, y la carga.
function Import-Native {
    if ('ClaudeVoice.Chime' -as [type]) { return }
    $sources = @('Mixer.cs', 'Chime.cs', 'Title.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    $sha  = [Security.Cryptography.SHA1]::Create()
    $all  = [Text.Encoding]::UTF8.GetBytes((($sources | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"))
    $hash = ([BitConverter]::ToString($sha.ComputeHash($all)) -replace '-', '').Substring(0, 12)
    $dll  = Join-Path $StateDir "Native-$hash.dll"
    if (-not (Test-Path $dll)) {
        $tmp = Join-Path $StateDir ('Native-{0}.dll' -f [guid]::NewGuid().ToString('N'))
        Add-Type -Path $sources -OutputAssembly $tmp -OutputType Library
        try { Move-Item $tmp $dll -ErrorAction Stop } catch { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    Add-Type -Path $dll
}

# ---------- firma musical por sesion ----------

$ChordIntervals = @{
    mayor = @(0, 4, 7, 12); menor = @(0, 3, 7, 12); sus2 = @(0, 2, 7, 12); sus4 = @(0, 5, 7, 12)
    maj7 = @(0, 4, 7, 11); m7 = @(0, 3, 7, 10); add9 = @(0, 4, 7, 14); seisnueve = @(0, 4, 9, 14)
    cuartas = @(0, 5, 10, 15); menor9 = @(0, 3, 7, 14)
}

# 'C4' -> 60, 'F#3' -> 54, 'Bb3' -> 58
function ConvertTo-Midi([string]$Note) {
    $m = [regex]::Match($Note, '^([A-Ga-g])([#b]?)(-?\d)$')
    if (-not $m.Success) { return 60 }
    $base = @{ c = 0; d = 2; e = 4; f = 5; g = 7; a = 9; b = 11 }[$m.Groups[1].Value.ToLower()]
    $acc = switch ($m.Groups[2].Value) { '#' { 1 } 'b' { -1 } default { 0 } }
    return 12 * ([int]$m.Groups[3].Value + 1) + $base + $acc
}

function Get-ChimeMotifs($Config) {
    @(Get-Opt $Config 'chime.motifs' @([pscustomobject]@{ root = 'C4'; chord = 'mayor'; pattern = 'sube' }))
}

# Genera (o regenera) el WAV de una sesion y guarda su descripcion en chime-<sesion>.json.
function New-SessionChime($Config, [string]$SessionId, [int]$Motif) {
    $motifs = Get-ChimeMotifs $Config
    $Motif = (($Motif % $motifs.Count) + $motifs.Count) % $motifs.Count
    $m = $motifs[$Motif]
    $info = Get-SessionName $SessionId
    $roleKey = if ($info -and $info.roleKey) { $info.roleKey } else { 'asistente' }
    $timbre = Get-Opt $Config "chime.roleTimbres.$roleKey" (Get-Opt $Config 'chime.defaultTimbre' 'campana')
    $intervals = $ChordIntervals["$($m.chord)"]
    if (-not $intervals) { $intervals = $ChordIntervals.mayor }
    $root = ConvertTo-Midi $m.root
    $notes = [int[]]@($intervals | ForEach-Object { $root + $_ })

    Import-Native
    $wav = Join-Path $StateDir ('chime-{0}.wav' -f (Get-SessionKey $SessionId))
    $lead = [ClaudeVoice.Chime]::Write($wav, $notes, "$($m.pattern)", $timbre, [double](Get-Opt $Config 'chime.volume' 0.35))
    $chime = [pscustomobject]@{
        motif = $Motif; root = $m.root; chord = $m.chord; pattern = $m.pattern
        timbre = $timbre; role = $roleKey; wav = $wav; leadMs = $lead
    }
    Write-JsonFile (Get-SessionFile 'chime' $SessionId) $chime
    return $chime
}

# Firma de la sesion: se asigna el primer motivo que no use otra sesion activa (como las voces).
# Si el rol cambio desde que se creo (sesion nombrada despues), se regenera con el timbre nuevo.
function Get-SessionChime($Config, [string]$SessionId) {
    if (-not (Get-Opt $Config 'chime.enabled' $true) -or (Get-SessionKey $SessionId) -in 'manual', 'replay') { return $null }
    $file = Get-SessionFile 'chime' $SessionId
    $chime = Read-JsonFile $file
    $info = Get-SessionName $SessionId
    $roleKey = if ($info -and $info.roleKey) { $info.roleKey } else { 'asistente' }
    if ($chime -and (Test-Path $chime.wav) -and $chime.role -eq $roleKey) {
        (Get-Item $file).LastWriteTime = Get-Date
        return $chime
    }
    if ($chime) { return New-SessionChime $Config $SessionId ([int]$chime.motif) }
    Use-StateLock {
        $again = Read-JsonFile $file  # otra llamada pudo asignarla mientras esperabamos
        if ($again -and (Test-Path $again.wav)) { return $again }
        $used = @(Get-ActiveStateFiles $Config 'chime' | Where-Object { $_.Extension -eq '' } |
            ForEach-Object { [int](Read-JsonFile $_.FullName).motif })
        $count = (Get-ChimeMotifs $Config).Count
        $motif = 0..($count - 1) | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if ($null -eq $motif) { $motif = $used.Count % $count }
        return New-SessionChime $Config $SessionId $motif
    }
}

# Baja el volumen de las apps que estan sonando. Guarda antes el estado en duck.json (con el
# proceso duenio) para poder restaurarlo aunque este proceso muera a mitad de frase.
function Invoke-Duck($Config) {
    if (-not (Get-Opt $Config 'duck.enabled' $true)) { return $false }
    try {
        Import-Native
        # Nunca bajar ffplay: es el reproductor de las voces y Windows recuerda el volumen por
        # programa, asi que si se cerrara bajado todas las voces siguientes sonarian bajas.
        $exclude = @($PID) + @(Get-Process ffplay -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $saved = [ClaudeVoice.Mixer]::Snapshot([int[]]$exclude)
        if (-not $saved) { return $false }
        $me = Get-Process -Id $PID
        Write-JsonFile $DuckFile ([pscustomobject]@{ pid = $PID; start = [string]$me.StartTime.Ticks; saved = $saved })
        $null = [ClaudeVoice.Mixer]::Apply($saved, [float](Get-Opt $Config 'duck.level' 0.2), [int](Get-Opt $Config 'duck.fadeMs' 300))
        return $true
    } catch { Write-Log "duck: $_"; return $false }
}

function Restore-Duck($Config, [int]$FadeMs = -1) {
    if (-not (Test-Path $DuckFile)) { return }
    try {
        $info = Read-JsonFile $DuckFile
        Remove-Item $DuckFile -Force -ErrorAction SilentlyContinue
        if (-not $info.saved) { return }
        if ($FadeMs -lt 0) { $FadeMs = [int](Get-Opt $Config 'duck.restoreMs' 800) }
        Import-Native
        $null = [ClaudeVoice.Mixer]::Apply($info.saved, 1.0, $FadeMs)
    } catch { Write-Log "restore-duck: $_" }
}

function Test-ProcessAlive($Info) {
    if (-not $Info -or [int]$Info.pid -le 0) { return $false }
    $proc = Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue
    return [bool]($proc -and [string]$proc.StartTime.Ticks -eq [string]$Info.start)
}

# Si quien bajo la musica ya no existe (se mato o fallo), la sube.
function Restore-StaleDuck($Config) {
    $info = Read-JsonFile $DuckFile
    if (-not $info -or (Test-ProcessAlive $info)) { return }
    Restore-Duck $Config 300
}

# Quien tiene el turno hereda la musica ya bajada por el anterior (si este termino dejandola
# baja porque habia cola), en vez de subirla y volver a bajarla.
function Receive-Duck {
    $info = Read-JsonFile $DuckFile
    if (-not $info -or (Test-ProcessAlive $info)) { return $false }
    $me = Get-Process -Id $PID
    Write-JsonFile $DuckFile ([pscustomobject]@{ pid = $PID; start = [string]$me.StartTime.Ticks; saved = $info.saved })
    return $true
}

# Deja la musica baja para el siguiente de la cola: marca duck.json sin duenio (pid -1) ANTES
# de soltar el turno, para que el siguiente lo herede aunque este proceso siga vivo un instante.
function Send-Duck {
    $info = Read-JsonFile $DuckFile
    if ($info) { Write-JsonFile $DuckFile ([pscustomobject]@{ pid = -1; start = ''; saved = $info.saved }) }
}

# Hay otro reproductor vivo esperando turno (aparte de este proceso)?
function Test-QueueWaiting {
    foreach ($f in @(Get-ChildItem $StateDir -Filter 'player-*.json' -ErrorAction SilentlyContinue)) {
        $info = Read-JsonFile $f.FullName
        if ($info -and [int]$info.pid -ne $PID -and (Test-ProcessAlive $info)) { return $true }
    }
    return $false
}

# ---------- reproduccion ----------

# Mata el reproductor de una sesion ('*' = todas). Compara la hora de inicio para no matar
# otro proceso que haya heredado el PID. Un reproductor cortado no alcanza a limpiar: aqui
# se borran sus temporales y, si estaba bajando la musica, se restaura.
function Stop-Playback([string]$SessionId = '*') {
    $key = if ($SessionId -eq '*') { '*' } else { Get-SessionKey $SessionId }
    $killed = $false
    foreach ($pidFile in @(Get-ChildItem $StateDir -Filter "player-$key.json" -ErrorAction SilentlyContinue)) {
        try {
            $info = Read-JsonFile $pidFile.FullName
            if (Test-ProcessAlive $info) {
                $null = & taskkill.exe /T /F /PID $info.pid 2>&1
                $killed = $true
            }
        } catch { Write-Log "stop-playback: $_" }
        Remove-Item $pidFile.FullName -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $StateDir -Filter "job-$key-*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Musica baja sin nadie que la suba (el reproductor muerto, o uno que la dejo baja para
    # el siguiente de la cola y ese siguiente acaba de morir): restaurar.
    # Con '*' (ctl stop, atajo de parar) se intenta siempre: tambien recupera la musica que dejo
    # baja un reproductor que murio por su cuenta, sin que hubiera nada que matar.
    if (($killed -or $SessionId -eq '*') -and -not (Test-QueueWaiting)) { Restore-StaleDuck (Get-VoiceConfig) }
}

# Lanza play.ps1 con una lista de cosas que decir, en un proceso oculto e independiente.
# Vuelve de inmediato. Si la clave ya tenia un reproductor, lo corta; los de otras claves no
# se tocan: play.ps1 hace cola con un mutex.
function Start-VoiceJob([object[]]$Items, [string]$Key, [bool]$History) {
    Stop-Playback $Key
    Remove-StaleState
    $file = Join-Path $StateDir ('job-{0}-{1}.json' -f $Key, [guid]::NewGuid().ToString('N'))
    Write-JsonFile $file ([pscustomobject]@{ key = $Key; history = $History; items = @($Items) })
    $play = Join-Path $PSScriptRoot 'play.ps1'
    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$play`"", '-JobFile', "`"$file`"")
    try {
        Write-JsonFile (Join-Path $StateDir "player-$Key.json") ([pscustomobject]@{ pid = $proc.Id; start = [string]$proc.StartTime.Ticks })
    } catch {}
    return $proc.Id
}

# Dice un texto con la voz y el nombre de la sesion.
# Con CLAUDEVOICE_DRYRUN=<ruta> solo escribe "voz|texto" en ese archivo (para tests).
function Start-Utterance([string]$Text, [string]$SessionId = 'manual', [string]$Voice = '') {
    $key = Get-SessionKey $SessionId
    if (-not $Voice) { $Voice = Get-SessionVoice (Get-VoiceConfig) $SessionId }
    if ($env:CLAUDEVOICE_DRYRUN) {
        [IO.File]::WriteAllText($env:CLAUDEVOICE_DRYRUN, "$Voice|$Text", $Utf8)
        return
    }
    $nameInfo = Get-SessionName $SessionId
    $item = [pscustomobject]@{ text = $Text; voice = $Voice; session = $key; name = "$($nameInfo.name)"; audio = '' }
    $id = Start-VoiceJob @($item) $key $true
    Write-Log ('speak[{0}] {1} {2}: {3}' -f $id, $key.Substring(0, [Math]::Min(8, $key.Length)), $Voice, $Text)
}

# Repite entradas del historial (usa el mp3 guardado; si no hay, vuelve a sintetizar).
function Start-Replay([object[]]$Items) {
    if (-not $Items -or $Items.Count -eq 0) { return $false }
    $id = Start-VoiceJob $Items 'replay' $false
    Write-Log ('replay[{0}] {1} entrada(s)' -f $id, $Items.Count)
    return $true
}
