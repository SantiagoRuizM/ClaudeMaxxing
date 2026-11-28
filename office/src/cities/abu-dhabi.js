// Abu Dhabi: an island in the Gulf, the Corniche towers along the water, Aldar's coin, the Etihad Towers and the mosque.
export default {
  id: 'abu-dhabi', name: 'Abu Dabi', region: 'medio-oriente', timeZone: 'Asia/Dubai',
  water: [[-1700, -1700, 1700, -520], [520, -520, 1700, 1700]], waterColor: '#2F8FA0', shore: '#E8D9B5', shoreW: 20,
  ground: { urban: '#8C8577', green: ['#B9A57E', '#C8B48C', '#A8966F'] },
  heights: { near: [6, 18], mid: [14, 40], far: [30, 90] },
  parks: 0.08,
  facades: {
    mix: { white: 0.5, glass: 0.35, concrete: 0.15 }, tall: { glass: 0.6, white: 0.4 },
    colors: { white: { wall: '#EFE8DA' }, glass: { wall: '#3A6A7A', glass: '#2E5866' } },
  },
  clusters: [{ x: 0, z: -470, rx: 380, rz: 40, n: 30, min: 80, max: 230 }],
  trees: { palms: 0.85 },
  fill: { colors: ['#EFE8DA', '#E6DCC8', '#F4F0E6', '#D9CFBC'] },
  landmarks: [
    { name: 'Aldar HQ', at: [-300, -420], clear: 60, parts: [{ s: 'disc', r: 55, t: 22, m: 'glass' }] },
    { name: 'Etihad Towers', at: [120, -440], clear: 70, parts: [
      { s: 'cyl', r: 16, r2: 12, h: 300, x: -40, y: 0, m: 'glass' }, { s: 'cyl', r: 15, r2: 11, h: 270, x: -5, z: 25, y: 0, m: 'glass' },
      { s: 'cyl', r: 14, r2: 10, h: 250, x: 30, y: 0, m: 'glass' }, { s: 'cyl', r: 13, r2: 9, h: 230, x: 60, z: 20, y: 0, m: 'glass' }] },
    { name: 'Mezquita Sheikh Zayed', at: [-480, -200], clear: 90, parts: [
      { s: 'box', w: 120, d: 80, h: 14, m: 'stone', c: '#F4F1EA' }, { s: 'sphere', r: 18, sy: 0.9, m: 'stone', c: '#FAF8F2' },
      ...[-35, 35].map((x) => ({ s: 'sphere', r: 9, sy: 0.9, x, y: 14, m: 'stone', c: '#FAF8F2' })),
      ...[[-70, -48], [70, -48], [-70, 48], [70, 48]].map(([x, z]) => ({ s: 'cyl', r: 2.5, h: 107, x, z, y: 0, m: 'stone', c: '#F4F1EA' }))] },
  ],
  skyline: { arcs: [[150, 300, 0.5]], min: 20, max: 80, color: '#7A7A76' },
  sky: { day: ['#5B8FC4', '#E7D7B8', '#B49E7E'], dusk: ['#3D4C8A', '#F5A65B', '#7A5A48'] }, haze: 1.4,
};
