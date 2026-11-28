// Dubai: the Gulf to the west, the line of towers on Sheikh Zayed Road, the Burj Khalifa, the Burj Al Arab and the Frame.
export default {
  id: 'dubai', name: 'Dubái', region: 'medio-oriente', timeZone: 'Asia/Dubai',
  water: [[-1700, -1700, -480, 1700]], waterColor: '#2F8FA0', shore: '#E8D9B5', shoreW: 24,
  ground: { urban: '#8C8577', green: ['#C8B48C', '#B9A57E', '#D2BF98'] },
  heights: { near: [6, 20], mid: [15, 45], far: [30, 110] },
  parks: 0.06,
  facades: {
    mix: { glass: 0.55, white: 0.35, concrete: 0.1 }, tall: { glass: 0.7, white: 0.3 },
    colors: { glass: { wall: '#3E5C6E', glass: '#2B4656' }, white: { wall: '#EDE4D3' } },
  },
  clusters: [{ x: 200, z: -480, rx: 50, rz: 450, n: 45, min: 120, max: 300 }],
  trees: { palms: 0.8 },
  fill: { colors: ['#EDE4D3', '#E2D6BF', '#F4EFE4', '#D5CAB4'] },
  landmarks: [
    { name: 'Burj Khalifa', at: [-40, -820], clear: 60, parts: [
      { s: 'cyl', r: 46, r2: 40, h: 200, seg: 6, m: 'glass' }, { s: 'cyl', r: 36, r2: 31, h: 150, seg: 6, m: 'glass' },
      { s: 'cyl', r: 27, r2: 22, h: 130, seg: 6, m: 'glass' }, { s: 'cyl', r: 19, r2: 14, h: 110, seg: 6, m: 'glass' },
      { s: 'cyl', r: 12, r2: 8, h: 90, seg: 6, m: 'glass' }, { s: 'cyl', r: 7, r2: 4, h: 60, seg: 6, m: 'metal', c: '#C9CED2' },
      { s: 'cyl', r: 3, r2: 0.4, h: 90, m: 'metal', c: '#C9CED2' }] },
    { name: 'Burj Al Arab', at: [-560, -300], clear: 70, parts: [
      { s: 'cyl', r: 60, h: 3, m: 'stone', c: '#E8D9B5' }, { s: 'cyl', r: 45, r2: 6, h: 290, seg: 3, sz: 0.35, m: 'white' },
      { s: 'cyl', r: 1.5, r2: 0, h: 30, m: 'metal', c: '#C9CED2' }] },
    { name: 'Dubai Frame', at: [-260, -480], clear: 80, parts: [
      { s: 'box', w: 25, d: 20, h: 150, x: -50, y: 0, m: 'metal', c: '#D4A93C' }, { s: 'box', w: 25, d: 20, h: 150, x: 50, y: 0, m: 'metal', c: '#D4A93C' },
      { s: 'box', w: 125, d: 20, h: 20, y: 130, m: 'metal', c: '#D4A93C' }] },
  ],
  skyline: { arcs: [[0, 180, 0.7], [300, 360, 0.4]], min: 30, max: 140, color: '#7D7B76' },
  sky: { day: ['#5B8FC4', '#E7D7B8', '#B49E7E'], dusk: ['#3D4C8A', '#F5A65B', '#7A5A48'] }, haze: 1.5,
};
