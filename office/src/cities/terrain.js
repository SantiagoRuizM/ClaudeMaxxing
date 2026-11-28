// Terrain helpers for city presets: plain functions of (x, z) in meters, 0 = the city floor.
export const smooth = (a, b, v) => { const t = Math.min(1, Math.max(0, (v - a) / (b - a))); return t * t * (3 - 2 * t); };

// Hills that rise from `from` to `to` meters away, up to h, with a little noise. dir: 'ew' (east and west, a valley),
// 'n', 's', 'e', 'w' (one side) or nothing (all around).
export function hills({ from = 900, to = 1500, h = 120, dir = '' } = {}) {
  const dist = { ew: (x) => Math.abs(x), n: (x, z) => -z, s: (x, z) => z, e: (x) => x, w: (x) => -x }[dir] || ((x, z) => Math.hypot(x, z));
  return (x, z) => {
    const d = dist(x, z);
    if (d < from) return 0;
    const n = 1 + 0.25 * Math.sin(x * 0.009 + 1.1) * Math.cos(z * 0.007) + 0.12 * Math.sin((x + z) * 0.021);
    return Math.max(0, smooth(from, to, d) * h * n);
  };
}
