# Sonda temporal (ctl.ps1 probe on): registra que eventos de hooks dispara Claude Code y con
# que datos, para averiguar si /btw pasa por algun hook. Guarda el JSON crudo (sin rutas largas)
# en vez de elegir campos por nombre: los campos reales no coinciden con la documentacion.
# No escribe en stdout.
. "$PSScriptRoot\common.ps1"

try {
    $stdin  = [Console]::OpenStandardInput()
    $buffer = New-Object IO.MemoryStream
    $stdin.CopyTo($buffer)
    $raw = $Utf8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
    if ($raw.Trim()) {
        $evt = $raw | ConvertFrom-Json
        foreach ($noise in 'transcript_path', 'cwd', 'permission_mode', 'effort') { $evt.PSObject.Properties.Remove($noise) }
        $json = $evt | ConvertTo-Json -Compress -Depth 6
        if ($json.Length -gt 600) { $json = $json.Substring(0, 600) + '...' }
        $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $json
        [IO.File]::AppendAllText((Join-Path $StateDir 'probe.log'), $line + [Environment]::NewLine, $Utf8)
    }
} catch {
    Write-Log "probe: $_"
}
exit 0
