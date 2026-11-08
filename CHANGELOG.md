# Changelog

ClaudeMaxxing follows [Semantic Versioning](https://semver.org): a new **major** version changes how it installs or what it keeps on your PC in a way that needs you to act, a **minor** one adds tools or options, a **patch** one fixes things. The version lives in `lib/common.ps1` (`$AppVersion`) and must match the newest entry here; pushing the tag `v<version>` publishes a GitHub Release with the ZIP to install (`.github/workflows/release.yml`).

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
