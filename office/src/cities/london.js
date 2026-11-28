const Q = Math.PI / 4;

// London: the Thames to the north, brick and Portland stone, the Shard, the Gherkin and the City, the Eye and Big Ben.
export default {
  id: 'london', name: 'Londres', region: 'europa', timeZone: 'Europe/London',
  water: [[-1700, -460, 1700, -400]], waterColor: '#5A6B66',
  heights: { near: [8, 20], mid: [14, 28], far: [18, 40] },
  parks: 0.12,
  facades: {
    mix: { brick: 0.4, white: 0.3, brick2: 0.15, concrete: 0.1, glass: 0.05 }, tall: { glass: 0.6, white: 0.2, concrete: 0.2 },
    colors: { brick: { wall: '#8E5A44' }, white: { wall: '#E6DFD0' } },
  },
  clusters: [{ x: 220, z: -640, rx: 150, rz: 110, n: 18, min: 90, max: 200 }],
  fill: { min: 12, max: 36, tall: 0.05 },
  landmarks: [
    { name: 'The Shard', at: [-80, -530], clear: 50, parts: [
      { s: 'cyl', r: 46, r2: 3, h: 300, seg: 4, ry: Q, m: 'glass' }, { s: 'cyl', r: 1.5, r2: 0, h: 10, m: 'metal', c: '#C9CED2' }] },
    { name: 'The Gherkin', at: [260, -700], clear: 35, parts: [{ s: 'sphere', r: 28, sy: 3.2, m: 'glass' }] },
    { name: 'London Eye', at: [-300, -380], clear: 70, parts: [
      { s: 'box', w: 2, d: 2, h: 70, x: -12, y: 0, rz: 0.35, m: 'metal', c: '#E8ECEF' },
      { s: 'ring', r: 62, t: 1.2, y: 6, m: 'light', c: '#E8ECEF' }] },
    { name: 'Big Ben', at: [-430, -500], clear: 30, parts: [
      { s: 'box', w: 12, d: 12, h: 60, m: 'stone', c: '#C9B48A' }, { s: 'box', w: 13, d: 13, h: 16, m: 'light', c: '#E9D9A8' },
      { s: 'box', w: 11, d: 11, h: 10, m: 'stone', c: '#C9B48A' }, { s: 'cyl', r: 8, r2: 0, h: 18, seg: 4, ry: Q, m: 'paint', c: '#3A4048' }] },
    { name: 'Parlamento', at: [-570, -510], clear: 130, parts: [{ s: 'box', w: 240, d: 30, h: 26, m: 'stone', c: '#C9B48A' }] },
  ],
  skyline: { arcs: [[0, 360, 0.6]], min: 15, max: 60, color: '#5E6670' },
  sky: { day: ['#7C93AA', '#C9D2D8', '#8E979C'] }, haze: 1.2, clouds: 34,
};
