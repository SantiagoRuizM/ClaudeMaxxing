# ClaudeTray: notification-area icon with Claude plan usage (5-hour session and weekly limits).
# Data comes from usage.json, which the Claude Code statusline writes on every response.
# Launch: powershell -NoProfile -ExecutionPolicy Bypass -STA -File tray.ps1
# -RenderTo / -RenderDialogTo <png> draw the popup / schedule dialog to an image and exit (layout check);
# -DialogTab plan renders the dialog's week tab; -UsagePath / -ExtrasPath read other snapshot files; -Theme light|dark overrides the Windows app theme.
# -RenderBridgeTo / -RenderApprovalTo <png> draw the Otros PCs window / the incoming-connection dialog with sample data.
# -RenderHubTo <png> draws the ClaudeMaxxing window with sample data; -HubSection picks the section (home, plan, plan-running, plan-error, plan-empty, usage, stats, code, pcs, whisper, voice; stats-hours, stats-projects, stats-models open the other Estadisticas tabs).
param([string]$RenderTo, [string]$UsagePath, [string]$RenderDialogTo, [string]$Theme, [string]$ExtrasPath, [string]$PreviewCloud, [string]$DialogTab,
    [string]$RenderBridgeTo, [string]$RenderApprovalTo, [string]$RenderHubTo, [string]$HubSection = 'home')

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\usage.ps1')
. (Join-Path $TrayRoot 'lib\schedule.ps1')
. (Join-Path $TrayRoot 'lib\usageapi.ps1')
. (Join-Path $TrayRoot 'lib\bridge.ps1')
. (Join-Path $TrayRoot 'lib\bridgenet.ps1')
. (Join-Path $TrayRoot 'lib\whisper.ps1')
. (Join-Path $TrayRoot 'lib\autoplan.ps1')
. (Join-Path $TrayRoot 'lib\sessions.ps1')
. (Join-Path $TrayRoot 'lib\freellm.ps1')
. (Join-Path $TrayRoot 'lib\voiceengine.ps1')
. (Join-Path $TrayRoot 'lib\maxx.ps1')
. (Join-Path $TrayRoot 'lib\forecast.ps1')
# Started by install.ps1 from a Claude Code shell, the tray would pass that shell's settings (no colors, no git
# prompts) to everything it starts, including remote sessions on this PC.
if ($env:CLAUDECODE) {
    foreach ($name in 'NO_COLOR', 'GIT_EDITOR', 'GIT_TERMINAL_PROMPT', 'GIT_ASKPASS') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
}
Clear-ClaudeSessionEnv
if ($UsagePath) { $UsageFile = $UsagePath }
if ($ExtrasPath) { $ExtrasFile = $ExtrasPath }

$Rendering = [bool]($RenderTo -or $RenderDialogTo -or $RenderBridgeTo -or $RenderApprovalTo -or $RenderHubTo)
if (-not $Rendering) {
    $createdNew = $false
    $script:TrayMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeTray', [ref]$createdNew)
    if (-not $createdNew) { exit 0 }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $TrayRoot 'lib\theme.ps1')
. (Join-Path $TrayRoot 'lib\dialog.ps1')
. (Join-Path $TrayRoot 'lib\bridgeui.ps1')
. (Join-Path $TrayRoot 'lib\whisperui.ps1')
. (Join-Path $TrayRoot 'lib\hub.ps1')
. (Join-Path $TrayRoot 'lib\hubstats.ps1')
. (Join-Path $TrayRoot 'lib\hubauto.ps1')
. (Join-Path $TrayRoot 'lib\judge.ps1')
. (Join-Path $TrayRoot 'lib\hubplan.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Path -LiteralPath $TrayHome)) { New-Item -ItemType Directory -Force -Path $TrayHome | Out-Null }
if (-not $Rendering) { [System.IO.File]::WriteAllText($TrayPidFile, [string]$PID) }

$lightTheme = if ($Theme) { $Theme -eq 'light' } else { Test-AppsLightTheme }
$script:Palette = Get-ClaudePalette $lightTheme
$P = $script:Palette
$F = $script:Fonts

# ---------------------------------------------------------------- state

$script:View = $null
$script:Extras = [pscustomobject]@{ ExtraUsage = $null; LimitReset = $null }
$script:Plan = Get-PlanName $CredsFile
$script:FooterRight = ''
$script:PendingTasks = @()
$script:LastHidden = [datetime]::MinValue
$script:Refresh = $null
$script:RefreshError = ''
$script:RefreshErrorAt = [datetime]::MinValue
$script:LastRefreshAt = [datetime]::MinValue

function Update-UsageState {
    $script:Plan = Get-PlanName $CredsFile
    $script:View = Get-UsageView (Read-JsonFile $UsageFile) (Get-Date)
    $script:Extras = Get-ExtrasView (Read-JsonFile $ExtrasFile) (Get-Date)
    Set-PopupSize
    $script:Notify.Text = Format-TrayTooltip $script:View $script:Plan
    Update-Footer
}

# Querying Task Scheduler takes ~0.7 s, so the task list is cached and refreshed only
# at startup, after the schedule dialog closes, and every few minutes.
function Update-ScheduleState {
    $script:PendingTasks = @(Get-SessionTasks)
    Update-Footer
}

function Update-Footer {
    $rows = @(Get-ScheduleRows $script:PendingTasks (Read-JsonFile $CloudFile) (Read-JsonFile $HistoryFile) (Get-Date) 1)
    $script:FooterRight = ''
    if ($rows.Count -eq 0) { return }
    $row = $rows[0]
    if ($row.State -in 'pending', 'requested', 'creating', 'cloud-ok') {
        $script:FooterRight = 'Next: ' + (Format-ShortDateTime $row.At)
    } else {
        $status = switch ($row.State) { 'ok' { 'OK' } 'failed' { 'failed' } default { 'cloud' } }
        $script:FooterRight = 'Last: ' + (Format-ShortDateTime $row.At) + " $status"
    }
}

# ---------------------------------------------------------------- live refresh

function Start-UsageRefresh {
    if ($script:Refresh -or $Rendering) { return }
    $script:LastRefreshAt = Get-Date
    $script:RefreshError = ''
    $auth = Get-OAuthToken $CredsFile
    if (-not $auth) {
        $script:RefreshError = 'Not logged in to Claude Code'
        $script:RefreshErrorAt = Get-Date
    } else {
        try {
            $script:Refresh = Start-UsageRequest $auth.Token
            $script:RefreshTimer.Start()
        } catch {
            $script:RefreshError = 'No connection'
            $script:RefreshErrorAt = Get-Date
        }
    }
    if ($script:Popup.Visible) { $script:Popup.Invalidate() }
}

$script:RefreshTimer = New-Object System.Windows.Forms.Timer
$script:RefreshTimer.Interval = 150
$script:RefreshTimer.Add_Tick({
    if (-not $script:Refresh -or -not $script:Refresh.Task.IsCompleted) { return }
    $script:RefreshTimer.Stop()
    $result = Complete-UsageRequest $script:Refresh
    $script:Refresh = $null
    if ($result.Ok) {
        Write-JsonFile $UsageFile $result.Snapshot
        Write-JsonFile $ExtrasFile $result.Extras
    } else {
        $script:RefreshError = $result.Error
        $script:RefreshErrorAt = Get-Date
    }
    Update-UsageState
    if ($script:Popup.Visible) { $script:Popup.Invalidate() }
})
# ---------------------------------------------------------------- popup

$PopupWidth = 360

# Layout (logical px): header, SESSION and WEEKLY blocks, optional EXTRA USAGE block and
# limit-reset card, then footer and button. Height follows what is shown.
$script:ExtraBlockHeight = 72
$script:ResetCardHeight = 60

function Get-PopupContentBottom {
    $y = 206
    if ($script:View -and $script:View.HasData) {
        if ($script:Extras.ExtraUsage) { $y += $script:ExtraBlockHeight }
        if ($script:Extras.LimitReset) { $y += $script:ResetCardHeight }
    }
    $y
}

function Set-PopupSize {
    if (-not $script:Popup) { return }
    $height = Px ((Get-PopupContentBottom) + 82)
    if ($script:Popup.ClientSize.Height -eq $height) { return }
    $script:Popup.ClientSize = New-Object System.Drawing.Size((Px $PopupWidth), $height)
    if ($script:Popup.Visible) { Move-PopupToCorner }
}

function Move-PopupToCorner {
    $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $script:Popup.Location = New-Object System.Drawing.Point(
        ($area.Right - $script:Popup.Width - (Px 12)), ($area.Bottom - $script:Popup.Height - (Px 12)))
}
$script:Popup = New-Object System.Windows.Forms.Form
$Popup.FormBorderStyle = 'None'
$Popup.ShowInTaskbar = $false
$Popup.TopMost = $true
$Popup.StartPosition = 'Manual'
$Popup.BackColor = $P.Back
$Popup.ClientSize = New-Object System.Drawing.Size((Px $PopupWidth), (Px 288))
Enable-DoubleBuffer $Popup
$Popup.Tag = New-HitMap
Register-HitMap $Popup
$script:PopupLogo = New-TintedLogo $P.Accent (Px 20)

function Draw-Window($G, [string]$Label, $Window, [int]$Top, [string]$IdleText) {
    $left = Px 18
    $width = Px ($PopupWidth - 36)
    $pctText = if ($Window.Active) { "$($Window.Percent)%" } else { '0%' }
    $pctColor = if ($Window.Active) { $P.Text } else { $P.Faint }
    Draw-Text $G $Label $F.Caps $P.Muted $left (Px $Top) $width (Px 22)
    Draw-Text $G $pctText $F.Number $pctColor $left (Px ($Top - 3)) $width (Px 28) 'Right'

    $track = New-Rect $left (Px ($Top + 28)) $width (Px 6)
    Fill-Round $G $track (Px 3) $P.Track
    if ($Window.Active -and $Window.Percent -gt 0) {
        $fillWidth = [Math]::Max((Px 6), [int]($width * $Window.Percent / 100))
        Fill-Round $G (New-Rect $left $track.Y $fillWidth $track.Height) (Px 3) $P[(Get-UsageLevel $Window.Percent)]
    }

    $resetText = if ($Window.Active) { Format-ResetText $Window.ResetsAt (Get-Date) } else { $IdleText }
    $resetColor = if ($Window.Active) { $P.Text } else { $P.Muted }
    Draw-Text $G 'Resets' $F.Small $P.Muted $left (Px ($Top + 40)) $width (Px 22)
    Draw-Text $G $resetText $F.Body $resetColor $left (Px ($Top + 40)) $width (Px 22) 'Right'
}

$Popup.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $map = $sender.Tag
    $map.Items.Clear()
    $w = $sender.ClientSize.Width
    $h = $sender.ClientSize.Height
    $view = $script:View

    # header: spark + serif title, plan pill and status dot on the right
    if ($script:PopupLogo) { $g.DrawImage($script:PopupLogo, (Px 18), (Px 19)) }
    Draw-Text $g 'Claude' $F.Title $P.Text (Px 46) (Px 13) (Px 160) (Px 32)
    $dotSize = Px 8
    $dotX = $w - (Px 18) - $dotSize
    $dotColor = if ($view -and $view.Fresh) { $P.low } else { $P.Faint }
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($dotColor)), $dotX, (Px 29) - [int]($dotSize / 2), $dotSize, $dotSize)
    $nextRight = $dotX - (Px 10)
    if ($script:Plan) {
        $pillW = (Measure-TextWidth $script:Plan $F.Badge) + (Px 18)
        $pill = New-Rect ($nextRight - $pillW) (Px 18) $pillW (Px 22)
        Fill-Round $g $pill (Px 11) $P.AccentTint
        Draw-Text $g $script:Plan $F.Badge $P.Accent $pill.X $pill.Y $pill.Width $pill.Height 'Center'
        $nextRight = $pill.X - (Px 6)
    }
    $refreshBox = New-Rect ($nextRight - (Px 28)) (Px 15) (Px 28) (Px 28)
    $busy = [bool]$script:Refresh
    if ($busy -or $map.Hover -eq 'refresh') { Fill-Round $g $refreshBox (Px 8) $P.SurfaceHover }
    $refreshColor = if ($busy -or $map.Hover -eq 'refresh') { $P.Accent } else { $P.Muted }
    Draw-Text $g (Tx '\u21bb') $F.Refresh $refreshColor $refreshBox.X ($refreshBox.Y - (Px 1)) $refreshBox.Width $refreshBox.Height 'Center'
    Add-Hit $map 'refresh' $refreshBox { Start-UsageRefresh }

    if (-not $view -or -not $view.HasData) {
        Draw-Text $g 'No usage data yet' $F.BodyStrong $P.Text (Px 18) (Px 74) (Px ($PopupWidth - 36)) (Px 24)
        Draw-Text $g 'Send a message in Claude Code to refresh.' $F.Small $P.Muted (Px 18) (Px 98) (Px ($PopupWidth - 36)) (Px 22)
    } else {
        Draw-Window $g 'SESSION' $view.Session 62 'Not started'
        Draw-Window $g 'WEEKLY' $view.Weekly 134 'Not started'
        $top = 206
        $extra = $script:Extras.ExtraUsage
        if ($extra) {
            $left = Px 18
            $width = Px ($PopupWidth - 36)
            Draw-Text $g 'EXTRA USAGE' $F.Caps $P.Muted $left (Px $top) $width (Px 22)
            $pctText = if ($null -ne $extra.Percent) { "$($extra.Percent)%" } else { 'On' }
            Draw-Text $g $pctText $F.Number $P.Text $left (Px ($top - 3)) $width (Px 28) 'Right'
            $track = New-Rect $left (Px ($top + 28)) $width (Px 6)
            Fill-Round $g $track (Px 3) $P.Track
            if ($extra.Percent -gt 0) {
                $fillWidth = [Math]::Max((Px 6), [int]($width * $extra.Percent / 100))
                Fill-Round $g (New-Rect $left $track.Y $fillWidth $track.Height) (Px 3) $P.Accent
            }
            if ($extra.AmountText) { Draw-Text $g $extra.AmountText $F.Body $P.Text $left (Px ($top + 40)) $width (Px 22) 'Right' }
            Draw-Text $g 'Credits' $F.Small $P.Muted $left (Px ($top + 40)) $width (Px 22)
            $top += $script:ExtraBlockHeight
        }
        $reset = $script:Extras.LimitReset
        if ($reset) {
            $card = New-Rect (Px 18) (Px $top) (Px ($PopupWidth - 36)) (Px 50)
            Fill-Round $g $card (Px 10) $P.AccentTint
            Draw-Text $g (Tx '\u21ba') $F.Refresh $P.Accent ($card.X + (Px 10)) $card.Y (Px 22) $card.Height 'Center'
            Draw-Text $g $reset.Title $F.BodyStrong $P.Text ($card.X + (Px 38)) ($card.Y + (Px 6)) (Px 200) (Px 20)
            Draw-Text $g $reset.Detail $F.Small $P.Muted ($card.X + (Px 38)) ($card.Y + (Px 25)) (Px 210) (Px 18)
            $useBox = New-Rect ($card.Right - (Px 64)) ($card.Y + (Px 11)) (Px 54) (Px 28)
            $useColor = if ($map.Hover -eq 'use-reset') { $P.AccentHover } else { $P.Accent }
            Fill-Round $g $useBox (Px 8) $useColor
            Draw-Text $g 'Use' $F.Button $P.AccentText $useBox.X $useBox.Y $useBox.Width $useBox.Height 'Center'
            Add-Hit $map 'use-reset' $useBox { Start-Process 'https://claude.ai/settings/usage' }
        }
    }

    $bottom = Get-PopupContentBottom
    $pen = New-Object System.Drawing.Pen($P.Border)
    $g.DrawLine($pen, (Px 18), (Px ($bottom - 4)), $w - (Px 18), (Px ($bottom - 4)))
    $ageColor = $P.Muted
    if ($script:Refresh) {
        $age = 'Updating...'
    } elseif ($script:RefreshError -and ((Get-Date) - $script:RefreshErrorAt).TotalSeconds -lt 30) {
        $age = $script:RefreshError; $ageColor = $P.Error
    } else {
        $age = if ($view) { Format-Age $view.AgeMinutes } else { 'No data yet' }
    }
    Draw-Text $g $age $F.Small $ageColor (Px 18) (Px ($bottom + 2)) (Px 190) (Px 24)
    Draw-Text $g $script:FooterRight $F.Small $P.Muted (Px 18) (Px ($bottom + 2)) (Px ($PopupWidth - 36)) (Px 24) 'Right'

    $button = New-Rect (Px 18) (Px ($bottom + 32)) (Px ($PopupWidth - 36)) (Px 36)
    $buttonColor = if ($map.Hover -eq 'hub') { $P.AccentHover } else { $P.Accent }
    Fill-Round $g $button (Px 8) $buttonColor
    Draw-Text $g 'Entrar a ClaudeMaxxing' $F.Button $P.AccentText $button.X $button.Y $button.Width $button.Height 'Center'
    Add-Hit $map 'hub' $button {
        $script:Popup.Hide()
        Show-HubDialog
    }

    $g.DrawRectangle($pen, 0, 0, $w - 1, $h - 1)
    $pen.Dispose()
})

$Popup.Add_Deactivate({
    $script:Popup.Hide()
    $script:LastHidden = Get-Date
})

$Popup.Add_HandleCreated({ Set-RoundedWindow $script:Popup $script:Palette.Border })

function Show-Popup {
    Update-UsageState
    if (-not $script:View.Fresh -and ((Get-Date) - $script:LastRefreshAt).TotalMinutes -ge 2) { Start-UsageRefresh }
    Move-PopupToCorner
    $script:Popup.Show()
    $script:Popup.Activate()
    $script:Popup.Invalidate()
}

function Switch-Popup {
    if ($script:Popup.Visible) { $script:Popup.Hide(); return }
    # The click that deactivated the popup also lands here; do not reopen it immediately.
    if (((Get-Date) - $script:LastHidden).TotalMilliseconds -lt 400) { return }
    Show-Popup
}

# ---------------------------------------------------------------- tray icon

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$Notify.Icon = Get-TrayIcon
$Notify.Text = 'Claude'
$Notify.Visible = -not $Rendering

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Entrar a ClaudeMaxxing...', $null, { Show-HubDialog })
[void]$menu.Items.Add((Tx 'Planear sesi\u00f3n del d\u00eda...'), $null, { Show-HubDialog 'plan' })
[void]$menu.Items.Add('Ver uso', $null, { Show-Popup })
[void]$menu.Items.Add('Actualizar datos', $null, { Start-UsageRefresh })
[void]$menu.Items.Add((Tx 'Agendar sesi\u00f3n...'), $null, { Show-ScheduleDialog; Update-ScheduleState })
[void]$menu.Items.Add('Plan semanal...', $null, { Show-ScheduleDialog -Tab 'plan'; Update-ScheduleState })
[void]$menu.Items.Add('Abrir uso en claude.ai', $null, { Start-Process 'https://claude.ai/settings/usage' })
[void]$menu.Items.Add('-')
# Claude Whisper: live call copilot in its own process (whisper.ps1).
[void]$menu.Items.Add('Claude Whisper', $null, { Start-WhisperWindow $TrayRoot })
# Otros PCs: terminals on paired PCs and the incoming sessions, rebuilt each time the submenu opens.
$script:BridgeMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Otros PCs')
[void]$script:BridgeMenu.DropDownItems.Add('Abrir Otros PCs...', $null, { Show-BridgeDialog })
$script:BridgeMenu.Add_DropDownOpening({ Update-BridgeMenu $script:BridgeMenu })
[void]$menu.Items.Add($script:BridgeMenu)
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Salir', $null, { [System.Windows.Forms.Application]::Exit() })
$Notify.ContextMenuStrip = $menu

$Notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-Popup }
})
$Notify.Add_BalloonTipClicked({
    if ($script:BridgeBalloonAction -eq 'dialog') { Show-BridgeDialog }
    elseif ($script:BridgeBalloonAction -eq 'whisper') { Start-WhisperWindow $TrayRoot }
})

# Like a meeting assistant: when a call app starts using the microphone, offer Claude Whisper. Only once
# Claude Whisper has been used on this PC (its settings exist), and not while it is open.
$script:MeetingAppsSeen = @()
function Test-MeetingStarted {
    if (-not (Test-Path -LiteralPath $WhisperSettingsFile) -or (Test-WhisperRunning)) { $script:MeetingAppsSeen = @(); return }
    if (-not (Get-WhisperSettings (Read-JsonFile $WhisperSettingsFile)).meetingNotice) { return }
    try { Import-WhisperNative; $apps = Get-MeetingApps ([ClaudeWhisper.AudioCapture]::MicrophoneUsers()) } catch { return }
    $new = @($apps | Where-Object { $script:MeetingAppsSeen -notcontains $_ })
    $script:MeetingAppsSeen = $apps
    if ($new.Count -eq 0 -or -not $script:Notify.Visible) { return }
    $script:BridgeBalloonAction = 'whisper'
    $script:Notify.ShowBalloonTip(6000, 'Claude Whisper', ((Tx '{0} est\u00e1 usando el micr\u00f3fono. Haz clic para abrir Claude Whisper.') -f $new[0]),
        [System.Windows.Forms.ToolTipIcon]::Info)
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$script:Ticks = 0
$timer.Add_Tick({
    $script:Ticks++
    if ($script:Ticks % 20 -eq 0) { Update-ScheduleState }
    # Agenda automatica (lib\hubauto.ps1): a stats scan finished with the window closed, and the hourly sync.
    if (-not $script:HubDialog) { Complete-HubStatsScan }
    Invoke-AutoSchedule
    Test-MeetingStarted
    Update-UsageState
    if ($script:Popup.Visible) { $script:Popup.Invalidate() }
})

Update-ScheduleState
Update-UsageState

# Otros PCs: the first tick sets it up (keys, firewall check, server), so the icon shows without waiting for it.
$script:BridgeTimer = New-Object System.Windows.Forms.Timer
$script:BridgeTimer.Interval = 400
$script:BridgeTimer.Add_Tick({ Invoke-BridgeTick })

if ($RenderHubTo) {
    Show-HubDialog $HubSection $RenderHubTo
    $Notify.Dispose()
    exit 0
}

if ($RenderBridgeTo -or $RenderApprovalTo) {
    Set-BridgePreview
    if ($RenderBridgeTo) { Show-BridgeDialog $RenderBridgeTo }
    if ($RenderApprovalTo) { Show-ApprovalForm $RenderApprovalTo }
    $Notify.Dispose()
    exit 0
}

if ($RenderDialogTo) {
    Show-ScheduleDialog $RenderDialogTo $PreviewCloud $DialogTab
    $Notify.Dispose()
    exit 0
}

if ($RenderTo) {
    $Popup.Location = New-Object System.Drawing.Point(-5000, -5000)
    $Popup.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($Popup.Width, $Popup.Height)
    $Popup.DrawToBitmap($bmp, (New-Rect 0 0 $Popup.Width $Popup.Height))
    $bmp.Save($RenderTo)
    $Notify.Dispose()
    exit 0
}

$timer.Start()
$script:BridgeTimer.Start()
Start-UsageRefresh
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    $script:BridgeTimer.Stop()
    Stop-BridgeTray
    $Notify.Visible = $false
    $Notify.Dispose()
    Remove-Item -LiteralPath $TrayPidFile -ErrorAction SilentlyContinue
    $script:TrayMutex.ReleaseMutex()
}
