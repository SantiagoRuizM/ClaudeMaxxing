// Dublin: Georgian red brick, the Liffey to the north and the bay to the east, the Spire, the Docklands and the harp bridge.
export default {
  id: 'dublin', name: 'Dublín', region: 'europa', timeZone: 'Europe/Dublin',
  water: [[-1700, -430, 1700, -400], [700, -400, 1700, 1700]], waterColor: '#4C6670',
  heights: { near: [8, 16], mid: [10, 20], far: [12, 24] },
  parks: 0.14,
  facades: {
    mix: { brick: 0.55, brick2: 0.25, white: 0.15, glass: 0.05 }, tall: { glass: 0.6, white: 0.2, brick: 0.2 },
    colors: { brick: { wall: '#8A4B38' } },
  },
  clusters: [{ x: 300, z: -540, rx: 120, rz: 80, n: 12, min: 40, max: 80 }],
  trees: { colors: ['#3F7A3A', '#4C8A40', '#3A6E36'] },
  fill: { min: 8, max: 22, tall: 0.03 },
  landmarks: [
    { name: 'The Spire', at: [-60, -500], clear: 20, parts: [{ s: 'cyl', r: 1.5, r2: 0.08, h: 120, m: 'metal', c: '#C9CED2' }] },
    { name: 'Convention Centre', at: [220, -470], clear: 50, parts: [
      { s: 'box', w: 80, d: 40, h: 22, m: 'stone', c: '#D8D4CC' }, { s: 'cyl', r: 18, h: 34, y: 8, rz: 0.3, m: 'glass' }] },
    { name: 'Samuel Beckett Bridge', at: [380, -415], clear: 70, parts: [
      { s: 'box', w: 120, d: 8, h: 2, y: 4, m: 'stone', c: '#B9B4AA' }, { s: 'cyl', r: 1.2, r2: 0.3, h: 48, y: 0, rz: 0.5, m: 'metal', c: '#E8ECEF' }] },
  ],
  skyline: { arcs: [[0, 360, 0.4]], min: 10, max: 30, color: '#5E6670' },
  sky: { day: ['#6F8FB0', '#CCD6DC', '#8E979C'] }, haze: 1.1, clouds: 36,
};
