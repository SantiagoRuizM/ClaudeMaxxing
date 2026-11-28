import { hills } from './terrain.js';

// Silicon Valley: low campuses among oaks and palms on the valley floor, golden hills on both sides, San Francisco far north.
export default {
  id: 'silicon-valley', name: 'Silicon Valley', region: 'america', timeZone: 'America/Los_Angeles',
  terrain: hills({ from: 450, to: 1100, h: 170, dir: 'ew' }),
  ground: { urban: '#5A5E60', green: ['#9C8A4E', '#B39A5A', '#7E7A45'] },
  heights: { near: [4, 10], mid: [6, 14], far: [8, 20] },
  parks: 0.25,
  facades: { mix: { white: 0.45, glass: 0.35, concrete: 0.2 }, tall: { glass: 0.6, white: 0.4 } },
  trees: { colors: ['#55693A', '#61733F', '#4B5E35'], palms: 0.2, palmColors: ['#5C8A3E', '#4F7D38'] },
  fill: { n: 1200, min: 4, max: 14, tall: 0.02, colors: ['#E9E4DA', '#D5DADF', '#C9CDD2', '#F2EEE6'] },
  landmarks: [{ name: 'Campus en anillo', at: [-60, -560], clear: 130, parts: [{ s: 'ring', r: 110, t: 9, flat: true, m: 'glass' }] }],
  skyline: {
    arcs: [[0, 360, 0.15], [330, 390, 0.75]], min: 8, max: 60, color: '#5E6670',
    landmarks: [
      { angle: 352, scale: 0.6, parts: [{ s: 'cyl', r: 16, r2: 12, h: 300 }, { s: 'sphere', r: 12, sy: 0.4 }] },
      { angle: 358, scale: 0.6, parts: [{ s: 'cyl', r: 22, r2: 0, h: 260, seg: 4 }] },
    ],
  },
  sky: { day: ['#3A84D6', '#D5E8EF', '#B59A6B'] },
};
