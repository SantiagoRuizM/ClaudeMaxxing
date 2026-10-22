@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-claude.ps1" %*
@exit /b %ERRORLEVEL%
