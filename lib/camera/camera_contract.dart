import 'package:flutter/widgets.dart';

enum CameraLensRole { ultraWide, wide }

enum CameraLensStrategy { logicalZoom, cameraId, physicalCamera, legacy }

enum CameraSessionFlashMode { off, auto, on }

@immutable
class CameraLensOption {
  const CameraLensOption({
    required this.id,
    required this.role,
    required this.strategy,
    required this.displayZoom,
    required this.focalLengthMm,
    required this.maxCaptureSize,
    required this.supportsFlash,
    required this.available,
  });

  final String id;
  final CameraLensRole role;
  final CameraLensStrategy strategy;
  final double displayZoom;
  final double focalLengthMm;
  final Size maxCaptureSize;
  final bool supportsFlash;
  final bool available;

  String get displayLabel {
    final rounded = displayZoom.toStringAsFixed(1);
    return '${rounded.endsWith('.0') ? rounded.substring(0, rounded.length - 2) : rounded}x';
  }
}

class CameraLensPolicy {
  CameraLensPolicy._();

  static const int minimumUltraWidePixels = 8000000;

  static bool isEligible(CameraLensOption lens) {
    if (!lens.available) return false;
    if (lens.role == CameraLensRole.wide) return true;
    final pixels = lens.maxCaptureSize.width * lens.maxCaptureSize.height;
    return lens.displayZoom < 0.95 && pixels >= minimumUltraWidePixels;
  }

  static List<CameraLensOption> ranked(Iterable<CameraLensOption> lenses) {
    final result = lenses.where(isEligible).toList(growable: false);
    return result..sort((a, b) => a.displayZoom.compareTo(b.displayZoom));
  }

  static CameraLensOption? preferred(Iterable<CameraLensOption> lenses) {
    final rankedLenses = ranked(lenses);
    return rankedLenses.isEmpty ? null : rankedLenses.first;
  }
}

@immutable
class CameraCaptureResult {
  const CameraCaptureResult({
    required this.path,
    required this.size,
    this.rotationDegrees = 0,
  });

  final String path;
  final Size size;
  final int rotationDegrees;
}

@immutable
class CameraSessionValue {
  const CameraSessionValue({
    required this.isInitialized,
    required this.isSwitchingLens,
    required this.lenses,
    required this.backend,
    this.currentLens,
    this.previewSize,
    this.error,
  });

  const CameraSessionValue.uninitialized({required String backend})
    : this(
        isInitialized: false,
        isSwitchingLens: false,
        lenses: const [],
        backend: backend,
      );

  final bool isInitialized;
  final bool isSwitchingLens;
  final List<CameraLensOption> lenses;
  final CameraLensOption? currentLens;
  final Size? previewSize;
  final String backend;
  final String? error;

  CameraSessionValue copyWith({
    bool? isInitialized,
    bool? isSwitchingLens,
    List<CameraLensOption>? lenses,
    CameraLensOption? currentLens,
    Size? previewSize,
    String? backend,
    String? error,
    bool clearError = false,
  }) {
    return CameraSessionValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isSwitchingLens: isSwitchingLens ?? this.isSwitchingLens,
      lenses: lenses ?? this.lenses,
      currentLens: currentLens ?? this.currentLens,
      previewSize: previewSize ?? this.previewSize,
      backend: backend ?? this.backend,
      error: clearError ? null : error ?? this.error,
    );
  }
}

abstract class CameraSession extends ChangeNotifier {
  CameraSessionValue get value;

  Widget buildPreview({required Size layoutSize, Key? key});

  Future<CameraCaptureResult> capture({required Size previewLayoutSize});

  Future<void> focus(Offset normalizedPoint);

  Future<void> setFlashMode(CameraSessionFlashMode mode);

  Future<void> setTorch(bool enabled);

  Future<void> switchLens(CameraLensOption lens);

  Future<void> pause();

  Future<void> resume();

  Future<void> disposeSession();
}

abstract interface class CameraBackend {
  String get name;

  Future<void> prefetch();

  Future<CameraSession> createSession();
}
