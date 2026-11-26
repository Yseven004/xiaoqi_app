from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile


WORKER_PATH = Path(__file__).resolve().parents[1] / "bin" / "book_markitdown.py"
spec = importlib.util.spec_from_file_location("book_markitdown", WORKER_PATH)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def write_pdf(path, texts):
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Count {len(texts)} /Kids [{''.join(f'{4+i*2} 0 R ' for i in range(len(texts)))}] >>".encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for index, text in enumerate(texts):
        content = (
            f"BT /F1 12 Tf 40 700 Td ({text}) Tj ET".encode()
            if text
            else b"0.5 0.5 0.5 rg 40 600 200 100 re f"
        )
        objects.extend(
            [
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                f"/Resources << /Font << /F1 3 0 R >> >> /Contents {5+index*2} 0 R >>".encode(),
                f"<< /Length {len(content)} >>\nstream\n".encode()
                + content
                + b"\nendstream",
            ]
        )
    body = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(body))
        body.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    start_xref = len(body)
    body.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        body.extend(f"{offset:010d} 00000 n \n".encode())
    body.extend(
        f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start_xref}\n%%EOF\n".encode()
    )
    path.write_bytes(body)


def write_epub(path, chapter_bodies):
    names = [f"chapter {index + 1}.xhtml" for index in range(len(chapter_bodies))]
    manifest = "".join(
        f'<item id="c{index}" href="{name.replace(" ", "%20")}" media-type="application/xhtml+xml"/>'
        for index, name in enumerate(names)
    )
    spine = "".join(f'<itemref idref="c{index}"/>' for index in range(len(names)))
    with ZipFile(path, "w") as epub:
        epub.writestr("mimetype", "application/epub+zip")
        epub.writestr(
            "META-INF/container.xml",
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        epub.writestr(
            "OEBPS/content.opf",
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<metadata><dc:title>Only metadata</dc:title></metadata>'
            f"<manifest>{manifest}</manifest><spine>{spine}</spine></package>",
        )
        for name, body in reversed(list(zip(names, chapter_bodies))):
            epub.writestr(
                f"OEBPS/{name}",
                '<html xmlns="http://www.w3.org/1999/xhtml">'
                f"<head><title>Document</title></head><body>{body}</body></html>",
            )


def write_docx(path):
    with ZipFile(path, "w") as docx:
        docx.writestr(
            "[Content_Types].xml",
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            "</Types>",
        )
        docx.writestr(
            "_rels/.rels",
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="word/document.xml"/></Relationships>',
        )
        docx.writestr(
            "word/document.xml",
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            "<w:body><w:p><w:r><w:t>Word 正文</w:t></w:r>"
            "<w:r><w:rPr><w:b/></w:rPr><w:t>加粗片段</w:t></w:r>"
            "</w:p></w:body></w:document>",
        )


class BookMarkItDownTests(unittest.TestCase):
    def test_native_diagnostics_are_excluded_from_worker_protocol(self):
        probe = subprocess.run(
            [
                sys.executable,
                "-c",
                "import os, runpy, sys\n"
                "worker = runpy.run_path(sys.argv[1])\n"
                "with worker['silence_parser_output']():\n"
                "    os.write(1, b'raw stdout')\n"
                "    os.write(2, b'raw stderr')\n"
                "print('result')\n",
                str(WORKER_PATH),
            ],
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(probe.stdout.strip(), "result")
        self.assertEqual(probe.stderr, "")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "result.jsonl"

    def invoke(self, path, format):
        return subprocess.run(
            [sys.executable, WORKER_PATH, path, format, self.output],
            encoding="utf-8",
            capture_output=True,
            timeout=20,
        )

    def units(self):
        return [
            json.loads(line)
            for line in self.output.read_text(encoding="utf-8").splitlines()
        ]

    def invoke_interactive(self, path, format, commands):
        return subprocess.run(
            [sys.executable, WORKER_PATH, path, format, "--interactive"],
            input="".join(json.dumps(command) + "\n" for command in commands),
            encoding="utf-8",
            capture_output=True,
            timeout=20,
        )

    def test_interactive_epub_yields_requested_spine_units_in_order(self):
        source = self.root / "sample.epub"
        write_epub(
            source,
            [
                "<h1>先读</h1><p>正文甲</p>",
                '<p><img src="cover.jpg" alt="封面"/></p>',
                "<h1>跳到</h1><p>正文丙</p>",
            ],
        )
        result = self.invoke_interactive(source, "epub", [{"ids": [3]}, {"ids": [1, 2]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog, late, end, early, empty, second_end = [
            json.loads(line) for line in result.stdout.splitlines()
        ]
        self.assertEqual(catalog["type"], "catalog")
        self.assertEqual([unit["id"] for unit in catalog["units"]], [1, 2, 3])
        self.assertEqual(catalog["units"][2]["item_id"], "c2")
        self.assertEqual(catalog["units"][2]["href"], "OEBPS/chapter 3.xhtml")
        self.assertEqual(late["id"], 3)
        self.assertEqual(late["status"], "ready")
        self.assertIn("正文丙", late["markdown"])
        self.assertIn("跳到", late["locator"])
        self.assertEqual(early["id"], 1)
        self.assertIn("正文甲", early["markdown"])
        self.assertEqual(empty["status"], "no_text")
        self.assertNotIn("markdown", empty)
        self.assertEqual(end, second_end)
        self.assertEqual(end, {"type": "batch_done"})
        self.assertFalse(self.output.exists())

    def test_interactive_pdf_preserves_outline_and_original_page_numbers(self):
        from pypdf import PdfReader, PdfWriter

        raw = self.root / "raw.pdf"
        write_pdf(raw, ["Chapter one", "", "Chapter two"])
        source = self.root / "outlined.pdf"
        writer = PdfWriter(clone_from=PdfReader(raw))
        writer.add_outline_item(title="Foreword", page_number=0)
        writer.add_outline_item(title="Chapter Two", page_number=2)
        writer.write(source)
        result = self.invoke_interactive(source, "pdf", [{"ids": [3, 2]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog, late, blank, end = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(catalog["units"][2]["page"], 3)
        self.assertEqual(
            catalog["sections"],
            [
                {"title": "Foreword", "start": 1, "end": 2},
                {"title": "Chapter Two", "start": 3, "end": 3},
            ],
        )
        self.assertEqual(late["locator"], "PDF 第 3 页")
        self.assertEqual(late["markdown"], "Chapter two")
        self.assertEqual(blank["status"], "no_text")
        self.assertEqual(end["type"], "batch_done")

    def test_interactive_rejects_invalid_batch_after_publishing_prior_unit(self):
        source = self.root / "sample.epub"
        write_epub(source, ["<p>已完成</p>"])
        result = self.invoke_interactive(source, "epub", [{"ids": [1]}, {"ids": [True]}])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr.strip(), "invalid_book")
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([record["type"] for record in records], ["catalog", "unit", "batch_done"])
        self.assertEqual(records[1]["markdown"], "已完成")

    def test_pdf_retains_physical_pages_and_skips_nontext(self):
        source = self.root / "sample.pdf"
        write_pdf(source, ["Early sample", "", "Late chapter answer"])
        conversion = self.invoke(source, "pdf")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertEqual(
            json.loads(conversion.stdout),
            {"page_count": 3, "skipped_pages": 1, "has_text": True},
        )
        first, late = self.units()
        self.assertEqual(first["locator"], "PDF 第 1 页")
        self.assertEqual(late["locator"], "PDF 第 3 页")
        self.assertIn("Late chapter answer", late["markdown"])

    def test_image_only_pdf_returns_no_text(self):
        source = self.root / "only-images.pdf"
        write_pdf(source, ["", ""])
        conversion = self.invoke(source, "pdf")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertEqual(
            json.loads(conversion.stdout),
            {"page_count": 2, "skipped_pages": 2, "has_text": False},
        )
        self.assertEqual(self.units(), [])

    def test_epub_uses_spine_order_and_preserves_markdown(self):
        source = self.root / "sample.epub"
        write_epub(
            source,
            [
                "<h1>前言</h1><p>早期正文</p>",
                "<h1>后段</h1><p>答案在<strong>后段</strong>。</p>"
                "<table><tr><th>字段</th></tr><tr><td>样本</td></tr></table>",
            ],
        )
        conversion = self.invoke(source, "epub")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertEqual(
            json.loads(conversion.stdout),
            {"page_count": None, "skipped_pages": 0, "has_text": True},
        )
        first, late = self.units()
        self.assertIn("前言", first["locator"])
        self.assertIn("后段", late["locator"])
        self.assertIn("**后段**", late["markdown"])
        self.assertIn("| 样本 |", late["markdown"])

    def test_epub_cover_and_metadata_do_not_count_as_body(self):
        source = self.root / "only-cover.epub"
        write_epub(source, ['<p><img src="cover.jpg" alt="封面"/></p>'])
        conversion = self.invoke(source, "epub")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertFalse(json.loads(conversion.stdout)["has_text"])
        self.assertEqual(self.units(), [])

    def test_size_limit_does_not_publish_partial_output(self):
        source = self.root / "sample.epub"
        write_epub(source, ["<h1>前言</h1><p>早期正文</p>", "<p>很长的正文</p>"])
        with patch.object(worker, "MAX_MARKDOWN_BYTES", 25):
            with self.assertRaises(worker.BookLimit):
                worker.convert_book(source, "epub", self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".book-markitdown-*")), [])

    def test_unreadable_file_is_not_treated_as_a_book(self):
        source = self.root / "bad.epub"
        source.write_text("not an EPUB", encoding="utf-8")
        conversion = self.invoke(source, "epub")
        self.assertEqual(conversion.returncode, 2)
        self.assertEqual(conversion.stderr.strip(), "invalid_book")
        self.assertFalse(self.output.exists())


    def test_docx_uses_official_markdown_formatting(self):
        source = self.root / "sample.docx"
        write_docx(source)
        conversion = self.invoke(source, "docx")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertEqual(
            json.loads(conversion.stdout),
            {"page_count": None, "skipped_pages": 0, "has_text": True},
        )
        markdown = self.units()[0]["markdown"]
        self.assertIn("Word 正文", markdown)
        self.assertIn("**加粗片段**", markdown)

    def test_pptx_preserves_slide_markers_and_titles(self):
        from pptx import Presentation

        source = self.root / "sample.pptx"
        deck = Presentation()
        for title, body in [("起始幻灯片", "早期正文"), ("后段幻灯片", "后段答案")]:
            slide = deck.slides.add_slide(deck.slide_layouts[1])
            slide.shapes.title.text = title
            slide.placeholders[1].text = body
        deck.save(source)
        conversion = self.invoke(source, "pptx")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        markdown = self.units()[0]["markdown"]
        self.assertIn("<!-- Slide number: 1 -->", markdown)
        self.assertIn("# 起始幻灯片", markdown)
        self.assertIn("<!-- Slide number: 2 -->", markdown)
        self.assertIn("# 后段幻灯片", markdown)
        self.assertIn("后段答案", markdown)

    def test_empty_pptx_markers_do_not_count_as_body(self):
        from pptx import Presentation

        source = self.root / "no-body.pptx"
        deck = Presentation()
        deck.slides.add_slide(deck.slide_layouts[6])
        deck.save(source)
        conversion = self.invoke(source, "pptx")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        self.assertFalse(json.loads(conversion.stdout)["has_text"])
        self.assertEqual(self.units(), [])

    def test_xlsx_preserves_named_sheets_and_table_cells(self):
        from openpyxl import Workbook

        source = self.root / "sample.xlsx"
        workbook = Workbook()
        workbook.active.title = "首表"
        workbook.active.append(["首字段", "数值"])
        workbook.active.append(["样本", 22])
        last = workbook.create_sheet("后表")
        last.append(["后字段", "数值"])
        last.append(["末尾样本", 42])
        workbook.save(source)
        conversion = self.invoke(source, "xlsx")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        markdown = self.units()[0]["markdown"]
        self.assertLess(markdown.index("## 首表"), markdown.index("## 后表"))
        self.assertIn("| 末尾样本 | 42 |", markdown)

    def test_plain_text_and_markdown_keep_unicode_and_source_text(self):
        for format, original, encoding in [
            ("txt", "普通文本\n下一行中文", "utf-8"),
            ("txt", "带 BOM 的中文", "utf-16"),
            ("md", "# 原有标题\n\n保留**加粗**和 [链接](https://example.invalid)", "utf-8"),
        ]:
            with self.subTest(format=format, encoding=encoding):
                source = self.root / f"sample.{format}"
                source.write_text(original, encoding=encoding, newline="\n")
                conversion = self.invoke(source, format)
                self.assertEqual(conversion.returncode, 0, conversion.stderr)
                self.assertEqual(self.units()[0]["markdown"], original + "\n\n")

    def test_html_preserves_links_and_strips_script_and_external_images(self):
        source = self.root / "sample.html"
        source.write_text(
            "<html><body><h1>HTML 正文</h1>"
            '<p><a href="https://example.invalid/article">示例</a>'
            '<img src="https://example.invalid/remote.png" alt="图片"/></p>'
            "<script>Do not keep this script.</script></body></html>",
            encoding="utf-8",
        )
        conversion = self.invoke(source, "html")
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        markdown = self.units()[0]["markdown"]
        self.assertIn("# HTML 正文", markdown)
        self.assertIn("[示例](https://example.invalid/article)", markdown)
        self.assertNotIn("remote.png", markdown)
        self.assertNotIn("Do not keep this script", markdown)

    def test_office_rejects_missing_package_markers_and_archive_over_limit(self):
        not_office = self.root / "other.docx"
        with ZipFile(not_office, "w") as archive:
            archive.writestr("unrelated.xml", "<other/>")
        conversion = self.invoke(not_office, "docx")
        self.assertEqual(conversion.returncode, 2)
        self.assertFalse(self.output.exists())
        source = self.root / "sample.docx"
        write_docx(source)
        with patch.object(worker, "MAX_OFFICE_EXPANDED_BYTES", 25):
            with self.assertRaises(worker.BookLimit):
                worker.convert_book(source, "docx", self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
