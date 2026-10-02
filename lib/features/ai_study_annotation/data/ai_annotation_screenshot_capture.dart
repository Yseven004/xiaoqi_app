import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../../../services/page_image_asset_store.dart';

class AiAnnotationScreenshotCaptureResult {
  const AiAnnotationScreenshotCaptureResult({
    required this.asset,
    required this.contentPixelRatio,
    required this.contentPixelCount,
  });

  final PageImageAsset asset;
  final double contentPixelRatio;
  final int contentPixelCount;

  bool get hasReadableContent =>
      contentPixelCount >= 24 && contentPixelRatio >= .0005;
}

/// Captures only the page region selected by the temporary laser gesture.
///
/// The resulting image is an evidence preview. The structured source anchor
/// remains the authoritative input for AI requests and persistence.
class AiAnnotationScreenshotCapture {
  const AiAnnotationScreenshotCapture(this.assetStore);

  final PageImageAssetStore assetStore;

  Future<PageImageAsset> capture({
    required RenderRepaintBoundary boundary,
    required ui.Rect normalizedBounds,
    double pixelRatio = 2,
  }) async => (await captureAnalyzed(
    boundary: boundary,
    normalizedBounds: normalizedBounds,
    pixelRatio: pixelRatio,
  )).asset;

  Future<AiAnnotationScreenshotCaptureResult> captureAnalyzed({
    required RenderRepaintBoundary boundary,
    required ui.Rect normalizedBounds,
    double pixelRatio = 2,
  }) async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final safe = _safeBounds(normalizedBounds);
      final source = ui.Rect.fromLTRB(
        safe.left * image.width,
        safe.top * image.height,
        safe.right * image.width,
        safe.bottom * image.height,
      );
      final outputWidth = source.width.round().clamp(1, image.width).toInt();
      final outputHeight = source.height.round().clamp(1, image.height).toInt();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
      );
      canvas.drawImageRect(
        image,
        source,
        ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final cropped = await recorder.endRecording().toImage(
        outputWidth,
        outputHeight,
      );
      try {
        final rawData = await cropped.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (rawData == null) throw const FormatException('无法分析来源截图');
        final content = _contentPixels(
          rawData.buffer.asUint8List(
            rawData.offsetInBytes,
            rawData.lengthInBytes,
          ),
          outputWidth * outputHeight,
        );
        final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw const FormatException('无法生成来源截图');
        final asset = await assetStore.storeBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          extension: '.png',
          originalName:
              'ai-source-${DateTime.now().microsecondsSinceEpoch}.png',
        );
        return AiAnnotationScreenshotCaptureResult(
          asset: asset,
          contentPixelRatio: content.$1,
          contentPixelCount: content.$2,
        );
      } finally {
        cropped.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  ui.Rect _safeBounds(ui.Rect value) {
    final left = (value.left - .025).clamp(0.0, 1.0).toDouble();
    final top = (value.top - .025).clamp(0.0, 1.0).toDouble();
    final right = (value.right + .025).clamp(0.0, 1.0).toDouble();
    final bottom = (value.bottom + .025).clamp(0.0, 1.0).toDouble();
    return ui.Rect.fromLTRB(
      left,
      top,
      right <= left ? (left + .01).clamp(0.0, 1.0).toDouble() : right,
      bottom <= top ? (top + .01).clamp(0.0, 1.0).toDouble() : bottom,
    );
  }

  (double, int) _contentPixels(Uint8List rgba, int totalPixels) {
    var contentPixels = 0;
    for (var index = 0; index + 3 < rgba.length; index += 4) {
      final red = rgba[index];
      final green = rgba[index + 1];
      final blue = rgba[index + 2];
      final alpha = rgba[index + 3];
      if (alpha < 32) continue;
      final minimum = red < green
          ? (red < blue ? red : blue)
          : (green < blue ? green : blue);
      final nearWhite = minimum > 238;
      final laserRed = red > 160 && red - green > 35 && red - blue > 35;
      if (!nearWhite && !laserRed) contentPixels++;
    }
    final ratio = totalPixels <= 0 ? 0.0 : contentPixels / totalPixels;
    return (ratio, contentPixels);
  }
}
