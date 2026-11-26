import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

typedef EpubReaderUpdate = ({
  XiaoqiDocument document,
  EpubReaderPreview? preview,
});

class EpubReaderLoad {
  EpubReaderLoad._(this._worker, this.layoutCache, this.initialChapterId);

  final _EpubReaderWorker _worker;
  final File? layoutCache;
  final String? initialChapterId;

  Stream<EpubReaderUpdate> get updates => _worker.watch(initialChapterId);

  void prioritize(String chapterId) => _worker.prioritize(chapterId);
}

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

  static final _epubReaderLoads = <String, _EpubReaderWorker>{};
  static bool _warmingReaderCache = false;

  /// File I/O is asynchronous, but decompression and document parsing also
  /// need to leave the UI isolate while the reader is sliding into view.
  static Future<XiaoqiDocument> parseBookSourceInBackground(
    BookSourceRecord source,
  ) => compute(_parseBookSource, source, debugLabel: 'read book source');

  /// Publishes the requested chapter before completing a cold EPUB. A current
  /// full cache follows the same stream contract and needs no partial update.
  static Future<EpubReaderLoad> openEpubReader(
    BookSourceRecord source, {
    String? initialChapterId,
  }) async {
    final directory = await _epubReaderCacheDirectory(source);
    final worker = _loadReaderEpub(source, directory, initialChapterId);
    return EpubReaderLoad._(
      worker,
      directory == null ? null : File(path.join(directory.path, 'layout.json')),
      initialChapterId,
    );
  }

  /// Share a speculative parse with the reader opening this source. A new
  /// reader can change the worker's target at its next chapter boundary.
  static Future<void> prepareReaderCache(BookSourceRecord source) async {
    if (_warmingReaderCache ||
        source.format != 'epub' ||
        source.fileSize > _maxCachedEpubBytes) {
      return;
    }
    _warmingReaderCache = true;
    try {
      final directory = await _epubReaderCacheDirectory(source);
      if (directory == null ||
          await File(path.join(directory.path, 'document.json')).exists()) {
        return;
      }
      await _loadReaderEpub(source, directory, null).done;
    } on Object {
      // The explicit open can retry and report the source error.
    } finally {
      _warmingReaderCache = false;
    }
  }

  static _EpubReaderWorker _loadReaderEpub(
    BookSourceRecord source,
    Directory? directory,
    String? target,
  ) {
    final cachePath = directory == null
        ? null
        : path.join(directory.path, 'document.json');
    final key =
        cachePath ??
        jsonEncode([
          source.filePath,
          source.sourceVersionId,
          source.contentHash,
        ]);
    final worker = _epubReaderLoads.putIfAbsent(key, () {
      final worker = _EpubReaderWorker(source.filePath, cachePath, target);
      unawaited(
        worker.done.then((_) {
          if (identical(_epubReaderLoads[key], worker)) {
            _epubReaderLoads.remove(key);
          }
        }),
      );
      return worker;
    });
    if (target != null) worker.prioritize(target);
    return worker;
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

  static Future<XiaoqiDocument?> _readEpubCache(String filePath) async {
    final file = File(filePath);
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file &&
          stat.size <= _maxCachedEpubBytes) {
        final restored = XiaoqiDocument.fromJson(await file.readAsString());
        if (restored.format == 'epub' &&
            restored.structureVersion == EpubDocumentService.structureVersion &&
            restored.chapters.isNotEmpty) {
          return restored;
        }
      }
    } on Object {
      // A missing or damaged cache is recoverable from the original package.
    }
    return null;
  }

  static List<int>? _encodeEpubCache(XiaoqiDocument document) {
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
      return null;
    }
    try {
      final data = JsonUtf8Encoder().convert(document.toMap());
      return data.length <= _maxCachedEpubBytes ? data : null;
    } on Object {
      return null;
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

typedef _EpubWorkerInput = ({
  SendPort output,
  String path,
  String? cachePath,
  String? target,
});

class _EpubReaderWorker {
  _EpubReaderWorker(String path, String? cachePath, this._initialTarget)
    : _target = _initialTarget {
    _port.listen(_receive);
    unawaited(
      Isolate.spawn(
        _readEpubInIsolate,
        (
          output: _port.sendPort,
          path: path,
          cachePath: cachePath,
          target: _initialTarget,
        ),
        onExit: _port.sendPort,
        debugName: 'read EPUB chapters',
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace trace) {
          _fail(error.toString());
          _finish();
        },
      ),
    );
  }

  final _port = ReceivePort();
  final _updates = StreamController<EpubReaderUpdate>.broadcast(sync: true);
  final _finished = Completer<void>();
  final String? _initialTarget;
  SendPort? _requests;
  EpubReaderUpdate? _latest;
  String? _target;
  String? _error;

  Future<void> get done => _finished.future;

  void prioritize(String chapterId) {
    if (_target == chapterId) return;
    _target = chapterId;
    _requests?.send(chapterId);
  }

  Stream<EpubReaderUpdate> watch(String? target) => Stream.multi((controller) {
    void forward(EpubReaderUpdate update) {
      final preview = update.preview;
      // A warmup may have published the first chapter before this reader
      // requested a restored position. Wait for that target when known.
      if (target != null &&
          preview != null &&
          preview.document.chapters.first.id != target &&
          preview.spine.any((item) => item.chapterId == target)) {
        return;
      }
      target = null;
      controller.add(update);
    }

    final subscription = _updates.stream.listen(
      forward,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
    if (_latest case final update?) forward(update);
    if (_error case final error?) controller.addError(StateError(error));
  });

  void _receive(Object? message) {
    switch (message) {
      case SendPort requests:
        _requests = requests;
        if (_target case final target? when target != _initialTarget) {
          requests.send(target);
        }
      case EpubReaderPreview preview:
        _publish((document: preview.document, preview: preview));
      case XiaoqiDocument document:
        _publish((document: document, preview: null));
      case String error:
        _fail(error);
      case null:
        if (_latest == null || _latest?.preview != null) {
          _fail('EPUB 章节读取中断');
        }
        _finish();
    }
  }

  void _publish(EpubReaderUpdate update) {
    _latest = update;
    _updates.add(update);
  }

  void _fail(String error) {
    if (_error != null) return;
    _error = error;
    _updates.addError(StateError(error));
  }

  void _finish() {
    _port.close();
    unawaited(_updates.close());
    _finished.complete();
  }
}

Future<void> _readEpubInIsolate(_EpubWorkerInput input) async {
  final requests = ReceivePort();
  var target = input.target;
  requests.listen((value) {
    if (value is String) target = value;
  });
  input.output.send(requests.sendPort);
  try {
    final cachePath = input.cachePath;
    final cached = cachePath == null
        ? null
        : await SourceDocumentLoader._readEpubCache(cachePath);
    if (cached != null) {
      input.output.send(cached);
      return;
    }
    final document = await const EpubDocumentService().parseForReader(
      input.path,
      takeTarget: () {
        final requested = target;
        target = null;
        return requested;
      },
      publish: input.output.send,
    );
    input.output.send(document);
    if (cachePath != null) {
      final data = SourceDocumentLoader._encodeEpubCache(document);
      if (data != null) {
        await SourceDocumentLoader._writeEpubCache(cachePath, data);
      }
    }
  } on Object catch (error) {
    input.output.send(error.toString());
  } finally {
    requests.close();
  }
}
