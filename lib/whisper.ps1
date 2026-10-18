# Claude Whisper: live call copilot. The PC's audio (the other side of the call) and the microphone are
# transcribed with Claude Code's own speech-to-text service, and Claude answers through a long-lived
# `claude -p` on the user's Claude subscription. This file holds the pure helpers (settings, prompts,
# question detection, transcript and stream-json handling) and loading the native side (lib\whisper.cs).
# Needs common.ps1. Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

$WhisperHome      = Join-Path $TrayHome 'whisper'
$WhisperSettingsFile = Join-Path $WhisperHome 'settings.json'
$WhisperSessionsDir  = Join-Path $WhisperHome 'sessions'
$WhisperPromptFile   = Join-Path $WhisperHome 'system-prompt.txt'
$WhisperLogFile      = Join-Path $WhisperHome 'whisper.log'
$WhisperPidFile      = Join-Path $WhisperHome 'whisper.pid'

$script:WhisperLanguages = [ordered]@{
    es = (Tx 'Espa\u00f1ol'); en = 'English'; pt = (Tx 'Portugu\u00eas'); fr = (Tx 'Fran\u00e7ais'); de = 'Deutsch'; it = 'Italiano'
}
$script:WhisperModels = [ordered]@{ sonnet = 'Sonnet'; haiku = (Tx 'Haiku (m\u00e1s r\u00e1pido)'); opus = 'Opus' }

function Get-WhisperDefaults {
    [ordered]@{
        language     = 'es'
        model        = 'sonnet'
        autoAnswer   = $true
        useMic       = $true
        gateMic      = $true
        profile      = ''
        meeting      = ''
        instructions = ''
        keyterms     = ''
        hotkeyAnswer = 'Ctrl+Alt+Shift+R'
        hotkeyScreen = 'Ctrl+Alt+Shift+C'
        hotkeyToggle = 'Ctrl+Alt+Shift+W'
        topMost      = $true
        meetingNotice = $true
        bounds       = $null
    }
}

# Saved settings over the defaults; unknown or wrongly typed values fall back to the default.
function Get-WhisperSettings($Saved) {
    $settings = Get-WhisperDefaults
    if ($null -eq $Saved) { return $settings }
    foreach ($key in @($settings.Keys)) {
        $prop = $Saved.PSObject.Properties[$key]
        if (-not $prop -or $null -eq $prop.Value) { continue }
        $default = $settings[$key]
        if ($default -is [bool]) { $settings[$key] = [bool]$prop.Value }
        elseif ($default -is [string]) { $settings[$key] = [string]$prop.Value }
        else { $settings[$key] = $prop.Value }
    }
    if (-not $script:WhisperLanguages.Contains($settings.language)) { $settings.language = 'es' }
    if (-not $script:WhisperModels.Contains($settings.model)) { $settings.model = 'sonnet' }
    $settings
}

# ---------------------------------------------------------------- prompts

function New-WhisperSystemPrompt($Settings) {
    $language = $script:WhisperLanguages[$Settings.language]
    $lines = @(
        (Tx 'Eres Claude Whisper, un copiloto en tiempo real para conversaciones en vivo: entrevistas de trabajo, reuniones, llamadas de venta o clases.'),
        (Tx 'Recibes la transcripci\u00f3n autom\u00e1tica de la llamada. "Ellos" es la otra parte (el audio del PC) y "T\u00fa" es el usuario (su micr\u00f3fono). La transcripci\u00f3n tiene errores: interpreta la intenci\u00f3n.'),
        '',
        (Tx 'Cuando se te pida una respuesta, escribe lo que el usuario puede decir en voz alta ahora mismo:'),
        (Tx '- Empieza directamente por la respuesta: sin saludos, sin repetir la pregunta y sin comentarios sobre estas instrucciones.'),
        (Tx '- Primero una o dos frases que respondan de forma directa. Despu\u00e9s, si ayuda, de 2 a 4 vi\u00f1etas cortas con los puntos de apoyo (datos, ejemplos, cifras).'),
        (Tx '- En primera persona y con tono hablado y natural, f\u00e1cil de leer de un vistazo.'),
        (Tx '- Si es una pregunta t\u00e9cnica o un ejercicio, da la respuesta correcta y concreta. C\u00f3digo solo cuando haga falta, breve y en un bloque ```.'),
        (Tx '- Usa el perfil del usuario y el contexto de la conversaci\u00f3n cuando venga al caso. No inventes experiencia, t\u00edtulos ni datos que no est\u00e9n en el perfil.'),
        (Tx '- Si te falta un dato del usuario, da igualmente la respuesta lista para decir y deja huecos entre corchetes para lo concreto ([a\u00f1os], [empresa], [proyecto]). Nunca le hagas preguntas al usuario ni le pidas m\u00e1s informaci\u00f3n.'),
        (Tx '- Si lo \u00faltimo no es una pregunta, sugiere en una o dos frases qu\u00e9 decir o qu\u00e9 preguntar.'),
        "- $(Tx 'Responde en') $language."
    )
    $sections = @(
        @{ Title = (Tx 'Sobre el usuario'); Text = $Settings.profile },
        @{ Title = (Tx 'La conversaci\u00f3n (puesto, empresa, objetivo)'); Text = $Settings.meeting },
        @{ Title = (Tx 'Indicaciones del usuario'); Text = $Settings.instructions }
    )
    foreach ($section in $sections) {
        $text = ([string]$section.Text).Trim()
        if (-not $text) { continue }
        $lines += ''
        $lines += "## $($section.Title)"
        $lines += $text
    }
    ($lines -join "`n") + "`n"
}

function Format-WhisperSpeaker([string]$Source) {
    if ($Source -eq 'me') { return (Tx 'T\u00fa') }
    'Ellos'
}

# Transcript lines not sent to Claude yet, as "Ellos: ..." / "Tu: ..." text.
function Format-WhisperTranscript($Lines) {
    @($Lines | ForEach-Object { '{0}: {1}' -f (Format-WhisperSpeaker $_.Source), $_.Text }) -join "`n"
}

function New-WhisperRequest([string]$Kind, [string]$NewTranscript, [string]$Question) {
    $parts = @()
    if ($NewTranscript) { $parts += (Tx 'Transcripci\u00f3n nueva:') + "`n" + $NewTranscript; $parts += '' }
    switch ($Kind) {
        'answer' {
            if ($Question) { $parts += (Tx 'Responde ahora a lo \u00faltimo que dijeron: ') + [char]0x00AB + $Question.Trim() + [char]0x00BB }
            else { $parts += (Tx 'Sugiere qu\u00e9 decir ahora.') }
        }
        'ask' { $parts += (Tx 'El usuario te pregunta a ti (no lo dijo en la llamada): ') + $Question.Trim() }
        'screen' {
            $parts += (Tx 'Esta es la pantalla del usuario ahora mismo. Si hay un problema o un ejercicio (por ejemplo de programaci\u00f3n), resu\u00e9lvelo: el enfoque en una o dos frases, la soluci\u00f3n (con c\u00f3digo si aplica) y su complejidad. Si no, resume lo relevante para la conversaci\u00f3n y sugiere qu\u00e9 decir.')
        }
        'warmup' { $parts += (Tx 'Responde solo: listo') }
    }
    ($parts -join "`n").Trim()
}

# One stream-json input line: a user message with text, and optionally a base64 PNG before it.
function ConvertTo-ClaudeInputLine([string]$Text, [string]$ImageBase64) {
    $content = if ($ImageBase64) {
        @(
            [ordered]@{ type = 'image'; source = [ordered]@{ type = 'base64'; media_type = 'image/png'; data = $ImageBase64 } },
            [ordered]@{ type = 'text'; text = $Text }
        )
    } else { $Text }
    $message = [ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = $content } }
    ConvertTo-Json -InputObject $message -Compress -Depth 8
}

$script:ClaudeInterruptLine = '{"type":"control_request","request_id":"whisper-interrupt","request":{"subtype":"interrupt"}}'

# What a stream-json output line means for the UI: delta (answer text), result (turn ended), init, or $null.
function ConvertFrom-ClaudeLine([string]$Line) {
    if (-not $Line -or $Line[0] -ne '{') { return $null }
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    switch ($o.type) {
        'stream_event' {
            $e = $o.event
            if ($e.type -eq 'content_block_delta' -and $e.delta.type -eq 'text_delta' -and $e.delta.text) {
                return [pscustomobject]@{ Kind = 'delta'; Text = [string]$e.delta.text }
            }
            if ($e.type -eq 'content_block_start' -and $e.content_block.type -eq 'text') {
                return [pscustomobject]@{ Kind = 'block'; Text = '' }
            }
        }
        'result' {
            $failure = if ($o.is_error -and $o.subtype -ne 'error_during_execution') { [string]$o.result } else { '' }
            return [pscustomobject]@{ Kind = 'result'; Text = $failure; Interrupted = ($o.subtype -eq 'error_during_execution') }
        }
        'system' { if ($o.subtype -eq 'init') { return [pscustomobject]@{ Kind = 'init'; Text = [string]$o.model; ApiKeySource = [string]$o.apiKeySource } } }
    }
    $null
}

# ---------------------------------------------------------------- questions and echo

function ConvertTo-PlainWords([string]$Text) {
    $normalized = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $plain = -join ($normalized.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    @($plain -split '[^a-z0-9]+' | Where-Object { $_ })
}

# Interrogative words only count with their accent (que/como/cuando also start plain statements:
# "Como te dec\u00eda...", "Cuando empec\u00e9..."); the speech service writes the accents and the question marks.
$script:QuestionWords = @((Tx 'qu\u00e9 c\u00f3mo cu\u00e1l cu\u00e1les cu\u00e1ndo d\u00f3nde qui\u00e9n qui\u00e9nes cu\u00e1nto cu\u00e1ntos cu\u00e1nta cu\u00e1ntas') -split ' ') +
    @((Tx 'por qu\u00e9|para qu\u00e9|o que|est-ce que|qu\u00e9 tal') -split '[|]')
# Prompts that ask for an answer without a question mark, compared without accents. English question
# openers go in pairs ("how would", "what is") because single words also start statements ("When I joined...").
$script:QuestionPrompts = @(
    'cuentame', 'cuentanos', 'hablame', 'hablanos', 'explica', 'explicame', 'explicanos', 'describe', 'describeme', 'describenos',
    'dime', 'danos', 'imagina', 'imaginate', 'supongamos', 'platicame', 'comentame', 'menciona', 'podrias contarme', 'podrias explicar',
    'tell me', 'tell us', 'walk me', 'walk us', 'explain', 'give me', 'give us', 'imagine', 'suppose', 'talk me', 'talk us',
    'how would', 'how do', 'how did', 'how does', 'how can', 'how have', 'what would', 'what do', 'what did', 'what is', 'what are',
    'whats your', 'why would', 'why do', 'why did', 'why should', 'which one', 'have you', 'do you', 'did you', 'are you', 'can you',
    'could you', 'would you', 'is there',
    'conte', 'fale', 'me conte', 'me fale', 'descreva', 'explique', 'racontez', 'parlez', 'expliquez', 'decrivez',
    'erzahlen sie', 'beschreiben sie', 'erklaren sie', 'parlami', 'raccontami', 'descrivi', 'spiegami', 'parlaci', 'raccontaci'
)

# True when a finished utterance from the other side asks for an answer: a question mark, or a sentence
# that starts with an accented interrogative or a prompt ("cuentame...", "walk me through...").
function Test-WhisperQuestion([string]$Text) {
    $text = ([string]$Text).Trim()
    if ($text.Length -lt 8) { return $false }
    if ($text.Contains('?') -or $text.Contains([string][char]0x00BF)) { return $true }
    foreach ($sentence in ($text -split '(?<=[\.\!;:])\s+')) {
        $words = @($sentence.ToLowerInvariant() -split '[^\p{L}\p{Nd}\-]+' | Where-Object { $_ })
        if ($words.Count -lt 3) { continue }
        if ($script:QuestionWords -ccontains $words[0] -or $script:QuestionWords -ccontains "$($words[0]) $($words[1])") { return $true }
        $plain = ConvertTo-PlainWords $sentence
        if ($script:QuestionPrompts -contains $plain[0] -or $script:QuestionPrompts -contains "$($plain[0]) $($plain[1])") { return $true }
    }
    $false
}

# The part of what the other side said that asks something: from the first line that is a question to the
# end (an earlier greeting or comment is left out), or everything when no line is.
function Get-WhisperQuestionText([string[]]$Lines) {
    $lines = @($Lines | Where-Object { $_ -and $_.Trim() })
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (Test-WhisperQuestion $lines[$i]) { return (($lines[$i..($lines.Count - 1)]) -join ' ').Trim() }
    }
    ($lines -join ' ').Trim()
}

# Without headphones the mic also hears the speakers: a mic line whose words mostly match what the other
# side just said is that echo, not the user.
function Test-WhisperEcho([string]$MicText, [string[]]$RecentThem) {
    $mine = @(ConvertTo-PlainWords $MicText)
    if ($mine.Count -eq 0) { return $false }
    $theirs = @{}
    foreach ($line in $RecentThem) { foreach ($w in (ConvertTo-PlainWords $line)) { $theirs[$w] = $true } }
    if ($theirs.Count -eq 0) { return $false }
    $shared = @($mine | Where-Object { $theirs.ContainsKey($_) }).Count
    ($shared / $mine.Count) -ge 0.6 -and $mine.Count -ge 2
}

# Proper nouns and technical terms from the context, sent to the speech service to spell them right.
function Get-WhisperKeyterms($Settings) {
    $terms = New-Object System.Collections.Generic.List[string]
    foreach ($term in ([string]$Settings.keyterms -split '[,;\r\n]+')) { if ($term.Trim()) { $terms.Add($term.Trim()) } }
    $text = (@($Settings.profile, $Settings.meeting) -join "`n")
    $found = [regex]::Matches($text, '(?<![\w])([A-Z][A-Za-z0-9\+\#\.]*[A-Z0-9\+\#][A-Za-z0-9\+\#\.]*|[A-Z][a-z]{2,}[A-Z][A-Za-z]*|[A-Za-z]+[0-9\+\#]+[A-Za-z0-9]*|\.NET|C\+\+|C\#)')
    foreach ($m in $found) {
        $term = $m.Value.TrimEnd('.')
        if ($term.Length -ge 2 -and $term.Length -le 40) { $terms.Add($term) }
    }
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    $length = 0
    foreach ($term in $terms) {
        $clean = ($term -replace '[^\x20-\x7E]', '' -replace ',', ' ' -replace '\s+', ' ').Trim()
        $key = $clean.ToLowerInvariant()
        if (-not $clean -or $seen.ContainsKey($key)) { continue }
        if ($length + $clean.Length + 1 -gt 1024 -or $out.Count -ge 80) { break }
        $seen[$key] = $true
        $out.Add($clean)
        $length += $clean.Length + 1
    }
    $out -join ','
}

# ---------------------------------------------------------------- transcript

# The transcript keeps finished lines plus, per side, the utterance still being spoken. Returns the line
# that was finished, if any.
function New-WhisperTranscript { @{ Lines = New-Object System.Collections.ArrayList; Open = @{ them = ''; me = '' }; Sent = 0 } }

function Update-WhisperTranscript($Transcript, [string]$Source, [string]$Kind, [string]$Text, [datetime]$At) {
    if ($Source -notin 'them', 'me') { return $null }
    if ($Kind -eq 'interim') { $Transcript.Open[$Source] = $Text; return $null }
    if ($Kind -ne 'final') { return $null }
    $Transcript.Open[$Source] = ''
    $text = $Text.Trim()
    if (-not $text) { return $null }
    $line = [pscustomobject]@{ Source = $Source; Text = $text; At = $At }
    [void]$Transcript.Lines.Add($line)
    $line
}

# Lines since the last request, which marks them sent.
function Pop-WhisperUnsent($Transcript) {
    $new = @()
    for ($i = $Transcript.Sent; $i -lt $Transcript.Lines.Count; $i++) { $new += $Transcript.Lines[$i] }
    $Transcript.Sent = $Transcript.Lines.Count
    , $new
}

function Format-WhisperLogLine($Line) {
    '**{0}** {1} {2}' -f (Format-WhisperSpeaker $Line.Source), $Line.At.ToString('HH:mm:ss'), $Line.Text
}

# ---------------------------------------------------------------- call history

# A Claude Whisper call log (whisper\sessions\yyyyMMdd-HHmmss.md): when, how long, how many lines from each
# side, how many answers from Claude and the first thing Claude answered.
function ConvertFrom-WhisperCallLog([string]$Name, [string[]]$Lines) {
    $started = $null
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Name, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) { $started = $parsed }
    $meTag = '**' + (Tx 'T\u00fa') + '** '
    $them = 0; $me = 0; $answers = 0; $first = ''; $firstThem = ''
    $times = New-Object System.Collections.Generic.List[timespan]
    foreach ($line in $Lines) {
        if ($line.StartsWith('**Ellos** ')) {
            $them++
            if (-not $firstThem) { $firstThem = ($line -replace '^\*\*Ellos\*\* (\d{2}:\d{2}:\d{2} )?', '').Trim() }
        } elseif ($line.StartsWith($meTag)) {
            $me++
        } elseif ($line.StartsWith('### Claude')) {
            $answers++
            if (-not $first) { $first = ($line -replace ('^### Claude\s*' + [char]0x00B7 + '?\s*'), '').Trim() }
        }
        if ($line -match '^\*\*[^*]+\*\* (\d{2}):(\d{2}):(\d{2}) ') {
            $times.Add((New-Object TimeSpan([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])))
        }
    }
    $minutes = 0
    if ($times.Count -ge 2) {
        $span = $times[$times.Count - 1] - $times[0]
        if ($span.TotalSeconds -lt 0) { $span = $span.Add([TimeSpan]::FromHours(24)) }
        $minutes = [int][Math]::Ceiling($span.TotalMinutes)
    }
    # An answered turn's title holds everything they said since the last one: keep it from the question on.
    $topic = if ($first) { $first } else { $firstThem }
    $mark = $topic.IndexOf([char]0x00BF)
    if ($mark -gt 0) { $topic = $topic.Substring($mark) }
    [pscustomobject]@{
        Name = $Name; Started = $started; Them = $them; Me = $me; Answers = $answers; Minutes = $minutes; Topic = $topic; Path = ''
    }
}

function Format-CallDuration([int]$Minutes) {
    if ($Minutes -lt 1) { return '<1 min' }
    if ($Minutes -lt 60) { return "$Minutes min" }
    '{0} h {1} min' -f [int][Math]::Floor($Minutes / 60), ($Minutes % 60)
}

# ---------------------------------------------------------------- hotkeys

# "Ctrl+Alt+Shift+R" -> @{ Mods = 7; Key = 82 } (mods: 1 Alt, 2 Ctrl, 4 Shift, 8 Win), or $null.
function ConvertFrom-WhisperHotkey([string]$Text) {
    if (-not $Text) { return $null }
    $mods = 0
    $key = $null
    foreach ($part in ($Text -split '\+')) {
        switch ($part.Trim().ToLowerInvariant()) {
            'alt' { $mods = $mods -bor 1 }
            'ctrl' { $mods = $mods -bor 2 }
            'control' { $mods = $mods -bor 2 }
            'shift' { $mods = $mods -bor 4 }
            'win' { $mods = $mods -bor 8 }
            default {
                $name = $part.Trim()
                if ($name -match '^\d$') { $name = "D$name" }
                try { $key = [int][System.Windows.Forms.Keys]$name } catch { return $null }
            }
        }
    }
    if ($null -eq $key -or $mods -eq 0) { return $null }
    @{ Mods = $mods; Key = $key }
}

# ---------------------------------------------------------------- claude

# The real claude.exe: an npm install puts a claude.cmd shim on PATH, and a .cmd cannot be given piped
# stdin without cmd.exe in the middle.
function Resolve-ClaudeExe {
    $candidates = New-Object System.Collections.Generic.List[string]
    $config = Read-JsonFile $ConfigFile
    if ($config -and $config.claudePath) { $candidates.Add([string]$config.claudePath) }
    foreach ($name in 'claude.exe', 'claude.cmd') {
        foreach ($cmd in @(Get-Command $name -All -ErrorAction SilentlyContinue)) { $candidates.Add($cmd.Source) }
    }
    $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
    foreach ($path in $candidates) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        if ($path -like '*.exe') { return $path }
        $exe = Join-Path (Split-Path -Parent $path) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    $null
}

function Get-ClaudeArguments([string]$Model, [string]$PromptFile) {
    # --safe-mode: no CLAUDE.md, hooks, plugins or MCP servers (so the voice plugin stays quiet).
    # --setting-sources project: not the user's settings either (an advisor model set there adds a 10-20 s
    # consultation to every answer); it runs in its own folder, so there is no project. --effort low: the
    # first words come about twice as fast, which is what matters in a live call.
    # --tools "": Claude only writes text here. Nothing is saved as a resumable session.
    '-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages ' +
    "--model $Model --effort low --tools `"`" --safe-mode --setting-sources project --no-session-persistence " +
    "--system-prompt-file `"$PromptFile`""
}

# Set on the claude process, as name/value pairs.
function Get-ClaudeExtraEnv { @('CLAUDE_CODE_DISABLE_ADVISOR_TOOL', '1') }

# Environment variables removed from the claude process: Claude Code session markers (so it is a
# top-level run) and API keys (so it uses the Claude subscription, never paid API credits).
function Get-ClaudeRemovedEnv {
    $names = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -match '^(CLAUDE_CODE_|CLAUDECODE$|CLAUDE_PID$)' })
    $names + @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')
}

# When Claude Code's login (the OAuth access token the speech service also uses) expires, or $null.
function Get-ClaudeLoginExpiry([string]$CredentialsPath) {
    try {
        $oauth = (Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json).claudeAiOauth
        if (-not $oauth -or -not $oauth.expiresAt) { return $null }
        [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt).LocalDateTime
    } catch { $null }
}

# ---------------------------------------------------------------- native side

function Import-WhisperNative {
    if ('ClaudeWhisper.Engine' -as [type]) { return }
    $source = Join-Path $TrayRoot 'lib\whisper.cs'
    $text = [IO.File]::ReadAllText($source)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $BinDir "ClaudeWhisper-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
        # Compile to a private name first so a concurrent run never loads a half-written file.
        $tmp = Join-Path $BinDir "ClaudeWhisper-$hash-$PID.dll"
        Add-Type -TypeDefinition $text -ReferencedAssemblies System.Web.Extensions, System.Windows.Forms -OutputAssembly $tmp -OutputType Library
        try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $BinDir -Filter 'ClaudeWhisper-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    Add-Type -Path $dll
}

function Write-WhisperLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $WhisperHome)) { New-Item -ItemType Directory -Force -Path $WhisperHome | Out-Null }
        $file = Get-Item -LiteralPath $WhisperLogFile -ErrorAction SilentlyContinue
        if ($file -and $file.Length -gt 1MB) { Remove-Item -LiteralPath $WhisperLogFile -ErrorAction SilentlyContinue }
        Add-Content -LiteralPath $WhisperLogFile -Value ('{0} {1}' -f (Get-Date).ToString('s'), $Text) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- launching (tray side)

# Hidden like the tray: conhost --headless keeps the PowerShell console out of sight.
function Get-WhisperLaunch([string]$Root) {
    @{
        File = Join-Path $env:WINDIR 'System32\conhost.exe'
        Arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f (Join-Path $Root 'whisper.ps1')
    }
}

# A second start only brings the open window back (whisper.ps1 checks its mutex).
function Start-WhisperWindow([string]$Root) {
    $launch = Get-WhisperLaunch $Root
    Start-Process -FilePath $launch.File -ArgumentList $launch.Arguments -WorkingDirectory $Root -WindowStyle Hidden
}

function Test-WhisperRunning {
    $mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\ClaudeWhisper', [ref]$mutex)) { $mutex.Dispose(); return $true }
    $false
}

# Apps that mean a call when they record from the microphone (process names, without .exe).
$script:MeetingApps = [ordered]@{
    'ms-teams' = 'Teams'; 'Teams' = 'Teams'; 'Zoom' = 'Zoom'; 'CptHost' = 'Zoom'; 'webex' = 'Webex'; 'CiscoCollabHost' = 'Webex'
    'atmgr' = 'Webex'; 'slack' = 'Slack'; 'Discord' = 'Discord'; 'Skype' = 'Skype'; 'lync' = 'Skype'; 'RingCentral' = 'RingCentral'
    'GoTo' = 'GoTo'; 'g2mcomm' = 'GoTo'; 'WhatsApp' = 'WhatsApp'; 'Telegram' = 'Telegram'; 'Signal' = 'Signal'
}

# Display names of the meeting apps among the processes using the mic.
function Get-MeetingApps([string[]]$MicUsers) {
    $found = @()
    foreach ($user in $MicUsers) {
        foreach ($key in $script:MeetingApps.Keys) {
            if ($user -ieq $key -and $found -notcontains $script:MeetingApps[$key]) { $found += $script:MeetingApps[$key] }
        }
    }
    , $found
}

