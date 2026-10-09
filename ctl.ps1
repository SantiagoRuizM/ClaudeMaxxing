# Control manual de ClaudeVoice.
#   .\ctl.ps1 status                 estado general, motores detectados y log
#   .\ctl.ps1 test | say <texto>     frase de prueba / texto libre
#   .\ctl.ps1 stop                   corta el audio de todas las sesiones
#   .\ctl.ps1 mute | unmute          silencio global (todas las sesiones)
#   .\ctl.ps1 repeat [n]             repite lo ultimo que se dijo (o las n ultimas, en orden)
#   .\ctl.ps1 history [n]            lista lo ultimo que se dijo
#   .\ctl.ps1 sessions               nombre, rol y voz de cada sesion reciente
#   .\ctl.ps1 voices                 voces SAPI y edge-tts en espanol
#   .\ctl.ps1 chimes [timbre]        escucha las firmas musicales disponibles (numeradas)
#   .\ctl.ps1 hotkeys on|off         atajos globales: Ctrl+Alt+Shift+O repetir, Ctrl+Alt+Shift+P parar
#   .\ctl.ps1 session <id> [on|off|parar|repetir [n]|repetir-todo [n]|voz <nombre>|sonido [n]|todo-on|todo-off]
#                                    lo usa el comando /voz
#   .\ctl.ps1 probe on|off|report    sonda de eventos de hooks (para investigar /btw)
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'test', 'say', 'stop', 'mute', 'unmute', 'repeat', 'history', 'sessions', 'voices',
                 'chimes', 'hotkeys', 'session', 'probe')]
    [string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

. "$PSScriptRoot\hooks\common.ps1"
try { [Console]::OutputEncoding = $Utf8 } catch {}  # nombres con tildes; sin consola puede fallar
$cfg = Get-VoiceConfig
$ProbeSettings = Join-Path $Root '.claude\settings.local.json'
$ProbeLog = Join-Path $StateDir 'probe.log'

function Get-Pool { @(Get-Opt $cfg 'edge.voicePool' $DefaultPool) }

# Acepta el nombre completo (es-MX-JorgeNeural) o una parte que coincida con una sola voz del pool (jorge).
function Resolve-Voice([string]$Name) {
    if ($Name -match '^[a-z]{2,3}-[A-Z]{2}-[A-Za-z]+Neural$') { return $Name }
    $hits = @(Get-Pool | Where-Object { $_ -like "*$Name*" })
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

function Show-Sessions {
    Get-ChildItem $StateDir -Filter 'voice-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $sid = $_.Name.Substring(6)
            $info = Read-JsonFile (Get-SessionFile 'name' $sid)
            [pscustomobject]@{
                Sesion     = $sid.Substring(0, [Math]::Min(8, $sid.Length))
                Nombre     = $info.name
                Rol        = $info.role
                Voz        = [IO.File]::ReadAllText($_.FullName, $Utf8).Trim()
                UltimoUso  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                Silenciada = Test-Path (Get-SessionFile 'muted' $sid)
            }
        } | Format-Table -AutoSize | Out-String
}

function Get-Count([string]$Value) {
    $n = 0
    if ([int]::TryParse("$Value", [ref]$n) -and $n -gt 0) { return [Math]::Min($n, 30) }
    return 1
}

function Invoke-Repeat([int]$Count, [string]$SessionId) {
    $items = @(Get-History $Count $SessionId)
    if (Start-Replay $items) { 'RESULTADO: repitiendo {0} mensaje(s).' -f $items.Count }
    else { 'RESULTADO: no hay nada que repetir todavia.' }
}

function Invoke-ChimeSync([string]$Wav) {
    $sp = New-Object System.Media.SoundPlayer $Wav
    $sp.PlaySync()
    $sp.Dispose()
}

function Describe-Chime($Chime) {
    '{0} {1}, {2}, {3}' -f $Chime.root, $Chime.chord, $Chime.pattern, $Chime.timbre
}

# Toca todas las firmas, numeradas, con un timbre (por defecto el general).
function Show-Chimes([string]$Timbre) {
    Import-Native
    if (-not $Timbre) { $Timbre = Get-Opt $cfg 'chime.defaultTimbre' 'campana' }
    $motifs = Get-ChimeMotifs $cfg
    $wav = Join-Path $StateDir 'chime-preview.wav'
    for ($i = 0; $i -lt $motifs.Count; $i++) {
        $m = $motifs[$i]
        $notes = [int[]]@($ChordIntervals["$($m.chord)"] | ForEach-Object { (ConvertTo-Midi $m.root) + $_ })
        $null = [ClaudeVoice.Chime]::Write($wav, $notes, "$($m.pattern)", $Timbre, [double](Get-Opt $cfg 'chime.volume' 0.35))
        '{0,2}. {1} {2}, {3}' -f ($i + 1), $m.root, $m.chord, $m.pattern
        Invoke-ChimeSync $wav
        Start-Sleep -Milliseconds 350
    }
    Remove-Item $wav -Force -ErrorAction SilentlyContinue
    'Timbres: campana, marimba, piano, cristal, kalimba, pluck (.\ctl.ps1 chimes marimba). Elegir: /voz sonido <n>'
}

# Atajos globales: un proceso oculto (hooks/hotkeys.ps1) los registra con RegisterHotKey.
# Arranca ahora y en cada inicio de sesion (acceso directo en la carpeta Inicio).
$OldHotkeyDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'ClaudeVoice'  # version anterior (.lnk con tecla rapida)
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeVoice atajos.lnk'
$HotkeyPidFile = Join-Path $StateDir 'hotkeys.pid'

function Stop-HotkeyListener {
    if (-not (Test-Path $HotkeyPidFile)) { return }
    $old = [int]([IO.File]::ReadAllText($HotkeyPidFile).Trim())
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$old" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -match 'hotkeys\.ps1') { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue }
    Remove-Item $HotkeyPidFile -Force -ErrorAction SilentlyContinue
}

function Set-Hotkeys([bool]$On) {
    # Los .lnk con tecla rapida de la version anterior pueden quedarse con la combinacion.
    if (Test-Path $OldHotkeyDir) { Remove-Item $OldHotkeyDir -Recurse -Force }
    Stop-HotkeyListener
    Remove-Item $StartupLink -Force -ErrorAction SilentlyContinue
    if (-not $On) { return 'Atajos desactivados.' }

    $listenerArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'hooks\hotkeys.ps1')
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLink)
    $lnk.TargetPath = (Get-Command powershell.exe).Source
    $lnk.Arguments = $listenerArgs
    $lnk.WindowStyle = 7
    $lnk.Save()
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $listenerArgs
    Start-Sleep -Seconds 3
    $lines = @(Get-Content $LogFile -Tail 4 -Encoding UTF8 | Where-Object { $_ -match 'hotkeys:' })
    'Atajos activos (tambien al iniciar sesion). Teclas en config.json -> hotkeys.'
    $lines
}

switch ($Command) {
    'test'   { Start-Utterance 'Hola, soy Claude. Si me escuchas, la voz funciona.'; 'Reproduciendo prueba...' }
    'say'    { Start-Utterance ($Rest -join ' ') }
    'stop'   { Stop-Playback '*'; 'Audio detenido en todas las sesiones.' }
    'mute'   { New-Item -ItemType File -Force -Path $MuteFile | Out-Null; 'Silencio global activado.' }
    'unmute' { Remove-Item $MuteFile -Force -ErrorAction SilentlyContinue; 'Silencio global desactivado.' }
    'sessions' { Show-Sessions }
    'repeat'   { Invoke-Repeat (Get-Count $(if ($Rest) { $Rest[0] })) '' }
    'history'  {
        Get-History (Get-Count $(if ($Rest) { $Rest[0] } else { '10' })) '' | ForEach-Object {
            '{0}  {1,-10} {2}' -f $_.time.Replace('T', ' '), $_.name, $_.text
        }
    }
    'hotkeys'  { Set-Hotkeys ($Rest -and $Rest[0] -eq 'on') }
    'chimes'   { Show-Chimes $(if ($Rest) { $Rest[0] }) }

    'session' {
        $sid = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
        $action = if ($Rest.Count -gt 1) { $Rest[1].ToLower() } else { 'estado' }
        $arg = if ($Rest.Count -gt 2) { $Rest[2..($Rest.Count - 1)] -join ' ' } else { '' }
        $sessionMute = Get-SessionFile 'muted' $sid
        switch ($action) {
            'off'      { New-Item -ItemType File -Force -Path $sessionMute | Out-Null; Stop-Playback $sid; 'RESULTADO: voz desactivada solo en esta sesion.' }
            'on'       { Remove-Item $sessionMute -Force -ErrorAction SilentlyContinue
                         if (Test-Path $MuteFile) { 'RESULTADO: voz activada en esta sesion, pero el silencio global sigue activo (usa /voz todo-on).' }
                         else { 'RESULTADO: voz activada en esta sesion.' } }
            'todo-off' { New-Item -ItemType File -Force -Path $MuteFile | Out-Null; Stop-Playback '*'; 'RESULTADO: voz desactivada en todas las sesiones.' }
            'todo-on'  { Remove-Item $MuteFile -Force -ErrorAction SilentlyContinue; 'RESULTADO: silencio global quitado; cada sesion conserva su propio on/off.' }
            'parar'    { Stop-Playback $sid; 'RESULTADO: audio de esta sesion detenido.' }
            'repetir'  { Invoke-Repeat (Get-Count $arg) $sid }
            'repetir-todo' { Invoke-Repeat (Get-Count $arg) '' }
            'sonido'   {
                $count = (Get-ChimeMotifs $cfg).Count
                $n = 0
                if ($arg -and -not ([int]::TryParse($arg, [ref]$n) -and $n -ge 1 -and $n -le $count)) {
                    "RESULTADO: elige un numero de 1 a $count (escuchalos con .\ctl.ps1 chimes)."
                } else {
                    $chime = if ($n) { New-SessionChime $cfg $sid ($n - 1) } else { Get-SessionChime $cfg $sid }
                    Invoke-ChimeSync $chime.wav
                    'RESULTADO: firma de esta sesion: n.{0}, {1}.' -f ($chime.motif + 1), (Describe-Chime $chime)
                }
            }
            'voz'      {
                $voice = Resolve-Voice $arg
                if (-not $voice) { "RESULTADO: no reconozco la voz '$arg'. Opciones: " + ((Get-Pool) -join ', ') }
                else { [IO.File]::WriteAllText((Get-SessionFile 'voice' $sid), $voice, $Utf8); "RESULTADO: esta sesion ahora habla con $voice." }
            }
            default    {
                $state = if (Test-Muted $sid) { 'silenciada' } else { 'activa' }
                $info = Get-SessionName $sid
                'RESULTADO: esta sesion es {0} ({1}); voz {2} ({3}); silencio global {4}.' -f $info.name, $info.role, $state,
                    (Get-SessionVoice $cfg $sid), $(if (Test-Path $MuteFile) { 'activo' } else { 'inactivo' })
                'Opciones: /voz on | off | parar | repetir [n] | repetir-todo [n] | voz <nombre> | sonido [n] | todo-on | todo-off. Voces: ' + ((Get-Pool) -join ', ')
            }
        }
    }

    'voices' {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        '--- SAPI (sapi.voice) ---'
        $synth.GetInstalledVoices() | ForEach-Object { '{0}  [{1}]' -f $_.VoiceInfo.Name, $_.VoiceInfo.Culture }
        $synth.Dispose()
        $edge = Find-Exe (Get-Opt $cfg 'edge.exe' '') 'edge-tts'
        if ($edge) {
            '--- edge-tts en espanol (edge.voice / edge.voicePool) ---'
            & $edge --list-voices | Select-String '^es-' | ForEach-Object { $_.Line }
        }
    }

    'probe' {
        $mode = if ($Rest.Count -gt 0) { $Rest[0] } else { 'report' }
        switch ($mode) {
            'on' {
                $probe = (Join-Path $PSScriptRoot 'hooks\probe.ps1').Replace('\', '/')
                $hook = @{ type = 'command'; async = $true; command = 'powershell.exe'
                           args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe) }
                $events = [ordered]@{}
                foreach ($e in 'MessageDisplay', 'UserPromptSubmit', 'UserPromptExpansion', 'Stop', 'Notification') {
                    $events[$e] = @(@{ hooks = @($hook) })
                }
                [IO.File]::WriteAllText($ProbeSettings, (@{ hooks = $events } | ConvertTo-Json -Depth 10), $Utf8)
                Remove-Item $ProbeLog -Force -ErrorAction SilentlyContinue
                "Sonda activa en $ProbeSettings. Abre una sesion NUEVA de Claude Code en esta carpeta,"
                'pide algo largo, lanza /btw mientras trabaja y luego: .\ctl.ps1 probe report'
            }
            'off' { Remove-Item $ProbeSettings -Force -ErrorAction SilentlyContinue; 'Sonda desactivada.' }
            default {
                if (-not (Test-Path $ProbeLog)) { 'Sin datos de la sonda todavia.' }
                else { Get-Content $ProbeLog -Encoding UTF8 }
            }
        }
    }

    'status' {
        $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
        $installed = (Test-Path $settings) -and ((Get-Content $settings -Raw) -match 'ClaudeVoice')
        [pscustomobject]@{
            Habilitado      = [bool](Get-Opt $cfg 'enabled' $true)
            SilencioGlobal  = Test-Path $MuteFile
            Motor           = Get-Opt $cfg 'engine' 'edge'
            VozPorSesion    = [bool](Get-Opt $cfg 'perSessionVoice' $true)
            VozPorDefecto   = Get-Opt $cfg 'edge.voice' 'es-CO-SalomeNeural'
            VozSapi         = Get-Opt $cfg 'sapi.voice' '(por defecto)'
            EdgeTts         = Find-Exe (Get-Opt $cfg 'edge.exe' '') 'edge-tts'
            FFplay          = Find-Exe (Get-Opt $cfg 'ffplay' '') 'ffplay'
            InstaladoGlobal = $installed
            SondaActiva     = Test-Path $ProbeSettings
            Log             = $LogFile
        } | Format-List
        '--- sesiones ---'
        Show-Sessions
        if (Test-Path $LogFile) { '--- ultimas lineas del log ---'; Get-Content $LogFile -Tail 5 -Encoding UTF8 }
    }
}
