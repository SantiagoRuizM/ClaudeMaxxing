import { hills } from './terrain.js';

const Q = Math.PI / 4;

// Shenzhen: the glass towers of Futian under green hills to the north, Ping An and the "bamboo shoot" of China Resources.
export default {
  id: 'shenzhen', name: 'Shenzhen', region: 'asia', timeZone: 'Asia/Shanghai',
  terrain: hills({ from: 900, to: 1500, h: 220, dir: 'n' }),
  heights: { near: [10, 30], mid: [20, 50], far: [30, 100] },
  facades: { mix: { glass: 0.45, white: 0.3, concrete: 0.25 }, tall: { glass: 0.75, white: 0.25 } },
  clusters: [{ x: -40, z: -620, rx: 280, rz: 150, n: 45, min: 100, max: 300 }],
  trees: { colors: ['#2F6B3A', '#3E7E3F', '#2B5E35'], palms: 0.2 },
  fill: { n: 1800, min: 20, max: 90, tall: 0.18 },
  landmarks: [
    { name: 'Ping An', at: [0, -760], clear: 55, parts: [
      { s: 'cyl', r: 48, r2: 30, h: 520, seg: 4, ry: Q, m: 'glass' }, { s: 'cyl', r: 30, r2: 10, h: 40, seg: 4, ry: Q, m: 'metal', c: '#B9BFC4' },
      { s: 'cyl', r: 1.2, r2: 0, h: 40, m: 'metal', c: '#C9CED2' }] },
    { name: 'China Resources', at: [240, -700], clear: 40, parts: [
      { s: 'cyl', r: 32, r2: 24, h: 300, seg: 24, m: 'glass' }, { s: 'sphere', r: 24, sy: 1.6, m: 'glass' }] },
  ],
  skyline: { arcs: [[0, 360, 0.8]], min: 30, max: 140, color: '#5E6870' },
  sky: { day: ['#6F96BA', '#D6DDD8', '#9AA39C'] }, haze: 1.3,
};
