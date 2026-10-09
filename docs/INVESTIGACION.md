# Investigación: ¿qué tan viable es que Claude Code responda con voz?

Fecha: 2026-10-09. **Veredicto: muy viable y barato.** Todo se apoya en mecanismos oficiales (hooks) y en esta máquina ya estaban instaladas todas las piezas.

## 1. Lo que dice la documentación oficial

Fuente: [Hooks reference](https://code.claude.com/docs/en/hooks).

| Afirmación | Estado | Detalle |
|---|---|---|
| El hook `Stop` recibe `last_assistant_message` | ✅ Confirmado | También `stop_reason`. La doc dice que los hooks que necesiten el texto final del turno deben usar este campo en vez de leer el transcript |
| Tipos de hook: `command`, `http`, `mcp_tool`, `prompt`, `agent` | ✅ | `agent` es experimental |
| `async: true` corre el hook en segundo plano | ✅ | Solo en hooks `command`. Claude Code **no** aplica el `timeout` a hooks async |
| `terminalSequence` en la salida del hook | ✅ | Restringido a OSC 0/1/2/9/99/777 y BEL: sirve para un pitido, una notificación o el título de la ventana. **No sirve para voz** |
| En Windows los hooks usan Git Bash, o PowerShell si no hay Git Bash | ✅ | `"shell": "powershell"` lo fuerza. Con `args` (exec form) no hay shell intermedio, que es lo que usa este proyecto |
| `${CLAUDE_PROJECT_DIR}` disponible en `command`/`args` | ✅ | Usado en `.claude/settings.json` |
| `Stop` y `SubagentStop` son eventos distintos | ✅ | Los subagentes no disparan la voz salvo que se enganche `SubagentStop` |
| Timeout por defecto de hooks `command` | ✅ 600 s | 30 s en `UserPromptSubmit` |
| "Anthropic recomienda `last_assistant_message` para leer en voz alta" | ⚠️ Exagerado | La doc no menciona TTS, voz ni lectura en voz alta en ninguna parte |

Nota: en `~/.claude/settings.json` ya existe `"voice": { "enabled": true, "mode": "hold" }`. Eso es **dictado** (tú hablas, Claude escribe), no salida de voz. Son complementarios: con los dos activos tienes conversación por voz en ambas direcciones.

## 2. Lo que se comprobó en esta máquina (Windows 11)

| Pieza | Resultado |
|---|---|
| SAPI (`System.Speech`) | Voces Helena (es-ES) y Zira (en-US). Funciona sin red, al instante, pero suena robótica |
| Voces OneCore | Helena, Laura y Pablo (es-ES) en el registro. No son accesibles desde `System.Speech` sin trucos de registro |
| `edge-tts` | Instalado en `%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\edge-tts.exe` (no está en el PATH). Generó un mp3 con `es-CO-SalomeNeural` en ~2,6 s. Gratis, suena natural, requiere internet |
| `ffplay` | Instalado vía winget (FFmpeg 8.1.2) y en el PATH |
| Comando `claude` | El shim viejo de `AppData\Roaming\npm` está roto (apunta a un `claude.exe` que no existe), pero el que usas de verdad es el de nvm (`AppData\Local\nvm\v24.15.0\...`, versión 2.1.280) y funciona. Se puede borrar el shim viejo |

## 2b. Comprobaciones posteriores (mismo día)

- **Sesión interactiva real:** el hook `Stop` se disparó y leyó la línea 🔊 (log de las 10:50 y las 10:58).
- **`claude -p`:** observado: el hook `Stop` no llega a sonar ni a registrarse en la sonda (causa sin verificar). La voz es para la sesión interactiva.
- **Skills:** `${CLAUDE_SESSION_ID}` y `$ARGUMENTS` se sustituyen dentro de ``!`comando` `` y el comando corre antes de que el modelo vea nada. Con `allowed-tools` no pide permiso. Es la base de `/voz`.
- **Campos reales en 2.1.280:** `MessageDisplay` trae `turn_id, message_id, index, final, delta` y `UserPromptSubmit` trae `prompt`. La referencia web dice otra cosa (`message_text`, `is_partial`, `user_message`).
- **`/btw`:** ver [BTW.md](BTW.md).

## 3. Proyectos que ya lo hacen

| Proyecto | Plataforma | Cómo funciona | Comentario |
|---|---|---|---|
| [MarioMagdy/give-claude-code-voice-tts](https://github.com/MarioMagdy/give-claude-code-voice-tts) | **Windows** | Hook Stop + daemon edge-tts persistente; Claude termina con un resumen de una línea que es lo único que se lee; skill para cambiar voz, silenciar e interrumpir | El más parecido a ClaudeVoice. El daemon persistente es una buena idea para bajar latencia (ver siguientes pasos) |
| [MatiousCorp/claude-tts](https://github.com/MatiousCorp/claude-tts) | macOS, Linux, Windows (Git Bash/WSL) | Plugin instalable. Hooks Stop + UserPromptSubmit (corta al escribir). Limpia código, URLs y markdown. 11 proveedores: ElevenLabs, OpenAI, Google, Polly, Azure, Fish, Gemini, Edge, Kitten, TADA, TTS del sistema | El más completo (~30 estrellas). Lee la respuesta limpia, no un resumen |
| [nickcent/claude-code-tts-hooks](https://github.com/nickcent/claude-code-tts-hooks) | **Solo macOS** (usa `afplay`) | Kokoro / ElevenLabs / OpenAI / `say`. Hooks SessionStart, UserPromptSubmit, Stop, PreCompact | La investigación inicial lo destacaba; en realidad no sirve en Windows y tiene 0 estrellas |
| [cris-m/claude_voice](https://github.com/cris-m/claude_voice) | — | El hook Stop extrae un `TTS_SUMMARY` de la respuesta | Mismo patrón de marcador |
| [TwinPeaksTownie/Claude-to-Speech](https://github.com/TwinPeaksTownie/Claude-to-Speech) | — | Marcadores invisibles en la respuesta, extraídos con regex, ElevenLabs | Mismo patrón |
| [ybouhjira/claude-code-tts](https://github.com/ybouhjira/claude-code-tts) | — | Plugin MCP + hook Stop que lee la primera frase (OpenAI TTS) | |
| [hopchouinard/claude-speak](https://github.com/hopchouinard/claude-speak) | — | Resúmenes hablados pasivos + capacidad de voz activa | |
| [pcamarajr/claude-spoken-briefs](https://github.com/pcamarajr/claude-spoken-briefs) | macOS | El hook Stop le pide a **Haiku** un resumen de 2-4 frases y Kokoro lo lee localmente | Cuesta una llamada extra al modelo por turno |
| [caiorlm/claude-code-tts](https://github.com/caiorlm/claude-code-tts) | — | Voces por sesión, OpenAI o Edge, relay opcional a Telegram | Idea útil para multi-sesión |
| [praneybehl/claude-code-voice-hook](https://github.com/praneybehl/claude-code-voice-hook) | — | Hook + servidor TTS local (Vois) | |

"CodeTalk", citado en la investigación inicial, no se pudo verificar.

## 4. Conclusiones de diseño

1. **Leer la respuesta completa no sirve**: lee código, tablas y rutas. Todos los proyectos serios limpian el texto o leen solo un resumen.
2. **El resumen lo escribe Claude en la misma respuesta**, con un marcador (🔊). Cero inferencias extra. La línea se ve en la terminal: no hay forma de que Claude escriba algo que se oiga pero no se vea.
3. **La voz "directamente en la terminal" no existe literalmente.** La terminal solo muestra texto y los hooks no tienen TTY. El audio siempre lo reproduce un proceso aparte (SAPI o ffplay), lo cual es transparente para el usuario.
4. **Hay que usar `async: true`** o un proceso desacoplado; si no, Claude espera a que termine de hablar.
5. **Hay que cortar el audio** al escribir un prompt nuevo y cuando llega otra respuesta, para que no se pisen.

## Fuentes

- https://code.claude.com/docs/en/hooks
- Los repositorios enlazados en la tabla de la sección 3.
