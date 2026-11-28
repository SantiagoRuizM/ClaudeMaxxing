import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { shade, blobTex } from './textures.js';

const matCache = new Map();
export function mat(color, opts = {}) {
  const key = color + JSON.stringify(opts);
  if (!matCache.has(key)) matCache.set(key, new THREE.MeshStandardMaterial({ color, roughness: 0.78, metalness: 0, ...opts }));
  return matCache.get(key);
}

const geoCache = new Map();
export function rgeo(w, h, d, r) {
  const rad = r ?? Math.min(w, h, d) * 0.25;
  const k = [w, h, d, rad].join();
  if (!geoCache.has(k)) geoCache.set(k, new RoundedBoxGeometry(w, h, d, 2, rad));
  return geoCache.get(k);
}

function part(parent, w, h, d, color, x, y, z, r) {
  const m = new THREE.Mesh(rgeo(w, h, d, r), typeof color === 'string' ? mat(color) : color);
  m.position.set(x, y, z);
  m.castShadow = true; m.receiveShadow = true;
  parent.add(m);
  return m;
}

const blobMat = new THREE.MeshBasicMaterial({ map: blobTex(), transparent: true, depthWrite: false, opacity: 0.6 });
const glassesMat = new THREE.MeshStandardMaterial({ color: '#1E232B', transparent: true, opacity: 0.55, roughness: 0.2 });
const phoneGlow = new THREE.MeshBasicMaterial({ color: '#9FD4FF', toneMapped: false });

function hair(head, style, hc) {
  const sideHair = (h = 0.13, y = 0.26) => [-1, 1].forEach((s) => part(head, 0.03, h, 0.22, hc, s * 0.155, y, -0.03, 0.01));
  const short = () => {
    part(head, 0.32, 0.08, 0.31, hc, 0, 0.33, -0.005, 0.03);
    part(head, 0.32, 0.22, 0.06, hc, 0, 0.23, -0.13, 0.02);
    part(head, 0.3, 0.05, 0.05, hc, 0, 0.305, 0.13, 0.015);
    sideHair();
  };
  switch (style) {
    case 'short': short(); break;
    case 'buzz':
      part(head, 0.31, 0.03, 0.3, hc, 0, 0.325, -0.005, 0.01);
      part(head, 0.31, 0.17, 0.03, hc, 0, 0.23, -0.14, 0.01);
      break;
    case 'long':
      short();
      part(head, 0.34, 0.44, 0.07, hc, 0, 0.1, -0.15, 0.03);
      [-1, 1].forEach((s) => part(head, 0.04, 0.36, 0.22, hc, s * 0.162, 0.12, -0.03, 0.015));
      break;
    case 'ponytail': {
      short();
      const tail = part(head, 0.09, 0.3, 0.09, hc, 0, 0.12, -0.21, 0.04);
      tail.rotation.x = 0.35;
      break;
    }
    case 'bun': {
      short();
      const bun = new THREE.Mesh(new THREE.SphereGeometry(0.085, 12, 10), mat(hc));
      bun.position.set(0, 0.37, -0.1); bun.castShadow = true;
      head.add(bun);
      break;
    }
    case 'afro':
      part(head, 0.42, 0.3, 0.36, hc, 0, 0.28, -0.05, 0.12);
      break;
    case 'curly':
      part(head, 0.36, 0.13, 0.34, hc, 0, 0.33, -0.02, 0.06);
      part(head, 0.35, 0.24, 0.08, hc, 0, 0.22, -0.13, 0.04);
      [-1, 1].forEach((s) => part(head, 0.05, 0.14, 0.24, hc, s * 0.16, 0.26, -0.03, 0.02));
      break;
    case 'slick': {
      // Hair combed straight back: flat top, a swept-back front, short sides.
      part(head, 0.31, 0.07, 0.29, hc, 0, 0.335, -0.015, 0.03);
      const quiff = part(head, 0.29, 0.07, 0.13, hc, 0, 0.345, 0.08, 0.03);
      quiff.rotation.x = -0.28;
      part(head, 0.31, 0.24, 0.06, hc, 0, 0.22, -0.14, 0.02);
      sideHair(0.1, 0.275);
      break;
    }
    default: break; // bald
  }
}

function beard(head, bc) {
  part(head, 0.3, 0.13, 0.07, bc, 0, 0.035, 0.12, 0.03);
  part(head, 0.29, 0.06, 0.24, bc, 0, -0.005, 0.0, 0.03);
  [-1, 1].forEach((s) => part(head, 0.035, 0.17, 0.2, bc, s * 0.148, 0.1, 0.02, 0.012));
  part(head, 0.16, 0.035, 0.03, bc, 0, 0.105, 0.155, 0.012);
}

export function makePerson(p) {
  const L = p.look;
  const s = L.height / 1.75;
  const g = new THREE.Group();
  const body = new THREE.Group();
  body.scale.setScalar(s);
  g.add(body);

  const pants = L.pants || '#2B2F38';
  const shoes = L.shoes || '#1B1E24';
  const shirt = L.shirt;
  const legs = [-1, 1].map((side) => {
    const hip = new THREE.Group(); hip.position.set(side * 0.1, 0.86, 0); body.add(hip);
    part(hip, 0.16, 0.46, 0.18, pants, 0, -0.21, 0);
    const knee = new THREE.Group(); knee.position.y = -0.44; hip.add(knee);
    part(knee, 0.14, 0.38, 0.16, pants, 0, -0.18, 0);
    part(knee, 0.15, 0.08, 0.27, shoes, 0, -0.38, 0.05, 0.03);
    return { hip, knee };
  });

  const upper = new THREE.Group(); upper.position.y = 0.86; body.add(upper);
  part(upper, 0.37, 0.16, 0.21, pants, 0, 0.04, 0);
  part(upper, 0.42, 0.5, 0.24, shirt, 0, 0.33, 0, 0.07);
  if (L.top === 'blazer') {
    part(upper, 0.13, 0.4, 0.02, L.inner || '#F4F7FA', 0, 0.37, 0.118, 0.006);
    [-1, 1].forEach((sd) => { const lap = part(upper, 0.05, 0.22, 0.02, shade(shirt, 0.8), sd * 0.075, 0.46, 0.122, 0.006); lap.rotation.z = sd * 0.35; });
  }
  if (L.top === 'hoodie') {
    part(upper, 0.32, 0.12, 0.12, shade(shirt, 0.85), 0, 0.56, -0.1, 0.05);
    part(upper, 0.26, 0.1, 0.02, shade(shirt, 0.85), 0, 0.2, 0.12, 0.008);
    [-1, 1].forEach((sd) => part(upper, 0.015, 0.13, 0.015, '#F4F7FA', sd * 0.045, 0.47, 0.125, 0.005));
  }
  part(upper, 0.11, 0.07, 0.11, L.skin, 0, 0.6, 0);

  const head = new THREE.Group(); head.position.y = 0.62; head.scale.setScalar(1.08); upper.add(head);
  part(head, 0.3, 0.32, 0.29, L.hair === 'bald' ? mat(L.skin, { roughness: 0.42 }) : L.skin, 0, 0.17, 0, 0.07);
  const eyes = [-1, 1].map((sd) => part(head, 0.045, 0.055, 0.02, '#1B1B1B', sd * 0.07, 0.19, 0.142, 0.008));
  eyes.forEach((e) => { const hl = new THREE.Mesh(rgeo(0.014, 0.014, 0.006, 0.002), mat('#FFFFFF')); hl.position.set(0.009, 0.012, 0.011); e.add(hl); }); // catchlight
  const browC = L.hairColor || L.beard || shade(L.skin, 0.5);
  [-1, 1].forEach((sd) => part(head, 0.075, 0.018, 0.02, browC, sd * 0.07, 0.25, 0.145, 0.005));
  part(head, 0.045, 0.06, 0.05, shade(L.skin, 0.9), 0, 0.13, 0.155, 0.015);
  const mouth = part(head, 0.08, 0.016, 0.01, '#7A3E36', 0, 0.072, 0.147, 0.004);
  [-1, 1].forEach((sd) => part(head, 0.035, 0.075, 0.07, L.skin, sd * 0.158, 0.17, 0, 0.012));
  hair(head, L.hair, L.hairColor);
  if (L.beard) beard(head, L.beard);
  if (L.glasses) {
    [-1, 1].forEach((sd) => {
      part(head, 0.095, 0.065, 0.012, glassesMat, sd * 0.07, 0.19, 0.157, 0.012);
      part(head, 0.01, 0.012, 0.17, '#1E232B', sd * 0.152, 0.2, 0.07, 0.003);
    });
    part(head, 0.05, 0.012, 0.01, '#1E232B', 0, 0.2, 0.158, 0.003);
  }

  const arms = [-1, 1].map((side) => {
    const sh = new THREE.Group(); sh.position.set(side * 0.27, 0.52, 0); upper.add(sh);
    part(sh, 0.12, 0.3, 0.13, shirt, 0, -0.13, 0, 0.05);
    const el = new THREE.Group(); el.position.y = -0.28; sh.add(el);
    part(el, 0.11, 0.25, 0.12, L.sleeves === 'short' ? L.skin : shirt, 0, -0.12, 0, 0.045);
    const hand = new THREE.Group(); hand.position.y = -0.27; el.add(hand);
    part(hand, 0.1, 0.1, 0.1, L.skin, 0, -0.01, 0, 0.035);
    return { sh, el, hand, side };
  });

  // props held in the right hand
  const phone = new THREE.Group();
  part(phone, 0.075, 0.15, 0.014, '#15181D', 0, 0, 0, 0.01);
  const scr = new THREE.Mesh(new THREE.PlaneGeometry(0.064, 0.134), phoneGlow);
  scr.position.z = 0.008; phone.add(scr);
  phone.position.set(-0.02, -0.08, 0.05);
  arms[1].hand.add(phone);

  const mug = new THREE.Group();
  const cup = new THREE.Mesh(new THREE.CylinderGeometry(0.045, 0.04, 0.11, 14), mat('#F4F5F7'));
  cup.castShadow = true; mug.add(cup);
  const coffee = new THREE.Mesh(new THREE.CircleGeometry(0.04, 14), mat('#3B2416'));
  coffee.rotation.x = -Math.PI / 2; coffee.position.y = 0.05; mug.add(coffee);
  mug.position.set(0, -0.08, 0.05); mug.rotation.x = 1.65;
  arms[1].hand.add(mug);

  const paddle = new THREE.Group();
  const blade = new THREE.Mesh(new THREE.CylinderGeometry(0.085, 0.085, 0.015, 18), mat('#C8323A'));
  blade.rotation.z = Math.PI / 2; blade.position.y = -0.16; paddle.add(blade);
  part(paddle, 0.03, 0.1, 0.025, '#8A5F38', 0, -0.06, 0, 0.008);
  arms[1].hand.add(paddle);

  const anchor = new THREE.Object3D(); // label anchor, follows the head but survives a hidden body
  g.add(anchor);
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(0.9, 0.9), blobMat);
  shadow.rotation.x = -Math.PI / 2; shadow.position.y = 0.014; shadow.renderOrder = 1;
  g.add(shadow);

  const P = { id: p.id, data: p, g, body, upper, head, legs, arms, eyes, mouth, s, anchor, shadow, props: { phone, mug, paddle }, seed: (p.id.charCodeAt(0) * 7 + p.id.length * 13) % 100 };
  g.traverse((o) => { o.userData.pid = p.id; });
  return P;
}

const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };

function phoneArms(P) {
  for (const a of P.arms) {
    a.sh.rotation.x = -0.38; a.sh.rotation.z = -a.side * 0.3;
    a.el.rotation.x = -1.45;
  }
  P.props.phone.visible = true;
  // thumb scrolling in short bursts
  const ph = P._t + P.seed;
  if ((ph * 1.3) % 2.2 < 0.25) P.arms[1].hand.rotation.z = Math.sin(ph * 40) * 0.12;
}

export function applyPose(P, kind, t, opt = {}) {
  const { legs, arms, upper, head, body, s } = P;
  upper.rotation.set(0, 0, 0); head.rotation.set(0, 0, 0);
  body.position.set(0, 0, 0); body.rotation.set(0, 0, 0);
  for (const l of legs) { l.hip.rotation.set(0, 0, 0); l.knee.rotation.set(0, 0, 0); }
  for (const a of arms) { a.sh.rotation.set(0, 0, a.side * 0.06); a.el.rotation.set(0, 0, 0); a.hand.rotation.set(0, 0, 0); }
  for (const e of P.eyes) e.scale.y = 1;
  P.mouth.scale.y = 1;
  P.props.phone.visible = P.props.mug.visible = P.props.paddle.visible = false;
  P._t = t;
  const ph = t + P.seed;
  const breathe = Math.sin(ph * 1.6) * 0.012;
  const blink = (ph % 4.3) < 0.12 ? 0.15 : 1;
  const sit = (seat = 0.47, hip = -Math.PI / 2, knee = Math.PI / 2) => {
    body.position.y = seat - 0.86 * s;
    legs.forEach((l) => { l.hip.rotation.x = hip; l.knee.rotation.x = knee; });
  };
  const closeEyes = () => P.eyes.forEach((e) => { e.scale.y = 0.15; });

  switch (kind) {
    case 'working':
      sit();
      upper.rotation.x = 0.1 + breathe;
      head.rotation.x = 0.1 + Math.sin(ph * 0.7) * 0.05;
      head.rotation.y = Math.sin(ph * 0.31) * 0.12;
      for (const a of arms) {
        a.sh.rotation.x = -1.0; a.sh.rotation.z = -a.side * 0.14;
        a.el.rotation.x = -0.55 + Math.sin(ph * 17 + a.side * 1.7) * 0.09;
      }
      P.eyes.forEach((e) => { e.scale.y = blink; });
      break;
    case 'sleepDesk':
      sit();
      upper.rotation.x = 0.88 + breathe * 2;
      head.rotation.set(0.2 + Math.sin(ph * 0.5) * 0.05, 0, 0.5 + Math.sin(ph * 0.31) * 0.06);
      for (const a of arms) { a.sh.rotation.x = -1.3; a.sh.rotation.z = -a.side * 0.55; a.el.rotation.x = -1.15; a.el.rotation.z = -a.side * 0.2; }
      closeEyes();
      break;
    case 'sleepBack':
      sit();
      upper.rotation.x = -0.4 + breathe * 2;
      head.rotation.set(-0.55, 0, 0.18);
      for (const a of arms) { a.sh.rotation.x = 0.12; a.sh.rotation.z = a.side * 0.2; a.el.rotation.x = -0.25; }
      closeEyes();
      P.mouth.scale.y = 3;
      break;
    case 'beanbag':
      sit(0.32, -1.2, 0.55);
      upper.rotation.x = -0.8 + breathe * 2;
      head.rotation.set(0.15, 0, 0.4);
      for (const a of arms) { a.sh.rotation.x = -0.45; a.sh.rotation.z = -a.side * 0.4; a.el.rotation.x = -1.35; }
      closeEyes();
      break;
    case 'phoneDesk':
      sit();
      upper.rotation.x = 0.05 + breathe;
      head.rotation.x = 0.62 + Math.sin(ph * 0.23) * 0.12; head.rotation.y = Math.sin(ph * 0.17) * 0.18;
      phoneArms(P);
      P.arms[1].hand.rotation.x = Math.sin(ph * 3) * 0.05;
      P.eyes.forEach((e) => { e.scale.y = blink; });
      break;
    case 'sofaPhone':
      sit(0.46);
      upper.rotation.x = -0.22 + breathe;
      head.rotation.x = 0.62 + Math.sin(ph * 0.23) * 0.12; head.rotation.y = Math.sin(ph * 0.17) * 0.18;
      head.rotation.z = Math.sin(ph * 0.4) * 0.08;
      phoneArms(P);
      legs[0].hip.rotation.y = 0.25;
      P.eyes.forEach((e) => { e.scale.y = blink; });
      break;
    case 'standPhone':
      head.rotation.x = 0.62 + Math.sin(ph * 0.23) * 0.12; head.rotation.y = Math.sin(ph * 0.17) * 0.18;
      body.rotation.z = Math.sin(ph * 0.5) * 0.02;
      upper.rotation.x = 0.05 + breathe;
      phoneArms(P);
      P.eyes.forEach((e) => { e.scale.y = blink; });
      break;
    case 'coffee': {
      const sip = smooth(0.8, 0.97, (Math.sin(ph * 0.6) + 1) / 2);
      upper.rotation.x = breathe;
      head.rotation.y = Math.sin(ph * 0.35) * 0.35;
      head.rotation.x = 0.05 - 0.3 * sip;
      const r = arms[1];
      r.sh.rotation.x = -0.35 - 0.55 * sip; r.sh.rotation.z = -0.12;
      r.el.rotation.x = -1.3 - 0.5 * sip;
      const l = arms[0];
      l.sh.rotation.x = 0.08; l.sh.rotation.z = -0.12; l.el.rotation.x = -0.25;
      P.props.mug.visible = true;
      P.eyes.forEach((e) => { e.scale.y = blink; });
      break;
    }
    case 'pingpong': {
      const sw = opt.swing ?? 0;
      legs.forEach((l) => { l.hip.rotation.x = -0.35; l.knee.rotation.x = 0.6; });
      body.position.y = -0.05 * s + Math.abs(Math.sin(ph * 5)) * 0.02;
      upper.rotation.x = 0.25;
      upper.rotation.y = -0.4 * sw;
      const r = arms[1];
      r.sh.rotation.x = -0.75 - 0.6 * sw; r.sh.rotation.z = -0.25 + 0.5 * sw;
      r.el.rotation.x = -0.9 + 0.5 * sw;
      const l = arms[0];
      l.sh.rotation.x = -0.6; l.el.rotation.x = -0.7;
      head.rotation.x = -0.05;
      P.props.paddle.visible = true;
      break;
    }
    case 'absent':
      sit();
      break;
    default:
      upper.rotation.x = breathe;
  }
}
