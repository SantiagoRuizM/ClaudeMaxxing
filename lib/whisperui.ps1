# Claude Whisper window pieces: themed controls, a small markdown renderer for answers, and the context
# dialog (profile, conversation, instructions, language, model). Needs theme.ps1 and whisper.ps1.

function Set-WhisperTitleBar([System.Windows.Forms.Form]$Form, $Palette, [bool]$Light) {
    # DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_CAPTION_COLOR = 35, DWMWA_TEXT_COLOR = 36 (COLORREF 0x00BBGGRR).
    $dark = if ($Light) { 0 } else { 1 }
    [void][ClaudeTray.Native]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$dark, 4)
    foreach ($pair in @(@(35, $Palette.Back), @(36, $Palette.Text))) {
        $c = $pair[1]
        $ref = [int]$c.R -bor ([int]$c.G -shl 8) -bor ([int]$c.B -shl 16)
        [void][ClaudeTray.Native]::DwmSetWindowAttribute($Form.Handle, $pair[0], [ref]$ref, 4)
    }
}

function New-WhisperButton([string]$Text, $Palette, [bool]$Accent = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object System.Windows.Forms.Padding((Px 6), (Px 1), (Px 6), (Px 1))
    $b.Margin = New-Object System.Windows.Forms.Padding((Px 2), (Px 4), (Px 2), (Px 4))
    $b.Font = $script:Fonts.Button
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseMnemonic = $false
    Set-WhisperButtonStyle $b $Palette $Accent
    $b
}

function Set-WhisperButtonStyle($Button, $Palette, [bool]$Accent) {
    if ($Accent) {
        $Button.BackColor = $Palette.Accent; $Button.ForeColor = $Palette.AccentText
        $Button.FlatAppearance.BorderColor = $Palette.Accent
        $Button.FlatAppearance.MouseOverBackColor = $Palette.AccentHover
        $Button.FlatAppearance.MouseDownBackColor = $Palette.AccentHover
    } else {
        $Button.BackColor = $Palette.Surface; $Button.ForeColor = $Palette.Text
        $Button.FlatAppearance.BorderColor = $Palette.Border
        $Button.FlatAppearance.MouseOverBackColor = $Palette.SurfaceHover
        $Button.FlatAppearance.MouseDownBackColor = $Palette.SurfaceHover
    }
}

function New-WhisperTextView($Palette, $Font) {
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.ReadOnly = $true
    $box.BorderStyle = 'None'
    $box.BackColor = $Palette.Back
    $box.ForeColor = $Palette.Text
    $box.Font = $Font
    $box.Dock = 'Fill'
    $box.DetectUrls = $false
    $box.HideSelection = $false
    $box.ScrollBars = 'Vertical'
    $box
}

function New-WhisperCaption([string]$Text, $Palette) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Font = $script:Fonts.Caps
    $label.ForeColor = $Palette.Muted
    $label.Dock = 'Top'
    $label.Height = Px 22
    $label.TextAlign = 'BottomLeft'
    $label.UseMnemonic = $false
    $label
}

# RichTextBox redraw off/on around a rebuild, so streaming text does not flicker.
function Suspend-Redraw($Control) { [void][ClaudeTray.Native]::SendMessage($Control.Handle, 0x000B, [IntPtr]::Zero, [IntPtr]::Zero) }
function Resume-Redraw($Control) {
    [void][ClaudeTray.Native]::SendMessage($Control.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero)
    $Control.Invalidate()
}

function Add-RichText($Box, [string]$Text, $Font, $Color) {
    if (-not $Text) { return }
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionFont = $Font
    $Box.SelectionColor = $Color
    $Box.SelectedText = $Text
}

# Inline **bold** and `code` within one line.
function Add-RichInline($Box, [string]$Text, $Fonts, $Palette) {
    $pattern = '(\*\*[^*]+\*\*|`[^`]+`)'
    foreach ($part in [regex]::Split($Text, $pattern)) {
        if (-not $part) { continue }
        if ($part.Length -gt 4 -and $part.StartsWith('**') -and $part.EndsWith('**')) {
            Add-RichText $Box $part.Substring(2, $part.Length - 4) $Fonts.Strong $Palette.Text
        } elseif ($part.Length -gt 2 -and $part.StartsWith('`') -and $part.EndsWith('`')) {
            Add-RichText $Box $part.Substring(1, $part.Length - 2) $Fonts.Code $Palette.Accent
        } else {
            Add-RichText $Box $part $Fonts.Answer $Palette.Text
        }
    }
}

# Enough markdown for answers: code fences, bullets, numbered items, headings, bold and inline code.
function Write-RichMarkdown($Box, [string]$Markdown, $Fonts, $Palette) {
    $inCode = $false
    $first = $true
    foreach ($raw in ($Markdown -replace "`r", '' -split "`n")) {
        if (-not $first) { Add-RichText $Box "`n" $Fonts.Answer $Palette.Text }
        $first = $false
        if ($raw.TrimStart().StartsWith('```')) { $inCode = -not $inCode; continue }
        if ($inCode) { Add-RichText $Box ("  " + $raw) $Fonts.Code $Palette.Text; continue }
        $line = $raw
        if ($line -match '^\s*#{1,6}\s+(.*)$') { Add-RichText $Box $Matches[1] $Fonts.Strong $Palette.Text; continue }
        if ($line -match '^(\s*)[-\*]\s+(.*)$') {
            Add-RichText $Box ($Matches[1] + [string][char]0x2022 + ' ') $Fonts.Answer $Palette.Accent
            Add-RichInline $Box $Matches[2] $Fonts $Palette
            continue
        }
        if ($line -match '^(\s*\d+[\.\)])\s+(.*)$') {
            Add-RichText $Box ($Matches[1] + ' ') $Fonts.Strong $Palette.Accent
            Add-RichInline $Box $Matches[2] $Fonts $Palette
            continue
        }
        Add-RichInline $Box $line $Fonts $Palette
    }
}

# ---------------------------------------------------------------- context dialog

# Edits a copy of the settings; returns it on Guardar, $null on Cancelar.
function Show-WhisperContextDialog($Settings, $Palette, $Owner) {
    $P = $Palette
    $F = $script:Fonts
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude Whisper ' + [char]0x00B7 + ' Contexto'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $P.Back
    $dlg.ForeColor = $P.Text
    $dlg.Font = $F.Body
    $dlg.ClientSize = New-Object System.Drawing.Size((Px 560), (Px 640))
    $dlg.MinimumSize = New-Object System.Drawing.Size((Px 460), (Px 520))
    $dlg.Add_HandleCreated({ Set-WhisperTitleBar $this $script:Palette $script:LightTheme })

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object System.Windows.Forms.Padding((Px 14), (Px 6), (Px 14), (Px 10))
    $layout.ColumnCount = 1
    $layout.BackColor = $P.Back
    $dlg.Controls.Add($layout)

    function Add-Row($Control, [string]$Style = 'AutoSize', [double]$Size = 0) {
        $layout.RowCount++
        if ($Style -eq 'Percent') { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', [single]$Size))) }
        else { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
        $Control.Dock = 'Fill'
        $layout.Controls.Add($Control, 0, $layout.RowCount - 1)
    }
    function New-Caption([string]$Text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.ForeColor = $P.Muted; $l.Font = $F.Caps; $l.UseMnemonic = $false
        $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 10), 0, (Px 3))
        $l
    }
    function New-Box([string]$Text, [bool]$Multi) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Multiline = $Multi
        if ($Multi) { $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true }
        $t.Text = ($Text -replace "`r?`n", "`r`n")
        $t.BackColor = $P.Surface; $t.ForeColor = $P.Text; $t.BorderStyle = 'FixedSingle'
        $t
    }

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = Tx 'Claude usa esto para responder como t\u00fa. Se guarda solo en este PC y va en cada conversaci\u00f3n con Claude.'
    $hint.AutoSize = $true; $hint.ForeColor = $P.Muted; $hint.MaximumSize = New-Object System.Drawing.Size((Px 520), 0)
    Add-Row $hint

    $profileHead = New-Object System.Windows.Forms.FlowLayoutPanel
    $profileHead.AutoSize = $true; $profileHead.WrapContents = $false; $profileHead.Margin = New-Object System.Windows.Forms.Padding(0)
    $profileCaption = New-Caption (Tx 'SOBRE TI (CV, EXPERIENCIA, LOGROS)')
    $load = New-WhisperButton (Tx 'Cargar archivo...') $P
    $load.Margin = New-Object System.Windows.Forms.Padding((Px 10), (Px 4), 0, 0)
    $profileHead.Controls.Add($profileCaption); $profileHead.Controls.Add($load)
    Add-Row $profileHead
    $profileBox = New-Box $Settings.profile $true
    Add-Row $profileBox 'Percent' 45
    $load.Add_Click({
        $open = New-Object System.Windows.Forms.OpenFileDialog
        $open.Filter = (Tx 'Texto (*.txt;*.md)|*.txt;*.md|Todos los archivos|*.*')
        if ($open.ShowDialog($dlg) -eq 'OK') {
            try { $profileBox.Text = ([IO.File]::ReadAllText($open.FileName) -replace "`r?`n", "`r`n") } catch { }
        }
    })

    Add-Row (New-Caption (Tx 'LA CONVERSACI\u00d3N (PUESTO, EMPRESA, TEMA, OBJETIVO)'))
    $meetingBox = New-Box $Settings.meeting $true
    Add-Row $meetingBox 'Percent' 25
    Add-Row (New-Caption (Tx 'INDICACIONES (TONO, LONGITUD, QU\u00c9 EVITAR)'))
    $instructionsBox = New-Box $Settings.instructions $true
    Add-Row $instructionsBox 'Percent' 15
    Add-Row (New-Caption (Tx 'T\u00c9RMINOS PARA LA TRANSCRIPCI\u00d3N (SEPARADOS POR COMAS)'))
    $termsBox = New-Box $Settings.keyterms $false
    Add-Row $termsBox

    $options = New-Object System.Windows.Forms.FlowLayoutPanel
    $options.AutoSize = $true; $options.WrapContents = $true
    $options.Margin = New-Object System.Windows.Forms.Padding(0, (Px 10), 0, 0)
    function New-Combo($Items, [string]$Selected) {
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'; $c.BackColor = $P.Surface; $c.ForeColor = $P.Text
        $c.Width = Px 150
        foreach ($key in $Items.Keys) { [void]$c.Items.Add($Items[$key]) }
        $index = [array]::IndexOf(@($Items.Keys), $Selected)
        $c.SelectedIndex = [Math]::Max(0, $index)
        $c
    }
    function New-Check([string]$Text, [bool]$Checked) {
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $Text; $c.Checked = $Checked; $c.AutoSize = $true; $c.ForeColor = $P.Text; $c.UseMnemonic = $false
        $c.Margin = New-Object System.Windows.Forms.Padding(0, (Px 6), (Px 14), 0)
        $c
    }
    function New-Inline([string]$Text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.ForeColor = $P.Muted
        $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 7), (Px 4), 0)
        $l
    }
    $languageCombo = New-Combo $script:WhisperLanguages $Settings.language
    $modelCombo = New-Combo $script:WhisperModels $Settings.model
    $options.Controls.Add((New-Inline 'Mi idioma'))
    $options.Controls.Add($languageCombo)
    $options.Controls.Add((New-Inline '   Modelo'))
    $options.Controls.Add($modelCombo)
    Add-Row $options

    $checks = New-Object System.Windows.Forms.FlowLayoutPanel
    $checks.AutoSize = $true; $checks.WrapContents = $true
    $autoCheck = New-Check (Tx 'Responder solo cuando detecte una pregunta (cualquier idioma, tambi\u00e9n en canciones)') $Settings.autoAnswer
    $micCheck = New-Check (Tx 'Transcribir tu micr\u00f3fono') $Settings.useMic
    $gateCheck = New-Check (Tx 'Silenciar tu micr\u00f3fono mientras hablan (sin auriculares)') $Settings.gateMic
    $meetingCheck = New-Check (Tx 'Avisar desde la bandeja cuando empiece una llamada (Teams, Zoom...)') $Settings.meetingNotice
    $checks.Controls.Add($autoCheck); $checks.Controls.Add($micCheck); $checks.Controls.Add($gateCheck); $checks.Controls.Add($meetingCheck)
    Add-Row $checks

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0, (Px 10), 0, 0)
    $save = New-WhisperButton 'Guardar' $P $true
    $cancel = New-WhisperButton 'Cancelar' $P
    $save.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.Add($save); $buttons.Controls.Add($cancel)
    Add-Row $buttons
    $dlg.AcceptButton = $null
    $dlg.CancelButton = $cancel

    $result = $dlg.ShowDialog($Owner)
    if ($result -ne 'OK') { $dlg.Dispose(); return $null }
    $updated = [ordered]@{}
    foreach ($key in $Settings.Keys) { $updated[$key] = $Settings[$key] }
    $updated.profile = $profileBox.Text.Trim()
    $updated.meeting = $meetingBox.Text.Trim()
    $updated.instructions = $instructionsBox.Text.Trim()
    $updated.keyterms = $termsBox.Text.Trim()
    $updated.language = @($script:WhisperLanguages.Keys)[$languageCombo.SelectedIndex]
    $updated.model = @($script:WhisperModels.Keys)[$modelCombo.SelectedIndex]
    $updated.autoAnswer = $autoCheck.Checked
    $updated.useMic = $micCheck.Checked
    $updated.gateMic = $gateCheck.Checked
    $updated.meetingNotice = $meetingCheck.Checked
    $dlg.Dispose()
    $updated
}
