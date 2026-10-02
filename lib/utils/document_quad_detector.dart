import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Shared document-edge quad finder.
///
/// Returns ordered corners TL, TR, BR, BL in image pixel coordinates, or null.
class DocumentQuadDetector {
  DocumentQuadDetector._();

  static List<Offset>? detect(cv.Mat src) {
    return detectDetailed(src).detection?.quad;
  }

  static List<Offset>? detectBytes(Uint8List encoded) {
    return detectBytesDetailed(encoded).detection?.quad;
  }

  static DocumentQuadDetectionResult detectBytesDetailed(Uint8List encoded) {
    final src = cv.imdecode(encoded, cv.IMREAD_COLOR);
    if (src.isEmpty) {
      return const DocumentQuadDetectionResult(
        detection: null,
        candidateCount: 0,
        rejectedCount: 0,
        reason: 'decode-empty',
      );
    }
    try {
      return detectDetailed(src);
    } finally {
      src.dispose();
    }
  }

  static DocumentQuadDetectionResult detectDetailed(cv.Mat src) {
    if (src.isEmpty) {
      return const DocumentQuadDetectionResult(
        detection: null,
        candidateCount: 0,
        rejectedCount: 0,
        reason: 'source-empty',
      );
    }

    final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
    try {
      return detectGrayDetailed(gray);
    } finally {
      gray.dispose();
    }
  }

  static DocumentQuadDetectionResult detectGrayDetailed(
    cv.Mat gray, {
    List<Offset>? preferredQuad,
  }) {
    if (gray.isEmpty) {
      return const DocumentQuadDetectionResult(
        detection: null,
        candidateCount: 0,
        rejectedCount: 0,
        reason: 'gray-empty',
      );
    }
    final candidates = <_QuadCandidate>[];
    var rejected = 0;

    void collect(cv.Mat mask, String source) {
      final result = _collectCandidates(
        mask: mask,
        gray: gray,
        source: source,
        imageArea: gray.rows * gray.cols,
        preferredQuad: preferredQuad,
      );
      candidates.addAll(result.candidates);
      rejected += result.rejectedCount;
    }

    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    try {
      final edges = cv.canny(blurred, 50.0, 150.0);
      try {
        collect(edges, 'canny');
        final dilateK = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
        final thick = cv.dilate(edges, dilateK);
        dilateK.dispose();
        try {
          collect(thick, 'canny-dilate');
        } finally {
          thick.dispose();
        }
      } finally {
        edges.dispose();
      }

      final binary = cv.adaptiveThreshold(
        blurred,
        255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv.THRESH_BINARY,
        31,
        10,
      );
      try {
        collect(binary, 'adaptive-bright');

        // Text binarisation tends to produce rectangles around a paragraph.
        // A separate paper mask recovers the actual page boundary when it
        // is visible but faint.
        final paperThreshold = cv
            .threshold(blurred, 145, 255, cv.THRESH_BINARY)
            .$2;
        try {
          collect(paperThreshold, 'paper-bright');
          final paperK = cv.getStructuringElement(cv.MORPH_RECT, (17, 17));
          final paperClosed = cv.morphologyEx(
            paperThreshold,
            cv.MORPH_CLOSE,
            paperK,
          );
          paperK.dispose();
          try {
            collect(paperClosed, 'paper-close');
          } finally {
            paperClosed.dispose();
          }
        } finally {
          paperThreshold.dispose();
        }

        final otsu = cv
            .threshold(blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU)
            .$2;
        try {
          collect(otsu, 'otsu-bright');
          final otsuK = cv.getStructuringElement(cv.MORPH_RECT, (15, 15));
          final otsuClosed = cv.morphologyEx(otsu, cv.MORPH_CLOSE, otsuK);
          otsuK.dispose();
          try {
            collect(otsuClosed, 'otsu-close');
          } finally {
            otsuClosed.dispose();
          }
        } finally {
          otsu.dispose();
        }

        final closeK = cv.getStructuringElement(cv.MORPH_RECT, (11, 11));
        final closed = cv.morphologyEx(binary, cv.MORPH_CLOSE, closeK);
        closeK.dispose();
        try {
          collect(closed, 'adaptive-close');
        } finally {
          closed.dispose();
        }

        final inverted = cv.bitwiseNOT(binary);
        try {
          collect(inverted, 'adaptive-inverted');
          final lineKernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 3));
          final textLines = cv.dilate(inverted, lineKernel);
          lineKernel.dispose();
          try {
            final blockKernel = cv.getStructuringElement(cv.MORPH_RECT, (
              3,
              11,
            ));
            final textBlocks = cv.dilate(textLines, blockKernel);
            blockKernel.dispose();
            try {
              collect(textBlocks, 'text-block');
            } finally {
              textBlocks.dispose();
            }
          } finally {
            textLines.dispose();
          }
        } finally {
          inverted.dispose();
        }
      } finally {
        binary.dispose();
      }
    } finally {
      blurred.dispose();
    }

    if (candidates.isEmpty) {
      return DocumentQuadDetectionResult(
        detection: null,
        candidateCount: 0,
        rejectedCount: rejected,
        reason: rejected == 0 ? 'no-contours' : 'all-candidates-rejected',
      );
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    var best = candidates.first;
    if (best.source.startsWith('paper') || best.source.startsWith('otsu')) {
      _QuadCandidate? textCandidate;
      for (final candidate in candidates) {
        if (candidate.source == 'text-block') {
          textCandidate = candidate;
          break;
        }
      }
      if (textCandidate != null &&
          textCandidate.score >= best.score - 34 &&
          textCandidate.areaRatio < best.areaRatio * 0.94) {
        best = textCandidate;
      }
    }
    if (best.score < 42.0) {
      return DocumentQuadDetectionResult(
        detection: null,
        candidateCount: candidates.length,
        rejectedCount: rejected,
        reason: 'low-score:${best.score.toStringAsFixed(1)}:${best.reason}',
      );
    }

    return DocumentQuadDetectionResult(
      detection: DocumentQuadDetection(
        quad: best.quad,
        score: best.score,
        source: best.source,
        areaRatio: best.areaRatio,
        inkRatio: best.inkRatio,
        reason: best.reason,
      ),
      candidateCount: candidates.length,
      rejectedCount: rejected,
      reason: 'ok',
    );
  }

  static _CandidateCollection _collectCandidates({
    required cv.Mat mask,
    required cv.Mat gray,
    required String source,
    required int imageArea,
    List<Offset>? preferredQuad,
  }) {
    final (contours, _) = cv.findContours(
      mask,
      source.startsWith('paper') ||
              source.startsWith('otsu') ||
              source == 'text-block'
          ? cv.RETR_EXTERNAL
          : cv.RETR_LIST,
      cv.CHAIN_APPROX_SIMPLE,
    );
    try {
      final candidates = <_QuadCandidate>[];
      var rejected = 0;

      for (final contour in contours) {
        final area = cv.contourArea(contour);
        if (area < imageArea * 0.025) {
          rejected++;
          continue;
        }

        final peri = cv.arcLength(contour, true);
        cv.VecPoint? bestApprox;
        for (final epsilon in const [0.015, 0.025, 0.04, 0.055]) {
          final approx = cv.approxPolyDP(contour, epsilon * peri, true);
          if (approx.length == 4 && cv.isContourConvex(approx)) {
            bestApprox = approx;
            break;
          }
          approx.dispose();
        }
        List<Offset>? fallbackQuad;
        if (bestApprox == null &&
            area >= imageArea * 0.10 &&
            (source.startsWith('paper') ||
                source.startsWith('otsu') ||
                source == 'text-block')) {
          final rotatedRect = cv.minAreaRect(contour);
          final points = rotatedRect.points;
          try {
            fallbackQuad = _orderPointOffsets([
              for (final point in points)
                Offset(point.x.toDouble(), point.y.toDouble()),
            ]);
          } finally {
            points.dispose();
            rotatedRect.dispose();
          }
        }
        if (bestApprox == null && fallbackQuad == null) {
          rejected++;
          continue;
        }
        try {
          var quad = bestApprox == null
              ? fallbackQuad!
              : _orderCorners(bestApprox);
          if (source == 'text-block') {
            quad = _expandTextBlock(quad, gray.cols, gray.rows);
          }
          final candidate = _scoreCandidate(
            quad: quad,
            contourArea: area,
            gray: gray,
            source: source,
            preferredQuad: preferredQuad,
          );
          if (candidate == null) {
            rejected++;
            continue;
          }
          candidates.add(candidate);
        } finally {
          bestApprox?.dispose();
        }
      }
      return _CandidateCollection(candidates, rejected);
    } finally {
      contours.dispose();
    }
  }

  static _QuadCandidate? _scoreCandidate({
    required List<Offset> quad,
    required double contourArea,
    required cv.Mat gray,
    required String source,
    List<Offset>? preferredQuad,
  }) {
    final imageArea = gray.rows * gray.cols;
    final areaRatio = _polygonArea(quad) / imageArea;
    if (areaRatio < 0.045 || areaRatio > 0.985) return null;

    final bounds = _boundingRect(quad);
    final edgeSides = _edgeContactSides(
      quad,
      gray.cols,
      gray.rows,
      insetRatio: 0.03,
    );
    // A large rectangle that borrows multiple analyzer borders does not have
    // four observed page edges. This commonly happens when a bright desk or
    // monitor merges with the paper near the top of the preview.
    if (edgeSides >= 3 || (edgeSides >= 2 && areaRatio > 0.70)) return null;
    final aspect = bounds.width / math.max(1.0, bounds.height);
    if (aspect < 0.26 || aspect > 1.72) return null;

    final top = _distance(quad[0], quad[1]);
    final right = _distance(quad[1], quad[2]);
    final bottom = _distance(quad[2], quad[3]);
    final left = _distance(quad[3], quad[0]);
    final oppositeRatio = math.min(_ratio(top, bottom), _ratio(left, right));
    if (oppositeRatio < 0.32) return null;

    final center = _center(quad);
    final imageCenter = Offset(gray.cols / 2, gray.rows / 2);
    final centerDistance = (center - imageCenter).distance;
    final maxCenterDistance = math.sqrt(
      math.pow(gray.cols / 2, 2) + math.pow(gray.rows / 2, 2),
    );
    final centerScore = 1.0 - (centerDistance / maxCenterDistance).clamp(0, 1);

    final metrics = _contentMetrics(gray, quad);
    if (metrics == null) return null;
    if (metrics.inkRatio < 0.0005 || metrics.inkRatio > 0.42) return null;
    final edgeEvidence = _edgeEvidence(gray, quad);
    if (areaRatio > 0.52 && edgeEvidence.supportedSides < 3) return null;
    final topContaminated =
        metrics.topMean + 24 < metrics.middleMean &&
        metrics.topDarkRatio > metrics.middleDarkRatio + 0.08;
    final bottomContaminated =
        metrics.bottomMean + 30 < metrics.middleMean &&
        metrics.bottomDarkRatio > metrics.middleDarkRatio + 0.10;
    if (topContaminated || bottomContaminated) return null;

    final areaScore = _triangularScore(
      areaRatio,
      low: 0.16,
      peak: 0.68,
      high: 0.99,
    );
    final inkScore = _triangularScore(
      metrics.inkRatio,
      low: 0.0015,
      peak: 0.025,
      high: 0.18,
    );
    final brightnessScore = _triangularScore(
      metrics.meanBrightness,
      low: 72,
      peak: 205,
      high: 250,
    );
    final aspectScore = _triangularScore(
      aspect,
      low: 0.36,
      peak: 0.68,
      high: 1.08,
    );
    final fillRatio = contourArea / math.max(1.0, bounds.width * bounds.height);
    final sourceBonus = switch (source) {
      'otsu-close' => 12.0,
      'otsu-bright' => 8.0,
      'paper-close' => 13.0,
      'paper-bright' => 10.0,
      'adaptive-close' => 5.0,
      'adaptive-bright' => 4.0,
      'canny-dilate' => 3.0,
      'canny' => 1.5,
      'text-block' => 24.0,
      _ => 0.0,
    };
    final temporalBonus = preferredQuad == null
        ? 0.0
        : _temporalSimilarity(quad, preferredQuad, gray.cols, gray.rows) * 18;

    final score =
        areaScore * 42 +
        centerScore * 15 +
        oppositeRatio * 14 +
        aspectScore * 12 +
        inkScore * 10 +
        brightnessScore * 6 +
        fillRatio.clamp(0.0, 1.0) * 5 +
        edgeEvidence.score * 18 +
        sourceBonus -
        _edgeContactPenalty(quad, gray.cols, gray.rows) +
        temporalBonus;

    return _QuadCandidate(
      quad: quad,
      source: source,
      score: score,
      areaRatio: areaRatio,
      inkRatio: metrics.inkRatio,
      reason:
          'area=${areaRatio.toStringAsFixed(2)} '
          'ink=${metrics.inkRatio.toStringAsFixed(3)} '
          'edges=${edgeEvidence.supportedSides} '
          'bands=${metrics.topMean.round()}/${metrics.middleMean.round()}/${metrics.bottomMean.round()}',
    );
  }

  static _ContentMetrics? _contentMetrics(cv.Mat gray, List<Offset> quad) {
    final pageMask = cv.Mat.zeros(gray.rows, gray.cols, cv.MatType.CV_8UC1);
    final points = cv.VecVecPoint.fromList([
      [
        for (final p in quad)
          cv.Point(
            p.dx.round().clamp(0, gray.cols - 1),
            p.dy.round().clamp(0, gray.rows - 1),
          ),
      ],
    ]);
    final white = cv.Scalar.all(255);
    cv.Mat? dark;
    cv.Scalar? mean;
    try {
      cv.fillPoly(pageMask, points, white);
      final maskPixels = pageMask.countNoneZero;
      if (maskPixels < gray.rows * gray.cols * 0.035) return null;
      mean = gray.mean(mask: pageMask);
      final inkThreshold = (mean.val1 - 28).clamp(35.0, 205.0);
      dark = cv
          .threshold(
            gray,
            inkThreshold,
            255,
            cv.THRESH_BINARY_INV,
            mask: pageMask,
          )
          .$2;
      final darkPixels = dark.countNoneZero;
      final sampled = _samplePageBands(gray, quad, mean.val1);
      return _ContentMetrics(
        inkRatio: darkPixels / maskPixels,
        meanBrightness: mean.val1,
        topMean: sampled.topMean,
        middleMean: sampled.middleMean,
        bottomMean: sampled.bottomMean,
        topDarkRatio: sampled.topDarkRatio,
        middleDarkRatio: sampled.middleDarkRatio,
        bottomDarkRatio: sampled.bottomDarkRatio,
      );
    } finally {
      mean?.dispose();
      dark?.dispose();
      white.dispose();
      points.dispose();
      pageMask.dispose();
    }
  }

  static _SampledPageBands _samplePageBands(
    cv.Mat gray,
    List<Offset> quad,
    double pageMean,
  ) {
    final bytes = gray.data;
    final top = <double>[];
    final middle = <double>[];
    final bottom = <double>[];
    const rows = 17;
    const columns = 11;
    for (var row = 0; row < rows; row++) {
      final v = 0.04 + row * 0.92 / (rows - 1);
      final left = Offset.lerp(quad[0], quad[3], v)!;
      final right = Offset.lerp(quad[1], quad[2], v)!;
      final target = v < 0.24
          ? top
          : v > 0.76
          ? bottom
          : middle;
      for (var column = 0; column < columns; column++) {
        final u = 0.08 + column * 0.84 / (columns - 1);
        final point = Offset.lerp(left, right, u)!;
        final x = point.dx.round().clamp(0, gray.cols - 1);
        final y = point.dy.round().clamp(0, gray.rows - 1);
        target.add(bytes[y * gray.cols + x].toDouble());
      }
    }
    final darkThreshold = (pageMean - 36).clamp(28.0, 205.0);
    return _SampledPageBands(
      topMean: _mean(top),
      middleMean: _mean(middle),
      bottomMean: _mean(bottom),
      topDarkRatio: _fractionBelow(top, darkThreshold),
      middleDarkRatio: _fractionBelow(middle, darkThreshold),
      bottomDarkRatio: _fractionBelow(bottom, darkThreshold),
    );
  }

  static _EdgeEvidence _edgeEvidence(cv.Mat gray, List<Offset> quad) {
    final bytes = gray.data;
    var supportedSides = 0;
    var totalScore = 0.0;
    for (var side = 0; side < 4; side++) {
      final start = quad[side];
      final end = quad[(side + 1) % 4];
      final delta = end - start;
      final length = delta.distance;
      if (length < 8) continue;
      final normal = Offset(-delta.dy / length, delta.dx / length);
      var contrastSum = 0.0;
      var strong = 0;
      var valid = 0;
      for (var sample = 1; sample <= 13; sample++) {
        final t = sample / 14;
        final center = Offset.lerp(start, end, t)!;
        final a = center + normal * 3.0;
        final b = center - normal * 3.0;
        if (!_inside(a, gray.cols, gray.rows) ||
            !_inside(b, gray.cols, gray.rows)) {
          continue;
        }
        final ax = a.dx.round().clamp(0, gray.cols - 1);
        final ay = a.dy.round().clamp(0, gray.rows - 1);
        final bx = b.dx.round().clamp(0, gray.cols - 1);
        final by = b.dy.round().clamp(0, gray.rows - 1);
        final av = bytes[ay * gray.cols + ax];
        final bv = bytes[by * gray.cols + bx];
        final contrast = (av - bv).abs().toDouble();
        contrastSum += contrast;
        if (contrast >= 9) strong++;
        valid++;
      }
      if (valid == 0) continue;
      final meanContrast = contrastSum / valid;
      final strongRatio = strong / valid;
      if (meanContrast >= 6.0 && strongRatio >= 0.23) supportedSides++;
      totalScore += (meanContrast / 18).clamp(0.0, 1.0);
    }
    return _EdgeEvidence(supportedSides: supportedSides, score: totalScore / 4);
  }

  static List<Offset> _expandTextBlock(
    List<Offset> quad,
    int width,
    int height,
  ) {
    final center = _center(quad);
    return <Offset>[
      for (final point in quad)
        Offset(
          (center.dx + (point.dx - center.dx) * 1.26).clamp(0.0, width - 1.0),
          (center.dy + (point.dy - center.dy) * 1.28).clamp(0.0, height - 1.0),
        ),
    ];
  }

  static bool _inside(Offset point, int width, int height) {
    return point.dx >= 0 &&
        point.dy >= 0 &&
        point.dx < width &&
        point.dy < height;
  }

  static double _mean(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _fractionBelow(List<double> values, double threshold) {
    if (values.isEmpty) return 0;
    return values.where((value) => value < threshold).length / values.length;
  }

  static double _triangularScore(
    double value, {
    required double low,
    required double peak,
    required double high,
  }) {
    if (value <= low || value >= high) return 0;
    if (value == peak) return 1;
    if (value < peak) {
      return ((value - low) / (peak - low)).clamp(0.0, 1.0).toDouble();
    }
    return ((high - value) / (high - peak)).clamp(0.0, 1.0).toDouble();
  }

  static double _edgeContactPenalty(List<Offset> quad, int width, int height) {
    var penalty = 0.0;
    final insetX = width * 0.015;
    final insetY = height * 0.015;
    for (final p in quad) {
      if (p.dx <= insetX || p.dx >= width - insetX) penalty += 3.0;
      if (p.dy <= insetY || p.dy >= height - insetY) penalty += 3.0;
    }
    return penalty;
  }

  static int _edgeContactSides(
    List<Offset> quad,
    int width,
    int height, {
    required double insetRatio,
  }) {
    final bounds = _boundsOf(quad);
    var count = 0;
    if (bounds.left <= width * insetRatio) count++;
    if (bounds.right >= width * (1 - insetRatio)) count++;
    if (bounds.top <= height * insetRatio) count++;
    if (bounds.bottom >= height * (1 - insetRatio)) count++;
    return count;
  }

  static Offset _center(List<Offset> quad) {
    var x = 0.0;
    var y = 0.0;
    for (final p in quad) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / quad.length, y / quad.length);
  }

  static ({double width, double height}) _boundingRect(List<Offset> quad) {
    final bounds = _boundsOf(quad);
    return (
      width: bounds.right - bounds.left,
      height: bounds.bottom - bounds.top,
    );
  }

  static ({double left, double right, double top, double bottom}) _boundsOf(
    List<Offset> quad,
  ) {
    var left = quad.first.dx;
    var right = quad.first.dx;
    var top = quad.first.dy;
    var bottom = quad.first.dy;
    for (final p in quad.skip(1)) {
      left = math.min(left, p.dx);
      right = math.max(right, p.dx);
      top = math.min(top, p.dy);
      bottom = math.max(bottom, p.dy);
    }
    return (left: left, right: right, top: top, bottom: bottom);
  }

  static double _polygonArea(List<Offset> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final current = points[index];
      final next = points[(index + 1) % points.length];
      sum += current.dx * next.dy - next.dx * current.dy;
    }
    return sum.abs() / 2;
  }

  static double _distance(Offset a, Offset b) => (a - b).distance;

  static double _ratio(double a, double b) {
    final largest = math.max(a, b);
    return largest == 0 ? 0 : math.min(a, b) / largest;
  }

  static double _temporalSimilarity(
    List<Offset> current,
    List<Offset> previous,
    int width,
    int height,
  ) {
    if (previous.length != 4) return 0;
    final diagonal = math.sqrt(width * width + height * height);
    if (diagonal <= 0) return 0;
    var movement = 0.0;
    for (var i = 0; i < 4; i++) {
      movement += (current[i] - previous[i]).distance;
    }
    return (1 - movement / 4 / (diagonal * 0.18)).clamp(0.0, 1.0);
  }

  static List<Offset> _orderCorners(cv.VecPoint contour) {
    final pts = <Offset>[];
    for (final point in contour) {
      pts.add(Offset(point.x.toDouble(), point.y.toDouble()));
    }
    return _orderPointOffsets(pts);
  }

  static List<Offset> _orderPointOffsets(List<Offset> points) {
    final pts = List<Offset>.from(points);
    pts.sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
    final tl = pts.first;
    final br = pts.last;
    pts.sort((a, b) => (a.dx - a.dy).compareTo(b.dx - b.dy));
    final bl = pts.first;
    final tr = pts.last;
    return [tl, tr, br, bl];
  }
}

class DocumentQuadDetectionResult {
  const DocumentQuadDetectionResult({
    required this.detection,
    required this.candidateCount,
    required this.rejectedCount,
    required this.reason,
  });

  final DocumentQuadDetection? detection;
  final int candidateCount;
  final int rejectedCount;
  final String reason;
}

class DocumentQuadDetection {
  const DocumentQuadDetection({
    required this.quad,
    required this.score,
    required this.source,
    required this.areaRatio,
    required this.inkRatio,
    required this.reason,
  });

  final List<Offset> quad;
  final double score;
  final String source;
  final double areaRatio;
  final double inkRatio;
  final String reason;
}

class _CandidateCollection {
  const _CandidateCollection(this.candidates, this.rejectedCount);

  final List<_QuadCandidate> candidates;
  final int rejectedCount;
}

class _QuadCandidate {
  const _QuadCandidate({
    required this.quad,
    required this.source,
    required this.score,
    required this.areaRatio,
    required this.inkRatio,
    required this.reason,
  });

  final List<Offset> quad;
  final String source;
  final double score;
  final double areaRatio;
  final double inkRatio;
  final String reason;
}

class _ContentMetrics {
  const _ContentMetrics({
    required this.inkRatio,
    required this.meanBrightness,
    required this.topMean,
    required this.middleMean,
    required this.bottomMean,
    required this.topDarkRatio,
    required this.middleDarkRatio,
    required this.bottomDarkRatio,
  });

  final double inkRatio;
  final double meanBrightness;
  final double topMean;
  final double middleMean;
  final double bottomMean;
  final double topDarkRatio;
  final double middleDarkRatio;
  final double bottomDarkRatio;
}

class _SampledPageBands {
  const _SampledPageBands({
    required this.topMean,
    required this.middleMean,
    required this.bottomMean,
    required this.topDarkRatio,
    required this.middleDarkRatio,
    required this.bottomDarkRatio,
  });

  final double topMean;
  final double middleMean;
  final double bottomMean;
  final double topDarkRatio;
  final double middleDarkRatio;
  final double bottomDarkRatio;
}

class _EdgeEvidence {
  const _EdgeEvidence({required this.supportedSides, required this.score});

  final int supportedSides;
  final double score;
}
