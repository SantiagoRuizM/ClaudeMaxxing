import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { facade, rng, glowTex, canvasTex } from './textures.js';
import { mat } from './people.js';
import { buildLandmark, paintLandmark } from './landmarks.js';
import { stackParts } from './parts.js';
import EXTRAS from './city-extras/index.js';

// Generic city around the tower, driven by a preset (src/cities/<id>.js, format in cities/index.js). Everything static
// is merged or instanced, so a city costs a few dozen draw calls: the 15 x 15 blocks near the tower, low-cost far
// fill, a painted skyline ring on the horizon (fog gives it the depth) and the city's landmarks built from parts.

const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };
const flat = () => 0;

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

const DEFAULTS = {
  ground: { urban: '#4A4F56', green: ['#2F5130', '#557042', '#46633A'] },
  waterColor: '#4C7A78', shore: '#5D8A47', shoreW: 6,
  heights: { near: [5, 16], mid: [10, 22], far: [16, 48] },
  facades: { mix: { brick: 0.35, brick2: 0.2, white: 0.2, concrete: 0.15, glass: 0.1 }, tall: { brick: 0.45, brick2: 0.15, glass: 0.2, white: 0.2 } },
  parks: 0.11,
  trees: { colors: ['#4E7F3A', '#5E9443', '#3F6E34', '#6FA04B', '#477A3E'], accents: [], palms: 0 },
  fill: { n: 1500, w: 1900, d: 1900, tall: 0.1, min: 8, max: 48, colors: ['#D9A08A', '#E0AE92', '#FFFFFF', '#D5DADF', '#F2EEE6'] },
};

function pickWeighted(weights, r) {
  const entries = Object.entries(weights);
  let sum = entries.reduce((a, [, w]) => a + w, 0) * r;
  for (const [k, w] of entries) { sum -= w; if (sum <= 0) return k; }
  return entries[entries.length - 1][0];
}

export function buildCity(scene, preset) {
  const S = { ...DEFAULTS, ...preset, facades: { ...DEFAULTS.facades, ...preset.facades }, trees: { ...DEFAULTS.trees, ...preset.trees }, fill: { ...DEFAULTS.fill, ...preset.fill } };
  const heightAt = S.terrain || flat;
  const R = rng(20261127);
  const root = new THREE.Group();
  scene.add(root);
  const nightFns = [];
  const updates = [];
  const water = S.water || [];
  const inWater = (x, z, m = 0) => water.some(([x0, z0, x1, z1]) => x > x0 - m && x < x1 + m && z > z0 - m && z < z1 + m);

  // ---------- terrain ----------
  // smooth (indexed) terrain with per-vertex color: no giant facets behind the office
  const tg = new THREE.PlaneGeometry(3400, 3400, 180, 180);
  tg.rotateX(-Math.PI / 2);
  const p = tg.attributes.position;
  for (let i = 0; i < p.count; i++) p.setY(i, heightAt(p.getX(i), p.getZ(i)) - 0.02);
  tg.computeVertexNormals();
  const cols = new Float32Array(p.count * 3);
  const G = S.ground;
  const c = new THREE.Color(), urban = new THREE.Color(G.urban), [g1, g2, g3] = G.green.map((x) => new THREE.Color(x));
  const hill = G.hill ? new THREE.Color(G.hill) : null;
  for (let i = 0; i < p.count; i++) {
    const h = p.getY(i), x = p.getX(i), z = p.getZ(i);
    if (h < 1) c.copy(urban);
    else {
      c.copy(g1).lerp(g2, Math.min(1, smooth(0, 220, h) * 0.8 + R() * 0.2)); if (R() < 0.15) c.lerp(g3, 0.5);
      if (hill && G.hillMix) c.lerp(hill, G.hillMix(x, z, h));
    }
    c.toArray(cols, i * 3);
  }
  tg.setAttribute('color', new THREE.BufferAttribute(cols, 3));
  const terrain = new THREE.Mesh(tg, new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 1 }));
  terrain.receiveShadow = true;
  root.add(terrain);

  // ---------- water ----------
  const waterMat = new THREE.MeshStandardMaterial({ color: S.waterColor, roughness: 0.08, metalness: 0.45 });
  const shoreMat = mat(S.shore);
  for (const [x0, z0, x1, z1] of water) {
    const w = new THREE.Mesh(new THREE.PlaneGeometry(x1 - x0, z1 - z0), waterMat);
    w.rotation.x = -Math.PI / 2; w.position.set((x0 + x1) / 2, 0.05, (z0 + z1) / 2); root.add(w);
    const s = new THREE.Mesh(new THREE.PlaneGeometry(x1 - x0 + 2 * S.shoreW, z1 - z0 + 2 * S.shoreW), shoreMat);
    s.rotation.x = -Math.PI / 2; s.position.set((x0 + x1) / 2, 0.03, (z0 + z1) / 2); root.add(s);
  }

  // ---------- facades ----------
  const styles = ['brick', 'brick2', 'concrete', 'glass', 'white'];
  const facMats = {};
  styles.forEach((s, i) => {
    const f = facade(s, 100 + i * 17, S.facades.colors?.[s]);
    facMats[s] = new THREE.MeshStandardMaterial({ map: f.map, emissiveMap: f.lit, roughnessMap: f.rough, emissive: '#ffffff', emissiveIntensity: 0, roughness: 1, metalness: s === 'glass' ? 0.35 : 0 });
  });
  nightFns.push((n) => { for (const m of Object.values(facMats)) m.emissiveIntensity = n * 0.4; });
  const geos = Object.fromEntries(styles.map((s) => [s, []]));
  const roofGeos = [], balcGeos = [];
  const pick = (tall) => pickWeighted(tall ? S.facades.tall : S.facades.mix, R());
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
    if (S.balconies && (style === 'white' || style === 'brick2') && h > 20 && R() < 0.75) {
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

  // ---------- blocks around the tower ----------
  const P = 48, B = 36, NB = 7;
  const slabs = [];
  const treeSpots = [];
  const H = S.heights;
  const span = ([a, b]) => a + R() * (b - a);
  for (let i = -NB; i <= NB; i++) for (let j = -NB; j <= NB; j++) {
    const bx = i * P, bz = j * P;
    if (inWater(bx, bz, B / 2 + 6)) continue;
    if (Math.max(heightAt(bx - B / 2, bz), heightAt(bx + B / 2, bz)) > 0.4) continue; // hillside
    const d = Math.hypot(bx, bz);
    if (i === 0 && j === 0) { slabs.push([bx, bz, 'plaza']); continue; }
    const park = R() < S.parks || (i === 1 && j === 0) || (i === 1 && j === 1);
    slabs.push([bx, bz, park ? 'park' : 'walk']);
    if (park) { for (let k = 0; k < 16; k++) treeSpots.push([bx + (R() - 0.5) * B * 0.85, bz + (R() - 0.5) * B * 0.85, 1.25]); continue; }
    if (d < 340) {
      for (let s = -B / 2 + 3; s <= B / 2 - 3; s += 8) {
        for (const [tx, tz] of [[bx + s, bz - B / 2 + 1.5], [bx + s, bz + B / 2 - 1.5], [bx - B / 2 + 1.5, bz + s], [bx + B / 2 - 1.5, bz + s]]) if (R() < 0.55) treeSpots.push([tx, tz, 1]);
      }
    }
    // Keep the office (floor at 26 m) and the view clear: low near the camera side, mid-rise around, taller far back.
    const front = bx + bz > -10 && d < 260;
    let minH, maxH;
    if (front) { minH = H.near[0]; maxH = d < 120 ? H.near[1] : H.near[1] - 4 + d * 0.06; }
    else if (d < 180) [minH, maxH] = H.mid;
    else { minH = H.far[0]; maxH = span([H.far[1] * 0.6, H.far[1]]); }
    if (S.corridor && bz < -40 && bx > S.corridor[0] && bx < S.corridor[1]) maxH = Math.min(maxH, H.mid[1]); // keep the view to the landmarks open
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
  // downtown clusters: towers gathered around a point (an ellipse rx x rz)
  for (const K of S.clusters || []) {
    for (let k = 0, placed = 0; k < K.n * 4 && placed < K.n; k++) {
      const x = K.x + (R() - 0.5) * 2 * K.rx, z = K.z + (R() - 0.5) * 2 * K.rz;
      if (((x - K.x) / K.rx) ** 2 + ((z - K.z) / K.rz) ** 2 > 1 || inWater(x, z, 12) || heightAt(x, z) > 1) continue;
      if ((S.landmarks || []).some((L) => Math.hypot(x - L.at[0], z - L.at[1]) < (L.clear || 30))) continue;
      const w = (K.w || [16, 26]);
      building(x, z, span(w), span(w), span([K.min, K.max]), pick(true));
      placed++;
    }
  }
  for (const s of styles) if (geos[s].length) root.add(new THREE.Mesh(mergeGeometries(geos[s]), facMats[s]));
  root.add(new THREE.Mesh(mergeGeometries(roofGeos), mat('#5E656C')));
  if (balcGeos.length) root.add(new THREE.Mesh(mergeGeometries(balcGeos), mat('#DCD7CD')));

  // sidewalks / parks / plaza
  const slabMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), mat('#ffffff', { roughness: 0.95 }), Math.max(1, slabs.length));
  slabMesh.count = slabs.length;
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), v = new THREE.Vector3(), sc = new THREE.Vector3(), up = new THREE.Vector3(0, 1, 0);
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
    for (let s = -NB * P; s < NB * P; s += 7) {
      if (!inWater(lc, s) && heightAt(lc, s) < 0.4) dashes.push([lc, s, 0]);
      if (!inWater(s, lc) && heightAt(s, lc) < 0.4) dashes.push([s, lc, 1]);
    }
  }
  const dashMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(0.22, 0.04, 3), mat('#E6E0C8'), dashes.length);
  dashes.forEach(([x, z, rot], i) => { m4.compose(v.set(x, 0.02, z), q.setFromAxisAngle(up, rot ? Math.PI / 2 : 0), sc.set(1, 1, 1)); dashMesh.setMatrixAt(i, m4); });
  root.add(dashMesh);

  // ---------- trees: broadleaf crowns (with accent colors) and palms ----------
  const T = S.trees;
  const palmSpots = [], broadSpots = [];
  for (const t of treeSpots) (R() < T.palms ? palmSpots : broadSpots).push(t);
  if (broadSpots.length) {
    const trunkGeo = new THREE.CylinderGeometry(0.2, 0.3, 2.6, 6); trunkGeo.translate(0, 1.3, 0);
    // three-lobed crown with darker underside so the canopy reads as volume
    const crownGeo = mergeGeometries([[1.5, 0, 0, 0], [1.1, 0.9, 0.5, 0.3], [1.0, -0.8, 0.4, -0.5]].map(([r, x, y, z]) => new THREE.IcosahedronGeometry(r, 1).translate(x, y, z)));
    { const cp = crownGeo.attributes.position, cc = new Float32Array(cp.count * 3); for (let i = 0; i < cp.count; i++) { const k = 0.62 + 0.38 * Math.min(1, Math.max(0, (cp.getY(i) + 1.4) / 2.6)); cc.set([k, k, k], i * 3); } crownGeo.setAttribute('color', new THREE.BufferAttribute(cc, 3)); }
    const trunks = new THREE.InstancedMesh(trunkGeo, mat('#6B4A2F'), broadSpots.length);
    const crowns = new THREE.InstancedMesh(crownGeo, new THREE.MeshStandardMaterial({ flatShading: true, roughness: 0.9, vertexColors: true }), broadSpots.length);
    broadSpots.forEach(([x, z, k], i) => {
      const s = (0.8 + R() * 0.7) * k;
      m4.compose(v.set(x, SLAB, z), q.identity(), sc.set(s, s, s)); trunks.setMatrixAt(i, m4);
      q.setFromEuler(new THREE.Euler(R() * 3, R() * 3, R() * 3));
      m4.compose(v.set(x, SLAB + 2.6 * s + 1.1 * s, z), q, sc.set(s * 1.15, s * 0.95, s * 1.15)); crowns.setMatrixAt(i, m4);
      let r = R(), col = null;
      for (const [accent, share] of T.accents) { if (r < share) { col = accent; break; } r -= share; }
      crowns.setColorAt(i, c.set(col || T.colors[Math.floor(R() * T.colors.length)]));
    });
    trunks.castShadow = crowns.castShadow = true;
    root.add(trunks, crowns);
  }
  if (palmSpots.length) {
    const trunkGeo = new THREE.CylinderGeometry(0.16, 0.26, 7, 6); trunkGeo.translate(0, 3.5, 0);
    // seven drooping fronds around the top, merged into one crown
    const fronds = mergeGeometries(Array.from({ length: 7 }, (_, k) => {
      const f = new THREE.BoxGeometry(0.7, 0.06, 3.2).translate(0, 0, 1.6);
      f.rotateX(0.45); f.rotateY((k / 7) * Math.PI * 2); return f;
    }));
    fronds.translate(0, 7, 0);
    const trunks = new THREE.InstancedMesh(trunkGeo, mat('#8C7354'), palmSpots.length);
    const crowns = new THREE.InstancedMesh(fronds, mat('#ffffff', { roughness: 0.85 }), palmSpots.length);
    palmSpots.forEach(([x, z, k], i) => {
      const s = (0.85 + R() * 0.5) * k;
      q.setFromAxisAngle(up, R() * 6.3);
      m4.compose(v.set(x, SLAB, z), q, sc.set(s, s, s)); trunks.setMatrixAt(i, m4); crowns.setMatrixAt(i, m4);
      crowns.setColorAt(i, c.set(T.palmColors?.[Math.floor(R() * T.palmColors.length)] || '#4F8A3C'));
    });
    trunks.castShadow = crowns.castShadow = true;
    root.add(trunks, crowns);
  }

  // ---------- far fill: one instanced block for everything between the blocks and the skyline ----------
  const glow = glowTex();
  const F = S.fill;
  const fill = [], fillLights = [];
  for (let k = 0; k < F.n * 5 && fill.length < F.n; k++) {
    const x = (R() - 0.5) * F.w, z = (R() - 0.5) * F.d;
    if (Math.abs(x) < NB * P + 30 && Math.abs(z) < NB * P + 30) continue;
    if (inWater(x, z, 14) || heightAt(x, z) > 1) continue;
    if ((S.landmarks || []).some((L) => Math.hypot(x - L.at[0], z - L.at[1]) < (L.clear || 30))) continue;
    if (S.fillSkip?.(x, z)) continue;
    fill.push([x, z]);
  }
  const fillMat = facMats.concrete.clone(); fillMat.metalness = 0; nightFns.push((n) => { fillMat.emissiveIntensity = n * 0.4; });
  const fillMesh = new THREE.InstancedMesh(scaleBoxUV(new THREE.BoxGeometry(1, 1, 1), 20, 40, 20).translate(0, 0.5, 0), fillMat, Math.max(1, fill.length));
  fillMesh.count = fill.length;
  fill.forEach(([x, z], i) => {
    const h = R() < F.tall ? F.max + R() * F.max * 1.2 : F.min + R() * (F.max - F.min);
    const w = 12 + R() * 16;
    m4.compose(v.set(x, 0, z), q.identity(), sc.set(w, h, w * (0.7 + R() * 0.6)));
    fillMesh.setMatrixAt(i, m4);
    fillMesh.setColorAt(i, c.set(F.colors[Math.floor(R() * F.colors.length)]));
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
    for (const [sx, sz] of [[6.5, 6.5], [-6.5, -6.5]]) if (!inWater(x + sx, z + sz, 4) && heightAt(x + sx, z + sz) < 0.4) streetArr.push(x + sx, 7, z + sz);
  }
  const poleGeo = new THREE.CylinderGeometry(0.12, 0.16, 7.2, 6).translate(0, 3.6, 0);
  const poles = new THREE.InstancedMesh(poleGeo, mat('#3A3F45', { metalness: 0.4, roughness: 0.5 }), streetArr.length / 3);
  const heads = new THREE.InstancedMesh(new THREE.BoxGeometry(0.5, 0.18, 0.9), mat('#2B3036'), streetArr.length / 3);
  for (let k = 0; k < streetArr.length / 3; k++) {
    m4.makeTranslation(streetArr[k * 3], 0.3, streetArr[k * 3 + 2]); poles.setMatrixAt(k, m4);
    m4.makeTranslation(streetArr[k * 3], 7.35, streetArr[k * 3 + 2]); heads.setMatrixAt(k, m4);
  }
  root.add(poles, heads);
  const nightPts = [lightPts(fillLights, 5, '#FFD08A'), lightPts(streetArr, 6, '#FFB65C')];
  nightFns.push((n) => { for (const m of nightPts) m.opacity = n; });

  // ---------- landmarks ----------
  const plainMats = new Map();
  const plain = (kind, color) => {
    const key = `${kind}${color}`;
    if (!plainMats.has(key)) {
      const m = kind === 'metal' ? mat(color, { metalness: 0.7, roughness: 0.3 })
        : kind === 'light' ? new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.05, roughness: 0.5 })
          : mat(color, { roughness: kind === 'stone' ? 0.95 : 0.7 });
      if (kind === 'light') nightFns.push((n) => { m.emissiveIntensity = 0.05 + n * 1.6; });
      plainMats.set(key, m);
    }
    return plainMats.get(key);
  };
  for (const L of S.landmarks || []) root.add(buildLandmark(L, { facMats, scaleBoxUV, plain }));

  // ---------- skyline ring: the city that goes on to the horizon, painted once ----------
  if (S.skyline) root.add(...skylineRing(S.skyline, rng(77), glow, nightFns));

  // ---------- per-city extras (Medellín: metro, Metrocable, comunas, taxis) ----------
  if (S.extras) EXTRAS[S.extras]({ THREE, root, R, mat, heightAt, facMats, scaleBoxUV, glow, lightPts, nightFns, updates, P, NB, SLAB, mergeGeometries });

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

  // one merged mesh per cloud
  const clouds = [];
  const cloudMat = new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: 1, transparent: true, opacity: 0.92 });
  for (let k = 0; k < (S.clouds ?? 22); k++) {
    const n = 4 + Math.floor(R() * 4);
    const puffs = [];
    for (let i = 0; i < n; i++) {
      const s = 14 + R() * 20;
      puffs.push(new THREE.IcosahedronGeometry(1, 2).scale(s * 1.4, s * 0.6, s).translate(i * 18 + (R() - 0.5) * 10, (R() - 0.5) * 6, (R() - 0.5) * 16));
    }
    const g = new THREE.Mesh(mergeGeometries(puffs), cloudMat);
    const ang = R() * Math.PI * 2, rad = 250 + R() * 1100;
    g.position.set(Math.cos(ang) * rad, 240 + R() * 120, Math.sin(ang) * rad);
    scene.add(g); clouds.push(g);
  }

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
      for (const u of updates) u(dt, t);
      for (const cl of clouds) { cl.position.x += dt * 3; if (cl.position.x > 1500) cl.position.x = -1500; }
    },
  };
}

// A cylinder around the scene with the far city painted on it: two tonal layers of towers (the back one lighter), the
// landmarks' silhouettes, and a second texture with lit windows that fades in at night. The scene's fog tints it with
// the time of day. Angles are degrees clockwise from north (-z).
const RING_R = 1500, RING_H = 460, RING_SINK = 20;
function skylineRing(K, R, glow, nightFns) {
  const W = 4096, Hpx = 256;
  const mx = W / (2 * Math.PI * RING_R), my = Hpx / RING_H;
  const base = Hpx - RING_SINK * my;
  const col = (a) => ((0.5 + a / 360) % 1 + 1) % 1 * W;
  const arcs = K.arcs || [[0, 360, 0.6]];
  // [from, to, density]: to may pass 360 to wrap around north
  const density = (a) => Math.max(0, ...arcs.map(([from, to, k]) => ((((a - from) % 360) + 360) % 360 <= to - from ? k : 0)));
  const rects = [];
  const tone = new THREE.Color(K.color || '#56606B');
  const day = canvasTex(W, Hpx, (g) => {
    for (const layer of [0, 1]) {
      const c = tone.clone().lerp(new THREE.Color('#ffffff'), layer ? 0 : 0.18);
      for (let a = 0; a < 360; a += 0.05 + R() * 0.25) {
        const d = density(a);
        if (R() > d) continue;
        const wm = 14 + R() * 30, hm = (K.min ?? 20) + Math.pow(R(), layer ? 1.6 : 1.2) * ((K.max ?? 90) - (K.min ?? 20)) * (0.55 + d * 0.6);
        const x = col(a), w = wm * mx, h = hm * my;
        const cc = c.clone().multiplyScalar(0.88 + R() * 0.2);
        g.fillStyle = `#${cc.getHexString()}`;
        g.fillRect(x - w / 2, base - h, w, h + RING_SINK * my);
        if (layer) rects.push([x - w / 2, base - h, w, h]);
      }
    }
    g.fillStyle = `#${tone.clone().multiplyScalar(0.92).getHexString()}`;
    for (const L of K.landmarks || []) paintLandmark(g, L.parts, col(L.angle), base, mx * (L.scale || 1), my * (L.scale || 1));
  }, { repeat: true });
  const lit = canvasTex(W, Hpx, (g) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, W, Hpx);
    for (const [x, y, w, h] of rects) for (let yy = y + 2; yy < y + h - 1; yy += 2.4) for (let xx = x + 1; xx < x + w - 1; xx += 2) {
      if (R() < 0.22) { g.fillStyle = R() < 0.8 ? '#FFC97A' : '#CFE0FF'; g.fillRect(xx, yy, 1, 1); }
    }
    for (const L of K.landmarks || []) {
      const top = stackParts(L.parts).reduce((m, [y0, h]) => Math.max(m, y0 + h), 0) * my * (L.scale || 1);
      g.fillStyle = '#FF5A4A'; g.fillRect(col(L.angle) - 1, base - top - 1, 2, 2); // aviation light
    }
  }, { repeat: true });
  for (const t of [day, lit]) { t.repeat.x = -1; t.wrapT = THREE.ClampToEdgeWrapping; t.anisotropy = 4; } // seen from inside: mirror so east is right of north
  const geo = new THREE.CylinderGeometry(RING_R, RING_R, RING_H, 160, 1, true);
  const ring = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ map: day, transparent: true, alphaTest: 0.5, side: THREE.BackSide }));
  const litMat = new THREE.MeshBasicMaterial({ map: lit, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, opacity: 0, side: THREE.BackSide, toneMapped: false });
  const lights = new THREE.Mesh(geo, litMat);
  ring.position.y = lights.position.y = RING_H / 2 - RING_SINK;
  lights.scale.setScalar(0.999);
  lights.renderOrder = 1;
  nightFns.push((n) => { litMat.opacity = n * 0.9; });
  return [ring, lights];
}
