import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/captured_page.dart';
import '../utils/jpeg_exif.dart';

/// Splits one book spread into its two pages without allowing an inner box,
/// table, or paragraph to be mistaken for the whole spread.
///
/// Perspective correction deliberately does not run here. The generic quad
/// detector is built for one page and can validly find a boxed callout inside
/// a two-page photo. Each output is instead a complete half of the oriented
/// source; later OCR receives the [CapturedPage.isDoublePage] context and
/// skips its own unconstrained dewarp pass as well.
class DoublePageCaptureService {
  DoublePageCaptureService._();

  static Future<List<CapturedPage>> split(
    String capturePath, {
    Directory? storageDirectory,
    DoublePageAxis? axis,
    bool swapped = false,
    String? captureBatchId,
    int? captureSequence,
    DoublePageImageSplitter? imageSplitter,
  }) async {
    final processingTimer = Stopwatch()..start();
    final appDir = storageDirectory ?? await getApplicationDocumentsDirectory();
    final tempDir = Directory(p.join(appDir.path, 'photos', 'temp'));
    await tempDir.create(recursive: true);

    final timestamp = DateTime.now();
    final groupId =
        'dp_${timestamp.microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final batchId =
        captureBatchId ??
        'batch_${timestamp.microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final sourcePath = p.join(tempDir.path, '${groupId}_original.jpg');
    await File(capturePath).copy(sourcePath);

    final sourceBytes = await File(sourcePath).readAsBytes();
    final orientation = JpegExif.orientation(sourceBytes);
    final encoded =
        await (imageSplitter?.call(sourceBytes, axis, orientation) ??
            Isolate.run(
              () => _splitImageBytes(
                sourceBytes,
                axis: axis,
                exifOrientation: orientation,
              ),
            ));

    final page1Path = p.join(tempDir.path, '${groupId}_page_1.jpg');
    final page2Path = p.join(tempDir.path, '${groupId}_page_2.jpg');
    await Future.wait([
      File(page1Path).writeAsBytes(encoded.first, flush: true),
      File(page2Path).writeAsBytes(encoded.second, flush: true),
    ]);
    debugPrint(
      '[DoublePageCapture] group=$groupId '
      'axis=${encoded.axis.name} source=${encoded.sourceWidth}x${encoded.sourceHeight} '
      'page1=${encoded.firstWidth}x${encoded.firstHeight} '
      'page2=${encoded.secondWidth}x${encoded.secondHeight} '
      'elapsed=${processingTimer.elapsedMilliseconds}ms',
    );
    final capturedAt = timestamp.toIso8601String();
    final pages = [
      CapturedPage(
        path: page1Path,
        inputKind: CaptureInputKind.camera,
        isDoublePage: true,
        pageGroupId: groupId,
        pageGroupIndex: swapped ? 1 : 0,
        sourcePhotoPath: sourcePath,
        capturedAt: capturedAt,
        captureBatchId: batchId,
        captureSequence: captureSequence,
      ),
      CapturedPage(
        path: page2Path,
        inputKind: CaptureInputKind.camera,
        isDoublePage: true,
        pageGroupId: groupId,
        pageGroupIndex: swapped ? 0 : 1,
        sourcePhotoPath: sourcePath,
        capturedAt: capturedAt,
        captureBatchId: batchId,
        captureSequence: captureSequence,
      ),
    ];
    return pages;
  }

  /// Worker-isolate image path: decode once, bake EXIF orientation once, then
  /// crop two OpenCV ROIs. No page-boundary detector runs on the spread.
  static DoublePageSplitBytes _splitImageBytes(
    Uint8List sourceBytes, {
    required DoublePageAxis? axis,
    required int exifOrientation,
  }) {
    // IMREAD_IGNORE_ORIENTATION is 128 in OpenCV. Ask native decode to leave
    // EXIF untouched, then apply it exactly once below; otherwise OpenCV's
    // device-specific auto-rotation can cause a second 90° turn.
    final source = cv.imdecode(sourceBytes, cv.IMREAD_COLOR | 128);
    if (source.isEmpty) {
      source.dispose();
      throw const FormatException('无法解码双页照片');
    }

    cv.Mat? oriented;
    cv.Mat? first;
    cv.Mat? second;
    cv.VecI32? params;
    try {
      oriented = _applyExifOrientation(source, exifOrientation);
      if (oriented.cols < 2 || oriented.rows < 2) {
        throw const FormatException('双页照片尺寸无效');
      }
      final resolvedAxis =
          axis ??
          (oriented.cols >= oriented.rows
              ? DoublePageAxis.horizontal
              : DoublePageAxis.vertical);
      final split = resolvedAxis == DoublePageAxis.horizontal
          ? oriented.cols ~/ 2
          : oriented.rows ~/ 2;
      if (split < 1) throw const FormatException('双页照片尺寸无效');

      first = resolvedAxis == DoublePageAxis.horizontal
          ? cv.Mat.fromMat(
              oriented,
              copy: true,
              roi: cv.Rect(0, 0, split, oriented.rows),
            )
          : cv.Mat.fromMat(
              oriented,
              copy: true,
              roi: cv.Rect(0, 0, oriented.cols, split),
            );
      second = resolvedAxis == DoublePageAxis.horizontal
          ? cv.Mat.fromMat(
              oriented,
              copy: true,
              roi: cv.Rect(split, 0, oriented.cols - split, oriented.rows),
            )
          : cv.Mat.fromMat(
              oriented,
              copy: true,
              roi: cv.Rect(0, split, oriented.cols, oriented.rows - split),
            );
      params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]);
      final (firstOk, firstBytes) = cv.imencode('.jpg', first, params: params);
      final (secondOk, secondBytes) = cv.imencode(
        '.jpg',
        second,
        params: params,
      );
      if (!firstOk || !secondOk || firstBytes.isEmpty || secondBytes.isEmpty) {
        throw const FormatException('无法保存拆分后的书页');
      }
      return DoublePageSplitBytes(
        first: firstBytes,
        second: secondBytes,
        axis: resolvedAxis,
        sourceWidth: oriented.cols,
        sourceHeight: oriented.rows,
        firstWidth: first.cols,
        firstHeight: first.rows,
        secondWidth: second.cols,
        secondHeight: second.rows,
      );
    } finally {
      params?.dispose();
      second?.dispose();
      first?.dispose();
      if (oriented != null && !identical(oriented, source)) {
        oriented.dispose();
      }
      source.dispose();
    }
  }

  static cv.Mat _applyExifOrientation(cv.Mat source, int orientation) {
    return switch (orientation) {
      2 => cv.flip(source, 1),
      3 => cv.rotate(source, cv.ROTATE_180),
      4 => cv.flip(source, 0),
      5 => cv.transpose(source),
      6 => cv.rotate(source, cv.ROTATE_90_CLOCKWISE),
      7 => _transposeThenFlip(source),
      8 => cv.rotate(source, cv.ROTATE_90_COUNTERCLOCKWISE),
      _ => source,
    };
  }

  static cv.Mat _transposeThenFlip(cv.Mat source) {
    final transposed = cv.transpose(source);
    try {
      return cv.flip(transposed, -1);
    } finally {
      transposed.dispose();
    }
  }
}

/// Test seam for file-system tests that must run without native OpenCV.
typedef DoublePageImageSplitter =
    Future<DoublePageSplitBytes> Function(
      Uint8List sourceBytes,
      DoublePageAxis? axis,
      int exifOrientation,
    );

class DoublePageSplitBytes {
  const DoublePageSplitBytes({
    required this.first,
    required this.second,
    required this.axis,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.firstWidth,
    required this.firstHeight,
    required this.secondWidth,
    required this.secondHeight,
  });

  final Uint8List first;
  final Uint8List second;
  final DoublePageAxis axis;
  final int sourceWidth;
  final int sourceHeight;
  final int firstWidth;
  final int firstHeight;
  final int secondWidth;
  final int secondHeight;
}
