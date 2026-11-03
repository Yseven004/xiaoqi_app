#!/usr/bin/env python3
"""Locate real glyphs, then overlay conventional reading annotations on source pixels."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
from html.parser import HTMLParser
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

MATERIALS = Path('/workspace/materials')
OUTPUT = Path('/workspace/output')
FONT = '/usr/local/share/fonts/LongCang-Regular.ttf'
KINDS = {'triangle', 'circle', 'underline', 'double', 'wave', 'question', 'highlight', 'bracket'}
RED = (162, 35, 49, 255)


def material(value: str) -> Path:
    path = Path(value).resolve()
    if not path.is_relative_to(MATERIALS.resolve()) or not path.is_file():
        raise ValueError('只能读取本次任务的私有材料')
    if path.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('图片超过 20 MB，请分开上传')
    return path


def source(path: Path) -> Image.Image:
    with Image.open(path) as image:
        if image.width * image.height > 8_000_000:
            raise ValueError('图片超过 800 万像素，请上传单页清晰图片')
        # EXIF orientation is the displayed source coordinate system; no redraw.
        return ImageOps.exif_transpose(image).convert('RGB')


class GlyphParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.lines = []
        self.line = None
        self.glyph = None
        self.depth = 0
        self.line_depth = None
        self.glyph_depth = None

    def handle_starttag(self, tag, attrs):
        self.depth += 1
        attrs = dict(attrs)
        classes = attrs.get('class', '').split()
        if 'ocr_line' in classes or 'ocr_caption' in classes:
            self.line = {'id': f'L{len(self.lines) + 1}', 'glyphs': []}
            self.lines.append(self.line)
            self.line_depth = self.depth
        if 'ocrx_cinfo' in classes and self.line is not None:
            title = attrs.get('title', '')
            box = re.search(r'x_bboxes (\d+) (\d+) (\d+) (\d+)', title)
            confidence = re.search(r'x_conf ([\d.]+)', title)
            if box and confidence:
                self.glyph = {'text': '', 'box': list(map(int, box.groups())),
                              'confidence': float(confidence.group(1))}
                self.glyph_depth = self.depth

    def handle_data(self, data):
        if self.glyph is not None:
            self.glyph['text'] += data

    def handle_endtag(self, tag):
        if self.glyph_depth == self.depth:
            self.line['glyphs'].append(self.glyph)
            self.glyph = None
            self.glyph_depth = None
        if self.line_depth == self.depth:
            self.line = None
            self.line_depth = None
        self.depth -= 1


def scan(path: Path, *, persist=True) -> dict:
    image = source(path)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    canonical = OUTPUT / 'ocr-input.png'
    try:
        image.save(canonical)
        result = subprocess.run(['tesseract', str(canonical), 'stdout', '-l', 'chi_sim+eng',
                                 '--psm', '3', '-c', 'hocr_char_boxes=1', 'hocr'],
                                capture_output=True, timeout=80, check=True)
    finally:
        canonical.unlink(missing_ok=True)
    parser = GlyphParser()
    parser.feed(result.stdout.decode('utf-8'))
    lines = []
    for line in parser.lines:
        glyphs = line['glyphs']
        if not glyphs:
            continue
        for glyph in glyphs:
            x0, y0, x1, y1 = glyph['box']
            if not (0 <= x0 < x1 <= image.width and 0 <= y0 < y1 <= image.height):
                raise ValueError('识别字框超出原图，请重新拍摄')
        line['text'] = ''.join(g['text'] for g in glyphs)
        line['box'] = union([g['box'] for g in glyphs])
        lines.append(line)
    if not lines:
        raise ValueError('未能识别清晰文字，请重新拍摄正向、清晰的单页图片')
    if len(lines)>180 or sum(len(line['text']) for line in lines)>16000:
        raise ValueError('单张图片内容过多，请拆成单页处理，不能截断后声称完整批注')
    state = {'schema': 1, 'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
             'size': list(image.size), 'lines': lines}
    if persist:
        state_path = OUTPUT / ('annotation-ocr-' + state['source_sha256'][:16] + '.json')
        state_path.write_text(json.dumps(state, ensure_ascii=False), encoding='utf-8')
        print(json.dumps({'state': state_path.name, 'lines': [
            {'id': line['id'], 'text': line['text']} for line in lines]}, ensure_ascii=False))
    return state


def union(boxes):
    return [min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes)]


def resolve(state: dict, mark: dict):
    if mark.get('kind') not in KINDS:
        raise ValueError('未知批注符号')
    quote = mark.get('quote', '')
    if not isinstance(quote, str) or not quote or len(quote) > 120:
        raise ValueError('批注必须引用短小的原文字句')
    line = next((line for line in state['lines'] if line['id'] == mark.get('line')), None)
    if line is None or line['text'].count(quote) != 1:
        raise ValueError('引用不存在或不唯一，请选择准确的行和原文')
    start = line['text'].index(quote)
    end = start + len(quote)
    selected, offset = [], 0
    for glyph in line['glyphs']:
        following = offset + len(glyph['text'])
        if offset < end and following > start:
            if offset < start or following > end or glyph['confidence'] < 80:
                raise ValueError('引用字框不够可靠，跳过该处批注并说明原因')
            selected.append(glyph)
        offset = following
    if not selected:
        raise ValueError('引用没有可靠字框')
    if mark['kind'] == 'triangle' and len(selected) > 8:
        raise ValueError('小三角仅用于短关键词，不能逐句铺满')
    comment = mark.get('comment', '')
    if not isinstance(comment, str) or len(comment) > 56 or '\n' in comment:
        raise ValueError('边批应为不超过 56 字的单条简评')
    return line, selected, comment


def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def render(path: Path, state: dict, plan: list) -> Path:
    image = source(path)
    if (state.get('schema') != 1 or state.get('source_sha256') != hashlib.sha256(path.read_bytes()).hexdigest()
            or state.get('size') != list(image.size)):
        raise ValueError('识别结果不属于这张原图，请重新识别')
    # Uploaded JSON and model-authored coordinates are never trusted as OCR.
    if state != scan(path, persist=False):
        raise ValueError('字框与原图重新识别结果不符，请重新识别')
    if not isinstance(plan, list) or not 1 <= len(plan) <= 16:
        raise ValueError('每页支持 1 至 16 处有意义的批注')
    resolved = [(mark, *resolve(state, mark)) for mark in plan]
    heights = [g['box'][3] - g['box'][1] for _, _, glyphs, _ in resolved for g in glyphs]
    scale = max(12, sorted(heights)[len(heights)//2])
    stroke = max(1, round(scale / 14))
    pad = max(24, round(scale * 1.2))
    has_comments = any(c for _, _, _, c in resolved)
    note_width = max(200, round(scale * 7)) if has_comments else pad
    safe_left = safe_right = 0
    if has_comments:
        content = union([line['box'] for line in state['lines']])
        candidates = (max(0, min(note_width-pad, content[0]-pad)),
                      max(0, min(note_width-pad, image.width-content[2]-pad)))
        # Only reuse genuinely blank original strips, never drawings or text.
        for right, width in enumerate(candidates):
            if width and min(v[0] for v in image.crop((image.width-width if right else 0, 0,
                                                     image.width if right else width, image.height)).getextrema()) >= 238:
                if right: safe_right = width
                else: safe_left = width
    margin, outer_right = note_width-safe_left, note_width-safe_right
    if (image.width+margin+outer_right)*(image.height+pad*2)>12_000_000:
        raise ValueError('批注画布过大，请上传裁好的单页图片')
    if not Path(FONT).is_file():
        raise ValueError('手写字体尚未安装，不能以印刷字体冒充手写批注')
    font = ImageFont.truetype(FONT, max(18, round(scale * 0.85)))
    canvas = Image.new('RGB', (image.width + margin + outer_right, image.height + pad * 2), 'white')
    canvas.paste(image, (margin, pad))
    layer = Image.new('RGBA', canvas.size)
    draw = ImageDraw.Draw(layer)
    used_comments = []
    source_boxes = [[b[0]+margin, b[1]+pad, b[2]+margin, b[3]+pad]
                    for line in state['lines'] for g in line['glyphs'] for b in [g['box']]]
    for mark, line, glyphs, comment in resolved:
        boxes = [[g['box'][0]+margin, g['box'][1]+pad, g['box'][2]+margin, g['box'][3]+pad] for g in glyphs]
        x0, y0, x1, y1 = union(boxes)
        kind = mark['kind']
        if kind == 'highlight':
            draw.rectangle((x0, y0, x1, y1), fill=(255, 230, 70, 65))
        elif kind == 'circle':
            draw.ellipse((x0-scale*.12, y0-scale*.1, x1+scale*.12, y1+scale*.1), outline=RED, width=stroke)
        elif kind == 'bracket':
            for x, sign in [(x0-scale*.2, 1), (x1+scale*.2, -1)]:
                draw.line([(x+sign*scale*.15,y0),(x,y0),(x,y1),(x+sign*scale*.15,y1)],fill=RED,width=stroke)
        elif kind == 'question':
            # Keep the mark outside the whole printed line, including punctuation.
            lx1 = line['box'][2]+margin
            candidate = [lx1+stroke*3,y0,lx1+scale*.8,y1+scale*.3]
            if any(overlap(candidate,b) for b in source_boxes):
                raise ValueError('问号旁没有安全空隙，跳过这处符号')
            draw.text((candidate[0],y0-scale*.15),'？',font=font,fill=RED)
        else:
            y = y1 + max(2,scale*.13)
            bottom = y + (scale*.2 if kind in {'triangle','double','wave'} else stroke)
            if any(overlap([x0,y-stroke,x1,bottom+stroke], b) for b in source_boxes):
                raise ValueError('行间距不足，不能把符号压到下一行正文')
            if kind == 'triangle':
                for b in boxes:
                    cx=(b[0]+b[2])/2; r=scale*.11
                    draw.line([(cx-r,y+r*1.6),(cx,y),(cx+r,y+r*1.6),(cx-r,y+r*1.6)],fill=RED,width=stroke)
            elif kind == 'double':
                for dy in (0,scale*.17):
                    draw.line((x0,y+dy,x1,y+dy),fill=RED,width=stroke)
            elif kind == 'wave':
                draw.line([(x,y+math.sin((x-x0)/scale*math.pi*2)*scale*.06)
                           for x in range(int(x0),int(x1)+1)],fill=RED,width=stroke)
            else:
                draw.line((x0,y,x1,y),fill=RED,width=stroke)
        if comment:
            right = (x0+x1)/2 >= margin+image.width/2
            left = margin+image.width-safe_right+pad//2 if right else pad//2
            chars = max(1, int((note_width-pad)/font.size))
            text = '\n'.join(comment[i:i+chars] for i in range(0,len(comment),chars))
            bounds = draw.multiline_textbbox((0,0),text,font=font,spacing=stroke*3)
            if bounds[2]-bounds[0] > note_width-pad:
                raise ValueError('边批文字过宽，请缩短评语')
            height = bounds[3]-bounds[1]+stroke*4
            top = max(pad,min(y0,canvas.height-height-pad))
            same_side = [b for b in used_comments if b[4]==right]
            for other in sorted(same_side,key=lambda b:b[1]):
                if overlap([left,top,left+note_width-pad,top+height],other):
                    top = other[3]+scale*.35
            if top+height > canvas.height-pad:
                raise ValueError('边批过密，请减少评语，避免重叠')
            used_comments.append([left,top,left+note_width-pad,top+height,right])
            draw.multiline_text((left,top-bounds[1]),text,font=font,fill=RED,spacing=stroke*3)
            # Arrows only connect genuinely displaced comments, never cross text.
            if abs(top-y0)>scale:
                edge=margin+image.width-safe_right+stroke if right else margin+safe_left-stroke
                tip=(edge,y0+scale*.5)
                tail=(edge+scale*.5 if right else edge-scale*.5,top+font.size*.5)
                draw.line([tail,tip],fill=RED,width=stroke)
                length=math.hypot(tail[0]-tip[0],tail[1]-tip[1])
                ux,uy=(tail[0]-tip[0])/length,(tail[1]-tip[1])/length
                r=scale*.2
                draw.line([(tip[0]+ux*r-uy*r*.55,tip[1]+uy*r+ux*r*.55),tip,
                           (tip[0]+ux*r+uy*r*.55,tip[1]+uy*r-ux*r*.55)],fill=RED,width=stroke)
    output = Image.alpha_composite(canvas.convert('RGBA'),layer).convert('RGB')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    target=OUTPUT/'annotated-reading.png'
    output.save(target)
    if target.stat().st_size > 10*1024*1024:
        target.unlink()
        raise ValueError('无损批注图超过 10 MB，请上传裁好的单页图片；原图不会被悄悄压缩')
    (OUTPUT/'annotation-receipt.json').write_text(json.dumps({
        'source_sha256':state['source_sha256'],'source_size':state['size'],
        'source_offset':[margin,pad],'marks':plan,'output':target.name},ensure_ascii=False),encoding='utf-8')
    print(json.dumps({'image':target.name,'source_preserved':True,'annotations':len(plan)},ensure_ascii=False))
    return target


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['scan','render'])
    parser.add_argument('image')
    parser.add_argument('--state')
    parser.add_argument('--plan')
    args=parser.parse_args()
    path=material(args.image)
    if args.action=='scan':
        scan(path)
    else:
        render(path,json.loads(material(args.state).read_text(encoding='utf-8')),json.loads(args.plan))


if __name__=='__main__':
    main()
