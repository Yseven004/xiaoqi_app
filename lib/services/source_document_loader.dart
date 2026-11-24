import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import 'docx_document_service.dart';
import 'epub_document_service.dart';
import 'html_article_document_service.dart';
import 'text_document_service.dart';
import 'web_article_source_service.dart';

/// Single dispatch point for structured source documents.
///
/// PDF keeps its existing viewer/catalog path. This loader only owns formats
/// that produce XiaoqiDocument and are consumed by the structured reader and
/// AI adapter.
class SourceDocumentLoader {
  const SourceDocumentLoader({
    this.text = const TextDocumentService(),
    this.epub = const EpubDocumentService(),
    this.docx = const DocxDocumentService(),
    this.html = const HtmlArticleDocumentService(),
  });

  final TextDocumentService text;
  final EpubDocumentService epub;
  final DocxDocumentService docx;
  final HtmlArticleDocumentService html;

  /// File I/O is asynchronous, but decompression and document parsing also
  /// need to leave the UI isolate while the reader is sliding into view.
  static Future<XiaoqiDocument> parseBookSourceInBackground(
    BookSourceRecord source,
  ) => compute(_parseBookSource, source, debugLabel: 'read book source');

  /// Stores only replaceable data from the original EPUB. Edited revisions
  /// remain the caller's responsibility and never share this layout cache.
  static Future<({XiaoqiDocument document, File? epubLayoutCache})>
  parseBookSourceForReader(BookSourceRecord source) async {
    final directory = await _epubReaderCacheDirectory(source);
    if (directory == null) {
      return (
        document: await parseBookSourceInBackground(source),
        epubLayoutCache: null,
      );
    }
    final bookFile = path.join(directory.path, 'document.json');
    final (document, cacheBytes) = await compute(_loadCachedEpub, (
      source,
      bookFile,
    ), debugLabel: 'restore or parse reader EPUB');
    if (cacheBytes != null) unawaited(_writeEpubCache(bookFile, cacheBytes));
    return (
      document: document,
      epubLayoutCache: File(path.join(directory.path, 'layout.json')),
    );
  }

  static Future<Directory?> _epubReaderCacheDirectory(
    BookSourceRecord source,
  ) async {
    if (normalizeBookSourceFormat(source.format) != 'epub') return null;
    try {
      final stat = await File(source.filePath).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final cache = await getTemporaryDirectory();
      final key = sha256.convert(
        utf8.encode(
          jsonEncode([
            EpubDocumentService.structureVersion,
            source.bookId,
            source.id,
            source.filePath,
            source.sourceVersionId,
            source.contentHash,
            stat.size,
            stat.modified.microsecondsSinceEpoch,
          ]),
        ),
      );
      return Directory(path.join(cache.path, 'reader-epub-v1', key.toString()));
    } on Exception {
      return null;
    }
  }

  static const _maxCachedEpubBytes = 48 * 1024 * 1024;

  static Future<(XiaoqiDocument, List<int>?)> _loadCachedEpub(
    (BookSourceRecord, String) request,
  ) async {
    final (source, filePath) = request;
    final file = File(filePath);
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file &&
          stat.size <= _maxCachedEpubBytes) {
        final restored = XiaoqiDocument.fromJson(await file.readAsString());
        if (restored.format == 'epub' &&
            restored.structureVersion == EpubDocumentService.structureVersion &&
            restored.chapters.isNotEmpty) {
          return (restored, null);
        }
      }
    } on Object {
      // A missing or damaged cache is recoverable from the original package.
    }
    final document = await _parseBookSource(source);
    // Bound the transient base64/JSON allocations for very large books.
    final estimatedBytes =
        document.assets.fold<int>(0, (sum, asset) => sum + asset.bytes.length) *
            2 +
        document.chapters.fold<int>(
          0,
          (sum, chapter) =>
              sum + 3 * (chapter.html.length + 2 * chapter.plainText.length),
        );
    if (document.chapters.isEmpty || estimatedBytes > _maxCachedEpubBytes) {
      return (document, null);
    }
    try {
      final data = JsonUtf8Encoder().convert(document.toMap());
      return (document, data.length <= _maxCachedEpubBytes ? data : null);
    } on Object {
      return (document, null);
    }
  }

  static Future<void> _writeEpubCache(String filePath, List<int> data) async {
    final file = File(filePath);
    final staging = File(
      '$filePath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await file.parent.create(recursive: true);
      await staging.writeAsBytes(data);
      await staging.rename(file.path);
    } on FileSystemException {
      // The live document is usable even if the cache cannot be written.
    } finally {
      try {
        if (await staging.exists()) await staging.delete();
      } on FileSystemException {
        // A later cache cleanup can remove unused staging files.
      }
    }
  }

  static Future<XiaoqiDocument> _parseBookSource(BookSourceRecord source) =>
      const SourceDocumentLoader().parseFile(
        source.filePath,
        format: source.format,
      );

  Future<XiaoqiDocument> parseFile(String filePath, {required String format}) {
    final normalized = normalizeBookSourceFormat(format);
    switch (normalized) {
      case 'epub':
        return epub.parseFile(filePath);
      case 'txt':
      case 'markdown':
        return text.parseFile(filePath, format: normalized);
      case 'docx':
        return docx.parseFile(filePath);
      case 'html':
        return _parseHtml(filePath);
      default:
        throw UnsupportedError('暂不支持整理 .$normalized 文件');
    }
  }

  static bool isStructuredFormat(String? format) => const {
    'epub',
    'txt',
    'markdown',
    'docx',
    'html',
  }.contains(normalizeBookSourceFormat(format ?? ''));

  /// PDF has its own reader. Existing structured sources remain readable even
  /// when their format is no longer offered by the import picker.
  static bool isReadableSource(BookSourceRecord source) =>
      source.status == 'ready' &&
      (normalizeBookSourceFormat(source.format) == 'pdf' ||
          isStructuredFormat(source.format));

  Future<XiaoqiDocument> _parseHtml(String filePath) async {
    final source = await File(filePath).readAsString();
    if (WebArticleSourceService.looksLikeAccessChallenge(source)) {
      throw const FormatException('网页需要完成验证，无法整理为正式资料');
    }
    return html.parse(source, sourceUrl: Uri.file(filePath).toString());
  }
}
