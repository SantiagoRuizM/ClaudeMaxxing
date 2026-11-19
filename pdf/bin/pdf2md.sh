#!/usr/bin/env bash
# ClaudeMaxxing PDF: runs pdf2md.py with the plugin's own Python (install.ps1 makes pdf\venv with PyMuPDF).
# -I: nothing from the current folder (the user's project) is imported.
#   bash pdf2md.sh <file.pdf> [--pages 1-3,7] [-o out.md]
dir="$(cd "$(dirname "$0")" && pwd)"
py="$dir/../venv/Scripts/python.exe"
if [ ! -f "$py" ]; then
  echo "ClaudeMaxxing PDF: PyMuPDF is not installed (run ClaudeMaxxing's install.ps1 again). Read the PDF with the Read tool instead." >&2
  exit 2
fi
exec "$py" -I "$dir/pdf2md.py" "$@"
