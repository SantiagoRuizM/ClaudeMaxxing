// Native messaging host: Chrome spawns one per profile when the extension connects.
// It exposes the extension to local CLIs via HTTP on 127.0.0.1 (random port, token-protected)
// and registers itself in run/<pid>.json so the CLI can find every profile.
// stdout is the native messaging channel: never log to it.
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const api = require('./api');

// Per-PC data, never in the install folder or the repo: environments\*.json, run\ (state, history, hosts) and .env.
const HOME = process.env.YOURHARNESS_HOME || path.join(require('os').homedir(), '.claude', 'usage-tray', 'harness');
const RUN_DIR = process.env.YOURHARNESS_RUN_DIR || path.join(HOME, 'run');
const runFile = path.join(RUN_DIR, `${process.pid}.json`);
const token = crypto.randomBytes(24).toString('hex');
const pending = new Map();
let nextId = 1;
let info = { pid: process.pid, token, port: null, email: '', startedAt: new Date().toISOString() };

const log = (...a) => process.stderr.write(`[yourharness-host] ${a.join(' ')}\n`);
const writeRunFile = () => fs.writeFileSync(runFile, JSON.stringify(info, null, 2));

function send(msg) {
  const body = Buffer.from(JSON.stringify(msg));
  const len = Buffer.alloc(4);
  len.writeUInt32LE(body.length);
  process.stdout.write(Buffer.concat([len, body]));
}

// Native messages: 4-byte little-endian length + UTF-8 JSON.
let buf = Buffer.alloc(0);
process.stdin.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  while (buf.length >= 4) {
    const n = buf.readUInt32LE(0);
    if (buf.length < 4 + n) break;
    const msg = JSON.parse(buf.subarray(4, 4 + n).toString('utf8'));
    buf = buf.subarray(4 + n);
    if (msg.hello) {
      info = { ...info, ...msg.hello };
      if (info.port) writeRunFile();
    } else if (msg.req) {
      // The extension asking (ClaudeMaxxing's badge, nudge and popup), not answering one of our commands.
      api.handle(msg.ask, msg.args).then((result) => send({ req: msg.req, result }), (e) => send({ req: msg.req, error: String(e.message || e) }));
    } else if (pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

function call(cmd, args, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); resolve({ error: 'extension timeout' }); }, timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    send({ id, cmd, args });
  });
}

const server = http.createServer((req, res) => {
  const reply = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
  const given = Buffer.from(String(req.headers['x-harness-token'] || ''));
  if (given.length !== token.length || !crypto.timingSafeEqual(given, Buffer.from(token))) return reply(403, { error: 'bad token' });
  if (req.method !== 'POST' || req.url !== '/rpc') return reply(404, { error: 'POST /rpc only' });
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', async () => {
    let parsed;
    try { parsed = JSON.parse(body); } catch { return reply(400, { error: 'invalid json' }); }
    const msg = await call(parsed.cmd, parsed.args);
    reply(msg.error ? 500 : 200, msg.error ? { error: msg.error } : { result: msg.result, email: info.email });
  });
});

function shutdown() {
  try { fs.unlinkSync(runFile); } catch {}
  process.exit(0);
}
process.stdin.on('end', shutdown); // Chrome closed the port (browser/profile closed or extension reloaded)
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

server.listen(0, '127.0.0.1', () => {
  fs.mkdirSync(RUN_DIR, { recursive: true });
  info.port = server.address().port;
  writeRunFile();
  log(`listening on 127.0.0.1:${info.port}`);
});
