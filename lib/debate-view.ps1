# The live view of one debate (lib\debate.ps1) in a terminal window: the transcript as the worker writes it, and
# where the debate is. Opened by the tray for both sides. Usage: debate-view.ps1 -Dir <bridge>\debates\<id>
param([Parameter(Mandatory = $true)][string]$Dir)

$TrayRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $TrayRoot 'lib\common.ps1')
. (Join-Path $TrayRoot 'lib\bridge.ps1')
. (Join-Path $TrayRoot 'lib\debate.ps1')
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$transcript = Join-Path $Dir 'transcript.md'

$shown = ''
while ($true) {
    $status = Get-DebateStatus $Dir
    $text = if (Test-Path -LiteralPath $transcript) { [IO.File]::ReadAllText($transcript, [Text.Encoding]::UTF8) } else { '' }
    $line = if ($status) { [string]$status.message } else { 'Preparando...' }
    if ($text + $line -ne $shown) {
        $shown = $text + $line
        Clear-Host
        Write-Host $text
        $color = if (-not $status) { 'Gray' } elseif ($status.state -eq 'error') { 'Red' } elseif ($status.state -eq 'done') { 'Green' } else { 'Yellow' }
        Write-Host ('> ' + $line) -ForegroundColor $color
    }
    if ($status -and $status.state -ne 'running') { break }
    Start-Sleep -Seconds 1
}
Write-Host ''
Write-Host ('Transcripci' + (Tx '\u00f3') + "n guardada en $transcript") -ForegroundColor DarkGray
Write-Host 'Pulsa una tecla para cerrar.' -ForegroundColor DarkGray
[void][Console]::ReadKey($true)
