#!/usr/bin/env node
// YourHarness CLI: every Chrome tab in every profile, with URL and page content; closes tabs on request.
//   node tabs.js                 list all tabs with a one-line context per tab
//   node tabs.js --json          full dump (list + content) for agents
//   node tabs.js show <id>       full content of one tab
//   node tabs.js close <id...>   close tabs by id
//   node tabs.js close <regex>   preview tabs whose title/URL match; add --yes to close them
//   node tabs.js reload          reload the extension in every profile after editing extension/
const fs = require('fs');
const path = require('path');

// Per-PC data, never in the install folder or the repo: environments\*.json, run\ (state, history, hosts) and .env.
const HOME = process.env.YOURHARNESS_HOME || path.join(require('os').homedir(), '.claude', 'usage-tray', 'harness');
const RUN_DIR = process.env.YOURHARNESS_RUN_DIR || path.join(HOME, 'run');

async function rpc(host, cmd, args) {
  const res = await fetch(`http://127.0.0.1:${host.port}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-harness-token': host.token },
    body: JSON.stringify({ cmd, args }),
    signal: AbortSignal.timeout(25000),
  });
  const body = await res.json();
  if (body.error) throw new Error(body.error);
  return body.result;
}

// One host per Chrome profile; drop run files whose host is gone.
async function hosts() {
  if (!fs.existsSync(RUN_DIR)) return [];
  const all = fs.readdirSync(RUN_DIR).filter((f) => f.endsWith('.json')).map((f) => {
    const file = path.join(RUN_DIR, f);
    try { return { file, ...JSON.parse(fs.readFileSync(file, 'utf8')) }; } catch { return null; }
  }).filter(Boolean);
  const alive = await Promise.all(all.map(async (h) => {
    try { await rpc(h, 'list'); return h; } catch (e) {
      if (e.cause?.code === 'ECONNREFUSED') fs.rmSync(h.file, { force: true });
      return null;
    }
  }));
  return alive.filter(Boolean);
}

// Tabs Chrome has not loaded (Memory Saver, restored sessions) have no DOM: read public metadata instead.
async function offlineContent(url) {
  if (!/^https?:/.test(url)) return null;
  try {
    const html = await (await fetch(url, { signal: AbortSignal.timeout(6000), headers: { 'accept-language': 'es,en' } })).text();
    const meta = (n) => html.match(new RegExp(`<meta[^>]+(?:name|property)=["']${n}["'][^>]*content=["']([^"']*)`, 'i'))?.[1] || '';
    const out = { live: false, fetched: true, title: meta('og:title'), description: meta('og:description') || meta('description') };
    const channel = html.match(/"ownerChannelName":"([^"]+)"/)?.[1];
    if (channel) out.youtube = { title: out.title, channel, description: out.description };
    return out;
  } catch {
    return null;
  }
}

async function collect({ max }) {
  const out = [];
  for (const h of await hosts()) {
    const tabs = await rpc(h, 'list');
    const content = await rpc(h, 'content', { ids: tabs.map((t) => t.id), max });
    const byId = Object.fromEntries(content.map((c) => [c.id, c]));
    await Promise.all(tabs.map(async (t) => {
      const c = byId[t.id] || {};
      t.content = c.live ? c : (await offlineContent(t.url)) || c;
    }));
    out.push({ host: h, profile: h.email || `pid ${h.pid}`, tabs });
  }
  return out;
}

const clip = (s, n) => (s = String(s || '').replace(/\s+/g, ' ').trim()).length > n ? `${s.slice(0, n - 1)}…` : s;
const mmss = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

function context(t) {
  const c = t.content || {};
  const yt = c.youtube;
  const parts = [];
  // YouTube Music keeps a generic tab title, so the song only shows up here.
  const song = yt?.title && !t.title.includes(yt.title) ? `${yt.title} — ` : '';
  if (yt) parts.push(`YouTube · ${song}${yt.channel || '?'}${yt.ad ? ' · anuncio' : ''}`);
  if (c.media) parts.push(`${c.media.paused ? 'pausado' : 'reproduciendo'} ${mmss(c.media.currentTime)}/${mmss(c.media.duration)}`);
  // Live text beats meta descriptions: SPAs (Gmail, WhatsApp, Claude) keep a generic one.
  parts.push(clip(yt?.description || (c.live && c.text) || c.description, 160));
  if (!c.live) parts.push(c.fetched ? '(no cargada: metadata pública)' : '(no cargada)');
  return parts.filter(Boolean).join(' · ').replace(/\s+/g, ' ');
}

function printList(profiles) {
  if (!profiles.length) {
    console.log('No hay perfiles conectados. ¿Está Chrome abierto y la extensión YourHarness cargada? (ver README)');
    return;
  }
  for (const p of profiles) {
    console.log(`\n== Perfil ${p.profile} (${p.tabs.length} pestañas)`);
    const windows = Map.groupBy(p.tabs, (t) => t.windowId);
    for (const [wid, tabs] of windows) {
      console.log(`  -- ventana ${wid}${tabs[0].windowFocused ? ' (enfocada)' : ''}`);
      for (const t of tabs.sort((a, b) => a.index - b.index)) {
        const flags = [t.active && 'ACTIVA', t.audible && 'SONANDO', t.pinned && 'fijada', t.group && `grupo:${t.group}`].filter(Boolean).join(',');
        console.log(`  [${t.id}] ${clip(t.title, 90)}${flags ? `  <${flags}>` : ''}`);
        console.log(`        ${clip(t.url, 110)}`);
        const ctx = context(t);
        if (ctx) console.log(`        ${ctx}`);
      }
    }
  }
}

async function findTab(id) {
  for (const h of await hosts()) {
    const tab = (await rpc(h, 'list')).find((t) => t.id === id);
    if (tab) return { host: h, tab };
  }
  return null;
}

async function close(args) {
  const yes = args.includes('--yes');
  const rest = args.filter((a) => a !== '--yes');
  if (!rest.length) throw new Error('uso: close <id...> | close <regex> [--yes]');
  const byIds = rest.every((a) => /^\d+$/.test(a));
  const re = byIds ? null : new RegExp(rest.join(' '), 'i');
  const ids = byIds ? rest.map(Number) : null;
  let total = 0;
  for (const h of await hosts()) {
    const tabs = (await rpc(h, 'list')).filter((t) => (ids ? ids.includes(t.id) : re.test(t.title) || re.test(t.url)));
    if (!tabs.length) continue;
    const failed = ids || yes ? (await rpc(h, 'close', { ids: tabs.map((t) => t.id) })).failed || [] : [];
    for (const t of tabs) {
      const f = failed.find((x) => x.id === t.id);
      console.log(`${re && !yes ? 'cerraría' : f ? `NO se cerró (${f.error})` : 'cerrada'} [${t.id}] ${clip(t.title, 90)} — ${clip(t.url, 80)}`);
    }
    total += tabs.length;
  }
  if (!total) console.log('Ninguna pestaña coincide.');
  else if (re && !yes) console.log(`\n${total} pestaña(s) coinciden. Repite con --yes para cerrarlas.`);
  else console.log('\nSe pueden recuperar con Ctrl+Shift+T o desde el historial.');
}

async function main(argv) {
  const [cmd, ...args] = argv;
  if (!cmd || cmd === 'list') return printList(await collect({ max: 600 }));
  if (cmd === '--json') return console.log(JSON.stringify((await collect({ max: 4000 })).map(({ host, ...p }) => p), null, 2));
  if (cmd === 'show') {
    const found = await findTab(Number(args[0]));
    if (!found) throw new Error(`no existe la pestaña ${args[0]}`);
    const [c] = await rpc(found.host, 'content', { ids: [found.tab.id], max: 20000 });
    const content = c.live ? c : (await offlineContent(found.tab.url)) || c;
    return console.log(JSON.stringify({ ...found.tab, content }, null, 2));
  }
  if (cmd === 'close') return close(args);
  if (cmd === 'reload') {
    for (const h of await hosts()) await rpc(h, 'reload');
    return console.log('Extensión recargada en todos los perfiles.');
  }
  throw new Error(`comando desconocido: ${cmd}`);
}

if (require.main === module) {
  // exitCode, not exit(): exiting with fetch sockets open trips a libuv assertion on Windows.
  main(process.argv.slice(2)).catch((e) => { console.error(`error: ${e.message}`); process.exitCode = 1; });
}
module.exports = { main, hosts, rpc, collect, clip, context };
