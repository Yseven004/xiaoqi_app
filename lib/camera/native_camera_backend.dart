import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_contract.dart';
import 'generated/native_camera_api.g.dart';

const _nativeViewType = 'xiaoqi/native_camera_preview';

class NativeCameraBackend implements CameraBackend {
  NativeCameraBackend({
    required CameraBackend fallbackBackend,
    NativeCameraHostApi? api,
  }) : _fallbackBackend = fallbackBackend,
       _api = api ?? NativeCameraHostApi();

  final CameraBackend _fallbackBackend;
  final NativeCameraHostApi _api;

  @override
  String get name => 'android_camerax_native';

  @override
  Future<void> prefetch() async {
    try {
      await _api.prefetch();
    } catch (error) {
      debugPrint('[XiaoQi Camera] backend=native prefetch_failed=$error');
    }
  }

  @override
  Future<CameraSession> createSession() async {
    return NativeCameraSession(
      api: _api,
      fallbackFactory: _fallbackBackend.createSession,
    );
  }
}

class NativeCameraSession extends CameraSession {
  NativeCameraSession({
    required NativeCameraHostApi api,
    required Future<CameraSession> Function() fallbackFactory,
  }) : _api = api,
       _fallbackFactory = fallbackFactory,
       _value = const CameraSessionValue.uninitialized(
         backend: 'android_camerax_native',
       );

  final NativeCameraHostApi _api;
  final Future<CameraSession> Function() _fallbackFactory;
  CameraSessionValue _value;
  CameraSession? _fallback;
  int? _viewId;
  Future<void>? _initialization;
  bool _disposed = false;

  @override
  CameraSessionValue get value => _fallback?.value ?? _value;

  @override
  Widget buildPreview({required Size layoutSize, Key? key}) {
    final fallback = _fallback;
    if (fallback != null) {
      return fallback.buildPreview(layoutSize: layoutSize, key: key);
    }
    return ClipRect(
      key: key,
      child: SizedBox.expand(
        child: AndroidView(
          viewType: _nativeViewType,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
      ),
    );
  }

  void _onPlatformViewCreated(int viewId) {
    if (_disposed) {
      unawaited(_api.dispose(viewId));
      return;
    }
    _viewId = viewId;
    _initialization ??= _initializeNative(viewId);
  }

  Future<void> _initializeNative(int viewId) async {
    try {
      final state = await _api.initialize(viewId);
      if (_disposed || _viewId != viewId) return;
      _applyNativeState(state);
    } catch (error, stack) {
      if (_disposed) return;
      debugPrint(
        '[XiaoQi Camera] backend=legacy_fallback reason=$error\n$stack',
      );
      try {
        await _api.dispose(viewId);
      } catch (_) {}
      final fallback = await _fallbackFactory();
      if (_disposed) {
        await fallback.disposeSession();
        return;
      }
      _fallback = fallback;
      fallback.addListener(_onFallbackChanged);
      notifyListeners();
    }
  }

  void _onFallbackChanged() => notifyListeners();

  void _applyNativeState(NativeCameraStateData state) {
    final lenses = CameraLensPolicy.ranked(state.lenses.map(_mapLens));
    CameraLensOption? selected;
    for (final lens in lenses) {
      if (lens.id == state.currentLensId) selected = lens;
    }
    _value = CameraSessionValue(
      isInitialized: state.ready,
      isSwitchingLens: state.switchingLens,
      lenses: lenses,
      currentLens: selected,
      previewSize: state.previewWidth > 0 && state.previewHeight > 0
          ? Size(state.previewWidth.toDouble(), state.previewHeight.toDouble())
          : null,
      backend: state.backend,
    );
    notifyListeners();
  }

  CameraLensOption _mapLens(NativeLensOptionData lens) {
    return CameraLensOption(
      id: lens.id,
      role: switch (lens.role) {
        NativeLensRole.ultraWide => CameraLensRole.ultraWide,
        NativeLensRole.wide => CameraLensRole.wide,
      },
      strategy: switch (lens.strategy) {
        NativeLensStrategy.logicalZoom => CameraLensStrategy.logicalZoom,
        NativeLensStrategy.cameraId => CameraLensStrategy.cameraId,
        NativeLensStrategy.physicalCamera => CameraLensStrategy.physicalCamera,
      },
      displayZoom: lens.displayZoom,
      focalLengthMm: lens.focalLengthMm,
      maxCaptureSize: Size(
        lens.maxCaptureWidth.toDouble(),
        lens.maxCaptureHeight.toDouble(),
      ),
      supportsFlash: lens.supportsFlash,
      available: lens.available,
    );
  }

  Future<int> _readyViewId() async {
    final initialization = _initialization;
    if (initialization != null) await initialization;
    if (_fallback != null) return -1;
    final viewId = _viewId;
    if (viewId == null || !_value.isInitialized) {
      throw StateError('Native camera is not initialized');
    }
    return viewId;
  }

  @override
  Future<CameraCaptureResult> capture({required Size previewLayoutSize}) async {
    final fallback = _fallback;
    if (fallback != null) {
      return fallback.capture(previewLayoutSize: previewLayoutSize);
    }
    final result = await _api.capture(await _readyViewId());
    return CameraCaptureResult(
      path: result.path,
      size: Size(result.width.toDouble(), result.height.toDouble()),
      rotationDegrees: result.rotationDegrees,
    );
  }

  @override
  Future<void> focus(Offset normalizedPoint) async {
    final fallback = _fallback;
    if (fallback != null) return fallback.focus(normalizedPoint);
    final viewId = await _readyViewId();
    await _api.focus(
      viewId,
      normalizedPoint.dx.clamp(0.0, 1.0),
      normalizedPoint.dy.clamp(0.0, 1.0),
    );
  }

  @override
  Future<void> setFlashMode(CameraSessionFlashMode mode) async {
    final fallback = _fallback;
    if (fallback != null) return fallback.setFlashMode(mode);
    final viewId = await _readyViewId();
    await _api.setFlashMode(viewId, switch (mode) {
      CameraSessionFlashMode.off => NativeFlashMode.off,
      CameraSessionFlashMode.auto => NativeFlashMode.auto,
      CameraSessionFlashMode.on => NativeFlashMode.on,
    });
  }

  @override
  Future<void> setTorch(bool enabled) async {
    final fallback = _fallback;
    if (fallback != null) return fallback.setTorch(enabled);
    await _api.setTorch(await _readyViewId(), enabled);
  }

  @override
  Future<void> switchLens(CameraLensOption lens) async {
    final fallback = _fallback;
    if (fallback != null || lens.id == value.currentLens?.id) return;
    final viewId = await _readyViewId();
    _value = _value.copyWith(isSwitchingLens: true);
    notifyListeners();
    try {
      _applyNativeState(await _api.switchLens(viewId, lens.id));
    } finally {
      if (_value.isSwitchingLens) {
        _value = _value.copyWith(isSwitchingLens: false);
        notifyListeners();
      }
    }
  }

  @override
  Future<void> pause() async {
    final fallback = _fallback;
    if (fallback != null) return fallback.pause();
    final viewId = _viewId;
    if (viewId != null) await _api.pause(viewId);
    _value = _value.copyWith(isInitialized: false);
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    final fallback = _fallback;
    if (fallback != null) return fallback.resume();
    final viewId = _viewId;
    if (viewId == null) return;
    _applyNativeState(await _api.resume(viewId));
  }

  @override
  Future<void> disposeSession() async {
    if (_disposed) return;
    _disposed = true;
    final fallback = _fallback;
    if (fallback != null) {
      fallback.removeListener(_onFallbackChanged);
      await fallback.disposeSession();
    }
    final viewId = _viewId;
    _viewId = null;
    if (viewId != null) {
      try {
        await _api.dispose(viewId);
      } catch (_) {}
    }
    super.dispose();
  }
}
