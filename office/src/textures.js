import * as THREE from 'three';

export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function hash(str) {
  let h = 2166136261;
  for (const c of str) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

export function shade(hex, f) {
  return '#' + new THREE.Color(hex).multiplyScalar(f).getHexString();
}

export function canvasTex(w, h, draw, { srgb = true, repeat = true } = {}) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  draw(c.getContext('2d'), w, h);
  const t = new THREE.CanvasTexture(c);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.anisotropy = 8;
  return t;
}

const FACADES = {
  brick: { wall: '#9C5A43', glass: '#2C3B47', frame: '#E9E2D4' },
  brick2: { wall: '#AA6A4C', glass: '#33424D', frame: '#EFE6D6' },
  concrete: { wall: '#D8D3C8', glass: '#33475A', frame: '#B9B3A6' },
  glass: { wall: '#3E5869', glass: '#2A4152', frame: '#8FA6B5' },
  white: { wall: '#ECE6DA', glass: '#2E3E4B', frame: '#C9C1B1' },
};
export const FACADE_STYLES = Object.keys(FACADES);

// 8x8 window grid per texture; UVs on buildings are scaled so one cell = 4 m bay x 3.6 m floor.
export function facade(style, seed, colors) {
  const S = { ...FACADES[style], ...colors };
  const N = 8, C = 64;
  const rects = [];
  const map = canvasTex(512, 512, (g) => {
    const r = rng(seed);
    g.fillStyle = S.wall; g.fillRect(0, 0, 512, 512);
    if (style.startsWith('brick')) {
      for (let y = 0; y < 512; y += 4) for (let x = ((y / 4) % 2) * 4; x < 512; x += 8) {
        g.fillStyle = `rgba(0,0,0,${r() * 0.14})`; g.fillRect(x, y, 7, 3);
      }
    }
    for (let i = 0; i < N; i++) for (let j = 0; j < N; j++) {
      const x = i * C, y = j * C;
      if (style === 'glass') {
        g.fillStyle = S.glass; g.fillRect(x + 3, y + 6, C - 6, C - 12); rects.push([x + 3, y + 6, C - 6, C - 12]);
        g.fillStyle = S.frame; g.fillRect(x + C / 2 - 1, y + 6, 2, C - 12);
        g.fillStyle = 'rgba(255,255,255,.08)'; g.fillRect(x + 3, y + 6, C / 2 - 4, C - 12);
      } else if (style === 'concrete') {
        g.fillStyle = S.glass; g.fillRect(x + 4, y + 18, C - 8, 30); rects.push([x + 4, y + 18, C - 8, 30]);
        g.fillStyle = S.frame; g.fillRect(x + C / 2 - 1, y + 18, 2, 30);
      } else {
        g.fillStyle = S.frame; g.fillRect(x + 12, y + 12, C - 24, C - 22);
        g.fillStyle = S.glass; g.fillRect(x + 15, y + 15, C - 30, C - 28); rects.push([x + 15, y + 15, C - 30, C - 28]);
        if (j % 2 === 0 && style !== 'brick') { g.fillStyle = 'rgba(0,0,0,.28)'; g.fillRect(x + 6, y + C - 12, C - 12, 4); }
      }
    }
  });
  const lit = canvasTex(512, 512, (g) => {
    const r = rng(seed * 7 + 3);
    g.fillStyle = '#000'; g.fillRect(0, 0, 512, 512);
    for (const [x, y, w, h] of rects) {
      if (r() < 0.28) { g.globalAlpha = 0.45 + r() * 0.55; g.fillStyle = r() < 0.78 ? '#FFCB7D' : '#BFD8FF'; g.fillRect(x, y, w, h); g.globalAlpha = 1; }
    }
  });
  const rough = canvasTex(512, 512, (g) => {
    const wall = style === 'glass' ? 90 : style === 'concrete' ? 210 : 235;
    g.fillStyle = `rgb(${wall},${wall},${wall})`; g.fillRect(0, 0, 512, 512);
    g.fillStyle = 'rgb(30,30,30)';
    for (const [x, y, w, h] of rects) g.fillRect(x, y, w, h);
  }, { srgb: false });
  return { map, lit, rough };
}

export function planks(colors = ['#B58C61', '#C9A77D']) {
  return canvasTex(512, 512, (g) => {
    const r = rng(7);
    const tones = colors.map((x) => new THREE.Color(x));
    for (let y = 0; y < 512; y += 16) {
      let x = -r() * 200;
      while (x < 512) {
        const w = 140 + r() * 200;
        g.fillStyle = '#' + tones[0].clone().lerp(tones[1], r()).getHexString();
        g.fillRect(x, y, w, 16);
        g.fillStyle = 'rgba(70,40,15,.22)'; g.fillRect(x, y, 1.5, 16);
        x += w;
      }
      g.fillStyle = 'rgba(90,55,25,.18)'; g.fillRect(0, y, 512, 1.5);
    }
    for (let k = 0; k < 1400; k++) {
      g.fillStyle = `rgba(120,80,40,${r() * 0.07})`;
      g.fillRect(r() * 512, r() * 512, 20 + r() * 70, 1);
    }
  });
}

// Polished concrete: soft clouds of tone, a few hairline cracks and saw-cut joints.
export function concreteFloor(color = '#8E8B86') {
  return canvasTex(512, 512, (g) => {
    const r = rng(11);
    g.fillStyle = color; g.fillRect(0, 0, 512, 512);
    for (let k = 0; k < 260; k++) {
      const x = r() * 512, y = r() * 512, rad = 20 + r() * 90;
      const grd = g.createRadialGradient(x, y, 0, x, y, rad);
      grd.addColorStop(0, `rgba(${r() < 0.5 ? '0,0,0' : '255,255,255'},${r() * 0.07})`); grd.addColorStop(1, 'rgba(0,0,0,0)');
      g.fillStyle = grd; g.fillRect(x - rad, y - rad, rad * 2, rad * 2);
    }
    g.strokeStyle = 'rgba(0,0,0,.12)'; g.lineWidth = 1;
    for (let k = 0; k < 5; k++) { g.beginPath(); let x = r() * 512, y = r() * 512; g.moveTo(x, y); for (let s = 0; s < 8; s++) { x += (r() - 0.5) * 60; y += (r() - 0.5) * 60; g.lineTo(x, y); } g.stroke(); }
    g.fillStyle = 'rgba(0,0,0,.18)'; g.fillRect(0, 0, 512, 2); g.fillRect(0, 0, 2, 512);
  });
}

// Exposed brick, running bond: one texture tile is 1 m x 1 m (office.js scales the wall UVs to meters).
export function brickWall(color = '#A65E46') {
  return canvasTex(256, 256, (g) => {
    const r = rng(5);
    const base = new THREE.Color(color);
    g.fillStyle = '#B9AFA2'; g.fillRect(0, 0, 256, 256); // mortar
    const bh = 256 / 15, bw = 256 / 4.5;
    for (let row = 0; row < 15; row++) for (let x = (row % 2) * -bw / 2; x < 256; x += bw) {
      g.fillStyle = `#${base.clone().multiplyScalar(0.82 + r() * 0.3).getHexString()}`;
      g.fillRect(x + 1.5, row * bh + 1.5, bw - 3, bh - 3);
    }
  });
}

export function tiles(base = '#E9E6E1', line = '#CFCAC2', n = 8) {
  return canvasTex(256, 256, (g) => {
    g.fillStyle = base; g.fillRect(0, 0, 256, 256);
    g.fillStyle = line;
    for (let i = 0; i <= n; i++) { g.fillRect(i * 256 / n, 0, 2, 256); g.fillRect(0, i * 256 / n, 256, 2); }
  });
}

export function rugTex(color, seed = 1) {
  return canvasTex(256, 256, (g) => {
    const r = rng(seed);
    g.fillStyle = color; g.fillRect(0, 0, 256, 256);
    for (let k = 0; k < 4000; k++) { g.fillStyle = `rgba(${r() < 0.5 ? '0,0,0' : '255,255,255'},${r() * 0.06})`; g.fillRect(r() * 256, r() * 256, 2, 2); }
    g.strokeStyle = 'rgba(255,255,255,.35)'; g.lineWidth = 6; g.strokeRect(10, 10, 236, 236);
  }, { repeat: false });
}

export function codeTex() {
  return canvasTex(256, 512, (g) => {
    const r = rng(42);
    g.fillStyle = '#0D1520'; g.fillRect(0, 0, 256, 512);
    const cols = ['#7FD1B9', '#F2C14E', '#F07178', '#82AAFF', '#C5CBD3', '#C792EA'];
    for (let y = 6; y < 512; y += 11) {
      let x = 8 + Math.floor(r() * 4) * 10;
      const n = 1 + Math.floor(r() * 4);
      for (let k = 0; k < n && x < 240; k++) {
        const w = 12 + r() * 50;
        g.fillStyle = cols[Math.floor(r() * cols.length)];
        g.fillRect(x, y, w, 5);
        x += w + 6;
      }
    }
  });
}

// Screensaver: the company's initial on a gradient.
export function saverTex(company = '') {
  return canvasTex(256, 160, (g) => {
    const grd = g.createLinearGradient(0, 0, 256, 160);
    grd.addColorStop(0, '#0B2A44'); grd.addColorStop(1, '#0E3D3A');
    g.fillStyle = grd; g.fillRect(0, 0, 256, 160);
    g.fillStyle = '#3CC0A9'; g.font = 'bold 84px sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText((company.trim()[0] || '·').toUpperCase(), 128, 84);
  }, { repeat: false });
}

// Stand-in for a logo image the configuration does not give: the company name in white on transparent.
export function textLogo(text, { w = 1024, h = 176, color = '#FFFFFF' } = {}) {
  const t = canvasTex(w, h, (g) => {
    let size = h * 0.7;
    g.font = `bold ${size}px sans-serif`;
    const fit = g.measureText(text).width;
    if (fit > w * 0.94) { size *= (w * 0.94) / fit; g.font = `bold ${size}px sans-serif`; }
    g.fillStyle = color; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(text, w / 2, h / 2);
  }, { repeat: false });
  return t;
}

export function dashTex(company = '') {
  return canvasTex(512, 288, (g) => {
    const r = rng(9);
    g.fillStyle = '#0F1A26'; g.fillRect(0, 0, 512, 288);
    g.fillStyle = '#E8EEF3'; g.font = 'bold 22px sans-serif'; g.fillText(company ? `${company} · Sprint 14` : 'Sprint 14', 22, 38);
    g.fillStyle = '#7F8FA0'; g.font = '14px sans-serif'; g.fillText('Entregas por semana', 22, 62);
    for (let i = 0; i < 12; i++) {
      const h = 40 + r() * 140;
      g.fillStyle = i % 2 ? '#25A18E' : '#0069AB';
      g.fillRect(24 + i * 30, 250 - h, 20, h);
    }
    g.strokeStyle = '#F2C14E'; g.lineWidth = 3; g.beginPath();
    for (let i = 0; i < 8; i++) g.lineTo(400 + i * 13, 200 - i * 14 - r() * 20);
    g.stroke();
    g.fillStyle = '#E8EEF3'; g.font = 'bold 34px sans-serif'; g.fillText('98%', 400, 250);
  }, { repeat: false });
}

export function whiteboardTex() {
  return canvasTex(512, 288, (g) => {
    g.fillStyle = '#F7F8F9'; g.fillRect(0, 0, 512, 288);
    g.lineWidth = 4; g.strokeStyle = '#1F5F8B';
    [[30, 40, 120, 60], [200, 40, 120, 60], [370, 40, 110, 60], [200, 180, 120, 60]].forEach(([x, y, w, h]) => g.strokeRect(x, y, w, h));
    g.strokeStyle = '#B5485A';
    [[150, 70, 200, 70], [320, 70, 370, 70], [260, 100, 260, 180]].forEach(([a, b, c, d]) => { g.beginPath(); g.moveTo(a, b); g.lineTo(c, d); g.stroke(); });
    g.fillStyle = '#1F5F8B'; g.font = 'bold 18px sans-serif';
    g.fillText('Web', 70, 76); g.fillText('API', 240, 76); g.fillText('Mobile', 395, 76); g.fillText('DB', 248, 216);
    g.fillStyle = '#3F7D5A'; g.font = '16px sans-serif'; g.fillText('offline sync → v2', 30, 270);
  }, { repeat: false });
}

// Travel poster of the background city (its name; the drawing is generic).
export function cityPoster(name = '') {
  return canvasTex(256, 360, (g) => {
    const grd = g.createLinearGradient(0, 0, 0, 360);
    grd.addColorStop(0, '#F6B26B'); grd.addColorStop(0.55, '#E97B5C'); grd.addColorStop(1, '#5A3A6E');
    g.fillStyle = grd; g.fillRect(0, 0, 256, 360);
    g.fillStyle = '#FFE2A8'; g.beginPath(); g.arc(128, 120, 34, 0, Math.PI * 2); g.fill();
    g.fillStyle = '#3F6B4F';
    g.beginPath(); g.moveTo(0, 230); g.lineTo(60, 160); g.lineTo(110, 205); g.lineTo(170, 150); g.lineTo(256, 215); g.lineTo(256, 360); g.lineTo(0, 360); g.fill();
    g.fillStyle = '#2B2340';
    [[20, 40], [48, 70], [80, 55], [104, 120], [128, 90], [160, 60], [190, 85], [222, 50]].forEach(([x, h]) => g.fillRect(x, 300 - h, 24, h + 60));
    g.fillStyle = '#FFF4E0'; g.font = 'bold 30px sans-serif'; g.textAlign = 'center';
    g.fillText(name.toUpperCase(), 128, 60, 236);
  }, { repeat: false });
}

export function zTex() {
  return canvasTex(64, 64, (g) => {
    g.font = 'bold 52px sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.lineWidth = 8; g.strokeStyle = '#1B2733'; g.strokeText('Z', 32, 34);
    g.fillStyle = '#FFFFFF'; g.fillText('Z', 32, 34);
  }, { repeat: false });
}

export function blobTex() {
  return canvasTex(128, 128, (g) => {
    const grd = g.createRadialGradient(64, 64, 4, 64, 64, 64);
    grd.addColorStop(0, 'rgba(0,0,0,.55)'); grd.addColorStop(0.55, 'rgba(0,0,0,.25)'); grd.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = grd; g.fillRect(0, 0, 128, 128);
  }, { repeat: false, srgb: false });
}

export function glowTex() {
  return canvasTex(64, 64, (g) => {
    const grd = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    grd.addColorStop(0, 'rgba(255,255,255,1)'); grd.addColorStop(0.25, 'rgba(255,255,255,.6)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grd; g.fillRect(0, 0, 64, 64);
  }, { repeat: false });
}
