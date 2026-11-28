// Interior styles: materials and palette of the office, never its floor plan. Every style has the same keys as moderno
// (test/styles.test.mjs); wallTexture is null or 'brick', floor.kind 'planks' (tones) or 'concrete' (color).
import moderno from './moderno.js';
import loft from './loft.js';

export const STYLES = [moderno, loft];
export const DEFAULT_STYLE = 'moderno';
export const styleById = (id) => STYLES.find((s) => s.id === id) || moderno;
