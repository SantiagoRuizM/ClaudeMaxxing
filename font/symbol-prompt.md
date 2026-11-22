# The prompts for a session symbol

Two steps in an image model: the icon, then its animation. `font/add_symbol.py` takes **only the second image**: a
3 x 3 sheet with the 9 frames of the thinking animation, black on white. The first frame is also the still symbol, and
the speaking one is made from it by filling its holes. Colors don't matter: every place paints the shape in the
session's color.

## 1. The icon

Replace `[figure here]`:

```text
Create one single original minimalist logo icon of: [figure here]

- Square 1:1 image, 1024x1024. Only one icon, centered, filling about 70% of the image, with white margin all around.
- Flat solid pure black shape on a flat pure white background. No gray, color, gradient, shadow, texture or 3D.
- Bold organic silhouette built from one thick, smooth outline with rounded corners. Compact, about as tall as it is
  wide or slightly taller, and recognizable from its outline alone.
- Inside the outline, 2 or 3 large white openings separated by thick black bands. Every opening is completely
  enclosed by black. Together they cover about 40% of the silhouette.
- Every stroke is at least 10% of the icon's width. No tiny details: it must read clearly at 16x16 pixels.
- No text, frame, watermark or transparency checkerboard. Not an existing character, mascot, brand or logo.
```

## 2. The animation

Attach the icon from step 1 and paste this as it is:

```text
Using the attached icon exactly as it is, create a "thinking" animation sprite sheet of it.

- One square 1:1 image, 1536x1536, with exactly 9 drawings of this same icon in an invisible, evenly spaced 3x3 grid.
- Cell 1 is the attached icon, unchanged. The cells read left to right, top to bottom, as a seamless loop, and cell 9
  leads smoothly back into cell 1.
- Animate it gently in the way that is natural for this figure: its inner bands flow and its loose parts sway.
  Small even steps, and every cell slightly different from the one before it.
- Keep the same identity, size, outer proportions and stroke thickness in all 9 cells. All white openings stay
  completely enclosed by black.
- Each drawing is centered in its cell and fills about 70% of it. Nothing touches or crosses a cell edge.
- Flat pure black on flat pure white. No grid lines, numbers, text, shadows, gray, color or watermark.
```

## 3. Add it

```
pip install fonttools pillow
python font/add_symbol.py <id> "<Spanish name>" "<English name>" <sheet.png>
```

It refuses a sheet whose cells touch their borders, differ too much in size, repeat or have no holes, and says which.
