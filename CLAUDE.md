# VoiceTray

Uso del plan de Claude en la bandeja de Windows, sesiones de Claude Code abiertas desde el menú del Explorador en mitades de pantalla, y voz por sesión (ClaudeVoice, en `voice/`). Ver `README.md` y `voice/README.md`.

## Al trabajar en este proyecto

- Los `.ps1` deben quedar en **ASCII** (sin tildes ni emojis en el código). Windows PowerShell 5.1 lee los scripts sin BOM como ANSI. Los textos con tildes van como `\uXXXX` (`Tx` en `lib/common.ps1`) o llegan por JSON/archivos UTF-8 (`voice/config.json`).
- `lib/common.ps1` y `voice/hooks/common.ps1` definen funciones y variables con el mismo nombre (`Read-JsonFile`, `Write-JsonFile`, `$Utf8`...). No los cargues en el mismo ámbito: desde la parte de la bandeja, carga lo de voz dentro de `& { . ... }`. Las variables de PowerShell no distinguen mayúsculas: no reutilices los nombres globales de `voice/hooks/common.ps1` (`$MuteFile`, `$StateDir`, `$Root`, `$LogFile`...) para variables locales.
- Los hooks no pueden escribir en stdout salvo su JSON de salida (en `UserPromptSubmit` se añadiría al prompt), escapan lo no ASCII (`Write-HookOutput`) y siempre salen con código 0.
- Pruebas:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1` (bandeja, huecos, menú; revisa además que todos los `.ps1` del repo sean ASCII y parseen).
  - `powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1` (voz, sin audio).
- Para probar el lanzador sin tocar las sesiones reales: `open-session.ps1 -StatePath <json aparte> -Run <comando>`, con `$env:CLAUDEVOICE='off'` para que no hable.
