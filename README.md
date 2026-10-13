# ClaudeMaxxing

Tools for working with several Claude Code sessions at once on Windows 11:

- **Usage tray**: your Claude plan usage (5-hour window and weekly limit) in the notification area, when each one resets, and **Agendar sesión** to start the 5-hour window ahead of time.
- **"Abrir con Claude Code"** in the Explorer right-click menu: every session opens in its own half of a screen (two per monitor), with its own color and a name such as "Martín · codificador".
- **Voice**: each session opened from the menu reads a one-line summary of every answer aloud, with its own voice and a short musical signature. Details in [`voice/README.md`](voice/README.md) (Spanish).
- **Otros PCs**: PCs on the same Wi-Fi that both run ClaudeMaxxing find each other. After you pair them once, either one can open a terminal or Claude Code on the other, or run commands there from Claude Code with `ssh cmx-<pc>`. The other PC asks before letting anyone in. See [Otros PCs](#otros-pcs-terminals-between-your-pcs).

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
| `~/.claude/usage-tray`, `%TEMP%\claude-voice` | Data: usage snapshots, sessions, logs, voice history, and Otros PCs keys and paired PCs (`bridge\`) |

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

**How it is kept safe.**
- Each PC runs its own `sshd` as the signed-in user, started by the tray, with no Windows service and no admin rights. It runs only while the tray is running and at least one PC is paired. Only that same user can log in, so a connection gets that user's rights, never more. That is why the approval dialog says so.
- No passwords: pairing swaps SSH keys (ed25519), and the code shown on both screens proves no one swapped them in between. The code covers both PCs' keys and two random values, and one PC commits to its value before seeing the other's, so a machine in the middle can't make both screens show the same code. Host keys are pinned, so a PC that changes address is still recognised, and an impostor is refused.
- Every paired key is forced through a gate program (`restrict`, `command=`, no port or agent forwarding, LAN source addresses only). The gate asks the tray before running anything.
- The firewall rules only open the two ports on networks Windows marks **Private**, and only to the local subnet. On public Wi-Fi nothing listens, and nothing is announced.
- Pairing requests are only accepted while the Otros PCs window is open on that PC.
- Discovery messages (UDP 41021) are unauthenticated and only carry the PC name, user name and port, never keys. A forged one can at most make a connection fail.

**Limits.** Both PCs need ClaudeMaxxing, with the tray running and the user signed in. Logins are only as that PC's own Windows user. **Olvidar** removes the PC only on the PC where you click it. Each PC uses its own Claude plan.

## Development

The repo is only the installer. After editing anything, run `install.ps1` again to deploy it.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1         # tray, slots, installer, menu package, Otros PCs helpers and gate; every .ps1 is ASCII and parses
powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1   # voice, no audio
powershell -NoProfile -ExecutionPolicy Bypass -File test\bridge-e2e.ps1        # Otros PCs on loopback: two fake PCs pair over UDP and log in with every ssh client found
powershell -NoProfile -STA -ExecutionPolicy Bypass -File test\bridge-tray-e2e.ps1   # the same through the tray functions (approval, grant, sessions)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # draws the popup to an image (-RenderBridgeTo / -RenderApprovalTo: Otros PCs windows)
```

The two `bridge-*` checks need the installed OpenSSH (or `-SshDir <folder>`) and are not part of CI.

- `.ps1` files must stay ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. Accented UI text goes in as `\uXXXX` and is decoded with `Tx`, or comes from UTF-8 JSON.
- `lib/installer.ps1` lists exactly which files make up the installed runtime.
- **Menu** (`menu/`): an `IExplorerCommand` in C++ (`menu/src`), registered through a sparse MSIX (`menu/package`).
  - `menu\build.cmd` rebuilds `menu\bin\*.dll|exe`. It needs Visual Studio with C++.
  - `menu\package.ps1` rebuilds the unsigned `menu\bin\ClaudeCodeMenu.msix` after the manifest or the logos change. It needs the Windows SDK. Raise `Version` in `AppxManifest.xml` too, so existing installs re-register.
  - `menu\install.ps1` signs a copy with `menu\src\MsixSigner.cs` (it calls `SignerSignEx2` in `mssign32.dll`, the same API signtool uses) and registers it.

## Español

ClaudeMaxxing reúne tres herramientas para trabajar con varias sesiones de Claude Code en Windows 11:

- una **bandeja** con el uso del plan (la ventana de 5 horas y el límite semanal), la opción de **agendar sesión** y un **plan semanal** que reparte el límite semanal en sesiones hasta el corte;
- la entrada **Abrir con Claude Code** en el menú del Explorador, que abre cada sesión en una mitad de pantalla, con su color y su nombre;
- la **voz**: cada sesión lee en voz alta un resumen de cada respuesta ([`voice/README.md`](voice/README.md));
- **Otros PCs**: los PCs de la misma red con ClaudeMaxxing se encuentran solos. Una vez emparejados (los dos muestran el mismo código de 6 dígitos y confirmas en ambos), desde la bandeja abres una terminal o Claude Code en el otro PC, y desde Claude Code puedes usar `ssh cmx-<pc> "comando"`. El otro PC siempre pregunta antes de dejar entrar (**Permitir**, **Permitir 1 hora** o **Rechazar**) y avisa cuando se abre y se cierra una sesión. Va por SSH, con un `sshd` que corre como tu usuario mientras la bandeja está abierta, solo en redes privadas y solo desde la red local.

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
