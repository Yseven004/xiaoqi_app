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


class BookMarkItDownTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
