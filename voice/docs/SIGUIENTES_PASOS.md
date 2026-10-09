# Siguientes pasos

## Estado (2026-10-09)

Hecho y probado en esta máquina:

- [x] Hook `Stop` que lee la línea 🔊 (o la primera frase como respaldo)
- [x] edge-tts con respaldo SAPI (Helena)
- [x] **Validado en una sesión interactiva real** (10:50 y 10:58): el hook se disparó y leyó la línea 🔊
- [x] Voz distinta por sesión (pool configurable) y cola entre sesiones con mutex. Probado con audio real: dos sesiones a la vez → dos voces, nunca simultáneas
- [x] Callar solo la sesión donde escribes; las demás siguen
- [x] `/voz` (on, off, parar, voz, todo-on, todo-off). **Validado con `claude -p`**: recibe el ID de sesión correcto y no pide permisos
- [x] Silencio por sesión, global, por variable de entorno (`CLAUDEVOICE=off`) y por config
- [x] Instalación global idempotente con backup (hooks + regla + `/voz`), probada sobre copias de tu configuración real
- [x] 30 pruebas sin audio, aisladas en su propio `%TEMP%`
- [x] Sonda de eventos (`ctl.ps1 probe`) para investigar `/btw`
- [x] Nombre + rol automáticos con el primer prompt (`sessionTitle`). **Visto en tu sesión real**: se llamó "Renata · asistente" y habló como "Renata: …"
- [x] Historial y repetir (`/voz repetir`, `ctl repeat`, atajo Ctrl+Alt+Shift+O), con el mp3 guardado
- [x] Bajar la música mientras habla, con traspaso entre voces de la cola y restauración si se corta. Medido con audio real
- [x] Firma musical por sesión (timbre por rol, motivo único por sesión) y "Soy <nombre>, <rol>. <mensaje>". Probado con audio real y con seis sesiones en paralelo
- [x] 59 pruebas sin audio

Pendiente:

- [ ] **Prueba de `/btw` con la sonda** (2 minutos, ver [BTW.md](BTW.md)). Decide si se puede leer en voz alta.
- [ ] Comprobar que el título de la sesión cambia en la interfaz de Claude Code (el hook lo envía; no lo he visto en pantalla).
- [x] Atajos globales con `RegisterHotKey` (proceso oculto que arranca con Windows). Los `.lnk` con tecla rápida no funcionaban, y además algo en el equipo intercepta Ctrl+Alt+R: repetir pasó a Ctrl+Alt+Shift+O. Verificado simulando la pulsación a nivel de sistema.
- [ ] Probar con música real (Spotify o el navegador); probado solo con un tono generado.
- [ ] Probar en sesión interactiva con dos terminales abiertas a la vez.
- [ ] Escuchar las 12 firmas (`.\ctl.ps1 chimes`) y quitar o cambiar las que no gusten en `chime.motifs`. Las diseñé por teoría musical, sin poder oírlas.
- [ ] Decidir si "Soy X, rol." en cada mensaje cansa; quizá solo en el primer mensaje de la sesión o cuando cambia de sesión respecto al último que habló.
- [ ] `.\install.ps1` para tenerlo en todas las sesiones, cuando te convenza.

## Fase 1: afinar (esta semana)

1. Hacer la prueba de `/btw` y actuar según el resultado (ver BTW.md).
2. Revisar el log (`.\ctl.ps1 status`): ¿cuántas respuestas traen la línea 🔊? Si Claude la olvida a menudo, reforzar la regla o inyectarla con un hook `SessionStart`.
3. Elegir el pool de voces y la velocidad (`.\ctl.ps1 voices`). Quizá separar por género para distinguir mejor las sesiones.
4. Instalar `edge-tts` por su cuenta (`pipx install edge-tts`) para no depender del venv de hermes-agent, y quitar `edge.exe` de `config.json`.

## Fase 2: experiencia

- **Quitar los ~0,4 s por prompt** del hook síncrono: un daemon local con hook `http` (sin arrancar PowerShell) o un ejecutable compilado pequeño en lugar del script.
- **Rol más fino** con el propio Claude: que la regla del `CLAUDE.md` le pida también una etiqueta de rol en la primera respuesta, sin llamadas extra.
- **Renombrar desde `/voz`** (`/voz nombre Lucía`).
- **Bajar la música solo de apps concretas** (lista en config) en vez de todas las que suenan.
- **Menos latencia con edge-tts**: reproducir mientras se genera (stream a `ffplay -i -`) o un daemon persistente, como give-claude-code-voice-tts. Objetivo: menos de 1 s.
- **Avisos hablados de permisos**: `Notification` / `PermissionRequest` → "la sesión de Catedrai necesita permiso". Es lo más útil cuando estás en otra ventana.
- **Sonidos cortos por herramienta** (`PostToolUse`): clic para Edit, otro para Bash.
- **Omitir turnos triviales**: no hablar si el turno duró pocos segundos.

## Fase 3: multi-sesión y agentes

- **Prioridad en la cola**: un aviso de permiso pasa delante de un resumen.
- **`SubagentStop`** opcional: aviso corto cuando termina un subagente largo.
- **Voz fija por proyecto** (además de por sesión): `config.json` → `{"Catedrai": "es-MX-JorgeNeural"}`.

## Fase 4: calidad y distribución

- **Voz neuronal offline** (Kokoro-82M o Piper) para no depender de internet ni de Microsoft; resolvería además que sin red todas las sesiones suenen igual.
- **ElevenLabs u OpenAI TTS** como motor opcional de pago.
- **Hook `http` + daemon** en `localhost`: Claude Code hace el POST y nos ahorramos arrancar PowerShell en cada turno. Imprescindible si se usa `MessageDisplay` para `/btw`.
- **Empaquetarlo como plugin de Claude Code** (hooks + skill + regla) para instalarlo con `claude plugin install`.
- **Conversación manos libres**: combinar con el dictado que ya tienes activo (`"voice": { "mode": "hold" }`).

## Riesgos abiertos

- `/btw` probablemente no pasa por ningún hook (pendiente de la prueba).
- Que Claude no ponga la línea 🔊 de forma consistente en respuestas muy técnicas. Mitigación: primera frase como respaldo.
- edge-tts usa un servicio no oficial de Microsoft que puede cambiar o bloquearse. Mitigación: respaldo SAPI; Kokoro/Piper en la fase 4.
- La referencia oficial de `MessageDisplay` no coincide con lo que envía la versión 2.1.280; los campos de los hooks pueden cambiar entre versiones.
