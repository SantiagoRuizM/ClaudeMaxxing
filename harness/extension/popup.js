// The toolbar popup: the plan's usage, the environment on (and what the detection thinks), this profile's tabs that
// do not fit it, switching environment and the nudge switch. Everything goes through background.js (host/api.js).
const $ = (id) => document.getElementById(id);
const send = (msg) => new Promise((resolve) => chrome.runtime.sendMessage(msg, (r) => resolve(r || { error: chrome.runtime.lastError?.message || 'sin respuesta' })));
const time = (secs) => new Date(secs * 1000).toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit' });
const el = (tag, props = {}, ...kids) => { const e = Object.assign(document.createElement(tag), props); e.append(...kids); return e; };
let pending = null;

// The logo exists only in the install (install.ps1 draws it); loaded from the repo, the header goes without it.
const logo = $('logo');
logo.onerror = () => logo.remove();
if (logo.complete && !logo.naturalWidth) logo.remove();

function bar(label, w) {
  const row = el('div', { className: 'bar' });
  if (!w) { row.append(el('span', { className: 'muted' }, label), el('span', { className: 'faint' }, 'sin empezar'), el('b', {}, '–')); return row; }
  const fill = el('div', { className: `fill${w.pct >= 90 ? ' high' : w.pct >= 70 ? ' warn' : ''}` });
  fill.style.width = `${Math.min(100, Math.max(2, w.pct))}%`;
  const track = el('div', { className: 'track', title: `se reinicia a las ${time(w.resetsAt)}` }, fill);
  row.append(el('span', { className: 'muted' }, label), track, el('b', {}, `${w.pct}%`));
  return row;
}

async function render() {
  const r = await send({ cmx: 'popup' });
  $('offline').hidden = !r.error;
  $('main').hidden = !!r.error;
  if (r.error) { $('offlineWhy').textContent = `${r.error}. Revisa que ClaudeMaxxing esté instalado (install.ps1) y que Node.js esté en el PC.`; return; }
  const { state, drift, nudges, email } = r.result;
  $('profile').textContent = email ? email.split('@')[0] : '';

  $('bars').replaceChildren(bar('Sesión', state.usage.session), bar('Semana', state.usage.weekly));

  const active = state.active;
  $('env').textContent = active ? active.name : 'Ninguno encendido';
  $('env').className = `env${active ? ' ok' : ' muted'}`;
  $('since').textContent = active ? `desde ${new Date(active.since).toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit' })}` : '';
  const running = state.job?.state === 'running';
  $('job').textContent = running ? `${state.job.action === 'off' ? 'Apagando' : 'Encendiendo'} ${state.job.name}: ${state.job.step || '…'}` : state.job?.state === 'error' ? `Falló ${state.job.name}: ${state.job.message}` : '';
  const d = state.detect;
  $('detect').textContent = d?.suggestion && d.suggestion !== active?.id ? `Lo abierto parece ${d.name} (${d.judge ? d.judge[0].toUpperCase() + d.judge.slice(1) : ''}, ${Math.round((d.confidence || 0) * 100)} %)` : '';

  // This profile's off-focus tabs, as the environment on would close them.
  $('driftBox').hidden = !active;
  $('driftCount').textContent = drift.length ? String(drift.length) : '';
  $('driftEmpty').textContent = drift.length ? '' : `✓ Todo encaja con ${active?.name || ''}`;
  $('drift').replaceChildren(...drift.slice(0, 8).map((t) => {
    const x = el('button', { className: 'x', title: 'Cerrar esta pestaña', textContent: '✕' });
    x.onclick = async () => { x.disabled = true; await send({ cmx: 'closeTabs', ids: [t.id] }); render(); };
    return el('li', {}, el('div', {}, el('div', { className: 't', title: t.url }, t.title || t.url), el('small', {}, t.reason)), x);
  }));
  $('driftActions').hidden = drift.length < 2;
  $('closeAll').textContent = `Cerrar todas (${drift.length})`;
  $('closeAll').onclick = async () => { $('closeAll').disabled = true; await send({ cmx: 'closeTabs', ids: drift.map((t) => t.id) }); $('closeAll').disabled = false; render(); };

  // Switching: one click picks, a second confirms (it closes what is not the new environment's).
  $('envs').replaceChildren(...state.envs.map((e) => {
    const b = el('button', { className: e.id === active?.id ? 'on' : '', textContent: e.name, disabled: running || e.id === active?.id, title: e.focus });
    b.onclick = () => { pending = e; $('confirmText').textContent = `¿Encender ${e.name}? Cierra lo que no es suyo, con apagado suave, y abre lo suyo.`; $('confirm').hidden = false; };
    return b;
  }));
  $('nudges').checked = nudges;
}

$('cancel').onclick = () => { pending = null; $('confirm').hidden = true; };
$('doSwitch').onclick = async () => {
  if (!pending) return;
  const r = await send({ cmx: 'switch', id: pending.id });
  $('confirm').hidden = true;
  pending = null;
  if (r.error) $('job').textContent = r.error;
  setTimeout(render, 600);
};
$('nudges').onchange = () => send({ cmx: 'nudges', on: $('nudges').checked });

render();
// While open, follow a change in progress.
setInterval(render, 3000);
