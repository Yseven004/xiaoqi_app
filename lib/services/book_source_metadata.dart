import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import '../models/book_recognition.dart';
import '../plugins/document_recognition/fast_ocr_plugin.dart';
import 'epub_document_service.dart';
import 'pdf_catalog_service.dart';

class BookSourceMetadataPreview {
  BookSourceMetadataPreview(this.book, this.coverFile, this.coverDirectory);

  final BookRecord book;
  final File? coverFile;
  final Directory? coverDirectory;

  Future<void> dispose() async {
    try {
      await coverFile?.delete();
    } on FileSystemException {
      // Preview files are temporary.
    }
    try {
      await coverDirectory?.delete();
    } on FileSystemException {
      // The platform can remove abandoned preview directories.
    }
  }

  static Future<BookSourceMetadataPreview> read(
    String path,
    BookRecord fallback,
  ) async {
    File? coverFile;
    Directory? coverDirectory;
    try {
      if (fallback.source == 'local_epub') {
        final metadata = await Isolate.run(
          () => const EpubDocumentService().readMetadata(path),
        );
        var edition = metadata.edition;
        final cover = metadata.cover;
        if (cover != null) {
          try {
            final decoded = await Isolate.run(
              () => validateEmbeddedBookCover(cover.bytes, cover.mimeType),
            );
            if (decoded != null) {
              coverDirectory = await (await getTemporaryDirectory()).createTemp(
                'book-metadata-',
              );
              coverFile = File(
                p.join(coverDirectory.path, 'cover.${decoded.extension}'),
              );
              await coverFile.writeAsBytes(decoded.bytes);
              if (edition.isEmpty) {
                edition = _explicitEdition(await _readCoverText(coverFile));
              }
            }
          } on Object {
            await BookSourceMetadataPreview(
              fallback,
              coverFile,
              coverDirectory,
            ).dispose();
            coverFile = null;
            coverDirectory = null;
          }
        }
        return BookSourceMetadataPreview(
          fallback.copyWith(
            title: metadata.title.isEmpty ? fallback.title : metadata.title,
            authors: metadata.authors,
            publisher: metadata.publisher,
            edition: edition,
            publishedDate: metadata.publishedDate,
            coverPath: coverFile?.path,
            coverType: coverFile == null ? null : 'uploaded',
          ),
          coverFile,
          coverDirectory,
        );
      }
      if (fallback.source == 'local_pdf') {
        if (await File(path).length() > PdfCatalogService.maxPdfBytes) {
          return BookSourceMetadataPreview(fallback, null, null);
        }
        await pdfrxFlutterInitialize();
        final document = await PdfDocument.openFile(path);
        late BookRecord book;
        var hasCoverTitle = false;
        var checkScannedCover = false;
        try {
          var fields = const <String, String>{};
          try {
            fields = await document.useNativeDocumentHandle(_readPdfMetadata);
          } on Object {
            // Extracted page text is still available without native metadata.
          }
          var firstPageText = '';
          final frontMatter = StringBuffer();
          final allowsCopying = document.permissions?.allowsCopying != false;
          if (allowsCopying) {
            for (final page in document.pages.take(3)) {
              try {
                final text = (await page.loadText())?.fullText ?? '';
                if (page.pageNumber == 1) firstPageText = text;
                frontMatter.writeln(text);
              } on Object {
                // An unreadable preliminary page does not hide the PDF info.
              }
            }
          }
          final frontText = frontMatter.toString();
          final title = fields['Title']?.isNotEmpty == true
              ? fields['Title']!
              : _explicitField(frontText, '书名|作品名称');
          final author = fields['Author']?.isNotEmpty == true
              ? fields['Author']!
              : _explicitField(frontText, '作者|著者');
          hasCoverTitle = _containsTitle(firstPageText, title);
          checkScannedCover =
              allowsCopying &&
              title.isNotEmpty &&
              firstPageText.trim().isEmpty &&
              (Platform.isAndroid || Platform.isIOS);
          book = fallback.copyWith(
            title: title.isEmpty ? fallback.title : title,
            authors: author.isEmpty ? [] : [author],
            publisher: fields['Publisher']?.isNotEmpty == true
                ? fields['Publisher']
                : _explicitField(frontText, '出版者|出版社|出版单位'),
            edition: _explicitEdition(frontText),
            publishedDate: _explicitPublicationYear(frontText),
          );
        } finally {
          await document.dispose();
        }
        if (hasCoverTitle || checkScannedCover) {
          try {
            final coverPath = await const PdfCatalogService()
                .renderPageForEditing(path, 1);
            coverFile = File(coverPath);
            if (hasCoverTitle ||
                _containsTitle(await _readCoverText(coverFile), book.title)) {
              book = book.copyWith(coverPath: coverPath, coverType: 'uploaded');
            }
          } on Object {
            // Confirm the available metadata even when the cover render fails.
          }
        }
        return BookSourceMetadataPreview(book, coverFile, null);
      }
    } on Object {
      await BookSourceMetadataPreview(
        fallback,
        coverFile,
        coverDirectory,
      ).dispose();
    }
    return BookSourceMetadataPreview(fallback, null, null);
  }
}

({Uint8List bytes, String extension})? validateEmbeddedBookCover(
  List<int> asset,
  String mimeType,
) {
  final bytes = asset is Uint8List ? asset : Uint8List.fromList(asset);
  final (decoder, extension) = switch (mimeType) {
    'image/jpeg' => (image.JpegDecoder(), 'jpg'),
    'image/png' => (image.PngDecoder(), 'png'),
    'image/webp' => (image.WebPDecoder(), 'webp'),
    _ => (null, ''),
  };
  try {
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 16 * 1024 * 1024) {
      return null;
    }
    return (bytes: bytes, extension: extension);
  } on Object {
    return null;
  }
}

Future<String> _readCoverText(File cover) async {
  try {
    return (await NativeFastOcrPlugin().recognize(cover.path)).fullText;
  } on Object {
    return '';
  }
}

String _explicitEdition(String text) {
  final value = RegExp(
    r'(?:版\s*本|版\s*次|\bedition)[ \t：:]*([vV]?[ \t]*\d+(?:[.．][ \t]*\d+)+|第[ \t]*[一二三四五六七八九十0-9]+[ \t]*版)',
    caseSensitive: false,
  ).firstMatch(text)?.group(1);
  return value?.replaceAll(RegExp(r'[ \t]'), '').replaceAll('．', '.') ?? '';
}

bool _containsTitle(String text, String title) {
  String compact(String value) => value.replaceAll(RegExp(r'[\s\u3000]'), '');
  final target = compact(title);
  return target.isNotEmpty && compact(text).contains(target);
}

String _explicitField(String text, String labels) =>
    RegExp(
      '^\\s*(?:$labels)\\s*[：:]\\s*([^\\r\\n]{2,100})',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim() ??
    '';

String _explicitPublicationYear(String text) =>
    RegExp(
      r'(?:出版日期|出版年份|出版时间)[ \t：:]+((?:19|20)\d{2})',
    ).firstMatch(text)?.group(1) ??
    '';

Map<String, String> _readPdfMetadata(int address) {
  final engine = pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);
  final document = pdfium.FPDF_DOCUMENT.fromAddress(address);
  return {
    for (final field in const ['Title', 'Author', 'Publisher'])
      field: using((arena) {
        final tag = field.toNativeUtf8(allocator: arena).cast<ffi.Char>();
        final count = engine.FPDF_GetMetaText(document, tag, ffi.nullptr, 0);
        if (count <= 2 || count > 4096) return '';
        final buffer = arena<ffi.Uint16>((count + 1) ~/ 2);
        final written = engine.FPDF_GetMetaText(
          document,
          tag,
          buffer.cast(),
          count,
        );
        final units = buffer.asTypedList(math.min(written, count) ~/ 2);
        return String.fromCharCodes(
          units.takeWhile((unit) => unit != 0),
        ).trim();
      }),
  };
}
