# Changelog

ClaudeMaxxing follows [Semantic Versioning](https://semver.org): a new **major** version changes how it installs or what it keeps on your PC in a way that needs you to act, a **minor** one adds tools or options, a **patch** one fixes things. The version lives in `lib/common.ps1` (`$AppVersion`) and must match the newest entry here; pushing the tag `v<version>` publishes a GitHub Release with the ZIP to install (`.github/workflows/release.yml`).

## 1.0.0 - 2026-11-07

First public release. Download the ZIP, unzip it and run `install.ps1` (see the README).

- **Usage tray**: the 5-hour window and the weekly limit of your Claude plan in the notification area, with when each resets, and the ClaudeMaxxing window with every tool.
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
