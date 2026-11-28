import test from 'node:test';
import assert from 'node:assert/strict';
import { STYLES, DEFAULT_STYLE, styleById } from '../src/styles/index.js';

const shape = (o) => Object.entries(o).map(([k, v]) => (v && typeof v === 'object' && !Array.isArray(v) ? `${k}{${shape(v)}}` : k)).sort().join(',');
const colors = (o) => Object.values(o).flatMap((v) => (typeof v === 'string' && v.startsWith('#') ? [v] : v && typeof v === 'object' ? colors(v) : []));

test('every style has the keys of the default one and valid colors', () => {
  const base = styleById(DEFAULT_STYLE);
  for (const s of STYLES) {
    const { floor, ...rest } = s;
    const { floor: baseFloor, ...baseRest } = base;
    assert.equal(shape(rest), shape(baseRest), s.id);
    assert.ok(['planks', 'concrete'].includes(floor.kind), `${s.id}: floor`);
    assert.ok([null, 'brick'].includes(s.wallTexture), `${s.id}: wallTexture`);
    for (const c of colors(s)) assert.match(c, /^#[0-9A-Fa-f]{6}$/, `${s.id}: ${c}`);
    assert.equal(s.leaves.length, 3);
    assert.equal(s.beanbags.length, 3);
  }
  assert.equal(new Set(STYLES.map((s) => s.id)).size, STYLES.length);
  assert.equal(styleById('nope').id, DEFAULT_STYLE);
});
