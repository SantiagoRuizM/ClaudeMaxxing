# ClaudeMaxxing

Tools for working with several Claude Code sessions at once on Windows 11:

- **Usage tray**: your Claude plan usage (5-hour window and weekly limit) in the notification area, when each one resets, and **Agendar sesión** to start the 5-hour window ahead of time.
- **"Abrir con Claude Code"** in the Explorer right-click menu: every session opens in its own half of a screen (two per monitor), with its own color and a name such as "Martín · codificador".
- **Voice**: each session opened from the menu reads a one-line summary of every answer aloud, with its own voice and a short musical signature. Details in [`voice/README.md`](voice/README.md) (Spanish).

The user interface is in Spanish, and so are the voices (Latin American neural voices).

*Versión en español más abajo: [Español](#español).*

## Requirements

- Windows 11, x64. Windows 10 is untested. On ARM64 the menu is skipped, because its DLL is x64 only.
- An account that can approve a UAC prompt (once, for the menu entry). Without it, everything except the menu entry still installs.
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
- The first time, Windows shows **one UAC prompt**. It trusts a code-signing certificate that the installer creates on your PC, which signs the package for the Explorer menu entry. The certificate's private key never leaves your PC. You don't need Visual Studio or the Windows SDK: the menu DLL and its package come prebuilt in `menu/bin`.
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
| `~/.claude/usage-tray`, `%TEMP%\claude-voice` | Data: usage snapshots, sessions, logs, and voice history |

## Uninstall

Use Settings > Apps > ClaudeMaxxing, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeMaxxing\uninstall.ps1"
```

This removes everything listed above, including the menu entry and its certificate (one UAC prompt). Data in `~/.claude/usage-tray` and `%TEMP%\claude-voice` is kept unless you pass `-RemoveData`. `-KeepMenu` keeps the menu entry, which then opens a plain Windows Terminal.

## How it works

### How the tray gets its data

- Claude Code's statusline receives `rate_limits` on every response. The block added to your statusline script saves them to `~/.claude/usage-tray/usage.json`; what the statusline shows doesn't change. The tray reads that file every 15 s. Left-click opens or closes the popup; right-click opens the menu.
- The **↻** button asks for live usage from the endpoint that `/usage` uses (`api.anthropic.com/api/oauth/usage`, with Claude Code's local token). The tray also asks it on start, and when you open the popup if the data is more than 10 minutes old. That endpoint is **undocumented**: if it changes, the popup shows the error and keeps the statusline data. Extra usage and an available limit reset show up as extra sections when the account has them.
- The green dot means some Claude Code session answered in the last 10 minutes.

### Scheduling a session

The 5-hour window starts with your first message, so scheduling a tiny prompt (Haiku, "ok") starts it, and resets it, earlier.

- **On this PC**: a one-off task in Task Scheduler (`\ClaudeMaxxing\`). It wakes the PC from sleep if wake timers are enabled. It doesn't run if the PC is off or you are signed out.
- **In the cloud**: Claude Code creates a claude.ai routine with `/schedule`, without a window. This works with the PC off.

### Half-screen sessions

- With **n** monitors there are **2n** slots, the left and right half of each monitor. Each new session takes the first free one. When they are all taken, the tray says so and opens nothing.
- Each slot has a color. The tab and Claude Code's prompt box get it (`/color`, sent as a local command, so no model call).
- Before Claude Code starts, the launcher reserves a name and a voice for the session. It then starts Claude Code with that `--session-id` and the voice plugin (`--plugin-dir`, for that session only). On the first real prompt the name gets a role: "Martín" becomes "Martín · codificador".
- Only sessions opened from the menu take a slot.

## Development

The repo is only the installer. After editing anything, run `install.ps1` again to deploy it.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1         # tray, slots, installer, menu package; every .ps1 is ASCII and parses
powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1   # voice, no audio
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # draws the popup to an image
```

- `.ps1` files must stay ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. Accented UI text goes in as `\uXXXX` and is decoded with `Tx`, or comes from UTF-8 JSON.
- `lib/installer.ps1` lists exactly which files make up the installed runtime.
- **Menu** (`menu/`): an `IExplorerCommand` in C++ (`menu/src`), registered through a sparse MSIX (`menu/package`).
  - `menu\build.cmd` rebuilds `menu\bin\*.dll|exe`. It needs Visual Studio with C++.
  - `menu\package.ps1` rebuilds the unsigned `menu\bin\ClaudeCodeMenu.msix` after the manifest or the logos change. It needs the Windows SDK. Raise `Version` in `AppxManifest.xml` too, so existing installs re-register.
  - `menu\install.ps1` signs a copy with `menu\src\MsixSigner.cs` (it calls `SignerSignEx2` in `mssign32.dll`, the same API signtool uses) and registers it.

## Español

ClaudeMaxxing reúne tres herramientas para trabajar con varias sesiones de Claude Code en Windows 11:

- una **bandeja** con el uso del plan (la ventana de 5 horas y el límite semanal) y la opción de **agendar sesión**;
- la entrada **Abrir con Claude Code** en el menú del Explorador, que abre cada sesión en una mitad de pantalla, con su color y su nombre;
- la **voz**: cada sesión lee en voz alta un resumen de cada respuesta ([`voice/README.md`](voice/README.md)).

**Instalar:** clona el repo o descárgalo en ZIP, y ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

- Todo se copia a `%LOCALAPPDATA%\ClaudeMaxxing` y se ejecuta desde ahí, así que después puedes mover o borrar el repo. Para actualizar, vuelve a ejecutar `install.ps1` desde una copia nueva.
- La primera vez Windows pide **un permiso de administrador (UAC)**. Sirve para confiar en un certificado que se crea en tu PC y firma la entrada del menú. No necesitas Visual Studio ni el Windows SDK.
- La entrada del menú aparece después de reiniciar el Explorador o de cerrar sesión.
- Si tienes `winget`, el instalador añade lo que necesita la voz: Python con edge-tts en un entorno propio, y FFmpeg para ffplay. Si no, la voz usa la de Windows.
- Lo propio de tu PC (rutas, cambios a la configuración de voz) va en `voice\config.local.json` y se conserva al actualizar.

**Requisitos:** Windows 11 x64 (Windows 10 sin probar), Claude Code (`claude` en el PATH), Windows Terminal y poder aprobar un aviso de UAC (solo para el menú). Para que la bandeja se actualice con cada respuesta, además, una barra de estado (statusline) en bash y `jq`.

**Desinstalar:** desde Configuración > Aplicaciones > ClaudeMaxxing, o con `uninstall.ps1` en la carpeta de instalación. Tus datos (`~/.claude/usage-tray`, `%TEMP%\claude-voice`) se conservan, salvo que uses `-RemoveData`.

**Desarrollo:** el repo es solo el instalador. Después de cambiar algo, vuelve a ejecutar `install.ps1`. Las pruebas están en `test\run-tests.ps1` y `voice\test\run-tests.ps1`.
