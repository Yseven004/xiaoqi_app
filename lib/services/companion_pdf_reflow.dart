import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
  static const readingChapterId = 'pdf-reflow-body';
  static final _chapterHeading = RegExp(
    r'^(?:第[\s零〇一二三四五六七八九十百千万两\d０-９]+[卷篇部章节回]|(?:chapter|part|section)\s+(?:\d+|[ivxlcdm]+)\b)',
    caseSensitive: false,
  );

  const CompanionReflowPage(
    this.number,
    this.lines, {
    this.keepOriginal = false,
    this.pictures = const [],
  });

  final int number;
  final List<CompanionReflowLine> lines;
  final bool keepOriginal;
  final List<CompanionPagePicture> pictures;
  int get imageByteCount =>
      pictures.fold(0, (sum, picture) => sum + picture.asset.bytes.length);
  bool get canRead =>
      pictures.isNotEmpty || (!keepOriginal && lines.isNotEmpty);

  String get text => lines.map((line) => line.text).join('\n');
  String get chapterId => 'pdf-page-$number';

  List<_ReflowParagraph> get _paragraphs {
    final paragraphs = <_ReflowParagraph>[];
    CompanionReflowLine? preceding;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (pictures.any((item) => item.bounds.contains(line.bounds.center))) {
        preceding = null;
        continue;
      }
      final previous = preceding;
      if (previous == null ||
          pictures.any(
            (item) =>
                item.bounds.center.dy > previous.bounds.center.dy &&
                item.bounds.center.dy < line.bounds.center.dy,
          ) ||
          _caption.hasMatch(line.text) ||
          _caption.hasMatch(previous.text) ||
          _listMarker.hasMatch(line.text) ||
          _isHeading(line.text) ||
          _isHeading(previous.text) ||
          line.bounds.top - previous.bounds.bottom >
              previous.bounds.height * .9 ||
          line.bounds.left - previous.bounds.left >
              previous.bounds.height * .9) {
        paragraphs.add(_ReflowParagraph('$chapterId-line-$index', line));
      } else {
        paragraphs.last.append(line);
      }
      preceding = line;
    }
    return paragraphs;
  }

  static bool _isHeading(String text) =>
      text.length <= 72 &&
      _chapterHeading.hasMatch(text) &&
      !RegExp(r'[。！？!?]$').hasMatch(text);

  static final _caption = RegExp(
    r'^(?:(?:图|圖|表)\s*[0-9０-９一二三四五六七八九十]+|(?:fig(?:ure)?\.?|table)\s*\d)',
    caseSensitive: false,
  );
  static final _listMarker = RegExp(
    r'^(?:[•●■▪]|[-–]\s|[（(][0-9０-９]+[)）]|[0-9０-９]+[、)]|\d+\.\s)',
  );

  ({String blockId, int offset})? entryNear(double? top) {
    if (top == null) return null;
    final entries = [
      for (final paragraph in _paragraphs)
        for (final entry in paragraph.lines)
          (
            bottom: entry.line.bounds.bottom,
            id: paragraph.id,
            offset: entry.offset,
          ),
      for (final picture in pictures)
        (bottom: picture.bounds.bottom, id: picture.asset.id, offset: 0),
    ]..sort((a, b) => a.bottom.compareTo(b.bottom));
    if (entries.isNotEmpty) {
      final entry = entries.firstWhere(
        (item) => item.bottom >= top,
        orElse: () => entries.last,
      );
      return (blockId: entry.id, offset: entry.offset);
    }
    return null;
  }

  double? originalTop(String? blockId, int? offset) {
    if (blockId == null || offset == null) return null;
    for (final picture in pictures) {
      if (picture.asset.id == blockId) return picture.bounds.top;
    }
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

  static XiaoqiDocument readingWindow(
    Iterable<CompanionReflowPage> pages,
    int pageCount,
  ) {
    final blocks = <XiaoqiDocumentBlock>[];
    CompanionReflowPage? previous;
    for (final page in pages) {
      final items = page._blocks();
      if (items.isNotEmpty &&
          blocks.isNotEmpty &&
          previous != null &&
          page.number == previous.number + 1 &&
          _continuesAcrossPage(blocks.last, items.first, previous, page)) {
        final first = items.removeAt(0);
        final last = blocks.removeLast();
        final prefix =
            last.text + _ReflowParagraph.separator(last.text, first.text);
        blocks.add(
          XiaoqiDocumentBlock(
            id: last.id,
            kind: last.kind,
            level: last.level,
            text: prefix + first.text,
            sourceLocator: last.sourceLocator,
            originalPageLabel: last.originalPageLabel,
            attributes: {
              ...last.attributes,
              first.id: prefix.length.toString(),
            },
          ),
        );
      }
      blocks.addAll(items);
      previous = page;
    }
    return XiaoqiDocument(
      format: 'pdf-reflow',
      title: '',
      author: '',
      language: '',
      originalPageCount: pageCount,
      assets: [
        for (final page in pages)
          for (final picture in page.pictures) picture.asset,
      ],
      chapters: [
        XiaoqiDocumentChapter(
          id: readingChapterId,
          title: '',
          href: readingChapterId,
          html: '',
          plainText: pages.map((page) => page.text).join('\n\n'),
          order: 0,
          blocks: blocks,
        ),
      ],
    );
  }

  List<XiaoqiDocumentBlock> _blocks() {
    final items = <({double top, XiaoqiDocumentBlock block})>[
      for (final paragraph in _paragraphs)
        (
          top: paragraph.lines.first.line.bounds.top,
          block: XiaoqiDocumentBlock(
            id: paragraph.id,
            kind: _isHeading(paragraph.body.toString())
                ? 'heading'
                : 'paragraph',
            level: 1,
            text: paragraph.body.toString(),
            sourceLocator: 'page:$number',
            originalPageLabel: '$number',
          ),
        ),
      for (final picture in pictures)
        (
          top: picture.bounds.top,
          block: XiaoqiDocumentBlock(
            id: picture.asset.id,
            kind: 'image',
            assetId: picture.asset.id,
            text: '',
            originalPageLabel: '$number',
            sourceLocator: picture.asset.sourceLocator,
            attributes: {
              'aspectRatio': picture.aspectRatio.toString(),
              if (picture.bounds == const Rect.fromLTWH(0, 0, 1, 1))
                'originalPageImage': 'true',
            },
          ),
        ),
    ]..sort((a, b) => a.top.compareTo(b.top));
    return items.map((item) => item.block).toList();
  }

  static bool _continuesAcrossPage(
    XiaoqiDocumentBlock end,
    XiaoqiDocumentBlock start,
    CompanionReflowPage previous,
    CompanionReflowPage next,
  ) {
    if (end.kind != 'paragraph' ||
        start.kind != 'paragraph' ||
        _caption.hasMatch(end.text) ||
        _caption.hasMatch(start.text) ||
        RegExp(r'''[。！？.!?:：；;”」』）)]$''').hasMatch(end.text) ||
        _listMarker.hasMatch(start.text)) {
      return false;
    }
    final last = previous.lines.last.bounds;
    final first = next.lines.first.bounds;
    return last.bottom > .65 &&
        first.top < .35 &&
        last.width > .48 &&
        (first.left - last.left).abs() <= .025;
  }

  /// Map a position in a joined paragraph back to its original PDF block.
  static ({String blockId, int offset})? sourcePosition(
    XiaoqiDocument document,
    String? blockId,
    int offset,
  ) {
    if (blockId == null) return null;
    for (final block in document.chapters.first.blocks) {
      if (block.id != blockId) continue;
      var id = blockId;
      var base = 0;
      for (final entry in block.attributes.entries) {
        if (!entry.key.startsWith('pdf-page-')) continue;
        final start = int.parse(entry.value);
        if (start > offset) break;
        id = entry.key;
        base = start;
      }
      return (blockId: id, offset: offset - base);
    }
    return null;
  }

  /// Map an original PDF block to its containing paragraph in this window.
  static ({String blockId, int offset})? displayPosition(
    XiaoqiDocument document,
    String? blockId,
    int offset,
  ) {
    if (blockId == null) return null;
    for (final block in document.chapters.first.blocks) {
      if (block.id == blockId) return (blockId: blockId, offset: offset);
      final base = int.tryParse(block.attributes[blockId] ?? '');
      if (base != null) return (blockId: block.id, offset: base + offset);
    }
    return null;
  }

  static int? pageForBlock(String? blockId) {
    final match = blockId == null ? null : _pageInBlock.firstMatch(blockId);
    return int.tryParse(match?.group(1) ?? '');
  }

  static final _pageInBlock = RegExp(r'^pdf-page-(\d+)-(?:line|image)-');
}

class _ReflowParagraph {
  _ReflowParagraph(this.id, CompanionReflowLine first)
    : body = StringBuffer(first.text),
      lines = [(line: first, offset: 0)];

  final String id;
  final StringBuffer body;
  final List<({CompanionReflowLine line, int offset})> lines;
  static final _eastAsian = RegExp(
    r'[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]',
  );
  static String separator(String previous, String next) {
    final last = previous.substring(previous.length - 1);
    final first = next.substring(0, 1);
    if (_eastAsian.hasMatch(last) ||
        _eastAsian.hasMatch(first) ||
        '([{-/'.contains(last) ||
        '.,;:!?)]}'.contains(first)) {
      return '';
    }
    return ' ';
  }

  void append(CompanionReflowLine line) {
    final previous = lines.last.line.text;
    body.write(separator(previous, line.text));
    lines.add((line: line, offset: body.length));
    body.write(line.text);
  }
}

class CompanionPagePicture {
  const CompanionPagePicture(this.bounds, this.aspectRatio, this.asset);
  final Rect bounds;
  final double aspectRatio;
  final XiaoqiDocumentAsset asset;
  Map<String, dynamic> toJson() => {
    'box': [bounds.left, bounds.top, bounds.right, bounds.bottom],
    'aspect': aspectRatio,
    'asset': asset.toMap(),
  };
  factory CompanionPagePicture.fromJson(Map<String, dynamic> map) {
    final box = (map['box'] as List).cast<num>();
    return CompanionPagePicture(
      Rect.fromLTRB(
        box[0].toDouble(),
        box[1].toDouble(),
        box[2].toDouble(),
        box[3].toDouble(),
      ),
      (map['aspect'] as num).toDouble(),
      XiaoqiDocumentAsset.fromMap(map['asset'] as Map<String, dynamic>),
    );
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
  int _cachedImageBytes = 0;
  final _jobs = <int, _ReflowJob>{};
  int _sequence = 0;
  late final Future<Directory> _directory = getTemporaryDirectory().then(
    (root) => Directory(
      '${root.path}${Platform.pathSeparator}companion-reflow-v2${Platform.pathSeparator}$_cacheKey',
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
          final cached = await _decodeCache(cacheFile, number);
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
      PdfPageText? structured;
      try {
        structured = await original.loadStructuredText();
      } on Exception {
        // Broken text maps still have a readable rendered page.
      }
      if (job.cancelled) return null;
      final lines = structured == null
          ? <CompanionReflowLine>[]
          : _nativeLines(page, structured);
      const whole = Rect.fromLTWH(0, 0, 1, 1);
      final canRecognize = Platform.isAndroid || Platform.isIOS;
      var keepOriginal =
          structured?.fragments.any(
            (fragment) =>
                fragment.direction == PdfTextDirection.vrtl ||
                fragment.direction == PdfTextDirection.rtl,
          ) ??
          false;
      var persistResult = true;
      final corruptGlyphs = RegExp(r'[\u0000\ufffd-\uffff\ue000-\uf8ff]');
      if (lines.any((line) => corruptGlyphs.hasMatch(line.text))) {
        // Encoding defects can affect part of a page. Retain valid native
        // lines, and keep the rest of the printed area available as pixels.
        lines.removeWhere((line) => corruptGlyphs.hasMatch(line.text));
      }
      List<Rect> regions = await _pictureRegions(page, lines, job);
      if (canRecognize &&
          !job.cancelled &&
          !keepOriginal &&
          regions.isNotEmpty) {
        final captions = lines.where(
          (line) => CompanionReflowPage._caption.hasMatch(line.text),
        );
        final missing = regions
            .where(
              (r) =>
                  r.width >= .35 &&
                  r.height >= .075 &&
                  !captions.any(
                    (line) =>
                        (line.bounds.top - r.bottom).abs() < .06 ||
                        (line.bounds.bottom - r.top).abs() < .04,
                  ),
            )
            .toList();
        var added = false;
        try {
          for (final region in missing) {
            if (job.cancelled) return null;
            final recognized = await _recognize(page, job, region);
            if (!recognized.reliable ||
                (region != whole &&
                    recognized.lines
                            .where((line) => line.text.trim().length >= 6)
                            .length <
                        2)) {
              continue;
            }
            for (final line in recognized.lines) {
              if (!lines.any((native) => _duplicates(native, line))) {
                lines.add(line);
                added = true;
              }
            }
          }
          if (added) {
            lines.sort(_readingOrder);
            regions = await _pictureRegions(page, lines, job);
          }
        } on FastOcrUnavailableException {
          // Preserve the missing region as a picture, retry after models update.
          persistResult = false;
        } on FastOcrCancelledException {
          return null;
        } on Exception {
          // A transient OCR or raster I/O failure must not hide the source.
          persistResult = false;
        }
      }
      if (job.cancelled) return null;
      lines.sort(_readingOrder);
      keepOriginal =
          keepOriginal ||
          lines.isEmpty ||
          _isComplex(
            lines
                .where(
                  (line) => !regions.any(
                    (region) => region.contains(line.bounds.center),
                  ),
                )
                .toList(),
          );
      if (regions.contains(whole)) keepOriginal = true;
      final pictures = <CompanionPagePicture>[];
      for (final region in keepOriginal ? [whole] : regions) {
        if (job.cancelled) return null;
        final picture = await _picture(
          page,
          region,
          number,
          pictures.length,
          job,
        );
        if (picture == null) {
          if (job.cancelled) return null;
          return CompanionReflowPage(number, lines, keepOriginal: true);
        }
        pictures.add(picture);
      }
      if (job.cancelled) return null;
      final result = CompanionReflowPage(
        number,
        List.unmodifiable(lines),
        keepOriginal: keepOriginal,
        pictures: List.unmodifiable(pictures),
      );
      if (persistResult) {
        _remember(result);
        if (cacheFile != null) unawaited(_saveCache(cacheFile, result, job.id));
      }
      return result;
    });
  }

  CompanionReflowPage _remember(CompanionReflowPage result) {
    final old = _results.remove(result.number);
    _cachedImageBytes -= old?.imageByteCount ?? 0;
    final bytes = result.imageByteCount;
    while (_results.isNotEmpty &&
        (_results.length >= 24 ||
            _cachedImageBytes + bytes > 32 * 1024 * 1024)) {
      _cachedImageBytes -= _results.remove(_results.keys.first)!.imageByteCount;
    }
    _cachedImageBytes += bytes;
    return _results[result.number] = result;
  }

  static Future<CompanionReflowPage> _decodeCache(File file, int number) async {
    final encoded = await file.readAsString();
    CompanionReflowPage decode() {
      final data = jsonDecode(encoded) as Map;
      return CompanionReflowPage(
        number,
        (data['lines'] as List)
            .map((row) => CompanionReflowLine.fromJson(row as List))
            .toList(growable: false),
        keepOriginal: data['keepOriginal'] == true,
        pictures: (data['pictures'] as List)
            .map(
              (item) =>
                  CompanionPagePicture.fromJson(item as Map<String, dynamic>),
            )
            .toList(growable: false),
      );
    }

    // A scanned original can be several MB; base64 and JSON must not steal
    // a reader frame when the next page comes from the disk cache.
    return encoded.length > 64 * 1024 ? Isolate.run(decode) : decode();
  }

  Future<void> _saveCache(
    File cache,
    CompanionReflowPage result,
    String id,
  ) async {
    final staging = File('${cache.path}.$id.tmp');
    try {
      String encode() => jsonEncode({
        'keepOriginal': result.keepOriginal,
        'pictures': result.pictures.map((picture) => picture.toJson()).toList(),
        'lines': result.lines.map((line) => line.toJson()).toList(),
      });
      final payload = result.pictures.isEmpty
          ? encode()
          : await Isolate.run(encode);
      await staging.writeAsString(payload);
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

  static int _readingOrder(CompanionReflowLine a, CompanionReflowLine b) {
    final top = a.bounds.top.compareTo(b.bounds.top);
    return top == 0 ? a.bounds.left.compareTo(b.bounds.left) : top;
  }

  // PDFium's word fragments retain their character spans. Build rows by
  // baseline and order fragments within each row, keeping large gutters intact.
  static List<CompanionReflowLine> _nativeLines(PdfPage page, PdfPageText raw) {
    final words = <({PdfPageTextFragment run, Rect box})>[];
    for (final fragment in raw.fragments) {
      if (fragment.text.trim().isEmpty || fragment.bounds.isEmpty) continue;
      final box = fragment.bounds.toRect(page: page);
      words.add((run: fragment, box: box));
    }
    words.sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));
    final result = <CompanionReflowLine>[];
    for (var start = 0; start < words.length;) {
      final first = words[start];
      var end = start + 1;
      while (end < words.length &&
          (words[end].box.center.dy - first.box.center.dy).abs() <
              math.min(first.box.height, words[end].box.height) * .45) {
        end++;
      }
      final row = words.sublist(start, end)
        ..sort((a, b) => a.box.left.compareTo(b.box.left));
      Rect? box;
      var text = StringBuffer();
      PdfPageTextFragment? previous;
      void finish() {
        if (box == null || text.isEmpty) return;
        result.add(
          CompanionReflowLine(
            text.toString().trim(),
            Rect.fromLTRB(
              box.left / page.width,
              box.top / page.height,
              box.right / page.width,
              box.bottom / page.height,
            ),
          ),
        );
      }

      for (final word in row) {
        if (box != null &&
            word.box.left - box.right >
                math.max(page.width * .032, word.box.height * 1.7)) {
          finish();
          box = null;
          previous = null;
          text = StringBuffer();
        }
        if (previous != null) {
          final gap = word.run.index >= previous.end
              ? raw.fullText.substring(previous.end, word.run.index)
              : '';
          if (gap.isNotEmpty && gap.trim().isEmpty) {
            text.write(
              gap.contains('\n') || gap.contains('\r')
                  ? _ReflowParagraph.separator(
                      previous.text.trim(),
                      word.run.text.trim(),
                    )
                  : gap,
            );
          } else if (box != null &&
              word.box.left - box.right > word.box.height * .18) {
            text.write(
              _ReflowParagraph.separator(
                previous.text.trim(),
                word.run.text.trim(),
              ),
            );
          }
        }
        box = box?.expandToInclude(word.box) ?? word.box;
        text.write(word.run.text.trim());
        previous = word.run;
      }
      finish();
      start = end;
    }
    return result..sort(_readingOrder);
  }

  // Recover diagrams made from paths as well as embedded bitmaps. Sparse thin
  // lines may be all that connects a tree, so also use an adjacent caption to
  // enclose the original figure, including any native text inside its boxes.
  Future<List<Rect>> _pictureRegions(
    PdfPage page,
    List<CompanionReflowLine> lines,
    _ReflowJob job,
  ) async {
    const whole = Rect.fromLTWH(0, 0, 1, 1);
    if (lines.isEmpty) return [whole];
    final image = await _render(page, job, 448);
    if (image == null) return [whole];
    late final List<Rect> bands;
    try {
      bands = await _scanUncoveredInk(image, lines);
    } finally {
      image.dispose();
    }
    if (job.cancelled) return [];
    final regions = bands
        .where(
          (b) =>
              (b.height >= .022 && b.width >= .04) ||
              (b.width >= .20 && b.height >= .004),
        )
        .toList();
    if (regions.any((r) => r.height > .84 && r.width > .85)) return [whole];
    for (var i = 0; i < lines.length; i++) {
      final caption = lines[i];
      if (!CompanionReflowPage._caption.hasMatch(caption.text)) continue;
      if (i == 0) continue;
      final preceding = lines
          .take(i)
          .where(
            (line) =>
                line.bounds.width > .4 &&
                line.text.length > 12 &&
                line.bounds.bottom <= caption.bounds.top,
          );
      final top = preceding.isEmpty ? 0.0 : preceding.last.bounds.bottom;
      final bottom = caption.bounds.top;
      if (bottom - top < .055 || bottom - top > .6) continue;
      final nearby = bands
          .where((b) => b.center.dy > top && b.center.dy < bottom)
          .toList();
      if (nearby.isEmpty) continue;
      var bounds = nearby.reduce((a, b) => a.expandToInclude(b));
      for (final line in lines) {
        if (line.bounds.center.dy > top && line.bounds.center.dy < bottom) {
          bounds = bounds.expandToInclude(line.bounds);
        }
      }
      regions.add(bounds);
    }
    regions.sort((a, b) => a.top.compareTo(b.top));
    final result = <Rect>[];
    for (final region in regions) {
      // Keep every native word whose glyphs touch this raster band on a single
      // side of the boundary. It either remains readable text or is in the crop.
      var box = region.inflate(.004).intersect(whole);
      for (final line in lines) {
        if (line.bounds.overlaps(box)) box = box.expandToInclude(line.bounds);
      }
      box = box.inflate(.002).intersect(whole);
      if (result.isNotEmpty && result.last.bottom >= box.top) {
        result.last = result.last.expandToInclude(box);
      } else {
        result.add(box);
      }
    }
    return result;
  }

  // Pass just raster bytes and text bounds to the worker, never the native image.
  static Future<List<Rect>> _scanUncoveredInk(
    PdfImage image,
    List<CompanionReflowLine> lines,
  ) {
    return _scanBands(
      TransferableTypedData.fromList([image.pixels]),
      image.width,
      image.height,
      lines,
    );
  }

  static Future<List<Rect>> _scanBands(
    TransferableTypedData payload,
    int width,
    int height,
    List<CompanionReflowLine> lines,
  ) => Isolate.run(() {
    final pixels = payload.materialize().asUint8List();
    final bands = <Rect>[];
    for (var y = 0; y < height; y++) {
      final dy = (y + .5) / height;
      final covered = lines
          .where(
            (l) => dy >= l.bounds.top - .003 && dy <= l.bounds.bottom + .003,
          )
          .toList();
      var left = width, right = -1, count = 0;
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        if (pixels[offset] > 227 &&
            pixels[offset + 1] > 227 &&
            pixels[offset + 2] > 227) {
          continue;
        }
        final dx = (x + .5) / width;
        if (covered.any(
          (l) => dx >= l.bounds.left - .005 && dx <= l.bounds.right + .005,
        )) {
          continue;
        }
        left = math.min(left, x);
        right = x;
        count++;
      }
      if (count == 0) continue;
      final row = Rect.fromLTRB(
        left / width,
        y / height,
        (right + 1) / width,
        (y + 1) / height,
      );
      if (bands.isNotEmpty && row.top - bands.last.bottom < .023) {
        bands.last = bands.last.expandToInclude(row);
      } else {
        bands.add(row);
      }
    }
    return bands;
  });

  Future<CompanionPagePicture?> _picture(
    PdfPage page,
    Rect region,
    int number,
    int index,
    _ReflowJob job,
  ) async {
    final raster = await _render(page, job, 1560, region: region);
    if (raster == null) return null;
    try {
      if (job.cancelled) return null;
      final bitmap = await raster.createImage();
      try {
        final png = await bitmap.toByteData(format: ImageByteFormat.png);
        if (png == null || job.cancelled) return null;
        final full = region == const Rect.fromLTWH(0, 0, 1, 1);
        return CompanionPagePicture(
          region,
          raster.width / raster.height,
          XiaoqiDocumentAsset(
            id: 'pdf-page-$number-image-$index',
            mimeType: 'image/png',
            bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            altText: full ? '第 $number 页原貌' : '第 $number 页原图',
            sourceLocator: 'page:$number',
          ),
        );
      } finally {
        bitmap.dispose();
      }
    } finally {
      raster.dispose();
    }
  }

  Future<PdfImage?> _render(
    PdfPage page,
    _ReflowJob job,
    double maxEdge, {
    Rect region = const Rect.fromLTWH(0, 0, 1, 1),
  }) {
    if (job.cancelled) return Future.value(null);
    final scale = maxEdge / math.max(page.width, page.height);
    final token = page.createCancellationToken();
    job.render = token;
    final width = math.max(1.0, (page.width * scale).roundToDouble());
    final height = math.max(1.0, (page.height * scale).roundToDouble());
    final x = (width * region.left).floor();
    final y = (height * region.top).floor();
    return page.render(
      fullWidth: width,
      fullHeight: height,
      x: x,
      y: y,
      width: math.max(1, (width * region.right).ceil() - x),
      height: math.max(1, (height * region.bottom).ceil() - y),
      backgroundColor: 0xffffffff,
      annotationRenderingMode: PdfAnnotationRenderingMode.none,
      cancellationToken: token,
    );
  }

  Future<({List<CompanionReflowLine> lines, bool reliable})> _recognize(
    PdfPage page,
    _ReflowJob job,
    Rect region,
  ) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}companion-${job.id}.png',
    );
    final raster = await _render(page, job, 2400, region: region);
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
            result.lines.isNotEmpty &&
            lowConfidence * 4 <= result.lines.length &&
            !result.lines.any(
              (line) => line.text.trim().isNotEmpty && line.confidence < .50,
            ),
        lines: [
          for (final line in result.lines)
            if (line.text.isNotEmpty &&
                line.width > 0 &&
                line.height > 0 &&
                line.confidence >= .50)
              CompanionReflowLine(
                line.text,
                Rect.fromLTRB(
                  region.left + region.width * line.left / result.imageWidth,
                  region.top + region.height * line.top / result.imageHeight,
                  region.left + region.width * line.right / result.imageWidth,
                  region.top + region.height * line.bottom / result.imageHeight,
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
