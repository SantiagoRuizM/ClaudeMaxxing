# Virtual office (Oficina virtual)

**Status: in progress on `feat/oficina-virtual`.** Plan written on 2026-11-27 against `main` at `0a9cd70` (v1.2.0).

## Goal

A 3D office (Three.js) where each Claude Code session the tray knows about shows up as a person at a desk: working while the session works, idle (asleep, on the phone, having coffee, playing ping-pong, or absent) otherwise. Part of the business edition, as a module the IT policy can switch off.

- Nothing company-specific in the repo: the company name, logos, team and city come from the user's configuration in `~/.claude/usage-tray/office/`.
- The building and floor plan are fixed. Interior **styles** (materials and palette) and the background **city** are swappable presets.
- Local mode (served by the tray on localhost) or shared mode (Cloudflare Pages + Pages Functions + KV, behind Cloudflare Access).
- **Not shipped with ClaudeMaxxing.** The installer carries only the hub section and `lib/office.ps1`. The 3D office is downloaded when the user asks for it, so the app stays light for everyone who never uses it.

Out of scope: editing the floor plan, more than four team pods, people walking between rooms in real time.

## Where each piece lives

| Piece | Where | Notes |
|---|---|---|
| 3D office (front) | `office/` (`index.html`, `src/`) | ES modules with an import map, **no build step**: what the tray serves locally is what Pages publishes. |
| Three.js | `office/vendor/three/` | r170, only the build and the addons the office imports, with its MIT `LICENSE`. |
| Interior styles | `office/src/styles/<id>.js` | Token objects (floor, walls, furniture, rugs, plants, lights). `office.js` reads tokens instead of literal colors. |
| Cities | `office/src/cities/<id>.js` + `office/src/city.js` | `city.js` becomes a generic engine; each preset gives `id, name, timeZone, terrain, palette, landmarks, transit, sky`. `generic` is the flat fallback, `medellin` the first full preset. |
| Team model | `office/src/team.js` | Pure logic, no Three.js: validates the configuration and places people (two private offices, four pods of four). Tested with `node --test`. |
| Demo configuration | `office/demo/` | Invented company and team, used when the user has none. |
| User configuration | `~/.claude/usage-tray/office/` | `office.json` (company, team, style, city, mode, shared URL and token) and `brand/` (logos). Never in the repo. |
| Downloaded office | `~/.claude/usage-tray/office/app/` | The release asset, unpacked. Removed with the user data by `uninstall.ps1 -RemoveData`. |
| Tray logic | `lib/office.ps1` | Configuration, download and SHA-256 check, session-to-role matching, `status.json` written only when it changes, publish to the shared site. |
| Local server | `lib/office.cs` | Minimal `HttpListener` on `http://localhost:<port>`: `/` from the downloaded app, `/config/` from the user's configuration, `/status.json` from memory. Not the phone's server: Celular is another module, off by default for companies. |
| Shared mode | `office/functions/api/status.js` | Pages Function with a KV binding: `GET` for viewers, `POST` only with the secret token. One deployment, one domain, all behind the same Access policy. Deployed with `npx wrangler` from the tray. |
| Hub section | `lib/huboffice.ps1` | `@{ Id = 'office'; Module = 'office'; Business = $true; Group = 'CONEXIONES' }` in `lib/hub.ps1`, and in `Get-MobileSection`. |
| Policy | `lib/business.ps1` | `office = 'Oficina virtual'` in `$script:BusinessModules`, on by default (local mode sends nothing off the PC). Checked in the section, the tray loop and when opening the office. |
| Release | `.gitattributes`, `.github/workflows/release.yml` | `office/ export-ignore` keeps it out of `ClaudeMaxxing-<v>.zip`; the release adds `ClaudeMaxxing-Office-<v>.zip` and its line in `SHA256SUMS.txt`. |

## Live state

The tray already knows the open sessions (`sessions.json`) and, every second, whether each one is busy. `lib/office.ps1` maps each session to a person of the team and writes:

```json
{ "agents": { "<person id>": { "state": "working" } } }
```

only when it changes (the free KV plan allows about 1000 writes a day). People without a working session stay idle; the idle activity is drawn per day from a seed of the date in the city's time zone.

Privacy: by default only the person and the state are published. The task text is optional.

## Phases

0. **Make the prototype generic.** *Done.* Try it: `python -m http.server 5182 --bind 127.0.0.1` in `office\` and open `http://127.0.0.1:5182/` (URL parameters: `hora`, `vista=normal|plano|cerca|lejos|oficina1|oficina2`, `estado=trabajando`, `sel=<id>`, `shot`, `cam`, `hide`, `nobloom`). Move it to `office/`, remove every company-specific asset and text, load the team and brand from configuration (demo when missing), import map and vendored Three.js, `team.js` with its tests. Result: the same office, with the demo team.
1. **Styles and cities.** Style tokens, `city.js` as an engine, `medellin` and `generic` presets. *Decision needed: which styles and cities go in the first version.*
2. **Local mode and hub section.** `lib/office.ps1`, `lib/office.cs`, download and check of the release asset, live state, the section (team status, style, city, open office), the policy module, `en.json`, installer, release, tests. *Decisions needed: how a session maps to a person; whether the task text is published.*
3. **Shared mode.** Pages + Functions + KV + Access with wrangler, the setup assistant in the hub, sharing (link and Access e-mail list). *Decision needed: domain and subdomain, and whether its DNS is on Cloudflare.*
4. **Phone and docs.** The section in the phone app, README, CHANGELOG, CLAUDE.md.

### Pending decisions

1. Domain and subdomain for shared mode; is the DNS on Cloudflare?
2. How a session maps to a person. The voice already names each session and gives it a role from keywords (`naming.roles` in `voice/config.json`), so a team member could say `match: { role: "codigo" }` or `match: { dir: "..." }`.
3. Publish the task text, or only the state (recommended default: only the state).
4. Which styles and cities go in the first version.

## Configuration format

```json
{
  "company": { "name": "Acme", "place": "Downtown", "logo": "brand/logo.png", "wordmark": "brand/wordmark.png", "wordmarkOnDark": "brand/wordmark-white.png" },
  "style": "moderno",
  "city": "medellin",
  "teams": { "lead": { "name": "Leadership", "color": "#F2C14E" }, "eng": { "name": "Engineering", "color": "#4AA3E6", "rug": "#9FB9CF" } },
  "people": [
    { "id": "CEO", "kind": "founder", "team": "lead", "name": "Ana Torres", "role": "CEO", "look": { "hair": "bun" }, "does": ["..."] },
    { "id": "BCK", "kind": "agent", "team": "eng", "name": "Backend", "look": { "hair": "short" }, "does": ["..."] }
  ]
}
```

- `company`: image paths are relative to `office.json`. `logo` is the square mark (reception desk, poster, favicon), `wordmark` goes on the light reception wall, `wordmarkOnDark` on the tower sign and the page header (falls back to `wordmark`). Without images, the name and its initial are drawn.
- `timeZone`: until the city presets exist (phase 1); then it comes from the city.
- `kind: "founder"`: the first two get the private offices (west, east). They are always at work.
- `kind: "agent"`: placed in the pod of its team. Up to four teams of agents (in the order of `teams`) and four agents per team; the rest are left out with a warning.
- `look`: `skin, hair (bald|slick|short|buzz|bun|long|ponytail|curly|afro), hairColor, beard, top (shirt|hoodie|blazer), shirt, inner, sleeves, pants, height, glasses`.
