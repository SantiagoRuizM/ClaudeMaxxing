# Peek's click on Windows: shows PEEK_FILE selected in Explorer, or with PEEK_OPEN=1 opens it with its
# app (a video plays, a PDF opens). Explorer takes /select,"<path>" with the quotes inside the argument.
$path = $env:PEEK_FILE
if (-not $path -or -not (Test-Path -LiteralPath $path)) { exit 1 }
if ($env:PEEK_OPEN -eq '1') { [void][System.Diagnostics.Process]::Start($path) }
else { [void][System.Diagnostics.Process]::Start('explorer.exe', '/select,"' + $path + '"') }
