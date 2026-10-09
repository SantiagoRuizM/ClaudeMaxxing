# Investigación inicial (texto de partida)

> Este es el texto con el que arrancó el proyecto, conservado como referencia. Se reformateó a markdown y se condensaron algunas listas y diagramas, sin cambiar su contenido ni sus afirmaciones (errores incluidos).
> Se verificó el 2026-10-09: lo esencial es correcto, pero tiene errores y exageraciones.
> Las correcciones están en [INVESTIGACION.md](INVESTIGACION.md). En resumen:
> - `nickcent/claude-code-tts-hooks` es **solo macOS** y no tiene estrellas; no sirve como referencia principal en Windows.
> - La documentación oficial **no** recomienda `last_assistant_message` para leer en voz alta (no menciona TTS); lo recomienda para obtener el texto final en general.
> - "CodeTalk" no se pudo verificar.
> - El proyecto más cercano para Windows es `MarioMagdy/give-claude-code-voice-tts`, que aquí solo se menciona de pasada.

---

Sí. De hecho, Claude Code tiene mecanismos bastante buenos para hacer exactamente eso, y puedes llevarlo mucho más lejos que simplemente hacer que emita un sonido.

La arquitectura que te recomiendo sería:

Claude Code → Hook → script local → TTS/API → MP3 → reproducción

Por ejemplo:

Claude termina una tarea → ejecuta notify.sh → genera un resumen hablado → reproduce summary.mp3.

Puedo mostrarte las distintas formas de hacerlo, incluyendo Hooks (Stop), Notification, scripts locales, ElevenLabs/OpenAI TTS, y una opción donde Claude genera directamente el resumen que se convierte en voz.

*(Pregunta: investiga quién lo ha hecho ya, qué documentación hay, si hay otra manera para que se reproduzca directamente en la terminal.)*

Sí. Revisé la documentación actual de Claude Code y varios proyectos reales de la comunidad. Lo que estás imaginando ya existe en varias variantes, pero hay una arquitectura que me parece especialmente buena para lo que buscas.

## 1. La pieza clave: Hooks de Claude Code

Claude Code tiene hooks oficiales que pueden ejecutar código automáticamente durante su ciclo de vida. Los más relevantes son:

| Hook | Cuándo dispara | Para tu caso |
|---|---|---|
| PostToolUse | Después de cada llamada de herramienta | 🔧 "terminó una acción" |
| PostToolBatch | Después de un lote de herramientas | 🔧 útil para evitar ruido |
| TaskCompleted | Cuando una tarea es marcada como terminada | ✅ resumen de tarea |
| Stop | Cuando Claude termina de responder | ⭐ mejor para "Claude terminó" |
| Notification | Cuando Claude genera una notificación | 🔔 avisos/permisos |
| SubagentStop | Cuando termina un subagente | 🤖 equipos de agentes |

La documentación oficial confirma además que un Stop hook recibe directamente `last_assistant_message`, es decir, el texto de la última respuesta de Claude sin que tengas que volver a leer el transcript. Anthropic específicamente recomienda ese campo para implementaciones de lectura en voz alta.

Documentación oficial de Claude Code Hooks

## 2. Y hay algo aún más interesante: HTTP Hooks

Esto encaja casi exactamente con tu idea.

Claude Code permite que un hook sea: `command`, `http`, `mcp_tool`, `prompt`, `agent`.

Un HTTP hook hace que Claude Code envíe automáticamente un POST con el JSON del evento a tu servidor.

Entonces puedes tener:

```
Claude Code
    │
    │ Stop
    ▼
POST http://localhost:3000/claude-complete
    │
    ├── recibe last_assistant_message
    ├── genera/selecciona resumen
    ├── TTS
    └── reproduce audio
```

Esto es mejor que hacer `Claude Code → hook → curl → API` porque Claude Code ya hace el HTTP POST por ti.

## 3. Gente que ya lo ha hecho

Encontré bastantes implementaciones. Algunas son especialmente interesantes.

### nickcent/claude-code-tts-hooks

Es probablemente el ejemplo más cercano a lo que describes. Soporta: Kokoro (local), ElevenLabs, OpenAI TTS, `say` de macOS, hooks de Stop, sonidos de inicio, confirmaciones, anuncios durante compaction. Y utiliza directamente la respuesta de Claude para producir voz.

### MatiousCorp/claude-tts

Este es todavía más completo. Soporta: ElevenLabs, OpenAI, Google, Amazon Polly, Azure, Edge TTS, Kitten, Gemini TTS y TTS local, en Windows, Linux y macOS.

Su arquitectura es prácticamente: `Stop hook → limpia respuesta → TTS provider → audio queue → speaker`. Y tiene algo importante: el hook sale inmediatamente, por lo que el TTS no bloquea a Claude Code.

### claude-speak

Encontré además una variante bastante interesante porque ni siquiera usa hooks. Monitoriza los JSONL que Claude Code escribe en `~/.claude/projects/` y detecta cuándo aparece una respuesta del asistente:

`Claude Code → JSONL → claude-speak → edge-tts → speakers`

Esto desacopla completamente el sistema de Claude Code y permite que siga funcionando aunque cambie la API de hooks. También permite usar OpenAI TTS, guardar el audio como archivo o reproducirlo directamente.

### give-claude-code-voice-tts

Este proyecto está particularmente alineado con tu idea del resumen. En vez de leer toda la respuesta, hace que Claude produzca:

```
<spoken>
He terminado la implementación del endpoint y las pruebas están pasando.
</spoken>
```

El hook solamente habla el contenido de `<spoken>`. Así evitas que Claude diga cosas absurdas como "Here is the following TypeScript file..." y empiece a leer 300 líneas de código.

### claude-tts con resumen local

También encontré proyectos que van un paso más allá: un daemon local recibe el flujo de Claude, filtra ruido y utiliza otro LLM local para decidir qué merece ser hablado. Una implementación descrita por su autor utiliza Qwen local para decidir qué eventos son suficientemente importantes.

Esto es interesante para una futura versión "Jarvis":

`Claude hace 17 cosas → Hook → filtro/LLM local → "Modifiqué 3 archivos y las pruebas pasan." → TTS`

## 4. Pero hay otra posibilidad: NO necesitas MP3

La terminal no necesita recibir un MP3 si utilizas el sintetizador de voz del sistema.

- **Windows**: `SpeechSynthesizer`, que convierte texto en voz desde el sistema sin crear un MP3. `Claude → Stop hook → PowerShell → SpeechSynthesizer → 🔊`.
- **macOS**: `say "Claude terminó la implementación."`, con selección de voces y parámetros.
- **Linux**: `echo "Claude terminó" | espeak-ng`.

## 5. Y existe algo todavía más "terminal"

Claude Code permite que un hook devuelva un campo `{ "terminalSequence": "..." }` y Claude Code se encarga de escribir esa secuencia en la terminal. Esto puede producir: 🔔 bell, notificaciones del terminal, cambios del título de la ventana, notificaciones de Ghostty, Warp, Windows Terminal, Kitty, etc.

Anthropic lo añadió porque los hooks no tienen un terminal controlador, por lo que escribir directamente en `/dev/tty` no funciona de forma fiable.

Eso es excelente para un ding, pero no para una voz.

## 6. Lo más interesante para TU caso

Tres niveles:

- **Nivel 1 — aviso**: `Stop → terminal bell / notification`. Muy barato y prácticamente instantáneo.
- **Nivel 2 — voz directa**: `Stop → last_assistant_message → Windows TTS / macOS say / espeak → 🔊`. No necesitas API ni MP3.
- **Nivel 3 — "Claude me hace un resumen"**:

```
                  ┌─────────────────────┐
                  │     Claude Code     │
                  └──────────┬──────────┘
                           Stop
                             ▼
                  last_assistant_message
                             ▼
                    spoken-summary
                   ┌─────────┴─────────┐
              TTS local            TTS API
            Kokoro / SAPI       ElevenLabs /
            Edge / say          OpenAI etc.
                   └─────────┬─────────┘
                             ▼
                          🔊 audio
```

Y puedes hacer que Claude produzca dos salidas simultáneamente: la respuesta normal (300 líneas de explicación) y un resumen hablado ("Autenticación implementada; añadí refresh tokens, tests y corregí el middleware."). El segundo texto puede ser lo único que escucha tu computador.

## 7. Incluso puedes hacerlo sin otra llamada a Claude

Una mala arquitectura sería `Claude → Stop → otro Claude/LLM → "resume esto" → TTS`, porque añades otra inferencia.

Varios proyectos evitan esto haciendo que el propio Claude incluya una pequeña sección hablada dentro de su respuesta, y el hook solamente la extrae. CodeTalk, por ejemplo, usa justamente ese concepto.

`Claude responde una vez → texto normal + <spoken>...</spoken> → hook → extrae <spoken> → TTS`. 0 llamadas adicionales al LLM.

## 8. Recomendación

No empezar con un MP3:

`CLAUDE CODE → Stop → last_assistant_message → <spoken>...</spoken> → TTS daemon → (Windows TTS | Edge/ElevenLabs) → 🔊`

Y dejar además un PostToolUse separado para sonidos cortos, no voz:

| Evento | Sonido |
|---|---|
| Edit | click |
| Bash | pequeño sonido |
| WebSearch | sonido |
| Task done | sonido |
| Stop | voz |
| Permission | alerta |

Esto puede acabar siendo algo parecido a un Claude Code tipo Jarvis, sin alterar Claude Code internamente. Todo está soportado por mecanismos oficiales de hooks, incluyendo Stop, PostToolUse, HTTP, ejecución asíncrona y notificaciones de terminal.

De los proyectos encontrados, MatiousCorp/claude-tts y nickcent/claude-code-tts-hooks son los que más directamente reutilizaría como referencia, mientras que el patrón `<spoken>...</spoken>` es el que adoptaría para conseguir resúmenes cortos sin otra llamada al LLM.
