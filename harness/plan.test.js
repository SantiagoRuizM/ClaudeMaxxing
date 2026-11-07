// Every case of turning environments on and off, on simulated machines: plan() is pure, so a snapshot
// in gives the same actions out, with no Chrome, Docker or Windows involved. Run through test.js.
// test/environments: copies of real environments with made-up emails, paths and URLs (the real ones are per PC).
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { plan, isSatisfied, recordSwitch, describe, judge, focusOf } = require('./env');

const load = (id) => JSON.parse(fs.readFileSync(path.join(__dirname, 'test', 'environments', `${id}.json`), 'utf8'));
const G = load('trabajo');
const D = load('atlas');
const S = load('startday');
const LABORAL = 'work@example.com';
const PERSONAL = 'personal@example.com';
const TRABAJO_DIR = 'C:\\Users\\me\\Documents\\Projects\\Trabajo';
const LAUNCHER = 'open-session.ps1 -Dir %1';
const LIBRO1 = D.tabs.open.find((o) => o.name.startsWith('Libro 1')).gdoc;
const LIBRO2 = D.tabs.open.find((o) => o.name.startsWith('Libro 2')).gdoc;

let nextId = 1;
const tab = (title, url, extra = {}) => ({ id: nextId++, windowId: 1, index: nextId, title, url, ...extra });
const profile = (email, ...tabs) => ({ email, host: { email }, tabs });
const machine = (over = {}) => ({
  profiles: [], emails: { 'Profile 7': LABORAL, 'Profile 1': PERSONAL }, folders: [], procs: [], ports: {},
  docker: { up: true, running: [] }, gdocs: { [LIBRO1]: 'doc1', [LIBRO2]: 'doc2' }, claude: { launcher: LAUNCHER, dirs: [] }, playerOpen: false, ...over,
});
const vite = { ProcessId: 500, Name: 'node.exe' };
// wmplayer's command line: it names the playlist an environment started it with.
const playing = (id) => `"C:\\Program Files\\Windows Media Player\\wmplayer.exe" C:\\YourHarness\\run\\${id}.m3u`;
const cliente = ['cliente-cliente-1', 'cliente-workers-1', 'cliente-beat-1', 'cliente-redis-1', 'cliente-cliente_db_service-1'];
const names = (tabs) => tabs.map((t) => t.title).sort();
const cases = [];
const it = (name, fn) => cases.push([name, fn]);

it('Trabajo on, from nothing: opens everything, closes nothing, says it cannot see Laboral', () => {
  const p = plan(G, machine({ docker: { up: false, running: [] } }));
  assert.equal(p.closeTabs.length, 0);
  assert.ok(p.openFolder);
  assert.deepEqual(p.music, { folder: G.music.folder, match: undefined, play: true });
  assert.deepEqual([p.docker.kind, p.docker.startDesktop], ['up', true]);
  assert.deepEqual(p.startServers.map((s) => s.port), [5173]);
  assert.deepEqual(p.open.map((o) => o.name), ['Django Admin', 'Frontend', 'GitHub PRs', 'GitHub Actions', 'AWS', 'Producción']);
  assert.ok(p.open.every((o) => o.profile === 'Profile 7'));
  assert.deepEqual(p.claude, { dir: G.claude.dir, launcher: LAUNCHER });
  assert.ok(p.warnings.some((w) => w.includes('work')));
  assert.ok(!isSatisfied(p));
});

it('Trabajo on when already on: nothing to do (idempotent)', () => {
  const snap = machine({
    profiles: [profile(LABORAL, tab('Site administration', 'http://localhost:8000/api/v1/admin/'), tab('Trabajo', 'http://localhost:5173/dashboard'),
      tab('Pull requests', 'https://github.com/example-org/Cliente/pulls'), tab('Actions', 'https://github.com/example-org/Cliente/actions/runs/1'),
      tab('AWS Console', 'https://us-east-1.console.aws.amazon.com/ecs/v2/home'), tab('Trabajo', 'https://app.example.com/work-orders'))],
    folders: [{ hwnd: 1, path: TRABAJO_DIR }], procs: [{ Id: 9, ProcessName: 'wmplayer' }], player: [playing('trabajo')],
    claude: { launcher: LAUNCHER, dirs: [G.claude.dir.toLowerCase()] },
    ports: { 5173: vite }, docker: { up: true, running: cliente },
  });
  const p = plan(G, snap);
  assert.ok(isSatisfied(p), JSON.stringify(p, null, 1));
  // Deterministic: the same snapshot always gives the same plan.
  assert.equal(JSON.stringify(plan(G, snap)), JSON.stringify(p));
});

it('Duplicates: the first tab of each item stays, the copies close', () => {
  const p = plan(G, machine({ profiles: [profile(LABORAL, tab('Admin A', 'http://localhost:8000/api/v1/admin/'), tab('Admin B', 'http://localhost:8000/api/v1/admin/'))] }));
  assert.deepEqual(names(p.closeTabs), ['Admin B']);
  assert.match(p.closeTabs[0].reason, /duplicado de "Django Admin"/);
  assert.ok(!p.open.some((o) => o.name === 'Django Admin'));
});

it('Trabajo closes the whole Personal profile, even what would stay elsewhere', () => {
  const p = plan(G, machine({ profiles: [profile(PERSONAL, tab('Tablero', 'http://localhost:5180/'), tab('Extensiones', 'chrome://extensions/'))] }));
  assert.deepEqual(names(p.closeTabs), ['Extensiones', 'Tablero']);
});

it('Content decides: an API video stays, MrBeast goes, other music goes', () => {
  const yt = (title, channel) => tab(title, 'https://www.youtube.com/watch?v=1', { content: { live: true, youtube: { title, channel } } });
  const p = plan(G, machine({ profiles: [profile(LABORAL, yt('Cómo crear APIs con Django', 'Dev'), yt('I Survived 7 Days', 'MrBeast'), tab('Lofi | YouTube Music', 'https://music.youtube.com/watch?v=2'))] }));
  assert.deepEqual(names(p.closeTabs), ['I Survived 7 Days', 'Lofi | YouTube Music']);
});

it('StartDay: Gmail in Laboral does not count as Gmail in Personal', () => {
  const p = plan(S, machine({ profiles: [profile(LABORAL, tab('Gmail', 'https://mail.google.com/mail/u/0/#inbox')), profile(PERSONAL)] }));
  assert.deepEqual(p.open.map((o) => `${o.name}@${o.profile}`).sort(), ['Calendario@Profile 7', 'Claude@Profile 1', 'Claude@Profile 7', 'Gmail@Profile 1', 'WhatsApp@Profile 1']);
  assert.equal(p.closeTabs.length, 0);
});

it('StartDay closes everything else, every folder, and opens none', () => {
  const p = plan(S, machine({
    profiles: [profile(LABORAL, tab('Admin', 'http://localhost:8000/api/v1/admin/')), profile(PERSONAL, tab('Tablero', 'http://localhost:5180/'))],
    folders: [{ hwnd: 1, path: TRABAJO_DIR }, { hwnd: 2, path: 'C:\\Users\\me\\Music\\Brain' }],
  }));
  assert.deepEqual(names(p.closeTabs), ['Admin', 'Tablero']);
  assert.equal(p.closeFolders.length, 2);
  assert.ok(!p.openFolder);
});

it('Atlas: Docker stops gently and Desktop quits only if no other project runs', () => {
  const alone = plan(D, machine({ docker: { up: true, running: cliente } })).docker;
  assert.deepEqual([alone.kind, alone.containers, alone.quit, alone.timeout], ['stop', 5, true, 30]);
  const shared = plan(D, machine({ docker: { up: true, running: [...cliente, 'franquix-api-1'] } })).docker;
  assert.deepEqual([shared.quit, shared.others], [false, 1]);
  assert.equal(plan(D, machine({ docker: { up: false, running: [] } })).docker, null);
});

it('Atlas: a missing gdoc is a warning, the rest still opens', () => {
  const p = plan(D, machine({ gdocs: { [LIBRO1]: 'doc1', [LIBRO2]: null } }));
  assert.ok(p.warnings.some((w) => w.includes('Libro 2')));
  assert.deepEqual(p.open.map((o) => o.name), ['Tablero', 'Libro 1. Primero', 'Música del Atlas']);
  assert.equal(p.open[1].url, 'https://docs.google.com/document/d/doc1/edit');
});

it('Atlas: stops Trabajo\'s Vite only when it is listening', () => {
  assert.deepEqual(plan(D, machine({ ports: { 5173: vite } })).stopPorts.map((s) => s.port), [5173]);
  assert.deepEqual(plan(D, machine({ ports: { 5173: null } })).stopPorts, []);
});

it('Atlas: its playlist survives "close other music"; Tablero running is reused', () => {
  const p = plan(D, machine({
    profiles: [profile(PERSONAL, tab('For Writting', 'https://music.youtube.com/playlist?list=PLexamplePlaylist0000'), tab('HANDS 1977', 'https://music.youtube.com/watch?v=x&list=OTHER'))],
    ports: { 5180: { ProcessId: 77, Name: 'node.exe' } },
  }));
  assert.deepEqual(names(p.closeTabs), ['HANDS 1977']);
  assert.equal(p.startServers.length, 0);
  assert.ok(!p.open.some((o) => o.name === 'Música del Atlas'));
});

it('Switching Atlas -> Trabajo closes Atlas\'s tabs but never its Tablero server', () => {
  const p = plan(G, machine({
    profiles: [profile(PERSONAL, tab('Tablero del Modulo', 'http://localhost:5180/'), tab('Libro 2', 'https://docs.google.com/document/d/doc2/edit'))],
    ports: { 5180: { ProcessId: 77, Name: 'node.exe' } },
  }));
  assert.equal(p.closeTabs.length, 2);
  assert.equal(p.stopPorts.length, 0);
});

it('Trabajo off: closes only what it owns', () => {
  const p = plan(G, machine({
    profiles: [profile(LABORAL, tab('Admin', 'http://localhost:8000/api/v1/admin/'), tab('Front', 'http://localhost:5173/'), tab('Calendario', 'https://calendar.google.com/'))],
    folders: [{ hwnd: 1, path: TRABAJO_DIR }, { hwnd: 2, path: 'C:\\Users\\me\\Downloads' }],
    procs: [{ Id: 9, ProcessName: 'wmplayer' }], playerOpen: true, ports: { 5173: vite }, docker: { up: true, running: cliente },
  }), 'off');
  assert.deepEqual(names(p.closeTabs), ['Admin', 'Front']);
  assert.deepEqual(p.closeFolders.map((f) => f.hwnd), [1]);
  assert.deepEqual(p.apps.map((a) => a.name), ['wmplayer']);
  assert.deepEqual(p.stopPorts.map((s) => s.port), [5173]);
  assert.deepEqual([p.docker.kind, p.docker.containers, p.docker.quit], ['stop', 5, true]);
  assert.equal(p.open.length + p.startServers.length, 0);
  assert.ok(!p.openFolder && !p.music);
});

it('Off when nothing of it is on: nothing to do', () => {
  assert.ok(isSatisfied(plan(G, machine({ docker: { up: false, running: [] } }), 'off')));
  assert.ok(isSatisfied(plan(S, machine({ profiles: [profile(LABORAL, tab('Docs', 'https://example.com'))] }), 'off')));
});

it('Atlas off never starts Docker and stops its Tablero', () => {
  const p = plan(D, machine({ docker: { up: false, running: [] }, ports: { 5180: { ProcessId: 77, Name: 'node.exe' } } }), 'off');
  assert.equal(p.docker, null);
  assert.deepEqual(p.stopPorts.map((s) => s.port), [5180]);
});

it('Trabajo keeps its GitHub, AWS and prod tabs even when they do not mention the stack', () => {
  const p = plan(G, machine({ profiles: [profile(LABORAL, tab('Issues', 'https://github.com/example-org/TrabajoMobileApp/issues'), tab('Billing', 'https://console.aws.amazon.com/billing/home'), tab('Inicio', 'https://app.sandbox.example.com/'))] }));
  assert.equal(p.closeTabs.length, 0);
});

it('Claude Code: no launcher is a warning; off and environments without it never open one', () => {
  const p = plan(G, machine({ claude: { launcher: null, dirs: [] } }));
  assert.equal(p.claude, null);
  assert.ok(p.warnings.some((w) => w.includes('lanzador de Claude Code')));
  assert.equal(plan(G, machine(), 'off').claude, null);
  assert.equal(plan(D, machine()).claude, null);
});

it('A profile that does not exist in Chrome is a warning, not a crash', () => {
  const p = plan(S, machine({ emails: { 'Profile 7': LABORAL } }));
  assert.ok(p.warnings.some((w) => w.includes('"Profile 1" no existe')));
});

const GAMING = load('gaming');
const VACIO = load('vacio');
const END = load('endday');
const HOST_PID = 4242;
const listening = [{ port: 5173, pid: 500, name: 'node' }, { port: 8765, pid: 600, name: 'python' }, { port: 55001, pid: HOST_PID, name: 'node' }, { port: 5432, pid: 700, name: 'postgres' }];

it('StartDay plays only Clair de Lune: other music closes first, its own keeps playing', () => {
  const p = plan(S, machine({ procs: [{ Id: 9, ProcessName: 'wmplayer' }], player: [playing('trabajo')] }));
  assert.deepEqual(p.music, { folder: S.music.folder, match: 'Clair de Lune', play: true });
  assert.deepEqual(p.apps.map((a) => [a.name, a.pids]), [['wmplayer', [9]]]);
  const again = plan(S, machine({ procs: [{ Id: 9, ProcessName: 'wmplayer' }], player: [playing('startday')] }));
  assert.equal(again.music.play, false);
  assert.equal(again.apps.length, 0);
});

it('Gaming opens Steam once, closes every tab and stops every dev server but YourHarness hosts', () => {
  const p = plan(GAMING, machine({
    profiles: [profile(LABORAL, tab('Admin', 'http://localhost:8000/')), profile(PERSONAL, tab('Gmail', 'https://mail.google.com/'))],
    listening, protectedPids: [HOST_PID], procs: [{ Id: 31, ProcessName: 'vmmemWSL' }], docker: { up: true, running: [...cliente, 'franquix-api-1'] },
  }));
  assert.deepEqual(p.launch.map((a) => a.name), ['Steam']);
  assert.deepEqual(names(p.closeTabs), ['Admin', 'Gmail']);
  assert.match(p.closeTabs[0].reason, /Gaming/);
  assert.deepEqual(p.stopPorts.map((s) => s.port), [5173, 8765]);
  assert.deepEqual([p.docker.containers, p.docker.quit, p.docker.names.length], [6, true, 6]);
  assert.ok(p.wsl);
  const running = plan(GAMING, machine({ procs: [{ Id: 40, ProcessName: 'steam' }], docker: { up: false, running: [] } }));
  assert.equal(running.launch.length, 0);
  assert.ok(isSatisfied(running));
  assert.deepEqual(plan(GAMING, machine({ procs: [{ Id: 40, ProcessName: 'steam' }] }), 'off').apps.map((a) => a.name), ['steam']);
});

it('Vacío: nothing left means nothing to do; WSL only when its VM runs', () => {
  const empty = plan(VACIO, machine({ docker: { up: false, running: [] }, listening: [{ port: 55001, pid: HOST_PID, name: 'node' }], protectedPids: [HOST_PID] }));
  assert.ok(isSatisfied(empty), JSON.stringify(empty));
  assert.equal(empty.wsl, false);
  const p = plan(VACIO, machine({ procs: [{ Id: 40, ProcessName: 'steam' }, { Id: 31, ProcessName: 'vmmem' }], listening }));
  assert.deepEqual(p.apps.map((a) => a.name), ['steam']);
  assert.ok(p.wsl);
  assert.deepEqual(plan(VACIO, machine(), 'off').stopPorts, []);
});

it('EndDay closes Laboral and work tabs, keeps the personal ones', () => {
  const p = plan(END, machine({ profiles: [profile(LABORAL, tab('Calendar', 'https://calendar.google.com/')), profile(PERSONAL, tab('Claude', 'https://claude.ai/chat/1'), tab('Netflix', 'https://www.netflix.com/'), tab('Tablero', 'http://localhost:5180/'))] }));
  assert.deepEqual(names(p.closeTabs), ['Calendar', 'Claude', 'Tablero']);
  assert.equal(p.open.length, 0);
});

it('History: switches are counted between any two environments, time per environment, through an off too', () => {
  const t = (h, m = 0) => new Date(2026, 10, 7, h, m);
  let h = recordSwitch(null, null, 'on', 'startday', t(8));
  assert.deepEqual(h.edges, {});
  h = recordSwitch(h, { id: 'startday', since: t(8).toISOString() }, 'on', 'trabajo', t(8, 30));
  h = recordSwitch(h, { id: 'trabajo', since: t(8, 30).toISOString() }, 'on', 'trabajo', t(9)); // re-on: nothing ends
  h = recordSwitch(h, { id: 'trabajo', since: t(8, 30).toISOString() }, 'off', 'trabajo', t(10, 30));
  h = recordSwitch(h, null, 'on', 'atlas', t(11));
  h = recordSwitch(h, { id: 'atlas', since: t(11).toISOString() }, 'on', 'trabajo', t(11, 15));
  assert.deepEqual(h.edges, { 'startday>trabajo': 1, 'trabajo>atlas': 1, 'atlas>trabajo': 1 });
  assert.deepEqual(h.time['2026-11-07'], { startday: 1800, trabajo: 7200, atlas: 900 });
  assert.equal(h.last, 'trabajo');
  const slept = recordSwitch(h, { id: 'trabajo', since: t(11, 15).toISOString() }, 'on', 'startday', new Date(2026, 10, 9, 8));
  assert.equal(slept.time['2026-11-07'].trabajo, 7200 + 12 * 3600);
});

it('Judge cascade: Jev decides when sure, claude -p when Jev is unsure, missing or failing', async () => {
  const opts = { trabajo: 'Trabajo', ninguno: 'ninguno' };
  const jev = (p) => async () => ({ ambiente: 'trabajo', confianza: p, motivo: 'jev' });
  const claude = async () => ({ ambiente: 'ninguno', confianza: 0.9, motivo: 'claude' });
  assert.equal((await judge({}, opts, { key: 'k', jev: jev(0.9), claude })).juez, 'jev');
  assert.equal((await judge({}, opts, { key: 'k', jev: jev(0.3), claude })).juez, 'claude');
  assert.equal((await judge({}, opts, { key: '', jev: jev(0.9), claude })).juez, 'claude');
  const down = async () => { throw new Error('sin red'); };
  const kept = await judge({}, opts, { key: 'k', jev: jev(0.4), claude: down });
  assert.deepEqual([kept.juez, kept.notas], ['jev', ['sin red']]);
  await assert.rejects(judge({}, opts, { key: 'k', jev: down, claude: down }), /sin red · sin red/);
});

it('Fingerprint: a new title is the same machine, a new site is not; fit comes from each plan', () => {
  const envs = [{ id: 'trabajo', ...G }, { id: 'gaming', ...GAMING }];
  const snap = (title, url) => machine({ profiles: [profile(LABORAL, tab(title, url))] });
  const a = describe(snap('(1) Inbox', 'https://mail.google.com/mail/u/0/#inbox'), envs, null);
  const b = describe(snap('(7) Inbox', 'https://mail.google.com/mail/u/0/#inbox/abc'), envs, null);
  const c = describe(snap('Admin', 'http://localhost:8000/api/v1/admin/'), envs, null);
  assert.equal(a.fingerprint, b.fingerprint);
  assert.notEqual(a.fingerprint, c.fingerprint);
  assert.deepEqual(c.state.encaje.find((f) => f.id === 'trabajo').suyo, 1);
  assert.deepEqual(c.state.encaje.find((f) => f.id === 'gaming').falta, 1);
});

it('Focus (SelfHarness): what the environment on would close, and dev servers but never its hosts', () => {
  const envs = [{ id: 'trabajo', ...G }, { id: 'gaming', ...GAMING }];
  const snap = machine({ profiles: [profile(LABORAL, tab('I Survived 7 Days', 'https://www.youtube.com/watch?v=1'), tab('Admin', 'http://localhost:8000/api/v1/admin/'))], listening, protectedPids: [HOST_PID] });
  const f = focusOf(envs, snap, { id: 'trabajo' }, new Date(2026, 10, 7, 9));
  assert.deepEqual(f.tabs.map((t) => [t.title, t.profile]), [['I Survived 7 Days', 'work']]);
  assert.match(f.tabs[0].reason, /Trabajo/);
  assert.deepEqual(f.servers.map((s) => [s.port, s.label]), [[5173, 'Frontend Vite'], [8765, null]]);
  assert.deepEqual(focusOf(envs, snap, null).tabs, []);
});

// Async cases (the judge) finish after the sync ones; a failure there sets the exit code.
let failed = 0;
const pending = [];
const fail = (name, e) => { failed++; console.error(`FAIL ${name}\n  ${e.message.split('\n').slice(0, 6).join('\n  ')}`); };
for (const [name, fn] of cases) {
  try { const r = fn(); if (r?.then) pending.push(r.catch((e) => fail(name, e))); } catch (e) { fail(name, e); }
}
if (failed) throw new Error(`${failed} de ${cases.length} casos de plan fallaron`);
Promise.all(pending).then(() => {
  if (failed) { console.error(`${failed} de ${cases.length} casos de plan fallaron`); process.exitCode = 1; } else console.log(`plan: ${cases.length} casos ok`);
});
