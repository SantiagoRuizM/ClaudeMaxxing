# Claude Whisper: a live copilot window for calls (interviews, meetings, sales calls). It transcribes what the
# PC plays (the other side) and the microphone (you) with Claude Code's speech-to-text, spots questions, and
# Claude answers them on your Claude subscription through one long-lived `claude -p`. Started from the tray
# menu; a second start just brings the window back.
# Launch: powershell -NoProfile -ExecutionPolicy Bypass -STA -File whisper.ps1
# -RenderTo <png> draws the window with sample data and exits (layout check); -Theme light|dark overrides
# the Windows app theme. -SimulateWav <16 kHz mono wav> plays that file as the other side instead of the PC's
# audio; with -ExitAfter <s> and -ReportTo <json> it writes the transcript and answers there and exits.
param([string]$RenderTo, [string]$Theme, [string]$SimulateWav, [int]$ExitAfter = 0, [string]$ReportTo)

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\whisper.ps1')
Clear-ClaudeSessionEnv

$Rendering = [bool]$RenderTo
$Testing = [bool]$SimulateWav
if (-not $Rendering -and -not $Testing) {
    $createdNew = $false
    $script:WhisperMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeWhisper', [ref]$createdNew)
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClaudeWhisperShow')
    if (-not $createdNew) { [void]$script:ShowEvent.Set(); exit 0 }
    if (-not (Test-Path -LiteralPath $WhisperHome)) { New-Item -ItemType Directory -Force -Path $WhisperHome | Out-Null }
    [IO.File]::WriteAllText($WhisperPidFile, [string]$PID)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $TrayRoot 'lib\theme.ps1')
. (Join-Path $TrayRoot 'lib\whisperui.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
Import-WhisperNative
if (-not (Test-Path -LiteralPath $WhisperHome)) { New-Item -ItemType Directory -Force -Path $WhisperHome | Out-Null }

$script:LightTheme = if ($Theme) { $Theme -eq 'light' } else { Test-AppsLightTheme }
$script:Palette = Get-ClaudePalette $script:LightTheme
$P = $script:Palette
$script:WFonts = @{
    Answer     = New-UiFont 'Segoe UI' 11
    Strong     = New-UiFont 'Segoe UI Semibold' 11
    Code       = New-UiFont 'Consolas' 10
    Line       = New-UiFont 'Segoe UI' 9.5
    LineStrong = New-UiFont 'Segoe UI Semibold' 9.5
    Question   = New-UiFont 'Segoe UI Semibold' 9.5
}
$WF = $script:WFonts

# ---------------------------------------------------------------- state

$script:Settings = Get-WhisperSettings (Read-JsonFile $WhisperSettingsFile)
$script:Transcript = New-WhisperTranscript
$script:Engine = New-Object ClaudeWhisper.Engine
$script:Claude = $null
$script:Turns = New-Object System.Collections.ArrayList     # sent to claude, oldest first, each ends with a result
$script:Answers = New-Object System.Collections.ArrayList   # what the answer pane can show, oldest first
$script:AnswerIndex = -1
$script:Listening = $false
$script:PendingThem = New-Object System.Collections.ArrayList
$script:AnswerDueAt = [datetime]::MaxValue
$script:StreamState = @{ them = ''; me = '' }
$script:Problem = ''
$script:SessionFile = $null
$script:TranscriptDirty = $true
$script:AnswerDirty = $true
$script:RenderedLines = 0
$script:OpenStart = 0
$script:MicUsers = ''
$script:Ticks = 0
$script:StartedAt = Get-Date
# Interpreter (a Haiku claude): live translation and question detection for every line from the other side.
$script:Interp = $null
$script:InterpQueue = New-Object System.Collections.ArrayList    # finished "them" lines waiting for it
$script:InterpInFlight = $null                                  # the batch it is working on
$script:InterpText = ''
$script:InterpSentAt = [datetime]::MinValue
$script:InterpTurns = 0
$script:InterpNext = 1
$script:Asked = New-Object System.Collections.ArrayList          # questions answered on their own (recent)
$script:AnswerQueue = New-Object System.Collections.ArrayList    # questions waiting for the answer being written
$script:PendingChecked = 0
$script:TranscriptFull = $false

function Save-WhisperSettings {
    try { Write-JsonFile $WhisperSettingsFile $script:Settings } catch { }
}

# ---------------------------------------------------------------- session log (markdown history)

function Add-SessionLog([string]$Text) {
    if ($Rendering) { return }
    try {
        if (-not $script:SessionFile) {
            if (-not (Test-Path -LiteralPath $WhisperSessionsDir)) { New-Item -ItemType Directory -Force -Path $WhisperSessionsDir | Out-Null }
            $script:SessionFile = Join-Path $WhisperSessionsDir ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.md')
            $head = '# Claude Whisper ' + [char]0x00B7 + ' ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + "`n`n"
            [IO.File]::WriteAllText($script:SessionFile, $head, (New-Object System.Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($script:SessionFile, $Text + "`n`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------- claude

function Start-Claude {
    Stop-Claude
    $exe = Resolve-ClaudeExe
    if (-not $exe) { $script:Problem = Tx 'No encuentro Claude Code (claude). Inst\u00e1lalo y vuelve a abrir Claude Whisper.'; return $false }
    [IO.File]::WriteAllText($WhisperPromptFile, (New-WhisperSystemPrompt $script:Settings), (New-Object System.Text.UTF8Encoding($false)))
    $process = New-Object ClaudeWhisper.ClaudeProcess
    try {
        $process.Start($exe, (Get-ClaudeArguments $script:Settings.model $WhisperPromptFile), $WhisperHome, [string[]](Get-ClaudeRemovedEnv), [string[]](Get-ClaudeExtraEnv))
    } catch {
        $script:Problem = (Tx 'No pude abrir Claude Code: ') + $_.Exception.Message
        Write-WhisperLog "claude start failed: $($_.Exception.Message)"
        return $false
    }
    $script:Claude = $process
    Write-WhisperLog "claude started pid=$($process.Pid) model=$($script:Settings.model)"
    # A first tiny turn loads the context into the prompt cache (faster first answer) and refreshes the
    # Claude Code login if it expired, which the speech service needs too.
    Send-ClaudeTurn 'warmup' (New-WhisperRequest 'warmup' '' '') '' ''
    $true
}

function Stop-Claude {
    if ($script:Claude) {
        Write-WhisperLog "claude stopped pid=$($script:Claude.Pid)"
        $script:Claude.Kill()
        $script:Claude = $null
    }
    foreach ($turn in $script:Turns) { if ($turn.Answer -and $turn.Answer.State -in 'waiting', 'streaming') { $turn.Answer.State = 'stopped' } }
    $script:Turns.Clear()
}

function Send-ClaudeTurn([string]$Kind, [string]$Text, [string]$Title, [string]$Image) {
    if (-not $script:Claude -or $script:Claude.HasExited) {
        if ($Kind -eq 'warmup') { return }
        if (-not (Start-Claude)) { $script:AnswerDirty = $true; return }
    }
    # Only the newest question matters: stop an answer still being written.
    $head = if ($script:Turns.Count -gt 0) { $script:Turns[$script:Turns.Count - 1] } else { $null }
    if ($head -and $head.Answer -and $head.Answer.State -in 'waiting', 'streaming') {
        [void]$script:Claude.Send($script:ClaudeInterruptLine)
        $head.Answer.State = 'interrupted'
    }
    $answer = $null
    if ($Kind -ne 'warmup') {
        $answer = @{ Kind = $Kind; Title = $Title; Text = ''; State = 'waiting'; At = (Get-Date); Error = '' }
        [void]$script:Answers.Add($answer)
        while ($script:Answers.Count -gt 50) { $script:Answers.RemoveAt(0) }
        $script:AnswerIndex = $script:Answers.Count - 1
        $script:AnswerDirty = $true
    }
    [void]$script:Turns.Add(@{ Kind = $Kind; Answer = $answer })
    if (-not $script:Claude.Send((ConvertTo-ClaudeInputLine $Text $Image))) {
        if ($answer) { $answer.State = 'error'; $answer.Error = Tx 'Claude Code se cerr\u00f3.' }
    }
}

# The speech service only reads Claude Code's login; claude refreshes it when it makes a request. So when
# the login is about to expire, or the service refuses it, a tiny turn renews it (at most once a minute;
# a turn already running renews it too).
$script:LastLoginRefresh = [datetime]::MinValue
function Request-LoginRefresh([string]$Why) {
    if (((Get-Date) - $script:LastLoginRefresh).TotalSeconds -lt 60) { return }
    $script:LastLoginRefresh = Get-Date
    Write-WhisperLog "login refresh ($Why)"
    if (-not $script:Claude -or $script:Claude.HasExited) { [void](Start-Claude); return }
    if ($script:Turns.Count -eq 0) { Send-ClaudeTurn 'warmup' (New-WhisperRequest 'warmup' '' '') '' '' }
}

function Request-Answer([string]$Question) {
    $unsent = Pop-WhisperUnsent $script:Transcript
    $title = if ($Question) { $Question } else { Tx 'Sugerencia para ahora' }
    Send-ClaudeTurn 'answer' (New-WhisperRequest 'answer' (Format-WhisperTranscript $unsent) $Question) $title ''
    $script:PendingThem.Clear()
    $script:PendingChecked = 0
    $script:AnswerDueAt = [datetime]::MaxValue
}

# "Responder" without a detected question: the other side's last words, if any.
function Request-AnswerNow {
    $question = Get-WhisperQuestionText @($script:PendingThem)
    if (-not $question) {
        $last = @($script:Transcript.Lines | Where-Object { $_.Source -eq 'them' } | Select-Object -Last 1)
        if ($last.Count -gt 0) { $question = $last[0].Text }
    }
    Request-Answer $question
}

function Request-Ask([string]$Text) {
    if (-not $Text.Trim()) { return }
    $unsent = Pop-WhisperUnsent $script:Transcript
    Send-ClaudeTurn 'ask' (New-WhisperRequest 'ask' (Format-WhisperTranscript $unsent) $Text) $Text.Trim() ''
}

# The monitor under the mouse, without this window on it, as a PNG with its long side at most 1568 px
# (Claude scales larger images down to that anyway; a screen that size is well under the image limit).
# PNG, not JPEG: with the JPEG encoder and its quality setting here, Windows Defender (AMSI) blocked the
# whole script as malicious; it does not with PNG.
function Get-ScreenPng {
    $opacity = $script:Form.Opacity
    $script:Form.Opacity = 0
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 180
    try {
        $bounds = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).Bounds
        $shot = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($shot)
        $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bounds.Size)
        $g.Dispose()
    } finally {
        $script:Form.Opacity = $opacity
    }
    $scale = [Math]::Min(1.0, 1568.0 / [Math]::Max($shot.Width, $shot.Height))
    $image = $shot
    if ($scale -lt 1) {
        $image = New-Object System.Drawing.Bitmap([int]($shot.Width * $scale), [int]($shot.Height * $scale))
        $g = [System.Drawing.Graphics]::FromImage($image)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($shot, 0, 0, $image.Width, $image.Height)
        $g.Dispose(); $shot.Dispose()
    }
    $stream = New-Object System.IO.MemoryStream
    $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
    [Convert]::ToBase64String($stream.ToArray())
}

function Request-Screen {
    try { $png = Get-ScreenPng } catch { $script:Problem = Tx 'No pude capturar la pantalla.'; return }
    $unsent = Pop-WhisperUnsent $script:Transcript
    Send-ClaudeTurn 'screen' (New-WhisperRequest 'screen' (Format-WhisperTranscript $unsent) '') (Tx 'Lo que hay en tu pantalla') $png
}

function Read-ClaudeOutput {
    if (-not $script:Claude) { return }
    $line = $null
    $count = 0
    while ($count -lt 400 -and $script:Claude.Lines.TryDequeue([ref]$line)) {
        $count++
        $ev = ConvertFrom-ClaudeLine $line
        if ($env:CLAUDEWHISPER_DEBUG) { Write-WhisperLog ("claude> " + $line.Substring(0, [Math]::Min(120, $line.Length)) + " => " + $(if ($ev) { $ev.Kind } else { '-' }) + " turns=" + $script:Turns.Count) }
        if (-not $ev) { continue }
        $turn = if ($script:Turns.Count -gt 0) { $script:Turns[0] } else { $null }
        switch ($ev.Kind) {
            'init' {
                if ($ev.ApiKeySource -and $ev.ApiKeySource -ne 'none') { Write-WhisperLog "warning: claude uses $($ev.ApiKeySource), not the subscription" }
            }
            'block' {
                # A new text block in the same turn (after thinking): keep paragraphs apart.
                if ($turn -and $turn.Answer -and $turn.Answer.Text -and $turn.Answer.State -eq 'streaming') { $turn.Answer.Text += "`n`n" }
            }
            'delta' {
                if ($turn -and $turn.Answer -and $turn.Answer.State -in 'waiting', 'streaming') {
                    $turn.Answer.Text += $ev.Text
                    $turn.Answer.State = 'streaming'
                    $script:AnswerDirty = $true
                }
            }
            'result' {
                if (-not $turn) { break }
                $script:Turns.RemoveAt(0)
                $a = $turn.Answer
                if (-not $a) { break }
                if ($a.State -in 'waiting', 'streaming') {
                    if ($ev.Text) { $a.State = 'error'; $a.Error = $ev.Text } else { $a.State = 'done' }
                }
                $script:AnswerDirty = $true
                if ($a.Text) { Add-SessionLog ("### Claude " + [char]0x00B7 + ' ' + $a.Title + "`n`n" + $a.Text.Trim()) }
                Send-QueuedAnswer
            }
        }
    }
    if ($script:Claude.HasExited) {
        $why = $script:Claude.LastErrors()
        Write-WhisperLog "claude exited: $why"
        foreach ($turn in $script:Turns) { if ($turn.Answer -and $turn.Answer.State -in 'waiting', 'streaming') { $turn.Answer.State = 'error'; $turn.Answer.Error = Tx 'Claude Code se cerr\u00f3.' } }
        $script:Turns.Clear()
        $script:Claude.Kill()
        $script:Claude = $null
        $script:AnswerDirty = $true
        if ($why -match 'login|auth|401') { $script:Problem = Tx 'Claude Code no tiene la sesi\u00f3n iniciada: abre Claude Code e inicia sesi\u00f3n.' }
    }
}

# ---------------------------------------------------------------- interpreter

function Start-Interpreter {
    Stop-Interpreter
    $exe = Resolve-ClaudeExe
    if (-not $exe) { return $false }
    $promptFile = Join-Path $WhisperHome 'interpreter-prompt.txt'
    [IO.File]::WriteAllText($promptFile, (New-WhisperInterpreterPrompt $script:Settings), (New-Object System.Text.UTF8Encoding($false)))
    $process = New-Object ClaudeWhisper.ClaudeProcess
    try {
        $process.Start($exe, (Get-ClaudeArguments 'haiku' $promptFile), $WhisperHome, [string[]](Get-ClaudeRemovedEnv), [string[]](Get-ClaudeExtraEnv))
    } catch {
        Write-WhisperLog "interpreter start failed: $($_.Exception.Message)"
        return $false
    }
    $script:Interp = $process
    $script:InterpTurns = 0
    Write-WhisperLog "interpreter started pid=$($process.Pid)"
    $true
}

function Stop-Interpreter {
    if ($script:Interp) { $script:Interp.Kill(); $script:Interp = $null }
    $script:InterpInFlight = $null
    $script:InterpText = ''
}

# One batch at a time: lines that arrive meanwhile go together in the next one. The process is replaced
# every 25 batches so its history (and the cost of each turn) stays small in a long call.
function Send-Interpretation {
    if ($script:InterpInFlight -or $script:InterpQueue.Count -eq 0) { return }
    if (-not ($script:Settings.translate -or $script:Settings.autoAnswer)) { $script:InterpQueue.Clear(); return }
    if (-not $script:Interp -or $script:Interp.HasExited -or $script:InterpTurns -ge 25) {
        if (-not (Start-Interpreter)) { $script:InterpQueue.Clear(); return }
    }
    $batch = @()
    foreach ($line in @($script:InterpQueue | Select-Object -Last 6)) {
        $batch += @{ Index = $script:InterpNext; Line = $line; Text = $line.Text }
        $script:InterpNext++
    }
    $script:InterpQueue.Clear()
    $script:InterpInFlight = $batch
    $script:InterpText = ''
    $script:InterpSentAt = Get-Date
    $script:InterpTurns++
    if (-not $script:Interp.Send((ConvertTo-ClaudeInputLine (New-WhisperInterpretRequest $batch) ''))) { Stop-Interpreter }
}

function Read-InterpreterOutput {
    if (-not $script:Interp) { return }
    $line = $null
    $count = 0
    while ($count -lt 400 -and $script:Interp -and $script:Interp.Lines.TryDequeue([ref]$line)) {
        $count++
        $ev = ConvertFrom-ClaudeLine $line
        if (-not $ev) { continue }
        if ($ev.Kind -eq 'delta') { $script:InterpText += $ev.Text }
        elseif ($ev.Kind -eq 'result') { Complete-Interpretation }
    }
    if ($script:Interp -and $script:Interp.HasExited) {
        Write-WhisperLog "interpreter exited: $($script:Interp.LastErrors())"
        Stop-Interpreter
    } elseif ($script:InterpInFlight -and ((Get-Date) - $script:InterpSentAt).TotalSeconds -gt 25) {
        Write-WhisperLog 'interpreter timed out'
        Stop-Interpreter
    }
}

function Complete-Interpretation {
    $batch = $script:InterpInFlight
    $script:InterpInFlight = $null
    if (-not $batch) { return }
    $parsed = ConvertFrom-WhisperInterpretation $script:InterpText
    if ($parsed.Count -eq 0 -and $env:CLAUDEWHISPER_DEBUG) { Write-WhisperLog ('interpreter said: ' + $script:InterpText) }
    foreach ($item in $batch) {
        $r = $parsed[$item.Index]
        if (-not $r) { continue }
        $translation = $r.Translation
        # Same words back means it was already in the user's language.
        if ($translation -and ((ConvertTo-PlainWords $translation) -join ' ') -ne ((ConvertTo-PlainWords $item.Text) -join ' ')) {
            $item.Line.Translation = $translation
            $script:TranscriptFull = $true
            Add-SessionLog ([string][char]0x21B3 + ' ' + $translation)
        }
        if ($r.Question -and $script:Settings.autoAnswer) { Request-AutoAnswer $r.Question }
    }
}

# ---------------------------------------------------------------- answering on its own

function Test-AnswerBusy {
    foreach ($turn in $script:Turns) { if ($turn.Answer -and $turn.Answer.State -in 'waiting', 'streaming') { return $true } }
    $false
}

# A question heard (in a final line, in text still being spoken, or found by the interpreter). The same
# question is answered once; while an answer is being written the new one waits its turn (newest two kept),
# so a song full of questions does not cut every answer off.
function Request-AutoAnswer([string]$Question) {
    $q = ([string]$Question).Trim()
    # A word or two is a fragment of a cut line ("slow."), not something to answer.
    if ($q.Length -lt 8 -or @(ConvertTo-PlainWords $q).Count -lt 3) { return }
    foreach ($done in $script:Asked) { if (Test-WhisperSameQuestion $done $q) { return } }
    [void]$script:Asked.Add($q)
    while ($script:Asked.Count -gt 40) { $script:Asked.RemoveAt(0) }
    if ($q.Length -gt 500) { $q = $q.Substring($q.Length - 500) }
    if (Test-AnswerBusy) {
        [void]$script:AnswerQueue.Add($q)
        while ($script:AnswerQueue.Count -gt 2) { $script:AnswerQueue.RemoveAt(0) }
        return
    }
    Request-Answer $q
}

function Send-QueuedAnswer {
    if ($script:AnswerQueue.Count -eq 0 -or (Test-AnswerBusy)) { return }
    $q = $script:AnswerQueue[0]
    $script:AnswerQueue.RemoveAt(0)
    Request-Answer $q
}

# ---------------------------------------------------------------- listening

function Start-Listening {
    if ($script:Listening) { return }
    $script:Problem = ''
    if (-not $script:Claude) { [void](Start-Claude) }
    $credentials = $CredsFile
    if (-not (Test-Path -LiteralPath $credentials)) { $script:Problem = Tx 'Claude Code no tiene la sesi\u00f3n iniciada: abre Claude Code e inicia sesi\u00f3n.' }
    $terms = Get-WhisperKeyterms $script:Settings
    if ($Testing) { $script:Engine.StartSimulation($SimulateWav, $script:Settings.language, $terms, $credentials) }
    else { $script:Engine.Start($script:Settings.language, $terms, $script:Settings.useMic, $script:Settings.gateMic, $credentials) }
    $script:Listening = $true
    Write-WhisperLog "listening language=$($script:Settings.language) mic=$($script:Settings.useMic)"
    Update-Controls
}

function Stop-Listening {
    if (-not $script:Listening) { return }
    $script:Engine.Stop()
    $script:Listening = $false
    $script:StreamState = @{ them = ''; me = '' }
    Read-EngineEvents
    Update-Controls
}

function Read-EngineEvents {
    $item = $null
    $count = 0
    $now = Get-Date
    while ($count -lt 400 -and $script:Engine.Events.TryDequeue([ref]$item)) {
        $count++
        $parts = $item.Split([char[]]@("`t"), 3)
        if ($parts.Count -lt 3) { continue }
        $source = $parts[0]; $kind = $parts[1]; $text = $parts[2]
        switch ($kind) {
            'interim' {
                [void](Update-WhisperTranscript $script:Transcript $source 'interim' $text $now)
                if ($source -eq 'them' -and $script:PendingThem.Count -gt 0) { $script:AnswerDueAt = $now.AddMilliseconds(1200) }
                if ($source -eq 'them' -and $script:Settings.autoAnswer) { foreach ($q in (Get-WhisperOpenQuestions $text)) { Request-AutoAnswer $q } }
                $script:TranscriptDirty = $true
            }
            'final' {
                if ($source -eq 'me') {
                    $recent = @($script:Transcript.Lines | Where-Object { $_.Source -eq 'them' -and ($now - $_.At).TotalSeconds -lt 15 } | ForEach-Object { $_.Text })
                    if ($script:Transcript.Open.them) { $recent += $script:Transcript.Open.them }
                    if (Test-WhisperEcho $text $recent) { $script:Transcript.Open.me = ''; $script:TranscriptDirty = $true; continue }
                }
                $line = Update-WhisperTranscript $script:Transcript $source 'final' $text $now
                $script:TranscriptDirty = $true
                if (-not $line) { continue }
                Add-SessionLog (Format-WhisperLogLine $line)
                if ($source -eq 'them') {
                    [void]$script:PendingThem.Add($line.Text)
                    $script:AnswerDueAt = $now.AddMilliseconds(700)
                    if ($script:Settings.translate -or $script:Settings.autoAnswer) { [void]$script:InterpQueue.Add($line) }
                }
            }
            'status' { $script:StreamState[$source] = $text; if ($text -eq 'open' -and $script:Problem -like '*sesi*') { $script:Problem = '' } }
            'error' {
                Write-WhisperLog "$source error: $text"
                if ($text -like 'language*') {
                    $script:StreamState[$source] = 'error'
                    $script:Problem = Tx 'El servicio de transcripci\u00f3n no acepta ese idioma: elige otro en Contexto.'
                } elseif ($text -eq 'auth') {
                    $script:StreamState[$source] = 'auth'
                    Request-LoginRefresh 'speech service refused the login'
                } else { $script:StreamState[$source] = 'error' }
            }
            'device' {
                if ($text -like 'device-error*') { $script:StreamState[$source] = 'device'; Write-WhisperLog "$source $text" }
            }
        }
    }
}

# Answers on its own once the other side stops talking and what they said was a question.
function Test-AutoAnswer {
    if ((Get-Date) -lt $script:AnswerDueAt) { return }
    $script:AnswerDueAt = [datetime]::MaxValue
    $fresh = @($script:PendingThem | Select-Object -Skip $script:PendingChecked)
    $script:PendingChecked = $script:PendingThem.Count
    $said = ($fresh -join ' ').Trim()
    if (-not $said) { return }
    # Lines without a question mark in other languages are left to the interpreter.
    if ($script:Settings.autoAnswer -and (Test-WhisperQuestion $said)) { Request-AutoAnswer (Get-WhisperQuestionText $fresh) }
}

# ---------------------------------------------------------------- window

$script:Form = New-Object System.Windows.Forms.Form
$Form = $script:Form
$Form.Text = 'Claude Whisper'
$Form.BackColor = $P.Back
$Form.ForeColor = $P.Text
$Form.Font = $script:Fonts.Body
$Form.StartPosition = 'Manual'
$Form.ShowInTaskbar = $true
$Form.TopMost = [bool]$script:Settings.topMost
$Form.Opacity = 1.0
$Form.KeyPreview = $true
$Form.MinimumSize = New-Object System.Drawing.Size((Px 380), (Px 420))
try { $Form.Icon = Get-TrayIcon } catch { }
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$bounds = $script:Settings.bounds
if ($bounds -and $bounds.w -gt 200 -and $bounds.h -gt 200 -and
    [System.Windows.Forms.Screen]::AllScreens.Where({ $_.WorkingArea.IntersectsWith((New-Rect $bounds.x $bounds.y $bounds.w $bounds.h)) }).Count -gt 0) {
    $Form.Bounds = New-Rect $bounds.x $bounds.y $bounds.w $bounds.h
} else {
    $w = Px 470; $h = [Math]::Min((Px 760), $area.Height - (Px 24))
    $Form.Bounds = New-Rect ($area.Right - $w - (Px 12)) ($area.Top + (Px 12)) $w $h
}
$Form.Add_HandleCreated({ Set-WhisperTitleBar $script:Form $script:Palette $script:LightTheme })

# ---- header: status + level meters (owner-drawn) and the buttons
$header = New-Object System.Windows.Forms.TableLayoutPanel
$header.Dock = 'Top'
$header.AutoSize = $true
$header.ColumnCount = 1
$header.Padding = New-Object System.Windows.Forms.Padding((Px 10), (Px 6), (Px 10), 0)
$header.BackColor = $P.Back

$script:StatusPanel = New-Object System.Windows.Forms.Panel
$StatusPanel = $script:StatusPanel
$StatusPanel.Dock = 'Fill'
$StatusPanel.Height = Px 30
$StatusPanel.Margin = New-Object System.Windows.Forms.Padding(0)
Enable-DoubleBuffer $StatusPanel

function Get-StatusLine {
    if ($script:Problem) { return @{ Text = $script:Problem; Color = $P.Error } }
    if (-not $script:Listening) { return @{ Text = (Tx 'En pausa'); Color = $P.Faint } }
    $states = @($script:StreamState.them)
    if ($script:Settings.useMic -and -not $Testing) { $states += $script:StreamState.me }
    if ($states -contains 'auth') { return @{ Text = (Tx 'Inicia sesi\u00f3n en Claude Code para transcribir'); Color = $P.Error } }
    if ($states -contains 'device') { return @{ Text = (Tx 'No puedo abrir el audio (altavoces o micr\u00f3fono)'); Color = $P.Error } }
    if ($states -contains 'error' -or $states -contains 'closed') { return @{ Text = (Tx 'Reconectando la transcripci\u00f3n...'); Color = $P.Warn } }
    if ($states -contains 'connecting' -or $states -contains '') { return @{ Text = 'Conectando...'; Color = $P.Warn } }
    @{ Text = 'Escuchando'; Color = $P.Ok }
}

$StatusPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $sender.ClientSize.Width
    $status = Get-StatusLine
    $dot = Px 9
    $brush = New-Object System.Drawing.SolidBrush($status.Color)
    $g.FillEllipse($brush, 0, [int](($sender.Height - $dot) / 2), $dot, $dot)
    $brush.Dispose()
    $meterW = Px 54
    $metersW = 2 * ($meterW + (Px 44))
    Draw-Text $g $status.Text $script:Fonts.BodyStrong $P.Text ($dot + (Px 8)) 0 ($w - $metersW - $dot - (Px 12)) $sender.Height
    $x = $w - $metersW
    foreach ($m in @(@('Ellos', $script:Engine.SystemLevel, $P.Accent), @((Tx 'T\u00fa'), $script:Engine.MicLevel, $P.Ok))) {
        Draw-Text $g $m[0] $script:Fonts.Small $P.Muted $x 0 (Px 40) $sender.Height 'Right'
        $track = New-Rect ($x + (Px 44)) ([int]($sender.Height / 2) - (Px 3)) $meterW (Px 6)
        Fill-Round $g $track (Px 3) $P.Track
        $level = [Math]::Min(1.0, [Math]::Sqrt([double]$m[1]) * 2.2)
        if ($script:Listening -and $level -gt 0.03) {
            Fill-Round $g (New-Rect $track.X $track.Y ([Math]::Max((Px 6), [int]($meterW * $level))) $track.Height) (Px 3) $m[2]
        }
        $x += $meterW + (Px 44)
    }
})
[void]$header.Controls.Add($StatusPanel, 0, 0)

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'
$buttons.AutoSize = $true
$buttons.WrapContents = $true
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, (Px 2))
$script:ListenButton = New-WhisperButton 'Escuchar' $P $true
$script:AnswerButton = New-WhisperButton 'Responder' $P
$script:ScreenButton = New-WhisperButton 'Pantalla' $P
$script:ContextButton = New-WhisperButton 'Contexto' $P
$script:AutoButton = New-WhisperButton 'Auto' $P
$script:TranslateButton = New-WhisperButton 'Traducir' $P
$script:MoreButton = New-WhisperButton ([string][char]0x22EF) $P
foreach ($b in $script:ListenButton, $script:AnswerButton, $script:ScreenButton, $script:ContextButton, $script:MoreButton) { $buttons.Controls.Add($b) }
[void]$header.Controls.Add($buttons, 0, 1)
# Second row: the two switches that decide what happens on its own.
$toggles = New-Object System.Windows.Forms.FlowLayoutPanel
$toggles.Dock = 'Fill'
$toggles.AutoSize = $true
$toggles.WrapContents = $true
$toggles.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 4))
foreach ($b in $script:AutoButton, $script:TranslateButton) {
    $b.Font = $script:Fonts.Small
    $b.Margin = New-Object System.Windows.Forms.Padding((Px 2), 0, (Px 4), 0)
    $toggles.Controls.Add($b)
}
[void]$header.Controls.Add($toggles, 0, 2)

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($script:AnswerButton, (Tx 'Que Claude responda ahora a lo \u00faltimo que dijeron'))
$tips.SetToolTip($script:ScreenButton, (Tx 'Claude mira tu pantalla (por ejemplo un ejercicio de programaci\u00f3n) y lo resuelve'))
$tips.SetToolTip($script:ContextButton, (Tx 'Tu perfil, la conversaci\u00f3n, el idioma y el modelo'))
$tips.SetToolTip($script:AutoButton, (Tx 'Responder solo cuando detecte una pregunta, en cualquier idioma (tambi\u00e9n en una canci\u00f3n)'))
$tips.SetToolTip($script:TranslateButton, (Tx 'Traducir en vivo a tu idioma lo que suena en el PC'))

$more = New-Object System.Windows.Forms.ContextMenuStrip
$script:TopMostItem = New-Object System.Windows.Forms.ToolStripMenuItem('Siempre visible')
$script:TopMostItem.Checked = [bool]$script:Settings.topMost
$script:TopMostItem.Add_Click({
    $script:Settings.topMost = -not [bool]$script:Settings.topMost
    $script:Form.TopMost = [bool]$script:Settings.topMost
    $script:TopMostItem.Checked = [bool]$script:Settings.topMost
    Save-WhisperSettings
})
[void]$more.Items.Add($script:TopMostItem)
[void]$more.Items.Add('Historial de llamadas', $null, {
    if (-not (Test-Path -LiteralPath $WhisperSessionsDir)) { New-Item -ItemType Directory -Force -Path $WhisperSessionsDir | Out-Null }
    Start-Process explorer.exe $WhisperSessionsDir
})
[void]$more.Items.Add((Tx 'Nueva conversaci\u00f3n (olvidar lo anterior)'), $null, { Reset-Conversation })
[void]$more.Items.Add('-')
[void]$more.Items.Add('Cerrar Claude Whisper', $null, { $script:Form.Close() })
$script:MoreButton.Add_Click({ $more.Show($script:MoreButton, 0, $script:MoreButton.Height) })

# ---- body: transcript above, answer below
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.BackColor = $P.Border
$split.SplitterWidth = Px 5
$split.Panel1.BackColor = $P.Back
$split.Panel2.BackColor = $P.Back
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding((Px 12), 0, (Px 8), (Px 4))
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding((Px 12), 0, (Px 8), (Px 4))

$script:TranscriptBox = New-WhisperTextView $P $WF.Line
$split.Panel1.Controls.Add($script:TranscriptBox)
$split.Panel1.Controls.Add((New-WhisperCaption (Tx 'TRANSCRIPCI\u00d3N') $P))

$answerHead = New-Object System.Windows.Forms.TableLayoutPanel
$answerHead.Dock = 'Top'
$answerHead.Height = Px 32
$answerHead.ColumnCount = 4
[void]$answerHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$answerHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$answerHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$answerHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$answerCaption = New-WhisperCaption 'CLAUDE' $P
$answerCaption.Dock = 'Fill'; $answerCaption.AutoSize = $true; $answerCaption.TextAlign = 'MiddleLeft'
$script:AnswerNav = New-Object System.Windows.Forms.Label
$script:AnswerNav.Dock = 'Fill'; $script:AnswerNav.TextAlign = 'MiddleRight'; $script:AnswerNav.ForeColor = $P.Muted
$script:AnswerNav.Font = $script:Fonts.Small
$script:PrevButton = New-WhisperButton ([string][char]0x2039) $P
$script:NextButton = New-WhisperButton ([string][char]0x203A) $P
foreach ($b in $script:PrevButton, $script:NextButton) {
    $b.Margin = New-Object System.Windows.Forms.Padding((Px 2), (Px 1), 0, (Px 1))
    $b.MinimumSize = New-Object System.Drawing.Size((Px 30), (Px 26))
}
$answerHead.Controls.Add($answerCaption, 0, 0)
$answerHead.Controls.Add($script:AnswerNav, 1, 0)
$answerHead.Controls.Add($script:PrevButton, 2, 0)
$answerHead.Controls.Add($script:NextButton, 3, 0)
$script:AnswerBox = New-WhisperTextView $P $WF.Answer
$split.Panel2.Controls.Add($script:AnswerBox)
$split.Panel2.Controls.Add($answerHead)

# ---- footer: ask box and hints
$footer = New-Object System.Windows.Forms.TableLayoutPanel
$footer.Dock = 'Bottom'
$footer.AutoSize = $true
$footer.ColumnCount = 1
$footer.Padding = New-Object System.Windows.Forms.Padding((Px 10), (Px 4), (Px 10), (Px 6))
$footer.BackColor = $P.Back
$script:AskBox = New-Object System.Windows.Forms.TextBox
$script:AskBox.Dock = 'Fill'
$script:AskBox.BackColor = $P.Surface
$script:AskBox.ForeColor = $P.Text
$script:AskBox.BorderStyle = 'FixedSingle'
$script:AskBox.Font = $WF.Line
$footer.Controls.Add($script:AskBox, 0, 0)
$script:HintLabel = New-Object System.Windows.Forms.Label
$script:HintLabel.Dock = 'Fill'
$script:HintLabel.AutoSize = $true
$script:HintLabel.ForeColor = $P.Muted
$script:HintLabel.Font = $script:Fonts.Small
$script:HintLabel.UseMnemonic = $false
$script:HintLabel.Margin = New-Object System.Windows.Forms.Padding(0, (Px 4), 0, 0)
$footer.Controls.Add($script:HintLabel, 0, 1)
$footer.Add_Resize({ $script:HintLabel.MaximumSize = New-Object System.Drawing.Size(($this.ClientSize.Width - (Px 20)), 0) })

$Form.Controls.Add($split)
$Form.Controls.Add($footer)
$Form.Controls.Add($header)

function Update-Controls {
    $script:ListenButton.Text = if ($script:Listening) { 'Pausar' } else { 'Escuchar' }
    $check = [string][char]0x2713 + ' '
    $script:AutoButton.Text = $(if ($script:Settings.autoAnswer) { $check } else { '' }) + (Tx 'Responder autom\u00e1ticamente')
    $script:TranslateButton.Text = $(if ($script:Settings.translate) { $check } else { '' }) + 'Traducir en vivo'
    Set-WhisperButtonStyle $script:AutoButton $P ([bool]$script:Settings.autoAnswer)
    Set-WhisperButtonStyle $script:TranslateButton $P ([bool]$script:Settings.translate)
    Set-WhisperButtonStyle $script:ListenButton $P (-not $script:Listening)
    $model = $script:WhisperModels[$script:Settings.model] -replace ' \(.*\)$', ''
    $auto = if ($script:Settings.autoAnswer) { Tx 'responde a las preguntas' } else { 'responde con el atajo' }
    $text = "$model $([char]0x00B7) $auto"
    $keys = @($script:Settings.hotkeyAnswer, $script:Settings.hotkeyScreen, $script:Settings.hotkeyToggle)
    $prefixes = @($keys | ForEach-Object { $_ -replace '\+[^+]+$', '' } | Select-Object -Unique)
    if ($prefixes.Count -eq 1 -and $prefixes[0]) {
        $last = @($keys | ForEach-Object { ($_ -split '\+')[-1] })
        $text += "`n" + ('{0} + {1} responder, {2} pantalla, {3} ocultar' -f $prefixes[0], $last[0], $last[1], $last[2])
    } else {
        $text += "`n" + ('{0} responder, {1} pantalla, {2} ocultar' -f $keys[0], $keys[1], $keys[2])
    }
    if ($script:HotkeyProblem) { $text += "`n" + $script:HotkeyProblem }
    if ($script:MicUsers) { $text += "`n" + (Tx 'Micr\u00f3fono en uso por: ') + $script:MicUsers }
    $script:HintLabel.Text = $text
    $script:StatusPanel.Invalidate()
}

# ---- rendering

function Render-Transcript {
    $box = $script:TranscriptBox
    $lines = $script:Transcript.Lines
    Suspend-Redraw $box
    try {
        # A translation arrived for a line already shown: draw everything again (the newest 300 lines).
        if ($script:TranscriptFull) {
            $script:TranscriptFull = $false
            $box.Clear()
            $script:OpenStart = 0
            $script:RenderedLines = [Math]::Max(0, $lines.Count - 300)
        }
        if ($script:OpenStart -lt $box.TextLength) {
            $box.SelectionStart = $script:OpenStart
            $box.SelectionLength = $box.TextLength - $script:OpenStart
            $box.ReadOnly = $false; $box.SelectedText = ''; $box.ReadOnly = $true
        }
        for ($i = $script:RenderedLines; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $color = if ($line.Source -eq 'me') { $P.Ok } else { $P.Accent }
            if ($box.TextLength -gt 0) { Add-RichText $box "`n" $WF.Line $P.Text }
            Add-RichText $box ((Format-WhisperSpeaker $line.Source) + '  ') $WF.LineStrong $color
            Add-RichText $box $line.Text $WF.Line $P.Text
            if ($line.Translation) { Add-RichText $box ("`n" + [char]0x21B3 + ' ' + $line.Translation) $WF.Line $P.Muted }
        }
        $script:RenderedLines = $lines.Count
        $script:OpenStart = $box.TextLength
        foreach ($source in 'them', 'me') {
            $open = $script:Transcript.Open[$source]
            if (-not $open) { continue }
            if ($box.TextLength -gt 0) { Add-RichText $box "`n" $WF.Line $P.Text }
            Add-RichText $box ((Format-WhisperSpeaker $source) + '  ') $WF.LineStrong $P.Faint
            Add-RichText $box $open $WF.Line $P.Muted
        }
        if ($box.TextLength -eq 0) {
            $hint = if ($script:Listening) { Tx 'Cuando alguien hable en la llamada, aparece aqu\u00ed.' } else { Tx 'Pulsa Escuchar al empezar la llamada. Claude Whisper oye lo que suena en el PC (la otra parte) y tu micr\u00f3fono.' }
            Add-RichText $box $hint $WF.Line $P.Faint
            $script:OpenStart = 0
        }
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.ScrollToCaret()
    } finally { Resume-Redraw $box }
}

function Render-Answer {
    $box = $script:AnswerBox
    Suspend-Redraw $box
    try {
        $box.Clear()
        $count = $script:Answers.Count
        $script:PrevButton.Enabled = $script:AnswerIndex -gt 0
        $script:NextButton.Enabled = $script:AnswerIndex -lt $count - 1
        if ($count -eq 0) {
            $script:AnswerNav.Text = ''
            $text = Tx 'Cuando te hagan una pregunta, la respuesta sugerida aparece aqu\u00ed. Tambi\u00e9n puedes pulsar Responder, mandar tu pantalla o escribirle a Claude abajo.'
            Add-RichText $box $text $WF.Line $P.Faint
            return
        }
        $a = $script:Answers[$script:AnswerIndex]
        $script:AnswerNav.Text = '{0}/{1}  {2}' -f ($script:AnswerIndex + 1), $count, $a.At.ToString('HH:mm')
        $title = [string]$a.Title
        if ($title.Length -gt 220) { $title = [string][char]0x2026 + $title.Substring($title.Length - 220) }
        Add-RichText $box ($title + "`n") $WF.Question $P.Muted
        if ($a.Text) { Add-RichText $box "`n" $WF.Line $P.Text; Write-RichMarkdown $box $a.Text.Trim() $WF $P }
        $note = switch ($a.State) {
            'waiting' { Tx "`nPensando\u2026" }
            'interrupted' { Tx "`n(cortada por una pregunta nueva)" }
            'stopped' { Tx "`n(detenida)" }
            'error' { "`n" + $(if ($a.Error) { $a.Error } else { Tx 'Claude no pudo responder.' }) }
            default { '' }
        }
        if ($note) { Add-RichText $box ("`n" + $note.TrimStart("`n")) $WF.Line $(if ($a.State -eq 'error') { $P.Error } else { $P.Faint }) }
        $box.SelectionStart = 0
        $box.SelectionLength = 0
        $box.ScrollToCaret()
    } finally { Resume-Redraw $box }
}

function Reset-Conversation {
    Stop-Claude
    Stop-Interpreter
    $script:InterpQueue.Clear()
    $script:Asked.Clear()
    $script:AnswerQueue.Clear()
    $script:PendingChecked = 0
    $script:Answers.Clear()
    $script:AnswerIndex = -1
    $script:Transcript = New-WhisperTranscript
    $script:PendingThem.Clear()
    $script:AnswerDueAt = [datetime]::MaxValue
    $script:RenderedLines = 0
    $script:OpenStart = 0
    $script:TranscriptBox.Clear()
    $script:SessionFile = $null
    $script:TranscriptDirty = $true
    $script:AnswerDirty = $true
    [void](Start-Claude)
}

# ---- actions

$script:ListenButton.Add_Click({ if ($script:Listening) { Stop-Listening } else { Start-Listening } })
$script:AnswerButton.Add_Click({ Request-AnswerNow })
$script:AutoButton.Add_Click({ $script:Settings.autoAnswer = -not [bool]$script:Settings.autoAnswer; Save-WhisperSettings; Update-Controls })
$script:TranslateButton.Add_Click({ $script:Settings.translate = -not [bool]$script:Settings.translate; Save-WhisperSettings; Update-Controls })
$script:ScreenButton.Add_Click({ Request-Screen })
$script:PrevButton.Add_Click({ if ($script:AnswerIndex -gt 0) { $script:AnswerIndex--; $script:AnswerDirty = $true } })
$script:NextButton.Add_Click({ if ($script:AnswerIndex -lt $script:Answers.Count - 1) { $script:AnswerIndex++; $script:AnswerDirty = $true } })
$script:ContextButton.Add_Click({
    $updated = Show-WhisperContextDialog $script:Settings $script:Palette $script:Form
    if (-not $updated) { return }
    $restartEngine = $script:Listening -and ($updated.language -ne $script:Settings.language -or $updated.useMic -ne $script:Settings.useMic -or
        $updated.gateMic -ne $script:Settings.gateMic -or $updated.keyterms -ne $script:Settings.keyterms -or $updated.profile -ne $script:Settings.profile)
    $script:Settings = $updated
    Save-WhisperSettings
    # The context is Claude's system prompt: a new claude process picks it up (the transcript so far is
    # sent again with the next question).
    $script:Transcript.Sent = [Math]::Max(0, $script:Transcript.Lines.Count - 40)
    [void](Start-Claude)
    Stop-Interpreter
    if ($restartEngine) { Stop-Listening; Start-Listening }
    Update-Controls
})
$script:AskBox.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true
        $text = $script:AskBox.Text
        $script:AskBox.Text = ''
        Request-Ask $text
    }
})

# ---- hotkeys
$script:HotkeyProblem = ''
$script:Hotkeys = $null
$script:HotkeyActions = @{ 1 = { Request-AnswerNow }; 2 = { Request-Screen }; 3 = { Switch-WhisperWindow } }
function Register-WhisperHotkeys {
    $script:Hotkeys = New-Object ClaudeWhisper.Hotkeys
    $failed = @()
    $map = @{ 1 = $script:Settings.hotkeyAnswer; 2 = $script:Settings.hotkeyScreen; 3 = $script:Settings.hotkeyToggle }
    foreach ($id in 1, 2, 3) {
        $hk = ConvertFrom-WhisperHotkey $map[$id]
        if (-not $hk -or -not $script:Hotkeys.Register($id, [uint32]$hk.Mods, [uint32]$hk.Key)) { $failed += $map[$id] }
    }
    if ($failed.Count -gt 0) {
        $script:HotkeyProblem = (Tx 'Atajo ocupado por otra app: ') + ($failed -join ', ')
        Write-WhisperLog "hotkeys not registered: $($failed -join ', ')"
    }
}

function Switch-WhisperWindow {
    if ($script:Form.Visible -and $script:Form.WindowState -ne 'Minimized') { $script:Form.Hide(); return }
    Show-WhisperWindow
}

function Show-WhisperWindow {
    $script:Form.Show()
    if ($script:Form.WindowState -eq 'Minimized') { $script:Form.WindowState = 'Normal' }
    $script:Form.Activate()
}

# ---- timer: drains the native queues and repaints
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 60
$script:Timer.Add_Tick({
    $script:Ticks++
    Read-EngineEvents
    Read-ClaudeOutput
    Test-AutoAnswer
    if ($script:Hotkeys) {
        $id = 0
        while ($script:Hotkeys.Pressed.TryDequeue([ref]$id)) { if ($script:HotkeyActions.ContainsKey($id)) { & $script:HotkeyActions[$id] } }
    }
    if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) { Show-WhisperWindow }
    Read-InterpreterOutput
    Send-Interpretation
    if ($script:TranscriptFull) { $script:TranscriptDirty = $true }
    if ($script:TranscriptDirty) { $script:TranscriptDirty = $false; Render-Transcript }
    if ($script:AnswerDirty -and ($script:Ticks % 2 -eq 0)) { $script:AnswerDirty = $false; Render-Answer }
    if ($script:Ticks % 3 -eq 0) { $script:StatusPanel.Invalidate() }
    if ($script:Ticks % 80 -eq 0 -and -not $Testing) {
        $users = ([ClaudeWhisper.AudioCapture]::MicrophoneUsers() | Where-Object { $_ -notin 'powershell', 'audiodg' }) -join ', '
        if ($users -ne $script:MicUsers) { $script:MicUsers = $users; Update-Controls }
    }
    if ($script:Listening -and $script:Ticks % 1000 -eq 0) {
        $expiry = Get-ClaudeLoginExpiry $CredsFile
        if ($expiry -and $expiry -lt (Get-Date).AddMinutes(5)) { Request-LoginRefresh 'login about to expire' }
    }
    if ($ExitAfter -gt 0 -and ((Get-Date) - $script:StartedAt).TotalSeconds -ge $ExitAfter) { $script:Form.Close() }
})

$Form.Add_FormClosing({
    $script:Timer.Stop()
    if (-not $Rendering -and -not $Testing -and $script:Form.WindowState -eq 'Normal') {
        $b = $script:Form.Bounds
        $script:Settings.bounds = [ordered]@{ x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height }
        Save-WhisperSettings
    }
    if ($ReportTo) {
        $report = [ordered]@{
            transcript = @($script:Transcript.Lines | ForEach-Object { [ordered]@{ source = $_.Source; text = $_.Text; translation = $_.Translation } })
            answers    = @($script:Answers | ForEach-Object { [ordered]@{ kind = $_.Kind; title = $_.Title; state = $_.State; text = $_.Text; error = $_.Error } })
            problem    = $script:Problem
            streams    = $script:StreamState
        }
        try { Write-JsonFile $ReportTo $report } catch { }
    }
    $script:Engine.Stop()
    Stop-Claude
    Stop-Interpreter
    if ($script:Hotkeys) { $script:Hotkeys.Dispose() }
})

# ---------------------------------------------------------------- render mode (layout check)

if ($Rendering) {
    $now = Get-Date
    foreach ($sample in @(
        @('them', (Tx 'Gracias por venir. Para empezar, \u00bfpodr\u00edas contarnos de un proyecto dif\u00edcil y c\u00f3mo lo resolviste?')),
        @('me', (Tx 'Claro, d\u00e9jame pensar un segundo.')),
        @('them', (Tx '\u00bfY qu\u00e9 papel tuviste t\u00fa en el equipo?'))
    )) { [void](Update-WhisperTranscript $script:Transcript $sample[0] 'final' $sample[1] $now) }
    $sample = Update-WhisperTranscript $script:Transcript 'them' 'final' 'And how would you scale it to ten times the traffic?' $now
    $sample.Translation = Tx '\u00bfY c\u00f3mo lo escalar\u00edas a diez veces el tr\u00e1fico?'
    $script:Transcript.Open.them = Tx 'Tambi\u00e9n nos interesa saber c\u00f3mo'
    $script:Listening = $true
    $script:StreamState = @{ them = 'open'; me = 'open' }
    [void]$script:Answers.Add(@{ Kind = 'answer'; Title = (Tx '\u00bfY qu\u00e9 papel tuviste t\u00fa en el equipo?'); State = 'done'; At = $now; Error = ''
        Text = (Tx "Lider\u00e9 la migraci\u00f3n del sistema de pagos a Kubernetes: defin\u00ed la arquitectura y coordin\u00e9 a cuatro personas.`n`n- **Dise\u00f1o:** separ\u00e9 el monolito en tres servicios con colas entre ellos.`n- **Resultado:** bajamos la latencia un 40 % y no hubo ca\u00eddas en el cambio.`n- Si quieren detalle t\u00e9cnico, puedo contar c\u00f3mo hicimos el despliegue blue-green.") })
    $script:AnswerIndex = 0
    # Rich text boxes do not support DrawToBitmap, so the window is shown for a moment and copied from the screen.
    $Form.TopMost = $true
    Update-Controls
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $split.SplitterDistance = [int]($split.Height * 0.42)
    Render-Transcript
    Render-Answer
    $Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.Application]::DoEvents()
    $b = $Form.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
    $g.Dispose()
    $bmp.Save($RenderTo)
    $script:Engine = New-Object ClaudeWhisper.Engine
    $Form.Dispose()
    exit 0
}

# ---------------------------------------------------------------- run

$Form.Add_Shown({
    $split.SplitterDistance = [int]($split.Height * 0.42)
    [ClaudeWhisper.Ui]::SetCueBanner($script:AskBox, (Tx 'Preg\u00fantale algo a Claude (Enter)'))
    if (-not $Testing) { Register-WhisperHotkeys }
    Update-Controls
    [void](Start-Claude)
    if ($Testing) { Start-Listening }
    $script:Timer.Start()
})
$Form.Add_FormClosed({ [System.Windows.Forms.Application]::Exit() })

try {
    [System.Windows.Forms.Application]::Run($Form)
} finally {
    $script:Engine.Stop()
    Stop-Claude
    Stop-Interpreter
    if ($script:WhisperMutex) {
        Remove-Item -LiteralPath $WhisperPidFile -ErrorAction SilentlyContinue
        $script:WhisperMutex.ReleaseMutex()
    }
}
