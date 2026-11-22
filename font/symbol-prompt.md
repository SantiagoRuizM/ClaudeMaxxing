# The prompt for a session symbol

`font/add_symbol.py` takes **one square image** (1536 x 1536 or more): a 3 x 3 sheet with the 9 frames of the thinking
animation, black on white. The first frame is also the still symbol, and the speaking one is made from it by filling
its holes. Colors don't matter: every place paints the shape in the session's color.

Replace the two values in brackets and paste it in an image model:

```text
Create a square 1:1 sprite sheet, 1536x1536 pixels, for an original minimalist app icon: [SYMBOL].

LAYOUT
- Exactly 9 drawings of the same icon in an invisible, evenly spaced 3x3 grid (three 512x512 cells per row).
- Each drawing is centered in its cell and fills about 70% of it, with clear empty white margin on all four sides.
  Nothing touches or crosses a cell edge.
- No grid lines, borders, frames, numbers, letters, captions or watermark.

STYLE
- Flat solid pure black (#000000) on a flat pure white (#FFFFFF) background. No gray, color, gradient, shadow, glow,
  texture, 3D or sketchy lines. Do not draw a transparency checkerboard.
- A bold organic logo silhouette built from one thick, smooth outline with rounded corners. Every stroke is at least
  10% of the icon's width, so it still reads at 16x16 pixels.
- Inside the outline, 2 or 3 large white openings separated by thick black bands. Every opening is completely
  enclosed by black. Together they cover about 40% of the silhouette. No tiny details.
- The outer shape is compact, about as tall as it is wide or slightly taller, and recognizable from its outline alone.
- An original design: not an existing character, mascot, brand or logo.

ANIMATION
- The 9 cells, read left to right and top to bottom, are consecutive frames of a seamless loop: [MOTION].
- Cell 1 is the neutral resting pose and must work as a standalone logo. Cell 9 leads smoothly back into cell 1.
- The icon keeps the same identity, size, position, outer proportions and stroke weight in all 9 cells. Only the
  motion described changes, in small even steps, and every cell is slightly different from the one before it.
- All openings stay enclosed in every cell.
```

Then:

```
pip install fonttools pillow
python font/add_symbol.py <id> "<Spanish name>" "<English name>" <sheet.png>
```

It refuses a sheet whose cells touch their borders, differ too much in size, repeat or have no holes, and says which.
