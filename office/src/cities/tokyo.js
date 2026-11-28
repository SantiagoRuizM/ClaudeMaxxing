const Q = Math.PI / 4;

// Tokyo: dense mid-rise to the horizon, the towers of Shinjuku, Tokyo Tower, the Skytree far away and cherry trees.
export default {
  id: 'tokyo', name: 'Tokio', region: 'asia', timeZone: 'Asia/Tokyo',
  water: [[500, 300, 1700, 1700]], waterColor: '#3F6474',
  heights: { near: [8, 24], mid: [16, 40], far: [20, 70] },
  parks: 0.07,
  facades: {
    mix: { concrete: 0.35, white: 0.35, glass: 0.25, brick2: 0.05 }, tall: { glass: 0.5, white: 0.25, concrete: 0.25 },
    colors: { white: { wall: '#E7E5E0' }, concrete: { wall: '#C9C7C2' } },
  },
  clusters: [{ x: -260, z: -620, rx: 130, rz: 110, n: 24, min: 120, max: 230 }],
  trees: { accents: [['#F2B8C6', 0.18], ['#F7CAD4', 0.1]] },
  fill: { n: 2400, min: 12, max: 60, tall: 0.12 },
  landmarks: [{ name: 'Tokyo Tower', at: [150, -520], clear: 35, parts: [
    { s: 'cyl', r: 30, r2: 16, h: 80, seg: 4, ry: Q, m: 'paint', c: '#E8542F' }, { s: 'cyl', r: 16, r2: 13, h: 10, seg: 4, ry: Q, m: 'light', c: '#F4F1EA' },
    { s: 'cyl', r: 13, r2: 6, h: 90, seg: 4, ry: Q, m: 'paint', c: '#E8542F' }, { s: 'cyl', r: 6, r2: 5, h: 8, seg: 4, ry: Q, m: 'light', c: '#F4F1EA' },
    { s: 'cyl', r: 5, r2: 1.2, h: 60, seg: 4, ry: Q, m: 'paint', c: '#E8542F' }] }],
  skyline: {
    arcs: [[0, 360, 0.85]], min: 20, max: 90, color: '#5E6670',
    landmarks: [{ angle: 40, parts: [ // Skytree
      { s: 'cyl', r: 34, r2: 12, h: 340, seg: 3 }, { s: 'cyl', r: 20, h: 14 }, { s: 'cyl', r: 12, r2: 10, h: 100 },
      { s: 'cyl', r: 15, h: 8 }, { s: 'cyl', r: 8, r2: 2, h: 130 }] }],
  },
  sky: { day: ['#4A86CC', '#D9E3E8', '#9AA0A4'] },
};
