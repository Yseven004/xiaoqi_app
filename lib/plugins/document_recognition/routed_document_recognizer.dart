import '../../models/ocr_layout.dart';
import 'document_recognition_plugin.dart';
import 'fast_ocr_plugin.dart';
import 'markdown_blocks_codec.dart';
import 'vlm_document_recognizer.dart';

typedef VlmFallback = Future<DocumentRecognitionResult> Function(String path);

/// Adapts native OCR to the document recognition contract without allowing an
/// imported PDF to fall back to a remote VLM. A failed local quality gate is
/// surfaced as an explicit OCR error instead of uploading the page.
class LocalFastOcrDocumentRecognizer implements DocumentRecognitionPlugin {
  LocalFastOcrDocumentRecognizer({FastOcrPlugin? fastOcr})
    : _delegate = RoutedDocumentRecognizer(
        fastOcr: fastOcr,
        fallback: (_) async {
          throw const FastOcrUnavailableException(
            '导入 PDF 的本地 OCR 结果不可用',
          );
        },
      );

  final RoutedDocumentRecognizer _delegate;

  @override
  Future<DocumentRecognitionResult> recognize(String imagePath) =>
      _delegate.recognize(imagePath);
}

/// Fast OCR first, existing VLM only when the local result is not safe enough
/// to become the user's editable source text.
class RoutedDocumentRecognizer implements DocumentRecognitionPlugin {
  RoutedDocumentRecognizer({
    FastOcrPlugin? fastOcr,
    VlmFallback? fallback,
    bool dewarp = true,
    bool strictPageDewarp = false,
  }) : _fastOcr = fastOcr ?? NativeFastOcrPlugin(),
       _injectedFallback = fallback,
       _dewarp = dewarp,
       _strictPageDewarp = strictPageDewarp;

  /// Quality-gate reasons that mean the page probably contains a table or a
  /// figure. When the first VLM response still has no such block, one retry
  /// with a visual-content hint is worth the extra request: a dropped table
  /// is invisible data loss, a wasted retry is only latency.
  static const Set<String> _visualSuspicionReasons = {
    'ambiguous_multiple_columns',
    'aligned_short_cells',
    'large_blank_band',
    'scattered_short_lines',
  };

  final FastOcrPlugin _fastOcr;
  final VlmFallback? _injectedFallback;
  final bool _dewarp;
  final bool _strictPageDewarp;

  @override
  Future<DocumentRecognitionResult> recognize(String imagePath) async {
    final total = Stopwatch()..start();
    try {
      final fast = await _fastOcr.recognize(imagePath);
      final quality = FastOcrQuality.evaluate(fast);
      if (quality.accepted) {
        final result = _fromFastOcr(fast, imagePath, total.elapsedMilliseconds);
        return result;
      }
      return _fallbackWithTrace(
        imagePath,
        total,
        route: 'vlm_fallback',
        reasons: quality.reasons,
        fastOcrMs: fast.elapsedMs,
      );
    } on FastOcrUnavailableException catch (error) {
      return _fallbackWithTrace(
        imagePath,
        total,
        route: 'vlm_fallback',
        reasons: ['fast_ocr_unavailable', error.message],
      );
    }
  }

  Future<DocumentRecognitionResult> _runFallback(
    String imagePath, {
    bool visualContentHint = false,
  }) {
    final fallback = _injectedFallback;
    if (fallback != null) return fallback(imagePath);
    return VlmDocumentRecognizer(
      enablePreprocess: _dewarp,
      strictPageDewarp: _strictPageDewarp,
      visualContentHint: visualContentHint,
    ).recognize(imagePath);
  }

  bool _hasStructuredVisual(List<OcrBlock> blocks) {
    final figures = blocks.where((block) => block.isFigure).toList();
    if (figures.any(
      (block) =>
          !block.hasRenderableFigure && block.figureKind != 'illustration',
    )) {
      return false;
    }
    return blocks.any(
      (block) =>
          block.isTable ||
          block.hasRenderableFigure ||
          (block.isFigure && block.figureKind == 'illustration'),
    );
  }

  Future<DocumentRecognitionResult> _fallbackWithTrace(
    String imagePath,
    Stopwatch total, {
    required String route,
    required List<String> reasons,
    int? fastOcrMs,
  }) async {
    var result = await _runFallback(imagePath);
    var visualRetry = false;
    final suspectedVisualContent = reasons.any(
      _visualSuspicionReasons.contains,
    );
    final figureSceneAlreadyAttempted =
        ((result.diagnostics?['figure_scene_attempt_count'] as num?)?.toInt() ??
            0) >
        0;
    if (suspectedVisualContent &&
        !_hasStructuredVisual(result.blocks) &&
        !figureSceneAlreadyAttempted) {
      try {
        final retried = await _runFallback(imagePath, visualContentHint: true);
        if (_hasStructuredVisual(retried.blocks)) {
          result = retried;
          visualRetry = true;
        }
      } catch (_) {
        // Keep the first usable response; the retry is best effort only.
      }
    }
    return result.copyWith(
      diagnostics: {
        ...?result.diagnostics,
        'route': route,
        'fallback_reasons': reasons,
        'fast_ocr_ms': ?fastOcrMs,
        'total_ms': total.elapsedMilliseconds,
        if (visualRetry) 'visual_retry': true,
      },
    );
  }

  DocumentRecognitionResult _fromFastOcr(
    FastOcrResult result,
    String imagePath,
    int totalMs,
  ) {
    // ML Kit retains useful line grouping, but it does not guarantee the
    // returned TextBlock order. A spread half is especially likely to arrive
    // after rotation with blocks out of reading order, so order by geometry
    // before rebuilding paragraphs.
    final sourceBlocks = result.blocks.isEmpty
        ? _lineFallback(result.lines)
        : result.blocks;
    final ordered = [...sourceBlocks]..sort(_compareReadingOrder);
    final pageNumberBlock = _pageNumberBlock(ordered, result.imageHeight);
    // A photographed page is often trapezoidal: the body margin moves as y
    // changes. More importantly, short form labels can sit further left than
    // the running text. Use long text lines to estimate the body-margin line
    // instead of treating the 20th-percentile x coordinate as a fixed margin.
    final bodyBaseline = _bodyBaseline(
      ordered,
      result.imageWidth,
      result.imageHeight,
    );
    final width = result.imageWidth <= 0 ? 1.0 : result.imageWidth.toDouble();
    final height = result.imageHeight <= 0
        ? 1.0
        : result.imageHeight.toDouble();
    final blocks = <OcrBlock>[
      for (final source in ordered)
        if (!identical(source, pageNumberBlock))
          ..._layoutBlocksFor(
            source,
            bodyBaseline: bodyBaseline,
            imageWidth: width,
            imageHeight: height,
          ),
    ];
    final numberedBlocks = [
      for (var i = 0; i < blocks.length; i++) blocks[i].copyWith(id: i + 1),
    ];
    final markdown = MarkdownBlocksCodec.toMarkdown(numberedBlocks);
    return DocumentRecognitionResult(
      markdown: markdown,
      blocks: numberedBlocks,
      displayImagePath: imagePath,
      pageNumber: pageNumberBlock?.text,
      pageDocument: BookPageDocument(
        blocks: numberedBlocks,
        pageNumber: pageNumberBlock?.text,
        compatibilityMarkdown: markdown,
      ),
      rawResponse: result.fullText,
      diagnostics: {
        'route': 'fast_ocr',
        'fast_ocr_ms': result.elapsedMs,
        'total_ms': totalMs,
        'line_count': result.lines.length,
        'paragraph_count': numberedBlocks
            .where((block) => block.type == 'paragraph')
            .length,
        'indented_paragraph_count': numberedBlocks
            .where(
              (block) =>
                  block.type == 'paragraph' && block.firstLineIndent == 2,
            )
            .length,
        'page_header_count': numberedBlocks
            .where((block) => block.type == 'page_header')
            .length,
        'sidebar_count': numberedBlocks
            .where((block) => block.type == 'sidebar')
            .length,
        'applied_rotation': result.appliedRotation,
      },
    );
  }

  List<OcrBlock> _layoutBlocksFor(
    FastOcrBlock source, {
    required _BodyBaseline bodyBaseline,
    required double imageWidth,
    required double imageHeight,
  }) {
    final type = _decorationType(source, imageWidth, imageHeight);
    if (type != null) {
      return [
        OcrBlock(
          id: 0,
          text: _joinLineTexts(source.lines),
          type: type,
          x: (source.left / imageWidth).clamp(0, 1).toDouble(),
          y: (source.top / imageHeight).clamp(0, 1).toDouble(),
          width: (source.width / imageWidth).clamp(0, 1).toDouble(),
          height: (source.height / imageHeight).clamp(0, 1).toDouble(),
        ),
      ];
    }

    final lines = [...source.lines]..sort(_compareLineReadingOrder);
    if (lines.isEmpty) return const [];
    final medianHeight = _median(lines.map((line) => line.height));
    final groups = <List<FastOcrLine>>[];
    var current = <FastOcrLine>[];
    for (final line in lines) {
      final verticalParagraphGap =
          current.isNotEmpty &&
          line.top - current.last.bottom > medianHeight * 0.75;
      final indentedParagraphStart = _startsIndentedParagraph(
        line,
        current,
        bodyBaseline,
      );
      if (verticalParagraphGap || indentedParagraphStart) {
        groups.add(current);
        current = <FastOcrLine>[];
      }
      current.add(line);
    }
    if (current.isNotEmpty) groups.add(current);

    return [
      for (final group in groups)
        _paragraphBlock(
          group,
          bodyBaseline: bodyBaseline,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ),
    ];
  }

  OcrBlock _paragraphBlock(
    List<FastOcrLine> lines, {
    required _BodyBaseline bodyBaseline,
    required double imageWidth,
    required double imageHeight,
  }) {
    final first = lines.first;
    final left = lines.map((line) => line.left).reduce((a, b) => a < b ? a : b);
    final right = lines
        .map((line) => line.right)
        .reduce((a, b) => a > b ? a : b);
    final top = lines.map((line) => line.top).reduce((a, b) => a < b ? a : b);
    final bottom = lines
        .map((line) => line.bottom)
        .reduce((a, b) => a > b ? a : b);
    final characterWidth = _median(
      lines
          .where((line) => line.text.isNotEmpty)
          .map((line) => line.width / line.text.length),
    );
    final text = _joinLineTexts(lines);
    // For a multi-line paragraph, its own continuation lines are the most
    // reliable body-margin evidence. They survive page perspective and avoid
    // being confused with nearby fill-in-the-blank labels. A one-line prose
    // paragraph falls back to the page-wide sloped baseline.
    final continuationLeft = lines.length > 1
        ? _median(lines.skip(1).map((line) => line.left))
        : bodyBaseline.leftAt(first.top);
    final indentDistance = first.left - continuationLeft;
    final threshold = lines.length > 1
        ? characterWidth * .65
        : characterWidth * .85;
    final excludedFromIndent =
        _looksLikeUnindentedRow(text) || _looksLikeHeading(text, lines.length);
    final geometricIndent = indentDistance > threshold;
    // Some ML Kit versions flatten every line in a TextBlock to the block's
    // left edge. Once the text has been rebuilt as a multi-line Chinese prose
    // paragraph, use the book-page convention as a fallback. The very first
    // lines at the top of a photographed page may continue the previous page,
    // so they still require geometric evidence.
    final proseFallback =
        lines.length > 1 &&
        first.top / imageHeight > .06 &&
        _looksLikeChineseProse(text);
    final indent = !excludedFromIndent && (geometricIndent || proseFallback);
    return OcrBlock(
      id: 0,
      text: text,
      type: 'paragraph',
      x: (left / imageWidth).clamp(0, 1).toDouble(),
      y: (top / imageHeight).clamp(0, 1).toDouble(),
      width: ((right - left) / imageWidth).clamp(0, 1).toDouble(),
      height: ((bottom - top) / imageHeight).clamp(0, 1).toDouble(),
      firstLineIndent: indent ? 2 : 0,
    );
  }

  List<FastOcrBlock> _lineFallback(List<FastOcrLine> lines) {
    final ordered = [...lines]
      ..sort((a, b) {
        final y = a.top.compareTo(b.top);
        return y != 0 ? y : a.left.compareTo(b.left);
      });
    return [
      for (final line in ordered)
        FastOcrBlock(
          text: line.text,
          lines: [line],
          left: line.left,
          top: line.top,
          right: line.right,
          bottom: line.bottom,
        ),
    ];
  }

  FastOcrBlock? _pageNumberBlock(List<FastOcrBlock> blocks, int imageHeight) {
    if (blocks.isEmpty || imageHeight <= 0) return null;
    final candidates = blocks.where((block) {
      final isFooter = block.top / imageHeight > 0.82;
      final isNumber = RegExp(
        r'^[—–-]?\s*\d{1,4}\s*[—–-]?$',
      ).hasMatch(block.text.trim());
      return isFooter && isNumber;
    }).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.top.compareTo(a.top));
    return candidates.first;
  }

  String? _decorationType(
    FastOcrBlock block,
    double imageWidth,
    double imageHeight,
  ) {
    if (imageWidth <= 0 || imageHeight <= 0) return null;
    final atEdge =
        block.left / imageWidth < 0.13 || block.right / imageWidth > 0.87;
    final vertical =
        block.height > block.width * 1.35 ||
        block.lines.where((line) => line.angle.abs() > 45).length >=
            (block.lines.length + 1) ~/ 2;
    if (atEdge && vertical) return 'sidebar';

    final nearTop = block.top / imageHeight < 0.06;
    final shortHeader =
        block.lines.length == 1 &&
        block.width / imageWidth < 0.82 &&
        block.text.runes.length <= 100;
    return nearTop && shortHeader ? 'page_header' : null;
  }

  _BodyBaseline _bodyBaseline(
    List<FastOcrBlock> blocks,
    int imageWidth,
    int imageHeight,
  ) {
    final width = imageWidth <= 0 ? 1.0 : imageWidth.toDouble();
    final candidates = [
      for (final block in blocks)
        if (_decorationType(block, width, imageHeight.toDouble()) == null)
          ...block.lines.where(
            (line) =>
                line.text.runes.length >= 8 &&
                line.width / width >= .35 &&
                !_looksLikeUnindentedRow(line.text),
          ),
    ];
    return _BodyBaseline.fromLines(candidates);
  }

  bool _looksLikeUnindentedRow(String text) {
    final value = text.trim();
    if (value.isEmpty) return true;
    if (RegExp(r'^(?:[-*+•]|\d+[.、])\s*').hasMatch(value)) return true;
    // Short labels, examples and fill-in rows are aligned to the body margin,
    // even when their x coordinate is slightly noisy after OCR.
    return value.length <= 24 &&
        (value.endsWith('：') || RegExp(r'^[^。！？!?]{1,14}[：:]').hasMatch(value));
  }

  bool _looksLikeHeading(String text, int lineCount) {
    if (lineCount != 1) return false;
    final value = text.trim();
    final length = value.runes.length;
    return length <= 12 && !RegExp(r'[，。！？；：,.!?;:]').hasMatch(value);
  }

  bool _looksLikeChineseProse(String text) {
    final value = text.trim();
    final cjkCount = RegExp(
      r'[\u3400-\u4DBF\u4E00-\u9FFF]',
    ).allMatches(value).length;
    return cjkCount >= 12 &&
        RegExp(r'[，。！？；：“”]').hasMatch(value) &&
        !RegExp(r'^(?:[-*+•]|\d+[.、])\s*').hasMatch(value);
  }

  bool _startsIndentedParagraph(
    FastOcrLine line,
    List<FastOcrLine> current,
    _BodyBaseline bodyBaseline,
  ) {
    if (current.isEmpty ||
        _looksLikeUnindentedRow(line.text) ||
        _looksLikeHeading(line.text, 1)) {
      return false;
    }
    final runeCount = line.text.runes.length;
    if (runeCount < 6 || !_containsCjk(line.text)) return false;
    final currentLeft = current.length > 1
        ? current.map((item) => item.left).reduce((a, b) => a < b ? a : b)
        : bodyBaseline.leftAt(line.top);
    final characterWidth = line.width / runeCount;
    final threshold = characterWidth * .65 > line.height * .55
        ? characterWidth * .65
        : line.height * .55;
    return line.left - currentLeft > threshold;
  }

  bool _containsCjk(String text) =>
      RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]').hasMatch(text);

  int _compareReadingOrder(FastOcrBlock a, FastOcrBlock b) {
    final tolerance = _median(
      [...a.lines, ...b.lines].map((line) => line.height),
    );
    if ((a.top - b.top).abs() <= tolerance * 0.65) {
      return a.left.compareTo(b.left);
    }
    return a.top.compareTo(b.top);
  }

  int _compareLineReadingOrder(FastOcrLine a, FastOcrLine b) {
    final tolerance = (a.height + b.height) / 2 * 0.65;
    if ((a.top - b.top).abs() <= tolerance) return a.left.compareTo(b.left);
    return a.top.compareTo(b.top);
  }

  String _joinLineTexts(List<FastOcrLine> lines) {
    final buffer = StringBuffer();
    for (final line in lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty &&
          _needsWordSpace(buffer.toString().runes.last, text.runes.first)) {
        buffer.write(' ');
      }
      buffer.write(text);
    }
    return buffer.toString();
  }

  bool _needsWordSpace(int previous, int next) {
    final previousAscii =
        (previous >= 0x30 && previous <= 0x39) ||
        (previous >= 0x41 && previous <= 0x5A) ||
        (previous >= 0x61 && previous <= 0x7A);
    final nextAscii =
        (next >= 0x30 && next <= 0x39) ||
        (next >= 0x41 && next <= 0x5A) ||
        (next >= 0x61 && next <= 0x7A);
    return previousAscii && nextAscii;
  }

  double _median(Iterable<double> values) {
    final sorted = values.where((value) => value.isFinite && value > 0).toList()
      ..sort();
    if (sorted.isEmpty) return 1;
    return sorted[sorted.length ~/ 2];
  }
}

/// A least-squares approximation of the running-text left margin. This keeps
/// the indentation decision stable when a photographed page has perspective.
class _BodyBaseline {
  const _BodyBaseline({required this.intercept, required this.slope});

  final double intercept;
  final double slope;

  factory _BodyBaseline.fromLines(List<FastOcrLine> lines) {
    if (lines.isEmpty) return const _BodyBaseline(intercept: 0, slope: 0);
    if (lines.length == 1) {
      return _BodyBaseline(intercept: lines.single.left, slope: 0);
    }
    final meanTop =
        lines.map((line) => line.top).reduce((a, b) => a + b) / lines.length;
    final meanLeft =
        lines.map((line) => line.left).reduce((a, b) => a + b) / lines.length;
    var covariance = 0.0;
    var variance = 0.0;
    for (final line in lines) {
      final topOffset = line.top - meanTop;
      covariance += topOffset * (line.left - meanLeft);
      variance += topOffset * topOffset;
    }
    final slope = variance > 0 ? covariance / variance : 0.0;
    return _BodyBaseline(intercept: meanLeft - slope * meanTop, slope: slope);
  }

  double leftAt(double top) => intercept + slope * top;
}
