// Self-check: plays the extension over native messaging against the real host, then drives the CLI.
// node test.js
const assert = require('assert');
const { spawn, execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

require('./plan.test'); // every on/off case on simulated machines

// Environment rules: the tab's content decides, explicit rules win.
const { classify } = require('./env');
const trabajo = JSON.parse(fs.readFileSync(path.join(__dirname, 'test', 'environments', 'trabajo.json'), 'utf8'));
const yt = (title, channel) => ({ title, url: 'https://www.youtube.com/watch?v=1', content: { live: true, youtube: { title, channel } } });
assert.equal(classify(yt('I Spent 7 Days Buried Alive', 'MrBeast'), trabajo).action, 'close');
assert.deepEqual(classify(yt('Cómo crear APIs con Django REST', 'Dev'), trabajo), { action: 'keep', reason: 'trata de "APIs"' });
assert.equal(classify({ title: 'The Dark Forest | YouTube Music', url: 'https://music.youtube.com/watch?v=k', content: { youtube: { title: 'React tutorial' } } }, trabajo).action, 'close');
assert.equal(classify({ title: 'Admin', url: 'http://localhost:8000/api/v1/admin/' }, trabajo).action, 'keep');
assert.equal(classify({ title: 'Recibidos - Gmail', url: 'https://mail.google.com/mail/u/0/' }, trabajo).action, 'close');
assert.equal(classify({ title: 'Calendario', url: 'https://calendar.google.com/calendar/u/0/r/week' }, trabajo).action, 'close');
// A closed profile loses every tab, even ones that would otherwise stay.
assert.equal(classify({ title: 'Admin', url: 'http://localhost:8000/api/v1/admin/', profile: 'personal@example.com' }, trabajo).action, 'close');
assert.equal(classify({ title: 'Extensiones', url: 'chrome://extensions/', profile: 'personal@example.com' }, trabajo).action, 'close');
assert.equal(classify({ title: 'Selfishgene sfhq dataset - Buscar con Google', url: 'https://www.google.com/search?q=sfhq' }, trabajo).action, 'close');

const atlas = JSON.parse(fs.readFileSync(path.join(__dirname, 'test', 'environments', 'atlas.json'), 'utf8'));
const personal = (title, url) => ({ title, url, profile: 'personal@example.com' });
// Keep beats close: the environment's own playlist survives the "other music" rule.
assert.equal(classify(personal('Atlas | YouTube Music', 'https://music.youtube.com/watch?v=a&list=PLexamplePlaylist0000'), atlas).action, 'keep');
assert.equal(classify(personal('HANDS 1977 | YouTube Music', 'https://music.youtube.com/watch?v=b&list=OTHER'), atlas).action, 'close');
assert.equal(classify(personal('Libro 2', 'https://docs.google.com/document/d/1wQ/edit'), atlas).action, 'keep');
assert.equal(classify(personal('Segundo - Wikipedia', 'https://es.wikipedia.org/wiki/Segundo'), atlas).action, 'keep');
assert.equal(classify(personal('Trabajo — Cliente', 'http://localhost:5173/'), atlas).action, 'close');
assert.equal(classify({ title: 'Tablero', url: 'http://localhost:5180/', profile: 'work@example.com' }, atlas).action, 'close');

// StartDay keeps only what it opens (claimed in plan()); everything else falls to the default close.
const startday = JSON.parse(fs.readFileSync(path.join(__dirname, 'test', 'environments', 'startday.json'), 'utf8'));
assert.equal(classify(personal('Tablero del Modulo', 'http://localhost:5180/'), startday).action, 'close');
assert.equal(classify({ title: 'Admin', url: 'http://localhost:8000/api/v1/admin/', profile: 'work@example.com' }, startday).action, 'close');
// An open-only environment ("default": "keep") respects what no rule mentions.
assert.equal(classify(personal('Tablero', 'http://localhost:5180/'), { name: 'X', tabs: { default: 'keep' } }).action, 'keep');

const runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'yourharness-'));
const env = { ...process.env, YOURHARNESS_RUN_DIR: runDir };
let tabs = [
  { id: 11, windowId: 1, index: 0, active: true, windowFocused: true, title: 'How to build APIs', url: 'https://www.youtube.com/watch?v=x' },
  { id: 12, windowId: 1, index: 1, active: false, windowFocused: true, title: 'MrBeast challenge', url: 'https://mrbeast.invalid/' }, // .invalid: offline fetch fails fast, no network
  { id: 13, windowId: 2, index: 0, active: true, windowFocused: false, title: 'Gmail', url: 'chrome://newtab/' },
];
const host = spawn(process.execPath, [path.join(__dirname, 'host', 'host.js')], { env, stdio: ['pipe', 'pipe', 'inherit'] });

const frame = (o) => { const b = Buffer.from(JSON.stringify(o)); const l = Buffer.alloc(4); l.writeUInt32LE(b.length); return Buffer.concat([l, b]); };
const fake = {
  list: () => tabs,
  content: ({ ids }) => ids.map((id) => (id === 11
    ? { id, live: true, youtube: { title: 'How to build APIs', channel: 'Fireship', description: 'REST in 100s' }, media: { currentTime: 65, duration: 600, paused: false }, text: 'x' }
    : { id, live: false })),
  close: ({ ids }) => { tabs = tabs.filter((t) => !ids.includes(t.id)); return { closed: ids }; },
};
let buf = Buffer.alloc(0);
host.stdout.on('data', (c) => {
  buf = Buffer.concat([buf, c]);
  while (buf.length >= 4 && buf.length >= 4 + buf.readUInt32LE(0)) {
    const n = buf.readUInt32LE(0);
    const msg = JSON.parse(buf.subarray(4, 4 + n));
    buf = buf.subarray(4 + n);
    host.stdin.write(frame({ id: msg.id, result: fake[msg.cmd](msg.args) }));
  }
});
host.stdin.write(frame({ hello: { email: 'test@example.com' } }));

// Async: a sync exec would block this process, which is also playing the extension.
const cli = (...a) => new Promise((res, rej) => execFile(process.execPath, [path.join(__dirname, 'tabs.js'), ...a], { env }, (e, out) => (e ? rej(e) : res(out))));

(async () => {
  for (let i = 0; i < 50 && !fs.readdirSync(runDir).length; i++) await new Promise((r) => setTimeout(r, 100));
  const list = await cli();
  assert.match(list, /Perfil test@example.com \(3 pestañas\)/);
  assert.match(list, /\[11\] How to build APIs  <ACTIVA>/);
  assert.match(list, /YouTube · Fireship · reproduciendo 1:05\/10:00 · REST in 100s/);
  assert.match(list, /\[13\] Gmail[\s\S]*\(no cargada\)/);

  const preview = await cli('close', 'mrbeast');
  assert.match(preview, /cerraría \[12\]/);
  assert.equal(tabs.length, 3, 'regex close without --yes must not close');

  await cli('close', 'mrbeast', '--yes');
  assert.deepEqual(tabs.map((t) => t.id), [11, 13]);
  await cli('close', '13');
  assert.deepEqual(tabs.map((t) => t.id), [11]);

  host.stdin.end(); // Chrome closing the port must unregister the host
  await new Promise((r) => host.on('exit', r));
  assert.equal(fs.readdirSync(runDir).length, 0);
  console.log('ok');
})().catch((e) => { console.error(e); host.kill(); process.exit(1); });
