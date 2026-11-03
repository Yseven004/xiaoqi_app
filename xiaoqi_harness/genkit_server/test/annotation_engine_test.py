import hashlib
import importlib.util
import json
import tempfile
import shutil
import unittest
from unittest.mock import patch
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT=Path(__file__).parent
spec=importlib.util.spec_from_file_location('annotate',ROOT.parent/'official_catalog/original-reading-annotations/skills/annotate/scripts/annotate.py')
a=importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


class Annotations(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.path=self.root/'source.png'
        Image.new('RGB',(640,480),(249,248,244)).save(self.path)
        a.MATERIALS=self.root
        a.OUTPUT=self.root/'output'
        a.FONT=str(ROOT.parent/'sandbox_image/fonts/LongCang-Regular.ttf')
        self.state={'schema':1,'source_sha256':hashlib.sha256(self.path.read_bytes()).hexdigest(),
                    'size':[640,480],'lines':[{'id':'L1','text':'盯着旧椅子。','box':[100,100,292,132],
                    'glyphs':[{'text':c,'box':[100+i*32,100,130+i*32,132],'confidence':99}
                              for i,c in enumerate('盯着旧椅子。')]}]}
        mock=patch.object(a,'scan',side_effect=lambda *args,**kwargs:json.loads(json.dumps(self.state)))
        mock.start()
        self.addCleanup(mock.stop)

    def test_hocr_uses_actual_character_boxes(self):
        p=a.GlyphParser()
        p.feed('<div><span class="ocr_line"><span class="ocrx_word"><span class="ocrx_cinfo" '
               'title="x_bboxes 12 19 43 51; x_conf 97.5">盯</span><span class="ocrx_cinfo" '
               'title="x_bboxes 48 20 77 52; x_conf 99">着</span></span></span></div>')
        self.assertEqual([g['box'] for g in p.lines[0]['glyphs']],[[12,19,43,51],[48,20,77,52]])

    def test_rejects_ambiguous_low_confidence_or_partial_glyphs(self):
        mark={'kind':'triangle','line':'L1','quote':'盯着'}
        a.resolve(self.state,mark)
        self.state['lines'][0]['glyphs'][0]['confidence']=79
        with self.assertRaises(ValueError): a.resolve(self.state,mark)
        self.state['lines'][0]['text']='盯着盯着'
        with self.assertRaises(ValueError): a.resolve(self.state,mark)

    def test_rejects_cross_source_state(self):
        self.state['source_sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'不属于'):
            a.render(self.path,self.state,[{'kind':'underline','line':'L1','quote':'盯着'}])

    def test_rejects_forged_glyph_coordinates_even_with_correct_source_hash(self):
        actual=json.loads(json.dumps(self.state))
        self.state['lines'][0]['glyphs'][0]['box']=[0,0,20,20]
        with patch.object(a,'scan',return_value=actual):
            with self.assertRaisesRegex(ValueError,'字框'):
                a.render(self.path,self.state,[{'kind':'triangle','line':'L1','quote':'盯着'}])

    def test_triangle_uses_exact_glyphs_and_source_pixels_stay_unchanged(self):
        target=a.render(self.path,self.state,[{'kind':'triangle','line':'L1','quote':'盯着'}])
        receipt=json.loads((a.OUTPUT/'annotation-receipt.json').read_text(encoding='utf-8'))
        ox,oy=receipt['source_offset']
        with Image.open(target) as result,Image.open(self.path) as original:
            crop=result.crop((ox,oy,ox+640,oy+480))
            difference=ImageChops.difference(crop,original)
            changed=difference.getbbox()
            self.assertIsNotNone(changed)
            self.assertGreaterEqual(changed[0],100)
            self.assertLessEqual(changed[2],162)
            self.assertGreater(changed[1],132)
            self.assertLess(changed[3],148)
            self.assertIsNone(ImageChops.difference(crop.crop((0,0,640,132)),original.crop((0,0,640,132))).getbbox())

    def test_rejects_marks_that_would_hit_next_line(self):
        self.state['lines'].append({'id':'L2','text':'下一行','box':[100,137,290,169],
                                   'glyphs':[{'text':'下','box':[100,137,130,169],'confidence':99}]})
        with self.assertRaisesRegex(ValueError,'行间距'):
            a.render(self.path,self.state,[{'kind':'double','line':'L1','quote':'盯着'}])

    def test_original_materials_boundary(self):
        with self.assertRaises(ValueError): a.material(str(self.root.parent/'outside.png'))

    def test_comments_reuse_only_blank_strips_not_original_artwork(self):
        plan=[{'kind':'triangle','line':'L1','quote':'盯着','comment':'关键词：细节描写'}]
        a.render(self.path,self.state,plan)
        blank=json.loads((a.OUTPUT/'annotation-receipt.json').read_text(encoding='utf-8'))['source_offset'][0]
        with Image.open(self.path) as source:
            changed=source.copy()
        changed.putpixel((0,0),(0,0,0))
        changed.save(self.path)
        self.state['source_sha256']=hashlib.sha256(self.path.read_bytes()).hexdigest()
        a.render(self.path,self.state,plan)
        artwork=json.loads((a.OUTPUT/'annotation-receipt.json').read_text(encoding='utf-8'))['source_offset'][0]
        self.assertGreater(artwork,blank)

    @unittest.skipUnless(shutil.which('tesseract'), 'real OCR runs in the built Linux sandbox image')
    def test_real_chinese_ocr_and_original_pixel_overlay(self):
        patch.stopall()
        image=Image.new('RGB',(1000,600),'white')
        font=ImageFont.truetype('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',42)
        draw=ImageDraw.Draw(image)
        for i,text in enumerate(['主动回忆','先回忆，再核对。','合上资料，用自己的话回答。','记录遗漏，安排下一次复习。']):
            draw.text((100,60+i*100),text,font=font,fill='black')
        image.save(self.path)
        before=self.path.read_bytes()
        state=a.scan(self.path)
        line=next(line for line in state['lines'] if '回忆' in line['text'])
        plan=[{'kind':'triangle','line':line['id'],'quote':'回忆','comment':'关键词：先尝试提取知识'}]
        target=a.render(self.path,state,plan)
        self.assertEqual(before,self.path.read_bytes())
        receipt=json.loads((a.OUTPUT/'annotation-receipt.json').read_text(encoding='utf-8'))
        ox,oy=receipt['source_offset']
        _,glyphs,_=a.resolve(state,plan[0])
        box=a.union([g['box'] for g in glyphs])
        with Image.open(target) as output:
            crop=output.crop((ox,oy,ox+image.width,oy+image.height))
            text_area=a.union([g['box'] for line in state['lines'] for g in line['glyphs']])
            changed=ImageChops.difference(crop.crop(text_area),image.crop(text_area)).getbbox()
            self.assertIsNotNone(changed)
            for line in state['lines']:
                for glyph in line['glyphs']:
                    self.assertIsNone(ImageChops.difference(crop.crop(glyph['box']),image.crop(glyph['box'])).getbbox())


if __name__=='__main__':
    unittest.main()
