"""Generate small, independent attachment regressions without production access.

Usage: python tool/generate_attachment_fixtures.py --output ../../tmp/attachment-fixtures
Requires the bundled reportlab, Pillow and pypdf libraries. No downloaded content.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader, PdfWriter
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas


def create_fixtures(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
    fixtures = []

    def record(name: str, **expected) -> None:
        path = output / name
        fixtures.append({
            "name": name,
            "path": str(path.resolve()),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": path.stat().st_size,
            **expected,
        })

    def native_page(pdf: canvas.Canvas, number: int) -> None:
        pdf.setFont("Helvetica", 22)
        pdf.drawString(54, 770, f"NATIVE_FIXTURE page {number}")
        pdf.setFont("Helvetica", 13)
        for index in range(10):
            pdf.drawString(54, 725 - index * 28, f"Independent sample paragraph {index + 1}; original page {number}.")
        pdf.setFont("STSong-Light", 16)
        pdf.drawString(54, 390, "附件解析回归：原生文字、中文与真实页码。")
        pdf.showPage()

    def scan_image(number: int) -> Image.Image:
        image = Image.new("RGB", (1240, 1754), "white")
        draw = ImageDraw.Draw(image)
        fonts = [
            Path("C:/Windows/Fonts/arial.ttf"),
            Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        ]
        font_path = next((font for font in fonts if font.exists()), None)
        font = ImageFont.truetype(str(font_path), 42) if font_path else ImageFont.load_default(size=42)
        draw.text((100, 150), f"SCAN_FIXTURE page {number}", fill="black", font=font)
        for index in range(10):
            draw.text((100, 260 + index * 90), f"Readable scanned line {index + 1}.", fill="black", font=font)
        return image

    def scanned_page(pdf: canvas.Canvas, number: int) -> None:
        image = scan_image(number)
        pdf.drawImage(ImageReader(image), 0, 0, width=A4[0], height=A4[1])
        pdf.showPage()

    native = output / "native.pdf"
    pdf = canvas.Canvas(str(native), pagesize=A4, invariant=1)
    for page in range(1, 4):
        native_page(pdf, page)
    pdf.save()
    record("native.pdf", kind="pdf", page_count=3, native_pages=[1, 2, 3], scan_pages=[], blank_pages=[], expected_tokens=["NATIVE_FIXTURE", "中文"], expected_status="ready")

    pdf = canvas.Canvas(str(output / "scan.pdf"), pagesize=A4, invariant=1)
    for page in range(1, 4):
        scanned_page(pdf, page)
    pdf.save()
    record("scan.pdf", kind="pdf", page_count=3, native_pages=[], scan_pages=[1, 2, 3], blank_pages=[], expected_tokens=["SCAN", "page"], expected_status="ready")

    pdf = canvas.Canvas(str(output / "mixed.pdf"), pagesize=A4, invariant=1)
    native_page(pdf, 1)
    pdf.showPage()
    scanned_page(pdf, 3)
    native_page(pdf, 4)
    pdf.save()
    record("mixed.pdf", kind="pdf", page_count=4, native_pages=[1, 4], scan_pages=[3], blank_pages=[2], expected_tokens=["NATIVE_FIXTURE", "SCAN"], expected_status="ready")

    pdf = canvas.Canvas(str(output / "blank.pdf"), pagesize=A4, invariant=1)
    pdf.showPage()
    pdf.showPage()
    pdf.save()
    record("blank.pdf", kind="pdf", page_count=2, native_pages=[], scan_pages=[], blank_pages=[1, 2], expected_status="failed", expected_error="no_readable_text")

    writer = PdfWriter()
    for page in PdfReader(native).pages:
        writer.add_page(page)
    writer.encrypt("attachment-fixture-password")
    with (output / "encrypted.pdf").open("wb") as stream:
        writer.write(stream)
    record("encrypted.pdf", kind="pdf", page_count=3, expected_status="failed", expected_error="invalid_or_encrypted_pdf")

    (output / "damaged.pdf").write_bytes(b"%PDF-1.4\nindependent intentionally damaged fixture\n%%EOF\n")
    record("damaged.pdf", kind="pdf", expected_status="failed", expected_error="invalid_or_encrypted_pdf")

    writer = PdfWriter()
    for _ in range(501):
        writer.add_blank_page(width=120, height=160)
    with (output / "over-page-limit.pdf").open("wb") as stream:
        writer.write(stream)
    record("over-page-limit.pdf", kind="pdf", page_count=501, expected_status="failed", expected_error="page_limit")

    image = scan_image(1)
    image.save(output / "image.png")
    record("image.png", kind="image", expected_status="ready")
    (output / "unicode.txt").write_text("附件解析回归\n中文 Unicode 文本\nIndependent fixture text.\n", encoding="utf-8")
    record("unicode.txt", kind="document", expected_status="uploaded", segments=[{"index": 0, "locator": "段落 1", "text": "附件解析回归\n中文 Unicode 文本\nIndependent fixture text."}])

    # Reopen generated PDFs to verify the structural expectations before shipping.
    for item in fixtures:
        if item["kind"] == "pdf" and "page_count" in item and item["name"] != "encrypted.pdf":
            assert len(PdfReader(item["path"]).pages) == item["page_count"], item["name"]
    manifest = {"schema": 1, "synthetic": True, "fixtures": fixtures}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    manifest = create_fixtures(arguments.output.resolve())
    print(json.dumps({"manifest": str((arguments.output / "manifest.json").resolve()), "count": len(manifest["fixtures"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
