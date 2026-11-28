import { hills } from './terrain.js';

// São Paulo: a sea of concrete towers to the horizon, Banespa, the Edifício Itália and the cable-stayed bridge.
export default {
  id: 'sao-paulo', name: 'São Paulo', region: 'america', timeZone: 'America/Sao_Paulo',
  terrain: hills({ from: 1000, to: 1650, h: 90 }),
  heights: { near: [12, 40], mid: [30, 70], far: [40, 110] },
  corridor: [-200, 100],
  parks: 0.05,
  balconies: true,
  facades: {
    mix: { concrete: 0.4, white: 0.35, brick2: 0.1, glass: 0.15 }, tall: { concrete: 0.4, white: 0.35, glass: 0.25 },
    colors: { concrete: { wall: '#CFC9BE' }, white: { wall: '#E6E0D4' } },
  },
  trees: { colors: ['#2F5E34', '#3A6B3B', '#2B5530'] },
  fill: { n: 2400, min: 25, max: 90, tall: 0.15, colors: ['#D8D2C6', '#E6E0D4', '#C9C3B8', '#F0EBE2', '#BDB7AC'] },
  landmarks: [
    { name: 'Banespa', at: [-80, -600], clear: 30, parts: [
      { s: 'box', w: 40, d: 40, h: 90, m: 'stone', c: '#D9CFB8' }, { s: 'box', w: 30, d: 30, h: 30, m: 'stone', c: '#D9CFB8' },
      { s: 'box', w: 22, d: 22, h: 20, m: 'stone', c: '#D9CFB8' }, { s: 'box', w: 14, d: 14, h: 12, m: 'stone', c: '#D9CFB8' },
      { s: 'cyl', r: 2, r2: 0, h: 30, m: 'metal', c: '#B9BFC4' }] },
    { name: 'Edifício Itália', at: [120, -520], ry: 0.3, clear: 35, parts: [{ s: 'box', w: 34, d: 50, h: 165, m: 'concrete' }] },
    { name: 'Ponte Estaiada', at: [300, -470], clear: 160, parts: [
      { s: 'box', w: 4, d: 4, h: 140, y: 0, rz: 0.25, m: 'paint', c: '#E9E6E0' }, { s: 'box', w: 4, d: 4, h: 140, y: 0, rz: -0.25, m: 'paint', c: '#E9E6E0' },
      { s: 'box', w: 300, d: 10, h: 2, y: 18, m: 'stone', c: '#B9B4AA' }] },
  ],
  skyline: { arcs: [[0, 360, 0.95]], min: 30, max: 110, color: '#6B6F72' },
  sky: { day: ['#5C8FC0', '#D8DCD8', '#9A9E98'] }, haze: 1.3,
};
