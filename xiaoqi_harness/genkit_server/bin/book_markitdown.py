#!/usr/bin/env python3
"""Convert uploaded books and attachments using MarkItDown's local converters."""
from __future__ import annotations

import argparse
import codecs
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import posixpath
import re
import sys
import tempfile
from urllib.parse import unquote, urlsplit
from zipfile import BadZipFile, ZipFile


MIB = 1024 * 1024
MAX_INPUT_BYTES = 256 * MIB
MAX_DOCUMENT_BYTES = 50 * MIB
MAX_MARKDOWN_BYTES = 50 * MIB
MAX_OUTPUT_BYTES = 64 * MIB
MAX_ARCHIVE_ENTRIES = 10_000
MAX_OFFICE_EXPANDED_BYTES = 250 * MIB
MAX_EPUB_EXPANDED_BYTES = 512 * MIB
MAX_EPUB_ENTRY_BYTES = 32 * MIB
MAX_PDF_PAGES = 2000
MAX_UNIT_CHARS = 60_000
MAX_BATCH_UNITS = 16
MAX_COMMAND_BYTES = 4096
EPUB_TEXT_TYPES = {"application/xhtml+xml", "text/html", "image/svg+xml"}
EPUB_TEXT_EXTENSIONS = {".xhtml", ".html", ".htm", ".svg"}
DOCUMENT_MIME_TYPES = {
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "txt": "text/plain",
    "md": "text/markdown",
    "html": "text/html",
}
OFFICE_FORMATS = {"docx", "pptx", "xlsx"}


class InvalidBook(Exception):
    pass


class BookLimit(Exception):
    pass


class MarkdownOutput:
    def __init__(self, stream):
        self.stream = stream
        self.markdown_bytes = 0
        self.output_bytes = 0

    def add(self, locator, markdown):
        markdown += "\n\n"
        for start in range(0, len(markdown), MAX_UNIT_CHARS):
            text = markdown[start : start + MAX_UNIT_CHARS]
            line = (
                json.dumps(
                    {"locator": locator, "markdown": text},
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
                + b"\n"
            )
            self.markdown_bytes += len(text.encode("utf-8"))
            self.output_bytes += len(line)
            if (
                self.markdown_bytes > MAX_MARKDOWN_BYTES
                or self.output_bytes > MAX_OUTPUT_BYTES
            ):
                raise BookLimit()
            self.stream.write(line)


class BoundedPdfPage(io.BytesIO):
    def write(self, data):
        if self.tell() + len(data) > MAX_INPUT_BYTES:
            raise BookLimit()
        return super().write(data)


@contextmanager
def open_pdf(input_path):
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError

    try:
        with input_path.open("rb") as original:
            if b"%PDF-" not in original.read(1024):
                raise InvalidBook()
            original.seek(0)
            pdf = PdfReader(original)
            if pdf.is_encrypted:
                raise InvalidBook()
            page_count = len(pdf.pages)
            if page_count > MAX_PDF_PAGES:
                raise BookLimit()
            yield pdf, page_count
    except PdfReadError as error:
        raise InvalidBook() from error


def pdf_page_converter():
    from markitdown import StreamInfo
    from markitdown.converters import PdfConverter
    from pypdf import PdfWriter

    converter = PdfConverter()
    stream_info = StreamInfo(extension=".pdf", mimetype="application/pdf")

    def convert(page):
        with BoundedPdfPage() as page_file:
            writer = PdfWriter()
            writer.add_page(page, excluded_keys=("/Annots", "/B"))
            writer.write(page_file)
            page_file.seek(0)
            markdown = converter.convert(page_file, stream_info).markdown
        return markdown.replace("\x00", "").strip()

    return convert


def convert_pdf(input_path, output):
    convert_page = pdf_page_converter()
    with open_pdf(input_path) as (pdf, page_count):
        skipped = 0
        for page_number, page in enumerate(pdf.pages, 1):
            markdown = convert_page(page)
            if not markdown:
                skipped += 1
                continue
            locator = f"PDF 第 {page_number} 页"
            output.add(locator, f"## {locator}\n\n{markdown}")
        return page_count, skipped


def open_epub_member(archive, name):
    try:
        member = archive.getinfo(name)
    except KeyError as error:
        raise InvalidBook() from error
    if member.is_dir() or (member.flag_bits & 1):
        raise InvalidBook()
    return archive.open(member)


def check_archive(archive, max_expanded_bytes, max_entry_bytes):
    entries = archive.infolist()
    if (
        len(entries) > MAX_ARCHIVE_ENTRIES
        or sum(item.file_size for item in entries) > max_expanded_bytes
        or any(item.file_size > max_entry_bytes for item in entries)
    ):
        raise BookLimit()
    names = {entry.filename for entry in entries}
    if len(names) != len(entries):
        raise InvalidBook()
    return names


def resolve_epub_member(archive, package_dir, href):
    try:
        reference = urlsplit(href)
    except ValueError as error:
        raise InvalidBook() from error
    if reference.scheme or reference.netloc or not reference.path:
        raise InvalidBook()
    for value in (unquote(reference.path), reference.path):
        path = posixpath.normpath(posixpath.join(package_dir, value))
        if path.startswith(("/", "../")) or path in (".", "..") or "\\" in path:
            continue
        try:
            archive.getinfo(path)
        except KeyError:
            continue
        return path
    raise InvalidBook()


def epub_spine_document(manifest, item_id):
    visited = set()
    while item_id and item_id not in visited:
        visited.add(item_id)
        node = manifest.get(item_id)
        if node is None:
            break
        href = node.get("href", "")
        mime_type = node.get("media-type", "").lower()
        path = href.split("#", 1)[0].split("?", 1)[0]
        if mime_type in EPUB_TEXT_TYPES or Path(path).suffix.lower() in EPUB_TEXT_EXTENSIONS:
            return href
        item_id = node.get("fallback", "")
    # Some fixed-layout books put images directly in the spine.
    return None


@contextmanager
def open_epub(input_path):
    from defusedxml.ElementTree import parse
    from defusedxml.common import DefusedXmlException
    from xml.etree.ElementTree import ParseError

    try:
        with ZipFile(input_path) as archive:
            check_archive(archive, MAX_EPUB_EXPANDED_BYTES, MAX_EPUB_ENTRY_BYTES)
            with open_epub_member(archive, "META-INF/container.xml") as container:
                rootfile = parse(container).find(".//{*}rootfile")
            if rootfile is None:
                raise InvalidBook()
            package = resolve_epub_member(archive, "", rootfile.get("full-path", ""))
            with open_epub_member(archive, package) as opf:
                book = parse(opf)
            manifest = {
                item.get("id", ""): item
                for item in book.findall("{*}manifest/{*}item")
            }
            spine = book.findall("{*}spine/{*}itemref")
            if not spine:
                raise InvalidBook()
            if len(spine) > MAX_ARCHIVE_ENTRIES:
                raise BookLimit()
            units = []
            for number, item in enumerate(spine, 1):
                item_id = item.get("idref", "")
                if item_id not in manifest:
                    raise InvalidBook()
                unit = {
                    "id": number,
                    "item_id": item_id,
                    "locator": f"EPUB 第 {number} 节",
                }
                reference = epub_spine_document(manifest, item_id)
                if reference is not None:
                    unit["href"] = resolve_epub_member(
                        archive, posixpath.dirname(package), reference
                    )
                units.append(unit)
            yield archive, units
    except (BadZipFile, DefusedXmlException, ParseError) as error:
        raise InvalidBook() from error


def epub_unit_converter(archive):
    from markitdown import StreamInfo
    from markitdown.converters import HtmlConverter

    converter = HtmlConverter()
    stream_info = StreamInfo(mimetype="application/xhtml+xml", extension=".xhtml")

    def convert(unit):
        locator = unit["locator"]
        if "href" not in unit:
            return locator, ""
        with open_epub_member(archive, unit["href"]) as chapter:
            converted = converter.convert(
                chapter, stream_info, strip=["img", "head", "style", "script"]
            )
        markdown = converted.markdown.replace("\x00", "").strip()
        if markdown:
            heading = re.match(r"^#{1,6}[ \t]+([^\r\n]+)", markdown)
            title = heading[1] if heading else converted.title
            if title:
                clean_title = " ".join(str(title).split())[:100]
                if clean_title:
                    locator += f" · {clean_title}"
        return locator, markdown

    return convert


def convert_epub(input_path, output):
    with open_epub(input_path) as (archive, units):
        convert_unit = epub_unit_converter(archive)
        for unit in units:
            locator, markdown = convert_unit(unit)
            if markdown:
                output.add(locator, markdown)
    return None, 0


def convert_document(input_path, format, output):
    from markitdown import StreamInfo
    from markitdown.converters import (
        DocxConverter,
        HtmlConverter,
        PlainTextConverter,
        PptxConverter,
        XlsxConverter,
    )

    converter_type = {
        "docx": DocxConverter,
        "pptx": PptxConverter,
        "xlsx": XlsxConverter,
        "txt": PlainTextConverter,
        "md": PlainTextConverter,
        "html": HtmlConverter,
    }[format]
    with input_path.open("rb") as source:
        try:
            if format in OFFICE_FORMATS:
                with ZipFile(source) as archive:
                    names = check_archive(
                        archive, MAX_OFFICE_EXPANDED_BYTES, MAX_OFFICE_EXPANDED_BYTES
                    )
                    if not {"[Content_Types].xml", "_rels/.rels"} <= names:
                        raise InvalidBook()
                source.seek(0)
            converter = converter_type()
            stream_info = StreamInfo(
                extension=f".{format}", mimetype=DOCUMENT_MIME_TYPES[format]
            )
            if format in ("txt", "md"):
                result = convert_plain_text(converter, source, stream_info)
            else:
                result = converter.convert(
                    source, stream_info, strip=["img", "head", "style", "script"]
                )
        except BadZipFile as error:
            raise InvalidBook() from error
    markdown = result.markdown.replace("\x00", "")
    if format == "pptx":
        # Official slide markers are kept for references; a deck with only
        # those markers does not have any body text.
        body = re.sub(r"^<!-- Slide number: [0-9]+ -->$", "", markdown, flags=re.M)
        if not body.strip():
            return None, 0
    if markdown.strip():
        output.add(f"{format.upper()} 正文", markdown)
    return None, 0


def convert_plain_text(converter, source, stream_info):
    from markitdown import StreamInfo

    # Short valid Chinese UTF-8 samples can look like a different encoding
    # to a statistical detector. Prefer verified UTF-8 or an explicit BOM.
    prefix = source.read(4)
    source.seek(0)
    if prefix.startswith((codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE)):
        encoding = "utf-32"
    elif prefix.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        encoding = "utf-16"
    elif prefix.startswith(codecs.BOM_UTF8):
        encoding = "utf-8-sig"
    else:
        encoding = "utf-8"
    try:
        return converter.convert(
            source, stream_info.copy_and_update(StreamInfo(charset=encoding))
        )
    except UnicodeDecodeError:
        if encoding != "utf-8":
            raise InvalidBook()
        source.seek(0)
        return converter.convert(source, stream_info)


def validate_input(input_path, format):
    if not input_path.is_file():
        raise InvalidBook()
    size = input_path.stat().st_size
    if not size:
        raise InvalidBook()
    max_input = MAX_INPUT_BYTES if format in ("pdf", "epub") else MAX_DOCUMENT_BYTES
    if size > max_input:
        raise BookLimit()


def convert_book(input_path, format, output_path):
    validate_input(input_path, format)
    if input_path.resolve() == output_path.resolve():
        raise InvalidBook()
    # Publish the result only after all readable chapters or pages converted.
    descriptor, path = tempfile.mkstemp(prefix=".book-markitdown-", dir=output_path.parent)
    temporary = Path(path)
    try:
        with os.fdopen(descriptor, "wb") as result:
            output = MarkdownOutput(result)
            if format == "pdf":
                page_count, skipped = convert_pdf(input_path, output)
            elif format == "epub":
                page_count, skipped = convert_epub(input_path, output)
            elif format in DOCUMENT_MIME_TYPES:
                page_count, skipped = convert_document(input_path, format, output)
            else:
                raise InvalidBook()
        temporary.replace(output_path)
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "page_count": page_count,
        "skipped_pages": skipped,
        "has_text": output.markdown_bytes > 0,
    }


def limit_worker_memory():
    if os.name == "posix":
        import resource

        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
        limit = 1024 * MIB
        if soft != resource.RLIM_INFINITY:
            limit = min(soft, limit)
        resource.setrlimit(resource.RLIMIT_AS, (limit, hard))


@contextmanager
def silence_parser_output():
    # Native dependencies can write directly to stdout and stderr. Keep
    # those diagnostics out of the worker protocol as well as Python logs.
    with open(os.devnull, "w") as quiet:
        original_stdout = os.dup(1)
        original_stderr = os.dup(2)
        try:
            os.dup2(quiet.fileno(), 1)
            os.dup2(quiet.fileno(), 2)
            with redirect_stdout(quiet), redirect_stderr(quiet):
                yield
        finally:
            os.dup2(original_stdout, 1)
            os.dup2(original_stderr, 2)
            os.close(original_stdout)
            os.close(original_stderr)


def pdf_sections(pdf, page_count):
    from pypdf.errors import PdfReadError

    try:
        # Nested entries belong to their top-level chapter. An ambiguous
        # outline falls back to prioritizing the current physical page.
        entries = [item for item in pdf.outline if not isinstance(item, list)]
        starts = [pdf.get_destination_page_number(item) + 1 for item in entries]
        if not starts or starts[0] < 1 or starts[-1] > page_count:
            return []
        if any(left >= right for left, right in zip(starts, starts[1:])):
            return []
        return [
            {"title": entry.title[:100], "start": start, "end": end - 1}
            for entry, start, end in zip(entries, starts, [*starts[1:], page_count + 1])
        ]
    except (AttributeError, KeyError, TypeError, ValueError, RecursionError, PdfReadError):
        return []


@contextmanager
def open_interactive_book(input_path, format):
    if format == "epub":
        with open_epub(input_path) as (archive, units):
            yield units, [], epub_unit_converter(archive)
    elif format == "pdf":
        with open_pdf(input_path) as (pdf, page_count):
            convert_page = pdf_page_converter()
            units = [
                {"id": page, "page": page, "locator": f"PDF 第 {page} 页"}
                for page in range(1, page_count + 1)
            ]

            def convert(unit):
                return unit["locator"], convert_page(pdf.pages[unit["page"] - 1])

            yield units, pdf_sections(pdf, page_count), convert
    else:
        raise InvalidBook()


def read_batch(source, unit_count):
    line = source.readline(MAX_COMMAND_BYTES + 1)
    if not line:
        return None
    if len(line) > MAX_COMMAND_BYTES or not line.endswith(b"\n"):
        raise InvalidBook()
    try:
        command = json.loads(line)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise InvalidBook() from error
    if not isinstance(command, dict) or command.keys() != {"ids"}:
        raise InvalidBook()
    ids = command["ids"]
    if not isinstance(ids, list) or not 1 <= len(ids) <= MAX_BATCH_UNITS:
        raise InvalidBook()
    if any(type(value) is not int or not 1 <= value <= unit_count for value in ids):
        raise InvalidBook()
    if len(ids) != len(set(ids)):
        raise InvalidBook()
    return ids


def run_interactive(input_path, format):
    validate_input(input_path, format)
    # Duplicate the protocol descriptor so native parser output can stay
    # redirected even while results are streamed to the coordinator.
    source = sys.stdin.buffer
    with os.fdopen(os.dup(1), "wb") as response, silence_parser_output():
        def emit(record):
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8", errors="replace"
            )
            if len(line) + 1 > MAX_OUTPUT_BYTES:
                raise BookLimit()
            response.write(line + b"\n")
            response.flush()

        with open_interactive_book(input_path, format) as (units, sections, convert):
            emit({"type": "catalog", "units": units, "sections": sections})
            sizes = {}
            total_bytes = 0
            while (ids := read_batch(source, len(units))) is not None:
                for unit_id in ids:
                    unit = units[unit_id - 1]
                    try:
                        locator, markdown = convert(unit)
                    except (BookLimit, MemoryError):
                        raise
                    except Exception:
                        # Keep diagnostics private and allow the remaining
                        # units in this book to complete independently.
                        emit(
                            {
                                "type": "unit",
                                "id": unit_id,
                                "locator": unit["locator"],
                                "status": "failed",
                            }
                        )
                        continue
                    text_size = len(markdown.encode("utf-8", errors="replace"))
                    total_bytes += text_size - sizes.get(unit_id, 0)
                    if total_bytes > MAX_MARKDOWN_BYTES:
                        raise BookLimit()
                    sizes[unit_id] = text_size
                    result = {
                        "type": "unit",
                        "id": unit_id,
                        "locator": locator,
                        "status": "ready" if markdown else "no_text",
                    }
                    if markdown:
                        result["markdown"] = markdown
                    emit(result)
                emit({"type": "batch_done"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_path", type=Path)
    parser.add_argument("format", choices=("pdf", "epub", *DOCUMENT_MIME_TYPES))
    parser.add_argument("output_path", type=Path, nargs="?")
    parser.add_argument("--interactive", action="store_true")
    args = parser.parse_args()
    if args.interactive == (args.output_path is not None):
        parser.error("provide exactly one of output_path and --interactive")
    # Word wrapping imports NumPy through optional upstream dependencies.
    os.environ["OMP_NUM_THREADS"] = "1"
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    try:
        limit_worker_memory()
        if args.interactive:
            run_interactive(args.input_path, args.format)
            return 0
        # PDF/HTML diagnostics may include book strings. Only publish our
        # fixed error categories outside the worker process.
        with silence_parser_output():
            status = convert_book(args.input_path, args.format, args.output_path)
    except InvalidBook:
        print("invalid_book", file=sys.stderr)
        return 2
    except (BookLimit, MemoryError):
        print("book_limit", file=sys.stderr)
        return 3
    except Exception:
        print("conversion_failed", file=sys.stderr)
        return 4
    print(json.dumps(status, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
