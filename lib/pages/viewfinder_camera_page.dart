import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../camera/camera_contract.dart';
import '../config/book_flow_theme.dart';
import '../features/photo_editor/photo_editor_page.dart';
import '../models/captured_page.dart';
import '../models/capture_mode.dart';
import '../services/camera_service.dart';
import '../services/camera_capture_preferences.dart';
import '../services/double_page_capture_service.dart';
import '../services/permission_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/camera_level_indicator.dart';
import '../widgets/camera_staging_stack.dart';
import '../widgets/camera_staging_tray.dart';
import '../widgets/camera_staging_viewer.dart';
import '../widgets/capture_fly_to_tray_overlay.dart';
import '../widgets/double_page_viewfinder_overlay.dart';
import '../widgets/viewfinder_camera_chrome.dart';

/// 夸克式全屏相机：端侧暂存多张，完成后再交给生成链路。
class ViewfinderCameraPage extends StatefulWidget {
  const ViewfinderCameraPage({
    super.key,
    this.initialSession,
    this.initialPages = const [],
    this.captureBatchId,
  });

  /// Prepared session from [CameraService.takePhoto].
  final CameraSession? initialSession;
  final List<CapturedPage> initialPages;
  final String? captureBatchId;

  @override
  State<ViewfinderCameraPage> createState() => _ViewfinderCameraPageState();
}

class _ViewfinderCameraPageState extends State<ViewfinderCameraPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraSession? _session;
  CameraSessionFlashMode _flash = CameraSessionFlashMode.off;
  bool _torchOn = false;
  CaptureMode _captureMode = CaptureMode.singlePage;
  bool _settingsOpen = false;
  bool _levelEnabled = false;
  bool _skipBatchReview = false;
  Offset _levelTilt = Offset.zero;

  /// 仅 takePicture 期间为 true：此时禁止 lifecycle dispose。
  bool _capturing = false;

  /// 防止 initState / resume 并发创建多个 CameraController。
  bool _initializing = false;

  /// 串行化 dispose → reinit，避免「dispose 未完成就 initialize」白屏。
  Future<void> _cameraOp = Future<void>.value();

  /// Newest capture first; pages inside one double-page capture stay ① → ②.
  final List<CapturedPage> _stagedPages = [];
  List<String> get _stagedPaths =>
      _stagedPages.map((page) => page.path).toList(growable: false);
  bool _stackExpanded = false;
  int? _viewerIndex;
  static const int kMaxStaged = 20;

  final GlobalKey _previewKey = GlobalKey();
  final GlobalKey _trayThumbKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();
  AnimationController? _flyController;
  String? _flyPath;
  Rect? _flyStart;
  Rect? _flyEnd;

  String? _error;
  Size? _lastPreviewLayout;
  StreamSubscription<AccelerometerEvent>? _levelSubscription;
  StreamSubscription<AccelerometerEvent>? _orientationSubscription;
  Timer? _doublePageGuideTimer;
  Timer? _previewProtectionTimer;
  bool _showDoublePageGuide = false;
  bool _doublePageGuideSeen = false;
  bool _previewProtectionVisible = false;
  bool _cameraPausedForLifecycle = false;
  DateTime? _cameraPausedAt;
  int _resumeEpoch = 0;
  bool _swapPages = false;
  DeviceOrientation _physicalOrientation = DeviceOrientation.portraitUp;
  Orientation? _lastOverlayOrientation;
  bool _orientationGuideScheduled = false;
  late final String _captureBatchId;
  int _captureSequence = 0;

  @override
  void initState() {
    super.initState();
    _captureBatchId =
        widget.captureBatchId ??
        'batch_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    _stagedPages.addAll(widget.initialPages);
    for (final page in widget.initialPages) {
      final sequence = page.captureSequence ?? 0;
      if (sequence > _captureSequence) _captureSequence = sequence;
    }
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    WidgetsBinding.instance.addObserver(this);
    _startOrientationUpdates();
    unawaited(_loadLevelPreference());
    unawaited(_loadSkipBatchReviewPreference());
    unawaited(_loadDoublePageGuidePreference());
    final seeded = widget.initialSession;
    if (seeded != null) {
      _setPreviewProtectionVisible(true);
      _session = seeded;
      seeded.addListener(_onSessionChanged);
      unawaited(_applyInitialFlash(seeded));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final layout = _lastPreviewLayout;
        if (layout == null) return;
        unawaited(_onPreviewReady(seeded));
      });
    } else {
      _enqueueCameraOp(_initCamera);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(
      '[ViewfinderCamera] lifecycle=$state pausedForLifecycle=$_cameraPausedForLifecycle '
      'capturing=$_capturing backend=${_session?.value.backend}',
    );

    if (state == AppLifecycleState.inactive) {
      return;
    }

    // 用 paused 而非 inactive：Android 上改闪光灯/系统短暂遮挡会进 inactive，
    // 若此时 dispose 会整页转圈重初始化，表现为「闪一下一直加载」。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_capturing) return;
      _cameraPausedForLifecycle = true;
      _cameraPausedAt = DateTime.now();
      _resumeEpoch++;
      _setPreviewProtectionVisible(true);
      _enqueueCameraOp(_pauseCamera);
    } else if (state == AppLifecycleState.resumed) {
      final wasPaused = _cameraPausedForLifecycle;
      final pausedAt = _cameraPausedAt;
      _cameraPausedForLifecycle = false;
      _cameraPausedAt = null;

      if (wasPaused) {
        final pausedFor = pausedAt == null
            ? Duration.zero
            : DateTime.now().difference(pausedAt);
        _enqueueCameraOp(
          () => _resumeCamera(forceReinitialize: pausedFor.inMinutes >= 10),
        );
      } else {
        _kickPreviewAfterTransientResume();
      }
    }
  }

  Future<void> _enqueueCameraOp(Future<void> Function() op) {
    _cameraOp = _cameraOp.then((_) => op()).catchError((
      Object e,
      StackTrace st,
    ) {
      debugPrint('[ViewfinderCamera] camera op failed: $e\n$st');
    });
    return _cameraOp;
  }

  Future<void> _releaseCamera() async {
    final session = _session;
    if (session == null) return;
    session.removeListener(_onSessionChanged);
    if (mounted) {
      setState(() => _session = null);
    } else {
      _session = null;
    }
    try {
      await session.disposeSession();
    } catch (e) {
      debugPrint('[ViewfinderCamera] dispose failed: $e');
    }
  }

  Future<void> _pauseCamera() async {
    final session = _session;
    if (session == null) return;
    try {
      await session.pause();
    } catch (e) {
      debugPrint('[ViewfinderCamera] pause failed: $e');
    }
  }

  Future<void> _resumeCamera({bool forceReinitialize = false}) async {
    final epoch = ++_resumeEpoch;
    final session = _session;
    _setPreviewProtectionVisible(true);
    if (session == null) {
      await _initCamera();
      return;
    }
    if (forceReinitialize) {
      debugPrint(
        '[ViewfinderCamera] resume forcing reinitialize after long pause',
      );
      await _releaseCamera();
      await _initCamera();
      return;
    }
    try {
      await session.resume();
      if (!mounted || !identical(_session, session)) return;
      await _applyInitialFlash(session);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_onPreviewReady(session)),
      );
      _schedulePreviewProtectionRelease(epoch);
    } catch (e) {
      debugPrint('[ViewfinderCamera] resume failed: $e');
      await _releaseCamera();
      await _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    if (_session != null && _session!.value.isInitialized) return;
    _initializing = true;
    _setPreviewProtectionVisible(true);
    try {
      if (_session != null) {
        await _releaseCamera();
      }
      final session = await CameraService().claimPreparedSession();
      if (!mounted) {
        await session.disposeSession();
        return;
      }
      if (_session != null) {
        await session.disposeSession();
        return;
      }
      session.addListener(_onSessionChanged);
      setState(() {
        _session = session;
        _error = null;
      });
      unawaited(_applyInitialFlash(session));
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_onPreviewReady(session)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _initializing = false;
    }
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _error = _session?.value.error;
    });
  }

  Future<void> _applyInitialFlash(CameraSession session) async {
    try {
      await session.setFlashMode(CameraSessionFlashMode.off);
    } catch (_) {}
    if (!mounted || !identical(_session, session)) return;
    if (_torchOn) {
      try {
        await session.setTorch(true);
      } catch (_) {}
    }
  }

  Future<void> _onPreviewReady(CameraSession session) async {
    if (!mounted || !identical(_session, session)) return;
    final layout = _lastPreviewLayout;
    if (layout == null || layout.isEmpty) return;
    unawaited(
      _applyFocusOnly(Offset(layout.width / 2, layout.height / 2), layout),
    );
    _schedulePreviewProtectionRelease(_resumeEpoch);
  }

  void _kickPreviewAfterTransientResume() {
    final session = _session;
    if (session == null || !session.value.isInitialized) {
      _enqueueCameraOp(_resumeCamera);
      return;
    }
    unawaited(_applyInitialFlash(session));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_session, session)) return;
      unawaited(_onPreviewReady(session));
    });
  }

  void _setPreviewProtectionVisible(bool visible) {
    _previewProtectionTimer?.cancel();
    _previewProtectionTimer = null;
    if (!mounted) {
      _previewProtectionVisible = visible;
      return;
    }
    if (_previewProtectionVisible == visible) return;
    setState(() => _previewProtectionVisible = visible);
  }

  void _schedulePreviewProtectionRelease(int epoch) {
    _previewProtectionTimer?.cancel();
    _previewProtectionTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || epoch != _resumeEpoch) return;
      setState(() => _previewProtectionVisible = false);
    });
  }

  Future<void> _loadLevelPreference() async {
    final enabled = await CameraCapturePreferences.loadLevelEnabled();
    if (!mounted) return;
    setState(() => _levelEnabled = enabled);
    if (enabled) _startLevelUpdates();
  }

  Future<void> _loadSkipBatchReviewPreference() async {
    final value = await CameraCapturePreferences.loadSkipBatchReview();
    if (mounted) setState(() => _skipBatchReview = value);
  }

  Future<void> _setSkipBatchReview(bool enabled) async {
    setState(() => _skipBatchReview = enabled);
    await CameraCapturePreferences.saveSkipBatchReview(enabled);
  }

  Future<void> _loadDoublePageGuidePreference() async {
    final seen = await CameraCapturePreferences.loadDoublePageGuideSeen();
    if (!mounted) return;
    _doublePageGuideSeen = seen;
  }

  Future<void> _setLevelEnabled(bool enabled) async {
    if (_levelEnabled == enabled) return;
    setState(() => _levelEnabled = enabled);
    await CameraCapturePreferences.saveLevelEnabled(enabled);
    if (enabled) {
      _startLevelUpdates();
    } else {
      await _stopLevelUpdates();
    }
  }

  void _startLevelUpdates() {
    if (_levelSubscription != null) return;
    _levelSubscription = accelerometerEventStream().listen((event) {
      if (!mounted || !_levelEnabled) return;
      const gravity = 9.80665;
      final tilt = Offset(
        (-event.x / gravity).clamp(-1.0, 1.0).toDouble(),
        (event.y / gravity).clamp(-1.0, 1.0).toDouble(),
      );
      if ((tilt - _levelTilt).distance < 0.02) return;
      setState(() => _levelTilt = tilt);
    });
  }

  void _startOrientationUpdates() {
    if (_orientationSubscription != null) return;
    _orientationSubscription =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen(
          (event) {
            if (!mounted) return;
            final next = _orientationFromAccelerometer(
              event,
              _physicalOrientation,
            );
            if (next == _physicalOrientation) return;
            setState(() => _physicalOrientation = next);
          },
          onError: (Object e) {
            debugPrint('[ViewfinderCamera] orientation sensor failed: $e');
          },
        );
  }

  DeviceOrientation _orientationFromAccelerometer(
    AccelerometerEvent event,
    DeviceOrientation current,
  ) {
    final x = event.x;
    final y = event.y;
    final strongestAxis = max(x.abs(), y.abs());
    if (strongestAxis < 3.0) return current;

    const hysteresis = 1.2;
    if (x.abs() > y.abs() + hysteresis) {
      return x > 0
          ? DeviceOrientation.landscapeRight
          : DeviceOrientation.landscapeLeft;
    }
    if (y.abs() > x.abs() + hysteresis) {
      return y > 0
          ? DeviceOrientation.portraitUp
          : DeviceOrientation.portraitDown;
    }
    return current;
  }

  double _overlayContentTurnsFor(Orientation layoutOrientation) {
    if (layoutOrientation == Orientation.landscape) return 0;
    return switch (_physicalOrientation) {
      DeviceOrientation.landscapeLeft => -.25,
      DeviceOrientation.landscapeRight => .25,
      DeviceOrientation.portraitDown => .5,
      DeviceOrientation.portraitUp => 0,
    };
  }

  Future<void> _stopLevelUpdates() async {
    final subscription = _levelSubscription;
    _levelSubscription = null;
    _levelTilt = Offset.zero;
    await subscription?.cancel();
  }

  Future<void> _onBack() async {
    if (_capturing) return;
    if (_viewerIndex != null) {
      setState(() => _viewerIndex = null);
      return;
    }
    if (_stackExpanded) {
      await _collapseStack();
      return;
    }
    if (_stagedPages.isNotEmpty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃已拍照片？'),
          content: Text('将丢弃 ${_stagedPages.length} 张暂存照片'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (mounted) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]),
      );
      Navigator.of(context).pop(null);
    }
  }

  bool _addStaged(CapturedPage page) {
    if (_stagedPages.length >= kMaxStaged) {
      AppToast.show(context, '最多拍摄 $kMaxStaged 张');
      return false;
    }
    setState(() {
      _stagedPages.insert(0, page);
    });
    _collapseStack();
    return true;
  }

  bool _addStagedBatch(List<CapturedPage> pages) {
    if (pages.isEmpty) return false;
    if (_stagedPages.length + pages.length > kMaxStaged) {
      AppToast.show(context, '最多拍摄 $kMaxStaged 张');
      return false;
    }
    setState(() => _stagedPages.insertAll(0, pages));
    _collapseStack();
    return true;
  }

  Future<void> _collapseStack() async {
    if (!_stackExpanded) return;
    final state = _stackKey.currentState;
    if (state != null) {
      await (state as dynamic).dismiss();
    }
    if (mounted) setState(() => _stackExpanded = false);
  }

  void _cancelFly() {
    _flyController?.stop();
    _flyController?.dispose();
    _flyController = null;
    _flyPath = null;
    _flyStart = null;
    _flyEnd = null;
  }

  Rect? _globalRectOf(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  void _startFly(String path) {
    _cancelFly();
    final overlayBox = context.findRenderObject() as RenderBox?;
    Offset toLocal(Offset g) => overlayBox?.globalToLocal(g) ?? g;

    Rect toLocalRect(Rect g) {
      final tl = toLocal(g.topLeft);
      return Rect.fromLTWH(tl.dx, tl.dy, g.width, g.height);
    }

    final startG =
        _globalRectOf(_previewKey) ??
        (Offset.zero & MediaQuery.sizeOf(context));
    var endG = _globalRectOf(_trayThumbKey);
    endG ??= estimateStagingThumbEndRect(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    controller.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      // Defer dispose: disposing an AnimationController inside its own
      // status listener can assert / corrupt ticker bookkeeping.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _flyController != controller) return;
        setState(_cancelFly);
      });
    });

    setState(() {
      _flyController = controller;
      _flyPath = path;
      _flyStart = toLocalRect(startG);
      _flyEnd = toLocalRect(endG!);
    });
    // After first frame, re-measure thumb if tray just appeared.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _flyPath != path) return;
      final better = _globalRectOf(_trayThumbKey);
      if (better != null) {
        setState(() => _flyEnd = toLocalRect(better));
      }
      controller.forward(from: 0);
    });
  }

  void _deleteStaged(int index) {
    if (index < 0 || index >= _stagedPages.length) return;
    final removed = _stagedPages.removeAt(index);
    try {
      File(removed.path).deleteSync();
    } catch (_) {}
    setState(() {
      if (_stagedPages.isEmpty) {
        _viewerIndex = null;
      } else if (_viewerIndex != null) {
        _viewerIndex = _viewerIndex!.clamp(0, _stagedPages.length - 1);
      }
    });
    if (_stagedPages.isEmpty) _collapseStack();
  }

  Future<void> _openEditor(int index) async {
    if (index < 0 || index >= _stagedPages.length) return;
    final path = _stagedPages[index].path;
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, animation, _) {
          return FadeTransition(
            opacity: animation,
            child: PhotoEditorPage(
              imagePath: path,
              onCompleted: (editedPath) {
                setState(() {
                  _stagedPages[index] = _stagedPages[index].copyWith(
                    path: editedPath,
                  );
                  _viewerIndex = index;
                });
              },
              onCancelled: () {},
            ),
          );
        },
      ),
    );
  }

  void _onComplete() {
    if (_stagedPages.isEmpty || _capturing) return;
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    Navigator.of(
      context,
    ).pop(CameraCaptureBatch(List<CapturedPage>.from(_stagedPages)));
  }

  void _onCaptureModeChanged(CaptureMode mode) {
    if (_captureMode != mode) {
      setState(() {
        _captureMode = mode;
        if (mode == CaptureMode.singlePage) _swapPages = false;
      });
    }
    if (mode == CaptureMode.doublePage) {
      _showDoublePageGuideMessage();
    } else {
      _doublePageGuideTimer?.cancel();
      if (_showDoublePageGuide) {
        setState(() => _showDoublePageGuide = false);
      }
    }
  }

  void _toggleSwapPages() {
    if (!mounted) return;
    setState(() => _swapPages = !_swapPages);
  }

  void _handleOverlayOrientation(Orientation orientation) {
    final previous = _lastOverlayOrientation;
    _lastOverlayOrientation = orientation;
    if (previous == null ||
        previous == orientation ||
        _captureMode != CaptureMode.doublePage ||
        _orientationGuideScheduled) {
      return;
    }
    _orientationGuideScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _orientationGuideScheduled = false;
      if (!mounted || _captureMode != CaptureMode.doublePage) return;
      _showDoublePageGuideMessage();
    });
  }

  void _showDoublePageGuideMessage() {
    _doublePageGuideTimer?.cancel();
    if (!_showDoublePageGuide) {
      setState(() => _showDoublePageGuide = true);
    }
    final duration = _doublePageGuideSeen
        ? const Duration(milliseconds: 2400)
        : const Duration(milliseconds: 4000);
    if (!_doublePageGuideSeen) {
      _doublePageGuideSeen = true;
      unawaited(CameraCapturePreferences.markDoublePageGuideSeen());
    }
    _doublePageGuideTimer = Timer(duration, () {
      if (mounted) setState(() => _showDoublePageGuide = false);
    });
  }

  Future<void> _applyFocusOnly(Offset localInPreview, Size layout) async {
    final session = _session;
    if (session == null || !session.value.isInitialized) return;
    final nx = (localInPreview.dx / layout.width).clamp(0.0, 1.0).toDouble();
    final ny = (localInPreview.dy / layout.height).clamp(0.0, 1.0).toDouble();
    try {
      await session.focus(Offset(nx, ny));
    } catch (e) {
      debugPrint('[ViewfinderCamera] AF point failed: $e');
    }
  }

  CameraFlashChoice get _flashChoice {
    switch (_flash) {
      case CameraSessionFlashMode.on:
        return CameraFlashChoice.on;
      case CameraSessionFlashMode.auto:
        return CameraFlashChoice.auto;
      default:
        return CameraFlashChoice.off;
    }
  }

  Future<void> _setFlash(CameraFlashChoice choice) async {
    final next = switch (choice) {
      CameraFlashChoice.on => CameraSessionFlashMode.on,
      CameraFlashChoice.auto => CameraSessionFlashMode.auto,
      CameraFlashChoice.off => CameraSessionFlashMode.off,
    };
    if (next == _flash) return;
    if (next != CameraSessionFlashMode.off) {
      await _ensureFlashCapableLens();
    }
    if (!mounted) return;
    setState(() => _flash = next);
  }

  Future<void> _ensureFlashCapableLens() async {
    final session = _session;
    final current = session?.value.currentLens;
    if (session == null || current == null || current.supportsFlash) return;
    for (final lens in session.value.lenses) {
      if (lens.role == CameraLensRole.wide &&
          lens.supportsFlash &&
          lens.available) {
        await session.switchLens(lens);
        return;
      }
    }
  }

  Future<void> _setTorch(bool on) async {
    if (on == _torchOn) return;
    // 先刷新滑块，再后台切手电筒——与闪光灯偏好同样即时反馈。
    setState(() => _torchOn = on);
    final session = _session;
    if (session == null || !session.value.isInitialized) return;
    try {
      if (on) await _ensureFlashCapableLens();
      await session.setTorch(on);
    } catch (e) {
      debugPrint('[ViewfinderCamera] setFlashMode torch failed: $e');
      if (mounted && _torchOn == on) {
        setState(() => _torchOn = !on);
        AppToast.show(context, '当前设备无法开灯');
      }
    }
  }

  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  void _closeSettings() {
    if (_settingsOpen) setState(() => _settingsOpen = false);
  }

  /// Apply flash only when needed. Skip focus/exposure resets — already auto
  /// from init/tap-to-focus; awaiting them on every shutter adds visible lag.
  Future<void> _prepareCapture(CameraSession session) async {
    if (_torchOn) return;
    try {
      if (_flash != CameraSessionFlashMode.off) {
        await _ensureFlashCapableLens();
      }
      await session
          .setFlashMode(_flash)
          .timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('[ViewfinderCamera] setFlashMode before capture failed: $e');
    }
  }

  Future<void> _resetFlashAfterCapture(CameraSession session) async {
    if (_torchOn) {
      try {
        await session.setTorch(true).timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      return;
    }
    if (_flash == CameraSessionFlashMode.off) return;
    try {
      await session
          .setFlashMode(CameraSessionFlashMode.off)
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  Future<void> _onShutter() async {
    final session = _session;
    if (session == null || !session.value.isInitialized || _capturing) return;
    final requiredSlots = _captureMode == CaptureMode.doublePage ? 2 : 1;
    if (_stagedPages.length + requiredSlots > kMaxStaged) {
      AppToast.show(context, '剩余暂存空间不足，双页拍需要 2 个位置');
      return;
    }

    _closeSettings();
    setState(() => _capturing = true);
    final sequence = ++_captureSequence;
    var flashResetScheduled = false;
    try {
      final previewLayout = _lastPreviewLayout;
      if (previewLayout == null || previewLayout.isEmpty) return;
      await _prepareCapture(session);
      if (!mounted) return;
      final captureTimer = Stopwatch()..start();
      final shot = await session.capture(previewLayoutSize: previewLayout);
      debugPrint(
        '[ViewfinderCamera] capture=${captureTimer.elapsedMilliseconds}ms '
        'backend=${session.value.backend}',
      );
      if (!mounted) return;
      if (_flash != CameraSessionFlashMode.off) {
        flashResetScheduled = true;
        unawaited(_resetFlashAfterCapture(session));
      }
      if (!mounted) return;
      if (_captureMode == CaptureMode.doublePage) {
        final pages = await DoublePageCaptureService.split(
          shot.path,
          swapped: _swapPages,
          captureBatchId: _captureBatchId,
          captureSequence: sequence,
        );
        if (!mounted) return;
        if (_addStagedBatch(pages)) {
          _startFly(pages.first.path);
        }
      } else {
        final page = CapturedPage(
          path: shot.path,
          inputKind: CaptureInputKind.camera,
          capturedAt: DateTime.now().toIso8601String(),
          captureBatchId: _captureBatchId,
          captureSequence: sequence,
        );
        if (_addStaged(page)) {
          _startFly(shot.path);
        }
      }
    } catch (e) {
      debugPrint('[ViewfinderCamera] shutter failed: $e');
      if (_flash != CameraSessionFlashMode.off && !flashResetScheduled) {
        unawaited(_resetFlashAfterCapture(session));
      }
      if (mounted) AppToast.show(context, '拍照失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _capturing = false);
      } else {
        _capturing = false;
      }
    }
  }

  Future<void> _onImportFromAlbum() async {
    if (_capturing) return;
    final remaining = kMaxStaged - _stagedPages.length;
    if (remaining <= 0) {
      AppToast.show(context, '最多拍摄 $kMaxStaged 张');
      return;
    }

    final permitted = await PermissionService().requestGalleryPermission();
    if (!mounted) return;
    if (!permitted) {
      PermissionService().showPermissionDeniedDialog(context, '相册');
      return;
    }

    // Keep camera preview alive — no release, no spinner overlay.
    // System picker slides up; limit once to at most 5 (and remaining slots).
    final limit = remaining < 5 ? remaining : 5;
    try {
      final files = await CameraService().pickMultipleFromGallery(
        maxImages: limit,
      );
      if (!mounted || files.isEmpty) return;
      for (final file in files) {
        final sequence = ++_captureSequence;
        if (!_addStaged(
          CapturedPage(
            path: file.path,
            inputKind: CaptureInputKind.gallery,
            capturedAt: DateTime.now().toIso8601String(),
            captureBatchId: _captureBatchId,
            captureSequence: sequence,
          ),
        )) {
          break;
        }
      }
    } catch (e) {
      debugPrint('[ViewfinderCamera] import failed: $e');
      if (mounted) AppToast.show(context, '导入失败，请重试');
    }
  }

  Future<void> _showCaptureHelp() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: BookFlowTheme.ink,
      showDragHandle: true,
      builder: (context) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '拍清楚，识别会更准确',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 16),
              _CaptureHelpLine(icon: Icons.crop_free, text: '让完整书页进入取景框'),
              _CaptureHelpLine(
                icon: Icons.wb_sunny_outlined,
                text: '避免阴影、反光和过暗环境',
              ),
              _CaptureHelpLine(
                icon: Icons.center_focus_strong,
                text: '文字清晰后再按下快门',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(Size layout) {
    final session = _session!;
    return GestureDetector(
      onTapDown: (d) => _applyFocusOnly(d.localPosition, layout),
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(child: session.buildPreview(layoutSize: layout)),
            if (_levelEnabled)
              Center(child: CameraLevelIndicator(tilt: _levelTilt)),
          ],
        ),
      ),
    );
  }

  Future<void> _switchLens(CameraLensOption lens) async {
    final session = _session;
    if (session == null || session.value.isSwitchingLens || _capturing) return;
    _closeSettings();
    try {
      await session.switchLens(lens);
      if (!mounted) return;
      final layout = _lastPreviewLayout;
      if (layout != null) {
        unawaited(_applyFocusOnly(layout.center(Offset.zero), layout));
      }
    } catch (error) {
      debugPrint('[ViewfinderCamera] switch lens failed: $error');
      if (mounted) AppToast.show(context, '镜头切换失败，已保留当前镜头');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Builder(
          builder: (context) {
            if (_error != null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.white)),
                    TextButton(onPressed: _onBack, child: const Text('返回')),
                  ],
                ),
              );
            }

            // No spinner on open: show chrome shell immediately; preview fills in.
            final session = _session;
            final sessionValue = session?.value;
            final previewReady = sessionValue?.isInitialized == true;
            final chromeEnabled =
                previewReady &&
                sessionValue?.isSwitchingLens != true &&
                !_capturing &&
                !_stackExpanded &&
                _viewerIndex == null;

            return Stack(
              fit: StackFit.expand,
              children: [
                Stack(
                  fit: StackFit.expand,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final layout = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        final mediaQuery = MediaQuery.of(context);
                        final safeTop = mediaQuery.padding.top;
                        final safeBottom = mediaQuery.padding.bottom;
                        final isLandscape =
                            mediaQuery.orientation == Orientation.landscape;
                        final topChromeHeight = safeTop + 48;
                        final bottomControlHeight = isLandscape
                            ? max(safeBottom + 104, layout.height * .18)
                            : (layout.height * .20).clamp(
                                safeBottom + 168,
                                safeBottom + 230,
                              );
                        final previewHeight = max(
                          0.0,
                          layout.height - topChromeHeight - bottomControlHeight,
                        );
                        final previewLayout = Size(layout.width, previewHeight);
                        final bottomBarBottom = safeBottom + 8;
                        final guideBottomOffset =
                            bottomControlHeight + (isLandscape ? 24.0 : 24.0);
                        _lastPreviewLayout = previewLayout;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (session != null)
                              Positioned(
                                top: topChromeHeight,
                                left: 0,
                                right: 0,
                                bottom: bottomControlHeight,
                                child: KeyedSubtree(
                                  key: _previewKey,
                                  child: _buildPreview(previewLayout),
                                ),
                              )
                            else
                              const ColoredBox(color: Colors.black),
                            if (_previewProtectionVisible)
                              Positioned(
                                key: const Key('viewfinder_preview_protection'),
                                top: topChromeHeight,
                                left: 0,
                                right: 0,
                                bottom: bottomControlHeight,
                                child: _CameraPreviewProtectionOverlay(
                                  initialized: previewReady,
                                ),
                              ),
                            Positioned(
                              key: const Key(
                                'viewfinder_bottom_control_surface',
                              ),
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: bottomControlHeight,
                              child: const IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: BookFlowTheme.camera,
                                  ),
                                ),
                              ),
                            ),
                            if (_captureMode == CaptureMode.doublePage)
                              Positioned(
                                top: topChromeHeight,
                                left: 0,
                                right: 0,
                                bottom: bottomControlHeight,
                                child: OrientationBuilder(
                                  builder: (context, orientation) {
                                    _handleOverlayOrientation(orientation);
                                    return DoublePageViewfinderOverlay(
                                      isLandscape:
                                          orientation == Orientation.landscape,
                                      contentTurns: _overlayContentTurnsFor(
                                        orientation,
                                      ),
                                      swapped: _swapPages,
                                      onSwap: _toggleSwapPages,
                                    );
                                  },
                                ),
                              ),
                            Positioned(
                              top: topChromeHeight + 24,
                              left: 24,
                              right: 24,
                              bottom: bottomControlHeight + 24,
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _BookScanFramePainter(
                                    doublePage:
                                        _captureMode == CaptureMode.doublePage,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 20,
                              right: 20,
                              bottom: guideBottomOffset,
                              child: AnimatedOpacity(
                                opacity: _showDoublePageGuide ? 1 : 0,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: OrientationBuilder(
                                  builder: (context, orientation) =>
                                      DoublePageGuide(
                                        isLandscape:
                                            orientation ==
                                            Orientation.landscape,
                                      ),
                                ),
                              ),
                            ),
                            if (_capturing &&
                                _captureMode == CaptureMode.doublePage)
                              const Center(
                                child: _DoublePageProcessingIndicator(),
                              ),
                            if (_settingsOpen)
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _closeSettings,
                                  child: const ColoredBox(
                                    color: Color(0x33000000),
                                  ),
                                ),
                              ),
                            // heightFactor=0 时高度为 0，避免负数 top 面板叠在顶栏上抢走点击。
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: ClipRect(
                                child: AnimatedAlign(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  heightFactor: _settingsOpen ? 1.0 : 0.0,
                                  child: IgnorePointer(
                                    ignoring: !_settingsOpen,
                                    child: ViewfinderCameraSettingsPanel(
                                      flashChoice: _flashChoice,
                                      onFlashChanged: _setFlash,
                                      torchOn: _torchOn,
                                      onTorchChanged: _setTorch,
                                      levelEnabled: _levelEnabled,
                                      onLevelChanged: _setLevelEnabled,
                                      skipBatchReview: _skipBatchReview,
                                      onSkipBatchReviewChanged:
                                          _setSkipBatchReview,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: ViewfinderCameraTopBar(
                                enabled: chromeEnabled,
                                onBack: _onBack,
                                captureMode: _captureMode,
                                onCaptureModeChanged: _onCaptureModeChanged,
                                onImport: _onImportFromAlbum,
                                onSettings: _toggleSettings,
                              ),
                            ),
                            if (previewReady &&
                                sessionValue != null &&
                                sessionValue.lenses
                                        .where((lens) => lens.available)
                                        .length >
                                    1)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: bottomControlHeight + 16,
                                child: Center(
                                  child: CameraLensSwitcher(
                                    lenses: sessionValue.lenses
                                        .where((lens) => lens.available)
                                        .toList(growable: false),
                                    selected: sessionValue.currentLens,
                                    enabled: chromeEnabled,
                                    onChanged: _switchLens,
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: bottomBarBottom,
                              child: ViewfinderCameraBottomBar(
                                enabled: chromeEnabled,
                                onShutter: _onShutter,
                                onImport: _onImportFromAlbum,
                                onHelp: _showCaptureHelp,
                                captureMode: _captureMode,
                                trailing: _stagedPages.isEmpty
                                    ? null
                                    : CameraStagingTray(
                                        paths: _stagedPaths,
                                        thumbKey: _trayThumbKey,
                                        thumbInteractive:
                                            !_capturing && _viewerIndex == null,
                                        completeInteractive:
                                            !_capturing && _viewerIndex == null,
                                        onExpand: () {
                                          if (_viewerIndex != null) return;
                                          setState(
                                            () => _stackExpanded =
                                                !_stackExpanded,
                                          );
                                        },
                                        onComplete: _onComplete,
                                      ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
                if (_stackExpanded)
                  CameraStagingStack(
                    key: _stackKey,
                    paths: _stagedPaths,
                    onOpen: (i) => setState(() => _viewerIndex = i),
                    onDelete: _deleteStaged,
                  ),
                if (_viewerIndex != null)
                  CameraStagingViewer(
                    paths: _stagedPaths,
                    initialIndex: _viewerIndex!,
                    onClose: () => setState(() => _viewerIndex = null),
                    onDelete: _deleteStaged,
                    onEdit: _openEditor,
                    onComplete: _onComplete,
                  ),
                if (_flyPath != null &&
                    _flyController != null &&
                    _flyStart != null &&
                    _flyEnd != null)
                  CaptureFlyToTrayOverlay(
                    path: _flyPath!,
                    animation: _flyController!,
                    startRect: _flyStart!,
                    endRect: _flyEnd!,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopLevelUpdates());
    unawaited(_orientationSubscription?.cancel());
    _orientationSubscription = null;
    _cancelFly();
    _previewProtectionTimer?.cancel();
    _doublePageGuideTimer?.cancel();
    final session = _session;
    _session = null;
    if (session != null) {
      session.removeListener(_onSessionChanged);
      unawaited(() async {
        await session.disposeSession();
      }());
    }
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    super.dispose();
  }
}

class _CaptureHelpLine extends StatelessWidget {
  const _CaptureHelpLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: BookFlowTheme.primarySoft, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookScanFramePainter extends CustomPainter {
  const _BookScanFramePainter({required this.doublePage});

  final bool doublePage;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .88)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const corner = 28.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final path = Path()
      ..moveTo(rect.left, rect.top + corner)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + corner, rect.top)
      ..moveTo(rect.right - corner, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + corner)
      ..moveTo(rect.right, rect.bottom - corner)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - corner, rect.bottom)
      ..moveTo(rect.left + corner, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - corner);
    canvas.drawPath(path, paint);
    if (doublePage) {
      final centerPaint = Paint()
        ..color = Colors.white.withValues(alpha: .42)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(size.width / 2, 10),
        Offset(size.width / 2, size.height - 10),
        centerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BookScanFramePainter oldDelegate) {
    return oldDelegate.doublePage != doublePage;
  }
}

class _CameraPreviewProtectionOverlay extends StatelessWidget {
  const _CameraPreviewProtectionOverlay({required this.initialized});

  final bool initialized;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: initialized ? 0.18 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Colors.black),
          child: Center(
            child: initialized
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .58),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24, width: .5),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          '正在唤醒相机…',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _DoublePageProcessingIndicator extends StatelessWidget {
  const _DoublePageProcessingIndicator();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        key: const Key('double_page_processing'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 10),
            Text(
              '正在校正并拆分双页…',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
