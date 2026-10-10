# VoiceTray

Tres piezas para trabajar con varias sesiones de Claude Code en Windows:

- **Bandeja** (`tray.ps1`, `lib/`): uso del plan de Claude (ventana de 5 horas y límite semanal), cuándo se reinicia y **Agendar sesión**.
- **Abrir con Claude Code** (`menu/`, `open-session.ps1`): desde el menú del Explorador, cada sesión se abre en una mitad de pantalla (máximo 2 por pantalla), con su color y un nombre como "Martín · codificador".
- **Voz** (`voice/`, antes ClaudeVoice): cada sesión del menú lee en voz alta un resumen de cada respuesta, con su propia voz y firma musical. Detalles en [`voice/README.md`](voice/README.md).

## Bandeja: cómo funciona

- La barra de estado (statusline) de Claude Code recibe `rate_limits` en cada respuesta. Un bloque añadido a `~/.claude/statusline-command.sh` guarda esos datos en `~/.claude/usage-tray/usage.json`, sin tocar lo que se muestra en la barra.
- `tray.ps1` lee ese archivo cada 15 s y dibuja el popup. Clic izquierdo abre o cierra; clic derecho abre el menú.
- Botón **↻** (y menú *Actualizar datos*): pide el uso en vivo al mismo endpoint que usa `/usage` (`api.anthropic.com/api/oauth/usage`, con el token local de Claude Code). También se pide al arrancar y al abrir el popup si los datos tienen más de 10 minutos. Si la cuenta tiene **uso extra** activado o un **limit reset** disponible (Configuración → Uso → Resets), aparecen como secciones extra; si no, no se muestran. El reinicio se reclama en claude.ai (botón *Use*), no desde aquí. Ese endpoint **no está documentado**: si cambia o falla, el popup muestra el error y sigue usando lo que escribe la barra de estado.
- El punto verde indica que algún Claude Code respondió en los últimos 10 minutos. Si está gris, los números son los últimos conocidos (el uso desde claude.ai o la app de escritorio no se refleja hasta la próxima respuesta en Claude Code). Cuando pasa la hora de reinicio, esa ventana se muestra en 0 %.

## Agendar sesión

La ventana de 5 horas empieza con el primer mensaje. Agendar un mensaje mínimo (Haiku, "ok") hace que empiece y se reinicie antes.

- **En este PC**: crea una tarea única en el Programador de tareas (`\ClaudeTray\`). Despierta el PC si está suspendido (requiere los temporizadores de reactivación activados en el plan de energía), pero no si está apagado ni si la sesión de Windows está cerrada (la tarea corre con tu usuario, con sesión iniciada). Cada ejecución queda en `~/.claude/usage-tray/history.json` (se ve en *Agendadas* como Hecha o Falló) y en `scheduled.log`.
- **En la nube**: al pulsar *Agendar*, el diálogo muestra una tarjeta *Creando rutina en claude.ai…* con los detalles (hora, Haiku, mensaje «ok») mientras Claude Code, sin ventana y con solo la herramienta de rutinas permitida, ejecuta `/schedule` (unos 50 s). Al terminar muestra la rutina creada o el error; el registro queda en `~/.claude/usage-tray/runs/cloud-<id>.log`. Funciona con el PC apagado y consume del mismo plan. La API adjunta los conectores de la cuenta a la rutina y no deja quitarlos por API; se pueden quitar editándola en claude.ai.

## Abrir con Claude Code (mitades de pantalla)

La entrada **Abrir con Claude Code** del menú contextual del Explorador (Windows 11) ejecuta el comando guardado en `HKCU\Software\ClaudeCodeMenu\Launcher`, que `install.ps1` apunta a `open-session.ps1`. Si ese valor no existe, el menú abre Windows Terminal como antes.

- Con **n** pantallas hay **2n** huecos: mitad izquierda y derecha de cada pantalla, numerados de la pantalla más a la izquierda a la más a la derecha. Cada sesión nueva abre una ventana de Windows Terminal y la coloca en el primer hueco libre (área de trabajo, sin tapar la barra de tareas; respeta el escalado de cada pantalla).
- Cada hueco tiene un color (azul, naranja, verde, morado, cian, rojo, amarillo, rosa): la pestaña y la caja del prompt de Claude Code (`/color`, como primer prompt: es un comando local, sin llamada al modelo) salen del mismo tono. Ni el perfil del terminal ni su esquema de colores cambian. El modo oscuro/claro de la ventana lo decide Windows Terminal (por defecto sigue al tema de Windows).
- **Nombre y rol:** antes de abrir, el lanzador reserva para la sesión un nombre y una voz (`voice/`, sin repetir los de otras sesiones activas) y arranca Claude Code con ese `--session-id` y el plugin de voz (`--plugin-dir voice\plugin`, solo para esa sesión). La sesión empieza llamándose "Martín" (caja del prompt, pestaña y `/resume`) y con el primer prompt que no sea un comando pasa a "Martín · codificador" según lo que pidas. Desde ahí habla como "Soy Martín, codificador. …". Nada de esto toca tu `~/.claude`.
- Con los 2n huecos ocupados, avisa y no abre nada. Al cerrar una de esas ventanas su hueco queda libre.
- Solo cuentan las sesiones abiertas desde el menú (`~/.claude/usage-tray/sessions.json`); un `claude` lanzado a mano en otra terminal no ocupa hueco. Lo que pasa en cada apertura queda en `sessions.log`.

La entrada del menú está en `menu/`: una extensión `IExplorerCommand` en C++ (`menu/src`) registrada con un paquete MSIX *sparse* firmado (`menu/package`), cuyos archivos de ejecución viven en `%LOCALAPPDATA%\ClaudeCodeMenu`.

| Archivo | Qué hace |
|---|---|
| `menu/build.cmd` | Compila la DLL y el ejecutable stub en `menu/bin` (requiere Visual Studio con C++). |
| `menu/package.ps1` | Empaqueta y firma el MSIX en `menu/bin` con el certificado `CN=ClaudeCodeMenu` (lo crea si falta; requiere el Windows SDK). Solo hace falta si cambia el manifiesto. |
| `menu/install.ps1` | Compila si falta (`-Build` fuerza), copia los archivos a `%LOCALAPPDATA%\ClaudeCodeMenu` y registra el paquete si no lo está (un aviso de UAC para confiar en el certificado). No reinicia el Explorador. `install.ps1` lo llama. |
| `menu/uninstall.ps1` | Quita la entrada, el valor `Launcher`, los archivos desplegados y el certificado. |

Tras cambiar la DLL: `menu\install.ps1 -Build`. Si el Explorador tenía la DLL cargada, la copia en uso se renombra y la nueva se usa en la próxima apertura del menú.

## Instalar / desinstalar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1     # parchea statusline (con backup), menú y su lanzador, /voz del plugin de voz, acceso directo de inicio y arranca
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1   # quita todo salvo los datos en ~/.claude/usage-tray (el menú vuelve a abrir Windows Terminal sin huecos; `menu\uninstall.ps1` lo quita)
```

El lanzador del menú, el acceso directo de inicio y el `/voz` del plugin guardan la ruta absoluta de esta carpeta. **Si la mueves o le cambias el nombre, vuelve a ejecutar `install.ps1`** (y cierra y reabre las sesiones del menú que estuvieran abiertas: arrancaron con `--plugin-dir` en la ruta vieja).

## Pruebas

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1         # bandeja, huecos, menú; ASCII y sintaxis de todos los .ps1
powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1   # voz, sin audio
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # dibuja el popup a una imagen
```

Los `.ps1` deben quedar en ASCII (PowerShell 5.1 los lee como ANSI); los textos con tildes van como `\uXXXX` y se decodifican con `Tx`.
