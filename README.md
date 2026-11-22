<p align="center">
  <img src="logo_pixel.png" alt="ClaudeMaxxing logo" width="160">
</p>

<h1 align="center">ClaudeMaxxing</h1>

<p align="center">
  <strong>Get the most out of your Claude plan</strong> <em>(on Windows 11)</em>
</p>

<p align="center">
  See what's left of your plan and make it last. Claude Code sessions tiled across your screens, answers read aloud, snips straight to Claude and a copilot for your calls<br>
  (all from the Windows tray, and from your Android phone if you want).
</p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#guide">Docs</a> ·
  <a href="#privacy-risks-and-permissions">Privacy</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-000?labelColor=555" alt="MIT licence"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/github/package-json/v/SantiagoRuizM/ClaudeMaxxing?label=version&amp;labelColor=555&amp;color=000" alt="Current version"></a>
  <a href="https://github.com/SantiagoRuizM/ClaudeMaxxing/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/SantiagoRuizM/ClaudeMaxxing/ci.yml?branch=main&amp;label=CI&amp;labelColor=555&amp;color=000" alt="CI status"></a>
  <br>
  <a href="#requirements"><img src="https://img.shields.io/badge/Windows%2011-x64-000?labelColor=555" alt="Windows 11, x64"></a>
  <a href="#phone-app"><img src="https://img.shields.io/badge/Android-companion%20app-000?labelColor=555" alt="Android companion app"></a>
</p>

> **Questions, concerns or a bug in ClaudeMaxxing?** Email [santiago.ruizm40@gmail.com](mailto:santiago.ruizm40@gmail.com) with a summary of what happened, or of the feature you would like.

---

> **1.1.0** (8 November 2026) is the current version, for Windows 11 (x64); Windows 10 is untested. There is no packaged release yet, so the [installer](#install) gets the `main` branch, which also has the [unreleased changes](CHANGELOG.md#unreleased) merged so far.

## Installation

### Install and update on each device

| Device | Install | Update | Uninstall |
|---|---|---|---|
| **PC** (Windows 11) | [One command](#install) | [Click the notice](#update-the-pc) | [Settings > Apps](#uninstalling) |
| **Android phone** (optional) | [The APK, then a QR](#install-on-the-phone) | [Tap the notice](#update-the-phone) | [Forget the PC, then uninstall](#uninstall-from-the-phone) |
| **Tailscale** (optional, to use the phone away from your Wi-Fi) | [On the PC and the phone, before pairing](#tailscale-away-from-your-wi-fi) | By Tailscale itself | Like any app |
| **Another PC** (optional) | [The same command there](#install), then [pair them](#other-pcs) | [On each PC](#update-another-pc) | On each PC |
| **iPhone, macOS, Linux** | Not available | | |

### Requirements

| | |
|---|---|
| **Windows** | Windows 11, x64. Windows 10 is untested. On ARM64 the Explorer menu entry is skipped, because its DLL is x64 only. |
| **Claude Code** | Installed, with `claude` on `PATH`. Peek needs 2.1.319 or later and the fullscreen interface (`"tui": "fullscreen"` in `~/.claude/settings.json`, or `/config`). |
| **Windows Terminal** | Included with Windows 11. |
| **Admin approval** | One UAC prompt for the menu entry on the first install, and one for the firewall rules of Other PCs and of the phone app if you turn them on. Without them, everything else still installs. |

Optional:

- **winget**, so the installer can add what the voice needs (Python for edge-tts, FFmpeg for `ffplay`). Without it, the voice uses the built-in Windows voice.
- **A bash statusline script and `jq`**, so the tray updates on every Claude Code response. Without them, the tray asks the usage endpoint instead (see [Usage tray](#usage-tray)).
- **Node.js**, for Environments (its Chrome extension and `env.js`).
- **Python 3** (`python3` on `PATH`), for Maxx Judge, and Python 3.11+ for the PDF plugin.

### Install

Run this in any PowerShell window on the PC. Nothing needs to be installed first.

```powershell
irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1 | iex
```

It downloads the [latest release](https://github.com/SantiagoRuizM/ClaudeMaxxing/releases/latest), verifies it against the release's SHA-256 and runs its `install.ps1`. If GitHub's API can't be reached (it allows 60 requests an hour per address) or the release has no SHA-256, it stops without installing anything. The unreleased `main` branch is installed only while the repo has no release at all, or with `-Ref main`.

To pass [options](#install-options):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1))) -SkipBridge
```

Other ways to install:

- **npx** (needs Node.js): `npx github:SantiagoRuizM/ClaudeMaxxing`. Options pass through, for example `-- -SkipBridge`. It installs `main` as it is, not the latest release, with no SHA-256 check.
- **By hand**: download and unzip the release ZIP (or clone the repo), then run this in that folder:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
  ```

### What happens on the first install

- Everything is copied to `%LOCALAPPDATA%\ClaudeMaxxing` and runs from there. You can move or delete the download afterwards.
- Windows shows **one UAC prompt** to trust a code-signing certificate the installer creates on your PC. It signs the package behind the Explorer menu entry, and its private key never leaves your PC. You don't need Visual Studio or the Windows SDK: the menu DLL and its package ship prebuilt in `menu/bin`.
- The tray starts right away and at every sign-in. The menu entry appears after you restart Explorer or sign out and back in.
- **Other PCs stays off** until you turn it on (**Turn on** in its window, or `install.ps1 -Bridge`). Turning it on downloads the portable [Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) release from GitHub (about 5 MB) and asks for a second UAC prompt for its firewall rules. The download is pinned: the zip must match a fixed SHA-256, and every program in it must be signed by Microsoft. An install where it was already set up keeps it.
- Nothing personal ships in the repo. Your environments, voices, keys, paired PCs and usage data are created on your PC by the installer and the tray, and are kept across updates.

### Tailscale, away from your Wi-Fi

Skip this if you only use the phone on the PC's Wi-Fi. Otherwise do it **before pairing**, because the QR carries the addresses the PC has at that moment.

1. On the PC, run this, or [download it](https://tailscale.com/download):

   ```powershell
   winget install --id Tailscale.Tailscale -e
   ```

2. On the phone, install Tailscale from Google Play.
3. Sign in on both with the same account, the one of whoever owns the PC and the phone.

If the phone was already paired, scan a new QR with **Add PC**: it replaces that PC in the app. Then, in **Phone** on the PC, **Revoke** the older of the phone's two entries.

### Install on the phone

Android 6 or later. In the business edition the phone app is off until the company's policy allows it.

1. On the phone, download **[ClaudeMaxxing.apk](https://github.com/SantiagoRuizM/ClaudeMaxxing/releases/latest/download/ClaudeMaxxing.apk)**, open it and allow installing from the browser.
2. On the PC, open **Phone** in the ClaudeMaxxing window, turn it on and accept the firewall prompt.
3. Press **Show the QR** (valid for 5 minutes). In the app, tap **Add PC** and scan it. The phone has to be on the PC's Wi-Fi, or both on Tailscale.

<details>
<summary><strong>Install or update the phone by USB</strong></summary>

Turn on **USB debugging** in the phone's Developer options, connect it and accept its prompt. `adb` comes with `winget install --id Google.PlatformTools -e` (open a new PowerShell window afterwards).

```powershell
curl.exe -fL -o "$env:TEMP\ClaudeMaxxing.apk" https://github.com/SantiagoRuizM/ClaudeMaxxing/releases/latest/download/ClaudeMaxxing.apk
adb install -r "$env:TEMP\ClaudeMaxxing.apk"
```

With several phones connected, `adb devices` lists them and `adb -s <serial> install -r ...` picks one. On a phone that isn't yours, revoke the USB debugging authorizations when you finish.

</details>

### Install options

| Option | Effect |
|---|---|
| `-InstallDir <path>` | Install somewhere other than `%LOCALAPPDATA%\ClaudeMaxxing` |
| `-SkipMenu` | Don't install or update the Explorer menu entry |
| `-SkipVoiceDeps` | Don't install edge-tts or FFmpeg (the voice uses the Windows voice) |
| `-NoHotkeys` | Don't enable the global voice hotkeys (Ctrl+Alt+Shift+O repeats, Ctrl+Alt+Shift+P stops) |
| `-NoStart` | Don't start the tray now (it still starts when you sign in) |
| `-BuildMenu` | Rebuild the menu DLL from source first (needs Visual Studio with C++) |
| `-Bridge` | Set up Other PCs now (it is off by default; **Turn on** in its window does the same later) |
| `-SkipBridge` | Never set up Other PCs, not even when an earlier install did (no OpenSSH download, no firewall rules, no `~/.ssh/config` change) |
| `-Business` / `-Personal` | The edition (also `--business` / `--personal`). Personal is the default, and the choice is kept for the next update. See [Business edition](#business-edition) |
| `-PolicyFile <json>` | Copy a company policy for this user (implies `-Business`) |

### Updating

Never uninstall to update. Updates keep your data, your settings, the edition and the paired phones.

Versions follow [Semantic Versioning](https://semver.org). What changed in each one is in [CHANGELOG.md](CHANGELOG.md), and what counts as a major, minor or patch version is in [VERSIONING.md](VERSIONING.md). The installed version shows in **Settings > Apps > ClaudeMaxxing**.

#### Update the PC

1. Click the notice of the new version, or right-click the jellyfish and choose **Install update...**. **Check for updates...** looks right away.
2. Confirm. It checks the download's SHA-256, installs over the old version and restarts the tray. Press Enter to close its window.
3. Reopen the sessions that were open, and reload the Chrome extension if you use it.

The business edition doesn't check by itself: IT chooses when, or use **Check for updates...**.

By hand, or from a version that has no **Check for updates...**, run the install command again:

```powershell
irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1 | iex
```

The button remembers what you installed without, the command doesn't: pass `-SkipMenu`, `-NoHotkeys`, `-SkipVoiceDeps` or `-InstallDir` again, or they go back to the default.

#### Update the phone

Tap **Download** on the app's notice, open the file and confirm: it installs over the old one and stays paired. Without a notice (an app from before it existed), [install the latest APK](#install-on-the-phone) over it, with no need to pair again.

The PC and the phone update separately.

#### Update another PC

Each PC updates on its own: do the same on each one, sitting at it. Updating closes that PC's Other PCs connections, so don't do it through one of them.

### Uninstalling

Use **Settings > Apps > ClaudeMaxxing**, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeMaxxing\uninstall.ps1"
```

This removes everything listed below, including the menu entry, its certificate and the Other PCs firewall rules (one UAC prompt for both). Background workers (a trial, a debate) are stopped first.

- Your data in `~/.claude/usage-tray`, `%TEMP%\claude-voice` and `%LOCALAPPDATA%\ClaudeJudge` is kept unless you pass `-RemoveData`, which also removes the installer's backups of your `settings.json` and statusline script, and the local report folder.
- `-KeepMenu` keeps the menu entry, which then opens a plain Windows Terminal.

#### Uninstall from the phone

1. In the app, tap the computer icon and **Forget this PC**, for each PC. If the PC was off, also **Revoke** the phone in **Phone** on that PC.
2. Uninstall ClaudeMaxxing like any app, or by USB with `adb uninstall com.claudemaxxing.claudemaxxing`. What the app kept on the phone goes with it.

<details>
<summary><strong>Everything the installer changes on your PC</strong></summary>

| Where | What |
|---|---|
| `%LOCALAPPDATA%\ClaudeMaxxing` | The runtime: tray, menu launcher, voice. Voice settings for this PC go in `voice\config.local.json`, edge-tts in `voice\venv` when it has to be installed, and PyMuPDF (about 250 MB) in `pdf\venv` |
| `%LOCALAPPDATA%\ClaudeCodeMenu` | The Explorer extension (DLL, stub, icons) |
| Packages | `ClaudeCode.ContextMenu`, a sparse package signed with this PC's `CN=ClaudeCodeMenu` certificate (CurrentUser\My, trusted in LocalMachine\TrustedPeople) |
| `HKCU\Software\ClaudeCodeMenu\Launcher` | The command the menu entry runs |
| Startup folder | `ClaudeMaxxing.lnk` (tray) and `ClaudeMaxxing atajos.lnk` (voice hotkeys) |
| Settings > Apps | A ClaudeMaxxing entry; uninstalling it there runs `uninstall.ps1` |
| `~/.claude/statusline-command.sh` | A block that saves `rate_limits` to `~/.claude/usage-tray/usage.json` and each session's model, effort, folder, context, cost and start to `~/.claude/usage-tray/status` (for the phone; a backup is kept) |
| `~/.claude/settings.json` (`env`) | `CLAUDE_CODE_PLUGIN_DIRS` lists the installed plugins (Peek, the theme, Maxx Whip, PDF), so every Claude Code session loads them, and `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` turns on plugin mods (early access in Claude Code). The rest of the file is left as it was, and a backup is kept the first time (`settings.json.bak-claudemaxxing`). Uninstalling removes the folders from the list and leaves the switch, which other plugins' mods may need |
| `~/.claude/settings.json` (`theme`) | Switched to the matching ClaudeMaxxing theme (`custom:maxx-theme:light` or `dark`), unless you use a custom theme of your own. Uninstalling gives back the exact theme you had |
| `~/.claude/settings.json`, `~/.claude/plugins` | Only if you turn on **Context saving (context-mode)**: Claude Code installs and enables that plugin for your user (`enabledPlugins`, `extraKnownMarketplaces`), so it applies to every session. Turning the switch off disables it; uninstalling ClaudeMaxxing leaves it installed (`claude plugin uninstall context-mode@context-mode`) |
| `%LOCALAPPDATA%\ClaudeMaxxing\ssh` | Other PCs, once turned on: the portable OpenSSH (`sshd`, `ssh`, `sftp`...) |
| Windows Defender Firewall | Other PCs, once turned on: two inbound rules in the `ClaudeMaxxing` group, TCP 41022 for that `sshd.exe` and UDP 41021 for PowerShell, **Private networks only, from the local subnet only** |
| `~/.ssh/config` | Other PCs, once turned on: a marked block at the top that includes `~/.claude/usage-tray/bridge/ssh_config` (a backup is kept the first time) |
| `%LOCALAPPDATA%\Programs\freellmapi-desktop`, `%APPDATA%\FreeLLMAPI` | Only if you press **Install** in the FreeLLMAPI card: that app and its data. It has its own entry in Settings > Apps, and uninstalling ClaudeMaxxing leaves it in place |
| `%LOCALAPPDATA%\ClaudeJudge` | Maxx Judge: every trial in `.court`, the logs in `logs`, the last status in `status.json`. Removed with `-RemoveData` |
| `~/.claude/usage-tray/edition.json`, `~/.claude/usage-tray/business` | The edition and, in the business edition, the user's policy, goals and seat calibration. `%ProgramData%\ClaudeMaxxing` (IT's policy and goals) is only read, never written |
| `~/.claude/usage-tray`, `%TEMP%\claude-voice` | Data: usage snapshots, sessions, logs, voice history, Other PCs keys and paired PCs (`bridge\`), Maxx Whisper's settings and call history (`whisper\`), and the statistics cache (`stats.json`, `stats-cache.json`) |

</details>

## Features

| | |
|---|---|
| **[Usage tray](#usage-tray)** | Your plan's 5-hour and weekly usage in the notification area, when each one resets, and a notification when either crosses 80 % and 95 %. |
| **[ClaudeMaxxing window](#the-claudemaxxing-window)** | One window with every tool's status and settings, in English or Spanish. |
| **[Explorer menu entry](#sessions-from-the-explorer-menu)** | Open Claude Code from any folder's right-click menu. Each session opens in its own slot (a whole screen, a half or a quarter) with its own color and name. |
| **[Usage planning](#planning-your-usage)** | Start a 5-hour window ahead of time, plan the week up to the weekly cutoff, or let the automatic schedule split your busiest hours across two windows. |
| **[Statistics](#statistics)** | When and how much you work with Claude Code, what each 5-hour window costs and a forecast for the open one. Computed on your PC. |
| **[Snip to Claude Code](#snip-to-claude-code)** | Win+Alt+C: a snipping tool (picture or video, draw, OCR) that hands the snip to a new session with your prompt. |
| **[Voice](#voice)** | Each session reads a one-line summary of every answer aloud, with its own voice and a short musical signature. |
| **[Peek](#peek)** | Every path Claude writes becomes a link: hover to preview it, click to show it in Explorer. |
| **[PDF as Markdown](#pdf-as-markdown)** | Claude reads PDFs as Markdown instead of page images, for a fraction of the tokens. |
| **[Maxx Judge](#plan-session-maxx-judge)** | Put the day's idea on trial before a jury of Claude agents before you spend the plan on it. |
| **[Environments](#environments)** | Work environments that close what doesn't belong and open what does, with focus tracking and a Chrome extension. |
| **[Maxx Whip](#maxx-whip)** | When the plan runs low, Claude stops writing code and directs another agent (Codex, Antigravity, OpenCode or Copilot) that does. |
| **[Other PCs](#other-pcs)** | Pair PCs on the same network to open terminals or Claude Code on each other, or let both Claudes debate a decision. Off until you turn it on. |
| **[Maxx Whisper](#maxx-whisper)** | A live copilot for calls: it transcribes, spots questions and suggests what to say. |
| **[Phone app](#phone-app)** | The ClaudeMaxxing panel on your Android phone: pair it with a QR, swipe through the sessions open on your PC and write to them. Off until you turn it on. |
| **[Skills & MCP](#skills--mcp-catalog)** | Every skill and MCP server, yours and a catalog of about 430 skills and 16 servers, in one searchable list with a switch each, always or per environment (an environment can load exactly its own list), and Anthropic's official packages to create your own. |
| **[Context saving](#context-saving) and [free models](#free-models-with-freellmapi)** | Optional add-ons that make the plan last longer. |

There are two editions, picked at install: **personal** (the default, everything above) and **[business](#business-edition)** (`-Business`): the same tools under a company policy, plus a Business section with the seat report, team reports, the company's goals and the team kit.

## Guide

### Usage tray

The tray icon shows your plan's usage. Left-click opens or closes the popup; right-click opens the menu. **Open ClaudeMaxxing**, at the bottom of the popup and first in the menu, opens [the ClaudeMaxxing window](#the-claudemaxxing-window).

- **Where the data comes from.** Claude Code's statusline receives `rate_limits` on every response. The block added to your statusline script saves them to `~/.claude/usage-tray/usage.json`, and the tray reads that file every 15 seconds. What your statusline shows doesn't change.
- **Live refresh.** The **↻** button asks the endpoint `/usage` uses (`api.anthropic.com/api/oauth/usage`, with Claude Code's local token). The tray also asks it on start, and when you open the popup with data older than 10 minutes. That endpoint is **undocumented**: if it changes, the popup shows the error and keeps the statusline data. Extra usage and an available limit reset show up as extra sections when the account has them.
- **Activity.** The green dot means a Claude Code session answered in the last 10 minutes, and each session opened from the menu gets a symbol in the tray (an egg, unless you pick another in **Settings**) that shows when it is working.

### The ClaudeMaxxing window

One window with every tool. It opens like a session, on the first half, quarter or screen no session holds (Claude Code > Per screen), and goes full screen with the maximize button or F11 (Esc or F11 leaves it). The side menu is grouped like this:

| Group | Section | What it has |
|---|---|---|
| | **Home** | Your account (name, plan, email, organization), session and weekly usage, the next scheduled session, a diagram of the PCs on your network, Maxx Whisper's latest calls, the open sessions, the voice switches, and shortcuts to the sections you open most. |
| | **Business** | Business edition only. See [Business edition](#business-edition). |
| Plan | **Plan session** | [Maxx Judge](#plan-session-maxx-judge). |
| | **Usage & schedule** | Both limits, the [automatic schedule](#automatic-schedule), the scheduled sessions (automatic ones marked AUTO), **Schedule session...** and **Weekly plan...**. |
| | **Statistics** | See [Statistics](#statistics). |
| Focus | **Environments** | See [Environments](#environments). |
| Sessions | **Claude Code** | The sessions opened from the menu (color, name, role, voice and slot), **Show** to bring one to the front, **New session...** in a folder you pick, **Per screen**, the screen order, whether the menu entry is installed, a link that explains Peek, and the [context-mode](#context-saving) and [FreeLLMAPI](#free-models-with-freellmapi) cards. |
| | **Maxx Whip** | See [Maxx Whip](#maxx-whip). |
| | **Skills & MCP** | One list of skills and one of MCP servers, with a switch each: the ones Claude Code loads (yours, your plugins', claude.ai's, your projects') and the [catalog's](#skills--mcp-catalog), with a search box. It also installs Anthropic's official packages to create them (skill-creator, mcp-server-dev, plugin-dev), each with a button that opens a Claude Code session that starts using it. |
| | **Voice** | Voice on or off for every session, the global hotkeys, **Test voice**, **Repeat the last one** and **Stop audio**, and the sessions that spoke in the last 12 hours, each with its own switch. |
| Connections | **Other PCs** | This PC's status, the **Accepts connections** switch and the paired PCs, with Terminal, Claude Code and **Disconnect**. Pairing happens in the Other PCs window (**Pair or find a PC...**), because pairing is only accepted while that window is open. |
| | **Maxx Whisper** | Open or show it, **Context...**, language, model, answer, microphone and call-notice options, the hotkeys, and the call history (click a call to open its Markdown file). While Whisper is open, its settings are read-only here. |
| | **Settings** | The **language** of the window, the tray and its notifications (English, the default, or Spanish), **Screenshots** (Snip on or off, and which hotkey it got), the **gender of the voices and names** for new sessions, and the **session symbol**, chosen on the PC or on the phone from a list that shows each one still and thinking: the taskbar, the strip and the phone change at once, each session already open keeps its own in its tab and statusline, and new sessions start with the one chosen. |

The language changes at once; Maxx Whisper and the other windows take it the next time they open. Numbers and dates follow it. The choice is saved in `~/.claude/usage-tray/language.json`.

### Sessions from the Explorer menu

Right-click a folder (or the empty space inside one) and choose **Abrir con Claude Code**. The entry's label is fixed in the menu DLL and is not translated yet.

- **Slots.** Each screen has 1, 2 or 4 slots (**Per screen** in the Claude Code section): the whole screen, its left and right halves, or its quarters. Each new session takes the first free slot, screens from left to right starting with the Windows primary or the one you choose. When all slots are taken, the tray says so and opens nothing, unless you turn the limit off: then new sessions open over the first ones.
- **Recommendation.** ClaudeMaxxing measures how much of the time your open sessions are working (kept for 30 days in `activity.json`) and, after an hour of sessions, recommends how many per screen. Agents that work half the time or more rarely wait for you, so 4 fit; ones that work under a fifth of the time mostly wait for you, so 1 shows more of each.
- **Identity.** Each slot has a color, which the tab and Claude Code's prompt box get (`/color`, sent as a local command, so no model call). Before Claude Code starts, the launcher reserves a name and a voice for the session and starts Claude Code with that `--session-id` and the voice plugin. On the first real prompt the name gets a role that describes the session's work.
- Only sessions opened from the menu, from **New session...** or from a snip take a slot.

### Planning your usage

The usage limit is per 5-hour window, and a window starts with the first message. Scheduling a tiny prompt (Haiku, "ok") starts the window, and resets it, earlier.

#### Schedule a session

**Schedule session...** in the tray menu or in Usage & schedule.

- **On this PC**: a one-off Task Scheduler task (`\ClaudeMaxxing\`). It wakes the PC from sleep if wake timers are enabled. It doesn't run if the PC is off or you are signed out.
- **In the cloud**: Claude Code creates a claude.ai routine with `/schedule`, without opening a window. This works with the PC off.

#### Weekly plan

The **Week** tab of the same dialog (also **Weekly plan...** in the tray menu) plans back-to-back 5-hour windows up to the weekly cutoff, so the weekly limit gets used before it resets.

- Choose how many sessions a day and when the first one starts; the windows follow 5 hours apart. The cutoff comes from the weekly usage data (without data, you pick the weekday and hour).
- Each day shows its window start times and the weekly usage to reach by the end of the day, and the summary gives the share of the weekly limit to spend per session. It is a target: nothing reports how much of the weekly limit one window uses.
- **Schedule plan** creates a task for every planned window that has nothing scheduled near it (those show a ✓). Settings are saved in `~/.claude/usage-tray/plan.json`.

#### Automatic schedule

When your busiest hours fall in the middle of one window, that single window carries all of that load and runs out. The **Automatic schedule** card in Usage & schedule places the windows so this doesn't happen:

1. From the last 30 days of statistics it computes your average time with Claude for each hour of the day and finds the **2-hour stretch with the most use**, for example 14:00–16:00.
2. The middle of that stretch becomes a **change between windows** (15:05 in the example), so the busiest part of the day is split between two windows' limits.
3. From there it chains windows 5 hours apart across your active day (from the end of your longest quiet stretch, usually the night, to its start): 05:05, 10:05, 15:05 and 20:05 in the example. Each start is at :05 so the previous window has reset.

- When it is on, the tray keeps one-off `Auto-…` tasks for the next 2 days, checks every hour and recomputes from fresh statistics at least once a day. Turning it off removes them.
- The card shows the hourly profile with the planned windows under it, the session times, the change hour (move it with ‹ ›, or **auto** to go back to the computed one) and whether today's window follows the plan.
- Tasks scheduled by hand over the next 2 weeks that would open a window off the plan are listed. **Clear** removes exactly those, only when you click it and confirm. Hand-made tasks within 30 minutes of a planned start fit the chain and are kept.
- A window only starts when none is running. If you start one at another time, the chain picks up again at the next planned start after it ends.

#### Plan session (Maxx Judge)

**Plan session** (also **Plan session...** in the tray menu) puts what you plan to do today on trial before **Maxx Judge**, the [court skill](https://github.com/alexyc9381/court-skill) (MIT, by Alex Chen), before you spend the plan on it.

- **New idea** opens a box to write the idea (6 jurors, or 12 with the full trial). A hidden `claude -p` (Sonnet, your plan) runs the trial: a prosecutor, a defense, their rebuttals, the jury voting alone and a judge. It takes about 6 minutes for 3 jurors (measured), so roughly 10 for 6 and 15 for 12, and keeps going if you close the window.
- **Earlier ideas** lists the ideas already judged with their verdict. Click one to read every juror's vote and what would flip it, and the judge's charges, strengths and conditions for acquittal. **Judge again with changes...** retries with the idea edited.
- Trials are kept in `%LOCALAPPDATA%\ClaudeJudge\.court`, not under `~/.claude` (Claude Code refuses to write inside a `.claude` folder even with accept-edits). Each trial leaves a log in `%LOCALAPPDATA%\ClaudeJudge\logs`. When a trial fails, the section says why and **View log** opens that log. A trial stops after 60 minutes.
- Two local changes to the skill: `python3 -X utf8` (Windows reads files as cp1252) and sub-agents write in the language of the idea.

### Statistics

When and how much you work with Claude Code, for the last 30 days or for all time. The data comes from Claude Code's own transcripts in `~/.claude/projects` and never leaves your PC.

| Tab | What it shows |
|---|---|
| **Summary** | Hours with Claude, active days, streak, prompts, replies, sessions and subagents, the average per active day, this week against the last one, how many sessions you run at once, tool uses, your peak hour and weekday, and hours per day. |
| **Usage** | What each 5-hour window spends and a forecast for the open one (details below). |
| **Hours** | A weekday × hour heatmap, hours by hour of the day, and the share of early morning, morning, afternoon and night. |
| **Projects** | Time, prompts and sessions per folder, plus the average, median and longest session. |
| **Models and tools** | Replies and output tokens per model, total tokens and the cache share, the tools Claude used most, and counts from the other tools (Whisper calls, scheduled sessions, sessions opened from the menu, paired PCs). |

**Usage** prices the tokens of every reply (subagents included) at API rates, with the pricing table of the installed [Ponytail](https://github.com/DietrichGebert/ponytail) plugin, or the same table built in when Ponytail isn't there. Cost follows the plan's limits better than raw tokens: a cache read costs a tenth of an input token, and Opus costs several times Haiku.

- The open window's spend and its **forecast at the end**, from the pace of the last hour and what you usually spend at those hours. With the tray's percentage it is calibrated against your real limit: what 1 % of your window is worth, the percent the window will close at, and when you would hit the limit.
- The average and median window, how much windows differ from one another, and the last 20 windows as bars.
- The average cost of each hour of the day, with the peak hour.

Hover over a bar or a cell to read its value. Time is active time: the gaps between events of a session that are under 15 minutes. Parallel sessions are counted once in "hours with Claude". The first scan reads every transcript in the background; after that only changed files are read again (`stats-cache.json`). Claude Code deletes transcripts older than 30 days, but the cache keeps their summaries, so all-time statistics keep growing from the first scan on.

### Snip to Claude Code

**Win+Alt+C** is a snipping tool like the one in Windows, built to hand what you snip to Claude Code. The screen freezes under a dark veil and a toolbar appears at the top of the screen with the pointer:

| Tool | What it does |
|---|---|
| Snip / Record video | A picture, or a video of the area you choose. |
| Shape | **Rectangle** (drag), **Window** (the window under the pointer lights up; a click takes the window itself, whole even where others cover it), **Full screen** (the screen with the pointer) or **Freeform** (outside the outline the PNG is transparent). Video: rectangle, window or full screen. |
| Draw | A pen in five colors and three widths, a **highlighter**, **undo** (Ctrl+Z) and **clear**. What you draw goes into the snip. |
| Color picker | A magnifier with the color's code; a click copies it as `#RRGGBB`. |
| Extract text | Drag over text: the Windows OCR reads it, in your profile's languages, and copies it to the clipboard. |

- **Pictures** are copied to the clipboard and saved in `Pictures\Screenshots`, like Windows does. A panel opens next to the snip with the prompt, **Send**, the folder list, **Copy** and **Save as…**. **Enter** (or **Send**) opens a session in that folder, in the next free slot, with the prompt and the image's path. **Esc** leaves.
- **Videos** show a frame and a bar with the **microphone** and **system audio** switches, **Start** (a 3, 2, 1 countdown), **Pause**, **Stop** and **Discard**. They are recorded with Media Foundation (H.264 at 24 fps with the pointer, AAC from the speakers and the microphone) to `Videos\Screen Recordings`. Claude reads images, not video, so the prompt carries the video's path and a frame every 2 seconds (up to 8).
- **After a Win+Shift+S snip**, the same panel appears in the bottom right corner. Win+Shift+S itself is not changed: the tray only reacts to images from the Snipping Tool, never to an image copied in another app.
- **The folder** starts on the one of the environment that is on, and the list also has the open sessions' folders, the last 5 you used, Desktop, Documents, Downloads and **Another folder…**.
- Snips are kept in `%LOCALAPPDATA%\ClaudeMaxxing\snips` for 7 days. Everything works in real pixels, so screens at other scales snip right too. If another app already holds Win+Alt+C, the tray takes **Win+Shift+X**, else **Ctrl+Alt+C**; **Settings > Screenshots** shows which one it got and turns the feature off.

### Voice

Each session opened from the menu reads a one-line summary of every answer aloud, with its own voice and a short musical signature. Engines: Edge neural voices (the default, Latin American Spanish voices), ElevenLabs and Gemini with automatic fallback, or the built-in Windows voice. The voice stays quiet while Maxx Whisper listens, and says when the plan ran out and when it comes back. Full documentation in [`voice/README.md`](voice/README.md) (in Spanish).

### Peek

In every Claude Code session, each path Claude writes (Windows or Linux, with or without backticks, spaces included) becomes a link. Hover it to preview an image, a video's frame, a PDF's first page, an audio file's length, a folder, or the first lines of code or text. A path with a line range, `src/app.ts[12:20]`, previews only those lines. Click it to show it in Explorer: programs and scripts are shown, never run. Each reply ends with its references, every path it named. See [`peek/README.md`](peek/README.md) (in Spanish).

### PDF as Markdown

Every session loads the `pdf` plugin. Its `pdf-markdown` skill has Claude turn a PDF into Markdown (text, headings, tables, page markers) with [PyMuPDF4LLM](https://github.com/pymupdf/pymupdf4llm) instead of loading its pages as images, which costs many times more tokens: a 10-page manual is about 2,000 tokens. Pages with no text (a scan) and figures are still read as images. PyMuPDF (AGPL-3.0) is downloaded from PyPI on your PC into its own environment (`pdf\venv`, about 250 MB) and is never copied into this repo.

### Environments

An environment says what to close and what to open to work on one thing. For example, a *Work* environment closes unrelated tabs and apps, starts Docker and the dev servers, and opens the project's tabs and music. It is built on `harness\` (a Chrome extension plus `env.js`, formerly the separate YourHarness project); see [`harness/README.md`](harness/README.md) (in Spanish).

- **Map tab.** A graph of your environments. Click a dot to turn it on or off. Each arrow is a switch you have made, with how many times, and each dot shows the time spent there today and in total. Only one change runs at a time: turning one on closes what doesn't belong (each close with its reason, and time to close before anything is forced), and turning it off closes only its own things.
- **Focus & settings tab.** **Focus drift** lists the open tabs the environment would close (close one, or all with **Close all**; Ctrl+Shift+T brings them back) and the apps that don't fit. **Servers** lists the dev servers listening, with **Turn off**, which stops that process tree only if it still listens on that port. **Switch notice** sets the detection, and **Environment stats** shows the time per environment and your average focus span. **Check now** runs a detection.
- **Skills & MCP tab.** A card per environment with a folder (`claude.dir` or else `folder`) with the skills and MCP servers its sessions load there. **Edit list** opens Skills & MCP on that environment: its first change gives it its own list, and from then on its folder loads exactly that list and nothing else (see [Skills & MCP catalog](#skills--mcp-catalog)).
- **Getting started.** A new install has no environments. The section shows a prompt to paste into Claude Code: Claude reads your usage, projects and sessions, proposes environments, asks what it can't tell, writes each `.json` and checks it with a preview that closes nothing. **Create with Claude** copies the same prompt later.
- **Where they live.** Your environments are this PC's, never in the repo: `~/.claude/usage-tray/harness/environments/*.json` (**Open folder** opens it), with the state in `run\` and the Jev key in `.env` next to them.
- **The Chrome extension** shows a badge with how many tabs the environment would close, a small bar when you load something off focus, and a popup with the plan's usage, the environment that is on and a switcher. `install.ps1` registers its native host (needs Node.js); load it once per Chrome profile from `chrome://extensions` > Developer mode > **Load unpacked** > `%LOCALAPPDATA%\ClaudeMaxxing\harness\extension`.
- **Detection** is off until you turn it on in **Switch notice**, and never runs without environments. Every 3 minutes the tray compares what is open with each environment and, only when that changed, asks `claude -p` (Haiku, your plan). **Judge: Jev** asks Jev first (TypeSafe's decision model, needs `TYPESAFE_API_KEY` in `.env`). When the answer is another environment with 60 % confidence or more, a message box asks whether to switch; **No** is remembered until what is open changes. Tab titles are sent to TypeSafe or Anthropic for that question.

### Maxx Whip

When the plan runs low, Claude Code stops writing code itself and directs another agent that does. Each agent spends its own quota, not your Claude plan.

- **Setup.** The Maxx Whip section has a switch, the threshold (70 % to 95 %, or always) and the agents you have installed: Codex, Antigravity CLI (`agy`), OpenCode and Copilot CLI, each with its account, plan and renewal date.
- **When it acts.** At the threshold. With **Before the threshold, if it will run out** on (off by default), also earlier when the open 5-hour window is past half and on pace to run out before it resets; the tray recomputes that forecast every 5 minutes, and the session says when the limit would come.
- **What it does.** In every session, including open ones, Claude can no longer edit, write, start subagents or run shell commands other than git, read-only ones, the agents and the check. Claude plans and writes the task, an agent writes the code (`whip\bin\whip-run.sh`), and Claude reviews git, runs the tests (`whip-check.sh`) and sends back what failed, for at most 3 rounds.
- **What it is not.** The shell rule is a guard on your plan, not a sandbox, and most agents run without one (see [Privacy, risks and permissions](#privacy-risks-and-permissions)).

### Other PCs

For two or more PCs on the same network that both run ClaudeMaxxing. Typical use: Claude Code on this PC needs a file or a command result from the other one, or you want a second Claude Code working there. Off until you turn it on.

**Pairing (once per pair of PCs).** Open **Other PCs...** from the tray menu on both PCs. Each one lists the other under *On your network*. Click **Pair** on one of them; both windows show the same 6-digit code. Check that it matches and confirm on both. If a PC doesn't show up (some routers isolate Wi-Fi clients), type its IP address at the bottom.

**Using it.**

- From the tray menu, **Other PCs > Terminal on \<PC\>** opens a PowerShell on the other PC in Windows Terminal, and **Claude Code on \<PC\>** opens Claude Code there. From any terminal, or from Claude Code itself, `ssh cmx-<pc> "<command>"`, `scp` and `sftp` work too.
- The other PC shows an **Incoming connection** dialog with the PC, the user and what it wants to do. The options are **Allow**, **Allow 1 hour** (no more questions from that PC for an hour) or **Reject**. With no answer within 60 seconds, the connection is refused.
- That PC is notified when a terminal opens and closes there. **Other PCs > Disconnect** ends a session, and **Accepts connections** turns incoming connections off.

<details>
<summary><strong>How it is kept safe</strong></summary>

An allowed connection gets a shell as that PC's Windows user. The design is about who can ask, what the person at the other PC sees before saying yes, and what keeps working when something fails.

- **Who can log in.** Each PC runs its own `sshd` as the signed-in user, started by the tray, with no Windows service and no admin rights. Only that same user can log in: a paired key asking for Administrator, SYSTEM or any other account is refused. There are no passwords (`AuthenticationMethods publickey`), and only keys exchanged by pairing are accepted.
- **Pairing.** It swaps ed25519 keys, and both screens show a 6-digit code computed from both PCs' keys and two random values. One PC commits to its value before it sees the other's, so a machine in the middle can't make both screens show the same code. A PC only answers pairing requests while its Other PCs window is open, and only for the first 10 minutes. Host keys are pinned, so a PC that changes address is still recognized and an impostor is refused.
- **Every connection is approved.**
  - Every paired key is forced through a gate program (`restrict`, `command=`, no port, agent or X11 forwarding, LAN source addresses only).
  - The gate asks the tray before running anything, and lets nobody in when the tray is not running, not even a PC allowed for an hour.
  - The dialog shows one request at a time, and its answer applies only to that request. Requests already waiting are still asked one by one after **Allow 1 hour**.
  - Commands are shown in full: line breaks and invisible characters are made visible, and padding that could push the dangerous part out of view is collapsed. A command too long to show whole can only be refused.
  - The buttons stay disabled for 1.5 seconds after a request appears, so a click meant for another window can't allow it. Tab and Enter do nothing in that dialog, and Esc rejects.
  - **Allow 1 hour** is capped at an hour, and the gate refuses longer grants.
- **Tampering.** `authorized_keys`, `sshd_config`, the gate and its settings are checked every 5 seconds against what the tray wrote. Anything changed from outside is put back and reported.
- **Network.** The firewall rules open the two ports only on networks Windows marks **Private**, and only to the local subnet. The server and discovery listen only on this PC's Private address; on public Wi-Fi nothing listens and nothing is announced. Discovery messages (UDP 41021) carry only the PC name, user name and port, and are size- and rate-limited.
- **Your own `~/.ssh/config`.** The `cmx-*` hosts turn off agent and X11 forwarding, proxies, local commands and host-key updates, so a `Host *` entry of yours can't hand anything of this PC to the other one.
- **OpenSSH.** The official Win32-OpenSSH release, pinned by SHA-256, with every program checked for Microsoft's signature.

**What it can't protect against.**

- **An allowed connection has your rights.** It can read your files, including Claude Code's login in `~/.claude`, install programs or change ClaudeMaxxing itself. Allow only your own PCs and connections you expect, and use **Allow 1 hour** only while you are working with that PC.
- **A compromised paired PC** can ask for connections. Each request still needs your approval unless an hour grant is active. **Forget** removes that PC's key at once.
- **Programs already running as you** can change the files in `%LOCALAPPDATA%\ClaudeMaxxing` and `~/.claude/usage-tray`, including `sshd.exe`, which the firewall rule trusts. That is true of every program you run.
- **Who is on your network.** Your PC name and user name are announced to the local network every 30 seconds, on Private networks only. Mark a network Private only if you trust who is on it.

**Limits.** Both PCs need ClaudeMaxxing, with the tray running and the user signed in. Logins are only as that PC's own Windows user. **Forget** removes the PC only on the PC where you click it. Each PC uses its own Claude plan.

</details>

#### Debates

When you and the person at a paired PC are deciding something (an implementation, a fix, a design), **Debate with \<PC\>...** in the tray menu puts the question to both Claudes. Each one argues from its own person's project, which the other side can't see, and you both get one recommendation.

- **Starting.** Write the question with what matters (options, limits, deadlines) and pick the project folder your Claude may read. The other PC shows an incoming connection with the topic; **Allow** asks that person for their folder. An hour grant never opens a debate.
- **Rounds.** Round 1 is written blind, so neither side anchors on the other. Rounds 2 and 3 are replies, and a point may only be conceded by naming the evidence that changed it. Then a moderator on your PC, with only the transcript and no files, writes the agreements, the disagreements, a recommendation, questions for both of you and a rating of the debate. The Claudes recommend; you decide.
- **Live.** A terminal on each PC shows the debate as it goes. The transcript stays in `~/.claude/usage-tray/bridge/debates/<id>/transcript.md`, with each call's prompt and answer. Debate folders are deleted after 30 days.
- **Cost.** It runs on Sonnet: four calls on your plan (three turns and the moderator) and three on theirs.
- **Only text crosses.** Each message is a JSON of at most 16 KB that the other PC's gate drops in that debate's folder; it runs nothing. Each turn is `claude -p --restricted` with only Read, Glob and Grep, confined to the folder you picked: no shell, no web, no MCP servers, and `.env*`, `*.pem`, `*.key` and SSH keys can't be read. A drive root or your whole user folder is refused as the folder. Before sending, each turn is scanned for API keys, JWTs, private keys and passwords, which are masked. The other side's words reach your Claude as data, between tags it is told not to obey.

### Maxx Whisper

A live copilot for calls: job interviews, meetings, sales calls. Open **Maxx Whisper** from the tray menu and press **Listen** when the call starts. The window stays on top of the call app.

- **Transcript.** Everything the PC plays shows as **Them** (the other side in any app: Teams, Zoom, Meet in a browser... but also videos and music), and your microphone shows as **You**. Words appear as they are spoken, in whatever language is being spoken.
- **Answers.** When a question is heard, Claude writes what you could say: one or two sentences, then a few short points, in the language of the question, with a translation into your language when it differs. It uses what you put in **Context** (your CV, the conversation's goal, your instructions) and never makes up experience: where a detail is missing it leaves a gap like `[years]`. Earlier answers stay one click away (‹ ›).
- **Live translation** translates every line in another language under it. **Answer automatically** and **Live translation** are the two switches under the buttons.
- **Controls.** **Answer** (Ctrl+Alt+Shift+R) asks for an answer now, **Screen** (Ctrl+Alt+Shift+C) sends the monitor under the mouse to Claude (to solve an exercise on screen, for example), and the box at the bottom asks Claude anything without saying it in the call. Ctrl+Alt+Shift+W hides or shows the window. The keys can be changed in `~/.claude/usage-tray/whisper/settings.json`.
- **History.** Every call is saved as Markdown in `~/.claude/usage-tray/whisper/sessions` (**⋯ > Call history**). Calls older than 30 days are deleted (`keepDays`; `0` keeps them all).
- **Calls starting.** Once you have used it, the tray shows a notice when a call app starts using the microphone.
- **Without headphones** the microphone also hears the speakers. While the PC is talking your mic is muted for the transcript, and lines that repeat what was just said are dropped. Headphones work best.

<details>
<summary><strong>How it works</strong></summary>

- Audio is captured with WASAPI (the speakers in loopback, and the microphone), converted to 16 kHz mono and streamed to the speech-to-text service that Claude Code's own voice dictation uses, signed in with Claude Code's login from `~/.claude/.credentials.json`. That service keeps one growing transcript per connection, so Whisper cuts it into lines itself and replaces the connection every minute or so, at a pause.
- Answers come from a single `claude -p` that stays open for the whole call (stream-json in and out), so Claude keeps the conversation and every answer skips the start-up time. It runs with no tools, no CLAUDE.md, hooks, plugins or MCP servers, and none of your Claude Code settings. API key variables are removed from its environment, so it always uses your subscription.
- Translation and question detection come from a second, light `claude -p` on Haiku that gets every finished line and returns its translation and whether it asks something.
- Everything is plain PowerShell and C# compiled on the first run (`lib/whisper.cs`); nothing else is installed.

</details>

**Things to know.**

- **The speech-to-text service is not a public API.** It is what Claude Code's `/voice` dictation calls, used here for longer stretches than dictation. It is undocumented and could change, be limited or stop working. Before the first listen, Whisper explains this and asks you to accept it.
- **Every answer uses your plan**, and so does each Haiku batch for translation and detection. Turn off **Live translation** and **Answer automatically** to spend nothing until you press **Answer**.
- **The call is sent to Anthropic**, under your Claude account. In many countries the other side has to know and agree; follow the rules that apply where you are.
- **It doesn't hide.** The window shows in screen sharing and in the taskbar like any other, on purpose.

### Phone app

The ClaudeMaxxing app for Android shows the panel of the ClaudeMaxxing window and the Claude Code sessions open on your PC. Off until you turn it on.

**Setting it up.** [Install on the phone](#install-on-the-phone) has the steps, [Tailscale](#tailscale-away-from-your-wi-fi) is for using it away from your Wi-Fi, and [Update the phone](#update-the-phone) is for new versions.

**Using it.**

- The first page is the panel: your account, the plan, the open sessions and every section of the window's side menu, with the same switches and choices. Buttons marked *on the PC* open something on the PC.
- Swipe sideways to go through the open sessions, one page each, with the session's color. Each page shows the conversation as it happens and has a box to write to the session.
- Attach photos, documents and audio to a session (the PC keeps them in ~/.claude/usage-tray/mobile/uploads and sends their path), dictate a voice note, and keep the sessions' symbols in the notification shade, moving and speaking as in the tray. The symbol is the PC's: change it in **Settings** on either side and both follow. The small status-bar icon is built into the APK, so a symbol newer than the app shows the app's mark there.
- **Calls**: the phone icon in a session's page starts a hands-free call that goes on with the phone locked. Talk and stay quiet for a few seconds to send. For a change Claude checks first and says a proposal: two taps on the headphones (play/pause) accept it, three (next) answer, previous repeats it. A question opens the microphone by itself, and a chime comes before each answer. A phone call pauses it. Hang up from the screen or the notification; it also ends after 4 hours or if the session closes. A tap never approves a permission prompt, those stay on the PC, and the proposal-first rule is an instruction to Claude, not a block: the session's own permission mode still decides what can run. Dictation and voice are Android's own, so what you say goes to the phone's speech service (usually Google's).
- **Voice notes**: what each session's voice says arrives on the phone as a voice note in its chat, as in WhatsApp: play and pause, drag the bar, 1×, 1.5× or 2×, and what it said underneath. The phone downloads each one as soon as the PC has it, whichever page is open, and keeps it. The headphones icon lists them all, newest first, also after their session closed; a long press deletes one from the phone. The PC keeps only its last 100 (`historySize` in the voice settings), so a phone away for longer misses the older ones. Lines read by Windows' own voice (SAPI, when no engine made an mp3) have no audio to send.
- Under each session's name, its status line as on the PC: the folder, the branch (and the worktree when it is in one) and the environment on, then the model with its effort in subtle italics, the context used, the cost and how long it has run.
- One app can hold several PCs: switch between them with the computer icon.
- **Phone** lists the paired phones, with the last time each one connected. **Revoke** cuts one off.

<details>
<summary><strong>How it works and what it can't do</strong></summary>

- The phone talks only to your PC: HTTPS on port 47830, with a self-signed certificate whose SHA-256 the QR carries, so the app rejects any other server. There is no relay. The firewall rule covers Private networks, from the local subnet or Tailscale (100.64.0.0/10), and the server refuses any other address.
- Pairing gives the phone a random token. The PC keeps only its hash (`~/.claude/usage-tray/mobile/devices.json`) and the phone keeps it in the Android Keystore. A pairing code works once and 5 wrong tries end it.
- The panel is described by the PC, already in the language chosen there: the app only draws it. A switch or a choice sends back the id of an action the PC registered for it, never a command.
- Writing to a session goes through Claude Code's cross-session messaging (a named pipe per session, Claude Code 2.1.234 or later). Claude Code delivers your text as a message from another session: Claude follows it, but it can't approve a permission prompt, which stays on the PC. Only sessions opened from the Explorer menu take messages, because the voice plugin records each one's inbox when it starts.
- Not included yet: iPhone (the Flutter code would build there, but it needs a Mac).
- The APKs in the Releases are signed with the project's release key, so each one installs over the one before. One signed with another key (a debug build, for example) can only be installed after uninstalling the app, and then the phone has to be paired again.

</details>

### Context saving

The **Context saving (context-mode)** switch in the Claude Code section installs or turns on [context-mode](https://github.com/mksglu/context-mode) (Elastic License 2.0) as a Claude Code plugin, from its own marketplace. It keeps big tool outputs (logs, web pages, JSON) out of the context window and keeps the session's memory across compactions, so the plan lasts longer. It applies to new sessions. Its optional statusline is not installed, because the statusline is what feeds the usage tray.

### Free models with FreeLLMAPI

[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) is a third-party local server (MIT) that pools the free tiers of many providers (Groq, Google, Mistral, OpenRouter, Cerebras…) behind one endpoint that speaks Anthropic's Messages API. The **Free models with FreeLLMAPI** card in the Claude Code section handles it:

1. **Install** asks first, then downloads a pinned version of the official Windows app, checks a fixed SHA-512 and installs it per user with no admin rights. `install.ps1` never downloads it.
2. In FreeLLMAPI's own window, create the account and add provider keys. Copy the unified key (`freellmapi-…`) and press **Paste key**; ClaudeMaxxing checks it against `/v1/models`.
3. The switch makes **new** sessions talk to FreeLLMAPI, by setting `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and an empty `ANTHROPIC_API_KEY` for that window only. If FreeLLMAPI can't be reached, the session opens on your plan and says so.

Nothing global changes: `~/.claude/settings.json`, scheduled sessions, open sessions and Other PCs keep using your plan. Quality and speed depend on the free model the router picks, and some providers' free tiers may use your prompts for training.

### Skills & MCP catalog

Skills & MCP has two tabs, **Skills** and **MCP**, each one list: what Claude Code already loads (yours, your plugins', claude.ai's, your projects') and the third-party skills and servers that come with ClaudeMaxxing, which are **all off** (a skill costs context in every session only once it is on; an MCP server costs more). Being installed or in the catalog only changes whether its switch starts on. Each switch acts in the place picked in **Turn on in**: **Always** (every session) or one of your [environments](#environments) (only the sessions in its folder, `claude.dir` or else `folder`). **Source** filters (what is on there, installed, or one repo) and the search box filters as you type (Esc clears it). New sessions pick the change up.

- **Always.** A catalog skill is copied to `~/.claude/skills` and a catalog server added with `claude mcp add -s user`. A skill of yours (or of a plugin, or claude.ai's) is switched off with `skillOverrides` in `~/.claude/settings.json`, the setting `/skills` uses. One of your user-scope servers switched off is kept in `~/.claude/usage-tray/catalog-stash.json` (with its env and headers) and removed with `claude mcp remove`; from then on it is switched like a catalog server. A plugin's server has no switch here: it goes with its plugin, and can be off in an environment.
- **An environment.** Until you change something there, it loads what Always does. Its first change gives it its own list, starting from what it had: its folder then loads exactly that list. `<folder>\.claude\settings.local.json` gets `skillOverrides` (every other skill off, the listed ones on even if off in Always) and `deniedMcpServers` (every other server blocked); catalog skills are copied to `<folder>\.claude\skills` and servers added with `claude mcp add -s local`, all of it listed in that repo's `.git/info/exclude`. A skill or plugin installed later is off there too (the list is brought up to date each time Skills & MCP reads it). `catalog-overrides.json` records the entries ClaudeMaxxing wrote, the only ones it ever changes.
- **What is never touched.** Switching off deletes only the copies ClaudeMaxxing made (they carry a `.maxx-catalog` marker) and removes only the servers it added, so a skill or server of yours with the same name stays. An MCP server marked *sign in with /mcp* asks for its OAuth login the first time. claude.ai's connectors live in your account, not on disk: they are not listed.

The skills are copied as text from these repos, at a pinned commit, by `toolsendor-catalog.ps1` (`catalog\sources.json` lists each commit and every skill left out, with the reason):

| Source | License | What comes in |
|---|---|---|
| [anthropics/skills](https://github.com/anthropics/skills) | Apache-2.0 | The skills with no scripts (frontend-design, canvas-design, doc-coauthoring, theme-factory...) |
| [obra/superpowers](https://github.com/obra/superpowers) | MIT | The skills with no scripts (test-driven-development, writing-plans...), without its SessionStart hook |
| [wshobson/agents](https://github.com/wshobson/agents) | MIT | About 170 skills: languages, infrastructure, security, data, LLM apps |
| [affaan-m/ECC](https://github.com/affaan-m/ECC) | MIT | About 240 skills. Not the ECC plugin itself, whose 28 hooks run on every tool call |

A skill is left out if it ships any script, grants tools (`allowed-tools`), registers hooks, posts or acts on your accounts, needs a paid third-party API, promotes a sponsor or only works with its own plugin. The MCP servers (`catalog\mcp.json`) are the vendors' official ones: documentation with no login (Context7, Microsoft Learn, AWS Knowledge, Cloudflare Docs), services with OAuth (Linear, Notion, Atlassian, Sentry, GitLab, Vercel, Supabase, Stripe, Figma) and three local ones run with `npx` at a pinned version (Playwright, Memory, Sequential Thinking).

## Privacy, risks and permissions

What each module lets in or sends out:

| Module | What to know |
|---|---|
| Maxx Whip | Antigravity runs with `--dangerously-skip-permissions`, Copilot with `--allow-all-tools` and OpenCode with `--auto`: they can run any command as you, so a prompt injection in the repo reaches your PC. Only Codex runs in a sandbox (`workspace-write`). Enable only the agents you trust with the repo |
| Other PCs | An allowed connection is a shell as your Windows user. **Allow 1 hour** lets that PC run commands with no question for an hour, including ones a Claude Code on that PC decides to run |
| Phone app | A paired phone reads your sessions' conversations, changes the settings the window has and writes to the sessions, from your network or Tailscale. It cannot approve a permission. Revoke a lost phone in **Phone** |
| Environments | The Chrome extension reads every tab of the profiles where you load it. Detection, off by default, sends tab titles to TypeSafe (Jev) or Anthropic (Haiku, your plan) |
| Maxx Whisper | The call's audio, both sides, goes to Anthropic through an undocumented service; you are asked once before the first listen |
| Voice | The Edge voice (the default) sends each spoken summary to Microsoft; ElevenLabs and Gemini send it to them. The Windows voice stays on the PC |
| FreeLLMAPI | The prompts of the sessions it serves go to free third-party providers, some of which train on them |
| Skills & MCP catalog | A skill is instructions Claude follows: the catalog's were checked when copied (text only, no scripts, hooks or tool grants) but are third-party. An MCP server you switch on reaches that vendor with your login; the local ones download their npm package the first time |
| Updates | The tray (personal edition) and the phone app ask GitHub for the latest release on start and every 6 hours. GitHub sees your IP address; nothing else is sent |
| Keys | The ElevenLabs, Gemini and FreeLLMAPI keys are stored encrypted for your Windows user (DPAPI). The Jev key in `harness\.env` is plain text (Node reads it) |

Statistics, transcripts and usage data are read and kept on your PC.

## Business edition

For a company whose people use Claude Code on Team or Enterprise seats. Install it with:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1))) -Business -PolicyFile \\files\claude\policy.json
```

`npx github:SantiagoRuizM/ClaudeMaxxing --business` and `install.ps1 -Business` work too. Updates keep the edition; `-Personal` switches back.

### The policy

A JSON file; [`business/policy.example.json`](business/policy.example.json) has every field.

| Field | Meaning |
|---|---|
| `company` | The name shown in the Business section |
| `disabled` | Modules turned off: `freellm`, `bridge` (Other PCs), `whisper`, `whip`, `ambientes` (Environments), `judge` (Maxx Judge). Default: all but `judge`, because FreeLLMAPI sends prompts to free third-party providers, Other PCs gives a shell over SSH, Maxx Whisper sends calls to an undocumented service, Maxx Whip hands the code to other companies' agents and Environments reads every Chrome tab. `[]` allows all. A change applies within 5 minutes with the tray running |
| `seatName`, `seatMonthlyUsd` | The seat and what it costs per month, for the return on it |
| `reportDir` | A folder the team shares (`\\server\share\...`, environment variables allowed) for the reports. Empty: `Documents\ClaudeMaxxing\informes` |
| `autoReport` | `true` sends the report there every 7 days, without asking |
| `reportPresence` | `true` leaves a small file per person in `reportDir\presence` every 5 minutes (open sessions and the current window's use), so the Business section shows who is connected. Default `false` |
| `reportProjects` | `false` leaves project names out of the report |
| `marketplaces`, `plugins` | The team kit: plugin marketplaces (`owner/repo` or an `https` URL) and plugins (`name@marketplace`) |

The policy is read from `%ProgramData%\ClaudeMaxxing\policy.json` when IT puts one there (it then wins, makes the PC business whatever the flag says, and only an administrator can change it), else from the user's `~/.claude/usage-tray/business/policy.json` (what `-PolicyFile` copies, or **Policy** in the Business section creates). A damaged file falls back to the defaults. A module that is off disappears from the tray menu and the window, and does not start.

### The Business section

- **The seat**: hours in the last 30 days, the API-equivalent cost, the return on the seat (that cost over `seatMonthlyUsd`), and whether the seat **falls short**, **fits** or **has room**. It falls short when a quarter or more of the last 30 windows reach 90 % of the plan, or the weekly limit reaches 95 %, and it has room when 9 of 10 windows use under 35 %. Until the open window reaches 10 %, it says **Not calibrated**.
- **Reports**: **Export my report** writes `<date>_<PC>_<user>.json` (hours, active days, prompts, sessions, cost, seat, return, the recommendation and the top 10 projects; never prompts or paths) to `reportDir`, after asking when that is a shared folder. **Team report** reads everyone's newest report and opens a CSV in Excel, one row per person.
- **Company goals**: a Markdown file, IT's `%ProgramData%\ClaudeMaxxing\objetivos.md` or the user's `business\objetivos.md` (**Edit** creates it from a template). Maxx Judge weighs every idea against them.
- **Team kit**: the policy's plugins, each marked installed or not; **Install what is missing** adds the marketplaces and installs the plugins with `claude plugin`.
- **Team**: with `reportPresence`, who is connected, their tokens and when they were last seen.

The business edition is not a security boundary against the user, who can still edit their own files (enforce Claude Code itself with its managed settings), and it has no server: team data only travels as the JSON files in the folder you choose.

## Development

The repo is only the installer. After editing anything, run `install.ps1` again to deploy it.

```powershell
npm test                                                                          # every suite below that runs in CI
powershell -NoProfile -ExecutionPolicy Bypass -File test\run-tests.ps1         # tray, slots, installer, menu package, Other PCs helpers and gate; every .ps1 is ASCII and parses
powershell -NoProfile -ExecutionPolicy Bypass -File voice\test\run-tests.ps1   # voice, no audio
node --test peek\test\paths.test.mjs                                            # Peek's path finding
node --test whip\test\rules.test.mjs                                            # Maxx Whip's rules
node harness\test.js                                                            # Environments
powershell -NoProfile -ExecutionPolicy Bypass -File test\bridge-e2e.ps1        # Other PCs on loopback: two fake PCs pair, log in with every ssh client and hold a debate
powershell -NoProfile -STA -ExecutionPolicy Bypass -File test\bridge-tray-e2e.ps1   # the same through the tray functions
powershell -NoProfile -ExecutionPolicy Bypass -File test\mobile-e2e.ps1        # the phone app's HTTPS server on loopback: pinned certificate, pairing, refusals
cd mobile; flutter analyze; flutter test; flutter build apk --release            # the phone app (Flutter); the APK lands in mobile\build\app\outputs\flutter-apk
# Release signing: mobile\android\key.properties (storePassword, keyPassword, keyAlias, storeFile: the .jks), kept
# out of git like the key itself. Without it the release build is signed with the debug key.
# Published APKs are built by release.yml, which also gives them their version (VERSIONING.md).
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tray.ps1 -RenderTo popup.png   # draw the popup to an image (-RenderHubTo x.png -HubSection <id> draws a section of the window)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File whisper.ps1 -RenderTo whisper.png   # Maxx Whisper with sample data
```

The two `bridge-*` checks need the installed OpenSSH (or `-SshDir <folder>`) and are not part of CI.

- **ASCII scripts.** `.ps1` files must stay ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI. Accented UI text goes in as `\uXXXX` and is decoded with `Tx`, or comes from UTF-8 JSON.
- **Session symbols** (`symbols/<id>`). `python font/add_symbol.py <id> "<Spanish name>" "<English name>" <sheet.png>` adds one from a 3 x 3 sheet of its animation (the two prompts to generate it: [font/symbol-prompt.md](font/symbol-prompt.md); needs `pip install fonttools pillow`): images, statusline font, phone icons and translation. Windows Terminal may need a restart to find the font of a symbol that was just installed; switching between installed ones needs none.
- **Runtime files.** `lib/installer.ps1` lists exactly which files make up the installed runtime.
- **The skills catalog.** `toolsendor-catalog.ps1` rebuilds `catalog\skills`, `catalog\index.json` and `catalog\sources.json` from the commits pinned in it (bump them there to update). It runs nothing it downloads, applies the rules above, and lists lines that read like prompt injection to check by hand before committing. The servers are edited in `catalog\mcp.json` (pin an `npx` package's version).
- **Languages** (`lib/lang/<code>.json`). The text in the code is Spanish, and each file maps it to its translation (`"strings"`), with the name shown in Settings (`"name"`) and the culture for numbers and dates (`"culture"`). To add a language, copy `en.json` to `<code>.json`, change `name` and `culture` and translate the values; a text left out shows in Spanish. Text built from pieces goes in as a template, `(L 'Actualizado hace {0} min') -f $n`, so a language can reorder it. `$env:CLAUDEMAXXING_LANG='en'` draws the previews in that language, and `test\run-tests.ps1` checks every catalog.
- **Menu** (`menu/`): an `IExplorerCommand` in C++ (`menu/src`), registered through a sparse MSIX (`menu/package`). `menu\build.cmd` rebuilds the DLL and stub (needs Visual Studio with C++). `menu\package.ps1` rebuilds the unsigned MSIX after the manifest or the logos change (needs the Windows SDK; raise `Version` in `AppxManifest.xml` too). `menu\install.ps1` signs a copy with `menu\src\MsixSigner.cs` and registers it.

## License

ClaudeMaxxing is released under the [MIT License](LICENSE).

Third-party code keeps its own license: the catalog's skills ([anthropics/skills](catalog/skills/anthropic) Apache-2.0, [obra/superpowers](catalog/skills/superpowers/LICENSE), [wshobson/agents](catalog/skills/wshobson/LICENSE) and [affaan-m/ECC](catalog/skills/ecc/LICENSE), MIT), Maxx Judge's [court skill](claudeJudge/.claude/skills/court/LICENSE) (MIT, Alex Chen) and [Peek](peek/LICENSE), derived from midudev's Quick Peek (MIT). PyMuPDF (AGPL-3.0), Win32-OpenSSH, context-mode (Elastic License 2.0) and FreeLLMAPI (MIT) are downloaded on your PC when needed and never bundled.

ClaudeMaxxing is an independent project, not affiliated with or endorsed by Anthropic.
