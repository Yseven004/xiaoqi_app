"""Render the standalone SVG asset sheet; this is not a browser/UI capture."""
from io import BytesIO
from pathlib import Path
import cairosvg
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
icons = sorted((root / 'public/icons/detail').glob('*.svg'))
previews = sorted((root / 'public/previews').glob('*.svg'))
canvas = Image.new('RGB', (840, 800), 'white')
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 13)
draw.text((24, 12), 'Standalone vectors: icons at 64 x 64; report previews at 220 x 300', fill='#191919', font=font)
for index, path in enumerate(icons):
    x, y = 24 + index % 7 * 116, 48 + index // 7 * 100
    png = cairosvg.svg2png(url=str(path), output_width=64, output_height=64)
    img = Image.open(BytesIO(png)).convert('RGBA')
    canvas.paste(img, (x, y), img)
    draw.text((x, y + 68), path.stem, fill='#555555', font=font)
for index, path in enumerate(previews):
    x, y = 24 + index * 270, 466
    png = cairosvg.svg2png(url=str(path), output_width=220, output_height=300)
    img = Image.open(BytesIO(png)).convert('RGBA')
    canvas.paste(img, (x, y), img)
    draw.text((x, y + 304), path.stem, fill='#555555', font=font)
output = root / '.impeccable/review/detail-assets.png'
output.parent.mkdir(parents=True, exist_ok=True)
canvas.save(output)
print(f'Rendered {len(icons)} icons + {len(previews)} report SVGs: {output}')
