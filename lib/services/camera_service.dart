import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../camera/camera_contract.dart';
import '../camera/legacy_camera_backend.dart';
import '../camera/native_camera_backend.dart';
import '../pages/viewfinder_camera_page.dart';
import '../models/captured_page.dart';

class CameraService {
  static final CameraService _instance = CameraService._internal();
  static const bool _nativeCameraEnabled = bool.fromEnvironment(
    'XIAOQI_NATIVE_CAMERA',
    defaultValue: true,
  );

  factory CameraService() => _instance;

  CameraService._internal() {
    _legacyBackend = LegacyCameraBackend();
    _backend = Platform.isAndroid && _nativeCameraEnabled
        ? NativeCameraBackend(fallbackBackend: _legacyBackend)
        : _legacyBackend;
  }

  final ImagePicker _picker = ImagePicker();
  late final LegacyCameraBackend _legacyBackend;
  late final CameraBackend _backend;

  /// In-flight (or completed) prepare; null after [claimPreparedSession] or cancel.
  Future<CameraSession>? _prepareFuture;

  /// Bumped on [cancelPrepare] so stale inits dispose themselves.
  int _prepareEpoch = 0;

  /// Prefetch device camera list (cheap after first call). Safe on home open.
  void prefetchCameras() {
    unawaited(_backend.prefetch());
  }

  /// Start initializing the back camera while the route animates in.
  void beginPrepare() {
    if (_prepareFuture != null) return;
    final epoch = _prepareEpoch;
    _prepareFuture = _createSession(epoch);
  }

  /// Drop a prepare that was never claimed (e.g. user picked album instead).
  void cancelPrepare() {
    final pending = _prepareFuture;
    if (pending == null) return;
    _prepareFuture = null;
    _prepareEpoch++;
    unawaited(
      pending
          .then((session) => session.disposeSession())
          .catchError((Object _) {}),
    );
  }

  /// Take ownership of the prepared controller, or create one if needed.
  Future<CameraSession> claimPreparedSession() async {
    beginPrepare();
    final pending = _prepareFuture;
    _prepareFuture = null;
    if (pending != null) {
      try {
        final session = await pending;
        debugPrint(
          '[XiaoQi Camera] event=claim backend=${session.value.backend}',
        );
        return session;
      } catch (e) {
        debugPrint('[XiaoQi Camera] event=prepare_failed error=$e');
      }
    }
    return _createSession(_prepareEpoch);
  }

  Future<CameraSession> _createSession(int epoch) async {
    final session = await _backend.createSession();
    if (epoch != _prepareEpoch) {
      await session.disposeSession();
      throw StateError('camera prepare cancelled');
    }
    return session;
  }

  /// 调起取景框相机；「完成」返回暂存路径列表（newest-first），取消为 null。
  ///
  /// 先等预览硬件就绪再 push，避免进页黑屏；首帧即带 [CameraPreview]。
  Future<List<String>?> takePhoto(BuildContext context) async {
    final batch = await takePhotoBatch(context);
    return batch?.paths;
  }

  /// Structured capture API. New callers should use this so double-page
  /// grouping and physical page order are preserved end-to-end.
  Future<CameraCaptureBatch?> takePhotoBatch(
    BuildContext context, {
    List<CapturedPage> initialPages = const [],
    String? captureBatchId,
  }) async {
    try {
      beginPrepare();
      final session = await claimPreparedSession();
      if (!context.mounted) {
        await session.disposeSession();
        return null;
      }
      final batch = await Navigator.of(context).push<CameraCaptureBatch>(
        PageRouteBuilder<CameraCaptureBatch>(
          opaque: true,
          fullscreenDialog: true,
          // Instant cut once preview is live — no fade-through black.
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 150),
          pageBuilder: (context, animation, secondaryAnimation) {
            return ViewfinderCameraPage(
              initialSession: session,
              initialPages: initialPages,
              captureBatchId: captureBatchId,
            );
          },
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return child;
          },
        ),
      );
      if (batch == null || batch.pages.isEmpty) {
        debugPrint('[XiaoQi] Camera: 用户取消或未完成暂存');
        return null;
      }
      debugPrint('[XiaoQi] Camera: 取景框暂存完成 count=${batch.pages.length}');
      return batch;
    } catch (e) {
      cancelPrepare();
      debugPrint('[XiaoQi] Camera: 拍照失败: $e');
      return null;
    }
  }

  /// Select the original gallery asset. Document dewarping needs native
  /// stroke and edge resolution; a 1920px cap made gallery pages materially
  /// worse than pages captured through the in-app camera.
  Future<XFile?> pickFromGallery() async {
    try {
      final XFile? file = await _picker.pickImage(source: ImageSource.gallery);

      if (file == null) {
        debugPrint('[XiaoQi] Camera: 用户取消选图');
        return null;
      }

      debugPrint('[XiaoQi] Camera: 选图成功，原始路径=${file.path}');
      return await _copyToTempDir(file);
    } catch (e) {
      debugPrint('[XiaoQi] Camera: 选图失败: $e');
      return null;
    }
  }

  /// 从系统相册多选图片，最多 [maxImages] 张。不释放相机；由调用方保持预览。
  Future<List<XFile>> pickMultipleFromGallery({int maxImages = 5}) async {
    try {
      final List<XFile> files = await _picker.pickMultiImage(limit: maxImages);

      if (files.isEmpty) {
        debugPrint('[XiaoQi] Camera: 用户取消多选');
        return [];
      }

      final limitedFiles = files.take(maxImages).toList();
      debugPrint('[XiaoQi] Camera: 多选成功，选择了 ${limitedFiles.length} 张图片');

      final copyFutures = limitedFiles
          .map(_copyToTempDir)
          .toList(growable: false);
      final copiedFiles = await Future.wait(copyFutures);
      return copiedFiles.whereType<XFile>().toList();
    } catch (e) {
      debugPrint('[XiaoQi] Camera: 多选失败: $e');
      return [];
    }
  }

  /// 统一入口：先尝试相机，不可用或取消则降级为相册选择（单张）。
  Future<XFile?> captureImage(BuildContext context) async {
    final paths = await takePhoto(context);
    if (paths != null && paths.isNotEmpty) return XFile(paths.first);
    return pickFromGallery();
  }

  /// 将图片复制到应用沙箱临时目录，防止系统回收
  Future<XFile?> _copyToTempDir(XFile file) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final tempDir = Directory(p.join(appDir.path, 'photos', 'temp'));
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      final random = Random().nextInt(99999);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${timestamp}_$random.jpg';
      final destPath = p.join(tempDir.path, fileName);

      final sourceFile = File(file.path);
      await sourceFile.copy(destPath);

      debugPrint('[XiaoQi] Camera: 图片已复制到临时目录: $destPath');
      return XFile(destPath);
    } catch (e) {
      debugPrint('[XiaoQi] Camera: 复制图片到临时目录失败: $e');
      return null;
    }
  }
}
