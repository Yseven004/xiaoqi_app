import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Fast, on-device OCR abstraction. Native implementations return geometry so
/// the router can decide whether the output is safe to use without a VLM.
abstract interface class FastOcrPlugin {
  Future<FastOcrResult> recognize(String imagePath);
}

class FastOcrUnavailableException implements Exception {
  const FastOcrUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FastOcrLine {
  const FastOcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    required this.angle,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final double angle;

  double get width => (right - left).clamp(0, double.infinity).toDouble();
  double get height => (bottom - top).clamp(0, double.infinity).toDouble();
}

/// Native OCR considers a [FastOcrBlock] to be a paragraph-like unit. Keeping
/// this boundary is essential: a page contains visual line wraps, not a list
/// of independent paragraphs.
class FastOcrBlock {
  const FastOcrBlock({
    required this.text,
    required this.lines,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final List<FastOcrLine> lines;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0, double.infinity).toDouble();
  double get height => (bottom - top).clamp(0, double.infinity).toDouble();
}

class FastOcrResult {
  const FastOcrResult({
    required this.fullText,
    required this.lines,
    required this.imageWidth,
    required this.imageHeight,
    required this.elapsedMs,
    this.blocks = const [],
    this.appliedRotation = 0,
  });

  final String fullText;
  final List<FastOcrLine> lines;
  final int imageWidth;
  final int imageHeight;
  final int elapsedMs;
  final List<FastOcrBlock> blocks;

  /// Clockwise source-pixel rotation used before the final native OCR pass.
  final int appliedRotation;
}

/// Android ML Kit bridge. Unsupported platforms throw a typed error so the
/// router can transparently retain the existing VLM path.
class NativeFastOcrPlugin implements FastOcrPlugin {
  NativeFastOcrPlugin({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'xiaoqi_app/fast_ocr',
  );

  final MethodChannel _channel;

  @override
  Future<FastOcrResult> recognize(String imagePath) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'recognizeChineseText',
        {'imagePath': imagePath},
      );
      if (raw == null) {
        throw const FastOcrUnavailableException('本地 OCR 未返回结果');
      }
      final blocks = _blocks(raw['blocks']);
      final lines = blocks.isEmpty ? _lines(raw['lines']) : _flatten(blocks);
      return FastOcrResult(
        fullText: raw['fullText']?.toString() ?? '',
        lines: lines,
        imageWidth: _number(raw['imageWidth']).round(),
        imageHeight: _number(raw['imageHeight']).round(),
        elapsedMs: _number(raw['elapsedMs']).round(),
        blocks: blocks,
        appliedRotation: _number(raw['appliedRotation']).round(),
      );
    } on MissingPluginException {
      throw const FastOcrUnavailableException('当前平台未提供本地 OCR');
    } on PlatformException catch (error) {
      throw FastOcrUnavailableException(error.message ?? '本地 OCR 不可用');
    }
  }

  static double _number(Object? value) => value is num ? value.toDouble() : 0;

  static List<FastOcrBlock> _blocks(Object? value) {
    if (value is! List) return const [];
    final blocks = <FastOcrBlock>[];
    for (final item in value) {
      if (item is! Map) continue;
      final block = Map<Object?, Object?>.from(item);
      final lines = _lines(block['lines']);
      final text = block['text']?.toString().trim() ?? '';
      if (text.isEmpty || lines.isEmpty) continue;
      blocks.add(
        FastOcrBlock(
          text: text,
          lines: lines,
          left: _number(block['left']),
          top: _number(block['top']),
          right: _number(block['right']),
          bottom: _number(block['bottom']),
        ),
      );
    }
    return blocks;
  }

  static List<FastOcrLine> _lines(Object? value) {
    if (value is! List) return const [];
    final lines = <FastOcrLine>[];
    for (final item in value) {
      if (item is! Map) continue;
      final line = Map<Object?, Object?>.from(item);
      final text = line['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      lines.add(
        FastOcrLine(
          text: text,
          left: _number(line['left']),
          top: _number(line['top']),
          right: _number(line['right']),
          bottom: _number(line['bottom']),
          confidence: _number(line['confidence']),
          angle: _number(line['angle']),
        ),
      );
    }
    return lines;
  }

  static List<FastOcrLine> _flatten(List<FastOcrBlock> blocks) => [
    for (final block in blocks) ...block.lines,
  ];
}

/// Conservative gate: false positives cost user trust, so uncertain layout is
/// deliberately handed to the existing VLM instead of forcing local OCR.
class FastOcrQuality {
  const FastOcrQuality({required this.accepted, required this.reasons});

  final bool accepted;
  final List<String> reasons;

  static FastOcrQuality evaluate(FastOcrResult result) {
    final lines = result.lines;
    final reasons = <String>[];
    if (lines.length < 4) reasons.add('too_few_lines');

    final confidences = lines
        .map((line) => line.confidence)
        .where((value) => value > 0)
        .toList();
    if (confidences.isEmpty) {
      // Some ML Kit versions do not expose line confidence. Do not turn that
      // platform limitation into a guaranteed remote VLM fallback; the layout
      // checks below still reject pages that look like tables or figures.
    } else {
      final average = confidences.reduce((a, b) => a + b) / confidences.length;
      final lowRatio =
          confidences.where((value) => value < 0.90).length /
          confidences.length;
      if (average < 0.90) reasons.add('low_ocr_confidence');
      if (lowRatio > 0.08) reasons.add('too_many_low_confidence_lines');
    }

    final rotated = lines.where((line) => line.angle.abs() > 5).length;
    if (rotated > lines.length * 0.1) reasons.add('mixed_or_rotated_text');
    if (_hasLikelyMultipleColumns(lines, result.imageWidth)) {
      reasons.add('ambiguous_multiple_columns');
    }
    // Local OCR only sees text, so a table with blank fill rows or a chart
    // would be silently dropped while every visible character still scores
    // high confidence. These geometric checks hand such pages to the VLM.
    if (_hasLargeBlankBand(lines, result.imageHeight)) {
      reasons.add('large_blank_band');
    }
    if (_hasAlignedShortCells(lines, result.imageWidth)) {
      reasons.add('aligned_short_cells');
    }
    if (_hasFloatingShortLines(lines, result.imageWidth)) {
      reasons.add('scattered_short_lines');
    }
    return FastOcrQuality(accepted: reasons.isEmpty, reasons: reasons);
  }

  /// A horizontal zone without any recognized text in the middle of the page.
  /// Prose never leaves a gap wider than a couple of blank lines, while an
  /// unbordered form table (header row + blank fill rules) or a sparse figure
  /// commonly does.
  static bool _hasLargeBlankBand(List<FastOcrLine> lines, int imageHeight) {
    if (imageHeight <= 0 || lines.length < 4) return false;
    final sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
    final heights = sorted
        .map((line) => line.height)
        .where((height) => height > 0)
        .toList()
      ..sort();
    if (heights.isEmpty) return false;
    final medianHeight = heights[heights.length ~/ 2];
    final threshold = math.max(imageHeight * 0.10, medianHeight * 4);
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].top - sorted[i - 1].bottom;
      // Ignore the space around the running header and the page-number footer;
      // only a gap inside the body area signals visual content.
      if (gap > threshold &&
          sorted[i - 1].bottom > imageHeight * 0.12 &&
          sorted[i].top < imageHeight * 0.88) {
        return true;
      }
    }
    return false;
  }

  /// Three or more mutually disjoint short labels on the same horizontal band,
  /// spread across more than half the page: the signature of a table header
  /// row such as 「益友名字 / 上次联系 / 下次联系」.
  static bool _hasAlignedShortCells(List<FastOcrLine> lines, int imageWidth) {
    if (imageWidth <= 0 || lines.length < 3) return false;
    final short = lines
        .where((line) => line.width > 0 && line.width < imageWidth * 0.4)
        .toList()
      ..sort((a, b) => a.top.compareTo(b.top));
    for (var i = 0; i < short.length; i++) {
      final anchor = short[i];
      final band = <FastOcrLine>[anchor];
      final tolerance = math.max(anchor.height * 0.8, 1.0);
      for (var j = i + 1; j < short.length; j++) {
        if (short[j].top - anchor.top > tolerance) break;
        band.add(short[j]);
      }
      if (band.length >= 3 && _spansDisjointColumns(band, imageWidth)) {
        return true;
      }
    }
    return false;
  }

  static bool _spansDisjointColumns(List<FastOcrLine> band, int imageWidth) {
    final sorted = [...band]..sort((a, b) => a.left.compareTo(b.left));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].left < sorted[i - 1].right) return false;
    }
    final span = sorted.last.right - sorted.first.left;
    return span > imageWidth * 0.55;
  }

  /// Short text floating strictly inside the body column: chart axis labels,
  /// curve annotations and in-figure captions. Prose starts at the body margin
  /// or ends at it, so it never produces many inset-only short lines.
  static bool _hasFloatingShortLines(List<FastOcrLine> lines, int imageWidth) {
    if (imageWidth <= 0 || lines.length < 6) return false;
    final long = lines
        .where((line) => line.width >= imageWidth * 0.55)
        .toList(growable: false);
    if (long.length < 3) return false;
    final bodyLeft = long
        .map((line) => line.left)
        .reduce((a, b) => a < b ? a : b);
    final bodyRight = long
        .map((line) => line.right)
        .reduce((a, b) => a > b ? a : b);
    final inset = imageWidth * 0.1;
    var floating = 0;
    for (final line in lines) {
      if (line.width >= imageWidth * 0.35) continue;
      if (line.left > bodyLeft + inset && line.right < bodyRight - inset) {
        floating++;
      }
    }
    return floating >= 4;
  }

  static bool _hasLikelyMultipleColumns(
    List<FastOcrLine> lines,
    int imageWidth,
  ) {
    if (imageWidth <= 0 || lines.length < 8) return false;
    final narrow = lines
        .where((line) => line.width / imageWidth < 0.55)
        .toList();
    final left = narrow.where((line) => line.left / imageWidth < 0.2).length;
    final right = narrow.where((line) => line.left / imageWidth > 0.5).length;
    return left >= 3 && right >= 3;
  }
}
