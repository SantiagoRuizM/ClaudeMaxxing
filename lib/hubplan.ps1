# "Planear sesion del dia" section of the ClaudeMaxxing window: before the day's sessions, an idea goes on trial
# before Claude Judge (lib\judge.ps1). Two ways in: Nueva idea (write it and start a trial) and Flujo previo (the
# ideas already judged: read the feedback or judge it again with changes). The idea and the feedback use their
# own windows (a text box does not fit the owner-drawn hub).
# Needs hub.ps1, judge.ps1, bridgeui.ps1 (pills, wrapped text) and whisperui.ps1 (buttons, title bar).
# Keep this file ASCII: non-ASCII text is written as \uXXXX and decoded with Tx.

# ---------------------------------------------------------------- data

function Update-HubJudge {
    $c = $script:Hub.Cache
    $status = Get-JudgeStatus
    $c.JudgeStatus = $status
    $c.JudgeTrials = @(Get-JudgeTrials -Count 8)
    $c.JudgeProgress = ''
    if ($status -and $status.state -eq 'running') {
        $latestFile = Join-Path $JudgeHome '.court\LATEST'
        $latest = if (Test-Path -LiteralPath $latestFile) { [IO.File]::ReadAllText($latestFile).Trim() } else { '' }
        $run = if ($latest -and $latest -ne $status.previous) { Join-Path $JudgeHome $latest } else { '' }
        $c.JudgeProgress = Get-JudgeProgress $run
    }
}

function Get-JudgeVerdictColor([string]$Verdict) {
    $P = $script:Palette
    switch ($Verdict) { 'GUILTY' { $P.Error } 'NOT GUILTY' { $P.Ok } default { $P.Warn } }
}

# ---------------------------------------------------------------- actions

function Open-HubJudgeIdea([string]$Text = '') {
    if ($script:Hub.Preview) { return }
    $status = Get-JudgeStatus
    if ($status -and $status.state -eq 'running') { Set-HubMessage 'Ya hay un juicio en curso.'; return }
    $request = Show-JudgeIdeaDialog $Text $script:Palette $script:HubDialog
    if (-not $request) { return }
    try {
        Start-JudgeJob $request.Idea $request.Jury
        Set-HubMessage ((Tx 'Claude Judge est\u00e1 deliberando') + '...')
    } catch { Set-HubMessage ('No se pudo empezar: ' + $_.Exception.Message) }
    Update-HubNow
}

function Open-HubJudgeLog {
    if ($script:Hub.Preview) { return }
    $log = [string]$script:Hub.Cache.JudgeStatus.log
    if ($log -and (Test-Path -LiteralPath $log)) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $log) }
}

function Open-HubJudgeTrial([int]$Index) {
    if ($script:Hub.Preview) { return }
    $trial = @($script:Hub.Cache.JudgeTrials)[$Index]
    if (-not $trial) { return }
    $choice = Show-JudgeVerdictDialog $trial $script:Palette $script:HubDialog
    if ($choice -eq 'retry') { Open-HubJudgeIdea $trial.Case }
}

# ---------------------------------------------------------------- section

function Draw-HubPlanSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $HF = $script:HubFonts
    $c = $script:Hub.Cache
    $gap = Px 12
    $trials = @($c.JudgeTrials)
    $status = $c.JudgeStatus
    $running = [bool]($status -and $status.state -eq 'running')

    Draw-Wrapped $G (Tx 'Antes de abrir sesiones, pon a prueba lo que vas a hacer hoy. Claude Judge lo lleva a juicio: un fiscal, una defensa y un jurado de Claudes votan, y un juez te dice qu\u00e9 cambiar.') $F.Small $P.Muted $X0 (Px 68) $Inner (Px 34)

    # the two ways in
    $y = Px 108
    $cw = [int](($Inner - $gap) / 2)
    $options = @(
        @{ Id = 'plan-new'; Glyph = '\uea80'; Title = 'Nueva idea'; Action = { Open-HubJudgeIdea }
           Sub = (Tx 'Escribe lo que quieres hacer hoy y recibe el feedback de Claude Judge.'); Button = 'Escribir idea...' },
        @{ Id = 'plan-previous'; Glyph = '\ue81c'; Title = 'Flujo previo'; Action = { Open-HubJudgeTrial 0 }
           Sub = (Tx 'Retoma una idea ya juzgada: revisa su veredicto o vuelve a juzgarla con cambios.'); Button = $(if ($trials.Count) { (Tx 'Retomar la \u00faltima') } else { '' }) }
    )
    for ($i = 0; $i -lt 2; $i++) {
        $o = $options[$i]
        $card = New-Rect ($X0 + $i * ($cw + $gap)) $y $(if ($i -eq 0) { $cw } else { $Inner - $cw - $gap }) (Px 150)
        $enabled = ($i -eq 0 -and -not $running) -or ($i -eq 1 -and $trials.Count)
        Fill-Round $G $card (Px 10) $(if ($enabled -and $Hover -like "$($o.Id)*") { $P.SurfaceHover } else { $P.Surface })
        $icon = New-Rect ($card.X + (Px 16)) ($card.Y + (Px 16)) (Px 36) (Px 36)
        Fill-Round $G $icon (Px 18) $P.AccentTint
        Draw-Text $G (Tx $o.Glyph) $HF.NodeLarge $P.Accent $icon.X $icon.Y $icon.Width $icon.Height 'Center'
        Draw-Text $G $o.Title $F.Number $P.Text ($card.X + (Px 64)) ($card.Y + (Px 18)) ($card.Width - (Px 76)) (Px 32)
        Draw-Wrapped $G $o.Sub $F.Small $P.Muted ($card.X + (Px 16)) ($card.Y + (Px 64)) ($card.Width - (Px 32)) (Px 36)
        if ($enabled) { Add-Hit $Map $o.Id $card $o.Action }
        $by = $card.Bottom - (Px 38)
        if ($i -eq 0 -and $running) {
            Draw-Text $G 'Hay un juicio en curso' $F.Small $P.Faint ($card.X + (Px 16)) $by ($card.Width - (Px 32)) (Px 24)
        } elseif ($i -eq 1) {
            $count = if ($trials.Count -eq 1) { '1 idea juzgada' } elseif ($trials.Count) { "$($trials.Count) ideas juzgadas" } else { (Tx 'A\u00fan no hay ideas juzgadas') }
            Draw-Text $G $count $F.Small $P.Faint ($card.X + (Px 16)) $by (Px 150) (Px 24)
        }
        if ($o.Button -and $enabled) {
            $bw = Get-PillWidth $o.Button
            Draw-PillButton $G $Map $Hover "$($o.Id)-button" (New-Rect ($card.Right - (Px 14) - $bw) $by $bw (Px 24)) $o.Button $o.Action -Accent
        }
    }

    # the trial in progress, or why the last one failed
    $y = Px 274
    if ($running -or ($status -and $status.state -eq 'error')) {
        $card = New-Rect $X0 $y $Inner (Px 64)
        Draw-HubCard $G $card
        $tx = $card.X + (Px 16)
        if ($running) {
            # Three dots that move with the hub's 2-second refresh.
            $phase = [int]((Get-Date).Second / 2) % 3
            for ($d = 0; $d -lt 3; $d++) { Draw-HubDot $G ($tx + $d * (Px 12)) ($card.Y + (Px 18)) (Px 8) $(if ($d -eq $phase) { $P.Accent } else { $P.Faint }) }
            Draw-Text $G (Tx 'Claude Judge est\u00e1 deliberando') $F.BodyStrong $P.Text ($tx + (Px 44)) ($card.Y + (Px 10)) ($card.Width - (Px 200)) (Px 22)
            Draw-Text $G $c.JudgeProgress $F.Small $P.Muted ($tx + (Px 44)) ($card.Y + (Px 34)) ($card.Width - (Px 200)) (Px 18)
            $minutes = 0
            try { $minutes = [int]((Get-Date) - [datetime]$status.at).TotalMinutes } catch { }
            $jury = if ($status.jury) { "$($status.jury) jurados" } else { '' }
            Draw-Text $G ("$jury  " + (Tx '\u00b7') + "  $minutes min") $F.Small $P.Faint ($card.Right - (Px 160)) ($card.Y + (Px 10)) (Px 144) (Px 22) 'Right'
            Draw-Text $G 'Puedes cerrar esta ventana' $F.Small $P.Faint ($card.Right - (Px 180)) ($card.Y + (Px 34)) (Px 164) (Px 18) 'Right'
        } else {
            # The log has the whole story: checks, command, Claude's answer and denials, stderr.
            $hasLog = [bool]($status.log -and (Test-Path -LiteralPath ([string]$status.log)))
            $bw = if ($hasLog) { Get-PillWidth 'Ver registro' } else { 0 }
            Draw-Text $G (Tx 'EL \u00daLTIMO JUICIO NO TERMIN\u00d3') $F.Caps $P.Error $tx ($card.Y + (Px 10)) ($card.Width - (Px 32)) (Px 18)
            Draw-Wrapped $G ([string]$status.message) $F.Small $P.Muted $tx ($card.Y + (Px 30)) ($card.Width - (Px 44) - $bw) (Px 30)
            if ($hasLog) { Draw-PillButton $G $Map $Hover 'plan-log' (New-Rect ($card.Right - (Px 14) - $bw) ($card.Y + (Px 20)) $bw (Px 24)) 'Ver registro' { Open-HubJudgeLog } }
        }
        $y = $card.Bottom + $gap
    }

    # Flujo previo: the ideas already judged, newest first
    $fit = [Math]::Max(0, [int][Math]::Floor(($script:HubDialog.ClientSize.Height - (Px 16) - ($y + (Px 24))) / (Px 44)))
    Draw-HubCaption $G (Tx 'FLUJO PREVIO \u00b7 IDEAS YA JUZGADAS') $X0 $y $Inner $(if ($trials.Count -gt $fit) { Tx "+$($trials.Count - $fit) m\u00e1s antiguas" } else { '' })
    $y += Px 24
    if (-not $trials.Count) {
        Draw-Wrapped $G (Tx 'Aqu\u00ed aparecer\u00e1n tus ideas con su veredicto. Empieza con Nueva idea.') $F.Small $P.Faint $X0 $y $Inner (Px 36)
        return
    }
    $bottom = $script:HubDialog.ClientSize.Height - (Px 16)
    for ($i = 0; $i -lt $trials.Count -and ($y + (Px 44)) -le $bottom; $i++) {
        $t = $trials[$i]
        $row = New-Rect $X0 $y $Inner (Px 40)
        $hitId = "plan-trial-$i"
        Fill-Round $G $row (Px 8) $(if ($Hover -eq $hitId) { $P.SurfaceHover } else { $P.Surface })
        $score = Format-JudgeScore $t.Tally
        $sw = (Measure-TextWidth $score $F.BodyStrong) + (Px 8)
        Draw-Text $G $t.Title $F.Body $P.Text ($row.X + (Px 14)) ($row.Y + (Px 3)) ($row.Width - $sw - (Px 40)) (Px 20)
        $when = if ($t.At) { Format-DialogDateTime $t.At (Get-Date) } else { '' }
        Draw-Text $G $when $F.Small $P.Muted ($row.X + (Px 14)) ($row.Y + (Px 21)) (Px 220) (Px 16)
        Draw-Text $G $score $F.BodyStrong (Get-JudgeVerdictColor $t.Tally.verdict) ($row.Right - $sw - (Px 26)) $row.Y $sw $row.Height 'Right'
        Draw-Text $G (Tx '\u203a') $F.BodyStrong $P.Faint ($row.Right - (Px 22)) $row.Y (Px 12) $row.Height 'Center'
        Add-Hit $Map $hitId $row ([scriptblock]::Create("Open-HubJudgeTrial $i"))
        $y += Px 44
    }
}

# ---------------------------------------------------------------- windows

function New-JudgeForm([string]$Title, $Palette, [int]$Width, [int]$Height) {
    $P = $Palette
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude Judge ' + [char]0x00B7 + ' ' + $Title
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $P.Back
    $dlg.ForeColor = $P.Text
    $dlg.Font = $script:Fonts.Body
    $dlg.ClientSize = New-Object System.Drawing.Size((Px $Width), (Px $Height))
    $dlg.MinimumSize = New-Object System.Drawing.Size((Px 420), (Px 360))
    $dlg.Add_HandleCreated({ Set-WhisperTitleBar $this $script:Palette $script:LightTheme })
    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object System.Windows.Forms.Padding((Px 14), (Px 8), (Px 14), (Px 10))
    $layout.ColumnCount = 1
    $layout.BackColor = $P.Back
    $dlg.Controls.Add($layout)
    $dlg.Tag = $layout
    $dlg
}

function Add-JudgeRow($Form, $Control, [double]$Percent = 0) {
    $layout = $Form.Tag
    $layout.RowCount++
    if ($Percent) { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', [single]$Percent))) }
    else { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
    $Control.Dock = 'Fill'
    $layout.Controls.Add($Control, 0, $layout.RowCount - 1)
}

function New-JudgeLabel([string]$Text, $Color, $Font = $script:Fonts.Body) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.ForeColor = $Color; $l.Font = $Font; $l.UseMnemonic = $false
    $l.MaximumSize = New-Object System.Drawing.Size((Px 520), 0)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 6), 0, (Px 3))
    $l
}

function New-JudgeBox([string]$Text, $Palette, [bool]$ReadOnly) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true; $t.WordWrap = $true
    $t.ReadOnly = $ReadOnly
    $t.Text = ($Text -replace "`r?`n", "`r`n")
    $t.BackColor = $Palette.Surface; $t.ForeColor = $Palette.Text; $t.BorderStyle = 'FixedSingle'
    $t.Font = New-UiFont 'Segoe UI' 10
    $t
}

# Nueva idea: returns @{ Idea; Jury } or $null.
function Show-JudgeIdeaDialog([string]$Text, $Palette, $Owner) {
    $P = $Palette
    $dlg = New-JudgeForm 'Nueva idea' $P 560 480
    Add-JudgeRow $dlg (New-JudgeLabel (Tx 'Describe la idea o el plan de hoy con todo lo que importa: para qui\u00e9n es, n\u00fameros, tiempo, presupuesto y lo que ya probaste. Claude Judge solo sabe lo que escribas aqu\u00ed.') $P.Muted)
    Add-JudgeRow $dlg (New-JudgeLabel 'TU IDEA' $P.Muted $script:Fonts.Caps)
    $box = New-JudgeBox $Text $P $false
    Add-JudgeRow $dlg $box 100
    $full = New-Object System.Windows.Forms.CheckBox
    $full.Text = Tx 'Juicio completo: 12 jurados (m\u00e1s lento). Sin marcar: 6 jurados.'
    $full.AutoSize = $true; $full.ForeColor = $P.Text; $full.UseMnemonic = $false
    $full.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    Add-JudgeRow $dlg $full
    Add-JudgeRow $dlg (New-JudgeLabel (Tx 'Usa tu plan de Claude (Sonnet): 11 llamadas con 6 jurados, 17 con 12. Tarda unos 10 minutos (15 con 12 jurados) y sigue aunque cierres la ventana.') $P.Faint $script:Fonts.Small)
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $go = New-WhisperButton 'Poner a juicio' $P $true
    $cancel = New-WhisperButton 'Cancelar' $P
    $go.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.Add($go); $buttons.Controls.Add($cancel)
    Add-JudgeRow $dlg $buttons
    $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ $box.Focus(); $box.SelectionStart = $box.TextLength })
    $result = $dlg.ShowDialog($Owner)
    $idea = $box.Text.Trim()
    $jury = if ($full.Checked) { 12 } else { 6 }
    $dlg.Dispose()
    if ($result -ne 'OK' -or -not $idea) { return $null }
    @{ Idea = $idea; Jury = $jury }
}

# The feedback of one trial. Returns 'retry' (judge it again with changes) or $null.
function Show-JudgeVerdictDialog($Trial, $Palette, $Owner) {
    $P = $Palette
    $dlg = New-JudgeForm 'Veredicto' $P 640 620
    $head = New-JudgeLabel (Format-JudgeScore $Trial.Tally) (Get-JudgeVerdictColor $Trial.Tally.verdict) (New-UiFont 'Georgia' 15)
    Add-JudgeRow $dlg $head
    $when = if ($Trial.At) { Format-DialogDateTime $Trial.At (Get-Date) } else { '' }
    Add-JudgeRow $dlg (New-JudgeLabel ($when + '  ' + [char]0x00B7 + '  ' + $Trial.Title) $P.Muted $script:Fonts.Small)
    $text = try { Format-JudgeFeedback $Trial } catch { 'No se pudo leer el veredicto: ' + $_.Exception.Message }
    $box = New-JudgeBox $text $P $true
    Add-JudgeRow $dlg $box 100
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $close = New-WhisperButton 'Cerrar' $P
    $retry = New-WhisperButton 'Rejuzgar con cambios...' $P $true
    $folder = New-WhisperButton 'Abrir el juicio completo' $P
    $close.DialogResult = 'Cancel'; $retry.DialogResult = 'Retry'
    $folder.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Trial.Dir) })
    $buttons.Controls.Add($close); $buttons.Controls.Add($retry); $buttons.Controls.Add($folder)
    Add-JudgeRow $dlg $buttons
    $dlg.CancelButton = $close
    $dlg.Add_Shown({ $box.SelectionLength = 0; $close.Focus() })
    $result = $dlg.ShowDialog($Owner)
    $dlg.Dispose()
    if ($result -eq 'Retry') { 'retry' } else { $null }
}
