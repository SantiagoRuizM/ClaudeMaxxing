import * as THREE from 'three';
import { FACADE_MATS, stackParts } from './parts.js';

// Builds a landmark from its parts (format in parts.js) in 3D, or paints its silhouette for the far skyline.

// Windows on cylinders: the facade grid is 20.8 m wide per texture and 25.6 m tall (as on the city's boxes).
function scaleCylUV(geo, r, h) {
  const uv = geo.attributes.uv;
  const k = (2 * Math.PI * r) / 20.8;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, uv.getX(i) * k, uv.getY(i) * h / 25.6);
  return geo;
}

export function buildLandmark(L, { facMats, scaleBoxUV, plain }) {
  const g = new THREE.Group();
  g.position.set(L.at[0], 0.3, L.at[1]);
  g.rotation.y = L.ry || 0;
  const ys = stackParts(L.parts);
  L.parts.forEach((p, i) => {
    const [y0, h] = ys[i];
    const facade = FACADE_MATS.includes(p.m);
    let geo;
    if (p.s === 'box') geo = facade ? scaleBoxUV(new THREE.BoxGeometry(p.w, p.h, p.d), p.w, p.h, p.d) : new THREE.BoxGeometry(p.w, p.h, p.d);
    else if (p.s === 'cyl') {
      geo = new THREE.CylinderGeometry(p.r2 ?? p.r, p.r, p.h, p.seg || 24);
      if (facade) scaleCylUV(geo, p.r, p.h);
    } else if (p.s === 'sphere') geo = new THREE.SphereGeometry(p.r, 24, 16).scale(1, p.sy || 1, 1);
    else if (p.s === 'disc') geo = new THREE.CylinderGeometry(p.r, p.r, p.t, 48).rotateX(Math.PI / 2);
    else geo = new THREE.TorusGeometry(p.r, p.t, 8, 64);
    const material = facade ? facMats[p.m] : plain(p.m || 'paint', p.c || '#C9C5BC');
    const mesh = new THREE.Mesh(geo, material);
    mesh.position.set(p.x || 0, y0 + h / 2, p.z || 0);
    if (p.s === 'ring' && p.flat) mesh.rotation.x = Math.PI / 2;
    mesh.rotation.x += p.rx || 0;
    mesh.rotation.z = p.rz || 0;
    mesh.rotation.y = p.ry || 0;
    mesh.scale.set(p.sx || 1, 1, p.sz || 1);
    g.add(mesh);
  });
  return g;
}

// Silhouette on a 2D canvas: cx, base in pixels, mx/my pixels per meter.
export function paintLandmark(g, parts, cx, base, mx, my) {
  const ys = stackParts(parts);
  parts.forEach((p, i) => {
    const [y0, h] = ys[i];
    g.save();
    g.translate(cx + (p.x || 0) * mx, base - y0 * my);
    if (p.rz) g.rotate(-p.rz * (mx / my));
    g.scale(p.sx || 1, 1);
    g.beginPath();
    if (p.s === 'box') g.rect(-p.w / 2 * mx, -h * my, p.w * mx, h * my);
    else if (p.s === 'cyl') {
      const r2 = p.r2 ?? p.r;
      g.moveTo(-p.r * mx, 0); g.lineTo(p.r * mx, 0); g.lineTo(r2 * mx, -h * my); g.lineTo(-r2 * mx, -h * my); g.closePath();
    } else if (p.s === 'sphere' || p.s === 'disc') g.ellipse(0, -h / 2 * my, p.r * mx, h / 2 * my, 0, 0, Math.PI * 2);
    else if (p.flat) g.rect(-(p.r + p.t) * mx, -h * my, 2 * (p.r + p.t) * mx, h * my);
    else { g.ellipse(0, -h / 2 * my, (p.r + p.t) * mx, h / 2 * my, 0, 0, Math.PI * 2); g.ellipse(0, -h / 2 * my, (p.r - p.t) * mx, (h / 2 - 2 * p.t) * my, 0, 0, Math.PI * 2, true); }
    g.fill('evenodd');
    g.restore();
  });
}
