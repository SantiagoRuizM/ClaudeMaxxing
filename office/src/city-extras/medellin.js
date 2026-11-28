import { barrio } from '../cities/medellin.js';

// What only Medellín has: the elevated metro with Estación Poblado, the Metrocable to the western hills, the comunas on
// the slopes and its yellow taxis. The only city with moving things besides the clouds.
export default function medellinExtras({ THREE, root, R, mat, heightAt, facMats, scaleBoxUV, glow, lightPts, nightFns, updates, P, NB }) {
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), v = new THREE.Vector3(), sc = new THREE.Vector3(), c = new THREE.Color(), tmp = new THREE.Vector3();

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

  // ---------- Metrocable to the western hills ----------
  const A = new THREE.Vector3(-232, 0, -150), Bp = new THREE.Vector3(-580, 0, -330);
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

  // ---------- comunas on the slopes ----------
  const houses = [], houseLights = [];
  for (let k = 0; k < 60000 && houses.length < 14000; k++) {
    const side = R() < 0.55 ? 1 : -1;
    const x = side * (232 + R() * 420), z = (R() - 0.5) * 1900;
    const h = heightAt(x, z);
    if (h < 6 || h > 130 || barrio(x, z) < 0.15) continue;
    houses.push([x, h, z]);
    if (R() < 0.85) houseLights.push(x, h + 3, z);
  }
  const houseMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1).translate(0, 0.5, 0), mat('#ffffff', { roughness: 0.95 }), houses.length);
  const houseCols = ['#9E5A40', '#A8613F', '#8F4E36', '#B87452', '#C9BFB0', '#A86A4E', '#94553C', '#BFA48C'];
  const yAxis = new THREE.Vector3(0, 1, 0);
  houses.forEach(([x, h, z], i) => {
    const hh = 2.4 + R() * 2.2; // sunk into the slope so no house floats
    m4.compose(v.set(x, h - 2.2, z), q.setFromAxisAngle(yAxis, Math.round(R() * 4) * Math.PI / 2 + (R() - 0.5) * 0.3), sc.set(3.4 + R() * 2.2, hh + 2.2, 3.4 + R() * 2.2));
    houseMesh.setMatrixAt(i, m4);
    houseMesh.setColorAt(i, c.set(houseCols[Math.floor(R() * houseCols.length)]));
  });
  root.add(houseMesh);
  const houseGlow = lightPts(houseLights, 4.5, '#FFC46A', false);

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
  const headPos = new Float32Array(NC * 3);
  const headGeo = new THREE.BufferGeometry(); headGeo.setAttribute('position', new THREE.BufferAttribute(headPos, 3));
  const headMat = new THREE.PointsMaterial({ color: '#FFE9B0', size: 4, map: glow, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, opacity: 0 });
  root.add(new THREE.Points(headGeo, headMat));
  nightFns.push((n) => { houseGlow.opacity = n; headMat.opacity = n; });

  updates.push((dt, t) => {
    cars.forEach((car, k) => {
      car.s += car.v * car.dir * dt;
      const lim = NB * P;
      if (car.s > lim) car.s = -lim; if (car.s < -lim) car.s = lim;
      const off = car.dir * 2.7;
      if (car.axis === 'z') { v.set(car.c + off, 0, car.s); q.setFromAxisAngle(yAxis, car.dir > 0 ? 0 : Math.PI); }
      else { v.set(car.s, 0, car.c - off); q.setFromAxisAngle(yAxis, car.dir > 0 ? Math.PI / 2 : -Math.PI / 2); }
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
  });
}
