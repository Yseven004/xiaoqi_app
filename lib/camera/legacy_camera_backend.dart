import 'dart:io';

import 'package:camera/camera.dart' as plugin;
import 'package:flutter/material.dart';

import 'camera_contract.dart';

class LegacyCameraBackend implements CameraBackend {
  Future<List<plugin.CameraDescription>>? _cameras;

  @override
  String get name => 'legacy_camera_plugin';

  Future<List<plugin.CameraDescription>> _getCameras() {
    return _cameras ??= plugin.availableCameras();
  }

  @override
  Future<void> prefetch() async {
    await _getCameras();
  }

  @override
  Future<CameraSession> createSession() async {
    final cameras = await _getCameras();
    if (cameras.isEmpty) {
      throw plugin.CameraException('NoCameras', 'No camera is available');
    }
    final back = cameras.where(
      (camera) => camera.lensDirection == plugin.CameraLensDirection.back,
    );
    final description = back.isNotEmpty ? back.first : cameras.first;
    final session = LegacyCameraSession(description);
    await session.initialize();
    return session;
  }
}

class LegacyCameraSession extends CameraSession {
  LegacyCameraSession(this._description)
    : _value = const CameraSessionValue.uninitialized(
        backend: 'legacy_camera_plugin',
      );

  final plugin.CameraDescription _description;
  plugin.CameraController? _controller;
  CameraSessionValue _value;
  CameraSessionFlashMode _flashMode = CameraSessionFlashMode.off;
  bool _torchEnabled = false;
  bool _disposed = false;

  @override
  CameraSessionValue get value => _value;

  Future<void> initialize() async {
    if (_disposed || _controller?.value.isInitialized == true) return;
    final controller = plugin.CameraController(
      _description,
      plugin.ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? plugin.ImageFormatGroup.bgra8888
          : plugin.ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    await controller.unlockCaptureOrientation();
    await controller.setZoomLevel(1.0);
    _controller = controller;
    final preview = controller.value.previewSize;
    const lens = CameraLensOption(
      id: 'legacy-wide',
      role: CameraLensRole.wide,
      strategy: CameraLensStrategy.legacy,
      displayZoom: 1,
      focalLengthMm: 0,
      maxCaptureSize: Size.zero,
      supportsFlash: true,
      available: true,
    );
    _value = CameraSessionValue(
      isInitialized: true,
      isSwitchingLens: false,
      lenses: const [lens],
      currentLens: lens,
      previewSize: preview == null ? null : Size(preview.height, preview.width),
      backend: 'legacy_camera_plugin',
    );
    notifyListeners();
  }

  @override
  Widget buildPreview({required Size layoutSize, Key? key}) {
    final controller = _controller;
    final previewSize = value.previewSize;
    if (controller == null || previewSize == null) {
      return const ColoredBox(color: Colors.black);
    }
    return ClipRect(
      key: key,
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: previewSize.width,
            height: previewSize.height,
            child: plugin.CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  @override
  Future<CameraCaptureResult> capture({required Size previewLayoutSize}) async {
    final shot = await _requireController().takePicture();
    return CameraCaptureResult(path: shot.path, size: Size.zero);
  }

  @override
  Future<void> focus(Offset normalizedPoint) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final point = Offset(
      normalizedPoint.dx.clamp(0.0, 1.0),
      normalizedPoint.dy.clamp(0.0, 1.0),
    );
    await controller.setFocusMode(plugin.FocusMode.auto);
    await controller.setExposureMode(plugin.ExposureMode.auto);
    await controller.setFocusPoint(point);
    await controller.setExposurePoint(point);
  }

  @override
  Future<void> setFlashMode(CameraSessionFlashMode mode) async {
    _flashMode = mode;
    if (_torchEnabled) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.setFlashMode(_pluginFlashMode(mode));
  }

  @override
  Future<void> setTorch(bool enabled) async {
    _torchEnabled = enabled;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.setFlashMode(
      enabled ? plugin.FlashMode.torch : _pluginFlashMode(_flashMode),
    );
  }

  @override
  Future<void> switchLens(CameraLensOption lens) async {}

  @override
  Future<void> pause() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) await controller.dispose();
    _value = _value.copyWith(isInitialized: false);
    notifyListeners();
  }

  @override
  Future<void> resume() => initialize();

  @override
  Future<void> disposeSession() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    _controller = null;
    if (controller != null) await controller.dispose();
    super.dispose();
  }

  plugin.CameraController _requireController() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('Legacy camera is not initialized');
    }
    return controller;
  }

  plugin.FlashMode _pluginFlashMode(CameraSessionFlashMode mode) {
    return switch (mode) {
      CameraSessionFlashMode.off => plugin.FlashMode.off,
      CameraSessionFlashMode.auto => plugin.FlashMode.auto,
      CameraSessionFlashMode.on => plugin.FlashMode.always,
    };
  }
}
