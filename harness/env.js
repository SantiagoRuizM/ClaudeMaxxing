#!/usr/bin/env node
// Work environments: turning one on closes what does not belong (with the reason, read from each tab's content)
// and opens a fixed set of things; turning it off closes only what it owns. Three layers keep it deterministic:
//   snapshot(env)        reads the machine (tabs, folders, processes, ports, Docker, gdocs): the only IO before acting
//   plan(env, snap, mode) pure: the same snapshot always gives the same actions (test.js covers the cases)
//   apply(env, plan)     does it, gently: everything is asked to close first and forced only after graceSeconds
// Usage:
//   node env.js <name> [on|off]          preview
//   node env.js <name> [on|off] --yes    apply (records the active environment in run/active.json)
//   node env.js status [--json]          which environment is on, the last job and the list of environments
//   node env.js detect [--json] [--force] [--state]   which environment what is open belongs to (run/detect.json),
//                                        plus focus drift and dev servers (run/focus.json)
//   --job                                also record progress in run/job.json (ClaudeMaxxing reads it)
// Every switch and the time spent in each environment go to run/history.json.
const fs = require('fs');
const path = require('path');
const { execFileSync, execSync, spawn } = require('child_process');
const { collect, rpc, clip, context } = require('./tabs');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const WMPLAYER = 'C:\\Program Files\\Windows Media Player\\wmplayer.exe';
const DOCKER_DESKTOP = 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe';
// Per-PC data, never in the install folder or the repo: environments\*.json, run\ (state, history, hosts) and .env.
const HOME = process.env.YOURHARNESS_HOME || path.join(require('os').homedir(), '.claude', 'usage-tray', 'harness');
const ENV_DIR = process.env.YOURHARNESS_ENV_DIR || path.join(HOME, 'environments');
const RUN_DIR = process.env.YOURHARNESS_RUN_DIR || path.join(HOME, 'run');
const ACTIVE_FILE = path.join(RUN_DIR, 'active.json');
const JOB_FILE = path.join(RUN_DIR, 'job.json');
const HISTORY_FILE = path.join(RUN_DIR, 'history.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ps = (script) => execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', `[Console]::OutputEncoding = [Text.Encoding]::UTF8; ${script}`], { encoding: 'utf8' }).trim();
const psJson = (script) => { const out = ps(`${script} | ConvertTo-Json -Compress`); return out ? [].concat(JSON.parse(out)) : []; };
const readJson = (file) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };
const writeJson = (file, value) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value, null, 2)); };

// ---------------------------------------------------------------- pure decisions

// Keep or close one tab: closed profiles, then explicit keep, explicit close, then the tab's content.
function classify(tab, env) {
  const profileRule = (env.closeProfiles || []).find((p) => p.email === tab.profile);
  if (profileRule) return { action: 'close', reason: profileRule.reason };
  const rule = (list) => (list || []).find((r) => new RegExp(r.match, 'i').test(tab.url));
  const keepRule = rule(env.tabs.keep); // keep wins: e.g. this environment's playlist inside a "close other music" rule
  if (keepRule) return { action: 'keep', reason: keepRule.reason };
  const closeRule = rule(env.tabs.close);
  if (closeRule) return { action: 'close', reason: closeRule.reason };
  const c = tab.content || {};
  const yt = c.youtube || {};
  // Title + YouTube metadata + meta description, not body text: an inbox or a sidebar mentions everything.
  const about = [tab.title, tab.url, yt.title, yt.channel, yt.description, c.description].filter(Boolean).join(' ');
  const topic = env.tabs.focusTopics && about.match(new RegExp(env.tabs.focusTopics, 'i'));
  if (topic) return { action: 'keep', reason: `trata de "${topic[0]}"` };
  // Open-only environments keep whatever no rule mentions.
  if (env.tabs.default === 'keep') return { action: 'keep', reason: 'sin regla: se respeta' };
  return { action: 'close', reason: env.tabs.defaultReason || `sin relación con ${env.name}` };
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const sameDir = (a, b) => !!a && !!b && path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();
const composeProject = (dir) => path.basename(dir).toLowerCase();
const playlistName = (env) => `${env.name.toLowerCase()}.m3u`;

// The decision, from a snapshot only. mode "on" enters the environment, "off" closes what it owns.
function plan(env, snap, mode = 'on') {
  const warnings = [];
  const off = mode === 'off';

  // What the environment opens, resolved per profile ("already open" only counts in that profile).
  const opens = [];
  for (const o of env.tabs.open) {
    let url = o.url;
    let match = o.match || (o.url && `^${escapeRe(o.url)}`);
    if (o.gdoc) {
      const id = snap.gdocs[o.gdoc];
      if (!id) { warnings.push(`no encuentro el gdoc de "${o.name}": ${o.gdoc}`); continue; }
      url = `https://docs.google.com/document/d/${id}/edit`;
      match = `/document/d/${id}`;
    }
    const profile = o.profile || env.chromeProfile;
    const email = snap.emails[profile];
    if (!email) warnings.push(`el perfil "${profile}" no existe en Chrome`);
    opens.push({ name: o.name, url, match, profile, email, label: email ? email.split('@')[0] : profile });
  }
  const connected = new Set(snap.profiles.map((p) => p.email));
  for (const o of opens) {
    if (o.email && !connected.has(o.email)) warnings.push(`no veo las pestañas de ${o.label}: Chrome cerrado o sin la extensión; se abre sin comprobar duplicados`);
  }

  // Every tab: the first one matching each open item is the environment's own; duplicates follow the rules.
  const claimed = new Set();
  const tabs = snap.profiles.flatMap((p) => p.tabs.map((t) => {
    const tab = { ...t, host: p.host, profile: p.email };
    const owned = opens.filter((o) => o.email === tab.profile && new RegExp(o.match, 'i').test(tab.url));
    const mine = owned.find((o) => !claimed.has(o));
    if (mine) {
      claimed.add(mine);
      return off ? { ...tab, action: 'close', reason: `lo abrió ${env.name}` } : { ...tab, action: 'keep', reason: `es "${mine.name}" de ${env.name}` };
    }
    if (off) return owned.length ? { ...tab, action: 'close', reason: `duplicado de "${owned[0].name}"` } : { ...tab, action: 'keep', reason: `no es de ${env.name}` };
    if (owned.length) return { ...tab, action: 'close', reason: `duplicado de "${owned[0].name}"` };
    return { ...tab, ...classify(tab, env) };
  }));

  // Explorer windows: "on" keeps only the environment's folder (or none with closeAllFolders); "off" closes it.
  const folders = snap.folders.map((f) => ({ ...f, own: sameDir(f.path, env.folder) }));
  let closeFolders = [];
  if (off) closeFolders = folders.filter((f) => f.own);
  else if (env.folder || env.closeAllFolders) closeFolders = folders.filter((f) => !f.own);
  const openFolder = !off && !!env.folder && !folders.some((f) => f.own);

  // Music: the player is this environment's when it plays the playlist written for it (run/<name>.m3u);
  // any other player is other music, closed on "on" so the environment's own can start.
  const ownPlayer = (snap.player || []).some((c) => String(c).toLowerCase().includes(playlistName(env)));
  const music = !off && env.music?.folder ? { folder: env.music.folder, match: env.music.match, play: !ownPlayer } : null;

  // Apps: by name from closeApps; "off" stops this environment's music player and the apps it opened.
  const byName = (name) => snap.procs.filter((p) => p.ProcessName.toLowerCase() === name.toLowerCase());
  const appRules = off
    ? [...(env.music?.folder ? [{ process: 'wmplayer', reason: `música de ${env.name}` }] : []), ...(env.openApps || []).map((a) => ({ process: a.process, reason: `lo abrió ${env.name}` }))]
    : [...(env.closeApps || []), ...(music?.play ? [{ process: 'wmplayer', reason: `otra música: en ${env.name} suena la suya` }] : [])];
  const apps = appRules.map((a) => {
    const mine = byName(a.process);
    return { name: a.process, reason: a.reason, pids: mine.map((p) => p.Id), title: mine.find((p) => p.MainWindowTitle)?.MainWindowTitle };
  }).filter((a, i, all) => a.pids.length && all.findIndex((b) => b.name.toLowerCase() === a.name.toLowerCase()) === i);
  const launch = off ? [] : (env.openApps || []).filter((a) => !byName(a.process).length);

  // Servers: "on" stops stopPorts (and, with stopServers, every listening server of those processes) and starts
  // missing devServers; "off" stops its own devServers. protectedPids (the Chrome hosts) are never stopped.
  const portRules = off ? (env.devServers || []).map((s) => ({ port: s.port, reason: `${s.name} de ${env.name}` })) : (env.stopPorts || []);
  const stopPorts = portRules.filter((s) => snap.ports[s.port]).map((s) => ({ ...s, owner: snap.ports[s.port] }));
  if (!off && env.stopServers) {
    const names = env.stopServers.processes.map((n) => n.toLowerCase());
    for (const l of snap.listening || []) {
      if (!names.includes(l.name.toLowerCase()) || (snap.protectedPids || []).includes(l.pid) || stopPorts.some((s) => s.owner.ProcessId === l.pid)) continue;
      stopPorts.push({ port: l.port, reason: env.stopServers.reason || `servidor ${l.name}`, owner: { ProcessId: l.pid, Name: l.name } });
    }
  }
  const startServers = off ? [] : (env.devServers || []).filter((s) => !snap.ports[s.port]);

  // Docker. Desktop quits only when no other project's container is running (it stops them all).
  let docker = null;
  const d = env.docker;
  const s = snap.docker;
  if (d && s) {
    // "all": every running container, of any project (no composeDir).
    const project = d.all ? null : composeProject(d.composeDir);
    const mine = d.all ? s.running : s.running.filter((n) => n.startsWith(`${project}-`));
    const others = d.all ? [] : s.running.filter((n) => !n.startsWith(`${project}-`));
    const ups = (d.action || 'up') === 'up';
    // "off" only undoes what "on" did: an environment that stops Docker never starts it when turned off.
    if (off ? ups && s.up : !ups && s.up) {
      docker = { kind: 'stop', composeDir: d.composeDir, names: d.all ? mine : null, containers: mine.length, timeout: d.stopTimeout || 30, quit: (off || !!d.quitDesktop) && !others.length, others: others.length, reason: off ? `${env.name} se apaga` : d.reason };
    } else if (!off && ups) {
      docker = { kind: 'up', composeDir: d.composeDir, startDesktop: !s.up, running: mine.length };
    }
  }

  // WSL's VM (vmmem) keeps gigabytes after Docker Desktop quits: shut it down when the environment asks to.
  const wsl = !off && !!env.wslShutdown && snap.procs.some((p) => /^vmmem/i.test(p.ProcessName));
  const open = off ? [] : opens.filter((o) => !claimed.has(o));

  // Claude Code session: "on" opens one in claude.dir unless one is already open there; "off" never closes it (unsaved work).
  let claude = null;
  if (!off && env.claude?.dir && !(snap.claude?.dirs || []).some((d) => sameDir(d, env.claude.dir))) {
    if (snap.claude?.launcher) claude = { dir: env.claude.dir, launcher: snap.claude.launcher };
    else warnings.push('no encuentro el lanzador de Claude Code de ClaudeMaxxing: no se abre la sesión');
  }
  return { mode, env: env.name, tabs, closeTabs: tabs.filter((t) => t.action === 'close'), apps, launch, closeFolders, openFolder, stopPorts, startServers, docker, wsl, music, open, opens, claude, claimed: [...claimed].map((o) => o.name), warnings };
}

// One Chrome profile's tabs judged against an environment, for the extension (badge, nudge, popup): the same plan as
// turning it on (its own tabs and their duplicates included), from just those tabs. emails and gdocs: tabsContext().
function judgeTabs(env, tabs, { email = '', emails = {}, gdocs = {} } = {}) {
  const snap = { profiles: [{ email, host: {}, tabs }], emails, gdocs, folders: [], procs: [], player: [], ports: {}, docker: null, listening: [] };
  return plan(env, snap, 'on').tabs.map((t) => ({ id: t.id, action: t.action, reason: t.reason }));
}

// Nothing to do: the machine already matches the environment (or, for "off", nothing of it is left).
function isSatisfied(p) {
  return !p.closeTabs.length && !p.apps.length && !p.launch.length && !p.closeFolders.length && !p.openFolder && !p.stopPorts.length &&
    !p.startServers.length && !p.open.length && !(p.music && p.music.play) && !p.claude && !p.wsl &&
    !(p.docker && (p.docker.kind === 'stop' ? p.docker.containers || p.docker.quit : p.docker.startDesktop || !p.docker.running));
}

// ---------------------------------------------------------------- reading the machine

// Chrome profile directory ("Profile 1") -> signed-in email, from Chrome's Local State.
function profileEmails() {
  const file = path.join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'User Data', 'Local State');
  const cache = readJson(file)?.profile?.info_cache || {};
  return Object.fromEntries(Object.entries(cache).map(([dir, v]) => [dir, v.user_name]));
}

// Get-NetTCPConnection exits non-zero when nothing listens: a free port is "no owner", not an error.
function portOwner(port) {
  try {
    return psJson(`Get-NetTCPConnection -State Listen -LocalPort ${port} -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" } | Select-Object ProcessId,Name`)[0] || null;
  } catch { return null; }
}
const dockerUp = () => { try { execFileSync('docker', ['info', '--format', '{{.ServerVersion}}'], { timeout: 15000, stdio: 'pipe' }); return true; } catch { return false; } };
const dockerRunning = () => { try { return execFileSync('docker', ['ps', '--format', '{{.Names}}'], { encoding: 'utf8', timeout: 15000 }).split('\n').map((x) => x.trim()).filter(Boolean); } catch { return []; } };

// ClaudeMaxxing's Explorer-menu launcher (registry, written by its install.ps1) and the folders of its live sessions
// (sessions.json, kept by open-session.ps1; a closed window leaves a stale entry, so each hwnd is checked).
function claudeSessions() {
  let launcher = null;
  try { launcher = ps(`(Get-ItemProperty 'HKCU:\\Software\\ClaudeCodeMenu' -ErrorAction Stop).Launcher`) || null; } catch {}
  const file = path.join(process.env.USERPROFILE, '.claude', 'usage-tray', 'sessions.json');
  let dirs = [];
  if (fs.existsSync(file)) {
    try {
      dirs = psJson(`Add-Type -Namespace YH -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h); [DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);'; $s = Get-Content -LiteralPath '${file}' -Raw -Encoding UTF8 | ConvertFrom-Json; $s | Where-Object { $_ -and [YH.W]::IsWindow([IntPtr][long]$_.hwnd) -and [YH.W]::IsWindowVisible([IntPtr][long]$_.hwnd) } | ForEach-Object { $_.dir }`);
    } catch {}
  }
  return { launcher, dirs };
}

// What judgeTabs needs from this PC: Chrome profile directories to emails and the gdocs' ids.
function tabsContext(env) {
  const gdocs = {};
  for (const o of env.tabs.open.filter((x) => x.gdoc)) gdocs[o.gdoc] = readJson(o.gdoc)?.doc_id || null;
  return { emails: profileEmails(), gdocs };
}

async function snapshot(env) {
  const profiles = (await collect({ max: 600 })).map((p) => ({ email: p.host.email || p.profile, host: p.host, tabs: p.tabs }));
  const folders = !env.folder && !env.closeAllFolders ? [] : psJson(`(New-Object -ComObject Shell.Application).Windows() | Where-Object { $_.FullName -like '*explorer.exe' } | ForEach-Object { [pscustomobject]@{ hwnd = $_.HWND; path = $_.Document.Folder.Self.Path; name = $_.LocationName } }`);
  const names = [...(env.closeApps || []), ...(env.openApps || [])].map((a) => a.process)
    .concat(env.music?.folder ? ['wmplayer'] : [], env.wslShutdown ? ['vmmem', 'vmmemWSL'] : []);
  // Filter instead of Get-Process -Name: a missing name fails the whole command.
  const procs = !names.length ? [] : psJson(`Get-Process | Where-Object { @(${names.map((n) => `'${n}'`).join(',')}) -contains $_.ProcessName } | Select-Object Id,ProcessName,MainWindowTitle`);
  // The player's command line names the playlist it was started with (run/<name>.m3u): whose music is playing.
  const player = !env.music?.folder ? [] : psJson(`Get-CimInstance Win32_Process -Filter "Name='wmplayer.exe'" | ForEach-Object { [string]$_.CommandLine }`);
  const ports = {};
  for (const port of [...(env.stopPorts || []), ...(env.devServers || [])].map((x) => x.port)) ports[port] = portOwner(port);
  // Below the ephemeral range (49152+): there listen Chrome hosts and other local helpers, never dev servers.
  const listening = !env.stopServers ? [] : psJson(`Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ge 1024 -and $_.LocalPort -lt 49152 } | Sort-Object LocalPort, OwningProcess -Unique | ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; if ($p) { [pscustomobject]@{ port = $_.LocalPort; pid = $_.OwningProcess; name = $p.ProcessName } } }`);
  let docker = null;
  if (env.docker) { const up = dockerUp(); docker = { up, running: up ? dockerRunning() : [] }; }
  const gdocs = {};
  for (const o of env.tabs.open.filter((x) => x.gdoc)) gdocs[o.gdoc] = readJson(o.gdoc)?.doc_id || null;
  const claude = env.claude ? claudeSessions() : null;
  return { profiles, emails: profileEmails(), folders, procs, player, ports, listening, protectedPids: protectedPids(), docker, gdocs, claude };
}

// This process, its parent and every Chrome host (run/<pid>.json): a "stop every server" must spare them.
function protectedPids() {
  const hosts = fs.existsSync(RUN_DIR) ? fs.readdirSync(RUN_DIR).filter((f) => /^\d+\.json$/.test(f)).map((f) => +f.slice(0, -5)) : [];
  return [process.pid, process.ppid, ...hosts];
}

// ---------------------------------------------------------------- doing it

const waitFor = async (fn, ms) => { for (const end = Date.now() + ms; Date.now() < end; await sleep(2000)) if (await fn()) return true; return false; };
const httpUp = async (url) => { try { return (await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(3000) })).status < 500; } catch { return false; } };
const isLocal = (url) => /^https?:\/\/(localhost|127\.0\.0\.1)[:/]/.test(url);

async function apply(env, p, step = () => {}) {
  const grace = (env.graceSeconds ?? 5) * 1000;
  const report = [];
  const note = (line) => { report.push(line); console.log(line); };

  if (p.closeTabs.length) {
    step(`Cerrando ${p.closeTabs.length} pestañas`);
    // Per profile: a host only owns its own profile's tabs. A stuck profile must not stop the rest.
    for (const [host, tabs] of Map.groupBy(p.closeTabs, (t) => t.host)) {
      try {
        const { failed = [] } = await rpc(host, 'close', { ids: tabs.map((t) => t.id) });
        for (const f of failed) note(`NO se cerró [${f.id}] ${clip(tabs.find((t) => t.id === f.id)?.title, 70)}: ${f.error}`);
      } catch (e) {
        // Closing every tab of a profile closes Chrome, and its host may go before it answers.
        if (tabs.length === p.tabs.filter((t) => t.host === host).length) note(`${tabs[0].profile}: Chrome se cerró con su última pestaña`);
        else note(`NO se cerraron las pestañas de ${tabs[0].profile}: ${e.message}`);
      }
    }
  }

  // Ask every window and server to close, give them time together, then force what is left.
  // PIDs may already be gone: killing a parent's tree (/T) takes its children with it.
  const pids = [...new Set([...p.apps.flatMap((a) => a.pids), ...p.stopPorts.map((s) => s.owner.ProcessId)])];
  if (pids.length) {
    step(`Pidiendo cierre a ${p.apps.length} apps y ${p.stopPorts.length} servidores (${grace / 1000} s)`);
    for (const id of pids) {
      try { ps(`$p = Get-Process -Id ${id} -ErrorAction Stop; [void]$p.CloseMainWindow()`); } catch {}
      try { execFileSync('taskkill', ['/PID', String(id), '/T'], { stdio: 'pipe' }); } catch {}
    }
    await sleep(grace);
    for (const id of pids) try { execFileSync('taskkill', ['/PID', String(id), '/T', '/F'], { stdio: 'pipe' }); } catch {}
  }

  if (p.closeFolders.length) {
    ps(`(New-Object -ComObject Shell.Application).Windows() | Where-Object { @(${p.closeFolders.map((f) => f.hwnd).join(',')}) -contains $_.HWND } | ForEach-Object { $_.Quit() }`);
  }

  const d = p.docker;
  if (d?.kind === 'stop') {
    if (d.containers) {
      step(`Parando ${d.containers} contenedores de ${d.names ? 'Docker' : path.basename(d.composeDir)} (hasta ${d.timeout} s cada uno)`);
      if (d.names) execFileSync('docker', ['stop', '-t', String(d.timeout), ...d.names], { stdio: 'pipe' });
      else execFileSync('docker', ['compose', 'stop', '-t', String(d.timeout)], { cwd: d.composeDir, stdio: 'pipe' });
    }
    // Checked again right before: something may have started meanwhile.
    if (d.quit && !dockerRunning().length) {
      step('Apagando Docker Desktop');
      try { execFileSync('docker', ['desktop', 'stop', '--timeout', '120'], { stdio: 'pipe' }); } catch (e) { note(`Docker Desktop no se apagó: ${e.message.split('\n')[0]}`); }
    }
  }
  if (p.wsl) {
    step('Apagando WSL (libera la memoria de vmmem)');
    try { execFileSync('wsl', ['--shutdown'], { stdio: 'pipe', timeout: 60000 }); note('wsl: apagado'); } catch (e) { note(`NO se apagó WSL: ${e.message.split('\n')[0]}`); }
  }
  note(`Cerrado: ${p.closeTabs.length} pestañas, ${p.apps.length} apps, ${p.stopPorts.length} servidores, ${p.closeFolders.length} carpetas.`);
  if (p.mode === 'off') return report;

  for (const a of p.launch) {
    step(`Abriendo ${a.name}`);
    spawn(a.path, a.args || [], { detached: true, stdio: 'ignore' }).unref();
    note(`${a.name}: abierto`);
  }

  if (p.openFolder) spawn('explorer.exe', [env.folder], { detached: true, stdio: 'ignore' }).unref();
  if (env.folder) note(`carpeta: ${env.folder}`);

  if (p.music?.play) {
    const files = fs.readdirSync(p.music.folder).filter((f) => /\.(mp3|m4a|flac|wav|ogg)$/i.test(f) && (!p.music.match || new RegExp(p.music.match, 'i').test(f)));
    const playlist = path.join(RUN_DIR, playlistName(env));
    fs.mkdirSync(RUN_DIR, { recursive: true });
    fs.writeFileSync(playlist, files.map((f) => path.join(p.music.folder, f)).join('\r\n'));
    if (files.length) {
      spawn(WMPLAYER, [playlist], { detached: true, stdio: 'ignore' }).unref();
      note(`música: ${files.length === 1 ? files[0] : `${files.length} pistas`} en Windows Media Player`);
    } else note(`NO se puso música: nada en ${p.music.folder}${p.music.match ? ` coincide con "${p.music.match}"` : ''}`);
  } else if (p.music) note('música: ya suena la de este ambiente (no se reinicia)');

  if (d?.kind === 'up') {
    if (d.startDesktop) {
      step('Abriendo Docker Desktop (hasta 2 min)');
      spawn(DOCKER_DESKTOP, [], { detached: true, stdio: 'ignore' }).unref();
      if (!(await waitFor(dockerUp, 120000))) throw new Error('Docker Desktop no respondió en 2 minutos');
    }
    step(`Levantando ${path.basename(d.composeDir)} en Docker`);
    // Right after Docker Desktop starts, `docker info` answers before the engine serves images (500s): retry.
    const composeUp = () => { try { execFileSync('docker', ['compose', 'up', '-d'], { cwd: d.composeDir, stdio: 'pipe' }); return true; } catch { return false; } };
    if (!(await waitFor(composeUp, 120000))) throw new Error(`docker compose up -d falló en ${d.composeDir} durante 2 minutos`);
    note(`docker: ${path.basename(d.composeDir)} arriba`);
  }

  for (const s of p.startServers) {
    step(`Levantando ${s.name} en :${s.port}`);
    if (s.managed) {
      execSync(s.command, { cwd: s.cwd, stdio: 'pipe' }); // the project's own launcher detaches its servers and returns
    } else {
      // cmd /c: when the server stops, its terminal tab goes with it.
      spawn('wt', ['-w', 'new', 'nt', '--title', `${env.name} · ${s.name} :${s.port}`, '-d', s.cwd, 'cmd', '/c', s.command], { detached: true, stdio: 'ignore' }).unref();
    }
    note(`${s.name}: http://localhost:${s.port}/`);
  }

  if (p.open.length) {
    step(`Abriendo ${p.open.length} pestañas`);
    await Promise.all(p.open.filter((o) => isLocal(o.url)).map((o) => waitFor(() => httpUp(o.url), 90000)));
    for (const [profile, tabs] of Map.groupBy(p.open, (o) => o.profile)) {
      spawn(CHROME, [`--profile-directory=${profile}`, ...tabs.map((o) => o.url)], { detached: true, stdio: 'ignore' }).unref();
      await sleep(1500); // let one profile's window open before asking Chrome for the next
    }
  }
  for (const o of p.opens) note(`${o.name} (${o.label}): ${o.url}${p.claimed.includes(o.name) && !p.open.includes(o) ? ' (ya estaba abierta)' : ''}`);

  if (p.claude) {
    step(`Abriendo Claude Code en ${path.basename(p.claude.dir)}`);
    // The launcher places the window on a free half-screen slot and says so itself when all are taken.
    spawn(p.claude.launcher.replace('%1', `"${p.claude.dir}"`), { shell: true, detached: true, stdio: 'ignore', windowsHide: true }).unref();
    note(`claude code: ${p.claude.dir}`);
  } else if (env.claude?.dir) note(`claude code: ya hay una sesión en ${env.claude.dir}`);
  return report;
}

// ---------------------------------------------------------------- output

function printPlan(env, p) {
  const tabLine = (t) => `[${t.id}] ${clip(t.title, 70)} (${String(t.profile).split('@')[0]})\n        ${clip(context(t), 120)}`;
  const d = p.docker;
  console.log(`\n=== ${p.mode === 'off' ? 'Apagar' : 'Entrar a'} ${env.name}: ${env.focus}\n`);
  for (const w of p.warnings) console.log(`AVISO: ${w}`);
  if (p.warnings.length) console.log('');
  console.log('CERRAR');
  for (const t of p.closeTabs) console.log(`  pestaña ${tabLine(t)}\n        motivo: ${t.reason}`);
  for (const a of p.apps) console.log(`  app     ${a.name} (pid ${a.pids.join(', ')})${a.title ? ` "${a.title}"` : ''}\n        motivo: ${a.reason}`);
  for (const f of p.closeFolders) console.log(`  carpeta ${f.path || f.name}\n        motivo: ${p.mode === 'off' ? `carpeta de ${env.name}` : env.folder ? `solo queda la carpeta de ${env.name}` : `${env.name} no usa carpetas`}`);
  for (const s of p.stopPorts) console.log(`  server  :${s.port} ${s.owner.Name} pid ${s.owner.ProcessId}\n        motivo: ${s.reason}`);
  if (d?.kind === 'stop') {
    if (d.containers) console.log(`  docker  ${d.containers} contenedores de ${d.names ? 'Docker' : path.basename(d.composeDir)} (stop con ${d.timeout} s de margen)`);
    console.log(`          Docker Desktop ${d.quit ? 'se apaga después' : d.others ? 'se queda: hay contenedores de otros proyectos' : 'se queda'}\n        motivo: ${d.reason}`);
  }
  if (p.wsl) console.log('  wsl     wsl --shutdown\n        motivo: libera la memoria de vmmem');
  if (isSatisfied(p)) console.log('  nada: ya está así');
  else console.log(`  (apagado suave: se pide cerrar y se fuerza solo tras ${env.graceSeconds ?? 5} s)`);
  if (p.mode === 'off') return;
  console.log('\nMANTENER');
  for (const t of p.tabs.filter((x) => x.action === 'keep')) console.log(`  pestaña ${clip(t.title, 70)}: ${t.reason}`);
  if (env.folder && !p.openFolder) console.log(`  carpeta ${env.folder}: es la del proyecto`);
  console.log('\nABRIR');
  if (p.openFolder) console.log(`  carpeta ${env.folder}`);
  for (const a of env.openApps || []) console.log(`  app     ${a.name} ${p.launch.includes(a) ? 'se abrirá' : 'ya está abierta'}`);
  if (p.music) console.log(`  música  ${p.music.play ? `${env.music.folder}${env.music.match ? ` (${env.music.match})` : ''} en Windows Media Player` : 'ya suena la de este ambiente (no se reinicia)'}`);
  if (d?.kind === 'up') console.log(`  docker  Docker Desktop ${d.startDesktop ? 'se abrirá' : 'ya responde'}; docker compose up -d en ${path.basename(d.composeDir)}`);
  for (const s of env.devServers || []) console.log(`  server  ${s.name} :${s.port} ${p.startServers.includes(s) ? 'se levantará' : 'ya corre (se reutiliza)'}`);
  for (const o of p.opens) console.log(`  pestaña ${o.name} ${clip(o.url, 80)} (${o.label}${p.open.includes(o) ? '' : ', ya abierta'})`);
  if (env.claude?.dir) console.log(`  claude  ${env.claude.dir} ${p.claude ? 'se abrirá' : 'ya tiene sesión (se reutiliza)'}`);
}

// ---------------------------------------------------------------- state and CLI

const listEnvs = () => (fs.existsSync(ENV_DIR) ? fs.readdirSync(ENV_DIR) : []).filter((f) => f.endsWith('.json')).map((f) => {
  const env = readJson(path.join(ENV_DIR, f)) || {};
  return { id: f.replace(/\.json$/, ''), name: env.name || f, focus: env.focus || '' };
});
const loadEnv = (id) => {
  const file = path.join(ENV_DIR, `${id.toLowerCase()}.json`);
  if (!fs.existsSync(file)) throw new Error(`no existe el ambiente "${id}" (hay: ${listEnvs().map((e) => e.id).join(', ')})`);
  return readJson(file);
};
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

// run/history.json, for ClaudeMaxxing's graph: edges["trabajo>atlas"] counts each switch (through an "off" too:
// "last" remembers where you were) and time[day][id] the seconds spent in each environment.
// shortcut: a stint counts on the day it started; split it at midnight if per-day totals ever need to be exact.
const MAX_STINT = 12 * 3600; // the PC may sleep or shut down with an environment on
const dayOf = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
function recordSwitch(hist, prev, mode, id, now) {
  const h = { last: hist?.last || null, edges: { ...hist?.edges }, time: JSON.parse(JSON.stringify(hist?.time || {})) };
  const ends = prev?.since && (mode === 'off' ? prev.id === id : prev.id !== id);
  if (ends) {
    const start = new Date(prev.since);
    const secs = Math.min(MAX_STINT, Math.max(0, Math.round((now - start) / 1000)));
    const day = (h.time[dayOf(start)] ||= {});
    day[prev.id] = (day[prev.id] || 0) + secs;
  }
  if (mode === 'on') {
    const from = prev?.id || h.last;
    if (from && from !== id) h.edges[`${from}>${id}`] = (h.edges[`${from}>${id}`] || 0) + 1;
    h.last = id;
  }
  return h;
}

// ---------------------------------------------------------------- which environment am I in?
// detect: everything open, reduced to a fingerprint of sites, apps, servers, folders and sessions (not titles: they
// change with every notification). Only a new fingerprint asks a judge: Jev (TypeSafe's decision model, a Choice
// with probabilities) when TYPESAFE_API_KEY is set, then claude -p when Jev is missing, fails or is unsure.
// The verdict goes to run/detect.json; ClaudeMaxxing offers the switch when it is not the environment that is on.
const DETECT_FILE = path.join(RUN_DIR, 'detect.json');
const FOCUS_FILE = path.join(RUN_DIR, 'focus.json');
const SURE = 0.6;
const siteOf = (url) => { try { const u = new URL(url); return u.protocol.startsWith('http') ? `${u.host}${u.pathname.split('/').slice(0, 2).join('/')}` : u.protocol.replace(':', ''); } catch { return 'otro'; } };

// One snapshot that every environment's plan can read: the union of what each one looks at.
function probeOf(envs) {
  const uniq = (xs) => [...new Set(xs)];
  return {
    closeAllFolders: true, docker: {}, claude: {}, music: { folder: true }, wslShutdown: true, stopServers: { processes: [] },
    closeApps: uniq(envs.flatMap((e) => [...(e.closeApps || []), ...(e.openApps || [])].map((a) => a.process))).map((process) => ({ process })),
    stopPorts: uniq(envs.flatMap((e) => [...(e.stopPorts || []), ...(e.devServers || [])].map((s) => s.port))).map((port) => ({ port })),
    tabs: { open: envs.flatMap((e) => e.tabs.open) },
  };
}

// What is open, as the judges see it, plus each environment's deterministic fit from its own plan:
// "suyo" is what it would keep or reuse, "falta" what it would open, "sobra" what it would close.
function describe(snap, envs, active) {
  const music = (snap.player || []).map((c) => (String(c).match(/([\wÀ-ɏ-]+)\.m3u/i) || [])[1] || 'otra').join(', ');
  const state = {
    activo: active?.id || null,
    pestañas: snap.profiles.flatMap((p) => p.tabs.map((t) => ({ perfil: String(p.email).split('@')[0], sitio: siteOf(t.url), titulo: clip(t.title, 80), ...(t.audible ? { sonando: true } : {}) }))).slice(0, 120),
    apps: [...new Set(snap.procs.map((p) => p.ProcessName.toLowerCase()))].sort(),
    musica: music || null,
    servidores: Object.entries(snap.ports).filter(([, o]) => o).map(([port]) => +port).sort((a, b) => a - b),
    carpetas: snap.folders.map((f) => path.basename(f.path || f.name || '')).filter(Boolean).sort(),
    sesionesClaude: (snap.claude?.dirs || []).map((d) => path.basename(d)).sort(),
    docker: [...(snap.docker?.running || [])].sort(),
  };
  const fit = envs.map((e) => {
    const p = plan(e, snap, 'on');
    return { id: e.id, suyo: p.claimed.length + (e.devServers || []).length - p.startServers.length + (p.music && !p.music.play ? 1 : 0), falta: p.open.length + p.startServers.length + p.launch.length, sobra: p.closeTabs.length + p.apps.length };
  });
  const fingerprint = require('crypto').createHash('sha1').update(JSON.stringify([
    [...new Set(state.pestañas.map((t) => `${t.perfil}|${t.sitio}`))].sort(), state.apps, state.musica, state.servidores, state.carpetas, state.sesionesClaude, state.docker, state.activo,
  ])).digest('hex').slice(0, 16);
  return { state: { ...state, encaje: fit }, fingerprint };
}

function typesafeKey() {
  if (process.env.TYPESAFE_API_KEY) return process.env.TYPESAFE_API_KEY.trim();
  try { return fs.readFileSync(path.join(HOME, '.env'), 'utf8').match(/^\s*TYPESAFE_API_KEY\s*=\s*["']?([^"'\r\n]+)/m)?.[1].trim() || ''; } catch { return ''; }
}

const QUESTION = '¿A qué ambiente de trabajo pertenece lo que está abierto en este PC? "encaje" es lo que cada ambiente ya tiene abierto (suyo), lo que le falta y lo que cerraría (sobra).';

async function askJev(key, state, options) {
  const r = await fetch('https://api.typesafe.ai/v1/systemone', {
    method: 'POST', signal: AbortSignal.timeout(20000),
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'jev-latest', state, questions: { ambiente: { type: 'choice', instructions: QUESTION, criteria: options } } }),
  });
  if (!r.ok) throw new Error(`Jev respondió ${r.status}`);
  const a = (await r.json()).answers?.ambiente;
  if (!a?.choice) throw new Error('Jev no eligió');
  const p = a.probabilities?.[a.choice] ?? a.confidence ?? 0;
  // Jev gives no reason, only the distribution: its top three say how close the call was.
  const top = Object.entries(a.probabilities || {}).sort((x, y) => y[1] - x[1]).slice(0, 3);
  return { ambiente: a.choice, confianza: p, motivo: `probabilidades: ${top.map(([k, v]) => `${k} ${Math.round(v * 100)} %`).join(', ')}` };
}

// Claude Code's own binary (claude.exe), not the npm shims: a .cmd cannot be started without a shell.
function claudeExe() {
  for (const dir of (process.env.PATH || '').split(path.delimiter).filter(Boolean)) {
    for (const exe of [path.join(dir, 'claude.exe'), path.join(dir, 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe')]) if (fs.existsSync(exe)) return exe;
  }
  return null;
}

function askClaude(state, options) {
  const exe = claudeExe();
  if (!exe) throw new Error('no encuentro claude.exe');
  const schema = { type: 'object', additionalProperties: false, required: ['ambiente', 'confianza', 'motivo'],
    properties: { ambiente: { type: 'string', enum: Object.keys(options) }, confianza: { type: 'number', minimum: 0, maximum: 1 }, motivo: { type: 'string' } } };
  const prompt = `${JSON.stringify(state)}\n\n${QUESTION}\nAmbientes:\n${Object.entries(options).map(([k, v]) => `- ${k}: ${v}`).join('\n')}\n\nDevuelve un JSON: ambiente (uno de los ids), confianza (0 a 1) y motivo (una frase en español).`;
  // Not the user's settings, hooks or plugins (the voice would speak), no tools, nothing saved; the subscription, never API keys.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(CLAUDE_CODE_|CLAUDECODE$|CLAUDE_PID$|ANTHROPIC_)/.test(k)));
  const out = execFileSync(exe, ['-p', '--model', 'haiku', '--output-format', 'json', '--json-schema', JSON.stringify(schema), '--tools', '', '--safe-mode', '--setting-sources', 'project', '--no-session-persistence'],
    { input: prompt, cwd: RUN_DIR, env: { ...env, CLAUDEVOICE: 'off' }, encoding: 'utf8', timeout: 120000, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const res = JSON.parse(out);
  if (res.is_error) throw new Error(`claude: ${clip(String(res.result), 120)}`);
  const a = res.structured_output || JSON.parse(String(res.result).match(/\{[\s\S]*\}/)?.[0] || 'null');
  if (!a?.ambiente) throw new Error('claude no eligió');
  return a;
}

// The cascade: Jev first (fast), claude -p when Jev is missing, fails or is unsure. Returns the verdict and who gave it.
async function judge(state, options, { jev = askJev, claude = askClaude, key = typesafeKey() } = {}) {
  const notes = [];
  let verdict = null;
  if (key) {
    try { verdict = { ...(await jev(key, state, options)), juez: 'jev' }; } catch (e) { notes.push(e.message); }
  }
  if (!verdict || verdict.confianza < SURE) {
    try { verdict = { ...(await claude(state, options)), juez: 'claude' }; } catch (e) { notes.push(e.message); if (!verdict) throw new Error(notes.join(' · ')); }
  }
  return { ...verdict, notas: notes };
}

// For ClaudeMaxxing's SelfHarness tab, from the same snapshot as the detection: what the environment that is on
// would close (focus drift, with each reason) and every dev server listening (the processes some environment's
// stopServers names, or the usual ones), never the Chrome hosts.
const DEV_PROCESSES = ['node', 'python', 'python3', 'pythonw', 'py', 'uvicorn', 'deno', 'bun', 'java', 'dotnet', 'php', 'ruby', 'go'];
function focusOf(envs, snap, active, now = new Date()) {
  const env = envs.find((e) => e.id === active?.id);
  const p = env ? plan(env, snap, 'on') : null;
  const names = new Set([...DEV_PROCESSES, ...envs.flatMap((e) => e.stopServers?.processes || [])].map((n) => n.toLowerCase()));
  const known = Object.fromEntries(envs.flatMap((e) => (e.devServers || []).map((s) => [s.port, s.name])));
  const servers = (snap.listening || []).filter((l) => names.has(l.name.toLowerCase()) && !(snap.protectedPids || []).includes(l.pid))
    .map((l) => ({ port: l.port, pid: l.pid, name: l.name, label: known[l.port] || null })).sort((a, b) => a.port - b.port);
  return {
    at: now.toISOString(), active: active?.id || null,
    tabs: p ? p.closeTabs.map((t) => ({ id: t.id, title: t.title, url: t.url, profile: String(t.profile).split('@')[0], reason: t.reason })) : [],
    apps: p ? p.apps.map((a) => ({ name: a.name, pids: a.pids, reason: a.reason })) : [],
    servers,
  };
}

async function detect(flags) {
  if (status().job?.state === 'running') return { skipped: 'hay un cambio en curso' };
  const envs = listEnvs().map((e) => ({ id: e.id, ...loadEnv(e.id) }));
  const active = readJson(ACTIVE_FILE);
  const snap = await snapshot(probeOf(envs));
  writeJson(FOCUS_FILE, focusOf(envs, snap, active));
  const { state, fingerprint } = describe(snap, envs, active);
  const last = readJson(DETECT_FILE);
  if (!flags.includes('--force') && last?.fingerprint === fingerprint && !last.error) return { ...last, cached: true };
  const options = Object.fromEntries([...envs.map((e) => [e.id, `${e.name}: ${e.focus}`]), ['ninguno', 'ninguno encaja: una mezcla sin foco']]);
  const result = { at: new Date().toISOString(), fingerprint, active: active?.id || null };
  try {
    const v = await judge(state, options);
    const suggestion = envs.some((e) => e.id === v.ambiente) ? v.ambiente : null;
    const name = envs.find((e) => e.id === suggestion)?.name || null;
    Object.assign(result, { suggestion, name, confidence: v.confianza, reason: v.motivo, judge: v.juez, notes: v.notas,
      offer: !!suggestion && suggestion !== result.active && v.confianza >= SURE });
  } catch (e) {
    Object.assign(result, { suggestion: null, offer: false, error: e.message });
  }
  if (flags.includes('--state')) result.state = state;
  writeJson(DETECT_FILE, result);
  return result;
}

function status() {
  const job = readJson(JOB_FILE);
  // A job whose process died mid-way is not running: report it as interrupted.
  if (job?.state === 'running' && !alive(job.pid)) Object.assign(job, { state: 'error', message: 'el proceso se interrumpió' });
  return { active: readJson(ACTIVE_FILE), job, envs: listEnvs() };
}

async function main(argv) {
  const flags = argv.filter((a) => a.startsWith('--'));
  const [id, modeArg] = argv.filter((a) => !a.startsWith('--'));
  if (!id) throw new Error(`uso: node env.js <ambiente> [on|off] [--yes]  ·  node env.js status [--json]  (ambientes: ${listEnvs().map((e) => e.id).join(', ')})`);
  if (id === 'status') {
    const st = status();
    if (flags.includes('--json')) return console.log(JSON.stringify(st));
    console.log(st.active ? `Encendido: ${st.active.name} desde ${new Date(st.active.since).toLocaleString('es-CO')}` : 'Ningún ambiente encendido.');
    if (st.job) console.log(`Último cambio: ${st.job.action} ${st.job.name} · ${st.job.state}${st.job.message ? ` · ${st.job.message}` : ''}`);
    return;
  }
  if (id === 'detect') {
    const r = await detect(flags);
    if (flags.includes('--json')) return console.log(JSON.stringify(r));
    if (r.skipped) return console.log(`Sin detectar: ${r.skipped}.`);
    if (r.error) throw new Error(r.error);
    console.log(`${r.suggestion ? `Parece ${r.name}` : 'No encaja en ningún ambiente'} (${r.judge}${r.cached ? ', sin cambios desde la última vez' : ''}, ${Math.round((r.confidence || 0) * 100)} %): ${r.reason}`);
    if (r.offer) console.log(`Para pasarte: node env.js ${r.suggestion} on --yes`);
    return;
  }
  const mode = modeArg || 'on';
  if (!['on', 'off'].includes(mode)) throw new Error(`modo desconocido "${mode}": usa on u off`);
  const env = loadEnv(id);
  const yes = flags.includes('--yes');
  const jobbed = yes && flags.includes('--job');

  // One change at a time: two environments fighting over the same windows is never deterministic.
  const current = status().job;
  if (yes && current?.state === 'running' && current.pid !== process.pid) throw new Error(`ya hay un cambio en curso: ${current.action} ${current.name}`);
  const job = { id: id.toLowerCase(), name: env.name, action: mode, state: 'running', step: 'Leyendo lo que está abierto', message: '', pid: process.pid, startedAt: new Date().toISOString() };
  const save = () => { if (jobbed) writeJson(JOB_FILE, job); };
  save();
  try {
    const p = plan(env, await snapshot(env), mode);
    printPlan(env, p);
    if (!yes) return console.log(`\nVista previa. Para aplicarlo: node env.js ${id} ${mode} --yes`);
    console.log('\n--- aplicando');
    const report = await apply(env, p, (text) => { job.step = text; save(); console.log(`${text}…`); });
    const prev = readJson(ACTIVE_FILE);
    const now = new Date();
    writeJson(HISTORY_FILE, recordSwitch(readJson(HISTORY_FILE), prev, mode, job.id, now));
    // Turning on the one already on keeps its "since": its time keeps running.
    if (mode === 'on') writeJson(ACTIVE_FILE, { id: job.id, name: env.name, since: prev?.id === job.id && prev.since ? prev.since : now.toISOString() });
    else if (prev?.id === job.id) fs.rmSync(ACTIVE_FILE, { force: true });
    const failed = report.filter((l) => l.startsWith('NO se'));
    Object.assign(job, { state: 'done', step: '', message: failed.length ? failed.join(' · ') : '', endedAt: new Date().toISOString() });
    console.log(`\nListo: ${mode === 'on' ? `estás en ${env.name}` : `${env.name} apagado`}.`);
  } catch (e) {
    // A half-applied "on" leaves no environment fully on.
    if (yes && mode === 'on') fs.rmSync(ACTIVE_FILE, { force: true });
    Object.assign(job, { state: 'error', step: '', message: e.message, endedAt: new Date().toISOString() });
    throw e;
  } finally {
    save();
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((e) => { console.error(`error: ${e.message}`); process.exitCode = 1; });
}
module.exports = { classify, plan, isSatisfied, status, recordSwitch, describe, judge, focusOf, judgeTabs, tabsContext, loadEnv, lastDetect: () => readJson(DETECT_FILE), ENV_JS: __filename };
