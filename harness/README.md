# Ambientes (harness)

Lo que hay detrás de la sección **Ambientes** de ClaudeMaxxing (antes era un proyecto aparte, YourHarness). Ve **todas** las pestañas de Chrome, de todos los perfiles abiertos, con su URL y su contenido, y las cierra cuando se pide. Funciona aunque la ventana esté minimizada, la pestaña no esté activa o Chrome la haya dormido. Encima de eso están los ambientes: qué cerrar y qué abrir para trabajar en una cosa.

**Datos de cada PC, fuera del repo:** `~/.claude/usage-tray/harness/` guarda `environments/*.json` (tus ambientes: nombran tus perfiles, carpetas y URLs), `run/` (el ambiente encendido, el último cambio, el historial, la detección y el registro de cada host de Chrome) y `.env` (la clave de Jev). `YOURHARNESS_HOME` cambia esa carpeta; `YOURHARNESS_ENV_DIR` y `YOURHARNESS_RUN_DIR`, cada parte por separado. Los `.json` de `test/environments` son copias con correos, rutas y URLs inventados, para las pruebas.

## Cómo funciona

```
Chrome (cada perfil)                 Este PC
┌──────────────────────┐  native   ┌────────────────────┐  HTTP 127.0.0.1   ┌──────────┐
│ extension/            │ messaging │ host/host.js       │  puerto aleatorio  │ tabs.js  │
│  chrome.tabs          │◄─────────►│ (Chrome lo arranca │◄──────────────────│  (CLI)   │
│  chrome.scripting     │           │  solo, uno por     │   + token          │          │
└──────────────────────┘           │  perfil)           │                    └──────────┘
                                    └─────── run/<pid>.json (puerto + token)
```

- **Extensión** (`extension/`): lista las pestañas (`chrome.tabs`), lee el contenido de cada página (`chrome.scripting`) y las cierra.
- **Host nativo** (`host/host.js`): Chrome lo arranca junto con la extensión y lo cierra al salir. No hay servidor que levantar. Se registra en `run/` para que el CLI encuentre cada perfil.
- **CLI** (`tabs.js`): junta todos los perfiles.

¿Por qué no otras vías? El script de UI Automation (skill `abierto`) solo ve títulos y pierde las pestañas de ventanas no visibles. Chrome 136+ bloquea `--remote-debugging-port` en el perfil normal, y Chrome 137+ ignora `--load-extension`. La extensión de Claude in Chrome solo ve su propio grupo de pestañas.

## Instalación (una vez)

1. El `install.ps1` de ClaudeMaxxing copia esta carpeta a `%LOCALAPPDATA%\ClaudeMaxxing\harness` y registra el host en `HKCU` (`Register-HarnessHost` en `lib\installer.ps1`: escribe el `.bat` con la ruta de `node` de este PC y su manifiesto). No necesita admin.
2. En **cada perfil de Chrome** que uses: `chrome://extensions` → activar *Modo de desarrollador* → *Cargar descomprimida* → elegir `%LOCALAPPDATA%\ClaudeMaxxing\harness\extension`. El ID debe ser `fmmpaipmfhkkghcljocefmmbhimeonkm` (sale del `key` del manifiesto, así que no cambia con la carpeta).

Tras actualizar ClaudeMaxxing basta el botón de recargar de la extensión (o `node tabs.js reload`).

## Uso

```bash
node tabs.js                  # todas las pestañas, con una línea de contexto
node tabs.js --json           # volcado completo (lista + contenido) para agentes
node tabs.js show <id>        # contenido completo de una pestaña
node tabs.js close <id...>    # cerrar por id
node tabs.js close youtube    # vista previa de las que coinciden (título o URL, regex)
node tabs.js close youtube --yes   # cerrarlas
node tabs.js reload           # recarga la extensión en todos los perfiles tras editar extension/
```

Qué da cada pestaña: título, URL, ventana, si es la activa, si está sonando o fijada, y su grupo. Del contenido, el texto de la página (prioriza `main`/`article`) y la meta descripción. En YouTube da además canal, descripción, minuto actual y duración, si está pausado y si sale un anuncio.

Pestañas dormidas o sin cargar (Memory Saver, sesión restaurada): no tienen DOM, así que se descarga la metadata pública de la URL (`og:title` y `og:description`), sin cookies. Ojo: YouTube está bloqueado en el `hosts` de este PC, así que para esas pestañas solo queda el título que guarda Chrome.

Las pestañas cerradas se recuperan con `Ctrl+Shift+T` o desde el historial.

## Ambientes

Un ambiente (`environments/<nombre>.json`) define cómo entrar en foco en un proyecto. Tiene dos partes:

- **Qué se abre (fijo):** música de una carpeta en Windows Media Player, Docker Desktop y `docker compose up -d`, los servidores de desarrollo (se reutilizan si el puerto ya escucha) y las pestañas del proyecto en un perfil de Chrome concreto.
- **Qué se cierra (con contexto):** cada pestaña se juzga por lo que contiene. Primero se aplican las reglas `close` y `keep` sobre la URL. Después, el título, la URL y los datos de YouTube (título, canal, descripción) se comparan con `focusTopics`. Un vídeo de "cómo crear APIs" se queda; uno de MrBeast se cierra. Las apps de `closeApps` se cierran con aviso a la ventana y después por PID. Cada cierre muestra su motivo.

```bash
node env.js trabajo              # vista previa de encenderlo: qué cierra (y por qué), qué mantiene y qué abre
node env.js trabajo on --yes     # encenderlo (sin "on" también vale)
node env.js trabajo off          # vista previa de apagarlo: cierra SOLO lo suyo
node env.js trabajo off --yes    # apagarlo
node env.js status [--json]       # cuál está encendido, el último cambio y la lista de ambientes
```

**Determinista.** `env.js` tiene tres capas:
- `snapshot(env)` lee la máquina (pestañas, carpetas, procesos, puertos, Docker y gdocs).
- `plan(env, snapshot, on|off)` es una función pura: con el mismo estado da siempre las mismas acciones.
- `apply` las ejecuta.

`plan.test.js` recorre los casos con máquinas simuladas: encender desde cero, encender dos veces (no hace nada), duplicados, perfiles distintos, Chrome sin extensión, perfil inexistente, gdoc que falta, Docker apagado o compartido con otro proyecto, puertos libres u ocupados, cambiar de un ambiente a otro, apagar lo que no está encendido y que apagar nunca enciende nada.

El ambiente encendido queda en `run/active.json`. Con `--job`, el progreso se escribe en `run/job.json` (el paso actual, `done` o `error`); ClaudeMaxxing lee ese archivo. Solo se permite un cambio a la vez. Si un encendido falla a medias, no queda ningún ambiente marcado como encendido.

`trabajo`: Cliente. Brain.fm de `Music\Brain`, el stack de Docker, Vite en `:5173`, las pestañas de Django Admin (`:8000/api/v1/admin/`), del frontend, de los PR y Actions de GitHub, del portal de AWS (`example.awsapps.com/start`) y de producción en el perfil Laboral, y una sesión de Claude Code en `Cliente` con el lanzador de ClaudeMaxxing (`"claude": { "dir" }`; si ya hay una viva en esa carpeta no abre otra, y apagar nunca la cierra). Cierra otra música (YouTube Music), correo, WhatsApp, chats de claude.ai, Steam, Ollama, FreeLLMAPI, Configuración y Realtek. Cierra todo el perfil Personal, Calendar y cualquier carpeta del Explorador salvo la de Trabajo, que abre si no está. Mantiene lo que sea localhost, los repos de example-org, AWS, producción y sandbox.

`atlas`: Modulo, en el perfil Personal. Abre la carpeta del Atlas, el Tablero en `:5180` (con su propio `levantar.mjs`, que no duplica servidores) y los gdoc del Libro 1 y del Libro 2 (v0.4); el `doc_id` se lee del `.gdoc` en Drive. También abre la playlist de YouTube Music. Cierra todo el perfil Laboral, el Vite de Trabajo y el Brain.fm, para los contenedores de Cliente y, si no queda ningún otro contenedor, Docker Desktop. Mantiene los documentos de Drive y lo que trate del Atlas.

`startday`: para planear el día. Cierra todo y deja solo Calendar, Gmail y Claude (claude.ai) en Laboral, y Gmail, WhatsApp y Claude en Personal. Pone *Clair de Lune* de Claude Debussy (`"music": { "folder", "match" }`: solo las pistas cuyo nombre coincide). Para el Vite de Trabajo, el Tablero, Docker (contenedores y después Desktop), las apps de `closeApps` y todas las carpetas (`closeAllFolders`). Las pestañas que el ambiente abriría y ya existen en su perfil se conservan (una por elemento); los duplicados se cierran. Un ambiente que solo abre usa `"default": "keep"` en `tabs`.

`endday`: terminar el día. Cierra todo el perfil Laboral y, en Personal, lo que es trabajo (claude.ai, localhost, GitHub, AWS, Calendar); lo demás se queda. Baja todos los servidores, todo Docker y WSL, la música y las carpetas.

`vacio`: la mínima RAM. Cierra todas las pestañas de todos los perfiles, todas las carpetas, la música, Steam, Ollama y FreeLLMAPI; baja todos los servidores de desarrollo (`stopServers`: cualquier puerto ≥ 1024 que escuche un `node`, `python`, `uvicorn`, `deno`, `bun`, `java`, `dotnet`…, nunca los hosts de Chrome de los ambientes), para todos los contenedores (`"docker": { "all": true }`), apaga Docker Desktop y hace `wsl --shutdown` si la VM (`vmmem`) sigue viva (`wslShutdown`). No toca servicios de Windows (Postgres) ni las sesiones de Claude Code.

`gaming`: lo mismo que Vacío, pero abre Steam (`openApps`: se abre si no corre; apagar el ambiente lo cierra).

La música es del ambiente si Windows Media Player se abrió con su playlist (`run/<nombre>.m3u`, se lee de la línea de comandos del proceso). Si suena otra, se cierra antes de poner la suya; si ya suena la suya, no se reinicia.

El apagado es suave: se pide cerrar a todas las apps y servidores a la vez, se esperan `graceSeconds` (5 por defecto, 8 en el Atlas) y solo entonces se fuerza lo que siga abierto. `docker compose stop` da 30 s a cada contenedor. Las reglas `keep` ganan a las `close`, así la playlist del ambiente sobrevive a "cerrar otra música".

### Historial: transiciones y tiempo

Cada cambio queda en `run/history.json`: `edges["trabajo>atlas"]` cuenta las veces que pasaste de uno a otro (también si apagaste uno y encendiste otro después: `last` recuerda dónde estabas) y `time["2026-11-07"]["trabajo"]` los segundos que estuviste en cada uno. Encender el que ya está encendido no corta su tiempo. Un tramo cuenta como mucho 12 h (el PC pudo dormir con el ambiente encendido) y se apunta al día en que empezó. ClaudeMaxxing lo dibuja como un grafo. Qué estadísticas se pueden sacar de estos datos (cadena de Markov, reparto de tiempo, foco, HMM sobre la detección) y qué hay que guardar para ello: [docs/ESTADISTICAS.md](docs/ESTADISTICAS.md).

### ¿En qué ambiente estoy?

```bash
node env.js detect            # qué ambiente encaja con lo que está abierto (run/detect.json)
node env.js detect --force    # pregunta aunque nada haya cambiado; --state guarda también lo que se envió
```

Primero, lo determinista: una foto de todo lo abierto (pestañas de todos los perfiles, apps, música, servidores, carpetas, sesiones de Claude Code y contenedores) y, por cada ambiente, su encaje según su propio `plan`: lo que ya tiene abierto (`suyo`), lo que le falta y lo que cerraría (`sobra`). De la foto sale una huella con los sitios (no los títulos, que cambian con cada notificación). Si la huella no cambió desde la última vez, no se pregunta a nadie.

Si cambió, se pregunta a un juez: **Jev** (el *decision model* de TypeSafe, una pregunta Choice con probabilidades; usa `TYPESAFE_API_KEY` de la variable de entorno o de `.env` en la carpeta de datos del PC) y, si Jev no está, falla o tiene menos de 60 %, `claude -p` con Haiku y un `--json-schema` (sin hooks, plugins ni herramientas, con la suscripción). Ojo: los títulos de las pestañas se envían a TypeSafe o a Anthropic. Con la misma foto, cada detección escribe `run/focus.json` para la pestaña SelfHarness de ClaudeMaxxing: lo que el ambiente encendido cerraría (con su motivo) y los servidores de desarrollo que escuchan (puertos por debajo de 49152; nunca los hosts de Chrome). El veredicto (`suggestion`, `confidence`, `reason`, `judge`) va a `run/detect.json`, con `offer: true` cuando el ambiente sugerido no es el encendido. ClaudeMaxxing lanza la detección cada 3 minutos y, con `offer`, muestra el aviso "¿Quieres pasarte a …?".

## Pruebas

```bash
node test.js   # simula la extensión contra el host real y prueba el CLI (listar, cerrar por id/regex, desregistro)
```

## Límites

- No lee pestañas en incógnito salvo que actives "Permitir en incógnito" en la extensión.
- Páginas internas (`chrome://`, Web Store, páginas de error) no se pueden leer: salen solo con título y URL.
- Cada perfil abierto mantiene un proceso `node` (el host) mientras Chrome esté abierto.
