import base64
import hashlib
import io
import unittest
import zipfile
from unittest.mock import patch

from evaluate import candidate_matches, check_file, check_pdf, ordinal


class SourceIndependentEvaluationTest(unittest.TestCase):
    def setUp(self):
        self.case = {
            "kind": "file", "title": ["示例书"], "author": ["甲"],
            "format": "epub", "language": ["中文"], "source": "https://example.org/original",
            "chapter_unit": "回", "chapters": 2, "exact_chapters": True, "check_epub_metadata": True,
        }
        self.card = {
            "title": "示例书", "author": "甲", "format": "epub", "edition": "中文原文",
            "language": "中文", "license": "Public domain", "sourceName": "新书源",
            "sourceUrl": "https://another.example/books/123",
        }
        self.text = "这里是每回各自独立的完整正文。" * 4

    def file(self, body, creator="甲"):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as book:
            book.writestr("mimetype", "application/epub+zip")
            book.writestr("META-INF/container.xml", '<container><rootfile full-path="book.opf"/></container>')
            book.writestr("book.opf", f"""<package>
                <metadata><title>示例书</title><creator>{creator}</creator></metadata>
                <manifest><item id="c" href="packed.xhtml"/></manifest>
                <spine><itemref idref="c"/></spine></package>""")
            book.writestr("packed.xhtml", "<html><body>" + body + "</body></html>")
        data = buf.getvalue()
        return {**self.card, "epubBase64": base64.b64encode(data), "sha256": hashlib.sha256(data).hexdigest()}

    def test_matching_file_on_unlisted_source(self):
        self.assertTrue(candidate_matches(self.card, self.case))
        body = f"<div>第一回　开篇</div><div>{self.text}第二回　　归来终章</div><div>{self.text}</div>"
        self.assertEqual(check_file(self.file(body), self.case)["chapters"], 2)
        self.assertEqual(ordinal("一○○"), 100)
        self.assertEqual(ordinal("一二零"), 120)

    def test_metadata_and_explicit_source(self):
        for change in ({"title": "示例书续集"}, {"author": "乙"}, {"language": "英文"}, {"license": ""}):
            self.assertFalse(candidate_matches({**self.card, **change}, self.case))
        self.assertFalse(candidate_matches(self.card, {**self.case, "required_source_host": "example.org"}))
        self.assertFalse(candidate_matches(self.card, {**self.case, "publisher": ["例社"]}))
        self.assertTrue(candidate_matches({**self.card, "publisher": "例社"}, {**self.case, "publisher": ["例社"]}))

    def test_incorrect_attribution(self):
        case = {**self.case, "author_attributions": [["甲", "A"], ["乙", "B"]]}
        body = f"<h1>第一回</h1><p>{self.text}</p><h1>第二回</h1><p>{self.text}</p>"
        self.assertEqual(check_file(self.file(body, "A"), case)["chapters"], 2)
        with self.assertRaisesRegex(ValueError, "epub_creator_mismatch"):
            check_file(self.file(body, "B"), case)
        with self.assertRaisesRegex(ValueError, "file_checksum_mismatch"):
            check_file({**self.file(body), "sha256": "0"*64}, self.case)

    def test_contents_only_or_partial_or_wrong_length(self):
        first = f"<h1>第一回</h1><p>{self.text}</p>"
        second = f"<h1>第二回</h1><p>{self.text}</p>"
        for body in (
            "<nav><p>第一回</p><p>第二回</p></nav>",
            "<p><a>第一回</a></p><p><a>第二回</a></p>",
            first + "<p>第二回中讲过了这些事情。</p>",
            first + "<h1>第二回</h1>",
        ):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "missing_chapter_text_"):
                check_file(self.file(body), self.case)
        with self.assertRaisesRegex(ValueError, "unexpected_extra_chapters"):
            check_file(self.file(first + second + f"<h1>第三回</h1><p>{self.text}</p>"), self.case)

    def test_printing_omitting_ordinal_prefix(self):
        first = f"<p>第一回　初会</p><p>{self.text}</p>"
        second = f"<p>二回     谈春秋胸罗锦绣　讲礼制口吐珠玑</p><p>{self.text}</p>"
        self.assertEqual(check_file(self.file(first + second), self.case)["chapters"], 2)
        prose = f"<p>二回提到了前面几个章节。</p><p>{self.text}</p>"
        with self.assertRaisesRegex(ValueError, "missing_chapter_text_2"):
            check_file(self.file(first + prose), self.case)

    def test_sampling_reads_body_in_packed_epub(self):
        case = {**self.case, "epub_text_terms": ["opening sentence", "ending sentence"]}
        case.pop("chapters")
        self.assertEqual(
            check_file(self.file("<p>opening sentence</p><p>ending sentence</p>"), case)["epub_text_check"],
            "matched",
        )
        with self.assertRaisesRegex(ValueError, "epub_body_sample_mismatch"):
            check_file(self.file("<p>opening sentence</p><h2>ending sentence</h2>"), case)


class PdfSamplingTest(unittest.TestCase):
    @patch("evaluate.shutil.which", side_effect=lambda name: name)
    @patch("evaluate.subprocess.check_output")
    def test_checks_page_floor_and_reads_both_ends(self, process, _which):
        case = {"pdf_min_pages": 120, "pdf_front_terms": ["Title"], "pdf_back_terms": ["Last chapter"]}
        process.side_effect = [b"Pages: 4\nEncrypted: no\n"]
        with self.assertRaisesRegex(ValueError, "pdf_page_count_below_full_reference"):
            check_pdf(b"%PDF-1.7", case)
        process.reset_mock()
        process.side_effect = [b"Pages: 150\nEncrypted: no\n", b"Title here", b"Wrong book"]
        with self.assertRaisesRegex(ValueError, "pdf_back_sample_mismatch"):
            check_pdf(b"%PDF-1.7", case)
        process.reset_mock()
        process.side_effect = [b"Pages: 150\nEncrypted: no\n", b"Title here", b"Last chapter and notes"]
        self.assertEqual(check_pdf(b"%PDF-1.7", case), {"pdf_pages": 150, "pdf_text_check": "matched"})
        self.assertEqual(process.call_args_list[1].args[0][1:5], ["-f", "1", "-l", "12"])
        self.assertEqual(process.call_args_list[2].args[0][1:5], ["-f", "127", "-l", "150"])


if __name__ == "__main__":
    unittest.main()
