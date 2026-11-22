"""Adds a session symbol from one image: a 3 x 3 sheet with the 9 frames of its thinking animation, black on white
(the prompts are in font/symbol-prompt.md). The first cell is also the still symbol.

    python font/add_symbol.py <id> "<Spanish name>" "<English name>" <sheet.png>
    python font/add_symbol.py --test

Writes symbols/<id> (images and font), the phone's notification icons and list, and the English name. Run it again
with the same id to replace the drawing. Needs fontTools and Pillow. Then install.ps1 deploys it, and the phone needs
a new APK only for the small status-bar icon.
"""
import json
import keyword
import pathlib
import re
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageStat

from build_eggs_font import ROOT, build, mask_of, silhouette

COLOR = (244, 105, 67)  # the egg's; only the shape counts, every place paints it in the session's color
SIDE = 384              # the longest side kept
FRAME_MS = 120
ANDROID = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
# Words Android refuses as a resource name, beyond Python's own, and the built-in symbol.
RESERVED = {'egg', 'default', 'new', 'null', 'public', 'private', 'switch', 'case', 'int', 'void', 'static', 'native'}


def alpha_of(sheet):
    """The ink: the image's own transparency if it has one, else how dark it is."""
    sheet = sheet.convert('RGBA')
    alpha = sheet.getchannel('A')
    if alpha.histogram()[0] > 0.2 * sheet.width * sheet.height:
        return alpha
    white = Image.new('RGBA', sheet.size, 'white')
    white.alpha_composite(sheet)
    return white.convert('L').point(lambda v: 255 if v <= 70 else 0 if v >= 190 else round((190 - v) * 255 / 120))


def solid(alpha):
    return alpha.point(lambda v: 255 if v > 127 else 0)


def area(mask):
    return mask.histogram()[255]


def centroid(mask):
    small = mask.resize((96, 96))
    pixels = small.load()
    total = sx = sy = 0
    for y in range(96):
        for x in range(96):
            v = pixels[x, y]
            total, sx, sy = total + v, sx + v * x, sy + v * y
    return sx / total * mask.width / 96, sy / total * mask.height / 96


def frames_of(sheet):
    """The 9 cells, centered on each other (image models drift) and cropped to one box."""
    alpha = alpha_of(sheet)
    w, h = sheet.width // 3, sheet.height // 3
    cells, shapes = [], []
    for k in range(9):
        cell = alpha.crop((k % 3 * w, k // 3 * h, (k % 3 + 1) * w, (k // 3 + 1) * h))
        box = solid(cell).getbbox()
        if not box:
            raise ValueError('cell %d is empty' % (k + 1))
        if box[0] < 2 or box[1] < 2 or box[2] > w - 2 or box[3] > h - 2:
            raise ValueError('cell %d touches its border: generate again with more margin and no grid lines' % (k + 1))
        cells.append(cell)
        shapes.append(silhouette(solid(cell)))
    sizes = [area(shape) for shape in shapes]
    if area(solid(cells[0])) > 0.95 * sizes[0]:
        raise ValueError('cell 1 has no enclosed holes: speaking would look like waiting')
    if max(sizes) > 1.5 * min(sizes):
        raise ValueError('the cells differ too much in size (or a hole is open in some): generate again')
    placed = []
    for cell, shape in zip(cells, shapes):
        x, y = centroid(shape)
        canvas = Image.new('L', (2 * w, 2 * h), 0)
        canvas.paste(cell, (round(w - x), round(h - y)))
        placed.append(canvas)
    union = placed[0]
    for frame in placed[1:]:
        union = ImageChops.lighter(union, frame)
    left, top, right, bottom = solid(union).getbbox()
    box = (left - 1, top - 1, right + 1, bottom + 1)
    scale = min(1, SIDE / max(box[2] - box[0], box[3] - box[1]))
    size = (round((box[2] - box[0]) * scale), round((box[3] - box[1]) * scale))
    return [frame.crop(box).resize(size, Image.LANCZOS) for frame in placed]


def painted(alpha, color=COLOR):
    image = Image.new('RGBA', alpha.size, color + (0,))
    image.putalpha(alpha)
    return image


def write_filled(folder):
    with Image.open(folder / 'still.png') as still:
        filled = ImageChops.lighter(still.convert('RGBA').getchannel('A'), silhouette(mask_of(still)))
    painted(filled).save(folder / 'filled.png', optimize=True)


def write_images(frames, folder):
    folder.mkdir(parents=True, exist_ok=True)
    painted(frames[0]).save(folder / 'still.png', optimize=True)
    write_filled(folder)
    gif = []
    for alpha in frames:
        indexed = Image.frombytes('P', alpha.size, solid(alpha).point(lambda v: 1 if v else 0).tobytes())
        indexed.putpalette([255, 255, 255] + list(COLOR) + [0, 0, 0] * 254)
        gif.append(indexed)
    target = folder / 'thinking.gif'
    gif[0].save(target, save_all=True, append_images=gif[1:], duration=FRAME_MS, loop=0, transparency=0, disposal=2, optimize=False)
    with Image.open(target) as saved:
        if getattr(saved, 'n_frames', 1) != 9:
            raise ValueError('two neighboring cells are the same drawing: generate again')


def write_android(symbol, still):
    still = still.crop(solid(still).getbbox())
    for density, side in ANDROID.items():
        scale = side / max(still.size)
        small = still.resize((max(1, round(still.width * scale)), max(1, round(still.height * scale))), Image.LANCZOS)
        icon = Image.new('L', (side, side), 0)
        icon.paste(small, ((side - small.width) // 2, (side - small.height) // 2))
        folder = ROOT / 'mobile/android/app/src/main/res' / ('drawable-' + density)
        painted(icon, (255, 255, 255)).save(folder / ('ic_stat_%s.png' % symbol))


def write_dart_list():
    ids = sorted(info.parent.name for info in (ROOT / 'symbols').glob('*/symbol.json'))
    (ROOT / 'mobile' / 'lib' / 'symbols.dart').write_bytes((
        '// Written by font/add_symbol.py: the symbols with a notification icon in this APK (ic_stat_<id>).\n'
        'const bundledSymbols = {%s};\n' % ', '.join("'%s'" % i for i in ids)).encode('utf-8'))


def write_english(spanish, english):
    path = ROOT / 'lib' / 'lang' / 'en.json'
    text = path.read_bytes().decode('utf-8')
    if spanish in json.loads(text)['strings']:
        return
    eol = '\r\n' if '\r\n' in text else '\n'
    end = text.rindex(eol + '  }')
    entry = ',%s    %s: %s' % (eol, json.dumps(spanish, ensure_ascii=False), json.dumps(english, ensure_ascii=False))
    path.write_bytes((text[:end] + entry + text[end:]).encode('utf-8'))


def add(symbol, spanish, english, sheet):
    if not re.fullmatch(r'[a-z][a-z0-9_]{1,24}', symbol) or keyword.iskeyword(symbol) or symbol in RESERVED:
        raise ValueError('the id takes lowercase letters, digits and _, and is neither egg nor a reserved word')
    frames = frames_of(Image.open(sheet))
    # All of it is made apart first: a drawing that fails leaves the one there was.
    with tempfile.TemporaryDirectory() as tmp:
        draft = pathlib.Path(tmp)
        write_images(frames, draft)
        build(draft, symbol)
        folder = ROOT / 'symbols' / symbol
        folder.mkdir(parents=True, exist_ok=True)
        for made in draft.iterdir():
            (folder / made.name).write_bytes(made.read_bytes())
    info = json.dumps({'name': spanish}, ensure_ascii=False, indent=2) + '\n'
    (folder / 'symbol.json').write_bytes(info.encode('utf-8'))
    write_android(symbol, frames[0])
    write_dart_list()
    write_english(spanish, english)
    print('%s ready. Deploy with install.ps1; a new APK brings its status-bar icon.' % symbol)


def self_test():
    def sheet(hole=True, reach=0):
        image = Image.new('RGB', (900, 900), 'white')
        draw = ImageDraw.Draw(image)
        for k in range(9):
            x, y = k % 3 * 300 + k, k // 3 * 300  # drifting a pixel per cell
            draw.ellipse((x + 50 - reach, y + 50, x + 240, y + 250), fill='black')
            if hole:
                draw.ellipse((x + 90, y + 80 + 8 * k, x + 190, y + 130 + 8 * k), fill='white')
        return image

    frames = frames_of(sheet())
    assert len(frames) == 9 and len({frame.size for frame in frames}) == 1
    middles = [centroid(silhouette(solid(frame)))[0] for frame in frames]
    assert max(middles) - min(middles) < 3, 'the drift is not removed'
    with tempfile.TemporaryDirectory() as tmp:
        folder = pathlib.Path(tmp)
        write_images(frames, folder)
        with Image.open(folder / 'filled.png') as filled:
            assert ImageStat.Stat(filled.getchannel('A')).sum[0] > ImageStat.Stat(frames[0]).sum[0] * 1.1, 'the hole is not filled'
        build(folder, 'selftest')
    for bad in (sheet(hole=False), sheet(reach=60), Image.new('RGB', (900, 900), 'white')):
        try:
            frames_of(bad)
        except ValueError:
            continue
        raise AssertionError('a bad sheet was accepted')
    print('add_symbol: ok')


if __name__ == '__main__':
    if sys.argv[1:] == ['--test']:
        self_test()
    elif len(sys.argv) == 5:
        try:
            add(*sys.argv[1:])
        except ValueError as error:
            sys.exit('not added: %s' % error)
    else:
        sys.exit(__doc__)
