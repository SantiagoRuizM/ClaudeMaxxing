// Berlin: even blocks of about 22 m, the Spree, the Fernsehturm and the Brandenburg Gate.
export default {
  id: 'berlin', name: 'Berlín', region: 'europa', timeZone: 'Europe/Berlin',
  water: [[-1700, -430, 1700, -400]], waterColor: '#4E6A70',
  heights: { near: [16, 22], mid: [18, 24], far: [18, 26] },
  parks: 0.14,
  facades: {
    mix: { white: 0.45, concrete: 0.25, brick2: 0.15, brick: 0.15 }, tall: { concrete: 0.4, white: 0.4, glass: 0.2 },
    colors: { white: { wall: '#E9E2D2' } },
  },
  clusters: [{ x: -280, z: -560, rx: 80, rz: 70, n: 8, min: 70, max: 100 }],
  fill: { min: 16, max: 26, tall: 0.03 },
  landmarks: [
    { name: 'Fernsehturm', at: [60, -620], clear: 30, parts: [
      { s: 'cyl', r: 9, r2: 6, h: 200, m: 'paint', c: '#D5D2CB' }, { s: 'sphere', r: 16, m: 'metal', c: '#B9BFC4' },
      { s: 'cyl', r: 3, r2: 2, h: 14, m: 'paint', c: '#D5D2CB' }, { s: 'cyl', r: 1.6, r2: 0.6, h: 90, m: 'paint', c: '#E5E1DA' }] },
    { name: 'Puerta de Brandeburgo', at: [-150, -470], clear: 40, parts: [
      { s: 'box', w: 62, d: 10, h: 3, m: 'stone', c: '#DCD3BE' },
      ...[-27, -16, -5.5, 5.5, 16, 27].map((x) => ({ s: 'cyl', r: 0.9, h: 15, x, y: 3, m: 'stone', c: '#DCD3BE' })),
      { s: 'box', w: 64, d: 11, h: 6, y: 18, m: 'stone', c: '#DCD3BE' }, { s: 'box', w: 10, d: 4, h: 5, m: 'metal', c: '#4E6B5A' }] },
  ],
  skyline: { arcs: [[0, 360, 0.5]], min: 18, max: 40, color: '#5E666E' },
  sky: { day: ['#4A84C2', '#D4DDE2', '#8E979C'] },
};
