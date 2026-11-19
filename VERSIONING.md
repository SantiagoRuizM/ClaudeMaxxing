# Versioning and releases

ClaudeMaxxing has one version for everything it installs (tray, menu launcher, voice, Peek, Whip, theme, Ambientes...). It follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

## Where the version lives

| Place | What |
|---|---|
| `lib/common.ps1` (`$AppVersion`) | The version. The window shows it, and so do Settings > Apps and the installer |
| `package.json` (`version`) | The same number, for `npx github:...` |
| `CHANGELOG.md` | The first `## X.Y.Z - date` heading is the same number; `## Unreleased` sits above it |
| Git tag `vX.Y.Z` | Publishes the release that `get.ps1` installs |

`test\run-tests.ps1` fails when the first three disagree, and `release.yml` fails when the tag disagrees with them.

These keep their own numbers:

- **The menu's MSIX** (`menu/package/AppxManifest.xml`): raise its `Version` whenever the manifest or the logos change, or existing installs don't register the new package.
- **The plugins** (`peek`, `whip`, `theme`, `voice/plugin`): their `plugin.json` version is informational, because they load from the install folder. Raise it when that plugin changes.

## What each number means

The **public surface** is everything that users, IT or another PC depend on:

- the options of `install.ps1`, `get.ps1` and `uninstall.ps1`;
- the files people or IT write: `voice\config.local.json`, `%ProgramData%\ClaudeMaxxing\policy.json` (its keys and what each means), and `harness\environments\*.json`;
- the state that an update must keep reading: `~/.claude/usage-tray`;
- what the installer changes outside its folder: `~/.claude/settings.json`, the statusline block, `~/.ssh/config`, the Explorer menu, the firewall rules;
- the protocol between paired PCs (Otros PCs).

Bump the number like this:

- **MAJOR**: something on that surface breaks, or the user has to act. For example:
  - an option is removed or renamed;
  - an update stops reading a state or settings file, with no migration;
  - a policy key changes meaning;
  - the new version can no longer talk to a PC on the older one;
  - Windows or Claude Code must be a newer version than before.
- **MINOR**: something new that doesn't break anything. For example:
  - a section, module, option or policy key (a new module that sends data off the PC is off by default);
  - a new file in `~/.claude/usage-tray`.

  Deprecations are announced in a minor version and removed in the next major.
- **PATCH**: fixes, wording and performance, with no new option.

The internal identifiers listed in `CLAUDE.md` (`ClaudeTrayWin`, the `Local\ClaudeTray*` mutexes, the `# >>> ClaudeTray` markers, `HKCU\Software\ClaudeCodeMenu`, `ClaudeCode.ContextMenu`) never change, not even in a major version.

## Day to day

- Work on a branch. `main` must always be releasable: every merge to `main` passes CI.
- Every change a user would notice adds a line under `## Unreleased` in `CHANGELOG.md`, in the same commit. Refactors, tests and CI changes don't.
- Pick the number when you release, not with each commit. The biggest kind of change listed under `## Unreleased` decides it: any breaking change makes it a major, otherwise anything new makes it a minor.
- To try something before a release, install the branch with `get.ps1 -Ref <branch>`, or run `install.ps1` from a clone. There are no pre-release tags: `get.ps1` and the version checks only accept `X.Y.Z`.

## Releasing

1. On `main`, up to date and with CI green, make one commit, `chore(release): vX.Y.Z`. It:
   - renames `## Unreleased` to `## X.Y.Z - YYYY-MM-DD` and adds a new, empty `## Unreleased` above it;
   - sets `$AppVersion` in `lib/common.ps1` and `version` in `package.json`.
2. Run `test\run-tests.ps1`.
3. Tag and push: `git tag -a vX.Y.Z -m "ClaudeMaxxing X.Y.Z"`, then `git push origin main vX.Y.Z`.
4. `release.yml` then:
   - runs the whole CI;
   - checks that the tag matches the version and is on `main` or on a `release/*` branch;
   - checks that `CHANGELOG.md` has an entry for that version;
   - publishes the ZIP, its `SHA256SUMS.txt` and `get.ps1`, with that entry as the notes.

   From then on, `get.ps1` installs that release.
5. Never move or delete a published tag. A bad release is fixed by the next patch.

**Fixing an old version** while `main` holds work that isn't ready to ship:

1. Create `release/X.Y` from the tag `vX.Y.Z`.
2. Fix it there, then release `X.Y.(Z+1)` from that branch, following the same steps.
3. Bring the fix to `main`, with its line under `## X.Y.(Z+1)`.
