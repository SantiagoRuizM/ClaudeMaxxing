// Bridges this Chrome profile's tabs to the local YourHarness host over native messaging.
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
    console.warn('YourHarness host disconnected:', chrome.runtime.lastError?.message);
    port = null;
  });
  const info = await chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' }).catch(() => ({}));
  port?.postMessage({ hello: { email: info.email || '', extensionId: chrome.runtime.id } });
}

chrome.alarms.create('keepalive', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
