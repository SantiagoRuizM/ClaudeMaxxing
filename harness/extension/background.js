// ClaudeMaxxing in Chrome: bridges this profile's tabs to the local host over native messaging (for env.js and the
// tray) and, the other way, shows the environment on, its badge, a nudge when a page is off focus and the popup.
// An open native port keeps the service worker alive; the alarm revives it if the host dies.
const HOST = 'com.yourharness.bridge';
let port = null;

// Runs inside the page: must be self-contained.
function extract(max) {
  const meta = (n) => document.querySelector(`meta[name="${n}"],meta[property="${n}"]`)?.content || '';
  const out = { description: meta('description') || meta('og:description') };
  const v = document.querySelector('video');
  if (v && Number.isFinite(v.duration)) {
    out.media = { currentTime: Math.round(v.currentTime), duration: Math.round(v.duration), paused: v.paused };
  }
  const txt = (s) => document.querySelector(s)?.innerText?.trim() || '';
  if (location.hostname === 'music.youtube.com') {
    out.youtube = { title: txt('ytmusic-player-bar .title'), channel: txt('ytmusic-player-bar .byline'), description: '' };
  } else if (location.hostname.endsWith('youtube.com') && location.pathname === '/watch') {
    // YouTube is an SPA: meta tags go stale after in-app navigation, the DOM does not.
    out.youtube = {
      title: txt('ytd-watch-metadata h1') || document.title,
      channel: txt('ytd-watch-metadata #owner #channel-name a') || txt('#owner #channel-name'),
      description: txt('ytd-watch-metadata #description-inline-expander').slice(0, 1500),
    };
    // Hidden tabs never load the <video>; the player controls still know time and state.
    const player = document.querySelector('#movie_player');
    const secs = (s) => (document.querySelector(s)?.textContent || '').split(':').reduce((a, x) => a * 60 + Number(x), 0);
    if (!out.media && player && secs('.ytp-time-duration')) {
      out.media = { currentTime: secs('.ytp-time-current'), duration: secs('.ytp-time-duration'), paused: !player.classList.contains('playing-mode') || player.classList.contains('unstarted-mode') };
    }
    if (player?.classList.contains('ad-showing')) out.youtube.ad = true;
  }
  const root = document.querySelector('main, article, [role="main"]') || document.body; // skip nav/menus when the page marks its content
  out.text = (root?.innerText || '').replace(/\n\s*\n+/g, '\n').slice(0, max);
  return out;
}

const EDITORS = /^https:\/\/docs\.google\.com\//;

// Runs in the page's MAIN world so it reaches the page's own beforeunload handlers.
function silence() {
  document.querySelectorAll('video, audio').forEach((m) => m.pause());
  window.onbeforeunload = null;
  // Capture listeners run first at the target: stop the page's own handlers from asking.
  window.addEventListener('beforeunload', (e) => e.stopImmediatePropagation(), true);
}

const withTimeout =(p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms))]);

const handlers = {
  async list() {
    const [tabs, groups, wins] = await Promise.all([
      chrome.tabs.query({}), chrome.tabGroups.query({}), chrome.windows.getAll(),
    ]);
    const groupName = Object.fromEntries(groups.map((g) => [g.id, g.title || g.color]));
    const focused = wins.find((w) => w.focused)?.id;
    return tabs.map((t) => ({
      id: t.id, windowId: t.windowId, windowFocused: t.windowId === focused, index: t.index,
      active: t.active, pinned: t.pinned, audible: !!t.audible, muted: !!t.mutedInfo?.muted,
      discarded: t.discarded, status: t.status, incognito: t.incognito,
      title: t.title, url: t.url || t.pendingUrl || '', group: groupName[t.groupId] ?? null,
      lastAccessed: t.lastAccessed,
    }));
  },

  async content({ ids, max = 4000 }) {
    return Promise.all(ids.map(async (id) => {
      try {
        const tab = await chrome.tabs.get(id);
        if (tab.discarded || tab.status === 'unloaded' || !/^(https?|file):/.test(tab.url || '')) return { id, live: false };
        const [r] = await withTimeout(chrome.scripting.executeScript({ target: { tabId: id }, func: extract, args: [max] }), 4000);
        return { id, live: true, ...r.result };
      } catch (e) {
        return { id, live: false, error: String(e.message || e) };
      }
    }));
  },

  // Players (YouTube Music, video sites) answer a close with a "Leave site?" prompt, which leaves
  // tabs.remove pending forever. Silence the page first; if it still hangs, discard (no prompt) and retry.
  async close({ ids }) {
    const results = await Promise.all(ids.map(async (id) => {
      // Editors only prompt when there are unsaved changes: never silence or discard them.
      const { url = '' } = await chrome.tabs.get(id).catch(() => ({}));
      if (EDITORS.test(url)) {
        try {
          await withTimeout(chrome.tabs.remove(id), 4000);
          return { id, closed: true };
        } catch {
          return { id, closed: false, error: 'tiene cambios sin guardar: ciérrala tú' };
        }
      }
      await withTimeout(chrome.scripting.executeScript({ target: { tabId: id }, world: 'MAIN', func: silence }), 2000).catch(() => {});
      try {
        await withTimeout(chrome.tabs.remove(id), 3000);
        return { id, closed: true };
      } catch {
        try {
          const discarded = await chrome.tabs.discard(id);
          await withTimeout(chrome.tabs.remove(discarded?.id ?? id), 3000);
          return { id, closed: true, forced: true };
        } catch (e) {
          return { id, closed: false, error: String(e.message || e) };
        }
      }
    }));
    return { closed: results.filter((r) => r.closed).map((r) => r.id), failed: results.filter((r) => !r.closed) };
  },

  // Picks up code changes on disk without visiting chrome://extensions.
  async reload() {
    setTimeout(() => chrome.runtime.reload(), 100);
    return { reloading: true };
  },
};

async function connect() {
  if (port) return;
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener(async (msg) => {
    // An answer to something this extension asked (ask below), not a command from the host.
    if (msg.req) { asks.get(msg.req)?.(msg); asks.delete(msg.req); return; }
    let reply;
    try {
      const fn = handlers[msg.cmd];
      if (!fn) throw new Error(`unknown cmd ${msg.cmd}`);
      reply = { id: msg.id, result: await fn(msg.args || {}) };
    } catch (e) {
      reply = { id: msg.id, error: String(e.message || e) };
    }
    port?.postMessage(reply);
  });
  port.onDisconnect.addListener(() => {
    console.warn('ClaudeMaxxing host disconnected:', chrome.runtime.lastError?.message);
    port = null;
  });
  const info = await chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' }).catch(() => ({}));
  profileEmail = info.email || '';
  port?.postMessage({ hello: { email: profileEmail, extensionId: chrome.runtime.id } });
}

// ---------------------------------------------------------------- ClaudeMaxxing in Chrome
// The extension asks the host ({ req, ask, args } -> { req, result | error }; see host/api.js): the popup's state,
// this profile's tabs judged against the environment on (badge, nudge, popup) and switching environment.
const asks = new Map();
let nextReq = 1;
let profileEmail = '';

async function ask(what, args = {}, ms = 8000) {
  await connect();
  if (!port) throw new Error('sin conexión con ClaudeMaxxing');
  return new Promise((resolve, reject) => {
    const req = nextReq++;
    const timer = setTimeout(() => { asks.delete(req); reject(new Error('ClaudeMaxxing no respondió')); }, ms);
    asks.set(req, (msg) => { clearTimeout(timer); if (msg.error) reject(new Error(msg.error)); else resolve(msg.result); });
    port.postMessage({ req, ask: what, args });
  });
}

const tabInfo = (t) => ({ id: t.id, title: t.title || '', url: t.url || t.pendingUrl || '' });
const judgeProfile = async () => ask('judge', { tabs: (await chrome.tabs.query({})).filter((t) => !t.incognito).map(tabInfo), email: profileEmail });

// Badge: how many of this profile's tabs the environment on would close. Debounced: tab events come in bursts.
let badgeTimer = null;
function refreshBadge() {
  clearTimeout(badgeTimer);
  badgeTimer = setTimeout(async () => {
    try {
      const r = await judgeProfile();
      const n = r.active ? r.tabs.filter((t) => t.action === 'close').length : 0;
      await chrome.action.setBadgeBackgroundColor({ color: '#D97757' });
      await chrome.action.setBadgeText({ text: n ? String(n) : '' });
      await chrome.action.setTitle({ title: r.active ? `ClaudeMaxxing · ${r.active.name}${n ? ` · ${n} fuera de foco` : ''}` : 'ClaudeMaxxing · ningún ambiente encendido' });
    } catch {
      await chrome.action.setBadgeText({ text: '' });
      await chrome.action.setTitle({ title: 'ClaudeMaxxing · sin conexión (¿está instalado?)' });
    }
  }, 1500);
}

// Runs inside the page (isolated world): a small bar, in a shadow root so the page's CSS cannot reach it.
function banner(envName, reason, key) {
  if (document.getElementById('claudemaxxing-nudge')) return;
  const host = document.createElement('div');
  host.id = 'claudemaxxing-nudge';
  host.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `<style>
    .bar{font:13px/1.35 system-ui,'Segoe UI',sans-serif;background:#1f1e1d;color:#f5f4ef;border:1px solid #3a3836;border-left:4px solid #D97757;
      border-radius:10px;padding:10px 12px;max-width:360px;box-shadow:0 6px 24px rgba(0,0,0,.35);display:flex;flex-direction:column;gap:8px}
    b{color:#D97757;font-weight:600} small{color:#a3a29d}
    .row{display:flex;gap:8px;justify-content:flex-end}
    button{font:inherit;border-radius:7px;padding:4px 10px;cursor:pointer;border:1px solid #3a3836;background:#2a2927;color:#f5f4ef}
    button.go{background:#D97757;border-color:#D97757;color:#1f1e1d;font-weight:600}
    button:focus-visible{outline:2px solid #D97757;outline-offset:2px}</style>
    <div class="bar" role="alert"><div><b>ClaudeMaxxing</b> · Esto no es de ${envName.replace(/</g, '&lt;')}<br><small></small></div>
    <div class="row"><button class="keep">Mantener</button><button class="go">Cerrar pestaña</button></div></div>`;
  root.querySelector('small').textContent = reason;
  const done = (what) => { chrome.runtime.sendMessage({ cmx: what, key }); host.remove(); };
  root.querySelector('.keep').onclick = () => done('keep');
  root.querySelector('.go').onclick = () => done('closeSelf');
  document.documentElement.appendChild(host);
}

// Nudge: when the tab you are on finishes loading a page the environment on would close, say so in the page.
// "Mantener" quiets it for that tab and site until the browser closes. Duplicates of the environment's own tabs
// are left to the badge and the popup.
async function nudge(tab) {
  if (!tab?.active || !/^https?:/.test(tab.url || '')) return;
  const { nudges = true } = await chrome.storage.local.get('nudges');
  if (!nudges) return;
  const key = `${tab.id}|${new URL(tab.url).host}`;
  const { kept = [] } = await chrome.storage.session.get('kept');
  if (kept.includes(key)) return;
  const [content] = await handlers.content({ ids: [tab.id], max: 0 }); // YouTube title and channel decide like env.js
  let r;
  try { r = await ask('judge', { tabs: [{ ...tabInfo(tab), content }], email: profileEmail }); } catch { return; }
  const j = r.active && r.tabs[0];
  if (!j || j.action !== 'close' || j.reason.startsWith('duplicado')) return;
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: banner, args: [r.active.name, j.reason, key] }).catch(() => {});
}

chrome.tabs.onUpdated.addListener((id, change, tab) => {
  if (change.status === 'complete') nudge(tab);
  if (change.url || change.title || change.status === 'complete') refreshBadge();
});
chrome.tabs.onCreated.addListener(refreshBadge);
chrome.tabs.onRemoved.addListener(refreshBadge);

// The page's bar and the popup talk to this worker; the popup cannot reach the native port itself.
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const run = {
    async keep() {
      const { kept = [] } = await chrome.storage.session.get('kept');
      await chrome.storage.session.set({ kept: [...kept, msg.key].slice(-200) });
    },
    async closeSelf() { await handlers.close({ ids: [sender.tab.id] }); },
    async popup() {
      const [state, judged] = await Promise.all([ask('state'), judgeProfile().catch(() => null)]);
      const tabs = await chrome.tabs.query({});
      const byId = Object.fromEntries(tabs.map((t) => [t.id, t]));
      const drift = (judged?.tabs || []).filter((t) => t.action === 'close' && byId[t.id]).map((t) => ({ ...t, title: byId[t.id].title, url: byId[t.id].url }));
      const { nudges = true } = await chrome.storage.local.get('nudges');
      return { state, drift, nudges, email: profileEmail };
    },
    async closeTabs() { const r = await handlers.close({ ids: msg.ids }); refreshBadge(); return r; },
    async switch() { return ask('switch', { id: msg.id }); },
    async nudges() { await chrome.storage.local.set({ nudges: !!msg.on }); },
  }[msg.cmx];
  if (!run) return false;
  run().then((result) => reply({ result }), (e) => reply({ error: String(e.message || e) }));
  return true; // answered asynchronously
});

chrome.alarms.create('keepalive', { periodInMinutes: 1 });
// The alarm also refreshes the badge: the environment may have changed from the tray or the CLI.
chrome.alarms.onAlarm.addListener(() => { connect(); refreshBadge(); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect().then(refreshBadge);
