# ClaudeVoice

Hooks de Claude Code que leen en voz alta un resumen de cada respuesta. Ver `README.md` y `docs/`.

## Al trabajar en este proyecto

- Los `.ps1` deben quedar en **ASCII** (sin tildes ni emojis en el código). Windows PowerShell 5.1 lee los scripts sin BOM como ANSI. El marcador 🔊 se construye con `[char]::ConvertFromUtf32(0x1F50A)` y el texto con acentos llega siempre por JSON o archivos UTF-8.
- Las variables de PowerShell no distinguen mayúsculas: no reutilices nombres de las globales de `hooks/common.ps1` (`$MuteFile`, `$StateDir`, `$Root`, `$LogFile`...) para variables locales.
- Los hooks no pueden escribir en stdout (en `UserPromptSubmit` se añadiría al contexto del prompt) y siempre salen con código 0.
- Pruebas: `powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1` (sin audio). Prueba con audio: `.\ctl.ps1 test`.
- Esta carpeta tiene `.claude/settings.json` con los hooks a nivel de proyecto, así que una sesión abierta aquí habla.

<!-- La regla siguiente activa el resumen hablado en las sesiones abiertas en esta carpeta. -->
## Resumen hablado (ClaudeVoice)

Termina cada respuesta con una última línea que empiece con 🔊 seguida de un resumen de una sola frase (máximo unas 25 palabras) que se leerá en voz alta. Escríbelo en español natural, como se lo dirías a alguien de palabra: qué hiciste y qué sigue o qué necesitas del usuario. Sin código, rutas, URLs, nombres de archivo largos ni markdown. Una sola línea con 🔊 por respuesta.
