# ClaudeMaxxing

Tools for working with several Claude Code sessions at once on Windows 11:

- **Usage tray**: your Claude plan usage (5-hour window and weekly limit) in the notification area, and when each one resets. Its **Entrar a ClaudeMaxxing** button opens the ClaudeMaxxing window, where every tool below has its status and settings (see [The ClaudeMaxxing window](#the-claudemaxxing-window)), including **Agendar sesión** to start the 5-hour window ahead of time.
- **"Abrir con Claude Code"** in the Explorer right-click menu: every session opens in its own half of a screen (two per monitor), with its own color and a name such as "Martín · codificador".
- **Voice**: each session opened from the menu reads a one-line summary of every answer aloud, with its own voice and a short musical signature. Details in [`voice/README.md`](voice/README.md) (Spanish).
- **Otros PCs**: PCs on the same Wi-Fi that both run ClaudeMaxxing find each other. After you pair them once, either one can open a terminal or Claude Code on the other, or run commands there from Claude Code with `ssh cmx-<pc>`. The other PC asks before letting anyone in. See [Otros PCs](#otros-pcs-terminals-between-your-pcs).
- **Claude Whisper**: a live copilot for calls (job interviews, meetings, sales calls). It transcribes the call as it happens, spots the questions the other side asks, and shows an answer from Claude written for you to say, using your profile and notes. It can also read your screen (for example a coding exercise). Everything runs on your Claude subscription through Claude Code. See [Claude Whisper](#claude-whisper-a-live-copilot-for-calls).

The user interface is in Spanish, and so are the voices (Latin American neural voices).

*Versión en español más abajo: [Español](#español).*

## Requirements

- Windows 11, x64. Windows 10 is untested. On ARM64 the menu is skipped, because its DLL is x64 only.
- An account that can approve UAC prompts: one for the menu entry and one for the Otros PCs firewall rules, both only the first time. Without them, everything else still installs.
- Claude Code installed, with `claude` on PATH.
- Windows Terminal (included with Windows 11).
- Optional: `winget`, so the installer can add what the voice needs (Python for edge-tts, and FFmpeg for ffplay). Without them, the voice uses the built-in Windows voice.
- Optional: a bash statusline script plus `jq`, so the tray updates on every Claude Code response. Without them, the tray refreshes from the usage endpoint instead (see [How the tray gets its data](#how-the-tray-gets-its-data)).

## Install

Clone the repo or download it as a ZIP, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

- Everything is copied to `%LOCALAPPDATA%\ClaudeMaxxing`, and everything runs from there. After installing you can move or delete the repo.
- The first time, Windows shows **two UAC prompts**:
  - one trusts a code-signing certificate that the installer creates on your PC, which signs the package for the Explorer menu entry. The certificate's private key never leaves your PC. You don't need Visual Studio or the Windows SDK: the menu DLL and its package come prebuilt in `menu/bin`;
  - the other creates the firewall rules for Otros PCs (see below).
- For Otros PCs the installer downloads the portable [Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) release from GitHub (about 5 MB). It is pinned: the zip must match a fixed SHA-256, and every program in it must be signed by Microsoft.
- The menu entry appears after you restart Explorer or sign out and back in.
- To update, run `install.ps1` again from a newer copy of the repo. It is idempotent, and it keeps your per-PC settings (`voice\config.local.json`).

| Option | Effect |
|---|---|
| `-InstallDir <path>` | Install somewhere other than `%LOCALAPPDATA%\ClaudeMaxxing` |
| `-SkipMenu` | Don't install or update the Explorer menu entry |
| `-SkipVoiceDeps` | Don't install edge-tts or FFmpeg (the voice uses the Windows voice) |
| `-NoHotkeys` | Don't enable the global voice hotkeys (Ctrl+Alt+Shift+O repeats, Ctrl+Alt+Shift+P stops) |
| `-NoStart` | Don't start the tray now (it still starts when you sign in) |
| `-BuildMenu` | Rebuild the menu DLL from source first (needs Visual Studio with C++) |
| `-SkipBridge` | Don't set up Otros PCs (no OpenSSH download, no firewall rules, no `~/.ssh/config` change) |

### What it changes on your PC

| Where | What |
|---|---|
| `%LOCALAPPDATA%\ClaudeMaxxing` | The runtime: tray, menu launcher, voice. Voice settings for this PC go in `voice\config.local.json`, and edge-tts in `voice\venv` when it has to be installed |
| `%LOCALAPPDATA%\ClaudeCodeMenu` | The Explorer extension (DLL, stub, icons) |
| Packages | `ClaudeCode.ContextMenu`, a sparse package signed with this PC's `CN=ClaudeCodeMenu` certificate (CurrentUser\My, trusted in LocalMachine\TrustedPeople) |
| `HKCU\Software\ClaudeCodeMenu\Launcher` | The command the menu entry runs |
| Startup folder | `ClaudeMaxxing.lnk` (tray) and `ClaudeMaxxing atajos.lnk` (voice hotkeys) |
| Settings > Apps | A "ClaudeMaxxing" entry; uninstalling it there runs `uninstall.ps1` |
| `~/.claude/statusline-command.sh` | A block that saves `rate_limits` to `~/.claude/usage-tray/usage.json` (a backup is kept). Nothing else in `~/.claude` changes |
| `%LOCALAPPDATA%\ClaudeMaxxing\ssh` | Otros PCs: the portable OpenSSH (`sshd`, `ssh`, `sftp`...) |
| Windows Defender Firewall | Otros PCs: two inbound rules in the `ClaudeMaxxing` group, TCP 41022 for that `sshd.exe` and UDP 41021 for PowerShell, **Private networks only, from the local subnet only** |
| `~/.ssh/config` | Otros PCs: a marked block at the top that includes `~/.claude/usage-tray/bridge/ssh_config` (a backup of the file is kept the first time) |
| `~/.claude/usage-tray`, `%TEMP%\claude-voice` | Data: usage snapshots, sessions, logs, voice history, Otros PCs keys and paired PCs (`bridge\`), Claude Whisper's settings and call history (`whisper\`), and the Estadísticas result and its per-transcript cache (`stats.json`, `stats-cache.json`) |

## Uninstall

Use Settings > Apps > ClaudeMaxxing, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeMaxxing\uninstall.ps1"
```

This removes everything listed above, including the menu entry, its certificate and the Otros PCs firewall rules (one UAC prompt for both). Data in `~/.claude/usage-tray` and `%TEMP%\claude-voice` is kept unless you pass `-RemoveData`. `-KeepMenu` keeps the menu entry, which then opens a plain Windows Terminal.

## How it works

### How the tray gets its data

- Claude Code's statusline receives `rate_limits` on every response. The block added to your statusline script saves them to `~/.claude/usage-tray/usage.json`; what the statusline shows doesn't change. The tray reads that file every 15 s. Left-click opens or closes the popup; right-click opens the menu.
- The **↻** button asks for live usage from the endpoint that `/usage` uses (`api.anthropic.com/api/oauth/usage`, with Claude Code's local token). The tray also asks it on start, and when you open the popup if the data is more than 10 minutes old. That endpoint is **undocumented**: if it changes, the popup shows the error and keeps the statusline data. Extra usage and an available limit reset show up as extra sections when the account has them.
- The green dot means some Claude Code session answered in the last 10 minutes.

### The ClaudeMaxxing window

**Entrar a ClaudeMaxxing**, the button at the bottom of the popup (also first in the tray menu), opens one window with every tool. A side menu switches between these sections:

- **Inicio**: an overview. It shows session and weekly usage and the next scheduled session. It also has a diagram of the PCs on your network: this PC in the middle and each other PC around it. The line to each PC shows its state: an orange line when it has a session open on this PC, green when it is online, dashed grey when it hasn't been seen lately, and dotted for PCs with ClaudeMaxxing that aren't paired yet. Last come Claude Whisper's latest calls, the open Claude Code sessions and the voice switches.
- **Uso y agenda**: both limits, a refresh, the scheduled sessions, and buttons for **Agendar sesión...** and **Plan semanal...** (the dialog described below).
- **Estadísticas**: when and how much you work with Claude Code, for the last 30 days or for all time. The data comes from Claude Code's own transcripts in `~/.claude/projects`; nothing leaves your PC. It has four tabs:
  - **Resumen**: hours with Claude, active days, the streak, prompts, replies, sessions and subagents, the average per active day, this week compared with the last one, how many sessions you run at once, and tool uses. It also shows when you work most (peak hour, peak weekday, part of the day, record day) and hours per day (per week for all time).
  - **Horarios**: a weekday × hour heatmap, hours by hour of the day, and the share of early morning, morning, afternoon and night.
  - **Proyectos**: time, prompts and sessions per folder, plus the average, median and longest session.
  - **Modelos y herramientas**: replies and output tokens per model, total tokens and the cache share, the tools Claude used most, and counts from the other tools (Whisper calls, scheduled sessions that ran, sessions opened from the menu, paired PCs).

  Hover over a bar or a cell to read its value. Time is active time: the gaps between events of a session that are under 15 minutes, with a lone event counted as one minute. Parallel sessions are counted once in "hours with Claude"; "en paralelo" compares that with the sum of all sessions. The first scan reads every transcript on a background thread, which takes several seconds for hundreds of MB. After that only changed files are read again (`stats-cache.json`), and the window recomputes when the result is more than 10 minutes old. Claude Code deletes transcripts older than 30 days (`cleanupPeriodDays`), but the cache keeps their summaries, so all-time statistics keep growing from the first scan on.
- **Claude Code**: the sessions opened from the Explorer menu, with color, name, role, voice and screen half. **Mostrar** brings a session's window to the front, and **Nueva sesión...** opens one in a folder you pick. It also tells you whether the menu entry is installed.
- **Otros PCs**: the same diagram, larger. The section also has this PC's status, the **Acepta conexiones** switch and the paired PCs, with **Terminal**, **Claude Code** and **Desconectar**. Pairing still happens in the Otros PCs window (**Emparejar o buscar un PC...**), because pairing is only accepted while that window is open.
- **Claude Whisper**: open or show it, **Contexto...**, language, model, the answer, microphone and call-notice options, and the hotkeys. Also its call history: date, length, number of answers and the first question. Click a call to open its Markdown file. While Whisper is open, its settings are changed in its own window, so here they are read-only.
- **Voz**: voice on or off for every session, the global hotkeys, **Probar voz**, **Repetir lo último** and **Detener audio**. It also lists the sessions that spoke in the last 12 hours, each with its own on/off switch.

### Scheduling a session

The 5-hour window starts with your first message, so scheduling a tiny prompt (Haiku, "ok") starts it, and resets it, earlier.

- **On this PC**: a one-off task in Task Scheduler (`\ClaudeMaxxing\`). It wakes the PC from sleep if wake timers are enabled. It doesn't run if the PC is off or you are signed out.
- **In the cloud**: Claude Code creates a claude.ai routine with `/schedule`, without a window. This works with the PC off.

### Planning the week

The **Semana** tab of the same dialog (also **Plan semanal...** in the tray menu) plans back-to-back 5-hour windows up to the weekly cutoff, so the weekly limit gets used before it resets.

- Choose how many sessions a day and when the first one starts; the windows follow 5 hours apart. The cutoff comes from the weekly usage data (without data, you pick the weekday and hour).
- Each day shows its window start times and the weekly usage to reach by the end of the day; the summary gives the share of the weekly limit to spend per session. It is a target: nothing reports how much of the weekly limit one window uses.
- **Agendar plan** creates a Task Scheduler task for every planned window that has nothing scheduled near it (those show a ✓). Settings are saved in `~/.claude/usage-tray/plan.json`.

### Half-screen sessions

- With **n** monitors there are **2n** slots, the left and right half of each monitor. Each new session takes the first free one. When they are all taken, the tray says so and opens nothing.
- Each slot has a color. The tab and Claude Code's prompt box get it (`/color`, sent as a local command, so no model call).
- Before Claude Code starts, the launcher reserves a name and a voice for the session. It then starts Claude Code with that `--session-id` and the voice plugin (`--plugin-dir`, for that session only). On the first real prompt the name gets a role: "Martín" becomes "Martín · codificador".
- Only sessions opened from the menu take a slot.

### Otros PCs: terminals between your PCs

For two (or more) PCs on the same network that both run ClaudeMaxxing. Typical use: Claude Code on this PC needs a file or a command result from the other one, or you want a second Claude Code working there.

**Pairing (once per pair of PCs).** Open **Otros PCs...** from the tray menu on both PCs. Each one lists the other under *En tu red* (a ClaudeMaxxing PC that appears on the network for the first time also shows a notification). Click **Emparejar** on one of them. Both windows then show the same 6-digit code: check that it matches and confirm on both. If a PC doesn't show up (some routers isolate Wi-Fi clients or drop broadcasts), type its IP address in the box at the bottom.

**Using it.**
- In the tray menu, **Otros PCs > Terminal en <PC>** opens a PowerShell on the other PC in Windows Terminal, and **Claude Code en <PC>** opens Claude Code there. From any terminal, or from Claude Code itself, `ssh cmx-<pc> "<command>"`, `scp` and `sftp` work too. The window shows each PC's `ssh cmx-...` name; click it to copy it.
- The other PC shows **Conexión entrante** with the PC, the user and what it wants to do: open a terminal, run a command, open Claude Code, or copy files. Its options are **Permitir**, **Permitir 1 hora** (no more questions from that PC for an hour; Claude Code runs one connection per command) or **Rechazar**. With no answer within 60 seconds, the connection is refused.
- That PC also gets a notification when a terminal opens and closes there, and **Otros PCs > Desconectar** ends a session. **Acepta conexiones** in the window turns incoming connections off.

**How it is kept safe.** What a connection gets, once allowed, is a shell as that PC's Windows user. So the design is about who can ask, what the person at the other PC sees before saying yes, and what keeps working when something fails.

- **Who can log in.** Each PC runs its own `sshd` as the signed-in user, started by the tray, with no Windows service and no admin rights. Only that same user can log in: a paired key asking for Administrator, SYSTEM or any other account is refused (checked in testing). There are no passwords (`AuthenticationMethods publickey`), and only keys exchanged by pairing are accepted.
- **Pairing.** It swaps ed25519 keys, and both screens show a 6-digit code computed from both PCs' keys and two random values. One PC commits to its value before it sees the other's, so a machine in the middle can't make both screens show the same code. The window says to confirm only when the other PC shows exactly that code, and it shows the IP the request comes from. A PC only answers pairing requests while its Otros PCs window is open, and only during the first 10 minutes. Host keys are pinned, so a PC that changes address is still recognised and an impostor is refused.
- **Every connection is approved.**
  - Every paired key is forced through a gate program (`restrict`, `command=`, no port, agent or X11 forwarding, LAN source addresses only).
  - The gate asks the tray before running anything, and lets nobody in when the tray is not running, not even a PC allowed for an hour.
  - The dialog shows one request at a time; **Permitir** and **Rechazar** apply only to that request.
  - Commands are shown in full: line breaks and invisible characters are made visible, and space padding that could push the dangerous part out of view is collapsed. Only the exact command `claude` is labelled "Claude Code".
  - The buttons stay off for 1.5 seconds after a request appears, so a click meant for another window can't allow it. With no answer, the connection is refused after 60 seconds.
  - **Permitir 1 hora** is capped at an hour, and the gate refuses longer grants.
- **Tampering.** `authorized_keys` and the gate's settings are compared every 5 seconds with what the tray writes. A key or setting added from outside (for example by a session that was allowed) is put back and reported.
- **Network.**
  - The firewall rules open the two ports only on networks Windows marks **Private**, and only to the local subnet.
  - The server and the discovery socket listen only on this PC's address in a Private network. On public Wi-Fi nothing listens and nothing is announced.
  - Discovery messages (UDP 41021) are unauthenticated and carry only the PC name, user name and port. They are size-limited and rate-limited, so a flood or a forged message can't freeze the tray, fill it with fake PCs, or do more than make a connection fail.
- **Your own `~/.ssh/config`.** The `cmx-*` hosts turn off agent and X11 forwarding, proxies, local commands and host-key updates, so a `Host *` entry of yours can't hand anything of this PC to the other one.
- **OpenSSH.** It is the official Win32-OpenSSH release, pinned by SHA-256, with every program checked for Microsoft's signature.

**What it can't protect against.**
- **An allowed connection has your rights.** It can read your files, including Claude Code's login in `~/.claude`, install programs, or change ClaudeMaxxing itself. Allow only your own PCs, and only connections you expect. Use **Permitir 1 hora** only while you are working with that PC.
- **The other PC.** If a paired PC is compromised, whoever controls it can ask for connections. Each request still needs your approval, unless an hour grant is active. **Olvidar** removes that PC's key at once.
- **Programs already running as you.** Anything running as your user on this PC can change the files in `%LOCALAPPDATA%\ClaudeMaxxing` and `~/.claude/usage-tray`. That includes `sshd.exe`, which the firewall rule trusts. That is true of every program you run.
- **Who is on your network.** Your PC name and user name are announced to the local network every 30 seconds, on Private networks only. Mark a network Private only if you trust who is on it.

**Limits.** Both PCs need ClaudeMaxxing, with the tray running and the user signed in. Logins are only as that PC's own Windows user. **Olvidar** removes the PC only on the PC where you click it. Each PC uses its own Claude plan.

### Claude Whisper: a live copilot for calls

Open **Claude Whisper** from the tray menu and press **Escuchar** when the call starts. The window stays on top of the call app.

- **Transcript.** What the PC plays (the other side of the call, any app: Teams, Zoom, Meet in a browser...) shows as **Ellos**, and your microphone as **Tú**. Words appear as they are spoken.
- **Answers.** When the other side finishes a question, Claude writes what you could say: one or two sentences, then a few short points. It uses what you put in **Contexto**: your CV or experience, the conversation (job, company, goal) and your instructions (tone, length). It doesn't make up experience you didn't list; where a detail is missing it leaves a gap like `[años]`. A newer question stops an answer still being written. Earlier answers stay one click away (‹ ›).
- **Responder** (Ctrl+Alt+Shift+R) asks for an answer now, **Pantalla** (Ctrl+Alt+Shift+C) sends the monitor under the mouse to Claude (it solves an exercise on screen, or tells you what matters there), and the box at the bottom asks Claude anything without saying it in the call. Ctrl+Alt+Shift+W hides or shows the window. The keys can be changed in `~/.claude/usage-tray/whisper/settings.json`.
- **History.** Every call is saved as Markdown (transcript and answers) in `~/.claude/usage-tray/whisper/sessions`; **⋯ > Historial de llamadas** opens the folder.
- **Calls starting.** Once you have used Claude Whisper, the tray shows a notice when a call app (Teams, Zoom, Webex, Slack, Discord...) starts using the microphone; click it to open Claude Whisper.
- **Without headphones** the microphone also hears the speakers. While the other side is talking, your mic is muted for the transcript, and lines that repeat what they just said are dropped. Headphones work best.

**How it works.**
- Audio is captured with WASAPI (the speakers in loopback, and the microphone), converted to 16 kHz mono and streamed to the speech-to-text service that Claude Code's own voice dictation uses (`wss://api.anthropic.com/api/ws/speech_to_text/voice_stream`), signed in with Claude Code's login from `~/.claude/.credentials.json`. That service is built for hold-to-talk: it keeps one growing transcript per connection. Claude Whisper cuts it into lines itself: a line ends after a pause, or when the text stops changing, and the connection is replaced by a fresh one every minute or so, at a pause.
- Answers come from a single `claude -p` that stays open for the whole call (stream-json in and out), so Claude keeps the conversation and every answer skips the start-up time. It runs with no tools, no CLAUDE.md, hooks, plugins or MCP servers, and none of your Claude Code settings, from its own folder. API key variables are removed from its environment, so it always uses your subscription. Your context goes in its system prompt.
- Everything is plain PowerShell and C# compiled on the first run (`lib/whisper.cs`); nothing else is installed.

**Things to know.**
- **The speech-to-text service is not a public API.** It is what Claude Code's `/voice` dictation calls, used here outside Claude Code and for longer stretches than dictation. It is undocumented: it could change, be limited, or stop working, and continuous use like this may not be what the subscription intends. If it fails, the window says so and keeps retrying; the answers part keeps working with what you type.
- **Every answer uses your plan.** Each answer is a Claude turn and counts against the 5-hour and weekly limits like any other. Answers start automatically only after a question; you can turn that off in **Contexto** and use **Responder** instead. Haiku is faster and lighter on the limits; Sonnet is the default.
- **The call is sent to Anthropic.** Audio goes to the speech service and the transcript to Claude, under your Claude account. Tell the people in the call when that matters, and follow the rules that apply to recording or transcribing calls where you are.
- Claude Whisper does not hide itself: the window shows in screen sharing and in the taskbar like any other window.

## Development

The repo is only the installer. After editing anything, run `install.ps1` again to deploy it.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1         # tray, slots, installer, menu package, Otros PCs helpers and gate; every .ps1 is ASCII and parses
powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1   # voice, no audio
powershell -NoProfile -ExecutionPolicy Bypass -File test\bridge-e2e.ps1        # Otros PCs on loopback: two fake PCs pair over UDP and log in with every ssh client found
powershell -NoProfile -STA -ExecutionPolicy Bypass -File test\bridge-tray-e2e.ps1   # the same through the tray functions (approval, grant, sessions)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # draws the popup to an image (-RenderBridgeTo / -RenderApprovalTo: Otros PCs windows; -RenderHubTo with -HubSection home|usage|stats|stats-hours|stats-projects|stats-models|code|pcs|whisper|voice, add -all to a stats tab for all time: the ClaudeMaxxing window)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File whisper.ps1 -RenderTo whisper.png   # Claude Whisper with sample data (shows the window for a moment)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File whisper.ps1 -SimulateWav call.wav -ExitAfter 30 -ReportTo report.json   # end to end: a 16 kHz mono WAV as the other side, real transcription and answers
```

The two `bridge-*` checks need the installed OpenSSH (or `-SshDir <folder>`) and are not part of CI.

- `.ps1` files must stay ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. Accented UI text goes in as `\uXXXX` and is decoded with `Tx`, or comes from UTF-8 JSON.
- `lib/installer.ps1` lists exactly which files make up the installed runtime.
- **Menu** (`menu/`): an `IExplorerCommand` in C++ (`menu/src`), registered through a sparse MSIX (`menu/package`).
  - `menu\build.cmd` rebuilds `menu\bin\*.dll|exe`. It needs Visual Studio with C++.
  - `menu\package.ps1` rebuilds the unsigned `menu\bin\ClaudeCodeMenu.msix` after the manifest or the logos change. It needs the Windows SDK. Raise `Version` in `AppxManifest.xml` too, so existing installs re-register.
  - `menu\install.ps1` signs a copy with `menu\src\MsixSigner.cs` (it calls `SignerSignEx2` in `mssign32.dll`, the same API signtool uses) and registers it.

## Español

ClaudeMaxxing reúne estas herramientas para trabajar con Claude Code en Windows 11:

- una **bandeja** con el uso del plan (la ventana de 5 horas y el límite semanal), la opción de **agendar sesión** y un **plan semanal** que reparte el límite semanal en sesiones hasta el corte. El botón **Entrar a ClaudeMaxxing** de la bandeja abre una ventana con todas las herramientas, cada una con su estado y su configuración. Está dividida en las secciones Inicio, Uso y agenda, Estadísticas, Claude Code, Otros PCs, Claude Whisper y Voz. Incluye un diagrama de los PCs cercanos que muestra si hay conexión con cada uno y el historial de llamadas de Claude Whisper. **Estadísticas** muestra cuándo trabajas más (un mapa de día × hora, la hora y el día pico, por franjas) y todas las métricas que se pueden sacar de las conversaciones de Claude Code de tu PC: horas, racha, prompts, sesiones, proyectos, modelos, tokens y herramientas. Esos datos se leen en local y no salen de tu PC. Claude Code borra las conversaciones de más de 30 días, pero ClaudeMaxxing guarda su resumen, así que el histórico sigue creciendo desde el primer cálculo;
- la entrada **Abrir con Claude Code** en el menú del Explorador, que abre cada sesión en una mitad de pantalla, con su color y su nombre;
- la **voz**: cada sesión lee en voz alta un resumen de cada respuesta ([`voice/README.md`](voice/README.md));
- **Otros PCs**: los PCs de la misma red con ClaudeMaxxing se encuentran solos. Una vez emparejados (los dos muestran el mismo código de 6 dígitos y confirmas en ambos), desde la bandeja abres una terminal o Claude Code en el otro PC, y desde Claude Code puedes usar `ssh cmx-<pc> "comando"`. El otro PC siempre pregunta antes de dejar entrar (**Permitir**, **Permitir 1 hora** o **Rechazar**) y avisa cuando se abre y se cierra una sesión. Va por SSH, con un `sshd` que corre como tu usuario mientras la bandeja está abierta, solo en redes privadas y solo desde la red local;
- **Claude Whisper**: un copiloto para llamadas (entrevistas, reuniones, ventas). Se abre desde el menú de la bandeja; al pulsar **Escuchar** transcribe en vivo lo que suena en el PC (**Ellos**) y tu micrófono (**Tú**), detecta cuándo te hacen una pregunta y Claude te propone qué decir, con tu perfil y tus notas de **Contexto**. **Responder** (Ctrl+Alt+Shift+R) pide una respuesta ya, **Pantalla** (Ctrl+Alt+Shift+C) le manda a Claude el monitor donde está el ratón (por ejemplo un ejercicio de programación) y Ctrl+Alt+Shift+W oculta o muestra la ventana. Cada llamada queda guardada en Markdown en `~/.claude/usage-tray/whisper/sessions`. Todo va con tu suscripción de Claude a través de Claude Code: la transcripción usa el mismo servicio que el dictado por voz de Claude Code (no es una API pública: puede cambiar o dejar de funcionar) y las respuestas, un `claude -p` que queda abierto durante la llamada. Cada respuesta cuenta para tus límites de uso. La llamada se envía a Anthropic: avisa a los demás cuando corresponda. Detalles en [Claude Whisper](#claude-whisper-a-live-copilot-for-calls).

**Instalar:** clona el repo o descárgalo en ZIP, y ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

- Todo se copia a `%LOCALAPPDATA%\ClaudeMaxxing` y se ejecuta desde ahí, así que después puedes mover o borrar el repo. Para actualizar, vuelve a ejecutar `install.ps1` desde una copia nueva.
- La primera vez Windows pide **dos permisos de administrador (UAC)**: uno para confiar en un certificado que se crea en tu PC y firma la entrada del menú, y otro para las reglas del firewall de Otros PCs. No necesitas Visual Studio ni el Windows SDK.
- Para Otros PCs, el instalador descarga el OpenSSH portable de Microsoft (unos 5 MB), comprobando un SHA-256 fijo y la firma de Microsoft, y añade un bloque marcado al principio de `~/.ssh/config`. `-SkipBridge` se salta todo esto.
- La entrada del menú aparece después de reiniciar el Explorador o de cerrar sesión.
- Si tienes `winget`, el instalador añade lo que necesita la voz: Python con edge-tts en un entorno propio, y FFmpeg para ffplay. Si no, la voz usa la de Windows.
- Lo propio de tu PC (rutas, cambios a la configuración de voz) va en `voice\config.local.json` y se conserva al actualizar.

**Requisitos:** Windows 11 x64 (Windows 10 sin probar), Claude Code (`claude` en el PATH), Windows Terminal y poder aprobar los avisos de UAC (para el menú y el firewall). Para que la bandeja se actualice con cada respuesta, además, una barra de estado (statusline) en bash y `jq`.

**Desinstalar:** desde Configuración > Aplicaciones > ClaudeMaxxing, o con `uninstall.ps1` en la carpeta de instalación. Tus datos (`~/.claude/usage-tray`, `%TEMP%\claude-voice`) se conservan, salvo que uses `-RemoveData`.

**Desarrollo:** el repo es solo el instalador. Después de cambiar algo, vuelve a ejecutar `install.ps1`. Las pruebas están en `test\run-tests.ps1` y `voice\test\run-tests.ps1`.
