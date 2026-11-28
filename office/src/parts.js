// Pure part helpers (no Three.js), shared by landmarks.js, the skyline painter and the preset tests.
// A landmark is a list of parts stacked from the ground up (each starts where the previous one ends unless it gives y).
// Shapes: box {w,d,h} | cyl {r,r2,h,seg} (r2 0 = cone) | sphere {r,sy} | ring {r,t,flat} | disc {r,t} (an upright coin). Placement: x, z, y; tilt rx, rz;
// yaw ry; horizontal scale sx, sz. Material m: a facade (glass, concrete, white, brick, brick2: windows that light at night), metal, stone, light
// (glows at night) or paint (plain c). The same parts draw the 3D landmark and its silhouette on the far skyline.

export const SHAPES = ['box', 'cyl', 'sphere', 'ring', 'disc'];
export const FACADE_MATS = ['glass', 'concrete', 'white', 'brick', 'brick2'];
export const PLAIN_MATS = ['metal', 'stone', 'light', 'paint'];

export function partHeight(p) {
  if (p.s === 'sphere') return 2 * p.r * (p.sy || 1);
  if (p.s === 'disc') return 2 * p.r;
  if (p.s === 'ring') return p.flat ? 2 * p.t : 2 * (p.r + p.t);
  return p.h;
}

// [y0, h] of every part, following the stacking rule.
export function stackParts(parts) {
  let top = 0;
  return parts.map((p) => {
    const y0 = p.y ?? top;
    const h = partHeight(p);
    top = y0 + h;
    return [y0, h];
  });
}
