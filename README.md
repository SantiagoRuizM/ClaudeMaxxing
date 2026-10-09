# ClaudeTray

Icono en la bandeja de Windows con el uso del plan de Claude: ventana de 5 horas (SESSION), límite semanal (WEEKLY), cuándo se reinicia cada uno y un botón **Agendar sesión**.

## Cómo funciona

- La barra de estado (statusline) de Claude Code recibe `rate_limits` en cada respuesta. Un bloque añadido a `~/.claude/statusline-command.sh` guarda esos datos en `~/.claude/usage-tray/usage.json`, sin tocar lo que se muestra en la barra.
- `tray.ps1` lee ese archivo cada 15 s y dibuja el popup. Clic izquierdo abre o cierra; clic derecho abre el menú.
- Botón **↻** (y menú *Actualizar datos*): pide el uso en vivo al mismo endpoint que usa `/usage` (`api.anthropic.com/api/oauth/usage`, con el token local de Claude Code). También se pide al arrancar y al abrir el popup si los datos tienen más de 10 minutos. Si la cuenta tiene **uso extra** activado o un **limit reset** disponible (Configuración → Uso → Resets), aparecen como secciones extra; si no, no se muestran. El reinicio se reclama en claude.ai (botón *Use*), no desde aquí. Ese endpoint **no está documentado**: si cambia o falla, el popup muestra el error y sigue usando lo que escribe la barra de estado.
- El punto verde indica que algún Claude Code respondió en los últimos 10 minutos. Si está gris, los números son los últimos conocidos (el uso desde claude.ai o la app de escritorio no se refleja hasta la próxima respuesta en Claude Code). Cuando pasa la hora de reinicio, esa ventana se muestra en 0 %.

## Agendar sesión

La ventana de 5 horas empieza con el primer mensaje. Agendar un mensaje mínimo (Haiku, "ok") hace que empiece y se reinicie antes.

- **En este PC**: crea una tarea única en el Programador de tareas (`\ClaudeTray\`). Despierta el PC si está suspendido (requiere los temporizadores de reactivación activados en el plan de energía), pero no si está apagado ni si la sesión de Windows está cerrada (la tarea corre con tu usuario, con sesión iniciada). Cada ejecución queda en `~/.claude/usage-tray/history.json` (se ve en *Agendadas* como Hecha o Falló) y en `scheduled.log`.
- **En la nube**: al pulsar *Agendar*, el diálogo muestra una tarjeta *Creando rutina en claude.ai…* con los detalles (hora, Haiku, mensaje «ok») mientras Claude Code, sin ventana y con solo la herramienta de rutinas permitida, ejecuta `/schedule` (unos 50 s). Al terminar muestra la rutina creada o el error; el registro queda en `~/.claude/usage-tray/runs/cloud-<id>.log`. Funciona con el PC apagado y consume del mismo plan. La API adjunta los conectores de la cuenta a la rutina y no deja quitarlos por API; se pueden quitar editándola en claude.ai.

## Abrir con Claude Code (mitades de pantalla)

La entrada **Abrir con Claude Code** del menú contextual del Explorador (DLL propia en `%LOCALAPPDATA%\ClaudeCodeMenu`) ejecuta el comando guardado en `HKCU\Software\ClaudeCodeMenu\Launcher`, que `install.ps1` apunta a `open-session.ps1`. Si ese valor no existe, el menú abre Windows Terminal como antes.

- Con **n** pantallas hay **2n** huecos: mitad izquierda y derecha de cada pantalla, numerados de la pantalla más a la izquierda a la más a la derecha. Cada sesión nueva abre una ventana de Windows Terminal y la coloca en el primer hueco libre (área de trabajo, sin tapar la barra de tareas; respeta el escalado de cada pantalla).
- Con los 2n huecos ocupados, avisa y no abre nada. Al cerrar una de esas ventanas su hueco queda libre.
- Solo cuentan las sesiones abiertas desde el menú (`~/.claude/usage-tray/sessions.json`); un `claude` lanzado a mano en otra terminal no ocupa hueco. Lo que pasa en cada apertura queda en `sessions.log`.

## Instalar / desinstalar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1     # parchea statusline (con backup), lanzador del menú, acceso directo de inicio y arranca
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1   # quita todo salvo los datos en ~/.claude/usage-tray
```

## Pruebas

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # dibuja el popup a una imagen
```

Los `.ps1` deben quedar en ASCII (PowerShell 5.1 los lee como ANSI); los textos con tildes van como `\uXXXX` y se decodifican con `Tx`.
