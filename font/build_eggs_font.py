"""Builds font/ClaudeMaxxingEggs.ttf: the session egg as glyphs for the Claude Code statusline.

Each frame of the egg is drawn two terminal cells wide, as two glyphs in the Private Use Area: frame k is
U+E100 + 2k (left half) and U+E101 + 2k (right half). The terminal colors them like any text, so the statusline
prints the frame in the session's color. Frames:
    0       the still egg (egg_logo.png)
    1..N    the thinking animation (the frames of egg_logo_gift_thinking.gif)
    N+1     the egg filled in (its silhouette), for the speaking blink
Metrics match Cascadia Mono (Windows Terminal's default font) so each glyph fills exactly one cell; the menu
sessions' terminal profiles list this font after their main one (lib\\installer.ps1, Install-TerminalProfiles).

Run it again after changing the egg images (needs fontTools and Pillow):
    python font/build_eggs_font.py
"""
import pathlib

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from PIL import Image, ImageDraw, ImageSequence

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'font' / 'ClaudeMaxxingEggs.ttf'
FAMILY = 'ClaudeMaxxing Eggs'

UPM, ADVANCE, ASCENT, DESCENT = 2048, 1200, 1900, 480  # Cascadia Mono's
BASE = 0xE100
ROWS = 150          # vertical resolution the egg is traced at; finer than any terminal renders it
MARGIN = 120        # space kept above and below the egg inside the line


def mask_of(image):
    """Opaque pixels of an image as a 0/255 mask."""
    return image.convert('RGBA').getchannel('A').point(lambda v: 255 if v > 100 else 0)


def silhouette(mask):
    """The mask with its holes filled: everything the outside cannot reach from the border."""
    padded = Image.new('L', (mask.width + 2, mask.height + 2), 0)
    padded.paste(mask, (1, 1))
    ImageDraw.floodfill(padded, (0, 0), 128)
    return padded.crop((1, 1, mask.width + 1, mask.height + 1)).point(lambda v: 0 if v == 128 else 255)


def union_box(masks):
    boxes = [m.getbbox() for m in masks if m.getbbox()]
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def rectangles(mask, box):
    """The egg inside box as row runs, in font units centered on two cells: (x0, y0, x1, y1), y up."""
    crop = mask.crop(box)
    height = ASCENT + DESCENT - 2 * MARGIN
    scale = height / ROWS
    cols = max(1, round(ROWS * crop.width / crop.height))
    small = crop.resize((cols, ROWS), Image.LANCZOS)
    left = (2 * ADVANCE - cols * scale) / 2
    top = ASCENT - MARGIN
    pixels = small.load()
    runs = []
    for row in range(ROWS):
        col = 0
        while col < cols:
            if pixels[col, row] >= 128:
                start = col
                while col < cols and pixels[col, row] >= 128:
                    col += 1
                runs.append((left + start * scale, top - (row + 1) * scale, left + col * scale, top - row * scale))
            else:
                col += 1
    return runs


def glyph(runs, offset):
    """One cell's glyph: the runs that fall inside [offset, offset + ADVANCE), shifted to start at 0."""
    pen = TTGlyphPen(None)
    for x0, y0, x1, y1 in runs:
        a, b = max(x0, offset), min(x1, offset + ADVANCE)
        if b - a < 1:
            continue
        a, b, y0, y1 = round(a - offset), round(b - offset), round(y0), round(y1)
        if b <= a or y1 <= y0:
            continue
        # Clockwise, as TrueType wants outer contours.
        pen.moveTo((a, y0))
        pen.lineTo((a, y1))
        pen.lineTo((b, y1))
        pen.lineTo((b, y0))
        pen.closePath()
    return pen.glyph()


def main():
    still = mask_of(Image.open(ROOT / 'egg_logo.png'))
    gif = Image.open(ROOT / 'egg_logo_gift_thinking.gif')
    thinking = [mask_of(frame.copy()) for frame in ImageSequence.Iterator(gif)]
    # The GIF's frames share one box, so its outline stays put while the waves move.
    frames = [(still, still.getbbox())]
    gif_box = union_box(thinking)
    frames += [(m, gif_box) for m in thinking]
    frames.append((silhouette(still), still.getbbox()))

    order = ['.notdef', 'space']
    cmap = {0x20: 'space'}
    glyphs = {'.notdef': TTGlyphPen(None).glyph(), 'space': TTGlyphPen(None).glyph()}
    for k, (mask, box) in enumerate(frames):
        runs = rectangles(mask, box)
        for half, offset in (('l', 0), ('r', ADVANCE)):
            name = 'egg%02d%s' % (k, half)
            order.append(name)
            cmap[BASE + 2 * k + (0 if half == 'l' else 1)] = name
            glyphs[name] = glyph(runs, offset)

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    table = fb.font['glyf']
    metrics = {}
    for name in order:
        g = table[name]
        g.recalcBounds(table)
        metrics[name] = (ADVANCE, getattr(g, 'xMin', 0))
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=-DESCENT)
    # Windows (GDI) refuses a font without its full set of names.
    fb.setupNameTable({'familyName': FAMILY, 'styleName': 'Regular', 'uniqueFontIdentifier': FAMILY + ' Regular 1.0',
                       'fullName': FAMILY + ' Regular', 'version': 'Version 1.000', 'psName': FAMILY.replace(' ', '') + '-Regular'})
    fb.setupOS2(sTypoAscender=ASCENT, sTypoDescender=-DESCENT, sTypoLineGap=0,
                usWinAscent=ASCENT, usWinDescent=DESCENT)
    fb.setupPost(isFixedPitch=1)
    fb.save(str(OUT))
    print('%s: %d frames (still, %d thinking, filled), U+%04X..U+%04X'
          % (OUT, len(frames), len(thinking), BASE, BASE + 2 * len(frames) - 1))


if __name__ == '__main__':
    main()
