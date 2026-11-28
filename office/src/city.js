import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { facade, rng, glowTex } from './textures.js';
import { mat } from './people.js';

const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };

// Valle de Aburrá: flat city floor, steep mountains east and west, softer hills north and south.
export function heightAt(x, z) {
  const ax = Math.abs(x), az = Math.abs(z);
  let h = smooth(225, 600, ax) * 330 + smooth(750, 1400, az) * 150;
  const n = Math.sin(x * 0.011 + 1.3) * Math.cos(z * 0.009) * 32 + Math.sin(x * 0.031 + z * 0.017) * 14 + Math.cos(z * 0.023 - x * 0.005) * 10;
  h += n * smooth(200, 400, Math.max(ax, az * 0.6));
  return Math.max(0, h);
}

// comunas grow in barrios separated by green strips
const barrio = (x, z) => Math.sin(x * 0.034 + 0.7) * Math.cos(z * 0.029) + 0.6 * Math.sin((x + z) * 0.017);

// ou/ov shift the window grid per building so lit windows don't repeat tower to tower
export function scaleBoxUV(geo, w, h, d, ou = 0, ov = 0) {
  const uv = geo.attributes.uv;
  for (let f = 0; f < 6; f++) {
    for (let k = 0; k < 4; k++) {
      const i = f * 4 + k;
      if (f === 2 || f === 3) { uv.setXY(i, 0.004, 0.004); continue; }
      const horiz = f < 2 ? d : w;
      uv.setXY(i, uv.getX(i) * horiz / 20.8 + ou, uv.getY(i) * h / 25.6 + ov); // 2.6 m bays, 3.2 m floors
    }
  }
  return geo;
}

export function buildCity(scene) {
  const R = rng(20261127);
  const root = new THREE.Group();
  scene.add(root);
  const nightFns = [];

  // ---------- terrain ----------
  // smooth (indexed) terrain with per-vertex color: no giant facets behind the office
  const tg = new THREE.PlaneGeometry(3400, 3400, 180, 180);
  tg.rotateX(-Math.PI / 2);
  const p = tg.attributes.position;
  for (let i = 0; i < p.count; i++) p.setY(i, heightAt(p.getX(i), p.getZ(i)) - 0.02);
  tg.computeVertexNormals();
  const cols = new Float32Array(p.count * 3);
  const terra = new THREE.Color('#5A4A3E');
  const c = new THREE.Color(), urban = new THREE.Color('#4A4F56'), g1 = new THREE.Color('#2F5130'), g2 = new THREE.Color('#557042'), g3 = new THREE.Color('#46633A');
  for (let i = 0; i < p.count; i++) {
    const h = p.getY(i), x = p.getX(i), z = p.getZ(i);
    if (h < 1) c.copy(urban);
    else {
      c.copy(g1).lerp(g2, Math.min(1, smooth(0, 220, h) * 0.8 + R() * 0.2)); if (R() < 0.15) c.lerp(g3, 0.5);
      if (h > 6 && h < 130) c.lerp(terra, smooth(0.0, 0.5, barrio(x, z)) * 0.85); // barrio ground blends into the green
    }
    c.toArray(cols, i * 3);
  }
  tg.setAttribute('color', new THREE.BufferAttribute(cols, 3));
  const terrain = new THREE.Mesh(tg, new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 1 }));
  terrain.receiveShadow = true;
  root.add(terrain);

  // ---------- facades ----------
  const styles = ['brick', 'brick2', 'concrete', 'glass', 'white'];
  const facMats = {};
  styles.forEach((s, i) => {
    const f = facade(s, 100 + i * 17);
    facMats[s] = new THREE.MeshStandardMaterial({ map: f.map, emissiveMap: f.lit, roughnessMap: f.rough, emissive: '#ffffff', emissiveIntensity: 0, roughness: 1, metalness: s === 'glass' ? 0.35 : 0 });
  });
  nightFns.push((n) => { for (const m of Object.values(facMats)) m.emissiveIntensity = n * 0.4; });
  const geos = Object.fromEntries(styles.map((s) => [s, []]));
  const roofGeos = [], balcGeos = [];
  const pick = (tall) => {
    const r = R();
    if (tall) return r < 0.45 ? 'brick' : r < 0.6 ? 'brick2' : r < 0.8 ? 'glass' : 'white';
    return r < 0.35 ? 'brick' : r < 0.55 ? 'brick2' : r < 0.75 ? 'white' : r < 0.9 ? 'concrete' : 'glass';
  };
  const SLAB = 0.3;
  function building(x, z, w, d, h, style) {
    // a third of the towers get a stepped-back crown so the skyline is not all boxes
    const step = h > 25 && R() < 0.35;
    const hb = step ? h * 0.8 : h;
    const ou = Math.floor(R() * 8) / 8, ov = Math.floor(R() * 8) / 8;
    const geo = scaleBoxUV(new THREE.BoxGeometry(w, hb, d), w, hb, d, ou, ov);
    geo.translate(x, SLAB + hb / 2, z);
    geos[style].push(geo);
    if (h > 8 && Math.hypot(x, z) < 170) { // glazed commercial ground floor on nearby blocks
      const pd = scaleBoxUV(new THREE.BoxGeometry(w + 0.6, 4.2, d + 0.6), w + 0.6, 4.2, d + 0.6); pd.translate(x, SLAB + 2.1, z); geos.glass.push(pd);
    }
    if (step) { const tw = w - 3.5, td = d - 3.5, th = h - hb; const top = scaleBoxUV(new THREE.BoxGeometry(tw, th, td), tw, th, td, ou, ov); top.translate(x, SLAB + hb + th / 2, z); geos[style].push(top); }
    if ((style === 'white' || style === 'brick2') && h > 20 && R() < 0.75) { // balcony slabs, very Poblado
      for (let y = 3.2; y < hb - 1; y += 3.2) { const b = new THREE.BoxGeometry(w + 1.4, 0.22, d + 1.4); b.translate(x, SLAB + y, z); balcGeos.push(b); }
    }
    if (h > 12 && R() < 0.65) {
      const tw = 2 + R() * 2;
      const t = new THREE.BoxGeometry(tw, 2 + R() * 2, tw);
      t.translate(x + (R() - 0.5) * (w - tw - 1), SLAB + h + 1.2, z + (R() - 0.5) * (d - tw - 1));
      roofGeos.push(t);
    }
    if (h > 6) { const pr = new THREE.BoxGeometry(w + 0.4, 0.6, d + 0.4); pr.translate(x, SLAB + h + 0.3, z); roofGeos.push(pr); }
    if (Math.hypot(x, z) < 170) for (let k = 0; k < 2; k++) { // HVAC units on nearby roofs
      const ac = new THREE.BoxGeometry(1.6 + R(), 1.2, 1.2 + R()); ac.translate(x + (R() - 0.5) * (w - 3), SLAB + h + 0.6, z + (R() - 0.5) * (d - 3)); roofGeos.push(ac);
    }
  }
  // exported so the office tower uses the same look
  const P = 48, B = 36, NB = 7;
  const slabs = [];
  const treeSpots = [];
  for (let i = -NB; i <= NB; i++) for (let j = -NB; j <= NB; j++) {
    const bx = i * P, bz = j * P;
    if (i === -4) continue; // river + metro corridor
    if (Math.max(heightAt(bx - B / 2, bz), heightAt(bx + B / 2, bz)) > 0.4) continue; // hillside: comunas take over
    const d = Math.hypot(bx, bz);
    if (i === 0 && j === 0) { slabs.push([bx, bz, 'plaza']); continue; }
    const park = R() < 0.11 || (i === 1 && j === 0) || (i === 1 && j === 1);
    slabs.push([bx, bz, park ? 'park' : 'walk']);
    if (park) { for (let k = 0; k < 16; k++) treeSpots.push([bx + (R() - 0.5) * B * 0.85, bz + (R() - 0.5) * B * 0.85, 1.25]); continue; }
    if (d < 340) {
      for (let s = -B / 2 + 3; s <= B / 2 - 3; s += 8) {
        for (const [tx, tz] of [[bx + s, bz - B / 2 + 1.5], [bx + s, bz + B / 2 - 1.5], [bx - B / 2 + 1.5, bz + s], [bx + B / 2 - 1.5, bz + s]]) if (R() < 0.55) treeSpots.push([tx, tz, 1]);
      }
    }
    // Keep the office (floor at 26 m) and the valley view clear: low near the camera side, mid-rise around, towers far back.
    const front = bx + bz > -10 && d < 260;
    let minH, maxH;
    if (front) { minH = 5; maxH = d < 120 ? 16 : 12 + d * 0.06; }
    else if (d < 180) { minH = 10; maxH = 22; }
    else { minH = 16; maxH = bz < -150 ? 22 + R() * 26 : 20 + R() * 34; }
    if (bz < -40 && bx > -180 && bx < 40) maxH = Math.min(maxH, 22); // keep the view to Coltejer open
    const tall = maxH > 30;
    const hgt = () => minH + R() * (maxH - minH);
    if (R() < 0.42) {
      const w = 16 + R() * 14, dd = 16 + R() * 14;
      building(bx + (R() - 0.5) * (B - w) * 0.8, bz + (R() - 0.5) * (B - dd) * 0.8, w, dd, hgt(), pick(tall));
    } else {
      const n = 2 + Math.floor(R() * 3);
      for (let q = 0; q < n; q++) {
        const w = 10 + R() * 5, dd = 10 + R() * 5;
        const cx = bx + (q % 2 ? 1 : -1) * B / 4, cz = bz + (q < 2 ? -1 : 1) * B / 4;
        building(cx, cz, w, dd, hgt(), pick(tall));
      }
    }
  }
  // Coltejer: the needle of downtown Medellín
  const colX = -70, colZ = -400;
  building(colX, colZ, 18, 26, 150, 'concrete');
  const needle = new THREE.Mesh(new THREE.ConeGeometry(15, 48, 4), mat('#CFCAC0'));
  needle.rotation.y = Math.PI / 4; needle.scale.set(0.6, 1, 1.45); needle.position.set(colX, SLAB + 150 + 24, colZ);
  root.add(needle);
  const slit = new THREE.Mesh(new THREE.BoxGeometry(1.4, 30, 26.6), mat('#26323D')); // Coltejer's dark vertical notch
  slit.position.set(colX, SLAB + 150 + 10, colZ); root.add(slit);
  // more downtown towers around it
  for (let k = 0; k < 26; k++) {
    const x = colX + (R() - 0.5) * 240, z = colZ + (R() - 0.5) * 200;
    if (Math.hypot(x - colX, z - colZ) < 30) continue;
    building(x, z, 16 + R() * 10, 16 + R() * 10, 30 + R() * 50, pick(true));
  }
  for (const s of styles) if (geos[s].length) root.add(new THREE.Mesh(mergeGeometries(geos[s]), facMats[s]));
  root.add(new THREE.Mesh(mergeGeometries(roofGeos), mat('#5E656C')));
  if (balcGeos.length) root.add(new THREE.Mesh(mergeGeometries(balcGeos), mat('#DCD7CD')));

  // sidewalks / parks / plaza
  const slabMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), mat('#ffffff', { roughness: 0.95 }), slabs.length);
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), v = new THREE.Vector3(), sc = new THREE.Vector3();
  slabs.forEach(([x, z, kind], i) => {
    m4.compose(v.set(x, SLAB / 2, z), q.identity(), sc.set(B, SLAB, B));
    slabMesh.setMatrixAt(i, m4);
    slabMesh.setColorAt(i, c.set(kind === 'park' ? '#5D8A47' : kind === 'plaza' ? '#CFC8BC' : '#B8B2A7'));
  });
  slabMesh.receiveShadow = true;
  root.add(slabMesh);

  // lane dashes
  const dashes = [];
  for (let i = -NB - 1; i <= NB; i++) {
    const lc = (i + 0.5) * P;
    for (let s = -NB * P; s < NB * P; s += 7) { dashes.push([lc, s, 0]); dashes.push([s, lc, 1]); }
  }
  const dashMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(0.22, 0.04, 3), mat('#E6E0C8'), dashes.length);
  dashes.forEach(([x, z, rot], i) => { m4.compose(v.set(x, 0.02, z), q.setFromAxisAngle(v.clone().set(0, 1, 0), rot ? Math.PI / 2 : 0), sc.set(1, 1, 1)); dashMesh.setMatrixAt(i, m4); });
  root.add(dashMesh);

  // ---------- trees (guayacanes amarillos y rosados) ----------
  const trunkGeo = new THREE.CylinderGeometry(0.2, 0.3, 2.6, 6); trunkGeo.translate(0, 1.3, 0);
  // three-lobed crown with darker underside so the canopy reads as volume
  const crownGeo = mergeGeometries([[1.5, 0, 0, 0], [1.1, 0.9, 0.5, 0.3], [1.0, -0.8, 0.4, -0.5]].map(([r, x, y, z]) => new THREE.IcosahedronGeometry(r, 1).translate(x, y, z)));
  { const cp = crownGeo.attributes.position, cc = new Float32Array(cp.count * 3); for (let i = 0; i < cp.count; i++) { const k = 0.62 + 0.38 * Math.min(1, Math.max(0, (cp.getY(i) + 1.4) / 2.6)); cc.set([k, k, k], i * 3); } crownGeo.setAttribute('color', new THREE.BufferAttribute(cc, 3)); }
  const trunks = new THREE.InstancedMesh(trunkGeo, mat('#6B4A2F'), treeSpots.length);
  const crowns = new THREE.InstancedMesh(crownGeo, new THREE.MeshStandardMaterial({ flatShading: true, roughness: 0.9, vertexColors: true }), treeSpots.length);
  const greens = ['#4E7F3A', '#5E9443', '#3F6E34', '#6FA04B', '#477A3E'];
  treeSpots.forEach(([x, z, k], i) => {
    const s = (0.8 + R() * 0.7) * k;
    m4.compose(v.set(x, SLAB, z), q.identity(), sc.set(s, s, s)); trunks.setMatrixAt(i, m4);
    q.setFromEuler(new THREE.Euler(R() * 3, R() * 3, R() * 3));
    m4.compose(v.set(x, SLAB + 2.6 * s + 1.1 * s, z), q, sc.set(s * 1.15, s * 0.95, s * 1.15)); crowns.setMatrixAt(i, m4);
    const r = R();
    crowns.setColorAt(i, c.set(r < 0.15 ? '#EDBB2C' : r < 0.23 ? '#DE7FA6' : r < 0.28 ? '#A385CF' : greens[Math.floor(R() * greens.length)]));
  });
  trunks.castShadow = crowns.castShadow = true;
  root.add(trunks, crowns);

  // ---------- cars: lots of yellow taxis ----------
  const lines = [];
  for (let i = -NB - 1; i <= NB; i++) { lines.push(['z', (i + 0.5) * P]); lines.push(['x', (i + 0.5) * P]); }
  const NC = 110;
  const cars = [];
  const carBody = new THREE.InstancedMesh(new THREE.BoxGeometry(1.9, 0.9, 4.3).translate(0, 0.65, 0), mat('#ffffff', { roughness: 0.4, metalness: 0.3 }), NC);
  const carTop = new THREE.InstancedMesh(new THREE.BoxGeometry(1.7, 0.62, 2.2).translate(0, 1.4, -0.2), mat('#1E2A33', { roughness: 0.2, metalness: 0.5 }), NC);
  const carCols = ['#F2C200', '#F2C200', '#F2C200', '#F4F5F7', '#9AA3AB', '#C8323A', '#1F5F8B', '#2B2F38'];
  for (let k = 0; k < NC; k++) {
    const L = R() < 0.45 ? lines[NB * 2 - 4 + Math.floor(R() * 10)] : lines[Math.floor(R() * lines.length)]; // busier near the tower
    cars.push({ axis: L[0], c: L[1], s: (R() * 2 - 1) * NB * P, v: 7 + R() * 7, dir: R() < 0.5 ? 1 : -1 });
    carBody.setColorAt(k, c.set(carCols[Math.floor(R() * carCols.length)]));
  }
  root.add(carBody, carTop);
  // headlights at night
  const headPos = new Float32Array(NC * 3);
  const headGeo = new THREE.BufferGeometry(); headGeo.setAttribute('position', new THREE.BufferAttribute(headPos, 3));
  const glow = glowTex();
  const headMat = new THREE.PointsMaterial({ color: '#FFE9B0', size: 4, map: glow, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, opacity: 0 });
  root.add(new THREE.Points(headGeo, headMat));

  // ---------- river ----------
  const river = new THREE.Mesh(new THREE.PlaneGeometry(24, 3400), new THREE.MeshStandardMaterial({ color: '#4C7A78', roughness: 0.08, metalness: 0.45 }));
  river.rotation.x = -Math.PI / 2; river.position.set(-196, 0.05, 0); root.add(river);
  const banks = new THREE.Mesh(new THREE.PlaneGeometry(36, 3400), mat('#5D8A47'));
  banks.rotation.x = -Math.PI / 2; banks.position.set(-196, 0.03, 0); root.add(banks);

  // ---------- metro (elevated) + Estación Poblado ----------
  const MX = -176;
  const via = new THREE.Mesh(new THREE.BoxGeometry(8, 1.4, 3200), mat('#D3D0C8'));
  via.position.set(MX, 10, 0); via.castShadow = true; root.add(via);
  const pillars = new THREE.InstancedMesh(new THREE.BoxGeometry(2, 10, 2).translate(0, 5, 0), mat('#C9C5BC'), 90);
  for (let k = 0; k < 90; k++) { m4.makeTranslation(MX, 0, -1600 + k * 36); pillars.setMatrixAt(k, m4); }
  root.add(pillars);
  const station = new THREE.Group(); station.position.set(MX, 0, 60); root.add(station);
  const st = (w, h, d, m, x, y, z) => { const b = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m); b.position.set(x, y, z); b.castShadow = true; station.add(b); };
  st(16, 0.6, 70, mat('#BFBAB0'), 0, 10.6, 0);
  st(18, 0.5, 72, mat('#3E7F4F'), 0, 17.2, 0);
  for (const x of [-8, 8]) for (const z of [-30, 0, 30]) st(0.6, 6.5, 0.6, mat('#8E969E'), x, 13.9, z);
  const trains = [0, 1, 2, 3].map((k) => {
    const g = new THREE.Group();
    for (let i = 0; i < 3; i++) {
      const car = new THREE.Group(); car.position.z = i * 20.5; g.add(car);
      const b = new THREE.Mesh(new THREE.BoxGeometry(3, 3.4, 20), mat('#E9ECEF', { roughness: 0.4, metalness: 0.3 })); b.position.y = 1.7; car.add(b);
      const w = new THREE.Mesh(new THREE.BoxGeometry(3.06, 0.9, 18), mat('#1E2A33', { roughness: 0.2 })); w.position.y = 2.3; car.add(w);
      const s = new THREE.Mesh(new THREE.BoxGeometry(3.08, 0.35, 20), mat('#3E9B4F')); s.position.y = 1.2; car.add(s);
    }
    g.position.set(MX + (k % 2 ? 1.9 : -1.9), 10.7, 0);
    root.add(g);
    return { g, z: [-300, 500, 1200, -1000][k], dir: k % 2 ? -1 : 1 };
  });

  // ---------- Metrocable to the eastern hills ----------
  const A = new THREE.Vector3(-232, 0, -150), Bp = new THREE.Vector3(-580, 0, -330); // west line, rising from the metro
  const N = 8, pts = [];
  for (let k = 0; k <= N; k++) {
    const pt = A.clone().lerp(Bp, k / N);
    const gh = heightAt(pt.x, pt.z);
    pt.y = gh + (k === 0 || k === N ? 12 : 26);
    pts.push(pt);
    const towerH = pt.y - gh;
    if (k > 0 && k < N) {
      const t = new THREE.Mesh(new THREE.BoxGeometry(1.4, towerH, 1.4), mat('#9AA3AB', { metalness: 0.4 }));
      t.position.set(pt.x, gh + towerH / 2, pt.z); root.add(t);
      const arm2 = new THREE.Mesh(new THREE.BoxGeometry(1, 0.7, 7), mat('#9AA3AB'));
      arm2.position.set(pt.x, pt.y + 0.4, pt.z); arm2.lookAt(pt.x + 1, pt.y + 0.4, pt.z); root.add(arm2);
    } else {
      const sb = new THREE.Mesh(scaleBoxUV(new THREE.BoxGeometry(18, 13, 26), 18, 13, 26), facMats.glass);
      sb.position.set(pt.x, gh + 6.5, pt.z); root.add(sb);
      const roof = new THREE.Mesh(new THREE.BoxGeometry(22, 1, 30), mat('#8E969E', { metalness: 0.5, roughness: 0.4 }));
      const band = new THREE.Mesh(new THREE.BoxGeometry(22.2, 0.5, 30.2), mat('#3E9B4F')); band.position.set(pt.x, gh + 13.1, pt.z); root.add(band);
      roof.position.set(pt.x, gh + 13.5, pt.z); root.add(roof);
    }
  }
  const dir = Bp.clone().sub(A).setY(0).normalize();
  const perp = new THREE.Vector3(-dir.z, 0, dir.x);
  const cum = [0];
  for (let k = 1; k < pts.length; k++) cum.push(cum[k - 1] + pts[k].distanceTo(pts[k - 1]));
  const total = cum[cum.length - 1];
  const along = (u, out) => {
    const d = u * total;
    let k = 1; while (k < cum.length - 1 && cum[k] < d) k++;
    const f = (d - cum[k - 1]) / (cum[k] - cum[k - 1]);
    return out.copy(pts[k - 1]).lerp(pts[k], f);
  };
  for (const s of [-1, 1]) {
    const lg = new THREE.BufferGeometry().setFromPoints(pts.map((pt) => pt.clone().addScaledVector(perp, s * 2.4)));
    root.add(new THREE.Line(lg, new THREE.LineBasicMaterial({ color: '#2B3036' })));
  }
  const NG = 28;
  const gond = new THREE.InstancedMesh(new THREE.BoxGeometry(2.6, 2.4, 2.6), mat('#ffffff', { roughness: 0.5 }), NG);
  for (let k = 0; k < NG; k++) gond.setColorAt(k, c.set(k % 3 ? '#D9433B' : '#F4F5F7'));
  root.add(gond);

  // ---------- comunas on the slopes + valley fill ----------
  const houses = [], houseLights = [];
  for (let k = 0; k < 60000 && houses.length < 14000; k++) {
    const side = R() < 0.55 ? 1 : -1;
    const x = side * (232 + R() * 420), z = (R() - 0.5) * 1900;
    const h = heightAt(x, z);
    if (h < 6 || h > 130 || barrio(x, z) < 0.15) continue;
    houses.push([x, h, z]);
    if (R() < 0.85) houseLights.push(x, h + 3, z);
  }
  const fill = [], fillLights = [];
  for (let k = 0; k < 7000 && fill.length < 1700; k++) {
    const x = (R() - 0.5) * 560, z = (R() - 0.5) * 2600;
    if (Math.abs(x) < NB * P + 30 && Math.abs(z) < NB * P + 30) continue;
    if (x > -225 && x < -160) continue;
    if (heightAt(x, z) > 1) continue;
    fill.push([x, z]);
  }
  const houseMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1).translate(0, 0.5, 0), mat('#ffffff', { roughness: 0.95 }), houses.length);
  const houseCols = ['#9E5A40', '#A8613F', '#8F4E36', '#B87452', '#C9BFB0', '#A86A4E', '#94553C', '#BFA48C'];
  houses.forEach(([x, h, z], i) => {
    const hh = 2.4 + R() * 2.2; // sunk into the slope so no house floats
    m4.compose(v.set(x, h - 2.2, z), q.setFromAxisAngle(new THREE.Vector3(0, 1, 0), Math.round(R() * 4) * Math.PI / 2 + (R() - 0.5) * 0.3), sc.set(3.4 + R() * 2.2, hh + 2.2, 3.4 + R() * 2.2));
    houseMesh.setMatrixAt(i, m4);
    houseMesh.setColorAt(i, c.set(houseCols[Math.floor(R() * houseCols.length)]));
  });
  root.add(houseMesh);
  const fillMat = facMats.concrete.clone(); fillMat.metalness = 0; nightFns.push((n) => { fillMat.emissiveIntensity = n * 0.4; });
  const fillMesh = new THREE.InstancedMesh(scaleBoxUV(new THREE.BoxGeometry(1, 1, 1), 20, 40, 20).translate(0, 0.5, 0), fillMat, fill.length);
  fill.forEach(([x, z], i) => {
    const h = R() < 0.1 ? 50 + R() * 60 : 8 + R() * 40;
    const w = 12 + R() * 16;
    m4.compose(v.set(x, 0, z), q.identity(), sc.set(w, h, w * (0.7 + R() * 0.6)));
    fillMesh.setMatrixAt(i, m4);
    fillMesh.setColorAt(i, c.set(['#D9A08A', '#E0AE92', '#FFFFFF', '#D5DADF', '#F2EEE6'][Math.floor(R() * 5)]));
    for (let l = 0; l < 4; l++) if (R() < 0.7) fillLights.push(x + (R() - 0.5) * w, R() * h, z + w * 0.55);
  });
  root.add(fillMesh);
  const lightPts = (arr, size, color, atten = true) => {
    const geo = new THREE.BufferGeometry(); geo.setAttribute('position', new THREE.Float32BufferAttribute(arr, 3));
    const m = new THREE.PointsMaterial({ color, size, map: glow, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, opacity: 0, sizeAttenuation: atten, toneMapped: false });
    root.add(new THREE.Points(geo, m));
    return m;
  };
  const streetArr = [];
  for (let i = -NB - 1; i <= NB; i++) for (let j = -NB - 1; j <= NB; j++) {
    const x = (i + 0.5) * P, z = (j + 0.5) * P;
    streetArr.push(x + 6.5, 7, z + 6.5, x - 6.5, 7, z - 6.5);
  }
  const poleGeo = new THREE.CylinderGeometry(0.12, 0.16, 7.2, 6).translate(0, 3.6, 0);
  const poles = new THREE.InstancedMesh(poleGeo, mat('#3A3F45', { metalness: 0.4, roughness: 0.5 }), streetArr.length / 3);
  const heads = new THREE.InstancedMesh(new THREE.BoxGeometry(0.5, 0.18, 0.9), mat('#2B3036'), streetArr.length / 3);
  for (let k = 0; k < streetArr.length / 3; k++) {
    m4.makeTranslation(streetArr[k * 3], 0.3, streetArr[k * 3 + 2]); poles.setMatrixAt(k, m4);
    m4.makeTranslation(streetArr[k * 3], 7.35, streetArr[k * 3 + 2]); heads.setMatrixAt(k, m4);
  }
  root.add(poles, heads);
  const nightPts = [lightPts(houseLights, 4.5, '#FFC46A', false), lightPts(fillLights, 5, '#FFD08A'), lightPts(streetArr, 6, '#FFB65C')];
  nightFns.push((n) => { for (const m of nightPts) m.opacity = n; headMat.opacity = n; });

  // ---------- sky, stars, sun, moon, clouds ----------
  const skyU = { top: { value: new THREE.Color() }, horizon: { value: new THREE.Color() }, bottom: { value: new THREE.Color() } };
  const sky = new THREE.Mesh(new THREE.SphereGeometry(6000, 32, 16), new THREE.ShaderMaterial({
    side: THREE.BackSide, depthWrite: false, uniforms: skyU,
    vertexShader: 'varying vec3 vP; void main(){ vP = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }',
    fragmentShader: `uniform vec3 top; uniform vec3 horizon; uniform vec3 bottom; varying vec3 vP;
      void main(){ float h = normalize(vP).y; vec3 col = h > 0.0 ? mix(horizon, top, pow(h, 0.5)) : mix(horizon, bottom, pow(-h, 0.35));
      gl_FragColor = vec4(col, 1.0);
      #include <tonemapping_fragment>
      #include <colorspace_fragment>
      }`,
  }));
  sky.renderOrder = -1;
  scene.add(sky);
  const starArr = [];
  for (let k = 0; k < 1800; k++) {
    const th = R() * Math.PI * 2, ph = Math.acos(0.1 + R() * 0.9);
    starArr.push(Math.sin(ph) * Math.cos(th) * 5000, Math.cos(ph) * 5000, Math.sin(ph) * Math.sin(th) * 5000);
  }
  const starGeo = new THREE.BufferGeometry(); starGeo.setAttribute('position', new THREE.Float32BufferAttribute(starArr, 3));
  const starMat = new THREE.PointsMaterial({ color: '#E8EEF3', size: 2, sizeAttenuation: false, transparent: true, opacity: 0, depthWrite: false, fog: false });
  scene.add(new THREE.Points(starGeo, starMat));
  const sunDisc = new THREE.Mesh(new THREE.SphereGeometry(90, 24, 16), new THREE.MeshBasicMaterial({ color: '#FFF1C9', fog: false, toneMapped: false }));
  const moon = new THREE.Mesh(new THREE.SphereGeometry(60, 24, 16), new THREE.MeshBasicMaterial({ color: '#EDEBE3', fog: false }));
  scene.add(sunDisc, moon);

  const clouds = [];
  const cloudMat = new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: 1, transparent: true, opacity: 0.92 });
  for (let k = 0; k < 22; k++) {
    const g = new THREE.Group();
    const n = 4 + Math.floor(R() * 4);
    for (let i = 0; i < n; i++) {
      const m = new THREE.Mesh(new THREE.IcosahedronGeometry(1, 2), cloudMat);
      const s = 14 + R() * 20;
      m.scale.set(s * 1.4, s * 0.6, s);
      m.position.set(i * 18 + (R() - 0.5) * 10, (R() - 0.5) * 6, (R() - 0.5) * 16);
      g.add(m);
    }
    const ang = R() * Math.PI * 2, rad = 250 + R() * 1100;
    g.position.set(Math.cos(ang) * rad, 240 + R() * 120, Math.sin(ang) * rad);
    scene.add(g); clouds.push(g);
  }

  const tmp = new THREE.Vector3();
  return {
    facMats, heightAt, root, sky, sunDisc, moon, clouds,
    setSky(top, horizon, bottom, night, sunDir, moonDir) {
      skyU.top.value.copy(top); skyU.horizon.value.copy(horizon); skyU.bottom.value.copy(bottom);
      starMat.opacity = Math.max(0, night - 0.3) * 1.4;
      sunDisc.position.copy(sunDir).multiplyScalar(4500); sunDisc.visible = sunDir.y > -0.05;
      moon.position.copy(moonDir).multiplyScalar(4500); moon.visible = night > 0.4;
      cloudMat.color.copy(horizon).lerp(new THREE.Color('#ffffff'), 0.55 * (1 - night)).multiplyScalar(1 - night * 0.6);
      for (const f of nightFns) f(night);
    },
    update(dt, t) {
      cars.forEach((car, k) => {
        car.s += car.v * car.dir * dt;
        const lim = NB * P;
        if (car.s > lim) car.s = -lim; if (car.s < -lim) car.s = lim;
        const off = car.dir * 2.7;
        if (car.axis === 'z') { v.set(car.c + off, 0, car.s); q.setFromAxisAngle(tmp.set(0, 1, 0), car.dir > 0 ? 0 : Math.PI); }
        else { v.set(car.s, 0, car.c - off); q.setFromAxisAngle(tmp.set(0, 1, 0), car.dir > 0 ? Math.PI / 2 : -Math.PI / 2); }
        m4.compose(v, q, sc.set(1, 1, 1));
        carBody.setMatrixAt(k, m4); carTop.setMatrixAt(k, m4);
        tmp.set(0, 0.8, 2.3).applyQuaternion(q).add(v);
        headPos[k * 3] = tmp.x; headPos[k * 3 + 1] = tmp.y; headPos[k * 3 + 2] = tmp.z;
      });
      carBody.instanceMatrix.needsUpdate = carTop.instanceMatrix.needsUpdate = true;
      headGeo.attributes.position.needsUpdate = true;
      for (const tr of trains) {
        tr.z += tr.dir * 16 * dt;
        if (tr.z > 1500) tr.z = -1500; if (tr.z < -1500) tr.z = 1500;
        tr.g.position.z = tr.z;
        tr.g.rotation.y = tr.dir > 0 ? 0 : Math.PI;
      }
      for (let k = 0; k < NG; k++) {
        const lane = k % 2;
        let u = ((t * 0.012 + k / NG) % 1);
        if (lane) u = 1 - u;
        along(u, v).addScaledVector(perp, lane ? 2.4 : -2.4);
        v.y -= 2.6;
        m4.makeTranslation(v.x, v.y, v.z);
        gond.setMatrixAt(k, m4);
      }
      gond.instanceMatrix.needsUpdate = true;
      for (const cl of clouds) { cl.position.x += dt * 3; if (cl.position.x > 1500) cl.position.x = -1500; }
    },
  };
}
