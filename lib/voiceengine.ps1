# Voice engine settings from the ClaudeMaxxing window (Voz): which engine reads the summaries (edge, ElevenLabs,
# Gemini or the Windows voice) and the keys for the paid-with-free-tier ones. The voice hooks
# (voice\hooks\engines.ps1) do the speaking; this file only edits the install's voice\config.local.json and
# checks keys and credits. Tray side: it does not load voice\hooks\common.ps1 (its names clash with
# lib\common.ps1). Keep this file ASCII.

$script:VoiceEngines = [ordered]@{ edge = 'Edge (gratis)'; elevenlabs = 'ElevenLabs'; gemini = 'Gemini'; sapi = 'Windows' }
$script:VoiceGenders = @('mix', 'f', 'm')
$VoiceCreditsFile =Join-Path $TrayHome 'voice-credits.json'

function Get-VoiceLocalConfigPath([string]$Root = $TrayRoot) { Join-Path $Root 'voice\config.local.json' }

function Read-VoiceLocalConfig([string]$Path) {
    $config = Read-JsonFile $Path
    if (-not $config) { $config = New-Object PSObject }
    $config
}

# Sets $Config.<Section>.<Name> (or $Config.<Name> when $Section is empty), creating the section.
function Set-VoiceLocalValue($Config, [string]$Section, [string]$Name, $Value) {
    $target = $Config
    if ($Section) {
        $node = $Config.PSObject.Properties[$Section]
        if (-not $node -or -not ($node.Value -is [System.Management.Automation.PSCustomObject])) {
            $Config | Add-Member -NotePropertyName $Section -NotePropertyValue (New-Object PSObject) -Force
        }
        $target = $Config.$Section
    }
    $target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

# What the Voz card shows: the engine and whether each premium engine has a key and voices.
function Get-VoiceEngineState([string]$Root = $TrayRoot) {
    $base = Read-JsonFile (Join-Path $Root 'voice\config.json')
    $local = Read-VoiceLocalConfig (Get-VoiceLocalConfigPath $Root)
    $engine = 'edge'
    if ($base -and $base.engine) { $engine = [string]$base.engine }
    if ($local.engine) { $engine = [string]$local.engine }
    if (-not $script:VoiceEngines.Contains($engine)) { $engine = 'edge' }
    $gender = 'mix'
    if ($base -and $base.voiceGender) { $gender = [string]$base.voiceGender }
    if ($local.voiceGender) { $gender = [string]$local.voiceGender }
    if ($gender -notin $script:VoiceGenders) { $gender = 'mix' }
    $eleven = $local.PSObject.Properties['elevenlabs']
    $gemini = $local.PSObject.Properties['gemini']
    [pscustomobject]@{
        Engine = $engine
        Gender = $gender
        ElevenKey = [bool]($eleven -and $eleven.Value.apiKey)
        ElevenVoices = $(if ($eleven -and $eleven.Value.voices) { @($eleven.Value.voices).Count } else { 0 })
        GeminiKey = [bool]($gemini -and $gemini.Value.apiKey)
        Credits = Read-JsonFile $VoiceCreditsFile
        Snooze = Get-VoiceEngineSnooze $engine
    }
}

# A pause the voice hooks put on an engine (voice\hooks\engines.ps1: no credits, a rejected key, too many
# requests); the summaries use Edge until it ends. @{ Until; Why } or $null.
function Get-VoiceEngineSnooze([string]$Engine) {
    $info = Read-JsonFile (Join-Path (Join-Path $env:TEMP 'claude-voice') "engine-off-$Engine.json")
    if (-not $info -or -not $info.until) { return $null }
    try { $until = [datetime]$info.until } catch { return $null }
    if ($until -le (Get-Date)) { return $null }
    [pscustomobject]@{ Until = $until; Why = [string]$info.why }
}

function Set-VoiceEngine([string]$Engine, [string]$Root = $TrayRoot) {
    if (-not $script:VoiceEngines.Contains($Engine)) { throw "unknown engine $Engine" }
    $path = Get-VoiceLocalConfigPath $Root
    $config = Read-VoiceLocalConfig $path
    Set-VoiceLocalValue $config '' 'engine' $Engine
    Write-JsonFile $path $config
}

# Which voices new sessions get (voice\hooks\common.ps1, Get-VoicePool): f, m or mix.
function Set-VoiceGender([string]$Gender, [string]$Root = $TrayRoot) {
    if ($Gender -notin $script:VoiceGenders) { throw "unknown gender $Gender" }
    $path = Get-VoiceLocalConfigPath $Root
    $config = Read-VoiceLocalConfig $path
    Set-VoiceLocalValue $config '' 'voiceGender' $Gender
    Write-JsonFile $path $config
}

# ElevenLabs keys start with sk_; Google AI Studio keys with AIza. Letters, digits, '_' and '-' only.
function Test-VoiceKeyFormat([string]$Engine, [string]$Key) {
    switch ($Engine) {
        'elevenlabs' { return [bool]($Key -cmatch '^sk_[A-Za-z0-9]{20,100}$') }
        'gemini'     { return [bool]($Key -cmatch '^AIza[A-Za-z0-9_\-]{30,60}$') }
    }
    $false
}

function Set-VoiceTls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ElevenLabs voices from the account, as @{ id; name; gender = f|m|''; accents = 'es/colombian', ... }. The premade
# voices are multilingual and speak Spanish with the Flash model. accents: the voice's own language/accent label
# plus its verified languages; engines.ps1 matches them against elevenlabs.accents.
function ConvertTo-ElevenVoicePool($Response) {
    $pool = @()
    foreach ($v in @($Response.voices)) {
        if (-not $v -or -not $v.voice_id) { continue }
        $gender = ''
        $label = if ($v.labels) { [string]$v.labels.gender } else { '' }
        if ($label -match '^f') { $gender = 'f' } elseif ($label -match '^m') { $gender = 'm' }
        $pairs = @(@($v.labels) + @($v.verified_languages) | Where-Object { $_ -and $_.language -and $_.accent } |
            ForEach-Object { ('{0}/{1}' -f $_.language, $_.accent).ToLowerInvariant() } | Select-Object -Unique)
        $pool += [pscustomobject]@{ id = [string]$v.voice_id; name = [string]$v.name; gender = $gender; accents = $pairs }
    }
    , $pool
}

# Credits left this month: @{ used; limit; resetAt; at }.
function ConvertTo-ElevenCredits($Subscription) {
    $reset = $null
    if ($Subscription.next_character_count_reset_unix) {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$Subscription.next_character_count_reset_unix).LocalDateTime.ToString('s')
    }
    [pscustomobject]@{ used = [int]$Subscription.character_count; limit = [int]$Subscription.character_limit; resetAt = $reset; at = (Get-Date).ToString('s') }
}

function Get-HttpStatus($ErrorRecord) {
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

# Checks the key with the service and saves it (and, for ElevenLabs, the account's voices and credits).
# Returns @{ Ok; Message }. The key is never logged.
function Save-VoiceKey([string]$Engine, [string]$Key, [string]$Root = $TrayRoot) {
    if (-not (Test-VoiceKeyFormat $Engine $Key)) {
        $what = if ($Engine -eq 'elevenlabs') { 'una clave de ElevenLabs (sk_...)' } else { 'una clave de Google AI Studio (AIza...)' }
        return [pscustomobject]@{ Ok = $false; Message = (L 'Eso no parece {0}.') -f (L $what) }
    }
    Set-VoiceTls12
    $path = Get-VoiceLocalConfigPath $Root
    $config = Read-VoiceLocalConfig $path
    try {
        if ($Engine -eq 'elevenlabs') {
            $voices = Invoke-RestMethod -Uri 'https://api.elevenlabs.io/v1/voices' -Headers @{ 'xi-api-key' = $Key } -TimeoutSec 15 -UseBasicParsing
            $pool = ConvertTo-ElevenVoicePool $voices
            if (-not $pool.Count) { return [pscustomobject]@{ Ok = $false; Message = 'La cuenta de ElevenLabs no tiene voces.' } }
            Set-VoiceLocalValue $config 'elevenlabs' 'apiKey' (Protect-Secret $Key)
            Set-VoiceLocalValue $config 'elevenlabs' 'voices' $pool
            $message = (L 'Clave de ElevenLabs guardada: {0} voces.') -f $pool.Count
            try {
                $sub = Invoke-RestMethod -Uri 'https://api.elevenlabs.io/v1/user/subscription' -Headers @{ 'xi-api-key' = $Key } -TimeoutSec 15 -UseBasicParsing
                Write-JsonFile $VoiceCreditsFile (ConvertTo-ElevenCredits $sub)
            } catch { }
        } else {
            [void](Invoke-RestMethod -Uri 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1' -Headers @{ 'x-goog-api-key' = $Key } -TimeoutSec 15 -UseBasicParsing)
            Set-VoiceLocalValue $config 'gemini' 'apiKey' (Protect-Secret $Key)
            $message = 'Clave de Gemini guardada.'
        }
    } catch {
        $code = Get-HttpStatus $_
        # ElevenLabs answers 401 for several reasons; its body says which ({"detail":{"status":...}}).
        $status = try { [string]($_.ErrorDetails.Message | ConvertFrom-Json).detail.status } catch { '' }
        $why = if ($status -eq 'missing_permissions') { 'a la clave le faltan permisos: dale Text to Speech, Voices (Read) y User (Read) en elevenlabs.io' }
        elseif ($status -eq 'detected_unusual_activity') { Tx 'ElevenLabs bloque\u00f3 la cuenta gratis por actividad inusual (VPN o proxy)' }
        elseif ($status -eq 'invalid_api_key') { Tx 'la clave no existe o fue borrada' }
        elseif ($code -in 400, 401, 403) { 'el servicio rechaza esa clave' } elseif ($code) { "error HTTP $code" } else { Tx 'sin conexi\u00f3n' }
        return [pscustomobject]@{ Ok = $false; Message = (L 'No se pudo comprobar la clave: {0}.') -f $why }
    }
    Set-VoiceLocalValue $config '' 'engine' $Engine
    Write-JsonFile $path $config
    # A new key clears a pause left by the old one (no credits, rejected key).
    Remove-Item -LiteralPath (Join-Path (Join-Path $env:TEMP 'claude-voice') "engine-off-$Engine.json") -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Ok = $true; Message = $message }
}

function Update-ElevenCredits([string]$Root = $TrayRoot) {
    $config = Read-VoiceLocalConfig (Get-VoiceLocalConfigPath $Root)
    $key = if ($config.elevenlabs) { Unprotect-Secret ([string]$config.elevenlabs.apiKey) } else { '' }
    if (-not $key) { return $null }
    Set-VoiceTls12
    try {
        $sub = Invoke-RestMethod -Uri 'https://api.elevenlabs.io/v1/user/subscription' -Headers @{ 'xi-api-key' = $key } -TimeoutSec 15 -UseBasicParsing
        $credits = ConvertTo-ElevenCredits $sub
        Write-JsonFile $VoiceCreditsFile $credits
        # Credits again (the month renewed, or more were bought): the pause for "sin creditos" is over.
        if ([int]$credits.limit -gt [int]$credits.used) {
            Remove-Item -LiteralPath (Join-Path (Join-Path $env:TEMP 'claude-voice') 'engine-off-elevenlabs.json') -Force -ErrorAction SilentlyContinue
        }
        $credits
    } catch {
        # A key made without User (Read) can speak but not read its subscription: say which permission is missing.
        $status = try { [string]($_.ErrorDetails.Message | ConvertFrom-Json).detail.status } catch { '' }
        if ($status -eq 'missing_permissions') { return [pscustomobject]@{ error = 'missing_permissions' } }
        $null
    }
}

# The Voz card when ElevenLabs ran out: credits renew each month on the plan's date (the free plan's 10.000 too).
function Get-ElevenNoCreditsText($Credits, [datetime]$Now = (Get-Date)) {
    $when = $null
    if ($Credits -and $Credits.resetAt) { try { $when = [datetime]$Credits.resetAt } catch { } }
    if ($when -and $when -gt $Now) {
        return (Tx 'ElevenLabs se qued\u00f3 sin cr\u00e9ditos: se renuevan el ') + $when.ToString('d MMM', $UiCulture).TrimEnd('.') +
            (Tx ' (cada mes, con tu plan). Mientras, los res\u00famenes usan Edge.')
    }
    Tx 'ElevenLabs se qued\u00f3 sin cr\u00e9ditos: se renuevan cada mes, en la fecha de tu plan (elevenlabs.io > Subscription). Mientras, Edge. Con el permiso User (Read) en la clave, aqu\u00ed sale la fecha.'
}

# "8.432 de 10.000 creditos (se renuevan el 3 nov)": credits left, or ''.
function Format-ElevenCredits($Credits) {
    if (-not $Credits -or -not $Credits.limit) { return '' }
    $culture = $UiCulture
    $left = [Math]::Max(0, [int]$Credits.limit - [int]$Credits.used)
    $text = ((L '{0} de {1} ') -f $left.ToString('N0', $culture), ([int]$Credits.limit).ToString('N0', $culture)) + (Tx 'cr\u00e9ditos')
    if ($Credits.resetAt) { try { $text += (L ' (se renuevan el ') + ([datetime]$Credits.resetAt).ToString('d MMM', $culture) + ')' } catch { } }
    $text
}
