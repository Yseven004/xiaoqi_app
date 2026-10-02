import 'capture_source_link.dart';

export 'capture_source_link.dart' show CaptureInputKind;

enum DoublePageAxis { vertical, horizontal }

class CapturedPage {
  const CapturedPage({
    required this.path,
    this.isDoublePage = false,
    this.pageGroupId,
    this.pageGroupIndex,
    this.sourcePhotoPath = '',
    this.capturedAt,
    this.captureBatchId,
    this.captureSequence,
    this.inputKind = CaptureInputKind.legacyUnknown,
  });

  final String path;
  final bool isDoublePage;
  final String? pageGroupId;

  /// Zero-based physical reading order. Page① is 0 and Page② is 1.
  final int? pageGroupIndex;
  final String sourcePhotoPath;
  final String? capturedAt;
  final String? captureBatchId;
  final int? captureSequence;
  final CaptureInputKind inputKind;

  CapturedPage copyWith({String? path, CaptureInputKind? inputKind}) {
    return CapturedPage(
      path: path ?? this.path,
      isDoublePage: isDoublePage,
      pageGroupId: pageGroupId,
      pageGroupIndex: pageGroupIndex,
      sourcePhotoPath: sourcePhotoPath,
      capturedAt: capturedAt,
      captureBatchId: captureBatchId,
      captureSequence: captureSequence,
      inputKind: inputKind ?? this.inputKind,
    );
  }
}

class CameraCaptureBatch {
  const CameraCaptureBatch(this.pages);

  final List<CapturedPage> pages;

  List<String> get paths =>
      pages.map((page) => page.path).toList(growable: false);
}
