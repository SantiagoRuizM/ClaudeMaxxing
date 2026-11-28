// Shanghai: the Huangpu to the north and Lujiazui across it: the Oriental Pearl, Jin Mao, the Shanghai Tower and SWFC.
export default {
  id: 'shanghai', name: 'Shanghái', region: 'asia', timeZone: 'Asia/Shanghai',
  water: [[-1700, -470, 1700, -400]], waterColor: '#5E6E66',
  heights: { near: [10, 30], mid: [20, 50], far: [30, 90] },
  facades: { mix: { glass: 0.4, white: 0.25, concrete: 0.3, brick2: 0.05 }, tall: { glass: 0.7, white: 0.15, concrete: 0.15 } },
  clusters: [{ x: 40, z: -690, rx: 280, rz: 160, n: 40, min: 120, max: 260 }],
  fill: { n: 2000, min: 18, max: 80, tall: 0.15 },
  landmarks: [
    { name: 'Perla Oriental', at: [-180, -560], clear: 40, parts: [
      { s: 'cyl', r: 6, h: 80, m: 'paint', c: '#C9C5BC' }, { s: 'sphere', r: 26, m: 'light', c: '#D84A8A' },
      { s: 'cyl', r: 5, h: 120, m: 'paint', c: '#C9C5BC' }, { s: 'sphere', r: 15, m: 'light', c: '#D84A8A' },
      { s: 'cyl', r: 3, h: 30, m: 'paint', c: '#C9C5BC' }, { s: 'sphere', r: 6, m: 'light', c: '#D84A8A' },
      { s: 'cyl', r: 1, r2: 0, h: 60, m: 'metal', c: '#C9CED2' }] },
    { name: 'Shanghai Tower', at: [60, -770], clear: 50, parts: [
      { s: 'cyl', r: 38, r2: 26, h: 560, seg: 9, m: 'glass' }, { s: 'cyl', r: 26, r2: 20, h: 30, seg: 9, m: 'metal', c: '#9AA3AB' }] },
    { name: 'Jin Mao', at: [180, -700], clear: 35, parts: [
      { s: 'cyl', r: 26, r2: 22, h: 120, seg: 8, m: 'glass' }, { s: 'cyl', r: 22, r2: 17, h: 90, seg: 8, m: 'glass' },
      { s: 'cyl', r: 17, r2: 12, h: 70, seg: 8, m: 'glass' }, { s: 'cyl', r: 12, r2: 7, h: 50, seg: 8, m: 'glass' },
      { s: 'cyl', r: 7, r2: 0, h: 40, seg: 8, m: 'metal', c: '#C9CED2' }] },
    { name: 'Shanghai World Financial Center', at: [300, -760], clear: 40, parts: [{ s: 'box', w: 50, d: 50, h: 420, m: 'glass' }] },
  ],
  skyline: { arcs: [[0, 360, 0.85]], min: 30, max: 120, color: '#5F6870' },
  sky: { day: ['#6F93B5', '#D3D8D2', '#9AA09A'] }, haze: 1.5,
};
