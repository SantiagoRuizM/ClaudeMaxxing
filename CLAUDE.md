# ClaudeMaxxing

Uso del plan de Claude en la bandeja de Windows, sesiones de Claude Code abiertas desde el menú del Explorador en mitades de pantalla, voz por sesión (`voice/`) y Claude Whisper, el copiloto de llamadas (`whisper.ps1`, `lib/whisper*`). Ver `README.md` y `voice/README.md`.

## Al trabajar en este proyecto

- **El repo es solo el instalador.** Lo que corre (bandeja, lanzador del menú, hooks de voz) es la copia en `%LOCALAPPDATA%\ClaudeMaxxing`; la extensión del menú vive en `%LOCALAPPDATA%\ClaudeCodeMenu`. Después de editar, ejecuta `install.ps1` para desplegar; si no, el cambio no se ve. Nada instalado puede apuntar al repo (lo comprueba `test\run-tests.ps1`).
- Un archivo nuevo que deba ir a la instalación tiene que estar en `lib/installer.ps1` (`$RuntimeFiles` o dentro de `$RuntimeDirs`).
- Lo propio de cada PC va en `voice\config.local.json` de la instalación, nunca en `voice/config.json` del repo (no subas rutas de este PC).
- Menú: los binarios de `menu/bin` (DLL, stub, MSIX sin firmar) se suben al repo. Tras cambiar `menu/src`, ejecuta `menu\build.cmd`; tras cambiar el manifiesto o los logos, `menu\package.ps1` y sube la `Version` del manifiesto. Cada PC firma su copia al instalar.
- Los `.ps1` deben quedar en **ASCII** (sin tildes ni emojis en el código). Windows PowerShell 5.1 lee los scripts sin BOM como ANSI. Los textos con tildes van como `\uXXXX` (`Tx` en `lib/common.ps1`) o llegan por JSON/archivos UTF-8 (`voice/config.json`).
- `lib/common.ps1` y `voice/hooks/common.ps1` definen funciones y variables con el mismo nombre (`Read-JsonFile`, `Write-JsonFile`, `$Utf8`...). No los cargues en el mismo ámbito: desde la parte de la bandeja, carga lo de voz dentro de `& { . ... }` o en otro proceso. Las variables de PowerShell no distinguen mayúsculas: no reutilices los nombres globales de `voice/hooks/common.ps1` (`$MuteFile`, `$StateDir`, `$Root`, `$LogFile`...) para variables locales.
- Los hooks no pueden escribir en stdout salvo su JSON de salida (en `UserPromptSubmit` se añadiría al prompt), escapan lo no ASCII (`Write-HookOutput`) y siempre salen con código 0.
- No renombres los identificadores internos heredados (`ClaudeTrayWin`, los mutex `Local\ClaudeTray*`, los marcadores `# >>> ClaudeTray` de la statusline, `HKCU\Software\ClaudeCodeMenu`, el paquete `ClaudeCode.ContextMenu`): las instalaciones existentes dependen de ellos.
- Pruebas:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1` (bandeja, huecos, instalador, paquete del menú; revisa además que todos los `.ps1` del repo sean ASCII y parseen).
  - `powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1` (voz, sin audio).
  - Otros PCs (`lib/bridge*.ps1`, `lib/bridgegate.cs`), con dos PCs falsos en loopback y el OpenSSH instalado (o `-SshDir`): `test\bridge-e2e.ps1` (protocolo, `sshd`, los tres clientes `ssh`) y `test\bridge-tray-e2e.ps1` con `-STA` (las funciones de la bandeja). No están en el CI.
- Otros PCs: el `sshd` corre como el usuario, lanzado por la bandeja (sin servicio); la bandeja instalada lo para al salir y `Stop-RecordedTray` también. Las rutas que leen los clientes `ssh` van como `~/...` (`Format-SshClientPath`): el `ssh` de Git, el que usa Claude Code, toma `C:/...` en `Include` como relativo a `~/.ssh`.
- Las herramientas convierten `\uXXXX` en el carácter real al escribir archivos: para dejar `\u00f3` literal en un `.ps1`, revisa que el archivo siga siendo ASCII (lo comprueba `test\run-tests.ps1`).
- Para probar el lanzador sin tocar las sesiones reales: el `open-session.ps1` instalado con `-StatePath <json aparte> -Run <comando>`, `$env:CLAUDEVOICE='off'` y `$env:TEMP` apuntando a una carpeta aparte (ahí guarda la voz su estado).
