// Places the configured people in the fixed floor plan: the first two founders get the private offices (west, east),
// agents sit in the pod of their team (up to four teams, four agents each). No Three.js here, so node --test runs it.

export const MAX_PODS = 4;
export const PER_POD = 4;
const FALLBACK_TEAM = { name: '', color: '#9AA5B1', rug: '#B9C0C7' };
const DEFAULT_LOOK = { skin: '#D9A27C', hair: 'short', hairColor: '#2B1D14', top: 'shirt', pants: '#2B2F38', height: 1.74 };

export function placeTeam(cfg) {
  const warnings = [];
  const teams = {};
  for (const [id, t] of Object.entries(cfg?.teams || {})) teams[id] = { ...FALLBACK_TEAM, ...t };
  const seen = new Set();
  const valid = [];
  for (const p of Array.isArray(cfg?.people) ? cfg.people : []) {
    if (!p || typeof p.id !== 'string' || !p.id) { warnings.push('a person without id was left out'); continue; }
    if (seen.has(p.id)) { warnings.push(`${p.id}: repeated id, left out`); continue; }
    if (p.kind !== 'founder' && p.kind !== 'agent') { warnings.push(`${p.id}: kind must be founder or agent, left out`); continue; }
    if (!teams[p.team]) { warnings.push(`${p.id}: unknown team ${p.team}, left out`); continue; }
    seen.add(p.id);
    valid.push({
      ...p, name: String(p.name || p.id), role: String(p.role || ''), does: Array.isArray(p.does) ? p.does.map(String) : [],
      look: { ...DEFAULT_LOOK, shirt: teams[p.team].color, ...(p.look || {}) },
    });
  }

  const founders = valid.filter((p) => p.kind === 'founder');
  founders.slice(2).forEach((p) => warnings.push(`${p.id}: only two founders have an office, left out`));
  const pods = [];
  for (const team of Object.keys(teams)) {
    const members = valid.filter((p) => p.kind === 'agent' && p.team === team);
    if (!members.length) continue;
    if (pods.length === MAX_PODS) { members.forEach((p) => warnings.push(`${p.id}: only ${MAX_PODS} team pods, left out`)); continue; }
    members.slice(PER_POD).forEach((p) => warnings.push(`${p.id}: only ${PER_POD} desks per pod, left out`));
    pods.push({ team, members: members.slice(0, PER_POD).map((p) => p.id) });
  }
  const placed = new Set([...founders.slice(0, 2).map((p) => p.id), ...pods.flatMap((p) => p.members)]);
  return {
    teams,
    people: valid.filter((p) => placed.has(p.id)),
    founders: founders.slice(0, 2).map((p) => p.id),
    pods,
    warnings,
  };
}
