// Boston: red-brick Back Bay, the Charles River to the north, the harbor to the east and maples in autumn.
export default {
  id: 'boston', name: 'Boston', region: 'america', timeZone: 'America/New_York',
  water: [[-1700, -470, 1700, -390], [600, -390, 1700, 1700]], waterColor: '#46667A',
  heights: { near: [6, 16], mid: [10, 24], far: [14, 30] },
  facades: { mix: { brick: 0.55, brick2: 0.2, white: 0.1, concrete: 0.1, glass: 0.05 }, tall: { glass: 0.55, concrete: 0.25, brick: 0.2 } },
  clusters: [{ x: 0, z: -660, rx: 260, rz: 150, n: 30, min: 60, max: 180 }],
  trees: { accents: [['#C8502E', 0.2], ['#E08B2C', 0.15], ['#B8352B', 0.08]] },
  landmarks: [
    { name: 'John Hancock Tower', at: [-60, -720], ry: 0.5, clear: 45, parts: [{ s: 'box', w: 32, d: 70, h: 240, m: 'glass' }] },
    { name: 'Prudential', at: [-220, -640], clear: 35, parts: [
      { s: 'box', w: 50, d: 50, h: 210, m: 'concrete' }, { s: 'box', w: 30, d: 30, h: 10, m: 'metal', c: '#8E969E' },
      { s: 'cyl', r: 1, h: 40, m: 'metal', c: '#B9BFC4' }] },
  ],
  skyline: { arcs: [[200, 420, 0.5]], min: 15, max: 70, color: '#5E6670' },
  sky: { day: ['#3D7FC4', '#D7E4EA', '#8E979C'] },
};
