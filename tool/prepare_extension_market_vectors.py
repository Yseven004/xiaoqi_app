"""Outline approved report text; assets remain standalone paths for flutter_svg.

Uses the prototype's first font (Microsoft YaHei), preserving its baseline,
font size, weight and text anchoring. This does not capture or trace pixels.
Run with fontTools installed; add --preview to render a standalone asset sheet
using CairoSVG/Pillow. No Flutter, device or browser operation is performed.
"""
from pathlib import Path
import argparse
import xml.etree.ElementTree as ET
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'docs/design/extension-market-v2/prototype/public'
DEST = ROOT / 'assets/icons/extension_market'
REPORTS = ROOT / 'docs/design/extension-market-v2/flutter-vectors'
NS = 'http://www.w3.org/2000/svg'
ET.register_namespace('', NS)


def outline(source, target):
    tree = ET.parse(source)
    fonts = {
        False: TTFont('C:/Windows/Fonts/msyh.ttc', fontNumber=0),
        True: TTFont('C:/Windows/Fonts/msyhbd.ttc', fontNumber=0),
    }
    count = 0

    def visit(parent, inherited):
        nonlocal count
        for node in list(parent):
            style = {**inherited, **node.attrib}
            if node.tag != f'{{{NS}}}text':
                visit(node, style)
                continue
            text = ''.join(node.itertext())
            weight = style.get('font-weight', '400')
            font = fonts[weight == 'bold' or weight.isdigit() and int(weight) >= 600]
            glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
            scale = float(style.get('font-size', '16')) / font['head'].unitsPerEm
            names = []
            for char in text:
                if ord(char) not in cmap:
                    raise ValueError(f'Missing glyph U+{ord(char):04X} in {source.name}')
                names.append(cmap[ord(char)])
            advance = sum(font['hmtx'][name][0] for name in names) * scale
            x, y = float(style.get('x', 0)), float(style.get('y', 0))
            anchor = style.get('text-anchor', 'start')
            x -= advance / 2 if anchor == 'middle' else advance if anchor == 'end' else 0
            group = ET.Element(f'{{{NS}}}g', {'fill': style.get('fill', '#191919'), 'aria-label': text})
            for name in names:
                pen = SVGPathPen(glyphs)
                glyphs[name].draw(pen)
                path = pen.getCommands()
                if path:
                    ET.SubElement(group, f'{{{NS}}}path', {
                        'd': path,
                        'transform': f'translate({x:.6f} {y:.6f}) scale({scale:.9f} {-scale:.9f})',
                    })
                x += font['hmtx'][name][0] * scale
            index = list(parent).index(node)
            parent.remove(node)
            parent.insert(index, group)
            count += 1

    visit(tree.getroot(), {})
    target.parent.mkdir(parents=True, exist_ok=True)
    tree.write(target, encoding='utf-8', xml_declaration=False)
    assert not tree.getroot().findall(f'.//{{{NS}}}text')
    print(f'{target.relative_to(ROOT)}: {count} text runs converted to glyph paths')


def preview():
    import cairosvg
    from PIL import Image, ImageDraw, ImageFont
    from io import BytesIO
    icons = sorted(DEST.glob('*.svg')) + sorted((DEST / 'detail').glob('*.svg'))
    reports = sorted(REPORTS.glob('*.svg'))
    canvas = Image.new('RGB', (900, 1230), 'white')
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 12)
    for index, path in enumerate(icons):
        x, y = 20 + index % 8 * 110, 20 + index // 8 * 125
        png = cairosvg.svg2png(url=str(path), output_width=64, output_height=64)
        img = Image.open(BytesIO(png)).convert('RGBA')
        canvas.paste(img, (x, y), img)
        draw.text((x, y + 70), path.stem, fill='#555555', font=font)
    for index, path in enumerate(reports):
        x, y = 20 + index * 290, 820
        png = cairosvg.svg2png(url=str(path), output_width=220, output_height=300)
        img = Image.open(BytesIO(png)).convert('RGBA')
        canvas.paste(img, (x, y), img)
        draw.text((x, y + 306), path.stem, fill='#555555', font=font)
    output = ROOT / '.codex-artifacts/extension-market-v2/standalone-vectors.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--preview', action='store_true')
    args = parser.parse_args()
    for source in sorted((SOURCE / 'previews').glob('*.svg')):
        outline(source, REPORTS / source.name)
    if args.preview:
        preview()
