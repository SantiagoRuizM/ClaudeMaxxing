// Builds every city and the office in every style with the vendored Three.js, in node: no WebGL, no browser. The
// import map of index.html is replayed with a resolve hook and canvases are stubs, so this catches runtime errors in the
// scene code (bad preset fields, geometry merges, materials), not how it looks.
import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';

const vendor = new URL('../vendor/three/', import.meta.url);
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'three') return { url: new URL('three.module.min.js', vendor).href, shortCircuit: true };
    if (specifier.startsWith('three/addons/')) return { url: new URL(`addons/${specifier.slice(13)}`, vendor).href, shortCircuit: true };
    return next(specifier, context);
  },
});

const ctx2d = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === 'measureText' ? () => ({ width: 100 }) : k.startsWith('create') ? () => ({ addColorStop() {} }) : () => {}),
  set: (t, k, v) => { t[k] = v; return true; },
});
globalThis.document = { createElement: () => ({ width: 0, height: 0, getContext: ctx2d, style: {} }) };

const THREE = await import('three');
const { buildCity } = await import('../src/city.js');
const { buildOffice } = await import('../src/office.js');
const { CITIES } = await import('../src/cities/index.js');
const { STYLES } = await import('../src/styles/index.js');
const { placeTeam } = await import('../src/team.js');

const meshes = (root) => { let n = 0; root.traverse((o) => { if (o.isMesh || o.isPoints) n++; }); return n; };

for (const preset of CITIES) {
  test(`${preset.id}: the city builds, and stays light`, () => {
    const scene = new THREE.Scene();
    const city = buildCity(scene, preset);
    city.setSky(new THREE.Color(), new THREE.Color(), new THREE.Color(), 0.8, new THREE.Vector3(0, 1, 0), new THREE.Vector3(0, 1, 0));
    city.update(0.016, 1);
    const n = meshes(scene);
    assert.ok(n > 10, `${n} draw calls`);
    assert.ok(n < 160, `${n} draw calls`); // shortcut: counts meshes, not GPU time; profile in a browser if a city feels slow
  });
}

test('the office builds in every style with the demo team', () => {
  const layout = placeTeam(JSON.parse(readFileSync(new URL('../demo/office.json', import.meta.url), 'utf8')));
  const tex = new THREE.Texture();
  for (const style of STYLES) {
    const office = buildOffice({ wordmark: tex, isotipo: tex, white: tex }, layout, { company: 'Demo', cityName: 'Demo', style });
    assert.equal(Object.keys(office.stations).length, 18, style.id);
    office.setNight(1);
    office.update(0.016, 1);
  }
});
