# ¿Se puede escuchar la respuesta de `/btw`?

Fecha: 2026-10-09. **Respuesta corta: casi seguro que no con hooks hoy, pero está sin confirmar. Hay una prueba de 2 minutos para salir de dudas.**

## Qué es `/btw`

`/btw <pregunta>` hace una pregunta lateral mientras Claude sigue trabajando. Según la [documentación de comandos](https://code.claude.com/docs/en/commands) y quienes han analizado su implementación:

- es una llamada aparte al modelo, de **un solo turno y sin herramientas**, que reutiliza el contexto de la sesión;
- la respuesta sale en un **panel temporal** que cierras con Espacio, Enter o Escape;
- **no entra en el historial** de la conversación ni en el transcript.

## Por qué ClaudeVoice no la oye

| Vía | ¿Sirve para `/btw`? |
|---|---|
| Hook `Stop` (lo que usa ClaudeVoice) | No. `Stop` es del turno principal; `/btw` no es un turno de la conversación |
| Leer el transcript `.jsonl` | No, según su descripción ("no entra en el historial"). En tus transcripts `/btw` solo aparece en notas de versión, así que no pude comprobarlo con un uso tuyo |
| Hook `MessageDisplay` | **Desconocido.** Se dispara mientras se pinta texto del asistente, con trozos (`delta`) y una marca `final`. Nadie documenta si incluye el panel de `/btw`. Es la única posibilidad real |
| `UserPromptSubmit` / `UserPromptExpansion` | Desconocido si se disparan con `/btw`; si lo hacen, solo darían la pregunta, no la respuesta |

Los análisis de la implementación ([1](https://gist.github.com/sorrycc/cca0b238a15027c3572f19b353a00853), [2](https://github.com/claytonsandham/claude-code-internals/blob/main/src/commands/btw/README.md)) describen la respuesta como una llamada aislada que se pinta directamente en un componente propio, sin mencionar hooks. Por eso lo más probable es que **ningún hook la vea**.

Datos encontrados con la sonda (Claude Code 2.1.280, `claude -p`):

- `MessageDisplay` llega con `turn_id`, `message_id`, `index`, `final` y `delta`, no con `message_text`/`is_partial` como dice la referencia. El texto está en `delta`; en una respuesta corta llegó entero en un solo evento con `final: true`.
- `UserPromptSubmit` trae `prompt`, no `user_message`.
- En ese mismo run, `Stop` no aparece registrado (observado, causa sin verificar).

## La prueba (hazla tú: `/btw` se usa mientras Claude trabaja en una sesión interactiva; no se puede simular con `claude -p`)

```powershell
.\ctl.ps1 probe on       # añade hooks de registro en .claude/settings.local.json (solo esta carpeta)
```

1. Abre una sesión **nueva** de Claude Code en `ClaudeVoice/`.
2. Pídele algo que tarde (por ejemplo, "revisa todos los scripts y explícame cada función").
3. Mientras trabaja: `/btw cuál es la capital de Australia`.
4. Cierra el panel y deja que termine.

```powershell
.\ctl.ps1 probe off      # primero apágala: MessageDisplay lanza un proceso por cada trozo de texto
Select-String -Path "$env:TEMP\claude-voice\probe.log" -Pattern 'Canberra', 'btw'
```

Cómo leer el resultado (busca en el archivo, no a ojo; los trozos de texto pueden partir palabras):

- **Hay un `MessageDisplay` con "Canberra"** cuyo `turn_id` no es el de las respuestas de la tarea principal → `/btw` sí pasa por el hook. Se puede leer en voz alta.
- **Solo aparece en `UserPromptSubmit`/`UserPromptExpansion`** (la pregunta) → Claude Code ve la pregunta pero la respuesta no pasa por hooks.
- **No aparece nada** → `/btw` no toca los hooks.

Si dudas, compara con una ejecución de control igual pero sin `/btw`.

## Qué haríamos según el resultado

- **Si aparece en `MessageDisplay`:** se puede. Un hook `MessageDisplay` acumularía los `delta` por `message_id` y, al llegar `final`, leería la respuesta, solo si ese `message_id` no pertenece al turno principal (que ya lee `Stop`). Por rendimiento convendría un hook `http` contra un daemon local en vez de lanzar PowerShell por cada trozo.
- **Si no aparece:** no hay forma limpia hoy. Opciones:
  - pedirlo a Anthropic (un evento tipo `SideQuestionAnswered` o que `/btw` dispare `MessageDisplay`);
  - usar un comando propio en lugar de `/btw` (por ejemplo `/pregunta`), aunque **no es equivalente**: entra en la conversación y espera a que Claude termine, en lugar de ir en paralelo;
  - leer la pantalla (OCR de la terminal): posible pero frágil; no lo recomiendo.
