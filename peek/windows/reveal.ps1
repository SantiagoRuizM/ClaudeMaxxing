# Peek's click on Windows: shows PEEK_FILE selected in Explorer, or with PEEK_OPEN=1 opens it with its
# app (a video plays, a PDF opens). Explorer takes /select,"<path>" with the quotes inside the argument.
$path = $env:PEEK_FILE
if (-not $path -or -not (Test-Path -LiteralPath $path)) { exit 1 }
# The path comes from the model's reply: a program, script or shortcut is only shown, never run by a click.
$runs = @("$env:PATHEXT" -split ';') + '.lnk', '.url', '.msi', '.msp', '.ps1', '.psm1', '.hta', '.scr', '.cpl', '.jar',
    '.reg', '.pif', '.scf', '.inf', '.appref-ms', '.application', '.settingcontent-ms' | Where-Object { $_ }
$isProgram = (Test-Path -LiteralPath $path -PathType Leaf) -and ($runs -contains [IO.Path]::GetExtension($path))
if ($env:PEEK_OPEN -eq '1' -and -not $isProgram) { [void][System.Diagnostics.Process]::Start($path) }
else { [void][System.Diagnostics.Process]::Start('explorer.exe', '/select,"' + $path + '"') }
