import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { placeTeam, MAX_PODS, PER_POD } from '../src/team.js';

const demo = JSON.parse(readFileSync(new URL('../demo/office.json', import.meta.url), 'utf8'));

test('the demo team fills both offices and the four pods', () => {
  const t = placeTeam(demo);
  assert.deepEqual(t.warnings, []);
  assert.deepEqual(t.founders, ['CEO', 'CTO']);
  assert.equal(t.pods.length, MAX_PODS);
  assert.ok(t.pods.every((p) => p.members.length === PER_POD));
  assert.equal(t.people.length, 18);
});

test('people the plan cannot hold are left out with a warning', () => {
  const agents = (team, n) => Array.from({ length: n }, (_, i) => ({ id: `${team}${i}`, kind: 'agent', team }));
  const t = placeTeam({
    teams: { a: {}, b: {}, c: {}, d: {}, e: {}, boss: {} },
    people: [
      ...['F1', 'F2', 'F3'].map((id) => ({ id, kind: 'founder', team: 'boss' })),
      ...agents('a', 5), ...agents('b', 1), ...agents('c', 1), ...agents('d', 1), ...agents('e', 1),
      { id: 'a0', kind: 'agent', team: 'a' }, { id: 'x', kind: 'agent', team: 'nope' }, { id: 'y', kind: 'robot', team: 'a' }, { kind: 'agent' },
    ],
  });
  assert.deepEqual(t.founders, ['F1', 'F2']);
  assert.deepEqual(t.pods.map((p) => p.team), ['a', 'b', 'c', 'd']);
  assert.deepEqual(t.pods[0].members, ['a0', 'a1', 'a2', 'a3']);
  assert.equal(t.people.length, 2 + 4 + 3);
  assert.equal(t.warnings.length, 7); // F3, a4, e0, repeated a0, unknown team, bad kind, no id
});

test('a person gets a default look and the team color as shirt', () => {
  const t = placeTeam({ teams: { a: { color: '#123456' } }, people: [{ id: 'A', kind: 'agent', team: 'a', look: { hair: 'bun' } }] });
  const [p] = t.people;
  assert.equal(p.look.shirt, '#123456');
  assert.equal(p.look.hair, 'bun');
  assert.equal(typeof p.look.height, 'number');
  assert.deepEqual(p.does, []);
});

test('an empty or missing configuration places nobody', () => {
  for (const cfg of [undefined, {}, { people: 'x' }]) assert.equal(placeTeam(cfg).people.length, 0);
});
