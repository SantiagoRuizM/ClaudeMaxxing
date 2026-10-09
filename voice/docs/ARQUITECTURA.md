# Arquitectura y decisiones

## Flujo

1. Claude termina el turno y Claude Code dispara `Stop` con un JSON por stdin que incluye `last_assistant_message`.
2. `hooks/speak.ps1` lee stdin como bytes UTF-8, carga `config.json`, revisa si está habilitado o silenciado y extrae el texto con `Get-SpokenText`:
   - la **última** línea que empieza con el marcador (se permiten `>`, `*`, `_` o espacios delante, por si Claude la pone en cursiva o en cita);
   - si no la hay, el `fallback` (primera frase del texto sin código, títulos, tablas ni URLs).
3. `Start-Utterance` corta cualquier reproducción previa, escribe el texto en un archivo temporal UTF-8 y lanza `hooks/play.ps1` en un `powershell.exe` oculto e independiente. Guarda su PID y su hora de inicio en `%TEMP%\claude-voice\player.json`. El hook sale de inmediato.
4. `play.ps1` intenta edge-tts (`--file` → mp3 → `ffplay -nodisp -autoexit`). Si edge-tts o ffplay no existen o fallan, usa SAPI. Al terminar borra sus temporales y el archivo de PID si sigue siendo el suyo.
5. Cuando escribes un prompt, `UserPromptSubmit` dispara `hooks/stop-audio.ps1`, que hace `taskkill /T /F` del reproductor (el árbol incluye `ffplay`).

## Varias sesiones

- **Estado por sesión** en `%TEMP%\claude-voice`, con el `session_id` saneado en el nombre del archivo: `voice-<id>` (voz asignada; su fecha de modificación marca la última actividad), `muted-<id>`, `player-<id>.json` (PID del reproductor) y `utt-<id>-*` (temporales). Se borran a los 7 días.
- **Reparto de voces:** la primera del pool que no use ninguna sesión activa en las últimas `sessionActiveHours` horas. Si todas están ocupadas, se reparte de forma rotatoria.
- **Cola:** cada reproductor genera su mp3 en paralelo y luego espera el mutex `Local\ClaudeVoicePlayer` para sonar. Si se mata un reproductor que tenía el mutex, el siguiente recibe `AbandonedMutexException` pero igual se queda con él.
- **Cortes:** una respuesta nueva o un prompt en la sesión A solo matan el reproductor de A, aunque esté esperando en la cola.
- **`/voz`** es una skill: su ``!`ctl.ps1 session ${CLAUDE_SESSION_ID} $ARGUMENTS` `` corre antes del modelo, con `allowed-tools` limitado a ese comando exacto para que no pida permiso.

## Nombre de sesión

- `UserPromptSubmit` es el único evento, además de `SessionStart`, que acepta `sessionTitle`, y el único que ve el primer prompt. Como la salida de un hook async se ignora, `on-prompt.ps1` es **síncrono** (timeout 10 s) y añade ~0,4 s a cada prompt (arranque de PowerShell). Solo escribe JSON la primera vez; las demás veces sale sin salida.
- La salida se escribe con todo lo no-ASCII escapado (`í`) para que la codificación de la consola de PowerShell no rompa tildes ni el emoji 🎙.
- Si la sesión ya tiene título propio (`session_title` en la entrada), no se pisa.
- Rol: se cuentan coincidencias de palabras clave (sin tildes, al inicio de palabra) en el texto del prompt sin los bloques `<pasted_content>`. Gana el rol con más coincidencias.

## Firma musical

- `Chime.cs` sintetiza el acorde por síntesis aditiva: cada nota es una suma de parciales con ataque corto y caída exponencial (los agudos caen antes). Hay seis timbres definidos por sus parciales: campana (inarmónica), marimba (1 : 3,93 : 9,2), piano, cristal (con vibrato suave), kalimba y pluck. Los dibujos (sube, baja, salto, eco, bloque) solo cambian el momento en que entra cada nota. Se normaliza el pico a `chime.volume` y se escribe un WAV mono de 16 bits.
- **Separación de papeles:** el timbre lo decide el rol (tipo de trabajo); el motivo (nota + acorde + dibujo), la sesión. Dos sesiones de código suenan a marimba pero con motivos distintos.
- Se genera una vez por sesión (`chime-<sesión>.wav` + `.json`). Si el rol cambia, por ejemplo en una sesión nombrada después, se regenera con el mismo motivo y el timbre nuevo.
- Suena con `System.Media.SoundPlayer` dentro del propio reproductor: no lanza otro proceso y no cuenta como "música" al bajar volúmenes. La voz entra `leadMs` después (último ataque + 0,45 s), solapada con la cola del acorde.
- **Candado de asignación** (`Use-StateLock`, mutex `Local\ClaudeVoiceState`): dos sesiones que terminaron a la vez preparaban su audio en paralelo y salieron con el mismo motivo. Ahora voz, nombre y firma se asignan dentro del candado. Probado: seis procesos simultáneos → seis motivos distintos.

## Historial y repetir

- `play.ps1` guarda cada audio que va a decir (`history/<fecha>-<sesión>.json` + `.mp3`) **antes** de esperar turno, así que también queda lo que cortaste.
- Repetir crea un trabajo con varios items que un solo reproductor dice seguidos, en orden. Con un proceso por item, el mutex no garantiza el orden.

## Bajar la música

- `Mixer.cs` usa Core Audio (`IAudioSessionManager2` → `ISimpleAudioVolume`) para leer y ajustar el volumen de cada app que **está sonando**, sin tocar los sonidos del sistema ni el volumen general. Se compila una vez a `%TEMP%\claude-voice\Mixer-<hash>.dll`.
- Antes de bajar se guarda en `duck.json` el volumen original de cada app y quién la bajó (PID y hora de inicio). Así cualquiera puede restaurarla si el reproductor muere: `Stop-Playback` tras un `taskkill`, o el siguiente reproductor.
- **Traspaso en la cola:** si al terminar hay otro reproductor vivo esperando, no se sube la música. Se marca `duck.json` sin dueño (`pid -1`) **antes** de soltar el mutex y el siguiente la hereda. Sin la marca había una carrera: el anterior seguía vivo unos milisegundos, el siguiente no heredaba, tomaba el volumen ya bajo como "original" y la música se quedaba baja.
- **`ffplay.exe` nunca se baja.** Windows recuerda el volumen por programa: si una app se cierra mientras está bajada, vuelve a abrir al 20 %. Le pasó a `ffplay` (el reproductor de las voces) en una prueba, y las voces siguientes habrían sonado al 20 %. Por eso las pruebas usan como música una copia renombrada (`test/duck-audio-test.ps1`). Riesgo que queda: si cierras Spotify justo mientras Claude habla, Spotify se abrirá al 20 % la próxima vez. Súbelo en el mezclador de volumen de Windows; con la app cerrada no hay forma de restaurarlo.
- `ctl stop` (y Ctrl+Alt+Shift+P) siempre intenta restaurar la música, aunque no haya ningún reproductor que matar.
- Medido con un tono de prueba: tres sesiones seguidas → baja una vez, se mantiene en 0,2 durante las tres voces y sube una vez al final. Corte a mitad de frase → vuelve a 1 de inmediato.

## Decisiones

| Decisión | Por qué |
|---|---|
| Hook `command` y no `http` | No exige un servidor corriendo. HTTP tiene sentido cuando haya un daemon persistente (ver siguientes pasos) |
| Exec form (`command` + `args`) | Sin Git Bash de por medio: sin problemas de comillas ni de rutas Windows ↔ POSIX y un proceso menos. Es la forma que muestra la doc para PowerShell |
| `async: true` **y** proceso desacoplado | `async` evita bloquear a Claude. El proceso aparte permite cortar el audio desde otro hook y que la reproducción no dependa del ciclo de vida del hook |
| Marcador 🔊 en la propia respuesta | Cero llamadas extra al modelo, y Claude conoce mejor que nadie qué hizo |
| Cortar en vez de encolar | Si llega una respuesta nueva, la anterior ya no importa. Más simple y sin solapamientos |
| PID + hora de inicio | Evita matar un proceso ajeno que haya heredado el PID |
| edge-tts por defecto, SAPI de respaldo | Calidad por defecto; si no hay red, sigue hablando |
| Estado en `%TEMP%\claude-voice` | Silenciar, PID y log no ensucian el proyecto ni requieren permisos |

## Trampas de Windows (todas encontradas al construir el MVP)

- **PowerShell 5.1 lee los `.ps1` sin BOM como ANSI.** Una tilde o un emoji en el código se rompe. Por eso los scripts son ASCII y el marcador se construye con `[char]::ConvertFromUtf32(0x1F50A)`.
- **`[Console]::InputEncoding` puede lanzar excepción** si el proceso no tiene consola (caso típico de un hook). Se lee stdin como bytes y se decodifica UTF-8 a mano.
- **Al hacer pipe hacia un proceso externo, PowerShell 5.1 manda ASCII** (`$OutputEncoding`). Rompió el primer test: "Arreglé" llegaba como "Arregl?" y el `?` cortaba la "primera frase". Claude Code manda UTF-8, así que solo afecta a pruebas manuales; el test fija `$OutputEncoding`.
- **Con `$ErrorActionPreference = 'Stop'`, el stderr de un ejecutable nativo** se convierte en error terminante en PS 5.1. `play.ps1` no usa `Stop` y descarta la salida de edge-tts y ffplay.
- **Un proceso matado no limpia sus temporales**, así que `Stop-Playback` borra los `utt-*` sobrantes.
- **Las variables de PowerShell no distinguen mayúsculas.** `$muteFile` (de la sesión) pisaba a `$MuteFile` (el global) y `/voz todo-off` silenciaba solo una sesión. Lo detectó un test; ahora se llama `$sessionMute`.
- **Git Bash convierte argumentos que empiezan con `/` en rutas** (`/voz` → `C:/Program Files/Git/voz`). Afecta a `claude -p "/voz ..."` lanzado desde Git Bash; se evita con `MSYS_NO_PATHCONV=1`.
- **`ConvertTo-Json` de PS 5.1 tiene `-Depth 2` por defecto** y trunca objetos anidados; `install.ps1` usa `-Depth 32`. El JSON resultante queda con la indentación peculiar de PS 5.1, pero es válido.

## Latencia aproximada

| Motor | Hasta oír la primera palabra |
|---|---|
| SAPI | ~1 s (estimado: dos arranques de PowerShell y carga de System.Speech; sin medir con precisión) |
| edge-tts | ~3-4 s (lo anterior + 2,6 s medidos para generar el mp3 por red + arranque de ffplay) |
