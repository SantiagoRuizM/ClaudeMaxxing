// Miami: the Atlantic to the east, a long beach, palms, pastel low-rise and the white and glass towers of Brickell.
export default {
  id: 'miami', name: 'Miami', region: 'america', timeZone: 'America/New_York',
  water: [[380, -1700, 1700, 1700]], waterColor: '#2E8BA6', shore: '#E9D9B5', shoreW: 40,
  ground: { urban: '#6A6E70', green: ['#4F7F3C', '#5E9443', '#6FA04B'] },
  heights: { near: [5, 14], mid: [12, 40], far: [30, 120] },
  balconies: true,
  facades: {
    mix: { white: 0.55, glass: 0.3, concrete: 0.15 }, tall: { white: 0.45, glass: 0.55 },
    colors: { white: { wall: '#F1EEE6' }, concrete: { wall: '#E7D3C7' } },
  },
  clusters: [{ x: 250, z: -500, rx: 110, rz: 250, n: 40, min: 90, max: 220 }],
  trees: { palms: 0.7, palmColors: ['#4F8A3C', '#5C9A45', '#3F7A35'] },
  fill: { colors: ['#F2EEE6', '#F4D9CF', '#D8EDE6', '#FFFFFF', '#F6E7C8'] },
  landmarks: [
    { name: 'Freedom Tower', at: [-120, -420], clear: 30, parts: [
      { s: 'box', w: 30, d: 30, h: 50, m: 'stone', c: '#EFE6D2' }, { s: 'box', w: 16, d: 16, h: 40, m: 'stone', c: '#EFE6D2' },
      { s: 'cyl', r: 7, h: 10, seg: 8, m: 'stone', c: '#EFE6D2' }, { s: 'sphere', r: 5, sy: 0.8, m: 'paint', c: '#3E8E7E' }] },
    { name: 'Panorama Tower', at: [300, -650], clear: 30, parts: [{ s: 'box', w: 40, d: 24, h: 260, m: 'glass' }] },
  ],
  skyline: { arcs: [[180, 360, 0.55], [0, 40, 0.6]], min: 15, max: 110, color: '#6A7680' },
  sky: { day: ['#2F7FD6', '#BFE3F2', '#9FB8B0'], dusk: ['#3B3E8F', '#FF8A5C', '#6A4A5A'] },
};
