const Q = Math.PI / 4;

// New York: Manhattan between the Hudson and the East River, Midtown to the north, One World Trade Center to the south.
export default {
  id: 'new-york', name: 'Nueva York', region: 'america', timeZone: 'America/New_York',
  water: [[-1700, -1700, -420, 1700], [430, -1700, 1700, 1700]], waterColor: '#3F5F6B',
  heights: { near: [8, 24], mid: [20, 60], far: [40, 140] },
  corridor: [-150, 120],
  parks: 0.06,
  facades: { mix: { brick: 0.4, concrete: 0.25, glass: 0.2, white: 0.15 }, tall: { glass: 0.45, concrete: 0.25, brick: 0.2, white: 0.1 } },
  clusters: [{ x: 0, z: -620, rx: 330, rz: 230, n: 60, min: 80, max: 260, w: [18, 32] }],
  fill: { n: 900, min: 20, max: 90, tall: 0.2 },
  landmarks: [
    { name: 'Empire State', at: [-40, -640], clear: 40, parts: [
      { s: 'box', w: 52, d: 40, h: 120, m: 'concrete' }, { s: 'box', w: 40, d: 30, h: 80, m: 'concrete' },
      { s: 'box', w: 26, d: 24, h: 50, m: 'concrete' }, { s: 'box', w: 14, d: 14, h: 20, m: 'stone', c: '#C9C3B5' },
      { s: 'cyl', r: 5, h: 18, m: 'metal', c: '#B9BFC4' }, { s: 'cyl', r: 1.4, r2: 0, h: 60, m: 'metal', c: '#B9BFC4' }] },
    { name: 'Chrysler', at: [140, -560], clear: 35, parts: [
      { s: 'box', w: 34, d: 34, h: 150, m: 'white' }, { s: 'box', w: 26, d: 26, h: 40, m: 'white' },
      { s: 'cyl', r: 13, r2: 9, h: 14, seg: 8, m: 'light', c: '#D8DCE0' }, { s: 'cyl', r: 9, r2: 6, h: 14, seg: 8, m: 'light', c: '#D8DCE0' },
      { s: 'cyl', r: 6, r2: 3, h: 14, seg: 8, m: 'light', c: '#D8DCE0' }, { s: 'cyl', r: 2.5, r2: 0, h: 50, m: 'metal', c: '#D8DCE0' }] },
    { name: 'One World Trade Center', at: [260, 520], clear: 45, parts: [
      { s: 'box', w: 60, d: 60, h: 50, m: 'glass' }, { s: 'cyl', r: 42, r2: 24, h: 330, seg: 4, ry: Q, m: 'glass' },
      { s: 'cyl', r: 1.5, r2: 0.6, h: 120, m: 'metal', c: '#C9CED2' }] },
  ],
  skyline: { arcs: [[0, 360, 0.8]], min: 30, max: 140, color: '#5A6470' },
};
