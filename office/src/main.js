import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { placeTeam } from './team.js';
import { buildCity, scaleBoxUV } from './city.js';
import { buildOffice } from './office.js';
import { makePerson, applyPose } from './people.js';
import { rng, hash, zTex, textLogo } from './textures.js';

const params = new URLSearchParams(location.search);
const SHOT = params.has('shot');
const FLOOR_Y = 26;

const STATES = {
  working: { label: 'Trabajando', icon: '⌨️', group: 'work', text: 'Está trabajando.' },
  sleepDesk: { label: 'Durmiendo', icon: '💤', group: 'sleep', text: 'Se quedó dormido sobre el escritorio.' },
  sleepBack: { label: 'Durmiendo', icon: '💤', group: 'sleep', text: 'Duerme echado para atrás en la silla.' },
  beanbag: { label: 'Durmiendo', icon: '💤', group: 'sleep', text: 'Se fue a dormir a un puf de la zona de descanso.' },
  phoneDesk: { label: 'En el celular', icon: '📱', group: 'phone', text: 'Está en su puesto, mirando el celular.' },
  sofaPhone: { label: 'En el celular', icon: '📱', group: 'phone', text: 'Está en el sofá, mirando el celular.' },
  standPhone: { label: 'En el celular', icon: '📱', group: 'phone', text: 'Está en el balcón, mirando el celular.' },
  coffee: { label: 'Tomando café', icon: '☕', group: 'break', text: 'Está en la cocina tomando café.' },
  pingpong: { label: 'Jugando ping-pong', icon: '🏓', group: 'break', text: 'Está jugando ping-pong.' },
  absent: { label: 'No vino', icon: '🚫', group: 'absent', text: 'Hoy no vino a la oficina.' },
};

// ---------- configuration: the user's (config/, served by the tray) or the demo ----------
async function loadConfig() {
  for (const dir of ['config/', 'demo/']) {
    try {
      const r = await fetch(`${dir}office.json`, { cache: 'no-store' });
      if (r.ok) return { ...(await r.json()), base: dir };
    } catch { /* next */ }
  }
  return { base: '', teams: {}, people: [] };
}
const cfg = await loadConfig();
const layout = placeTeam(cfg);
layout.warnings.forEach((w) => console.warn('office.json:', w));
const PEOPLE = layout.people, TEAMS = layout.teams;
const COMPANY = String(cfg.company?.name || '');
const CITY_NAME = 'Medellín'; // shortcut: fixed until the city presets (phase 1) give name and time zone
const TZ = cfg.timeZone || 'America/Bogota';
const esc = (x) => String(x).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

// ---------- renderer ----------
const app = document.getElementById('app');
const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance', preserveDrawingBuffer: SHOT });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
app.appendChild(renderer.domElement);
renderer.domElement.addEventListener('webglcontextlost', () => console.log('SHOTINFO context lost'));
addEventListener('error', (e) => console.log('SHOTINFO error', e.message));
const labelR = new CSS2DRenderer();
labelR.setSize(innerWidth, innerHeight);
labelR.domElement.className = 'labels';
app.appendChild(labelR.domElement);

const scene = new THREE.Scene();
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.5;
scene.fog = new THREE.FogExp2('#CFE5EE', 0.00058);
const camera = new THREE.PerspectiveCamera(38, innerWidth / innerHeight, 0.3, 14000);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.maxPolarAngle = 1.42;
controls.minDistance = 2.8;
controls.maxDistance = 520;

const composer = new EffectComposer(renderer, new THREE.WebGLRenderTarget(innerWidth, innerHeight, { type: THREE.HalfFloatType, samples: 4 }));
composer.addPass(new RenderPass(scene, camera));
const bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), 0.2, 0.55, 0.8);
if (!params.has('nobloom')) composer.addPass(bloom);
composer.addPass(new OutputPass());

// ---------- world ----------
const loader = new THREE.TextureLoader();
// Paths in office.json are relative to its folder. Without an image, the company name (or its initial) is drawn.
const brandTex = (f, fallback) => {
  if (!f) return fallback();
  const t = loader.load(cfg.base + f); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8; return t;
};
const C0 = cfg.company || {};
const brand = {
  wordmark: brandTex(C0.wordmark, () => textLogo(COMPANY, { color: '#1F2A36' })),
  isotipo: brandTex(C0.logo, () => textLogo((COMPANY[0] || '').toUpperCase(), { w: 256, h: 256, color: '#2F93D6' })),
  white: brandTex(C0.wordmarkOnDark || C0.wordmark, () => textLogo(COMPANY)),
};
const city = buildCity(scene);
for (const h of (params.get('hide') || '').split(',').filter(Boolean)) { // debug
  if (h === 'city') city.root.visible = false;
  if (h === 'sky') city.sky.visible = city.sunDisc.visible = false;
  if (h === 'clouds') city.clouds.forEach((c) => { c.visible = false; });
}
const office = buildOffice(brand, layout, { company: COMPANY, cityName: CITY_NAME });
office.root.position.y = FLOOR_Y;
scene.add(office.root);

// the tower: glass floors below the open office floor
const towerH = FLOOR_Y - 0.85;
const towerMat = city.facMats.glass.clone();
Object.assign(towerMat, { roughness: 0.18, metalness: 0.55 });
towerMat.color.set('#B7C6D1');
const tower = new THREE.Mesh(scaleBoxUV(new THREE.BoxGeometry(31.2, towerH, 21.2), 31.2, towerH, 21.2), towerMat);
tower.position.y = 0.3 + towerH / 2;
tower.castShadow = tower.receiveShadow = true;
scene.add(tower);
const lobby = new THREE.Mesh(new THREE.BoxGeometry(31.4, 4, 21.4), new THREE.MeshStandardMaterial({ color: '#2B3036', roughness: 0.4 }));
lobby.position.y = 2.3; scene.add(lobby);
const signMat = new THREE.MeshStandardMaterial({ map: brand.white, transparent: true, emissiveMap: brand.white, emissive: '#ffffff', emissiveIntensity: 0.2 });
const sign = new THREE.Mesh(new THREE.PlaneGeometry(10, 1.7), signMat);
const bandMat = new THREE.MeshStandardMaterial({ color: '#141C24', roughness: 0.35, metalness: 0.3 });
const band = new THREE.Mesh(new THREE.BoxGeometry(31.4, 3.0, 21.4), bandMat);
band.position.y = FLOOR_Y - 3.2; scene.add(band);
sign.position.set(0, FLOOR_Y - 3.2, 10.72); scene.add(sign);
const sign2 = new THREE.Mesh(new THREE.PlaneGeometry(8, 1.36), signMat);
sign2.position.set(15.72, FLOOR_Y - 3.2, 0); sign2.rotation.y = Math.PI / 2; scene.add(sign2);
const entry = new THREE.Mesh(new THREE.BoxGeometry(8, 3.2, 0.2), new THREE.MeshStandardMaterial({ color: '#9CC9E0', emissive: '#FFD7A0', emissiveIntensity: 0, roughness: 0.1 }));
entry.position.set(0, 1.9, 10.75); scene.add(entry);

// ---------- lights ----------
const hemi = new THREE.HemisphereLight('#D8ECFF', '#6B5A44', 1);
scene.add(hemi);
const sun = new THREE.DirectionalLight('#FFF3DC', 3);
sun.castShadow = true;
sun.shadow.mapSize.set(4096, 4096);
Object.assign(sun.shadow.camera, { left: -26, right: 26, top: 26, bottom: -26, near: 1, far: 400 });
sun.shadow.bias = -0.0004;
sun.shadow.normalBias = 0.06;
sun.target.position.set(0, FLOOR_Y, 0);
scene.add(sun, sun.target);

// ---------- people ----------
const persons = PEOPLE.map((p) => {
  const P = makePerson(p);
  office.root.add(P.g);
  const el = document.createElement('button');
  el.type = 'button';
  el.className = `tag ${p.kind}`;
  el.style.setProperty('--team', TEAMS[p.team].color);
  el.addEventListener('click', (e) => { e.stopPropagation(); select(p.id); });
  el.addEventListener('pointerdown', (e) => e.stopPropagation());
  const obj = new CSS2DObject(el);
  obj.center.set(0.5, 1);
  P.anchor.add(obj);
  P.tag = el;
  return P;
});
const byId = Object.fromEntries(persons.map((P) => [P.id, P]));
const pickables = [];
persons.forEach((P) => P.g.traverse((o) => { if (o.isMesh) pickables.push(o); }));

// room labels (only in plan view)
for (const [name, x, z] of office.rooms) {
  const el = document.createElement('div'); el.className = 'room'; el.textContent = name;
  const o = new CSS2DObject(el); o.position.set(x, 0.1, z); office.root.add(o);
}

// ---------- states ----------
let status = { agents: {} };
let states = {};
const cityDay = () => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date());

function computeStates() {
  const R = rng(hash(cityDay()));
  const forced = params.get('estado');
  const out = {};
  for (const p of PEOPLE) {
    const s = status.agents?.[p.id];
    if (forced === 'trabajando' || s?.state === 'working') out[p.id] = { kind: 'working', task: s?.task };
    else if (s?.state === 'absent') out[p.id] = { kind: 'absent' };
    else if (p.kind === 'founder') out[p.id] = { kind: 'working', task: s?.task };
  }
  const idle = PEOPLE.filter((p) => !out[p.id]);
  for (let i = idle.length - 1; i > 0; i--) { const j = Math.floor(R() * (i + 1)); [idle[i], idle[j]] = [idle[j], idle[i]]; }
  let slots = office.slots;
  if (idle.length < 2) slots = slots.filter((s) => s.kind !== 'pingpong');
  idle.forEach((p, i) => { out[p.id] = { ...(slots[i] || { kind: 'absent' }) }; });
  return out;
}

const AT_DESK = new Set(['working', 'sleepDesk', 'sleepBack', 'phoneDesk', 'absent']);
const zMat = new THREE.SpriteMaterial({ map: zTex(), transparent: true, depthWrite: false });
function applyStates() {
  states = computeStates();
  const R = rng(hash(cityDay() + 'chairs'));
  for (const P of persons) {
    const st = states[P.id];
    const S = office.stations[P.id];
    S.chair.position.set(0, 0, -0.02); S.chair.rotation.set(0, 0, 0);
    P.body.visible = P.shadow.visible = st.kind !== 'absent';
    if (AT_DESK.has(st.kind)) {
      P.g.position.copy(S.group.position);
      const swivel = st.kind === 'phoneDesk' ? 0.5 : 0;
      P.g.rotation.y = S.group.rotation.y + swivel;
      S.chair.rotation.y = swivel;
      if (st.kind === 'absent') { S.chair.position.z = 0.2; }
      S.setScreen(st.kind === 'working' ? 'code' : st.kind === 'absent' ? 'off' : 'saver');
    } else {
      P.g.position.set(st.pos[0], 0, st.pos[1]);
      P.g.rotation.y = st.rot;
      S.chair.rotation.y = (R() - 0.5) * 1.4;
      S.chair.position.set((R() - 0.5) * 0.3, 0, -0.25);
      S.setScreen(R() < 0.5 ? 'saver' : 'off');
    }
    const meta = STATES[st.kind];
    const isSleep = meta.group === 'sleep';
    if (isSleep && !P.zzz) {
      P.zzz = [0, 1, 2].map(() => { const s = new THREE.Sprite(zMat.clone()); office.root.add(s); return s; });
    }
    if (P.zzz) P.zzz.forEach((s) => { s.visible = isSleep; });
    const d = P.data;
    P.tag.classList.toggle('dim', st.kind === 'absent');
    P.tag.innerHTML = d.kind === 'founder'
      ? `<b>${esc(d.name.split(' ')[0])}</b><span class="r">${esc(d.id)}</span>${st.kind === 'working' ? '' : `<i>${meta.icon}</i>`}`
      : `<b>${esc(d.id)}</b><i>${meta.icon}</i>`;
    P.tag.title = `${d.name} · ${meta.label}`;
  }
  renderStats();
  if (selected) select(selected, false);
}

async function loadStatus() {
  try {
    const r = await fetch(`status.json?ts=${Date.now()}`, { cache: 'no-store' });
    if (!r.ok) return false;
    const next = await r.json();
    if (JSON.stringify(next) === JSON.stringify(status)) return false;
    status = next;
    return true;
  } catch { return false; }
}

// ---------- HUD ----------
const $ = (s) => document.querySelector(s);
function renderStats() {
  const agents = PEOPLE.filter((p) => p.kind === 'agent');
  const count = (g) => agents.filter((p) => STATES[states[p.id].kind].group === g).length;
  $('#s-work').textContent = `${count('work')}/${agents.length}`;
  $('#s-sleep').textContent = count('sleep');
  $('#s-phone').textContent = count('phone');
  $('#s-break').textContent = count('break');
  $('#s-absent').textContent = count('absent');
  $('#mood').textContent = count('work') === 0
    ? 'Nadie tiene tarea asignada. La oficina está en modo ocio.'
    : `${count('work')} agentes trabajando en lo que les asignaste.`;
}

let selected = null;
const ring = new THREE.Mesh(new THREE.RingGeometry(0.55, 0.68, 48), new THREE.MeshBasicMaterial({ color: '#F2C14E', transparent: true, depthWrite: false, toneMapped: false }));
ring.rotation.x = -Math.PI / 2; ring.visible = false; office.root.add(ring);
function select(id, focus = true) {
  selected = id;
  const P = byId[id], d = P.data, st = states[id], meta = STATES[st.kind];
  persons.forEach((Q) => Q.tag.classList.toggle('sel', Q.id === id));
  const panel = $('#panel');
  panel.hidden = false;
  panel.style.setProperty('--team', TEAMS[d.team].color);
  $('#p-team').textContent = d.kind === 'founder' ? TEAMS[d.team].name : `Agente · ${TEAMS[d.team].name}`;
  $('#p-name').textContent = d.kind === 'founder' ? d.name : `${d.id} · ${d.name}`;
  $('#p-role').textContent = d.role;
  $('#p-state').innerHTML = `<i>${meta.icon}</i><b>${meta.label}</b>`;
  const tx = st.kind === 'working' ? (st.task ? `Está trabajando en: ${st.task}` : meta.text) : meta.text;
  $('#p-text').textContent = tx;
  $('#p-hint').textContent = d.kind === 'founder' || st.kind === 'working'
    ? ''
    : `Nadie le ha asignado nada. Para ponerlo a trabajar, abre una sesión de Claude Code con el rol ${d.id}.`;
  $('#p-does').replaceChildren(...d.does.map((x) => Object.assign(document.createElement('li'), { textContent: x })));
  $('#p-does').previousElementSibling.hidden = !d.does.length;
  $('#p-src').textContent = d.src ? `Fuente: ${d.src}` : '';
  if (focus && !plan) {
    const wp = P.g.getWorldPosition(new THREE.Vector3());
    const off = camera.position.clone().sub(controls.target);
    const dist = Math.min(off.length(), 16);
    off.setLength(dist);
    flyTo({ t: wp.clone().setY(FLOOR_Y + 0.8), p: wp.clone().setY(FLOOR_Y + 0.8).add(off) }, 1.2);
  }
}
$('#p-close').addEventListener('click', () => { $('#panel').hidden = true; selected = null; persons.forEach((Q) => Q.tag.classList.remove('sel')); ring.visible = false; });

// ---------- camera ----------
const T0 = new THREE.Vector3(0, FLOOR_Y, 0.8);
const VIEWS = {
  normal: { t: T0.clone().add(new THREE.Vector3(-3, 2.2, -8)), p: T0.clone().add(new THREE.Vector3(19.3, 14.6, 31.5)) },
  plano: { t: new THREE.Vector3(0, FLOOR_Y, -1.2), p: new THREE.Vector3(0.01, FLOOR_Y + 42, 3) },
  cerca: { t: new THREE.Vector3(-4, FLOOR_Y + 0.6, 3.5), p: new THREE.Vector3(5, FLOOR_Y + 7.5, 15) },
  lejos: { t: new THREE.Vector3(-70, 40, -260), p: new THREE.Vector3(120, 85, 210) },
  oficina1: { t: new THREE.Vector3(-12.5, FLOOR_Y + 1.1, -9.1), p: new THREE.Vector3(-10.2, FLOOR_Y + 2.35, -5.8) },
  oficina2: { t: new THREE.Vector3(12.5, FLOOR_Y + 1.1, -9.0), p: new THREE.Vector3(11.0, FLOOR_Y + 2.3, -5.2) },
};
let fly = null;
function flyTo(view, dur = 1.6, done = null) { fly = { fp: camera.position.clone(), ft: controls.target.clone(), view, k: 0, dur, done }; }
if (params.get('cam')) { // debug: cam=px,py,pz,tx,ty,tz
  const n = params.get('cam').split(',').map(Number);
  VIEWS.custom = { p: new THREE.Vector3(n[0], n[1], n[2]), t: new THREE.Vector3(n[3], n[4], n[5]) };
}
const startView = VIEWS.custom || VIEWS[params.get('vista')] || VIEWS.normal;
if (SHOT || matchMedia('(prefers-reduced-motion: reduce)').matches) {
  camera.position.copy(startView.p); controls.target.copy(startView.t);
} else {
  camera.position.set(260, 190, 420); controls.target.set(0, FLOOR_Y, 0);
  // establishing shot of the valley (river, metro, Coltejer), then land on the office
  flyTo({ p: new THREE.Vector3(65, 110, 175), t: new THREE.Vector3(-120, 30, -160) }, 2.6, () => flyTo(startView, 3));
}
let plan = params.get('vista') === 'plano';
document.body.classList.toggle('plan', plan);

// ---------- time of day ----------
const MODES = ['real', 'dia', 'tarde', 'noche'];
const MODE_LABEL = { real: 'Hora real', dia: 'Día', tarde: 'Atardecer', noche: 'Noche' };
const MODE_H = { dia: 10.5, tarde: 17.75, noche: 20.6 };
let mode = params.get('hora') ? 'fixed' : 'real';
const fixedH = Number(params.get('hora'));
function cityHour() {
  const [h, m] = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date()).split(':').map(Number);
  return (h % 24) + m / 60;
}
const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };
const C = (h) => new THREE.Color(h);
const PAL = {
  day: [C('#3F86CF'), C('#CBE3EE'), C('#8E9FA4')],
  dusk: [C('#2C4583'), C('#F29A5C'), C('#5A4848')],
  night: [C('#040816'), C('#16233D'), C('#090D18')],
};
const moonDir = new THREE.Vector3(-0.45, 0.75, 0.5).normalize();
const sunDir = new THREE.Vector3();
let night = 0;
function setTime(h) {
  const a = ((h - 6) / 12) * Math.PI;
  const el = Math.sin(a);
  const day = smooth(-0.14, 0.1, el);
  const dusk = Math.max(0, 1 - Math.abs(el - 0.08) / 0.2) * (h > 12 ? 1 : 0.6);
  night = 1 - day;
  sunDir.set(Math.cos(a) * 0.8, el, 0.5).normalize();
  const top = PAL.night[0].clone().lerp(PAL.day[0], day).lerp(PAL.dusk[0], dusk * 0.7);
  const hor = PAL.night[1].clone().lerp(PAL.day[1], day).lerp(PAL.dusk[1], dusk * 0.55);
  const bot = PAL.night[2].clone().lerp(PAL.day[2], day).lerp(PAL.dusk[2], dusk * 0.6);
  scene.fog.color.copy(hor);
  scene.fog.density = 0.00058 + dusk * 0.00014 + night * 0.00018;
  city.setSky(top, hor, bot, night, sunDir, moonDir);
  const lightDir = day > 0.35 ? sunDir.clone().setY(Math.max(sunDir.y, 0.12)).normalize() : moonDir;
  sun.position.copy(sun.target.position).addScaledVector(lightDir, 160);
  sun.intensity = day > 0.35 ? 0.4 + 3.2 * day + dusk * 0.4 : 0.25;
  sun.color.set('#FFE6C4').lerp(C('#FFA060'), dusk).lerp(C('#9FB6E8'), day > 0.35 ? 0 : 1);
  hemi.intensity = (0.12 + 0.5 * day) * (1 - 0.4 * dusk);
  hemi.color.set('#D8ECFF').lerp(C('#728BC8'), dusk).lerp(C('#3A4A72'), night);
  hemi.groundColor.set('#6B5A44').lerp(C('#382633'), dusk).lerp(C('#1A1A24'), night);
  scene.environmentIntensity = (0.1 + 0.2 * day) * (1 - 0.5 * dusk);
  towerMat.emissiveIntensity = night * 0.28;
  renderer.toneMappingExposure = 1.0 + night * 0.02;
  bloom.strength = 0.08 + night * 0.25;
  bloom.threshold = 0.92 - night * 0.12;
  office.setNight(Math.max(night, dusk * 0.25));
  signMat.emissiveIntensity = 0.15 + night * 0.65;
  entry.material.emissiveIntensity = night * 1.2;
  document.body.classList.toggle('night', night > 0.5);
}
function currentHour() { return mode === 'real' ? cityHour() : mode === 'fixed' ? fixedH : MODE_H[mode]; }
function renderClock() {
  const h = currentHour();
  const now = mode === 'real'
    ? new Intl.DateTimeFormat('es-CO', { timeZone: TZ, hour: 'numeric', minute: '2-digit' }).format(new Date())
    : `${((Math.floor(h) + 11) % 12) + 1}:${String(Math.round((h % 1) * 60)).padStart(2, '0')} ${h < 12 ? 'a. m.' : 'p. m.'}`;
  $('#clock').textContent = now;
  $('#b-time').textContent = mode === 'fixed' ? `Hora: ${fixedH}h` : MODE_LABEL[mode];
}

// ---------- controls ----------
$('#b-time').addEventListener('click', () => {
  mode = MODES[(MODES.indexOf(mode) + 1) % MODES.length];
  setTime(currentHour()); renderClock();
});
$('#b-plan').addEventListener('click', () => {
  plan = !plan;
  document.body.classList.toggle('plan', plan);
  $('#b-plan').setAttribute('aria-pressed', String(plan));
  flyTo(plan ? VIEWS.plano : VIEWS.normal, 1.6);
});
$('#b-labels').addEventListener('click', () => {
  const off = document.body.classList.toggle('no-labels');
  $('#b-labels').setAttribute('aria-pressed', String(!off));
});
$('#b-full').addEventListener('click', () => {
  if (document.fullscreenElement) document.exitFullscreen?.();
  else document.documentElement.requestFullscreen?.().catch(() => {});
});
$('#b-home').addEventListener('click', () => { plan = false; document.body.classList.remove('plan'); flyTo(VIEWS.normal, 1.6); });

const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
let down = null;
renderer.domElement.addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; });
renderer.domElement.addEventListener('pointerup', (e) => {
  if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 5) return;
  ndc.set((e.clientX / innerWidth) * 2 - 1, -(e.clientY / innerHeight) * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const hit = ray.intersectObjects(pickables, false).find((h) => h.object.userData.pid && byId[h.object.userData.pid].body.visible);
  if (hit) select(hit.object.userData.pid);
});
addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight; camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight); labelR.setSize(innerWidth, innerHeight);
  composer.setSize(innerWidth, innerHeight);
});

// ---------- loop ----------
const clock = new THREE.Clock();
const v = new THREE.Vector3();
let t = 0, timeAcc = 0;
const ease = (k) => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);

function pingPong() {
  const T = 0.85;
  const cyc = t % (2 * T);
  const players = persons.filter((P) => states[P.id]?.kind === 'pingpong');
  const PP = office.PP;
  const g = (x) => Math.exp(-(x * x) / 0.012);
  for (const P of players) {
    const side = states[P.id].side;
    const sw = side === 0 ? g(cyc) + g(cyc - 2 * T) : g(cyc - T);
    applyPose(P, 'pingpong', t, { swing: sw });
  }
  const ball = office.ball;
  ball.visible = players.length === 2;
  if (!ball.visible) return;
  const leg = cyc < T ? cyc / T : (cyc - T) / T;
  const xa = PP.x - 1.55, xb = PP.x + 1.55;
  const [x0, x1] = cyc < T ? [xa, xb] : [xb, xa];
  const y = leg < 0.7 ? 0.8 + Math.sin((leg / 0.7) * Math.PI) * 0.34 : 0.8 + Math.sin(((leg - 0.7) / 0.3) * Math.PI) * 0.2;
  ball.position.set(x0 + (x1 - x0) * leg, y, PP.z + Math.sin(t * 1.7) * 0.25);
}

let firstFrame = true, shotFrames = 0;
function frame() {
  const dt = Math.min(clock.getDelta(), 0.05);
  t += dt;
  timeAcc += dt;
  if (timeAcc > 20) { timeAcc = 0; if (mode === 'real') setTime(currentHour()); renderClock(); }

  for (const P of persons) {
    const st = states[P.id];
    if (!st || st.kind === 'pingpong') continue;
    applyPose(P, st.kind, t);
  }
  pingPong();
  office.update(dt, t);
  city.update(dt, t);

  // label anchors follow heads, Zzz rise from sleepers
  for (const P of persons) {
    P.head.getWorldPosition(v);
    P.g.worldToLocal(v);
    P.anchor.position.set(v.x, v.y + 0.62 * P.s, v.z);
    if (P.zzz && P.zzz[0].visible) {
      P.head.getWorldPosition(v); office.root.worldToLocal(v);
      P.zzz.forEach((s, i) => {
        const k = (t * 0.45 + i / 3 + P.seed * 0.01) % 1;
        s.position.set(v.x + 0.12 + k * 0.35, v.y + 0.35 + k * 0.75, v.z);
        s.scale.setScalar(0.12 + k * 0.2);
        s.material.opacity = Math.sin(k * Math.PI);
      });
    }
  }
  if (selected) {
    const P = byId[selected];
    ring.visible = true;
    ring.position.set(P.g.position.x, 0.02, P.g.position.z);
    ring.scale.setScalar(1 + Math.sin(t * 4) * 0.08);
  }

  if (fly) {
    fly.k = Math.min(1, fly.k + dt / fly.dur);
    const e = ease(fly.k);
    camera.position.lerpVectors(fly.fp, fly.view.p, e);
    controls.target.lerpVectors(fly.ft, fly.view.t, e);
    if (fly.k >= 1) { const done = fly.done; fly = null; done?.(); }
  }
  controls.update();
  const dist = camera.position.distanceTo(controls.target);
  document.body.classList.toggle('far', dist > 70);
  document.body.classList.toggle('vfar', dist > 200);
  document.body.classList.toggle('mid', dist > 30);

  composer.render();
  labelR.render(scene, camera);
  if (firstFrame) { firstFrame = false; document.body.classList.add('ready'); }
  // shot mode (headless screenshots): software GL is slow, so stop after the scene has settled
  if (SHOT && shotFrames === 2) console.log('SHOTINFO', JSON.stringify(renderer.info.render), renderer.getContext().getError());
  if (SHOT && ++shotFrames > 12) {
    const img = new Image();
    img.src = renderer.domElement.toDataURL('image/png');
    img.style.cssText = 'position:absolute;inset:0;width:100%;height:100%';
    app.insertBefore(img, labelR.domElement);
    const px = new Uint8Array(4); const gl = renderer.getContext();
    gl.readPixels(innerWidth >> 1, innerHeight >> 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    console.log('SHOTINFO center pixel', [...px].join(','), 'cam', camera.position.toArray().map((x) => x.toFixed(1)).join(','));
    return;
  }
  requestAnimationFrame(frame);
}

// ---------- header ----------
document.title = COMPANY ? `${COMPANY} · Oficina virtual` : 'Oficina virtual';
$('#company').textContent = COMPANY;
$('#place').textContent = [C0.place, CITY_NAME].filter(Boolean).join(', ');
if (C0.wordmarkOnDark || C0.wordmark) { const img = $('#logo'); img.src = cfg.base + (C0.wordmarkOnDark || C0.wordmark); img.alt = COMPANY; img.hidden = false; $('#company').hidden = true; }
if (C0.logo) { const icon = Object.assign(document.createElement('link'), { rel: 'icon', href: cfg.base + C0.logo }); document.head.append(icon); }

(async () => {
  await loadStatus();
  applyStates();
  setTime(currentHour());
  renderClock();
  if (byId[params.get('sel')]) select(params.get('sel'), false);
  frame();
  setInterval(async () => { if (await loadStatus()) applyStates(); }, 15000);
})();
