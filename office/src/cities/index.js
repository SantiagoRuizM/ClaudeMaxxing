// The background cities. A preset is data (plus plain functions of x, z), read by the engine in src/city.js:
//   id, name (in the product language), region (america | europa | asia | medio-oriente | otra), timeZone (IANA, or null
//   for the viewer's own), terrain(x, z) -> height (0 = city floor; cities/terrain.js has hills()), ground {urban, green[3],
//   hill?, hillMix?}, water [[x0, z0, x1, z1]...] (meters; -z is north, the way the office looks), waterColor, shore, shoreW,
//   heights {near, mid, far: [min, max] m}, corridor [x0, x1] (kept low toward the landmarks), clusters [{x, z, rx, rz, n,
//   min, max, w?}], facades {mix, tall: weights per facade, colors: {facade: {wall, glass, frame}}}, balconies, parks
//   (share of park blocks), trees {colors, accents [[color, share]], palms, palmColors}, fill {n, w, d, min, max, tall,
//   colors}, fillSkip(x, z), landmarks [{name, at: [x, z], ry, clear, parts}] (parts.js), skyline {arcs [[from, to,
//   density]], min, max, color, landmarks [{angle, scale, parts}]} or null, sky {day, dusk, night: [top, horizon, bottom]},
//   haze (fog multiplier), clouds (count), intro / far {p, t: [x, y, z]} (camera), extras (city-extras/index.js).
// Nothing in a preset moves; only Medellín's extras do.
import medellin from './medellin.js';
import siliconValley from './silicon-valley.js';
import newYork from './new-york.js';
import miami from './miami.js';
import boston from './boston.js';
import saoPaulo from './sao-paulo.js';
import london from './london.js';
import dublin from './dublin.js';
import berlin from './berlin.js';
import tokyo from './tokyo.js';
import shanghai from './shanghai.js';
import shenzhen from './shenzhen.js';
import beijing from './beijing.js';
import dubai from './dubai.js';
import abuDhabi from './abu-dhabi.js';
import generic from './generic.js';

export const CITIES = [medellin, siliconValley, newYork, miami, boston, saoPaulo, london, dublin, berlin, tokyo, shanghai, shenzhen, beijing, dubai, abuDhabi, generic];
export const REGIONS = { america: 'América', europa: 'Europa', asia: 'Asia', 'medio-oriente': 'Medio Oriente', otra: 'Otra' };
export const DEFAULT_CITY = 'medellin';
export const cityById = (id) => CITIES.find((c) => c.id === id) || CITIES.find((c) => c.id === 'generic');
