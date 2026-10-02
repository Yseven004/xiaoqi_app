import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/pdf_catalog.dart';
import '../plugins/document_recognition/fast_ocr_plugin.dart';

class PdfCatalogService {
  const PdfCatalogService();

  static const int maxPdfBytes = 512 * 1024 * 1024;
  static const double _recognitionWidth = 1400;
  static const double _maxRecognitionPixels = 12 * 1000 * 1000;
  static const double _maxRecognitionDimension = 8000;

  // Bump when extraction heuristics or fallback stages change. Existing PDF
  // sources are reprocessed lazily the next time the正文工作台 is opened.
  static const int parserVersion = 12;

  /// Defensive upper bound for malformed input. Normal documents are not
  /// forced into a fixed "part/chapter/section" depth; this only prevents an
  /// adversarial or corrupt outline from exhausting the reader UI.
  static const int maxCatalogDepth = 32;

  /// A scanned PDF has no text layer for the normal parser to inspect. Keep
  /// this fallback explicitly bounded and local-only: the caller supplies the
  /// physical pages, and [NativeFastOcrPlugin] never silently uploads them.
  static const int maxScannedCatalogPages = 24;

  /// Test seam for the pure hierarchy stage. Production parsing supplies the
  /// same fields from PDF text/OCR; exposing this small value object lets
  /// regression fixtures cover different document shapes without shipping
  /// copyrighted book pages in the repository.
  @visibleForTesting
  static List<int> resolveLevelsForTesting(
    Iterable<PdfCatalogLayoutSample> samples,
  ) {
    return const PdfCatalogService()._resolveCandidateLevels([
      for (final sample in samples)
        _CatalogCandidate(
          title: sample.title,
          level: 1,
          printedPage: sample.printedPage,
          sourcePdfPage: sample.sourcePdfPage,
          left: sample.left,
          top: sample.top,
          right: sample.right,
          bottom: sample.bottom,
        ),
    ]);
  }

  @visibleForTesting
  static List<String?> resolveParentIdsForTesting(
    Iterable<PdfCatalogLayoutSample> samples,
  ) {
    final list = samples.toList(growable: false);
    final candidates = [
      for (final sample in list)
        _CatalogCandidate(
          title: sample.title,
          level: 1,
          printedPage: sample.printedPage,
          sourcePdfPage: sample.sourcePdfPage,
          left: sample.left,
          top: sample.top,
          right: sample.right,
          bottom: sample.bottom,
        ),
    ];
    final levels = const PdfCatalogService()._resolveCandidateLevels(candidates);
    final stack = <String>[];
    final parents = <String?>[];
    for (var index = 0; index < candidates.length; index++) {
      final inferredLevel = levels[index];
      while (stack.length >= inferredLevel) {
        stack.removeLast();
      }
      parents.add(stack.isEmpty ? null : stack.last);
      stack.add('node:$index');
    }
    return parents;
  }

  Future<PdfCatalogParseResult> parse(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('PDF 文件不存在');
    if (await file.length() > maxPdfBytes) {
      throw const FormatException('PDF 文件过大，无法安全解析');
    }
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(filePath);
    try {
      List<PdfOutlineNode> outline = const [];
      try {
        outline = await document.loadOutline();
      } catch (_) {
        // A malformed optional outline must not prevent text extraction.
      }
      final outlineEntries = <PdfCatalogEntry>[];
      _flattenOutline(outline, outlineEntries);
      // Some PDFs contain a title-only outline whose destinations are all
      // missing. Do not let that empty shell suppress the text fallback.
      if (outlineEntries.any((entry) => entry.pdfPage != null)) {
        return PdfCatalogParseResult(
          pageCount: document.pages.length,
          entries: outlineEntries,
          sourceKind: 'pdf_outline',
        );
      }

      final textResult = await _parseTextToc(document);
      return textResult;
    } finally {
      await document.dispose();
    }
  }

  /// Renders one PDF page to an app-private image so the existing document
  /// recognition/editor path can operate on scanned pages as well as text PDFs.
  Future<String> renderPageForEditing(
    String filePath,
    int pageNumber,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('PDF 文件不存在');
    if (await file.length() > maxPdfBytes) {
      throw const FormatException('PDF 文件过大，无法安全渲染');
    }
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(filePath);
    try {
      if (pageNumber < 1 || pageNumber > document.pages.length) {
        throw RangeError('PDF 第 $pageNumber 页不存在');
      }
      return _renderPageForRecognition(
        document.pages[pageNumber - 1],
        pageNumber,
        directoryName: 'pdf_edit_temp',
        filePrefix: 'edit',
      );
    } finally {
      await document.dispose();
    }
  }

  void _flattenOutline(
    List<PdfOutlineNode> nodes,
    List<PdfCatalogEntry> output, {
    int level = 1,
    String? parentId,
  }) {
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final title = _normalizeWhitespace(node.title);
      final id = 'outline:$level:$index:${node.dest?.pageNumber ?? 0}:$title';
      if (title.isNotEmpty) {
        output.add(
          PdfCatalogEntry(
            id: id,
            title: title,
            level: level,
            pdfPage: node.dest?.pageNumber,
            parentId: parentId,
            nodeType: level == 1 ? 'chapter' : 'section',
            order: output.length,
            sourceKind: 'pdf_outline',
            status: node.dest == null ? 'needs_review' : 'candidate',
          ),
        );
      }
      if (node.children.isNotEmpty) {
        _flattenOutline(
          node.children,
          output,
          level: level + 1,
          parentId: title.isEmpty ? parentId : id,
        );
      }
    }
  }

  Future<PdfCatalogParseResult> _parseTextToc(PdfDocument document) async {
    final candidates = <_CatalogCandidate>[];
    var tocPage = -1;
    var hasTextLayer = false;
    // Most books place the contents near the front. Keep a generous upper
    // bound for long prefaces, but stop as soon as two pages contain no TOC
    // lines so ordinary books still finish after a handful of page batches.
    final pageLimit = document.pages.length.clamp(1, 48).toInt();
    var emptyPagesAfterToc = 0;
    var stop = false;
    for (var batchStart = 0; batchStart < pageLimit && !stop; batchStart += 4) {
      final batchEnd = (batchStart + 4).clamp(0, pageLimit).toInt();
      final structuredPages = await Future.wait<PdfPageText?>([
        for (var index = batchStart; index < batchEnd; index++)
          _loadStructuredText(document.pages[index]),
      ]);
      for (
        var batchIndex = 0;
        batchIndex < structuredPages.length;
        batchIndex++
      ) {
        final index = batchStart + batchIndex;
        final structured = structuredPages[batchIndex];
        final raw = structured == null
            ? await _loadRawText(document.pages[index])
            : null;
        if (structured != null &&
            (structured.fullText.trim().isNotEmpty ||
                structured.fragments.isNotEmpty)) {
          hasTextLayer = true;
        }
        if (raw != null && raw.fullText.trim().isNotEmpty) {
          hasTextLayer = true;
        }
        final structuredLines = structured == null
            ? const <_CatalogOcrLine>[]
            : _linesFromStructuredText(structured);
        final lines = structured == null
            ? raw?.fullText.split(RegExp(r'\r?\n')) ?? const <String>[]
            : structuredLines.map((line) => line.text).toList(growable: false);
        final body = lines.join('\n');
        final marker = RegExp(
          r'目\s*录|目次|contents|table\s+of\s+contents',
          caseSensitive: false,
        ).hasMatch(body);
        final catalogLike =
            marker || tocPage >= 0 || _looksLikeCatalogPage(lines);
        final pageCandidates = structured == null
            ? _parseCandidateLines(lines, allowUnnumbered: catalogLike)
            : _parseCandidateLinesWithGeometry(
                structuredLines,
                allowUnnumbered: catalogLike,
              );
        if (marker) tocPage = tocPage < 0 ? index : tocPage;
        final hasCatalogLines =
            pageCandidates.isNotEmpty &&
            (tocPage >= 0 || pageCandidates.length >= 3);
        if (hasCatalogLines) {
          tocPage = tocPage < 0 ? index : tocPage;
          candidates.addAll([
            for (var candidateIndex = 0;
                candidateIndex < pageCandidates.length;
                candidateIndex++)
              pageCandidates[candidateIndex].copyWith(
                sourcePdfPage: index + 1,
                sequence: candidates.length + candidateIndex,
              ),
          ]);
          emptyPagesAfterToc = 0;
        } else if (tocPage >= 0) {
          emptyPagesAfterToc++;
          if (emptyPagesAfterToc >= 2) stop = true;
        }
        if (candidates.length >= 200) {
          stop = true;
        }
      }
    }
    if (candidates.isEmpty) {
      return PdfCatalogParseResult(
        pageCount: document.pages.length,
        entries: const [],
        sourceKind: hasTextLayer ? 'text_no_toc' : 'no_text_layer',
      );
    }

    final entries = _estimateCandidatesToBodyPages(
      document,
      candidates,
      tocPage: tocPage,
    );
    return PdfCatalogParseResult(
      pageCount: document.pages.length,
      entries: entries,
      sourceKind: 'toc_text_candidate',
    );
  }

  /// Recognizes only the user-selected image pages of a scanned PDF, plus a
  /// small bounded tail used to calibrate printed page numbers.
  ///
  /// The result is still a candidate catalog. Page numbers are mapped to PDF
  /// pages only when at least two recognized chapter anchors agree on the same
  /// offset; otherwise entries remain explicitly reviewable.
  Future<PdfCatalogParseResult> parseScannedCatalog(
    String filePath, {
    required List<int> pageNumbers,
    void Function(int completed, int total)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('PDF 文件不存在');
    final selected = pageNumbers.toSet().where((page) => page > 0).toList()
      ..sort();
    if (selected.isEmpty) throw ArgumentError('至少选择一页目录图片');
    if (selected.length > maxScannedCatalogPages) {
      throw ArgumentError('目录识别最多处理 $maxScannedCatalogPages 页');
    }

    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(filePath);
    final pageCount = document.pages.length;
    final selectedPages = selected
        .where((page) => page <= pageCount)
        .toList(growable: false);
    if (selectedPages.length != selected.length) {
      await document.dispose();
      throw ArgumentError('选择的 PDF 页码超出范围（共 $pageCount 页）');
    }
    if (selectedPages.isEmpty) {
      await document.dispose();
      throw ArgumentError('选择的 PDF 页码超出范围');
    }
    final calibrationEnd = (selectedPages.last + 8).clamp(1, pageCount);
    final scanPages = <int>{
      ...selectedPages,
      for (var page = selectedPages.last + 1;
          page <= calibrationEnd;
          page++)
        page,
    }.toList()..sort();

    final recognizer = NativeFastOcrPlugin();
    final candidates = <_CatalogCandidate>[];
    final pageTexts = <int, String>{};
    final tocPages = <int>{};
    var tocStarted = false;
    var tocEnded = false;
    var emptyPagesAfterToc = 0;
    var completed = 0;
    try {
      for (final pageNumber in scanPages) {
        final imagePath = await _renderPageForRecognition(
          document.pages[pageNumber - 1],
          pageNumber,
        );
        try {
          final recognition = await recognizer.recognize(imagePath);
          final lines = _recognitionLines(recognition);
          final body = lines.map((line) => line.text).join('\n');
          pageTexts[pageNumber] = body;
          final marker = RegExp(
            r'目\s*录|目次|contents|table\s+of\s+contents',
            caseSensitive: false,
          ).hasMatch(body);
          final pageCandidates = _parseScannedCandidateLines(
            lines,
            hasMarker: marker,
            inCatalog: tocStarted && !tocEnded,
          );
          final catalogLike = marker || _looksLikeCatalogPage(
            lines.map((line) => line.text),
          );
          final hasChapterHeading = pageCandidates.any(
            (candidate) =>
                _nodeTypeForTitle(candidate.title) == 'part' ||
                _nodeTypeForTitle(candidate.title) == 'chapter',
          );
          if (!tocStarted &&
              (marker ||
                  (pageCandidates.length >= 3 &&
                      (hasChapterHeading || catalogLike)))) {
            tocStarted = true;
          }
          if (tocStarted && !tocEnded) {
            if (pageCandidates.isNotEmpty) {
              tocPages.add(pageNumber);
              emptyPagesAfterToc = 0;
              candidates.addAll([
                for (var index = 0; index < pageCandidates.length; index++)
                  pageCandidates[index].copyWith(
                    sourcePdfPage: pageNumber,
                    sourceKind: 'scanned_catalog_ocr',
                    sequence: candidates.length + index,
                  ),
              ]);
            } else if (++emptyPagesAfterToc >= 2) {
              tocEnded = true;
            }
          }
        } finally {
          try {
            await File(imagePath).delete();
          } catch (_) {
            // The temporary image is best-effort cleanup only.
          }
        }
        completed++;
        onProgress?.call(completed, scanPages.length);
      }
    } finally {
      await document.dispose();
    }

    // Repeated titles and restarted page numbers are legal in real books.
    // Keep every source occurrence; de-duplicating by title/page silently
    // destroys valid siblings from different parts or appendices.
    final ordered = [...candidates]
      ..sort((a, b) {
        final page = (a.sourcePdfPage ?? 0).compareTo(b.sourcePdfPage ?? 0);
        if (page != 0) return page;
        return a.sequence.compareTo(b.sequence);
      });
    if (ordered.isEmpty) {
      return PdfCatalogParseResult(
        pageCount: pageCount,
        entries: const [],
        sourceKind: 'scanned_catalog_no_toc',
      );
    }

    final normalizedPages = <int, String>{
      for (final item in pageTexts.entries)
        if (!tocPages.contains(item.key))
          item.key: _normalizeForMatch(item.value),
    };
    final exactPages = <String, int>{};
    final votes = <int, int>{};
    for (final candidate in ordered) {
      final exact = _findPdfPage(candidate, normalizedPages);
      if (exact == null) continue;
      exactPages[_candidateKey(candidate)] = exact;
      if (candidate.printedPage != null) {
        final offset = exact - candidate.printedPage!;
        votes[offset] = (votes[offset] ?? 0) + 1;
      }
    }
    final inferredOffset = votes.isEmpty
        ? null
        : votes.entries.reduce(
            (left, right) => left.value >= right.value ? left : right,
          );
    final usableOffset = inferredOffset != null && inferredOffset.value >= 2
        ? inferredOffset.key
        : null;

    return PdfCatalogParseResult(
      pageCount: pageCount,
      entries: _buildScannedEntries(
        ordered,
        exactPages: exactPages,
        inferredOffset: usableOffset,
        pageCount: pageCount,
      ),
      sourceKind: 'scanned_catalog_ocr',
    );
  }

  List<PdfCatalogEntry> _buildScannedEntries(
    List<_CatalogCandidate> candidates, {
    required Map<String, int> exactPages,
    required int? inferredOffset,
    required int pageCount,
  }) {
    final levels = _resolveCandidateLevels(candidates);
    final entries = <PdfCatalogEntry>[];
    final stack = <String>[];
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final id = 'scan:${candidate.sourcePdfPage ?? 0}:$index:'
          '${candidate.printedPageLabel ?? candidate.printedPage ?? ''}';
      final nodeType = _nodeTypeForTitle(candidate.title);
      final inferredLevel = levels[index];
      while (stack.length >= inferredLevel) {
        stack.removeLast();
      }
      final level = stack.length + 1;
      final parentId = stack.isEmpty ? null : stack.last;
      stack.add(id);

      final exactPage = exactPages[_candidateKey(candidate)];
      int? pdfPage = exactPage;
      var status = exactPage == null ? 'needs_review' : 'candidate';
      if (pdfPage == null &&
          inferredOffset != null &&
          candidate.printedPage != null) {
        final estimated = candidate.printedPage! + inferredOffset;
        if (estimated >= 1 && estimated <= pageCount) {
          pdfPage = estimated;
          status = 'estimated';
        }
      }
      entries.add(
        PdfCatalogEntry(
          id: id,
          title: candidate.title,
          level: level,
          pdfPage: pdfPage,
          printedPage: candidate.printedPage,
          printedPageLabel: candidate.printedPageLabel,
          sourcePdfPage: candidate.sourcePdfPage,
          parentId: parentId,
          nodeType: nodeType,
          order: index,
          confidence: candidate.confidence.clamp(0, 1).toDouble(),
          sourceLeft: candidate.left,
          sourceTop: candidate.top,
          sourceRight: candidate.right,
          sourceBottom: candidate.bottom,
          sourceKind: candidate.sourceKind,
          status: status,
        ),
      );
    }
    return entries;
  }

  List<int> _buildIndentLevels(List<_CatalogCandidate> candidates) {
    final pageRight = <int, double>{};
    for (final candidate in candidates) {
      if (candidate.left <= 0) continue;
      final page = candidate.sourcePdfPage ?? 0;
      final right = candidate.right > candidate.left
          ? candidate.right
          : candidate.left + 1;
      pageRight[page] = (pageRight[page] ?? 0) > right
          ? pageRight[page]!
          : right;
    }
    final positions = <double>[];
    final normalized = <double?>[];
    for (final candidate in candidates) {
      if (candidate.left <= 0) {
        normalized.add(null);
        continue;
      }
      final width = pageRight[candidate.sourcePdfPage ?? 0] ?? 1;
      final value = (candidate.left / width).clamp(0, 1).toDouble();
      normalized.add(value);
      positions.add(value);
    }
    if (positions.isEmpty) {
      return [for (final _ in candidates) 1];
    }
    positions.sort();
    final clusters = <double>[];
    // Coordinates from different PDF pages are not comparable until they are
    // normalized. A relative threshold follows the page scale instead of a
    // fixed pixel value that changes with OCR render size.
    const tolerance = 0.022;
    for (final position in positions) {
      if (clusters.isEmpty || position - clusters.last > tolerance) {
        clusters.add(position);
      } else {
        clusters[clusters.length - 1] =
            (clusters.last + position) / 2;
      }
    }
    return [
      for (var index = 0; index < candidates.length; index++)
        normalized[index] == null
            ? 1
            : _nearestIndentCluster(normalized[index]!, clusters) + 1,
    ];
  }

  int _nearestIndentCluster(double left, List<double> clusters) {
    var best = 0;
    var distance = double.infinity;
    for (var index = 0; index < clusters.length; index++) {
      final candidateDistance = (clusters[index] - left).abs();
      if (candidateDistance < distance) {
        best = index;
        distance = candidateDistance;
      }
    }
    return best;
  }

  String _nodeTypeForTitle(String title) {
    final value = _compactCjkSpaces(_normalizeWhitespace(title));
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*[篇部]').hasMatch(
      value,
    )) {
      return 'part';
    }
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*章').hasMatch(
      value,
    )) {
      return 'chapter';
    }
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*节').hasMatch(
      value,
    )) {
      return 'section';
    }
    if (RegExp(r'^附录').hasMatch(value) ||
        RegExp(r'^(?:图表一览表|参考书目|词汇表|后记)').hasMatch(value)) {
      return 'appendix';
    }
    if (RegExp(r'^(?:代序|序|序言|前言)(?:$|[\s（(])').hasMatch(value)) {
      return 'front_matter';
    }
    if (RegExp(r'^引言(?:$|[\s（(])').hasMatch(value)) {
      // "引言" appears once under each part in the source catalog. Its
      // parent is decided from the surrounding part/chapter context below.
      return 'section';
    }
    return 'section';
  }

  List<int> _resolveCandidateLevels(List<_CatalogCandidate> candidates) {
    final indentLevels = _buildIndentLevels(candidates);
    final levels = <int>[];
    String? partId;
    String? chapterId;
    var partLevel = 1;
    var chapterLevel = 1;
    int? partIndent;
    int? chapterIndent;

    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final nodeType = _nodeTypeForTitle(candidate.title);
      final indent = indentLevels[index];
      final hasGeometry = candidate.left > 0;
      final id = '${candidate.sourcePdfPage ?? 0}:$index';
      var level = 1;

      if (nodeType == 'part') {
        level = 1;
        partId = id;
        partLevel = level;
        partIndent = hasGeometry ? indent : null;
        chapterId = null;
        chapterIndent = null;
      } else if (nodeType == 'chapter') {
        // A chapter is a top-level navigation item unless the source has
        // explicitly established a containing part. Do not turn a larger
        // page margin into a phantom hierarchy level.
        level = partId == null ? 1 : 2;
        level = level.clamp(1, maxCatalogDepth).toInt();
        chapterId = id;
        chapterLevel = level;
        chapterIndent = hasGeometry ? indent : null;
      } else if (nodeType == 'appendix' &&
          (!hasGeometry ||
              indent <= (chapterIndent ?? partIndent ?? 1))) {
        // A root appendix starts a new scope. Clear both structural anchors;
        // retaining the previous part would attach following entries to it.
        level = 1;
        partId = null;
        chapterId = null;
        partIndent = null;
        chapterIndent = null;
      } else if (hasGeometry && chapterId != null && chapterIndent != null) {
        // Map local layout indentation onto the current chapter scope. This
        // keeps a child on a continuation page under the same chapter even if
        // that page has a different left margin.
        level = chapterLevel +
            (indent - chapterIndent).clamp(1, maxCatalogDepth).toInt();
      } else if (hasGeometry && partId != null && partIndent != null) {
        level = partLevel +
            (indent - partIndent).clamp(1, maxCatalogDepth).toInt();
      } else {
        final explicit = _explicitCatalogLevel(candidate.title);
        final relative = explicit == null
            ? 1
            : chapterId != null
            ? (explicit - 1).clamp(1, maxCatalogDepth).toInt()
            : explicit;
        if (chapterId != null) {
          level = chapterLevel + relative;
        } else if (partId != null) {
          level = partLevel + relative;
        } else {
          level = explicit ?? indent;
        }
      }

      levels.add(level.clamp(1, maxCatalogDepth).toInt());
    }
    return levels;
  }

  int? _explicitCatalogLevel(String title) {
    final value = _compactCjkSpaces(_normalizeWhitespace(title));
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*[篇部]').hasMatch(value)) {
      return 1;
    }
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万]+\s*章').hasMatch(value)) {
      return 1;
    }
    final dotted = RegExp(r'^(\d+(?:\s*[.、]\s*\d+)*)\s*[.、]?').firstMatch(value);
    if (dotted != null) return RegExp(r'\d+').allMatches(dotted.group(1)!).length;
    if (RegExp(r'^[一二三四五六七八九十百千万]+[、.]').hasMatch(value)) {
      return 1;
    }
    return null;
  }

  Future<String> _renderPageForRecognition(
    PdfPage page,
    int pageNumber, {
    String directoryName = 'pdf_catalog_temp',
    String filePrefix = 'catalog',
  }) async {
    final sourceWidth = math.max(page.width, 1.0);
    final sourceHeight = math.max(page.height, 1.0);
    var scale = 1.0;
    final requestedHeight = _recognitionWidth * sourceHeight / sourceWidth;
    if (_recognitionWidth * requestedHeight > _maxRecognitionPixels) {
      scale = math.min(
        scale,
        math.sqrt(_maxRecognitionPixels /
            (_recognitionWidth * requestedHeight)),
      );
    }
    if (requestedHeight > _maxRecognitionDimension) {
      scale = math.min(scale, _maxRecognitionDimension / requestedHeight);
    }
    final width = math.max(1.0, _recognitionWidth * scale);
    final height = math.max(1.0, requestedHeight * scale);
    final rendered = await page.render(
      fullWidth: width,
      fullHeight: height,
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) throw StateError('PDF 第 $pageNumber 页无法渲染');
    try {
      final raster = img.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rendered.pixels.buffer,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory(p.join(root.path, directoryName));
      await directory.create(recursive: true);
      final path = p.join(
        directory.path,
        '${filePrefix}_${DateTime.now().microsecondsSinceEpoch}_$pageNumber.jpg',
      );
      await File(path).writeAsBytes(img.encodeJpg(raster, quality: 92));
      unawaited(_pruneRenderedPages(directory));
      return path;
    } finally {
      rendered.dispose();
    }
  }

  /// 每次渲染都会留下一个页面图片文件，而识别完成后没有别的地方会删除它。
  /// 设备上曾累积到 92 个文件 / 34MB，因此这里按时间清理自己生成的渲染图。
  ///
  /// 只处理本服务写出的 `edit_` / `catalog_` 前缀文件，并且保留最近
  /// [_renderedPageKeepCount] 个文件不受时间限制，避免误删正在使用的渲染图。
  static const int _renderedPageKeepCount = 20;
  static const Duration _renderedPageMaxAge = Duration(days: 3);
  static DateTime? _lastRenderedPagePrune;

  Future<void> _pruneRenderedPages(Directory directory) async {
    final now = DateTime.now();
    final last = _lastRenderedPagePrune;
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastRenderedPagePrune = now;
    try {
      final files = <File>[];
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('edit_') && !name.startsWith('catalog_')) {
          continue;
        }
        files.add(entity);
      }
      if (files.length <= _renderedPageKeepCount) return;
      final stats = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          stats.add(MapEntry(file, (await file.stat()).modified));
        } on Object catch (_) {
          // 文件在扫描过程中消失时忽略即可。
        }
      }
      stats.sort((a, b) => b.value.compareTo(a.value));
      for (final entry in stats.skip(_renderedPageKeepCount)) {
        if (now.difference(entry.value) < _renderedPageMaxAge) continue;
        try {
          await entry.key.delete();
        } on Object catch (_) {
          // 清理失败不影响识别流程。
        }
      }
    } on Object catch (_) {
      // 目录不存在或不可读时保持原样。
    }
  }

  List<_CatalogOcrLine> _recognitionLines(FastOcrResult result) {
    if (result.lines.isNotEmpty) {
      return [...result.lines]
          .where((line) => line.text.trim().isNotEmpty)
          .map(
            (line) => _CatalogOcrLine(
              text: _normalizeWhitespace(line.text),
              left: line.left,
              top: line.top,
              right: line.right,
              bottom: line.bottom,
              confidence: line.confidence,
            ),
          )
          .toList(growable: false);
    }
    return [
      for (final text in result.fullText.split(RegExp(r'\r?\n')))
        if (text.trim().isNotEmpty)
          _CatalogOcrLine(
            text: _normalizeWhitespace(text),
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
            confidence: 0,
          ),
    ];
  }

  List<_CatalogCandidate> _parseScannedCandidateLines(
    Iterable<_CatalogOcrLine> lines, {
    required bool hasMarker,
    required bool inCatalog,
  }) {
    final normalized = _orderScannedLines(lines)
        .where((line) => line.text.isNotEmpty)
        .toList(growable: false);
    final strict = _parseCandidateLines(normalized.map((line) => line.text));
    final catalogLike =
        hasMarker || _looksLikeCatalogPage(normalized.map((line) => line.text));
    final structuralHeading = normalized.any(
      (line) =>
          _nodeTypeForTitle(line.text) == 'part' ||
          _nodeTypeForTitle(line.text) == 'chapter',
    );
    // A contents page may contain only unnumbered headings. The marker is
    // sufficient evidence to parse those lines; requiring a numbered
    // chapter would reject perfectly valid one-level books.
    if (strict.isEmpty && !catalogLike && !inCatalog && !structuralHeading) {
      return const [];
    }
    return _parseCandidateLinesWithGeometry(
      normalized,
      allowUnnumbered: catalogLike || inCatalog,
    );
  }

  List<_CatalogOcrLine> _orderScannedLines(
    Iterable<_CatalogOcrLine> input,
  ) {
    final lines = input.toList(growable: false);
    final positioned = lines.where((line) => line.right > line.left).toList();
    if (positioned.length < 4) return lines;
    final sortedLeft = positioned.map((line) => line.left).toList()..sort();
    var largestGap = 0.0;
    var split = -1;
    for (var index = 1; index < sortedLeft.length; index++) {
      final gap = sortedLeft[index] - sortedLeft[index - 1];
      if (gap > largestGap) {
        largestGap = gap;
        split = index;
      }
    }
    final pageWidth = positioned.map((line) => line.right).reduce(
          (a, b) => a > b ? a : b,
        );
    // Treat a large horizontal gap as columns only when both sides have
    // enough lines. Indentation within one column should remain one stream.
    if (split <= 0 ||
        largestGap < pageWidth * .22 ||
        split < 2 ||
        sortedLeft.length - split < 2) {
      return lines;
    }
    final boundary = (sortedLeft[split - 1] + sortedLeft[split]) / 2;
    return [...lines]..sort((a, b) {
      final aColumn = a.left < boundary ? 0 : 1;
      final bColumn = b.left < boundary ? 0 : 1;
      if (aColumn != bColumn) return aColumn.compareTo(bColumn);
      final top = a.top.compareTo(b.top);
      return top == 0 ? a.left.compareTo(b.left) : top;
    });
  }

  String _candidateKey(_CatalogCandidate candidate) =>
      '${candidate.sourcePdfPage ?? 0}:${candidate.sequence}:'
      '${_normalizeForMatch(candidate.title)}:'
      '${candidate.printedPageLabel ?? candidate.printedPage ?? ''}';

  Future<PdfPageText?> _loadStructuredText(PdfPage page) async {
    try {
      return await page.loadStructuredText();
    } catch (_) {
      return null;
    }
  }

  List<_CatalogOcrLine> _linesFromStructuredText(PdfPageText pageText) {
    final lines = <_TextLine>[];
    final fragments =
        pageText.fragments
            .where((fragment) => fragment.text.trim().isNotEmpty)
            .toList(growable: false)
          ..sort((a, b) {
            final y = b.bounds.bottom.compareTo(a.bounds.bottom);
            return y == 0 ? a.bounds.left.compareTo(b.bounds.left) : y;
          });
    for (final fragment in fragments) {
      final baseline = fragment.bounds.bottom;
      _TextLine? line;
      for (final candidate in lines) {
        if ((candidate.baseline - baseline).abs() <= 4.5) {
          line = candidate;
          break;
        }
      }
      if (line == null) {
        lines.add(_TextLine(baseline, [fragment]));
      } else {
        line.fragments.add(fragment);
      }
    }
    lines.sort((a, b) => b.baseline.compareTo(a.baseline));
    return lines
        .map((line) {
          line.fragments.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
          final text = _normalizeWhitespace(
            line.fragments.map((item) => item.text).join(' '),
          );
          final first = line.fragments.first.bounds;
          final last = line.fragments.last.bounds;
          return _CatalogOcrLine(
            text: text,
            left: first.left,
            top: line.fragments
                .map((item) => item.bounds.top)
                .reduce((a, b) => a < b ? a : b),
            right: last.right,
            bottom: line.fragments
                .map((item) => item.bounds.bottom)
                .reduce((a, b) => a > b ? a : b),
            confidence: 1,
          );
        })
        .where((line) => line.text.isNotEmpty)
        .toList(growable: false);
  }

  List<_CatalogCandidate> _parseCandidateLinesWithGeometry(
    Iterable<_CatalogOcrLine> lines, {
    required bool allowUnnumbered,
  }) {
    final output = <_CatalogCandidate>[];
    for (final line in lines) {
      final pageOnly = _pageLabelPattern.firstMatch(line.text);
      if (pageOnly != null && output.isNotEmpty) {
        final previous = output.removeLast();
        if (previous.printedPage == null) {
          output.add(
            previous.copyWith(
              printedPage: _parsePageNumber(pageOnly.group(1)!),
              printedPageLabel: pageOnly.group(1),
            ),
          );
          continue;
        }
        output.add(previous);
      }
      final matches = _parseCandidateLines(
        [line.text],
        allowUnnumbered: allowUnnumbered,
      );
      output.addAll(
        matches.map(
          (candidate) => candidate.copyWith(
            nodeType: _nodeTypeForTitle(candidate.title),
            left: line.left,
            top: line.top,
            right: line.right,
            bottom: line.bottom,
            confidence: line.confidence,
          ),
        ),
      );
    }
    return output;
  }

  bool _looksLikeCatalogPage(Iterable<String> lines) {
    var matches = 0;
    for (final raw in lines) {
      final line = _normalizeWhitespace(raw);
      if (RegExp(r'(?:\.{2,}|\s+)(\d{1,4})$').hasMatch(line)) {
        matches++;
      }
    }
    return matches >= 3;
  }

  List<_CatalogCandidate> _parseCandidateLines(
    Iterable<String> lines, {
    bool allowUnnumbered = false,
  }) {
    final result = <_CatalogCandidate>[];
    for (final rawLine in lines) {
      final line = _compactCjkSpaces(_normalizeWhitespace(rawLine))
          .replaceAll(RegExp(r'[·•⋯…]+'), '...')
          .replaceAll(RegExp(r'[_＿]+'), '...');
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^((?:\d+\s*[.、]\s*)*\d+|\d+\s*[.、]|第\s*[0-9一二三四五六七八九十百千万]+\s*[章节篇部]|附录\s*[0-9一二三四五六七八九十百千万]+|[一二三四五六七八九十百千万]+[、.])\s*(.+?)(?:\s*\.{2,}\s*|\s{2,}|\s+)(\d{1,4})$',
      ).firstMatch(line);
      if (match == null) {
        // Some publishers omit printed page numbers or place them in a
        // separate text layer. Keep the chapter title as a reviewable
        // candidate instead of returning an empty catalog.
        final numberedWithoutPrefix = allowUnnumbered
            ? RegExp(
                r'^(.{1,160}?)(?:\s*\.{2,}\s*|\s{2,}|\s+)(\d{1,4})$',
              ).firstMatch(line)
            : null;
        if (numberedWithoutPrefix != null) {
          final titlePart = _normalizeWhitespace(
            numberedWithoutPrefix.group(1)!,
          );
          final printedPage = int.tryParse(numberedWithoutPrefix.group(2)!);
          if (titlePart.isNotEmpty && printedPage != null) {
            result.add(
              _CatalogCandidate(
                title: titlePart,
                level: 2,
                printedPage: printedPage,
                printedPageLabel: numberedWithoutPrefix.group(2),
              ),
            );
          }
          continue;
        }
        final heading = RegExp(
          r'^((?:\d+\s*[.、]\s*)*\d+|\d+\s*[.、]|第\s*[0-9一二三四五六七八九十百千万]+\s*[章节篇部]|附录\s*[0-9一二三四五六七八九十百千万]+|[一二三四五六七八九十百千万]+[、.])\s*(.{1,160})$',
        ).firstMatch(line);
        final unnumbered = allowUnnumbered &&
            !line.contains(RegExp(r'[。！？!?：:]')) &&
            line.length <= 36 &&
            !RegExp(
                    r'^目\s*录$|^目次$|^contents$|^table\s+of\s+contents$',
                    caseSensitive: false,
                  )
                .hasMatch(line);
        if (heading == null && !unnumbered) continue;
        final prefix = heading == null
            ? ''
            : _normalizeWhitespace(heading.group(1)!);
        final titlePart = heading == null
            ? line
            : _normalizeWhitespace(heading.group(2)!);
        if (titlePart.isEmpty || titlePart.length > 160) continue;
        result.add(
          _CatalogCandidate(
            title: prefix.isEmpty ? titlePart : '$prefix $titlePart',
            level: prefix.isEmpty ? 2 : 1,
            printedPage: null,
          ),
        );
        continue;
      }
      final prefix = _normalizeWhitespace(match.group(1)!);
      final titlePart = _normalizeWhitespace(match.group(2)!);
      if (titlePart.length < 1 || titlePart.length > 160) continue;
      final printedPage = int.tryParse(match.group(3)!);
      final level = prefix.startsWith('第')
          ? 1
          : '.'.allMatches(prefix).length + 1;
      result.add(
        _CatalogCandidate(
          title: '$prefix $titlePart',
          level: level.clamp(1, maxCatalogDepth).toInt(),
          printedPage: printedPage,
          printedPageLabel: match.group(3),
        ),
      );
    }
    return result;
  }

  List<PdfCatalogEntry> _estimateCandidatesToBodyPages(
    PdfDocument document,
    List<_CatalogCandidate> candidates, {
    required int tocPage,
  }) {
    int? firstPrinted;
    for (final candidate in candidates) {
      if (candidate.printedPage != null) {
        firstPrinted = candidate.printedPage;
        break;
      }
    }
    final inferredOffset = firstPrinted == null
        ? null
        : (tocPage < 0 ? 0 : tocPage + 2 - firstPrinted);
    final entries = <PdfCatalogEntry>[];
    final stack = <String>[];
    final levels = _resolveCandidateLevels(candidates);
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final nodeType = _nodeTypeForTitle(candidate.title);
      final inferredLevel = levels[index];
      while (stack.length >= inferredLevel) {
        stack.removeLast();
      }
      final level = stack.length + 1;
      final parentId = stack.isEmpty ? null : stack.last;
      final entry = _toEntry(
        candidate,
        index,
        exactPage: null,
        inferredOffset: inferredOffset,
        pageCount: document.pages.length,
        levelOverride: level,
        parentId: parentId,
        nodeType: nodeType,
        order: index,
      );
      entries.add(entry);
      stack.add(entry.id);
    }
    return entries;
  }

  /// Refines only a few anchor chapters around their estimated pages. This
  /// replaces the old O(book-page-count) scan with a bounded O(anchors × 17)
  /// lookup; the quick catalog remains usable if refinement is interrupted.
  Future<PdfCatalogParseResult> refine(
    String filePath,
    PdfCatalogParseResult initial,
  ) async {
    if (initial.sourceKind == 'pdf_outline' || initial.entries.isEmpty) {
      return initial;
    }
    final anchorIndexes =
        <int>{0, initial.entries.length ~/ 2, initial.entries.length - 1}
            .where((index) {
              final entry = initial.entries[index];
              return entry.printedPage != null && entry.pdfPage != null;
            })
            .toList(growable: false);
    if (anchorIndexes.length < 2) return initial;

    final file = File(filePath);
    if (!await file.exists()) throw StateError('PDF 文件不存在');
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(filePath);
    try {
      final votes = <int, int>{};
      final exactAnchorIds = <String>{};
      for (final index in anchorIndexes) {
        final anchor = initial.entries[index];
        final foundPage = await _findPdfPageNear(
          document,
          anchor.title,
          anchor.pdfPage!,
        );
        if (foundPage == null) continue;
        final offset = foundPage - anchor.printedPage!;
        votes[offset] = (votes[offset] ?? 0) + 1;
        exactAnchorIds.add(anchor.id);
      }
      if (votes.isEmpty) return initial;
      final best = votes.entries.reduce(
        (left, right) => left.value >= right.value ? left : right,
      );
      if (best.value < 2) return initial;

      final entries = [
        for (final entry in initial.entries)
          if (entry.printedPage == null)
            entry
          else
            PdfCatalogEntry(
              id: entry.id,
              title: entry.title,
              level: entry.level.clamp(1, maxCatalogDepth).toInt(),
              pdfPage: (entry.printedPage! + best.key)
                  .clamp(1, document.pages.length)
                  .toInt(),
              printedPage: entry.printedPage,
              printedPageLabel: entry.printedPageLabel,
              sourcePdfPage: entry.sourcePdfPage,
              parentId: entry.parentId,
              nodeType: entry.nodeType,
              order: entry.order,
              pdfEndPage: entry.pdfEndPage,
              confidence: entry.confidence,
              sourceLeft: entry.sourceLeft,
              sourceTop: entry.sourceTop,
              sourceRight: entry.sourceRight,
              sourceBottom: entry.sourceBottom,
              sourceKind: entry.sourceKind,
              status: exactAnchorIds.contains(entry.id)
                  ? 'candidate'
                  : 'estimated',
            ),
      ];
      return PdfCatalogParseResult(
        pageCount: document.pages.length,
        entries: entries,
        sourceKind: initial.sourceKind,
      );
    } finally {
      await document.dispose();
    }
  }

  Future<int?> _findPdfPageNear(
    PdfDocument document,
    String title,
    int estimatedPage,
  ) async {
    final start = (estimatedPage - 8).clamp(1, document.pages.length).toInt();
    final end = (estimatedPage + 8).clamp(1, document.pages.length).toInt();
    final normalizedPages = <int, String>{};
    for (var batchStart = start; batchStart <= end; batchStart += 4) {
      final batchEnd = (batchStart + 4).clamp(start, end + 1).toInt();
      final texts = await Future.wait<PdfPageRawText?>([
        for (var page = batchStart; page < batchEnd; page++)
          _loadRawText(document.pages[page - 1]),
      ]);
      for (var index = 0; index < texts.length; index++) {
        final text = texts[index];
        if (text == null) continue;
        final body = _normalizeForMatch(text.fullText);
        if (body.isNotEmpty) normalizedPages[batchStart + index] = body;
      }
    }
    final candidate = _CatalogCandidate(
      title: title,
      level: 1,
      printedPage: null,
    );
    return _findPdfPage(candidate, normalizedPages);
  }

  Future<PdfPageRawText?> _loadRawText(PdfPage page) async {
    try {
      return await page.loadText();
    } catch (_) {
      return null;
    }
  }

  PdfCatalogEntry _toEntry(
    _CatalogCandidate candidate,
    int index, {
    required int? exactPage,
    required int? inferredOffset,
    required int pageCount,
    int? levelOverride,
    String? parentId,
    String? nodeType,
    int? order,
  }) {
    var pdfPage = exactPage;
    var status = 'candidate';
    if (pdfPage == null &&
        inferredOffset != null &&
        candidate.printedPage != null) {
      final estimated = candidate.printedPage! + inferredOffset;
      if (estimated >= 1 && estimated <= pageCount) {
        pdfPage = estimated;
        status = 'estimated';
      }
    }
    return PdfCatalogEntry(
      id:
          'text:${candidate.sourcePdfPage ?? 0}:$index:${candidate.sequence}:${candidate.title}',
      title: candidate.title,
      level: levelOverride ?? candidate.level,
      pdfPage: pdfPage,
      printedPage: candidate.printedPage,
      printedPageLabel: candidate.printedPageLabel,
      sourcePdfPage: candidate.sourcePdfPage,
      parentId: parentId,
      nodeType: nodeType ?? candidate.nodeType,
      order: order ?? index,
      confidence: candidate.confidence.clamp(0, 1).toDouble(),
      sourceLeft: candidate.left,
      sourceTop: candidate.top,
      sourceRight: candidate.right,
      sourceBottom: candidate.bottom,
      sourceKind: candidate.sourceKind,
      status: pdfPage == null ? 'needs_review' : status,
    );
  }

  int? _findPdfPage(
    _CatalogCandidate candidate,
    Map<int, String> normalizedPages,
  ) {
    final needle = _normalizeForMatch(candidate.title);
    final bareNeedle = _normalizeForMatch(
      candidate.title.replaceFirst(
        RegExp(r'^(?:第[^ ]+[章节篇部]|[\d.、]+|[一二三四五六七八九十百千万]+[、.])'),
        '',
      ),
    );
    for (final page in normalizedPages.entries) {
      if (page.value.contains(needle) ||
          (bareNeedle.length >= 3 && page.value.contains(bareNeedle))) {
        return page.key;
      }
    }
    return null;
  }
}

class _CatalogOcrLine {
  const _CatalogOcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;

  double get height => (bottom - top).clamp(0, double.infinity).toDouble();
}

class PdfCatalogLayoutSample {
  const PdfCatalogLayoutSample({
    required this.title,
    this.sourcePdfPage,
    this.printedPage,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final String title;
  final int? sourcePdfPage;
  final int? printedPage;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class _TextLine {
  _TextLine(this.baseline, this.fragments);

  final double baseline;
  final List<PdfPageTextFragment> fragments;
}

class _CatalogCandidate {
  const _CatalogCandidate({
    required this.title,
    required this.level,
    required this.printedPage,
    this.printedPageLabel,
    this.sourcePdfPage,
    this.nodeType = 'section',
    this.sourceKind = 'toc_text_candidate',
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.confidence = 0,
    this.sequence = 0,
  });

  final String title;
  final int level;
  final int? printedPage;
  final String? printedPageLabel;
  final int? sourcePdfPage;
  final String nodeType;
  final String sourceKind;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final int sequence;

  _CatalogCandidate copyWith({
    int? printedPage,
    String? printedPageLabel,
    int? sourcePdfPage,
    String? nodeType,
    String? sourceKind,
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? confidence,
    int? sequence,
  }) =>
      _CatalogCandidate(
        title: title,
        level: level,
        printedPage: printedPage ?? this.printedPage,
        printedPageLabel: printedPageLabel ?? this.printedPageLabel,
        sourcePdfPage: sourcePdfPage ?? this.sourcePdfPage,
        nodeType: nodeType ?? this.nodeType,
        sourceKind: sourceKind ?? this.sourceKind,
        left: left ?? this.left,
        top: top ?? this.top,
        right: right ?? this.right,
        bottom: bottom ?? this.bottom,
        confidence: confidence ?? this.confidence,
        sequence: sequence ?? this.sequence,
      );
}

String _normalizeWhitespace(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

String _compactCjkSpaces(String value) {
  var compact = value;
  while (true) {
    final next = compact.replaceAll(
      RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'),
      r'\1\2',
    );
    if (next == compact) return compact;
    compact = next;
  }
}

String _normalizeForMatch(String value) => _normalizeWhitespace(
  value
      .toLowerCase()
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll(RegExp(r'[\s·•…._—–-]+'), ''),
);

final _pageLabelPattern = RegExp(r'^(\d{1,4})$');

int? _parsePageNumber(String label) => int.tryParse(label);
