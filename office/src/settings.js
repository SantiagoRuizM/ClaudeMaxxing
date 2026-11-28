import { CITIES, REGIONS, DEFAULT_CITY, cityById } from './cities/index.js';
import { STYLES, DEFAULT_STYLE, styleById } from './styles/index.js';

// The settings panel of the page: background city and interior style. The viewer's choice wins over office.json and is
// kept in this browser (and in the URL, to share a view). Saving it for everyone goes through the tray (phase 2).
const KEY = 'office.view';
const SKIP_INTRO = 'office.skipIntro';

function readSaved() {
  try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; }
}

export function resolveChoice(params, cfg) {
  const saved = readSaved();
  return {
    city: cityById(params.get('ciudad') || saved.city || cfg.city || DEFAULT_CITY),
    style: styleById(params.get('estilo') || saved.style || cfg.style || DEFAULT_STYLE),
  };
}

// After a change the page reloads; this skips the establishing flight the second time.
export function takeSkipIntro() {
  try { const v = sessionStorage.getItem(SKIP_INTRO); sessionStorage.removeItem(SKIP_INTRO); return v === '1'; } catch { return false; }
}

function apply(next) {
  try { localStorage.setItem(KEY, JSON.stringify(next)); sessionStorage.setItem(SKIP_INTRO, '1'); } catch { /* the URL still carries it */ }
  const url = new URL(location.href);
  url.searchParams.set('ciudad', next.city);
  url.searchParams.set('estilo', next.style);
  location.replace(url);
}

const localTime = (tz) => new Intl.DateTimeFormat('es-CO', { timeZone: tz || undefined, hour: 'numeric', minute: '2-digit' }).format(new Date());

export function mountSettings(choice, { panel, button }) {
  const el = (tag, props = {}, ...kids) => { const e = Object.assign(document.createElement(tag), props); e.append(...kids); return e; };
  const chip = (label, sub, pressed, onClick) => {
    const b = el('button', { type: 'button', className: 'chip', onclick: onClick }, el('b', { textContent: label }));
    if (sub) b.append(el('span', { textContent: sub }));
    b.setAttribute('aria-pressed', String(pressed));
    return b;
  };
  function render() {
    const current = { city: choice.city.id, style: choice.style.id };
    const cities = Object.entries(REGIONS).map(([region, name]) => {
      const list = CITIES.filter((c) => c.region === region);
      if (!list.length) return '';
      return el('div', { className: 'group' }, el('h4', { textContent: name }),
        el('div', { className: 'chips' }, ...list.map((c) => chip(c.name, localTime(c.timeZone), c.id === current.city, () => apply({ ...current, city: c.id })))));
    });
    panel.replaceChildren(
      el('button', { type: 'button', className: 'close', textContent: '×', ariaLabel: 'Cerrar', onclick: () => toggle(false) }),
      el('h2', { textContent: 'Configurar la oficina' }),
      el('h3', { textContent: 'Ciudad de fondo' }), ...cities,
      el('h3', { textContent: 'Estilo de la oficina' }),
      el('div', { className: 'chips' }, ...STYLES.map((s) => chip(s.name, '', s.id === current.style, () => apply({ ...current, style: s.id })))),
      el('p', { className: 'note', textContent: 'Se guarda en este navegador. El edificio y la planta son siempre los mismos.' }),
    );
  }
  function toggle(open = panel.hidden) {
    if (open) render();
    panel.hidden = !open;
    button.setAttribute('aria-expanded', String(open));
    if (open) panel.querySelector('.chip[aria-pressed="true"]')?.focus();
    else button.focus();
  }
  button.addEventListener('click', () => toggle());
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && !panel.hidden) toggle(false); });
  return { toggle };
}
