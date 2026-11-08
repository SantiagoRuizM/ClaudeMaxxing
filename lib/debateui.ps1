# Debates in the tray (lib\debate.ps1): "Debatir con <PC>..." in the Otros PCs menu starts one as the host, and
# Permitir on an incoming debate (lib\bridgeui.ps1) joins it as the guest. Either way the user picks the one folder
# their Claude may read, and a terminal shows the debate live (lib\debate-view.ps1).
# Needs bridgeui.ps1, hubplan.ps1 (its dialog helpers) and debate.ps1. Keep this file ASCII.

$script:DebateAccepted = $null

function Open-DebateView([string]$Dir, [string]$PeerName) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Dir "{1}"' -f (Join-Path $TrayRoot 'lib\debate-view.ps1'), $Dir
    try { Start-Process -FilePath 'wt.exe' -ArgumentList ('-w new --title "Debate con {0}" powershell.exe {1}' -f $PeerName, $arguments) -ErrorAction Stop }
    catch { Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments }
}

# '' when the user cancels. A drive root or the whole profile is refused: Claude reads one project.
function Select-DebateFolder($Owner) {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = Tx 'Carpeta del proyecto que tu Claude puede leer en el debate. Solo lee: no ejecuta nada y no se env\u00eda ning\u00fan archivo entero.'
    try {
        while ($picker.ShowDialog($Owner) -eq 'OK' -and $picker.SelectedPath) {
            if (-not (Test-DebateFolderTooBroad $picker.SelectedPath)) { return $picker.SelectedPath }
            [void][System.Windows.Forms.MessageBox]::Show($Owner, (Tx 'Esa carpeta es demasiado amplia. Elige la carpeta de un proyecto.'), 'Debate')
        }
        ''
    } finally { $picker.Dispose() }
}

# The topic, or $null when cancelled.
function Show-DebateTopicDialog([string]$PeerName) {
    $P = $script:Palette
    $dlg = New-JudgeForm ('Debatir con ' + $PeerName) $P 560 440
    Add-JudgeRow $dlg (New-JudgeLabel ((Tx 'Tu Claude y el de ') + $PeerName + (Tx ' debaten, cada uno desde su propio proyecto, y les dan una recomendaci\u00f3n. Escribe la pregunta o la decisi\u00f3n con lo que importa: opciones, l\u00edmites, plazos.')) $P.Muted)
    Add-JudgeRow $dlg (New-JudgeLabel 'TEMA' $P.Muted $script:Fonts.Caps)
    $box = New-JudgeBox '' $P $false
    Add-JudgeRow $dlg $box 100
    Add-JudgeRow $dlg (New-JudgeLabel ((Tx 'Despu\u00e9s eliges la carpeta que tu Claude puede leer, y ') + $PeerName + (Tx ' tiene que aceptar en su PC. Cada uno usa su plan (Sonnet): 4 llamadas aqu\u00ed y 3 all\u00e1.')) $P.Faint $script:Fonts.Small)
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.FlowDirection = 'RightToLeft'
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $go = New-WhisperButton 'Elegir carpeta y debatir' $P $true
    $cancel = New-WhisperButton 'Cancelar' $P
    $go.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.Add($go); $buttons.Controls.Add($cancel)
    Add-JudgeRow $dlg $buttons
    $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ $box.Focus() })
    $result = $dlg.ShowDialog()
    $topic = $box.Text.Trim()
    $dlg.Dispose()
    if ($result -ne 'OK' -or -not $topic) { return $null }
    $topic
}

# Host: the menu item.
function Start-DebateWith([string]$PeerId) {
    $b = $script:Bridge
    $peer = Find-BridgePeer $PeerId
    if (-not $b -or -not $peer) { return }
    $topic = Show-DebateTopicDialog $peer.name
    if (-not $topic) { return }
    $folder = Select-DebateFolder $null
    if (-not $folder) { return }
    $dir = Join-Path (Get-DebateRoot $b.Ctx) (New-DebateId)
    [void](Start-DebateWorker $b.Ctx $dir 'host' $peer.id $topic $folder)
    Write-BridgeLog $b.Ctx "debate started with $($peer.name): $(Split-Path -Leaf $dir)"
    Open-DebateView $dir $peer.name
}

# Guest: after Permitir on a debate, once the approval dialog is answered. The gate has stored the host's open;
# cancelling the folder still starts the worker, which only tells the host.
function Complete-DebateAccept {
    $request = $script:DebateAccepted
    $script:DebateAccepted = $null
    if (-not $request -or -not $script:Bridge) { return }
    $id = Get-DebateIdFromCommand $request.Command
    if (-not $id) { return }
    $folder = Select-DebateFolder $script:ApprovalForm
    $dir = Join-Path (Get-DebateRoot $script:Bridge.Ctx) $id
    [void](Start-DebateWorker $script:Bridge.Ctx $dir 'guest' $request.Peer.id (Get-DebateTopic $request) $folder)
    if ($folder) { Open-DebateView $dir $request.Peer.name }
}
