import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import '../plugins/document_recognition/fast_ocr_plugin.dart';

/// A source page, in reading order, with geometry in original page fractions.
class CompanionReflowPage {
  const CompanionReflowPage(
    this.number,
    this.lines, {
    this.keepOriginal = false,
  });

  final int number;
  final List<CompanionReflowLine> lines;
  final bool keepOriginal;

  String get text => lines.map((line) => line.text).join('\n');
  String get chapterId => 'pdf-page-$number';

  List<_ReflowParagraph> get _paragraphs {
    final paragraphs = <_ReflowParagraph>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final previous = index == 0 ? null : lines[index - 1];
      if (previous == null ||
          line.bounds.top - previous.bounds.bottom >
              previous.bounds.height * .9 ||
          line.bounds.left - previous.bounds.left >
              previous.bounds.height * .9) {
        paragraphs.add(_ReflowParagraph('$chapterId-line-$index', line));
      } else {
        paragraphs.last.append(line);
      }
    }
    return paragraphs;
  }

  ({String blockId, int offset})? entryNear(double? top) {
    if (top == null || lines.isEmpty) return null;
    for (final paragraph in _paragraphs) {
      for (final entry in paragraph.lines) {
        if (entry.line.bounds.bottom >= top) {
          return (blockId: paragraph.id, offset: entry.offset);
        }
      }
    }
    return null;
  }

  double? originalTop(String? blockId, int? offset) {
    if (blockId == null || offset == null) return null;
    for (final paragraph in _paragraphs) {
      if (paragraph.id == blockId) {
        return paragraph.lines
            .lastWhere((entry) => entry.offset <= offset)
            .line
            .bounds
            .top;
      }
    }
    return null;
  }

  XiaoqiDocument document(int pageCount) => XiaoqiDocument(
    format: 'pdf-reflow',
    title: '',
    author: '',
    language: '',
    originalPageCount: pageCount,
    chapters: [
      XiaoqiDocumentChapter(
        id: chapterId,
        title: '',
        href: chapterId,
        html: '',
        plainText: text,
        order: number - 1,
        blocks: [
          for (final paragraph in _paragraphs)
            XiaoqiDocumentBlock(
              id: paragraph.id,
              kind: 'paragraph',
              text: paragraph.body.toString(),
              sourceLocator: 'page:$number',
              originalPageLabel: '$number',
            ),
        ],
        sourceLocator: 'page:$number',
      ),
    ],
  );
}

class _ReflowParagraph {
  _ReflowParagraph(this.id, CompanionReflowLine first)
    : body = StringBuffer(first.text),
      lines = [(line: first, offset: 0)];

  final String id;
  final StringBuffer body;
  final List<({CompanionReflowLine line, int offset})> lines;
  static final _eastAsianEdge = RegExp(r'[\u2e80-\u9fff\uf900-\ufaff]');

  void append(CompanionReflowLine line) {
    final previous = lines.last.line.text;
    if (!_eastAsianEdge.hasMatch(previous.substring(previous.length - 1)) &&
        !_eastAsianEdge.hasMatch(line.text.substring(0, 1))) {
      body.write(' ');
    }
    lines.add((line: line, offset: body.length));
    body.write(line.text);
  }
}

class CompanionReflowLine {
  const CompanionReflowLine(this.text, this.bounds, {this.recognized = false});

  final String text;
  final Rect bounds;
  final bool recognized;

  List<Object> toJson() => [
    text,
    bounds.left,
    bounds.top,
    bounds.right,
    bounds.bottom,
    recognized,
  ];

  static CompanionReflowLine fromJson(List<dynamic> row) => CompanionReflowLine(
    row[0] as String,
    Rect.fromLTRB(
      (row[1] as num).toDouble(),
      (row[2] as num).toDouble(),
      (row[3] as num).toDouble(),
      (row[4] as num).toDouble(),
    ),
    recognized: row[5] as bool,
  );
}

/// Single owner for extraction and OCR. The same page request joins existing
/// work, and a foreground page can supersede background prefetch.
class CompanionPdfReflow {
  CompanionPdfReflow(BookSourceRecord source)
    : _cacheKey = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                source.id,
                source.sourceVersionId,
                source.contentHash,
                source.filePath,
              ]),
            ),
          )
          .toString();

  final String _cacheKey;
  final _ocr = NativeFastOcrPlugin();
  final _results = <int, CompanionReflowPage>{};
  final _jobs = <int, _ReflowJob>{};
  int _sequence = 0;
  late final Future<Directory> _directory = getTemporaryDirectory().then(
    (root) => Directory(
      '${root.path}${Platform.pathSeparator}companion-reflow-v1${Platform.pathSeparator}$_cacheKey',
    ).create(recursive: true),
  );

  CompanionReflowPage? cached(int page) => _results[page];

  Future<CompanionReflowPage?> load(
    PdfViewerController viewer,
    int number, {
    bool prefetch = false,
  }) async {
    final existing = _results[number];
    if (existing != null) return existing;
    final active = _jobs[number];
    if (active != null) {
      if (!prefetch) active.prefetch = false;
      return active.result;
    }
    if (!prefetch) {
      for (final entry in _jobs.entries.toList()) {
        if (entry.value.prefetch) _cancel(entry.key, entry.value);
      }
    }
    final job = _ReflowJob(
      '$_cacheKey-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
      prefetch: prefetch,
    );
    _jobs[number] = job;
    job.result = _readOrExtract(viewer, number, job);
    try {
      return await job.result;
    } finally {
      if (identical(_jobs[number], job)) _jobs.remove(number);
    }
  }

  void cancel({int? exceptPage}) {
    for (final entry in _jobs.entries.toList()) {
      if (entry.key != exceptPage) _cancel(entry.key, entry.value);
    }
  }

  void _cancel(int number, _ReflowJob job) {
    _jobs.remove(number);
    job.cancelled = true;
    job.render?.cancel();
    if (job.recognizing) unawaited(_ocr.cancelRecognition(job.id));
  }

  Future<CompanionReflowPage?> _readOrExtract(
    PdfViewerController viewer,
    int number,
    _ReflowJob job,
  ) async {
    if (!viewer.isReady) return null;
    return await viewer.useDocument<CompanionReflowPage?>((document) async {
      if (document.permissions?.allowsCopying == false) {
        return CompanionReflowPage(number, const [], keepOriginal: true);
      }
      if (number < 1 || number > document.pages.length) return null;
      File? cacheFile;
      try {
        final directory = await _directory;
        cacheFile = File(
          '${directory.path}${Platform.pathSeparator}$number.json',
        );
        if (await cacheFile.exists()) {
          final data = jsonDecode(await cacheFile.readAsString()) as Map;
          final cached = CompanionReflowPage(
            number,
            (data['lines'] as List)
                .map((row) => CompanionReflowLine.fromJson(row as List))
                .toList(growable: false),
            keepOriginal: data['keepOriginal'] == true,
          );
          if (job.cancelled) return null;
          return _remember(cached);
        }
      } on Object {
        // The cache is expendable. Always attempt to read the original file.
      }
      if (job.cancelled) return null;
      final page = await document.pages[number - 1].waitForLoaded(
        timeout: const Duration(seconds: 8),
      );
      if (job.cancelled || page == null) return null;
      final original = page is _RecognizedPdfPage ? page.original : page;
      final raw = await original.loadText();
      final lines = _nativeLines(page, raw);
      final canRecognize = Platform.isAndroid || Platform.isIOS;
      var keepOriginal = false;
      var persistResult = true;
      if (canRecognize &&
          !job.cancelled &&
          (lines.isEmpty || await _hasUncoveredContent(page, lines, job))) {
        try {
          final recognized = await _recognize(page, job);
          final countBefore = lines.length;
          for (final line in recognized.lines) {
            if (!lines.any((native) => _duplicates(native, line))) {
              lines.add(line);
            }
          }
          keepOriginal = !recognized.reliable || lines.length == countBefore;
        } on FastOcrUnavailableException {
          // A system language or model may become available after an update.
          keepOriginal = true;
          persistResult = false;
        } on FastOcrCancelledException {
          return null;
        }
      }
      if (job.cancelled) return null;
      lines.sort(
        (first, second) => first.bounds.top.compareTo(second.bounds.top),
      );
      final result = CompanionReflowPage(
        number,
        List.unmodifiable(lines),
        keepOriginal: keepOriginal || lines.isEmpty || _isComplex(lines),
      );
      if (persistResult) {
        _remember(result);
        if (cacheFile != null) unawaited(_saveCache(cacheFile, result, job.id));
      }
      return result;
    });
  }

  CompanionReflowPage _remember(CompanionReflowPage result) {
    if (_results.length >= 24) _results.remove(_results.keys.first);
    return _results[result.number] = result;
  }

  Future<void> _saveCache(
    File cache,
    CompanionReflowPage result,
    String id,
  ) async {
    final staging = File('${cache.path}.$id.tmp');
    try {
      await staging.writeAsString(
        jsonEncode({
          'keepOriginal': result.keepOriginal,
          'lines': result.lines.map((line) => line.toJson()).toList(),
        }),
      );
      await staging.rename(cache.path);
    } on FileSystemException {
      if (await staging.exists()) {
        try {
          await staging.delete();
        } on FileSystemException {
          // A future extraction can still replace the cache.
        }
      }
    }
  }

  static List<CompanionReflowLine> _nativeLines(
    PdfPage page,
    PdfPageRawText? raw,
  ) {
    if (raw == null || raw.fullText.isEmpty) return [];
    final result = <CompanionReflowLine>[];
    for (final match in RegExp(r'[^\r\n]+').allMatches(raw.fullText)) {
      final text = match.group(0)!.trim();
      if (text.isEmpty || match.end > raw.charRects.length) continue;
      Rect? box;
      for (var index = match.start; index < match.end; index++) {
        final character = raw.charRects[index];
        if (character.isEmpty) continue;
        final bounds = character.toRect(page: page);
        box = box?.expandToInclude(bounds) ?? bounds;
      }
      if (box != null && box.width > 0 && box.height > 0) {
        result.add(
          CompanionReflowLine(
            text,
            Rect.fromLTRB(
              box.left / page.width,
              box.top / page.height,
              box.right / page.width,
              box.bottom / page.height,
            ),
          ),
        );
      }
    }
    return result;
  }

  /// PDFium exposes text boxes and rendering. Sample outside those boxes at a
  /// small resolution to find scanned body regions without OCRing born-digital
  /// pages simply because they contain margins or whitespace.
  Future<bool> _hasUncoveredContent(
    PdfPage page,
    List<CompanionReflowLine> lines,
    _ReflowJob job,
  ) async {
    final image = await _render(page, job, 192);
    if (image == null) return false;
    try {
      var rowsWithInk = 0;
      for (var y = 0; y < image.height; y += 2) {
        final dy = y / image.height;
        final covered = lines
            .where(
              (line) =>
                  dy >= line.bounds.top - .009 &&
                  dy <= line.bounds.bottom + .009,
            )
            .toList();
        var pixelsWithInk = 0;
        for (var x = 0; x < image.width; x += 2) {
          final i = (y * image.width + x) * 4;
          final pixels = image.pixels;
          if (pixels[i] >= 160 &&
              pixels[i + 1] >= 160 &&
              pixels[i + 2] >= 160) {
            continue;
          }
          final dx = x / image.width;
          if (!covered.any(
            (line) =>
                dx >= line.bounds.left - .015 && dx <= line.bounds.right + .015,
          )) {
            pixelsWithInk++;
          }
        }
        if (pixelsWithInk > 3) rowsWithInk++;
      }
      return rowsWithInk > image.height * .025;
    } finally {
      image.dispose();
    }
  }

  Future<PdfImage?> _render(PdfPage page, _ReflowJob job, double maxEdge) {
    if (job.cancelled) return Future.value(null);
    final scale = maxEdge / math.max(page.width, page.height);
    final token = page.createCancellationToken();
    job.render = token;
    return page.render(
      fullWidth: math.max(1.0, page.width * scale),
      fullHeight: math.max(1.0, page.height * scale),
      backgroundColor: 0xffffffff,
      annotationRenderingMode: PdfAnnotationRenderingMode.none,
      cancellationToken: token,
    );
  }

  Future<({List<CompanionReflowLine> lines, bool reliable})> _recognize(
    PdfPage page,
    _ReflowJob job,
  ) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}companion-${job.id}.png',
    );
    final raster = await _render(page, job, 2400);
    const empty = (lines: <CompanionReflowLine>[], reliable: false);
    if (raster == null) return empty;
    try {
      if (job.cancelled) return empty;
      final image = await raster.createImage();
      try {
        final png = await image.toByteData(format: ImageByteFormat.png);
        if (job.cancelled || png == null) return empty;
        await file.writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
      if (job.cancelled) return empty;
      job.recognizing = true;
      final result = await _ocr.recognizePage(file.path, jobId: job.id);
      if (job.cancelled || result.imageWidth < 1 || result.imageHeight < 1) {
        return empty;
      }
      final lowConfidence = result.lines
          .where((line) => line.confidence < .70)
          .length;
      return (
        reliable:
            result.lines.isNotEmpty && lowConfidence * 4 <= result.lines.length,
        lines: [
          for (final line in result.lines)
            if (line.text.isNotEmpty &&
                line.width > 0 &&
                line.height > 0 &&
                line.confidence >= .50)
              CompanionReflowLine(
                line.text,
                Rect.fromLTRB(
                  line.left / result.imageWidth,
                  line.top / result.imageHeight,
                  line.right / result.imageWidth,
                  line.bottom / result.imageHeight,
                ),
                recognized: true,
              ),
        ],
      );
    } finally {
      job.recognizing = false;
      raster.dispose();
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Temporary rasters are managed by the operating system.
      }
    }
  }

  static bool _duplicates(CompanionReflowLine native, CompanionReflowLine ocr) {
    final overlap = native.bounds.intersect(ocr.bounds);
    if (overlap.isEmpty) return false;
    final smaller = math.min(
      native.bounds.width * native.bounds.height,
      ocr.bounds.width * ocr.bounds.height,
    );
    return overlap.width * overlap.height > smaller * .55 ||
        native.text.replaceAll(' ', '') == ocr.text.replaceAll(' ', '');
  }

  static bool _isComplex(List<CompanionReflowLine> lines) {
    var parallel = 0;
    for (var index = 1; index < lines.length; index++) {
      final first = lines[index - 1].bounds;
      final second = lines[index].bounds;
      if ((first.center.dy - second.center.dy).abs() <
              math.min(first.height, second.height) * .65 &&
          (first.right < second.left - .02 ||
              second.right < first.left - .02)) {
        parallel++;
      }
    }
    return parallel >= 3;
  }
}

class _ReflowJob {
  _ReflowJob(this.id, {required this.prefetch});

  final String id;
  bool prefetch;
  bool cancelled = false;
  bool recognizing = false;
  PdfPageRenderCancellationToken? render;
  late final Future<CompanionReflowPage?> result;
}

/// Gives the existing PDF viewer a text layer for recognized page regions
/// while the native document continues to own rendering and file permissions.
class CompanionSelectionDocument extends PdfDocument {
  CompanionSelectionDocument(this.original)
    : super(sourceName: original.sourceName) {
    _subscription = original.events.listen(
      _events.add,
      onError: _events.addError,
    );
  }

  final PdfDocument original;
  final _events = StreamController<PdfDocumentEvent>.broadcast(sync: true);
  late final StreamSubscription<PdfDocumentEvent> _subscription;
  final _recognized = <int, _RecognizedPdfPage>{};
  List<PdfPage>? _basePages;
  List<PdfPage> _pages = const [];

  void install(CompanionReflowPage reflow) {
    if (permissions?.allowsCopying == false ||
        _recognized.containsKey(reflow.number) ||
        !reflow.lines.any((line) => line.recognized)) {
      return;
    }
    final page = original.pages[reflow.number - 1];
    final replacement = _RecognizedPdfPage(page, reflow);
    _recognized[reflow.number] = replacement;
    _basePages = null;
    _events.add(
      PdfDocumentPageStatusChangedEvent(
        this,
        changes: {
          reflow.number: PdfPageStatusChange.modified(page: replacement),
        },
      ),
    );
  }

  @override
  List<PdfPage> get pages {
    final originalPages = original.pages;
    if (!identical(_basePages, originalPages)) {
      _basePages = originalPages;
      _pages = List.unmodifiable(
        originalPages.map((page) {
          final recognized = _recognized[page.pageNumber];
          return recognized != null && identical(recognized.original, page)
              ? recognized
              : page;
        }),
      );
    }
    return _pages;
  }

  @override
  set pages(List<PdfPage> value) => original.pages = [
    for (final page in value) page is _RecognizedPdfPage ? page.original : page,
  ];

  @override
  PdfPermissions? get permissions => original.permissions;

  @override
  bool get isEncrypted => original.isEncrypted;

  @override
  Stream<PdfDocumentEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    await Future.wait<void>([
      _subscription.cancel(),
      _events.close(),
      original.dispose(),
    ]);
  }

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) => original.loadPagesProgressively(
    onPageLoadProgress: onPageLoadProgress,
    data: data,
    loadUnitDuration: loadUnitDuration,
  );

  @override
  Future<List<PdfOutlineNode>> loadOutline() => original.loadOutline();

  @override
  bool isIdenticalDocumentHandle(Object? other) =>
      original.isIdenticalDocumentHandle(
        other is CompanionSelectionDocument ? other.original : other,
      );

  @override
  Future<bool> assemble() => original.assemble();

  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) => original.encodePdf(
    incremental: incremental,
    removeSecurity: removeSecurity,
  );

  @override
  Future<T> useNativeDocumentHandle<T>(
    FutureOr<T> Function(int nativeDocumentHandle) task,
  ) => original.useNativeDocumentHandle(task);

  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) =>
      original.reloadPages(pageNumbersToReload: pageNumbersToReload);
}

class _RecognizedPdfPage implements PdfPage {
  _RecognizedPdfPage(this.original, this.reflow);

  final PdfPage original;
  final CompanionReflowPage reflow;

  @override
  PdfDocument get document => original.document;
  @override
  int get pageNumber => original.pageNumber;
  @override
  double get width => original.width;
  @override
  double get height => original.height;
  @override
  PdfPageRotation get rotation => original.rotation;
  @override
  bool get isLoaded => original.isLoaded;

  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      original.createCancellationToken();

  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) => original.loadLinks(
    compact: compact,
    enableAutoLinkDetection: enableAutoLinkDetection,
  );

  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) => original.render(
    x: x,
    y: y,
    width: width,
    height: height,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    backgroundColor: backgroundColor,
    rotationOverride: rotationOverride,
    annotationRenderingMode: annotationRenderingMode,
    flags: flags,
    cancellationToken: cancellationToken,
  );

  @override
  Future<PdfPageRawText?> loadText() async {
    final raw = await original.loadText();
    final text = StringBuffer();
    final boxes = <PdfRect>[];
    for (final line in reflow.lines) {
      final bounds = line.bounds;
      final match = line.recognized || raw == null
          ? -1
          : raw.fullText.indexOf(line.text);
      final count = line.text.length;
      text.writeln(line.text);
      for (var index = 0; index < count; index++) {
        if (match >= 0 && match + index < raw!.charRects.length) {
          boxes.add(raw.charRects[match + index]);
          continue;
        }
        boxes.add(
          Rect.fromLTRB(
            width * (bounds.left + bounds.width * index / count),
            height * bounds.top,
            width * (bounds.left + bounds.width * (index + 1) / count),
            height * bounds.bottom,
          ).toPdfRect(page: original),
        );
      }
      boxes.add(PdfRect.empty);
    }
    return PdfPageRawText(text.toString(), boxes);
  }
}
