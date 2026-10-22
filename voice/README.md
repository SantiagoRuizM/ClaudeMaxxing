# Voz (ClaudeMaxxing)

> **Dónde se ejecuta:** el `install.ps1` de la raíz del repo copia esta carpeta a `%LOCALAPPDATA%\ClaudeMaxxing\voice`, y todo corre desde ahí. Los comandos `.\ctl.ps1` y `.\install.ps1` de esta página se lanzan en esa carpeta (`cd "$env:LOCALAPPDATA\ClaudeMaxxing\voice"`). Tus cambios de configuración van en `config.local.json`, que se aplica encima de `config.json` y se conserva al actualizar; `config.json` se reemplaza en cada instalación.

Claude Code te responde en voz alta. Cuando Claude termina un turno, un hook `Stop` toma la respuesta, extrae una línea de resumen marcada con 🔊 y la lee con el motor de voz que elijas en **ClaudeMaxxing > Voz**:

| Motor | Cómo suena | Qué necesita |
|---|---|---|
| **Edge** (por defecto) | Voces neuronales de Microsoft | Nada: gratis y sin clave (edge-tts, que el instalador mantiene al día) |
| **ElevenLabs** | La más natural y fluida | Una cuenta gratis en elevenlabs.io: unos 10.000 créditos al mes con el modelo Flash v2.5, unos 100 resúmenes. Pega la clave (`sk_…`) con **Pegar clave ElevenLabs**; usa las voces de tu cuenta, una distinta por sesión y del mismo género que su nombre |
| **Gemini** | Muy natural, tono cálido y conversacional | Una clave gratis de Google AI Studio (`AIza…`), con límite diario. **Pegar clave Gemini** |
| **Windows** | La voz local (SAPI) | Nada; funciona sin internet |

Si el motor elegido falla (sin clave, sin créditos, límite del día, sin red), esa frase se lee con Edge, y si Edge también falla, con la voz de Windows. Un motor que se queda sin créditos o rechaza la clave se aparta un rato para no esperar su error en cada frase. La cuenta gratis de ElevenLabs no permite uso comercial.

- **Cada sesión tiene nombre, rol, voz y firma musical propios.** Con el primer prompt, la sesión pasa a llamarse por ejemplo "Valentina · codificadora" (título de la sesión en Claude Code). Cada mensaje empieza con su acorde y sigue con "Soy Valentina, codificadora. Terminé el login."
- **Firma musical**: un acorde corto, único entre las sesiones activas. El timbre dice el tipo de trabajo (marimba = código, cristal = investigación, piano = redacción…) y el acorde, la nota y el dibujo dicen qué sesión es.
- **Cola sin superposiciones**: si varias sesiones terminan a la vez, hablan por turnos.
- **Baja la música mientras habla** (Spotify, Chrome…) y luego la sube con un fundido. Entre voces seguidas de la cola se queda baja.
- **Repetir**: `/voz repetir`, `.\ctl.ps1 repeat` o el atajo global **Ctrl+Alt+Shift+O** (oír otra vez).
- **Se calla** cuando escribes un mensaje nuevo en esa sesión.
- **`/voz`** dentro de Claude Code para activar, silenciar, repetir o cambiar la voz.

```
Primer prompt de la sesión
   └─ hook UserPromptSubmit (síncrono, ~0,4 s) ─► hooks/on-prompt.ps1
         ├─ calla el audio de ESA sesión
         └─ la 1.ª vez: voz del pool → nombre aleatorio de su género + rol según el prompt
            → sessionTitle "Valentina · codificadora" + aviso en pantalla

Claude termina el turno
   └─ hook Stop (async) ─► hooks/speak.ps1 ── "🔊 ..." (o primera frase) → "Soy Valentina, codificadora. ..."
                               ▼
                         play.ps1 (proceso oculto)
                               ├─ genera el audio (ElevenLabs, Gemini o edge-tts) y lo guarda en el historial
                               ├─ prepara la firma de la sesión (WAV sintetizado una vez)
                               ├─ espera turno (mutex compartido entre sesiones)
                               ├─ baja la música (o la hereda ya baja del anterior)
                               ├─ 🎵 acorde de la sesión → la voz entra mientras se apaga
                               ├─ ffplay 🔊   ·   si ningún motor pudo: SAPI (Helena) 🔊
                               └─ sube la música, salvo que otra voz espere turno
```

Cero llamadas extra al modelo: el resumen lo escribe Claude en la misma respuesta (regla que añade `hooks/on-start.ps1` al contexto, o en `CLAUDE.md` con la instalación global) y el rol se deduce por palabras clave.

## Probarlo

**En las sesiones del menú del Explorador (lo que instala el `install.ps1` de la raíz).**
*Abrir con Claude Code* arranca cada sesión con el plugin `plugin/` (`--plugin-dir`), solo para esa sesión: hooks `SessionStart` (`hooks/on-start.ps1`: título con el nombre reservado y la regla del 🔊 en el contexto), `UserPromptSubmit` y `Stop`, y el comando `/voz`. No toca tu `~/.claude`. El nombre y la voz se reservan antes de abrir (`New-ReservedSession`, con el `--session-id` de la sesión) y el primer prompt que no sea un comando completa el rol: "Martín" → "Martín · codificador".

**En todas las sesiones (opcional).**

```powershell
.\install.ps1              # hooks + regla + /voz en ~/.claude (con backup)
.\install.ps1 -Uninstall   # lo quita todo
.\ctl.ps1 hotkeys on       # atajos globales (el instalador ya los activa, salvo con -NoHotkeys)
```

Los hooks se leen al iniciar la sesión: abre una sesión nueva después de instalar.

## Repetir

| Qué | Cómo |
|---|---|
| Lo último de esta sesión | `/voz repetir` (o `/voz repetir 3` para las tres últimas, en orden) |
| Lo último de cualquier sesión | `/voz repetir-todo [n]` · `.\ctl.ps1 repeat [n]` · **Ctrl+Alt+Shift+O** |
| Ver qué se dijo | `.\ctl.ps1 history [n]` |
| Cortar todo | `.\ctl.ps1 stop` · **Ctrl+Alt+Shift+P** |

Se guardan los últimos `historySize` audios (30) con su mp3, así que repetir es instantáneo y suena con la misma voz. Lo que cortaste escribiendo un prompt también queda en el historial. Las repeticiones también bajan la música y hacen cola.

Los atajos los escucha un proceso oculto (`hooks/hotkeys.ps1`) que se inicia con Windows (acceso directo en la carpeta Inicio). Las teclas se cambian en `config.local.json` → `hotkeys` (una letra o F1–F12, siempre con Ctrl+Alt+Shift); después ejecuta `.\ctl.ps1 hotkeys on`. Repetir no usa la R porque en este equipo algo intercepta Ctrl+Alt+R antes de que llegue a cualquier programa. Si una combinación está ocupada, el log lo dice y se reintenta cada 15 s.

## Nombre y rol por sesión

- **Nombre:** aleatorio, del género de la voz asignada (`naming.names.f` / `.m`), sin repetir el de otra sesión activa.
- **Rol:** según las palabras clave del primer prompt (`naming.roles`): codificador/a, investigador/a, editor/a, revisor/a, diseñador/a, analista, arquitecto/a; si no hay pistas, asistente. Lo que pegas en el prompt no cuenta, solo lo que escribes.
- **Título:** se pone como título de la sesión (igual que `/rename`), salvo que ya tenga uno tuyo (`--name` o `/rename`). Se avisa una vez en pantalla: "🎙 Esta sesión es Valentina (codificadora), voz es-CO-SalomeNeural".
- **Qué se dice:** `announceFormat`, por defecto `"Soy {name}, {role}. {text}"`. También admite `{project}` (carpeta). Para solo el mensaje: `"{text}"`.
- **Sesiones ya abiertas** antes de instalar: reciben nombre en su siguiente prompt; si hablan antes, reciben un nombre con rol "asistente".

## Firma musical por sesión

Antes de cada mensaje suena un acorde corto (≈1 s) que identifica la sesión; la voz entra mientras se apaga.

- **Timbre = tipo de trabajo** (`chime.roleTimbres`): código → marimba, investigación → cristal, redacción → piano, revisión → pluck, diseño → kalimba, datos → pluck, arquitectura → piano, asistente → campana.
- **Motivo = la sesión** (`chime.motifs`): 12 combinaciones de nota, acorde (mayor, menor, maj7, sus2, add9, m7, 6/9, cuartas…) y dibujo (sube, baja, salto, eco, bloque). Cada sesión activa recibe uno que no use otra, igual que las voces.
- **Escucharlas todas:** `.\ctl.ps1 chimes` (o `.\ctl.ps1 chimes marimba` para oírlas con otro timbre).
- **Cambiar la de esta sesión:** `/voz sonido 7`. `/voz sonido` toca la actual.
- Las repeticiones también suenan con la firma de su sesión, así sabes de quién era.
- Se sintetiza en local (sin descargas) y se guarda una vez por sesión. `"chime": {"enabled": false}` la apaga; `chime.volume` ajusta el volumen.

## Activar y desactivar

| Alcance | Cómo |
|---|---|
| Esta sesión, desde Claude Code | `/voz off` · `/voz on` · `/voz parar` · `/voz sonido [n]` · `/voz` (estado) |
| Todas las sesiones, desde Claude Code | `/voz todo-off` · `/voz todo-on` |
| Todas las sesiones, desde la terminal | `.\ctl.ps1 mute` · `.\ctl.ps1 unmute` · `.\ctl.ps1 stop` |
| Una sesión desde que la abres | `$env:CLAUDEVOICE='off'; claude` |
| Todas, mientras Claude Whisper escucha una llamada | Automático: vuelven a hablar al pausarlo o cerrarlo |
| Todo, sin desinstalar | `"enabled": false` en `config.local.json` |
| Solo bajar la música / solo los nombres | `"duck": {"enabled": false}` · `"naming": {"enabled": false}` |
| Todo, permanente | `.\install.ps1 -Uninstall` · `.\ctl.ps1 hotkeys off` (quita el proceso de atajos y su inicio automático) |

`/voz` ejecuta `ctl.ps1` antes de que el modelo lo vea, así que el cambio es inmediato; luego Claude solo confirma en una frase. Sin comprobar: qué pasa si lo lanzas mientras Claude trabaja. Para actuar al instante, usa los atajos o `ctl.ps1` desde otra terminal.

## Voz por sesión

Cada sesión nueva recibe la primera voz del pool (`edge.voicePool`) que no use otra sesión activa en las últimas `sessionActiveHours` horas.

El pool tiene 8 voces, una por hueco con hasta 4 pantallas, alternando mujer y hombre: primero las dos colombianas de edge-tts, Salomé y Gonzalo (acento colombiano general; no hay ninguna antioqueña), y luego seis de acento latino neutro: Paloma y Alonso (`es-US`), Dalia y Jorge (`es-MX`), Camila y Alex (`es-PE`). Con más de 8 sesiones activas las voces se repiten; el nombre, el color y la firma musical siguen siendo distintos.

- Cambiarla: `/voz voz gonzalo` (nombre completo o un trozo que identifique una sola voz del pool).
- Fijarla al abrir: `$env:CLAUDEVOICE_VOICE='es-CO-GonzaloNeural'; claude`.
- Ver sesiones: `.\ctl.ps1 sessions` (nombre, rol, voz, silencio).

Sin internet, la voz de respaldo (SAPI) solo tiene una voz en español (Helena), así que todas las sesiones suenan igual; la firma musical y el "Soy …" siguen sirviendo para distinguirlas.

## Comandos de terminal

```powershell
.\ctl.ps1 status          # configuración, sesiones y últimas líneas del log
.\ctl.ps1 test            # frase de prueba
.\ctl.ps1 say Hola mundo  # leer cualquier texto
.\ctl.ps1 repeat [n]      # repetir
.\ctl.ps1 history [n]     # qué se dijo
.\ctl.ps1 stop            # cortar el audio de todas las sesiones
.\ctl.ps1 mute / unmute   # silencio global
.\ctl.ps1 sessions        # nombre, rol y voz de cada sesión
.\ctl.ps1 voices          # voces SAPI y edge-tts en español
.\ctl.ps1 chimes [timbre] # escuchar las 12 firmas musicales
.\ctl.ps1 hotkeys on|off  # atajos globales
.\ctl.ps1 probe on|off|report   # sonda de eventos (ver docs/BTW.md)
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1        # 59 pruebas sin audio
powershell -NoProfile -ExecutionPolicy Bypass -File test\duck-audio-test.ps1   # prueba con audio de la bajada de música
```

## Configuración (`config.json` + `config.local.json`)

Para cambiar algo, escríbelo en `config.local.json` con la misma estructura, solo con las claves que cambian, por ejemplo `{ "engine": "sapi", "edge": { "rate": "+15%" } }`. Los objetos se combinan clave a clave y las listas se reemplazan enteras. El instalador también guarda ahí las rutas de `edge.exe` y `ffplay` que encuentra o instala.

| Clave | Qué hace |
|---|---|
| `enabled` | Interruptor general |
| `engine` | `edge` (voz neuronal gratis, ~3 s), `elevenlabs`, `gemini` o `sapi` (Windows, offline). Si el elegido falla se usa edge, y luego SAPI |
| `elevenlabs.apiKey`, `elevenlabs.model`, `elevenlabs.voices`, `elevenlabs.voiceSettings` | ElevenLabs: la clave y las voces las guarda ClaudeMaxxing al pegar la clave; modelo `eleven_flash_v2_5` (el más barato y rápido) y ajustes de estabilidad y velocidad |
| `gemini.apiKey`, `gemini.model`, `gemini.style`, `gemini.voices.f` / `.m` | Gemini TTS: clave, modelo, estilo de lectura (por ejemplo "cálida y conversacional") y voces por género |
| `marker` | Prefijo de la línea que se lee (🔊). Si lo cambias, cambia también la regla en `templates/claude-md-rule.md` y `CLAUDE.md` |
| `fallback` | `first-sentence` / `full` / `none`: qué decir si Claude no escribió la línea 🔊 |
| `maxChars` | Recorta lo que se lee |
| `stopOnPrompt` | Callar la sesión cuando escribes en ella |
| `perSessionVoice`, `sessionActiveHours` | Voz distinta por sesión y cuánto cuenta una sesión como activa |
| `announceFormat` | Qué se dice: `"Soy {name}, {role}. {text}"` (admite `{project}`) |
| `chime.enabled`, `chime.volume`, `chime.roleTimbres`, `chime.defaultTimbre`, `chime.motifs` | Firma musical: timbre por rol y lista de motivos (`root` como `C4`/`F#3`/`Bb3`, `chord`, `pattern`) |
| `queueTimeoutSeconds` | Máximo que una voz espera turno antes de descartarse |
| `historySize` | Cuántos audios se guardan para repetir |
| `duck.enabled`, `duck.level`, `duck.fadeMs`, `duck.restoreMs` | Bajar la música: a qué fracción de su volumen (0.2 = 20 %) y en cuánto tiempo baja y sube |
| `naming.enabled`, `naming.setTitle`, `naming.titleFormat` | Nombres de sesión y si se pone como título |
| `naming.names.f` / `.m`, `naming.roles`, `naming.defaultRole` | Listas de nombres y roles con sus palabras clave (se comparan sin tildes) |
| `edge.voice`, `edge.voicePool`, `edge.voiceGenders`, `edge.rate`, `edge.exe` | Voces. `voiceGenders` decide si el nombre es femenino o masculino |
| `sapi.voice`, `sapi.rate`, `ffplay` | Voz local y reproductor |

## Archivos

| Archivo | Para qué |
|---|---|
| `hooks/on-start.ps1` | Hook `SessionStart` (solo sesiones del menú): título con el nombre reservado y regla del 🔊 |
| `hooks/on-prompt.ps1` | Hook `UserPromptSubmit`: calla la sesión y le pone nombre en el primer prompt (o completa el rol de una sesión reservada) |
| `hooks/speak.ps1` | Hook `Stop`: lee el evento y lanza la reproducción |
| `hooks/play.ps1` | Reproductor: prepara audio, cola, baja/sube música, historial |
| `hooks/common.ps1` | Texto, sesiones (voz, nombre, silencio), historial, música, PID y log |
| `hooks/Mixer.cs` | Volumen por aplicación (Core Audio) |
| `hooks/Chime.cs` | Sintetizador de la firma musical (WAV). Se compila junto con Mixer.cs una vez a una DLL |
| `hooks/probe.ps1` | Sonda temporal de eventos (`ctl.ps1 probe`) |
| `ctl.ps1` | Control manual, atajos y backend de `/voz` |
| `install.ps1` | Instalación global idempotente con backup |
| `config.json` | Configuración por defecto (se reemplaza al actualizar) |
| `config.local.json` | Lo propio de este PC, encima de `config.json` (no está en el repo) |
| `templates/` | Regla del 🔊 y plantilla de `/voz` |
| `plugin/` | Plugin que el menú carga con `--plugin-dir` en cada sesión: hooks y `/voz` (`skills/voz` lo genera el `install.ps1` de la raíz) |
| `test/` | Pruebas sin audio y evento `Stop` de ejemplo |
| `docs/` | Investigación, `/btw`, arquitectura y siguientes pasos |

El estado de ejecución (nombres, voces, silencios, historial, log) vive en `%TEMP%\claude-voice`.

## Diagnóstico

- **No suena nada:** `.\ctl.ps1 status`. Si `.\ctl.ps1 test` suena pero Claude no, los hooks no están cargados (sesión nueva, `/hooks`). Mira si la sesión o todo está silenciado (`/voz`).
- **La música se quedó baja:** `.\ctl.ps1 stop` la restaura. No debería pasar (se restaura incluso si se mata el reproductor), pero si pasa, avísame con el log.
- **Lee la primera frase en vez del resumen:** Claude no escribió la línea 🔊; en las sesiones del menú la añade el hook `SessionStart` (mira `/hooks`); con la instalación global, revisa que la regla está en el `CLAUDE.md`.
- **Tarda en hablar:** generación con edge-tts (red). `"engine": "sapi"` responde enseguida.
- **Cada prompt tarda ~0,4 s más en enviarse:** es el hook síncrono que pone el nombre (arranque de PowerShell). Con `naming.enabled=false` sigue corriendo para callar el audio; ver siguientes pasos.
- **Con `claude -p` no habla:** observado; la voz es para la sesión interactiva.
- **`claude -p "/voz ..."` desde Git Bash:** usa `MSYS_NO_PATHCONV=1`.
