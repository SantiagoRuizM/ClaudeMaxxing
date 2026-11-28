import test from 'node:test';
import assert from 'node:assert/strict';
import { CITIES, REGIONS, DEFAULT_CITY, cityById } from '../src/cities/index.js';
import { SHAPES, FACADE_MATS, PLAIN_MATS, stackParts } from '../src/parts.js';

const isColor = (c) => /^#[0-9A-Fa-f]{6}$/.test(c);
const checkParts = (where, parts) => {
  assert.ok(Array.isArray(parts) && parts.length, `${where}: no parts`);
  for (const p of parts) {
    assert.ok(SHAPES.includes(p.s), `${where}: unknown shape ${p.s}`);
    if (p.m) assert.ok([...FACADE_MATS, ...PLAIN_MATS].includes(p.m), `${where}: unknown material ${p.m}`);
    if (p.c) assert.ok(isColor(p.c), `${where}: bad color ${p.c}`);
  }
  for (const [y0, h] of stackParts(parts)) assert.ok(Number.isFinite(y0) && h > 0, `${where}: a part has no height`);
};

test('the cities the user asked for are all there, once', () => {
  const ids = CITIES.map((c) => c.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of ['medellin', 'silicon-valley', 'new-york', 'miami', 'boston', 'berlin', 'sao-paulo', 'tokyo', 'shanghai', 'shenzhen', 'beijing', 'abu-dhabi', 'dubai', 'london', 'dublin', 'generic']) {
    assert.ok(ids.includes(id), id);
  }
  assert.equal(cityById(DEFAULT_CITY).id, 'medellin');
  assert.equal(cityById('atlantis').id, 'generic');
});

for (const c of CITIES) {
  test(`${c.id}: a valid preset`, () => {
    assert.ok(c.name && REGIONS[c.region], 'name and region');
    if (c.timeZone !== null) assert.doesNotThrow(() => new Intl.DateTimeFormat('en', { timeZone: c.timeZone }), c.timeZone);
    if (c.terrain) for (const [x, z] of [[0, 0], [300, -300], [1500, 1500]]) assert.ok(Number.isFinite(c.terrain(x, z)));
    if (c.terrain) assert.ok(c.terrain(0, 0) < 0.4, 'the tower stands on flat ground');
    for (const w of c.water || []) {
      assert.ok(w.length === 4 && w[0] < w[2] && w[1] < w[3], `water ${w}`);
      assert.ok(!(w[0] < 40 && w[2] > -40 && w[1] < 40 && w[3] > -40), 'no water under the tower');
    }
    for (const [k, v] of Object.entries(c.facades?.mix || {})) assert.ok(FACADE_MATS.includes(k) && v > 0, k);
    for (const [k, v] of Object.entries(c.facades?.tall || {})) assert.ok(FACADE_MATS.includes(k) && v > 0, k);
    for (const L of c.landmarks || []) {
      checkParts(`${c.id}/${L.name}`, L.parts);
      assert.ok(Math.hypot(...L.at) > 350, `${L.name} stands beyond the blocks around the tower`);
    }
    if (c.skyline) {
      for (const [from, to, d] of c.skyline.arcs || []) assert.ok(from < to && to - from <= 360 && d > 0 && d <= 1, 'arc');
      for (const L of c.skyline.landmarks || []) checkParts(`${c.id}/skyline`, L.parts);
    }
    for (const key of ['day', 'dusk', 'night']) if (c.sky?.[key]) assert.ok(c.sky[key].length === 3 && c.sky[key].every(isColor), key);
  });
}
