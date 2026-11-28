import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { mat } from './people.js';
import * as TX from './textures.js';
import { styleById } from './styles/index.js';

// Floor plan (meters, office-local, origin at floor center): x -15.5..15.5 (west→east), z -10.5..10.5 (north→south).
// North band z<-4.6: west office | Juntas | Recepción | Servidores | Baños | east office. Middle: 4 team pods. South band: cocina, sala, ping-pong, descanso.
// Who sits where comes from team.js (placeTeam): founders[0] west, founders[1] east, pods[k] in POD_X[k].
export const PLAN = { W: 31, D: 21, H: 3.2 };
export const POD_X = [-11.25, -3.75, 3.75, 11.25];
export const POD_Z = -0.2;

// World-scale UVs (one texture tile every `size` meters) for a textured box such as a brick wall; untouched otherwise.
function tileUV(geo, w, h, d, size) {
  if (!size) return geo;
  const uv = geo.attributes.uv;
  for (let f = 0; f < 6; f++) {
    const [U, V] = f < 2 ? [d, h] : f < 4 ? [w, d] : [w, h];
    for (let k = 0; k < 4; k++) { const i = f * 4 + k; uv.setXY(i, uv.getX(i) * U / size, uv.getY(i) * V / size); }
  }
  return geo;
}

export function buildOffice(brand, layout, { company = '', cityName = '', style = styleById() } = {}) {
  const { teams, pods, founders } = layout;
  const S = style;
  const root = new THREE.Group();
  const R = TX.rng(314);
  const shadowy = (m, cast = true) => { m.castShadow = cast; m.receiveShadow = true; return m; };
  const add = (geo, material, x, y, z, parent = root, cast = true) => {
    const m = shadowy(new THREE.Mesh(geo, material), cast);
    m.position.set(x, y, z); parent.add(m); return m;
  };
  // y is the bottom of the box
  const box = (w, h, d, material, x, y, z, parent = root, cast = true) => add(tileUV(new THREE.BoxGeometry(w, h, d), w, h, d, material.userData.tile), material, x, y + h / 2, z, parent, cast);
  const rbox = (w, h, d, material, x, y, z, parent = root, r = 0.04) => add(new RoundedBoxGeometry(w, h, d, 2, r), material, x, y + h / 2, z, parent);
  const plane = (w, d, material, x, y, z, parent = root) => {
    const m = add(new THREE.PlaneGeometry(w, d), material, x, y, z, parent, false);
    m.rotation.x = -Math.PI / 2; return m;
  };

  // its own material, not mat()'s shared one: the brick map must not reach other parts of the same color
  const wallMat = S.wallTexture === 'brick'
    ? Object.assign(new THREE.MeshStandardMaterial({ map: TX.brickWall(S.wall), roughness: 0.95 }), { userData: { tile: 1 } })
    : mat(S.wall);
  const M = {
    wall: wallMat,
    wallWarm: mat(S.wallWarm),
    frame: mat(S.frame, { roughness: 0.45, metalness: 0.4 }),
    glass: new THREE.MeshStandardMaterial({ color: '#B9DCEB', transparent: true, opacity: 0.14, roughness: 0.05, metalness: 0.2, depthWrite: false }),
    oak: mat(S.oak),
    oakDark: mat(S.oakDark),
    white: mat(S.white),
    steel: mat(S.steel, { metalness: 0.55, roughness: 0.35 }),
    dark: mat(S.dark),
    concrete: mat(S.concrete),
    pot: mat(S.pot),
    potDark: mat(S.potDark),
    leaf: S.leaves.map((color) => new THREE.MeshStandardMaterial({ color, roughness: 0.8 })),
    screenOff: new THREE.MeshStandardMaterial({ color: '#0C0F13', roughness: 0.15, metalness: 0.4 }),
  };
  const codeTex = TX.codeTex();
  codeTex.repeat.set(1, 0.32);
  const screens = {
    off: M.screenOff,
    code: new THREE.MeshBasicMaterial({ map: codeTex, toneMapped: false, color: '#D8DEE6' }),
    saver: new THREE.MeshBasicMaterial({ map: TX.saverTex(company), toneMapped: false, color: '#C8D0D8' }),
  };

  // ---------- floor, slab ----------
  const concreteFloor = S.floor.kind === 'concrete';
  const floorTex = concreteFloor ? TX.concreteFloor(S.floor.color) : TX.planks(S.floor.tones); floorTex.repeat.set(6, 4);
  plane(PLAN.W, PLAN.D, new THREE.MeshStandardMaterial({ map: floorTex, roughness: concreteFloor ? 0.38 : 0.68, metalness: concreteFloor ? 0.05 : 0 }), 0, 0, 0);
  // contact shadows: soft dark blobs that anchor furniture to the floor
  const blobMat = new THREE.MeshBasicMaterial({ map: TX.blobTex(), transparent: true, depthWrite: false, opacity: 0.75 });
  const blob = (w, d, x, z, parent = root, y = 0.012) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, d), blobMat);
    m.rotation.x = -Math.PI / 2; m.position.set(x, y, z); m.renderOrder = 1; parent.add(m); return m;
  };
  box(PLAN.W + 0.6, 0.55, PLAN.D + 0.6, M.concrete, 0, -0.55, 0);
  const tileTex = TX.tiles(...S.tiles); tileTex.repeat.set(3, 3);
  const tileMat = new THREE.MeshStandardMaterial({ map: tileTex, roughness: 0.35 });
  plane(4.9, 5.9, tileMat, -13.05, 0.004, 7.55); // kitchen
  plane(3.0, 5.9, tileMat, 8.0, 0.004, -7.55); // baños
  plane(3.5, 5.9, mat(S.serverFloor, { roughness: 0.6 }), 4.75, 0.004, -7.55); // servers

  // ---------- walls ----------
  const H = PLAN.H;
  function oriented(x0, z0, x1, z1) {
    const g = new THREE.Group();
    const len = Math.hypot(x1 - x0, z1 - z0);
    g.position.set((x0 + x1) / 2, 0, (z0 + z1) / 2);
    g.rotation.y = -Math.atan2(z1 - z0, x1 - x0);
    root.add(g);
    return { g, len };
  }
  function windowWall(x0, z0, x1, z1) {
    const { g, len } = oriented(x0, z0, x1, z1);
    box(len, 0.5, 0.22, M.wall, 0, 0, 0, g);
    box(len, 0.32, 0.22, M.wall, 0, H - 0.32, 0, g);
    box(len, H - 0.82, 0.03, M.glass, 0, 0.5, 0, g, false);
    for (let x = -len / 2; x <= len / 2 + 0.01; x += len / Math.round(len / 1.6)) box(0.07, H - 0.82, 0.14, M.frame, x, 0.5, 0, g);
  }
  function parapet(x0, z0, x1, z1) {
    const { g, len } = oriented(x0, z0, x1, z1);
    box(len, 0.28, 0.3, M.wall, 0, 0, 0, g);
    box(len, 0.78, 0.025, M.glass, 0, 0.28, 0, g, false);
    box(len, 0.05, 0.09, M.frame, 0, 1.06, 0, g);
    for (let x = -len / 2; x <= len / 2 + 0.01; x += len / Math.round(len / 1.6)) box(0.05, 1.06, 0.05, M.frame, x, 0, 0, g);
  }
  function wall(x0, z0, x1, z1, { h = 2.7, material = M.wall, door = null, t = 0.12 } = {}) {
    const { g, len } = oriented(x0, z0, x1, z1);
    const segs = door ? [[-len / 2, door[0] - len / 2], [door[1] - len / 2, len / 2]] : [[-len / 2, len / 2]];
    for (const [a, b] of segs) if (b - a > 0.01) box(b - a, h, t, material, (a + b) / 2, 0, 0, g);
    if (door) box(door[1] - door[0], h - 2.15, t, material, (door[0] + door[1]) / 2 - len / 2, 2.15, 0, g);
    return g;
  }
  function glassWall(x0, z0, x1, z1, { h = 2.7, door = null } = {}) {
    const { g, len } = oriented(x0, z0, x1, z1);
    const segs = door ? [[-len / 2, door[0] - len / 2], [door[1] - len / 2, len / 2]] : [[-len / 2, len / 2]];
    for (const [a, b] of segs) {
      if (b - a < 0.01) continue;
      box(b - a, h - 0.1, 0.02, M.glass, (a + b) / 2, 0.05, 0, g, false);
      box(b - a, 0.05, 0.06, M.frame, (a + b) / 2, 0, 0, g);
      box(0.05, h, 0.06, M.frame, a, 0, 0, g); box(0.05, h, 0.06, M.frame, b, 0, 0, g);
      box(b - a, 0.08, 0.02, mat('#E9EDF0', { transparent: true, opacity: 0.85 }), (a + b) / 2, 1.1, 0, g, false); // frosted band
    }
    box(len, 0.06, 0.08, M.frame, 0, h - 0.06, 0, g);
  }

  windowWall(-15.5, -10.5, 15.5, -10.5);
  windowWall(-15.5, -10.5, -15.5, 10.5);
  parapet(15.5, -10.5, 15.5, 10.5);
  parapet(-15.5, 10.5, 15.5, 10.5);

  [-9.5, -3, 3, 6.5, 9.5].forEach((x) => wall(x, -10.39, x, -4.6));
  glassWall(-15.5, -4.6, -9.5, -4.6, { door: [4.6, 5.6] });
  glassWall(-9.5, -4.6, -3, -4.6, { door: [0.4, 1.4] });
  wall(3, -4.6, 6.5, -4.6, { door: [2.3, 3.2], material: M.wallWarm });
  wall(6.5, -4.6, 9.5, -4.6, { door: [0.4, 1.3], material: M.wallWarm });
  glassWall(9.5, -4.6, 15.5, -4.6, { door: [0.4, 1.4] });

  // ---------- helpers: plants, chairs, stations ----------
  function plant(x, z, size = 1, parent = root, tall = false) {
    const g = new THREE.Group(); g.position.set(x, 0, z); parent.add(g);
    add(new THREE.CylinderGeometry(0.24 * size, 0.18 * size, 0.46 * size, 14), R() < 0.5 ? M.pot : M.potDark, 0, 0.23 * size, 0, g);
    const n = tall ? 7 : 4 + Math.floor(R() * 3);
    for (let i = 0; i < n; i++) {
      const s = (0.26 + R() * 0.2) * size;
      const leaf = add(new THREE.IcosahedronGeometry(s, 1), M.leaf[i % 3], (R() - 0.5) * 0.4 * size, (0.55 + R() * (tall ? 1.4 : 0.6)) * size, (R() - 0.5) * 0.4 * size, g);
      leaf.rotation.set(R() * 3, R() * 3, R() * 3);
      leaf.scale.y = 1.2;
    }
    return g;
  }
  function chair(parent, color = S.chair, x = 0, z = 0, rot = 0) {
    const c = new THREE.Group(); c.position.set(x, 0, z); c.rotation.y = rot; parent.add(c);
    for (let i = 0; i < 5; i++) {
      const leg = box(0.04, 0.03, 0.3, M.dark, 0, 0.03, 0, c);
      leg.geometry.translate(0, 0, 0.15); leg.rotation.y = (i / 5) * Math.PI * 2;
    }
    add(new THREE.CylinderGeometry(0.025, 0.025, 0.36, 8), M.steel, 0, 0.22, 0, c);
    rbox(0.5, 0.08, 0.48, mat(color), 0, 0.4, 0, c, 0.035);
    const back = rbox(0.46, 0.54, 0.06, mat(color), 0, 0.56, -0.25, c, 0.03);
    back.rotation.x = -0.1;
    [-1, 1].forEach((s) => { box(0.03, 0.2, 0.03, M.dark, s * 0.26, 0.46, -0.02, c); rbox(0.05, 0.03, 0.26, M.dark, s * 0.26, 0.66, -0.02, c, 0.01); });
    return c;
  }
  function monitor(parent, x, z, rotY, screenMat) {
    const g = new THREE.Group(); g.position.set(x, 0.76, z); g.rotation.y = rotY; parent.add(g);
    box(0.22, 0.015, 0.16, M.dark, 0, 0, 0, g);
    box(0.05, 0.22, 0.035, M.dark, 0, 0, -0.04, g);
    box(0.62, 0.37, 0.03, M.dark, 0, 0.2, -0.02, g);
    const scr = add(new THREE.PlaneGeometry(0.58, 0.33), screenMat, 0, 0.385, -0.004, g, false);
    return scr;
  }
  const stations = {};
  function station(id, x, z, rot, opts = {}) {
    const g = new THREE.Group(); g.position.set(x, 0, z); g.rotation.y = rot; root.add(g);
    const W = opts.wide ? 1.9 : 1.5, Dp = opts.wide ? 0.9 : 0.75;
    const cz = 0.42 + Dp / 2;
    blob(W + 0.7, Dp + 1.4, 0, cz - 0.3, g);
    rbox(W, 0.045, Dp, opts.wide ? M.oakDark : M.oak, 0, 0.72, cz, g, 0.015);
    [-1, 1].forEach((s) => box(0.05, 0.72, Dp - 0.08, M.frame, s * (W / 2 - 0.06), 0, cz, g));
    if (opts.divider) box(W, 0.42, 0.035, mat(opts.divider, { roughness: 0.95 }), 0, 0.765, cz + Dp / 2, g);
    if (opts.wide) box(W - 0.2, 0.5, 0.03, M.oakDark, 0, 0.2, cz + Dp / 2 - 0.05, g);
    const scr = [];
    if (opts.dual) { scr.push(monitor(g, -0.34, cz + Dp / 2 - 0.2, Math.PI - 0.22, M.screenOff)); scr.push(monitor(g, 0.34, cz + Dp / 2 - 0.2, Math.PI + 0.22, M.screenOff)); }
    else scr.push(monitor(g, 0, cz + Dp / 2 - 0.2, Math.PI, M.screenOff));
    box(0.42, 0.02, 0.14, mat('#E4E7EA'), 0, 0.765, 0.62, g);
    rbox(0.06, 0.025, 0.1, mat('#E4E7EA'), 0.32, 0.765, 0.63, g, 0.01);
    if (opts.laptop) {
      box(0.34, 0.015, 0.24, M.steel, -0.62, 0.765, 0.66, g);
      const lid = box(0.34, 0.22, 0.012, M.steel, 0, 0, 0, g);
      lid.geometry.translate(0, 0, 0); lid.position.set(-0.62, 0.89, 0.78); lid.rotation.x = 0.25;
      scr.push(add(new THREE.PlaneGeometry(0.31, 0.19), M.screenOff, -0.62, 0.89, 0.772, g, false));
      scr[scr.length - 1].rotation.set(0.25, Math.PI, 0);
    }
    // personal items
    const r = TX.rng(TX.hash(id));
    if (r() < 0.75) add(new THREE.CylinderGeometry(0.04, 0.036, 0.1, 12), mat(['#F4F5F7', '#C8323A', '#0069AB', '#25A18E'][Math.floor(r() * 4)]), (r() < 0.5 ? 1 : -1) * 0.58, 0.815, 0.58, g);
    if (r() < 0.6) { const pp = box(0.21, 0.012, 0.29, M.white, -0.45, 0.765, 0.75, g); pp.rotation.y = r() - 0.5; }
    if (r() < 0.55) plant(W / 2 - 0.2, cz + 0.15, 0.22, g).position.y = 0.765;
    const ch = chair(g, opts.chair || S.chair, 0, -0.02);
    stations[id] = {
      group: g, chair: ch, screens: scr,
      setScreen(kind) { for (const s of scr) s.material = screens[kind] || screens.off; },
    };
  }

  // ---------- team pods ----------
  pods.forEach(({ team, members }, k) => {
    const cx = POD_X[k];
    const rugT = TX.rugTex(teams[team].rug, k + 3);
    plane(4.6, 4.8, new THREE.MeshStandardMaterial({ map: rugT, roughness: 1 }), cx, 0.006, POD_Z);
    members.forEach((id, i) => {
      const dx = (i % 2 ? 0.77 : -0.77);
      const north = i < 2;
      station(id, cx + dx, POD_Z + (north ? -1.2 : 1.2), north ? 0 : Math.PI, { divider: teams[team].color });
    });
  });
  [-7.5, 0, 7.5].forEach((x) => { add(new THREE.CylinderGeometry(0.2, 0.2, H, 20), mat(S.column), x, H / 2, POD_Z); blob(1, 1, x, POD_Z); });
  // suspended linear lamps over each pod (cutaway ceiling: cables run up out of view)
  const lampOn = new THREE.MeshStandardMaterial({ color: '#F4F1EA', emissive: S.lamp, emissiveIntensity: 0, roughness: 0.6 });
  const pendant = (x, z, len, rotY = 0) => {
    const g = new THREE.Group(); g.position.set(x, 0, z); g.rotation.y = rotY; root.add(g);
    box(len, 0.05, 0.22, mat(S.pendant, { roughness: 0.5 }), 0, 2.62, 0, g);
    box(len - 0.06, 0.012, 0.18, lampOn, 0, 2.608, 0, g, false);
    [-1, 1].forEach((s) => box(0.012, 0.5, 0.012, M.dark, s * (len / 2 - 0.2), 2.67, 0, g, false));
  };
  POD_X.forEach((x) => pendant(x, POD_Z, 3.2));
  pendant(-6.25, -7.6, 2.4); pendant(-12.6, 7.3, 1.8, Math.PI / 2); pendant(0, -7.0, 2.4);
  [-7.5, 7.5].forEach((x) => { plant(x - 0.7, POD_Z + 0.75, 0.9); plant(x + 0.7, POD_Z - 0.75, 0.7); });
  // water cooler + printer
  box(0.36, 1.0, 0.36, M.white, -7.5, 0, 3.4);
  add(new THREE.CylinderGeometry(0.15, 0.15, 0.42, 14), new THREE.MeshStandardMaterial({ color: '#8EC9F0', transparent: true, opacity: 0.7, roughness: 0.1 }), -7.5, 1.21, 3.4);
  rbox(0.6, 0.85, 0.5, mat('#D9DDE1'), 7.5, 0, 3.4); box(0.45, 0.04, 0.3, M.white, 7.5, 0.85, 3.4);

  // ---------- founders' offices ----------
  plane(5.2, 4.6, new THREE.MeshStandardMaterial({ map: TX.rugTex(S.rugs.west, 11), roughness: 1 }), -12.5, 0.006, -7.6);
  station(founders[0] || 'office-west', -12.5, -9.3, 0, { wide: true, laptop: true, chair: S.bossChair });
  chair(root, S.guestChair, -13.1, -6.9, Math.PI); chair(root, S.guestChair, -11.9, -6.9, Math.PI);
  const shelf = (x, z, rot, w = 2.2, h = 2.0) => {
    const g = new THREE.Group(); g.position.set(x, 0, z); g.rotation.y = rot; root.add(g);
    box(w, h, 0.34, M.oakDark, 0, 0, 0, g);
    for (let s = 0; s < Math.floor(h / 0.48); s++) {
      let bx = -w / 2 + 0.08;
      while (bx < w / 2 - 0.2) {
        const bw = 0.04 + R() * 0.05, bh = 0.24 + R() * 0.12;
        box(bw, bh, 0.24, mat(['#0069AB', '#25A18E', '#C8323A', '#F2C14E', '#E8EEF3', '#3A3F45'][Math.floor(R() * 6)]), bx, 0.08 + s * 0.48, 0.06, g);
        bx += bw + 0.01 + (R() < 0.1 ? 0.2 : 0);
      }
    }
    return g;
  };
  shelf(-9.75, -8.0, -Math.PI / 2);
  plant(-15.0, -5.2, 1.3, root, true);
  plane(5.2, 4.6, new THREE.MeshStandardMaterial({ map: TX.rugTex(S.rugs.east, 12), roughness: 1 }), 12.5, 0.006, -7.6);
  station(founders[1] || 'office-east', 12.5, -9.3, 0, { wide: true, dual: true, chair: S.bossChair });
  chair(root, S.chair, 11.9, -6.9, Math.PI); chair(root, S.chair, 13.1, -6.9, Math.PI);
  const wb = add(new THREE.PlaneGeometry(2.3, 1.25), new THREE.MeshStandardMaterial({ map: TX.whiteboardTex(), roughness: 0.4 }), 9.58, 1.55, -7.6, root, false);
  wb.rotation.y = Math.PI / 2;
  box(0.04, 1.35, 2.4, M.steel, 9.57, 0.88, -7.6);
  plant(15.0, -5.2, 1.2, root, true);

  // ---------- meeting room ----------
  rbox(3.4, 0.05, 1.3, M.oak, -6.25, 0.72, -7.6, root, 0.02);
  [-1, 1].forEach((s) => box(0.08, 0.72, 0.9, M.frame, -6.25 + s * 1.3, 0, -7.6));
  [-7.4, -6.25, -5.1].forEach((x) => { chair(root, S.meetingChair, x, -8.65, 0); chair(root, S.meetingChair, x, -6.55, Math.PI); });
  box(0.05, 1.2, 2.1, M.dark, -9.41, 0.95, -7.6);
  const tv = add(new THREE.PlaneGeometry(1.98, 1.1), new THREE.MeshBasicMaterial({ map: TX.dashTex(company), toneMapped: false, color: '#D0D6DD' }), -9.38, 1.55, -7.6, root, false);
  tv.rotation.y = Math.PI / 2;
  plant(-3.6, -10.0, 0.8);

  // ---------- reception ----------
  box(6, H, 0.16, mat(S.receptionWall), 0, 0, -10.3);
  // elevator doors flanking the logo wall
  [-2.55, 2.55].forEach((x) => {
    box(0.85, 2.2, 0.05, M.steel, x, 0, -10.2);
    box(0.012, 2.15, 0.06, M.dark, x, 0, -10.19, root, false);
    box(0.18, 0.06, 0.02, new THREE.MeshBasicMaterial({ color: '#7FD1B9', toneMapped: false }), x, 2.32, -10.2, root, false);
  });
  const logoMat = new THREE.MeshStandardMaterial({ map: brand.wordmark, transparent: true, roughness: 0.5, emissiveMap: brand.wordmark, emissive: '#ffffff', emissiveIntensity: 0.15 });
  add(new THREE.PlaneGeometry(3.3, 0.57), logoMat, 0, 2.45, -10.17, root, false);
  rbox(3.0, 1.05, 0.7, M.white, 0, 0, -7.0, root, 0.05);
  rbox(3.15, 0.05, 0.85, M.oak, 0, 1.05, -7.0, root, 0.02);
  box(2.98, 0.04, 0.02, new THREE.MeshBasicMaterial({ color: '#2F93D6', toneMapped: false }), 0, 0.9, -6.64);
  add(new THREE.PlaneGeometry(0.36, 0.55), new THREE.MeshStandardMaterial({ map: brand.isotipo, transparent: true, roughness: 0.5 }), 0, 0.45, -6.643, root, false);
  chair(root, S.chair, 0, -7.9, 0);
  plant(-2.4, -6.0, 1.1, root, true); plant(2.4, -6.0, 1.1, root, true);
  // framed posters on the reception side walls
  const poster = (map, x, z, rotY, w = 0.9, h = 1.27) => {
    const g = new THREE.Group(); g.position.set(x, 1.55, z); g.rotation.y = rotY; root.add(g);
    add(new THREE.BoxGeometry(w + 0.08, h + 0.08, 0.04), M.dark, 0, 0, 0, g, false);
    add(new THREE.PlaneGeometry(w, h), M.white, 0, 0, 0.021, g, false);
    add(new THREE.PlaneGeometry(w * 0.92, h * 0.92), new THREE.MeshStandardMaterial({ map, roughness: 0.6, transparent: true }), 0, 0, 0.023, g, false);
  };
  poster(TX.cityPoster(cityName), -2.92, -8.2, Math.PI / 2);
  poster(brand.isotipo, 2.92, -8.2, -Math.PI / 2, 0.62, 0.95);
  // waiting bench
  rbox(2.2, 0.42, 0.6, mat(S.bench), 0, 0, -5.3, root, 0.06);

  // ---------- servers ----------
  const ledGeo = new THREE.BoxGeometry(0.05, 0.022, 0.01);
  const leds = new THREE.InstancedMesh(ledGeo, new THREE.MeshBasicMaterial({ toneMapped: false }), 3 * 9 * 3);
  let li = 0;
  const m4 = new THREE.Matrix4();
  [3.8, 4.6, 5.4].forEach((x) => {
    box(0.66, 2.05, 0.95, M.dark, x, 0, -9.7);
    box(0.6, 1.9, 0.01, mat('#2C3238', { metalness: 0.5, roughness: 0.4 }), x, 0.08, -9.22);
    for (let row = 0; row < 9; row++) for (let c = 0; c < 3; c++) {
      m4.makeTranslation(x - 0.18 + c * 0.1, 0.25 + row * 0.19, -9.21);
      leds.setMatrixAt(li++, m4);
    }
  });
  const ledCol = new THREE.Color();
  for (let i = 0; i < leds.count; i++) leds.setColorAt(i, ledCol.set('#2BE07A'));
  root.add(leds);
  box(0.9, 0.35, 0.25, M.white, 4.75, 2.25, -10.25);

  // ---------- baños ----------
  rbox(1.2, 0.85, 0.5, M.white, 8.0, 0, -10.05, root, 0.04);
  box(1.0, 0.7, 0.02, M.steel, 8.0, 1.25, -10.29);
  wall(6.5, -7.6, 9.5, -7.6, { h: 2.1, material: M.wallWarm, door: [1.0, 1.9] });

  // ---------- kitchen ----------
  rbox(0.7, 0.9, 4.4, M.white, -15.05, 0, 7.6, root, 0.03);
  box(0.74, 0.04, 4.44, mat(S.counter, { roughness: 0.3 }), -15.05, 0.9, 7.6);
  rbox(0.8, 1.95, 0.75, M.steel, -15.0, 0, 4.95, root, 0.04);
  box(0.32, 0.42, 0.36, M.dark, -15.1, 0.94, 6.3);
  box(0.06, 0.06, 0.02, new THREE.MeshBasicMaterial({ color: '#E5484D', toneMapped: false }), -14.93, 1.24, 6.3);
  box(0.42, 0.04, 0.5, M.steel, -15.0, 0.925, 8.4);
  add(new THREE.CylinderGeometry(0.18, 0.14, 0.12, 16), mat('#E9B830'), -15.0, 0.99, 9.2);
  rbox(0.75, 0.05, 2.2, M.oak, -12.6, 1.02, 7.3, root, 0.02);
  [6.6, 8.0].forEach((z) => { box(0.08, 1.02, 0.08, M.frame, -12.6, 0, z); });
  [6.6, 7.9].forEach((z) => {
    add(new THREE.CylinderGeometry(0.17, 0.17, 0.05, 16), mat('#25A18E'), -13.25, 0.74, z);
    add(new THREE.CylinderGeometry(0.025, 0.025, 0.74, 8), M.frame, -13.25, 0.37, z);
  });

  // ---------- lounge ----------
  plane(5.4, 3.8, new THREE.MeshStandardMaterial({ map: TX.rugTex(S.rugs.lounge, 21), roughness: 1 }), -8.1, 0.006, 8.55);
  const sofa = new THREE.Group(); sofa.position.set(-8.1, 0, 9.95); sofa.rotation.y = Math.PI; root.add(sofa);
  const sofaMat = mat(S.sofa, { roughness: 0.95 });
  rbox(3.0, 0.38, 0.9, sofaMat, 0, 0.04, 0, sofa, 0.08);
  rbox(3.0, 0.5, 0.22, sofaMat, 0, 0.38, -0.34, sofa, 0.08);
  [-1, 1].forEach((s) => { rbox(0.22, 0.6, 0.9, sofaMat, s * 1.5, 0.04, 0, sofa, 0.08); rbox(1.38, 0.12, 0.72, mat(S.sofaSeat, { roughness: 0.95 }), s * 0.72, 0.38, 0.05, sofa, 0.05); });
  rbox(1.3, 0.38, 0.7, M.oak, -8.1, 0, 8.45, root, 0.03);
  box(0.3, 0.02, 0.22, mat('#C8323A'), -8.4, 0.38, 8.4);
  const arm = new THREE.Group(); arm.position.set(-10.6, 0, 8.3); arm.rotation.y = Math.PI / 2; root.add(arm);
  rbox(0.9, 0.4, 0.85, mat(S.armchair, { roughness: 0.95 }), 0, 0.04, 0, arm, 0.08);
  rbox(0.9, 0.5, 0.2, mat(S.armchair, { roughness: 0.95 }), 0, 0.4, -0.32, arm, 0.08);
  // floor lamp
  add(new THREE.CylinderGeometry(0.02, 0.02, 1.6, 8), M.frame, -6.2, 0.8, 9.9);
  const lampMat = new THREE.MeshStandardMaterial({ color: S.floorLamp, emissive: S.lamp, emissiveIntensity: 0, roughness: 0.8 });
  add(new THREE.CylinderGeometry(0.16, 0.24, 0.3, 16, 1, true), lampMat, -6.2, 1.7, 9.9);

  // office dog: a caramel criollo asleep on its cushion
  const dog = new THREE.Group(); dog.position.set(-5.7, 0, 8.7); dog.rotation.y = 0.6; root.add(dog);
  add(new THREE.CylinderGeometry(0.5, 0.52, 0.12, 24), mat('#5C6B7A', { roughness: 1 }), 0, 0.06, 0, dog);
  const fur = mat('#C58A52', { roughness: 0.95 });
  const dogBody = rbox(0.62, 0.24, 0.34, fur, 0, 0.12, 0, dog, 0.1);
  const dogHead = rbox(0.24, 0.18, 0.22, fur, 0.3, 0.13, 0.12, dog, 0.06);
  dogHead.rotation.y = -0.5;
  rbox(0.1, 0.07, 0.1, mat('#E8D2B4'), 0.42, 0.14, 0.2, dog, 0.03); // snout
  [-1, 1].forEach((s) => { const ear = rbox(0.07, 0.1, 0.03, mat('#8A5A33'), 0.26, 0.27, 0.12 + s * 0.08, dog, 0.015); ear.rotation.x = s * 0.5; });
  const tail = rbox(0.3, 0.07, 0.07, fur, -0.22, 0.15, 0.2, dog, 0.03); tail.rotation.y = -0.9;
  blob(1.2, 1.2, -5.7, 8.7);

  // ---------- ping-pong ----------
  const PP = { x: -1.4, z: 7.4 };
  box(2.74, 0.05, 1.525, mat('#1D4F8F', { roughness: 0.5 }), PP.x, 0.71, PP.z);
  const lineMat = new THREE.MeshBasicMaterial({ color: '#F4F5F7' });
  box(2.74, 0.004, 0.02, lineMat, PP.x, 0.762, PP.z, root, false);
  [-1, 1].forEach((s) => box(2.74, 0.004, 0.02, lineMat, PP.x, 0.762, PP.z + s * 0.752, root, false));
  box(0.02, 0.16, 1.7, new THREE.MeshStandardMaterial({ color: '#F4F5F7', transparent: true, opacity: 0.75 }), PP.x, 0.76, PP.z);
  [-1, 1].forEach((s) => box(0.08, 0.71, 1.2, M.frame, PP.x + s * 1.0, 0, PP.z));
  const ball = add(new THREE.SphereGeometry(0.035, 10, 8), new THREE.MeshStandardMaterial({ color: '#FF8A00', emissive: '#FF8A00', emissiveIntensity: 0.4 }), PP.x, 0.9, PP.z);

  // ---------- rest zone ----------
  plane(6.5, 4.6, new THREE.MeshStandardMaterial({ map: TX.rugTex(S.rugs.rest, 31), roughness: 1 }), 8.6, 0.006, 7.8);
  const beanbag = (x, z, c) => {
    const b = add(new THREE.SphereGeometry(0.55, 18, 12), mat(c, { roughness: 1 }), x, 0.28, z);
    b.scale.set(1.25, 0.58, 1.25);
  };
  beanbag(6.6, 7.9, S.beanbags[0]); beanbag(8.6, 8.5, S.beanbags[1]); beanbag(10.4, 7.6, S.beanbags[2]);
  shelf(12.5, 5.0, 0, 3.0, 1.1);
  plant(15.0, 5.0, 1.2, root, true); plant(4.6, 10.0, 1.0, root, true); plant(11.5, 10.0, 0.9);
  // planters along the south parapet
  [-12.5, -4.8, 2.8].forEach((x) => {
    rbox(1.6, 0.45, 0.45, M.potDark, x, 0, 10.1, root, 0.03);
    for (let i = 0; i < 5; i++) {
      const l = add(new THREE.IcosahedronGeometry(0.22 + R() * 0.1, 0), M.leaf[i % 3], x - 0.6 + i * 0.3, 0.6, 10.1);
      l.rotation.set(R() * 3, R() * 3, 0);
    }
  });
  plant(-15.0, 10.0, 1.0, root, true);

  // ---------- night lights ----------
  const lights = [];
  blob(3.6, 1.7, -8.1, 9.95); blob(3.4, 2.2, PP.x, PP.z); blob(4.0, 2.0, -6.25, -7.6); blob(3.6, 1.4, 0, -7.0);
  blob(1.6, 5.2, -15.0, 7.4); [[6.6, 7.9], [8.6, 8.5], [10.4, 7.6]].forEach(([x, z]) => blob(1.9, 1.9, x, z));
  [[-12.5, -7.5], [12.5, -7.5], [-6.25, -7.5], ...POD_X.map((x) => [x, POD_Z]), [-8.1, 8.2], [-1.4, 7.4], [8.6, 7.8], [-13.0, 7.3], [0, -7.0]].forEach(([x, z]) => {
    const l = new THREE.PointLight(z > -1.5 && z < 1.5 ? S.lightCool : S.lightWarm, 0, 8.5, 2);
    l.userData.boost = z > -1.5 && z < 1.5 ? 9 : 13;
    l.position.set(x, 2.55, z);
    root.add(l); lights.push(l);
  });

  // ---------- idle slots (order matters: pairs first, absences last) ----------
  const slots = [
    { kind: 'pingpong', pos: [PP.x - 2.05, PP.z], rot: Math.PI / 2, side: 0 },
    { kind: 'pingpong', pos: [PP.x + 2.05, PP.z], rot: -Math.PI / 2, side: 1 },
    { kind: 'sleepDesk' },
    { kind: 'phoneDesk' },
    { kind: 'sofaPhone', pos: [-8.82, 9.85], rot: Math.PI },
    { kind: 'coffee', pos: [-14.2, 6.3], rot: -Math.PI / 2 },
    { kind: 'sleepBack' },
    { kind: 'beanbag', pos: [6.6, 8.05], rot: 0.35 },
    { kind: 'phoneDesk' },
    { kind: 'sofaPhone', pos: [-7.38, 9.85], rot: Math.PI },
    { kind: 'coffee', pos: [-11.95, 7.3], rot: -Math.PI / 2 },
    { kind: 'standPhone', pos: [13.6, 9.6], rot: Math.PI },
    { kind: 'sleepDesk' },
    { kind: 'absent' },
    { kind: 'absent' },
    { kind: 'absent' },
  ];

  const officeOf = (id) => (id ? `Oficina ${layout.people.find((p) => p.id === id).name.split(' ')[0]}` : 'Oficina');
  const rooms = [
    [officeOf(founders[0]), -12.5, -5.4], ['Sala de juntas', -6.25, -5.4], ['Recepción', 0, -4.4], ['Servidores', 4.75, -5.4],
    ['Baños', 8.0, -5.4], [officeOf(founders[1]), 12.5, -5.4],
    ...pods.map(({ team }, k) => [teams[team].name, POD_X[k], 2.9]),
    ['Cocina', -13.0, 9.7], ['Sala', -8.1, 7.2], ['Perro de la oficina', -5.7, 9.5], ['Ping-pong', -1.4, 9.3], ['Zona de descanso', 8.6, 6.0],
  ];

  let blinkT = 0;
  return {
    root, stations, slots, rooms, lights, ball, PP,
    setNight(n) {
      for (const l of lights) l.intensity = n * l.userData.boost;
      lampOn.emissiveIntensity = 0.15 + n * 2.2;
      lampMat.emissiveIntensity = n * 1.5;
      logoMat.emissiveIntensity = 0.15 + n * 0.6;
    },
    update(dt, t) {
      codeTex.offset.y = (codeTex.offset.y - dt * 0.04) % 1;
      dogBody.scale.y = 1 + Math.sin(t * 2.2) * 0.06;
      blinkT += dt;
      if (blinkT > 0.18) {
        blinkT = 0;
        for (let i = 0; i < leds.count; i++) {
          const v = Math.random();
          leds.setColorAt(i, ledCol.set(v < 0.08 ? '#F2C14E' : v < 0.5 ? '#2BE07A' : v < 0.6 ? '#2F93D6' : '#0E3B22'));
        }
        leds.instanceColor.needsUpdate = true;
      }
    },
  };
}
