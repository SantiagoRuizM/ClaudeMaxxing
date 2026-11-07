// What the ClaudeMaxxing extension asks its host (the other direction from the CLI's commands): the state its popup
// shows, a judgment of this profile's tabs against the environment that is on (badge, nudge, popup) and switching
// environment. Reads the same per-PC files as env.js and the tray; nothing here writes to stdout.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const harness = require('../env');

const TRAY_HOME = path.join(os.homedir(), '.claude', 'usage-tray');
const readJson = (file) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };

// The plan's two windows from ClaudeMaxxing's statusline snapshot. Claude Code keeps a window's last values after it
// resets, so a window whose reset time has passed is not shown (the tray does the same).
function usageView(snapshot, nowSeconds) {
  const view = (w) => (w && w.resets_at > nowSeconds ? { pct: Math.round(w.used_percentage || 0), resetsAt: w.resets_at } : null);
  const limits = snapshot?.rate_limits || {};
  return { session: view(limits.five_hour), weekly: view(limits.seven_day) };
}

const handlers = {
  state() {
    const st = harness.status();
    return {
      active: st.active, job: st.job, envs: st.envs,
      detect: harness.lastDetect(),
      usage: usageView(readJson(path.join(TRAY_HOME, 'usage.json')), Date.now() / 1000),
    };
  },

  judge({ tabs = [], email = '' }) {
    const active = harness.status().active;
    if (!active) return { active: null, tabs: [] };
    const env = harness.loadEnv(active.id);
    return { active, tabs: harness.judgeTabs(env, tabs, { email, ...harness.tabsContext(env) }) };
  },

  // The same command the tray runs; env.js itself refuses a second change while one is running.
  switch({ id }) {
    const st = harness.status();
    if (!/^[a-z0-9_-]+$/.test(String(id)) || !st.envs.some((e) => e.id === id)) throw new Error(`no existe el ambiente "${id}"`);
    if (st.job?.state === 'running') throw new Error(`ya hay un cambio en curso: ${st.job.action} ${st.job.name}`);
    spawn(process.execPath, [harness.ENV_JS, id, 'on', '--yes', '--job'], { cwd: path.dirname(harness.ENV_JS), detached: true, stdio: 'ignore', windowsHide: true }).unref();
    return { started: id };
  },
};

async function handle(ask, args) {
  const fn = handlers[ask];
  if (!fn) throw new Error(`pregunta desconocida: ${ask}`);
  return fn(args || {});
}

module.exports = { handle, usageView };
