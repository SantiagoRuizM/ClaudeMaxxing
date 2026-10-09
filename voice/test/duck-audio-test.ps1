# Prueba CON AUDIO de la bajada de musica (no forma parte de run-tests.ps1).
# Usa como "musica" una copia renombrada de ffplay con un tono muy bajo: ffplay.exe esta
# excluido de la bajada (es el reproductor de las voces) y asi tampoco se toca su volumen.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\duck-audio-test.ps1
. "$PSScriptRoot\..\hooks\common.ps1"
Import-Native
$ctl = "$PSScriptRoot\..\ctl.ps1"

$fake = Join-Path $StateDir 'musica-de-prueba.exe'
Copy-Item (Find-Exe (Get-Opt (Get-VoiceConfig) 'ffplay' '') 'ffplay') $fake -Force
$music = Start-Process $fake -ArgumentList '-nodisp', '-loglevel', 'quiet', '-f', 'lavfi', '-i', 'sine=frequency=330', '-af', 'volume=0.02' -PassThru -WindowStyle Hidden
Start-Sleep 2
$musicId = ([ClaudeVoice.Mixer]::Snapshot([int[]]@($PID)).Trim() -split "`n") | Where-Object { $_ -match 'musica-de-prueba' } |
    ForEach-Object { $_.Split("`t")[0] } | Select-Object -First 1
function Vol {
    $l = [ClaudeVoice.Mixer]::Snapshot([int[]]@($PID)) -split "`n" | Where-Object { $_.StartsWith($musicId) }
    if ($l) { [math]::Round([double]$l.Split("`t")[1], 2) } else { '?' }
}
function Watch([int]$Seconds) { (1..($Seconds * 2) | ForEach-Object { Vol; Start-Sleep -Milliseconds 500 }) -join ' ' }

try {
    "volumen inicial de la musica: $(Vol)"
    Start-Utterance 'Uno: termine el login.' 'duckt-uno'
    Start-Utterance 'Dos: ya compare las voces.' 'duckt-dos'
    "1) dos voces en cola (debe bajar una vez y subir una vez): $(Watch 14)"

    $child = '. "' + "$PSScriptRoot\..\hooks\common.ps1" + '"; $null = Invoke-Duck (Get-VoiceConfig)'
    powershell -NoProfile -ExecutionPolicy Bypass -Command $child
    "2) reproductor huerfano la deja baja: $(Vol); duck.json: $(Test-Path $DuckFile)"
    & $ctl stop | Out-Null
    "   tras ctl stop: $(Vol); duck.json: $(Test-Path $DuckFile)"
} finally {
    Stop-Process $music.Id -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item $fake -Force -ErrorAction SilentlyContinue
    # No dejar estas pruebas en el historial ni en las sesiones reales
    Get-ChildItem $StateDir, $HistoryDir -Filter '*duckt-*' -ErrorAction SilentlyContinue |
        ForEach-Object { [IO.File]::Delete($_.FullName) }
}
