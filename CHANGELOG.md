# Changelog

ClaudeMaxxing follows [Semantic Versioning](https://semver.org): a new **major** version changes how it installs or what it keeps on your PC in a way that needs you to act, a **minor** one adds tools or options, a **patch** one fixes things. The version lives in `lib/common.ps1` (`$AppVersion`) and must match the newest entry here; pushing the tag `v<version>` publishes a GitHub Release with the ZIP to install (`.github/workflows/release.yml`). What counts as each kind of change, and how to release, is in [VERSIONING.md](VERSIONING.md).

## Unreleased

- **English**: the ClaudeMaxxing window, the tray, its notifications and the other windows (Agendar sesión, Otros PCs, Claude Whisper, Claude Judge) are now in English too. Pick the language in the new **Configuración** section (the gear next to full screen); without a choice it follows the Windows display language. Each language is one file in `lib/lang`, so adding another is translating a copy of `en.json`.
- **The ClaudeMaxxing window goes full screen** with the button next to minimize, or F11 (Esc or F11 leaves it). The window is drawn at the screen's size, so the text stays sharp.
- **Inicio has shortcuts to the sections you open most**, next to its title (until you have used it for a while, Uso y agenda, Claude Code, Estadísticas and Voz).
- **Claude Code explains Peek**: a link at the bottom of the section shows what hovering over a path, clicking it and right-clicking it do with files and images in Claude's answers.
- **Ambientes explains how to create one**: a new install starts with none, and the section shows a prompt to copy into Claude Code. The prompt has Claude read your usage, projects and sessions, propose the environments, ask about what it can't tell, write each `.json` and check it with a preview that closes nothing. **Crear con Claude** copies the same prompt once there are environments. Ambientes' README and an example environment are now installed, so the prompt can point to them.
- **Claude Whip's icon is a whip.**
- **Versioning policy** in `VERSIONING.md`: what counts as major, minor and patch, and how to release. A release must be tagged on `main` (or a `release/*` branch) and have a changelog entry.

- **Claude Whip follows the forecast**: past half the 5-hour window, if it is on pace to run out before it resets, Whip comes on before its threshold and says at what time the limit would come. The shell guard is tighter (a lone `&`, extra lines, `$(...)`, backticks, `git -c`/`config`/`apply`, `sort -o`, `VAR=` prefixes, a `whip-check.sh` planted in the repo) and MCP tools that run code or write are blocked. The check stops a test command after 20 minutes.
- **Claude Whip shows each agent's account**: the email, the plan (ChatGPT Plus, Copilot Free...) and until when, from each CLI's own login files; Copilot's plan comes from `gh api`, refreshed every 6 hours.
- **The voice says when the plan ran out** and at what time it comes back.
- **Opt-in**: Otros PCs sets up nothing on a new install until **Activar** (or `install.ps1 -Bridge`); environment detection stays off until you turn it on, and never runs without environments.
- **Claude Whisper** asks once, before the first listen, after saying that the transcription is an undocumented service and that the call's audio goes to Anthropic; calls older than 30 days are deleted.
- **Business**: the policy can also turn off Ambientes (off by default) and Claude Judge; a changed policy applies within 5 minutes; the Whip plugin reads IT's policy itself.
- **Security fixes**: `get.ps1` no longer installs the unverified `main` branch when GitHub's API fails; **Permitir 1 hora** no longer allows requests already waiting, and a command too long to show can only be refused; Peek shows programs and scripts in Explorer instead of running them; a paired PC whose user has an apostrophe no longer breaks every `ssh`; the tamper check covers `sshd_config` and the gate.
- **Fixes**: after `/clear` a session no longer lists itself among the other sessions; JSON state is written atomically and `history.json`/`cloud.json` under a lock; updates now refresh the statusline block; the window fits 1366x768 screens; uninstall gives back the exact theme; money and times follow one Spanish format; keys are stored encrypted (DPAPI); scheduled runs find Claude Code after it moved.
- **CI** runs the Whip and Peek tests and draws every window; a release runs the whole CI.

## 1.1.0 - 2026-11-08

- **Business edition**: `install.ps1 -Business` (or `--business`; `-Personal` is the default and switches back). The choice is kept on update, and a policy that IT puts in `%ProgramData%\ClaudeMaxxing\policy.json` makes the PC business. A new **Empresa** section shows:
  - the seat report: 30-day use, the API-equivalent cost against the seat price, and whether the seat falls short, fits or has room;
  - reports for a shared folder (by hand, or every 7 days) and the team's summary as a CSV;
  - the company's objectives, which Claude Judge weighs in every trial;
  - the team kit of plugins and marketplaces, installed with one click.
- The company policy (`business\policy.example.json`) turns modules off: FreeLLMAPI, Otros PCs and Claude Whisper are off by default. A module that is off disappears from the tray and the window and does not start; turning Otros PCs off also removes its firewall rules and `~/.ssh/config` block.
- **Debates** in Otros PCs: **Debatir con <PC>...** has your Claude and the other person's argue a decision, each from its own project, and gives you both one recommendation. A blind first round, two replies, and a moderator with no files on the PC that started it. Each Claude only reads the folder its person picks (`claude -p --restricted`, Read/Glob/Grep, no `.env` or keys); only text crosses, through a new mailbox mode of the gate that runs nothing; keys are hidden before anything is sent. The other PC accepts each debate on its own: an hour grant does not open one.

## 1.0.0 - 2026-11-07

First public release. Install with one command: `irm https://raw.githubusercontent.com/SantiagoRuizM/ClaudeMaxxing/main/get.ps1 | iex` (or `npx github:SantiagoRuizM/ClaudeMaxxing`, or the ZIP and `install.ps1`; see the README).

- **Usage tray**: the 5-hour window and the weekly limit of your Claude plan in the notification area, with when each resets, a warning at 80 % and 95 %, and the ClaudeMaxxing window with every tool.
- **Skills y MCP**: every skill and MCP server Claude Code loads, and Anthropic's packages to create skills, MCP servers and plugins.
- **"Abrir con Claude Code"** in the Explorer menu: each session in its own half of a screen, with its own color and name.
- **Voice**: a spoken one-line summary of every answer, a voice and a musical signature per session (Edge, ElevenLabs, Gemini or the Windows voice).
- **Agenda**: scheduled and automatic sessions on this PC (Task Scheduler) or in the cloud, and a week plan that spreads the weekly limit.
- **Planear sesión**: Claude Judge puts the day's idea on trial before you start.
- **Estadísticas**: hours, consumption per 5-hour window with a forecast, schedules, projects, models and tools, from Claude Code's own transcripts.
- **Ambientes**: work environments that open and close apps, folders, servers and Chrome tabs, with detection of the one you are in.
- **Otros PCs**: PCs on the same network find each other, pair once, and open terminals or Claude Code on each other.
- **Claude Whisper**: a live copilot for calls.
- **Peek**: every path in Claude's replies becomes a link with a preview (image, video frame, PDF page, audio length, folder, code with `path[from:to]` ranges), and each reply lists its references.
- **FreeLLMAPI** sessions when the plan runs out, and **context-mode** to save context.
