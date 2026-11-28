import { hills } from './terrain.js';

const Q = Math.PI / 4;

// Beijing: grey low hutongs near the tower, the CBD with the CCTV loop and China Zun, the Temple of Heaven, hazy hills.
export default {
  id: 'beijing', name: 'Pekín', region: 'asia', timeZone: 'Asia/Shanghai',
  terrain: hills({ from: 1100, to: 1700, h: 260 }),
  heights: { near: [6, 14], mid: [14, 40], far: [30, 90] },
  facades: {
    mix: { concrete: 0.4, white: 0.25, glass: 0.25, brick: 0.1 }, tall: { glass: 0.55, concrete: 0.3, white: 0.15 },
    colors: { brick: { wall: '#7E8085' } }, // grey brick
  },
  clusters: [{ x: 220, z: -620, rx: 200, rz: 150, n: 35, min: 100, max: 220 }],
  fill: { n: 1800, min: 10, max: 70, tall: 0.12 },
  landmarks: [
    { name: 'CCTV', at: [-120, -660], clear: 80, parts: [
      { s: 'box', w: 140, d: 40, h: 40, y: 0, m: 'glass' }, { s: 'box', w: 40, d: 40, h: 230, x: -50, y: 0, m: 'glass' },
      { s: 'box', w: 40, d: 40, h: 230, x: 50, y: 0, m: 'glass' }, { s: 'box', w: 140, d: 40, h: 45, y: 190, m: 'glass' }] },
    { name: 'China Zun', at: [200, -770], clear: 50, parts: [
      { s: 'cyl', r: 44, r2: 34, h: 460, seg: 4, ry: Q, m: 'glass' }, { s: 'cyl', r: 34, r2: 44, h: 50, seg: 4, ry: Q, m: 'glass' }] },
    { name: 'Templo del Cielo', at: [-300, -420], clear: 40, parts: [
      { s: 'cyl', r: 30, h: 2, m: 'stone', c: '#EDEAE2' }, { s: 'cyl', r: 26, h: 2, m: 'stone', c: '#EDEAE2' },
      { s: 'cyl', r: 22, h: 2, m: 'stone', c: '#EDEAE2' }, { s: 'cyl', r: 12, h: 6, m: 'paint', c: '#B43A2E' },
      { s: 'cyl', r: 15, r2: 10, h: 4, m: 'paint', c: '#2F4F8F' }, { s: 'cyl', r: 10, h: 4, m: 'paint', c: '#B43A2E' },
      { s: 'cyl', r: 12, r2: 7, h: 4, m: 'paint', c: '#2F4F8F' }, { s: 'cyl', r: 7, h: 3, m: 'paint', c: '#B43A2E' },
      { s: 'cyl', r: 9, r2: 0.5, h: 7, m: 'paint', c: '#2F4F8F' }, { s: 'sphere', r: 1.4, m: 'metal', c: '#D4A93C' }] },
  ],
  skyline: { arcs: [[0, 360, 0.75]], min: 20, max: 100, color: '#6A6E72' },
  sky: { day: ['#7A97B0', '#D6D7CF', '#A09E96'] }, haze: 1.7,
};
