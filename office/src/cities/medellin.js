// Medellín: the Valle de Aburrá, with its river, the elevated metro, the Metrocable to the comunas and Coltejer.
const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };

// flat city floor, steep mountains east and west, softer hills north and south
export function valley(x, z) {
  const ax = Math.abs(x), az = Math.abs(z);
  let h = smooth(225, 600, ax) * 330 + smooth(750, 1400, az) * 150;
  const n = Math.sin(x * 0.011 + 1.3) * Math.cos(z * 0.009) * 32 + Math.sin(x * 0.031 + z * 0.017) * 14 + Math.cos(z * 0.023 - x * 0.005) * 10;
  h += n * smooth(200, 400, Math.max(ax, az * 0.6));
  return Math.max(0, h);
}

// comunas grow in barrios separated by green strips
export const barrio = (x, z) => Math.sin(x * 0.034 + 0.7) * Math.cos(z * 0.029) + 0.6 * Math.sin((x + z) * 0.017);

export default {
  id: 'medellin', name: 'Medellín', region: 'america', timeZone: 'America/Bogota',
  terrain: valley,
  ground: { urban: '#4A4F56', green: ['#2F5130', '#557042', '#46633A'], hill: '#5A4A3E', hillMix: (x, z, h) => (h > 6 && h < 130 ? smooth(0, 0.5, barrio(x, z)) * 0.85 : 0) },
  water: [[-208, -1700, -184, 1700]], shore: '#5D8A47',
  heights: { near: [5, 16], mid: [10, 22], far: [16, 50] },
  corridor: [-180, 40],
  balconies: true,
  clusters: [{ x: -70, z: -400, rx: 120, rz: 100, n: 26, min: 30, max: 80 }],
  fill: { n: 1700, w: 560, d: 2600 },
  fillSkip: (x) => x > -225 && x < -160, // river and metro
  trees: { accents: [['#EDBB2C', 0.15], ['#DE7FA6', 0.08], ['#A385CF', 0.05]] }, // guayacanes amarillos y rosados
  landmarks: [{
    name: 'Coltejer', at: [-70, -400], clear: 30, parts: [
      { s: 'box', w: 18, d: 26, h: 150, m: 'concrete' },
      { s: 'cyl', r: 15, r2: 0, h: 48, seg: 4, ry: Math.PI / 4, sx: 0.6, sz: 1.45, m: 'paint', c: '#CFCAC0' },
      { s: 'box', w: 1.4, d: 26.6, h: 30, y: 145, m: 'paint', c: '#26323D' }, // its dark vertical notch
    ],
  }],
  skyline: null, // the mountains close the valley
  intro: { p: [65, 110, 175], t: [-120, 30, -160] },
  far: { p: [120, 85, 210], t: [-70, 40, -260] },
  extras: 'medellin',
};
