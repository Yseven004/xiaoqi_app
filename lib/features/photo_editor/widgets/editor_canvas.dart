import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/editor_state.dart';
import '../models/editor_action.dart' as models;

/// 裁剪拖拽手柄
enum _CropHandle {
  none,
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
  center,
}

/// 编辑器画布组件
class EditorCanvas extends StatefulWidget {
  final String imagePath;
  final EditorTool currentTool;
  final EditorState editorState;
  final Color penColor;
  final double penStrokeWidth;
  final double mosaicBlockSize;
  final Function(List<models.EditorAction>) onActionsChanged;
  final List<models.EditorAction> actions;
  final int currentActionIndex;
  final bool isEraserMode;
  final bool isPenActive;

  // 裁剪参数
  final Rect? cropRect;
  final double cropRotation;
  final Size? originalImageSize;
  final Function(Rect)? onCropRectChanged;
  final Function(double)? onCropRotationChanged;
  final Function(Size)? onCanvasSizeReady;
  final ValueNotifier<int>? cropResetNotifier;
  final int imageVersion; // 图片版本号，用于强制刷新缓存
  final ValueChanged<bool>? onPanModeChanged; // 平移模式变化通知父组件

  const EditorCanvas({
    super.key,
    required this.imagePath,
    required this.currentTool,
    required this.editorState,
    required this.penColor,
    required this.penStrokeWidth,
    required this.mosaicBlockSize,
    required this.onActionsChanged,
    required this.actions,
    required this.currentActionIndex,
    this.isEraserMode = false,
    this.isPenActive = false,
    this.cropRect,
    this.cropRotation = 0.0,
    this.originalImageSize,
    this.onCropRectChanged,
    this.onCropRotationChanged,
    this.onCanvasSizeReady,
    this.cropResetNotifier,
    required this.imageVersion,
    this.onPanModeChanged,
  });

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas>
    with TickerProviderStateMixin {
  // 当前正在绘制的路径点（内容空间坐标）
  List<Offset> _currentPoints = [];

  // 画布尺寸（屏幕像素）
  Size _canvasSize = Size.zero;

  // 当前手指位置（内容空间坐标，用于显示橡皮擦范围）
  Offset? _currentFingerPosition;

  // --- 缩放/平移状态（逻辑值，手势计算用） ---
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // --- 缩放/平移显示值（渲染用，动画过渡） ---
  double _displayScale = 1.0;
  Offset _displayOffset = Offset.zero;

  // 绘制重绘通知器（避免 setState 闪屏）
  final ValueNotifier<int> _drawRepaint = ValueNotifier(0);

  // 手势追踪
  double _initialScale = 1.0;
  Offset _initialOffset = Offset.zero;
  Offset _initialFocalPoint = Offset.zero;
  bool _isZooming = false;

  // 延迟绘制
  Offset? _pendingStartPoint;

  // 平移模式：双指缩放后单指拖动画布，双击切回标注
  bool _isPanMode = false;
  Offset? _panStartPos;
  DateTime _lastPanTap = DateTime.now();

  // --- 裁剪状态 ---
  _CropHandle _draggedHandle = _CropHandle.none;
  Rect _imageDisplayRect = Rect.zero;
  bool _isCropDragging = false;
  double _preCropScale = 1.0;
  Offset _preCropOffset = Offset.zero;
  bool _cropCompleted = false; // 标记裁剪已完成（非取消）

  // 预览捕获

  // 裁剪缩放动画
  AnimationController? _cropAnimCtrl;

  // 裁剪模式下的基准缩放（进入裁剪后的初始状态，还原时恢复到此）
  double _cropBaseScale = 1.0;
  Offset _cropBaseOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.cropResetNotifier?.addListener(_onCropResetSignal);
  }

  @override
  void dispose() {
    widget.cropResetNotifier?.removeListener(_onCropResetSignal);
    _cropAnimCtrl?.dispose();
    _drawRepaint.dispose();
    super.dispose();
  }

  /// 还原信号：重置裁剪框时同步重置画布缩放
  void _onCropResetSignal() {
    if (_cropAnimCtrl?.isAnimating == true) {
      _cropAnimCtrl?.stop();
    }
    _animateCropTransition(
      fromScale: _displayScale,
      fromOffset: _displayOffset,
      toScale: _cropBaseScale,
      toOffset: _cropBaseOffset,
    );
    setState(() {
      _scale = _cropBaseScale;
      _offset = _cropBaseOffset;
    });
  }

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);

    final wasCrop = oldWidget.currentTool == EditorTool.crop;
    final isCrop = widget.currentTool == EditorTool.crop;

    // 进入裁剪模式 → 动画缩小并居中
    if (!wasCrop && isCrop) {
      _preCropScale = _scale;
      _preCropOffset = _offset;

      const padding = 32.0;
      final sw = (_canvasSize.width - padding * 2) / _canvasSize.width;
      final sh = (_canvasSize.height - padding * 2) / _canvasSize.height;
      final targetScale = (sw < sh ? sw : sh).clamp(0.6, 1.0);
      const targetOffset = Offset.zero;

      _scale = targetScale;
      _offset = targetOffset;
      _cropBaseScale = targetScale;
      _cropBaseOffset = targetOffset;

      _animateCropTransition(
        fromScale: _displayScale,
        fromOffset: _displayOffset,
        toScale: targetScale,
        toOffset: targetOffset,
      );
    }

    // 裁剪模式下旋转角度变化 → 重新适配缩放以保持图片在屏幕内
    if (isCrop &&
        oldWidget.cropRotation != widget.cropRotation &&
        _imageDisplayRect != Rect.zero) {
      _fitScaleForRotation();
    }

    // 退出裁剪模式 → 动画恢复
    if (wasCrop && !isCrop) {
      if (_cropCompleted) {
        // 裁剪完成：重置为默认缩放，显示裁剪后的新图片
        _cropCompleted = false;
        _scale = 1.0;
        _offset = Offset.zero;
        _displayScale = 1.0;
        _displayOffset = Offset.zero;
      } else {
        // 取消裁剪：恢复进入前的缩放
        _scale = _preCropScale;
        _offset = _preCropOffset;
      }

      _animateCropTransition(
        fromScale: _displayScale,
        fromOffset: _displayOffset,
        toScale: _scale,
        toOffset: _offset,
      );
    }

    // 退出画笔/马赛克模式 → 重置缩放
    final wasAnnotation = oldWidget.currentTool == EditorTool.pen ||
        oldWidget.currentTool == EditorTool.mosaic;
    final isAnnotation = widget.currentTool == EditorTool.pen ||
        widget.currentTool == EditorTool.mosaic;
    if (wasAnnotation && !isAnnotation) {
      _scale = 1.0;
      _offset = Offset.zero;
      _displayScale = 1.0;
      _displayOffset = Offset.zero;
      _isPanMode = false;
      _panStartPos = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onPanModeChanged?.call(false);
      });
    }

  }

  /// 裁剪缩放动画过渡
  void _animateCropTransition({
    required double fromScale,
    required Offset fromOffset,
    required double toScale,
    required Offset toOffset,
  }) {
    _cropAnimCtrl?.dispose();
    _cropAnimCtrl = AnimationController(
      duration: const Duration(milliseconds: 380),
      vsync: this,
    );

    final scaleAnim = Tween<double>(begin: fromScale, end: toScale)
        .animate(CurvedAnimation(
      parent: _cropAnimCtrl!,
      curve: Curves.easeInOut,
    ));
    final offsetAnim = Tween<Offset>(begin: fromOffset, end: toOffset)
        .animate(CurvedAnimation(
      parent: _cropAnimCtrl!,
      curve: Curves.easeInOut,
    ));

    _cropAnimCtrl!
      ..addListener(() {
        setState(() {
          _displayScale = scaleAnim.value;
          _displayOffset = offsetAnim.value;
        });
      })
      ..forward();
  }

  /// 旋转后重新计算缩放，保证旋转后的图片完整在屏幕内
  void _fitScaleForRotation() {
    final rect = _imageDisplayRect;
    final angle = widget.cropRotation;

    // 计算矩形旋转后的包围盒尺寸
    // rotW = |w·cosθ| + |h·sinθ|, rotH = |w·sinθ| + |h·cosθ|
    final cosA = cos(angle).abs();
    final sinA = sin(angle).abs();
    final rotW = rect.width * cosA + rect.height * sinA;
    final rotH = rect.width * sinA + rect.height * cosA;

    const padding = 32.0;
    final availableW = _canvasSize.width - padding * 2;
    final availableH = _canvasSize.height - padding * 2;

    final targetScale = (availableW / rotW < availableH / rotH
            ? availableW / rotW
            : availableH / rotH)
        .clamp(0.6, 1.0);

    const targetOffset = Offset.zero;

    _cropBaseScale = targetScale;
    _cropBaseOffset = targetOffset;

    _animateCropTransition(
      fromScale: _displayScale,
      fromOffset: _displayOffset,
      toScale: targetScale,
      toOffset: targetOffset,
    );

    _scale = targetScale;
    _offset = targetOffset;
  }

  /// 自动放大动画过渡
  void _animateAutoZoom({
    required double fromScale,
    required Offset fromOffset,
    required double toScale,
    required Offset toOffset,
    VoidCallback? onComplete,
  }) {
    _cropAnimCtrl?.dispose();
    _cropAnimCtrl = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    final scaleAnim = Tween<double>(begin: fromScale, end: toScale)
        .animate(CurvedAnimation(
      parent: _cropAnimCtrl!,
      curve: Curves.easeOutCubic,
    ));
    final offsetAnim = Tween<Offset>(begin: fromOffset, end: toOffset)
        .animate(CurvedAnimation(
      parent: _cropAnimCtrl!,
      curve: Curves.easeOutCubic,
    ));

    _cropAnimCtrl!
      ..addListener(() {
        setState(() {
          _scale = scaleAnim.value;
          _offset = offsetAnim.value;
          _displayScale = _scale;
          _displayOffset = _offset;
        });
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          onComplete?.call();
        }
      })
      ..forward();
  }

  /// BoxFit.contain 下图片在画布中的实际显示区域（含letterbox偏移）
  Rect _computeImageDisplayRect() {
    if (widget.originalImageSize == null || _canvasSize == Size.zero) {
      return Rect.zero;
    }
    final img = widget.originalImageSize!;
    final canvasAspect = _canvasSize.width / _canvasSize.height;
    final imgAspect = img.width / img.height;

    if (imgAspect > canvasAspect) {
      final h = _canvasSize.width / imgAspect;
      final top = (_canvasSize.height - h) / 2;
      return Rect.fromLTWH(0, top, _canvasSize.width, h);
    } else {
      final w = _canvasSize.height * imgAspect;
      final left = (_canvasSize.width - w) / 2;
      return Rect.fromLTWH(left, 0, w, _canvasSize.height);
    }
  }

  /// 屏幕坐标 → 内容空间坐标
  /// Transform 矩阵: T(cx+ox, cy+oy) * S(s) * R(a) * T(-cx, -cy)
  /// 逆变换: T(cx,cy) * R(-a) * S(1/s) * T(-cx-ox, -cy-oy)
  Offset _screenToContent(Offset screenPoint) {
    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;
    final angle = widget.cropRotation;

    // 1. 减去平移: T(-cx-ox, -cy-oy)
    double dx = screenPoint.dx - cx - _offset.dx;
    double dy = screenPoint.dy - cy - _offset.dy;
    // 2. 反缩放: S(1/s)
    dx /= _scale;
    dy /= _scale;
    // 3. 反旋转: R(-angle)
    if (angle != 0.0) {
      final cosA = cos(-angle);
      final sinA = sin(-angle);
      final rx = dx * cosA - dy * sinA;
      final ry = dx * sinA + dy * cosA;
      dx = rx;
      dy = ry;
    }
    // 4. 加回中心: T(cx, cy)
    return Offset(dx + cx, dy + cy);
  }

  /// 检测触摸点命中的裁剪手柄
  /// 优先匹配四角 → 边缘中点 → 区域内部 → 无匹配
  static const double _cornerHitRadius = 32.0;
  static const double _edgeHitRadius = 28.0;

  _CropHandle _hitTestCropHandle(Offset point, Rect rect) {
    // 优先检测四角（更大的命中半径）
    const cr = _cornerHitRadius;
    if ((rect.topLeft - point).distance < cr) return _CropHandle.topLeft;
    if ((rect.topRight - point).distance < cr) return _CropHandle.topRight;
    if ((rect.bottomLeft - point).distance < cr) return _CropHandle.bottomLeft;
    if ((rect.bottomRight - point).distance < cr) return _CropHandle.bottomRight;

    // 检测四边中点
    const er = _edgeHitRadius;
    final midTop = Offset(rect.center.dx, rect.top);
    final midBottom = Offset(rect.center.dx, rect.bottom);
    final midLeft = Offset(rect.left, rect.center.dy);
    final midRight = Offset(rect.right, rect.center.dy);
    if ((midTop - point).distance < er) return _CropHandle.top;
    if ((midBottom - point).distance < er) return _CropHandle.bottom;
    if ((midLeft - point).distance < er) return _CropHandle.left;
    if ((midRight - point).distance < er) return _CropHandle.right;

    // 检测四条边（靠近边框15像素内也算命中）
    const edgeMargin = 15.0;
    if (point.dx >= rect.left - edgeMargin &&
        point.dx <= rect.right + edgeMargin &&
        point.dy >= rect.top - edgeMargin &&
        point.dy <= rect.bottom + edgeMargin) {
      // 判断最靠近哪条边
      final distTop = (point.dy - rect.top).abs();
      final distBottom = (point.dy - rect.bottom).abs();
      final distLeft = (point.dx - rect.left).abs();
      final distRight = (point.dx - rect.right).abs();
      final minDist = [distTop, distBottom, distLeft, distRight]
          .reduce((a, b) => a < b ? a : b);
      if (minDist == distTop) return _CropHandle.top;
      if (minDist == distBottom) return _CropHandle.bottom;
      if (minDist == distLeft) return _CropHandle.left;
      if (minDist == distRight) return _CropHandle.right;
    }

    // 在裁剪框内部 → 移动整个框
    if (rect.contains(point)) return _CropHandle.center;

    return _CropHandle.none;
  }

  /// 根据手柄拖拽计算新裁剪矩形
  Rect? _computeUpdatedCropRect(
      Rect rect, _CropHandle handle, Offset currentPos) {
    final displayRect = _imageDisplayRect;
    const minSize = 30.0;

    double l = rect.left, t = rect.top, r = rect.right, b = rect.bottom;

    switch (handle) {
      case _CropHandle.topLeft:
        l = currentPos.dx;
        t = currentPos.dy;
        break;
      case _CropHandle.top:
        t = currentPos.dy;
        break;
      case _CropHandle.topRight:
        r = currentPos.dx;
        t = currentPos.dy;
        break;
      case _CropHandle.right:
        r = currentPos.dx;
        break;
      case _CropHandle.bottomRight:
        r = currentPos.dx;
        b = currentPos.dy;
        break;
      case _CropHandle.bottom:
        b = currentPos.dy;
        break;
      case _CropHandle.bottomLeft:
        l = currentPos.dx;
        b = currentPos.dy;
        break;
      case _CropHandle.left:
        l = currentPos.dx;
        break;
      case _CropHandle.center:
        final dx = currentPos.dx - rect.center.dx;
        final dy = currentPos.dy - rect.center.dy;
        var moved = rect.translate(dx, dy);
        if (moved.left < displayRect.left) {
          moved = moved.translate(displayRect.left - moved.left, 0);
        }
        if (moved.top < displayRect.top) {
          moved = moved.translate(0, displayRect.top - moved.top);
        }
        if (moved.right > displayRect.right) {
          moved = moved.translate(displayRect.right - moved.right, 0);
        }
        if (moved.bottom > displayRect.bottom) {
          moved = moved.translate(0, displayRect.bottom - moved.bottom);
        }
        return moved;
      case _CropHandle.none:
        return null;
    }

    return Rect.fromLTRB(
      l.clamp(displayRect.left, r - minSize),
      t.clamp(displayRect.top, b - minSize),
      r.clamp(l + minSize, displayRect.right),
      b.clamp(t + minSize, displayRect.bottom),
    );
  }

  /// 平移模式下限制偏移量，基于图片实际显示区域约束
  Offset _constrainPanOffset(Offset offset) {
    final rect = _imageDisplayRect;
    if (rect.isEmpty || _scale <= 1.0) return Offset.zero;

    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;

    final imgLeft = (rect.left - cx) * _scale + cx;
    final imgRight = (rect.right - cx) * _scale + cx;
    final imgTop = (rect.top - cy) * _scale + cy;
    final imgBottom = (rect.bottom - cy) * _scale + cy;

    return Offset(
      offset.dx.clamp(_canvasSize.width - imgRight, -imgLeft),
      offset.dy.clamp(_canvasSize.height - imgBottom, -imgTop),
    );
  }

  /// 限制偏移量，保证内容不跑出屏幕
  Offset _constrainOffset(Offset offset, double scale) {
    if (scale <= 1.0) return Offset.zero;

    final maxDx = 0.0;
    final minDx = _canvasSize.width * (1.0 - scale);
    final maxDy = 0.0;
    final minDy = _canvasSize.height * (1.0 - scale);

    return Offset(
      offset.dx.clamp(minDx, maxDx),
      offset.dy.clamp(minDy, maxDy),
    );
  }

  /// 计算自动放大到裁剪框区域的缩放和目标偏移
  _AutoZoomResult _computeAutoZoom(Rect cropRect) {
    const padding = 24.0;
    final availableW = _canvasSize.width - padding * 2;
    final availableH = _canvasSize.height - padding * 2;
    final targetScale = (availableW / cropRect.width)
        .clamp(1.0, (availableH / cropRect.height).clamp(1.0, 5.0));

    // 以裁剪框中心为锚点
    final cropCenter = cropRect.center;
    final canvasCenter = Offset(_canvasSize.width / 2, _canvasSize.height / 2);
    final targetOffset = (canvasCenter - cropCenter) * targetScale;

    return _AutoZoomResult(scale: targetScale, offset: targetOffset);
  }

  /// 将内容空间坐标限制在图片范围内
  Offset _clampToCanvas(Offset point) {
    return Offset(
      point.dx.clamp(0.0, _canvasSize.width),
      point.dy.clamp(0.0, _canvasSize.height),
    );
  }

  /// 内容空间坐标 → 归一化图片坐标 (0~1)
  Offset _contentToNormalized(Offset contentPoint) {
    final rect = _imageDisplayRect;
    if (rect.width == 0 || rect.height == 0) return Offset.zero;
    return Offset(
      ((contentPoint.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((contentPoint.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    // --- 裁剪模式优先级最高 ---
    if (widget.currentTool == EditorTool.crop) {
      // 停止正在播放的自动放大动画，避免与新手势冲突
      _cropAnimCtrl?.stop();
      final currentCropRect = widget.cropRect ?? _imageDisplayRect;
      if (details.pointerCount >= 2) {
        // 双指：缩放/平移
        _isZooming = true;
        _initialScale = _scale;
        _initialOffset = _offset;
        _initialFocalPoint = details.localFocalPoint;
      } else {
        // 单指：拖拽裁剪手柄
        final pos = _screenToContent(details.localFocalPoint);
        _draggedHandle = _hitTestCropHandle(pos, currentCropRect);
        if (_draggedHandle != _CropHandle.none) {
          _isCropDragging = true;
        }
      }
      _pendingStartPoint = null;
      _currentPoints = [];
      return;
    }

    // --- 画笔/马赛克统一手势 ---
    if (widget.currentTool == EditorTool.pen || widget.currentTool == EditorTool.mosaic) {
      return _onAnnotationScaleStart(details);
    }
  }

  void _onAnnotationScaleStart(ScaleStartDetails details) {
    if (details.pointerCount >= 2) {
      // 双指 → 缩放/平移模式
      _isZooming = true;
      if (!_isPanMode) {
        _isPanMode = true;
        widget.onPanModeChanged?.call(true);
      }
      _initialScale = _scale;
      _initialOffset = _offset;
      _initialFocalPoint = details.localFocalPoint;
      _pendingStartPoint = null;
      _currentPoints = [];
      _currentFingerPosition = null;
      _panStartPos = null;
      return;
    }

    // 单指
    if (_isPanMode) {
      // 平移模式 → 准备拖动画布
      _panStartPos = details.localFocalPoint;
      _initialOffset = _offset;
      return;
    }

    // 标注模式 → 准备绘制
    _isZooming = false;
    final canDraw = widget.currentTool == EditorTool.mosaic ||
        (widget.currentTool == EditorTool.pen && widget.isPenActive);
    if (canDraw) {
      _pendingStartPoint = details.localFocalPoint;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // --- 裁剪模式 update ---
    if (widget.currentTool == EditorTool.crop) {
      final currentCropRect = widget.cropRect ?? _imageDisplayRect;
      // 缩放/平移中
      if (_isZooming) {
        setState(() {
          final newScale =
              (_initialScale * details.scale).clamp(1.0, 5.0);
          final fcX =
              (_initialFocalPoint.dx - _initialOffset.dx) / _initialScale;
          final fcY =
              (_initialFocalPoint.dy - _initialOffset.dy) / _initialScale;
          _scale = newScale;
          _offset = _constrainOffset(
            Offset(
              details.localFocalPoint.dx - fcX * _scale,
              details.localFocalPoint.dy - fcY * _scale,
            ),
            _scale,
          );
          _displayScale = _scale;
          _displayOffset = _offset;
        });
        return;
      }
      // 裁剪拖拽中
      if (_isCropDragging) {
        final pos = _screenToContent(details.localFocalPoint);
        final newRect =
            _computeUpdatedCropRect(currentCropRect, _draggedHandle, pos);
        if (newRect != null) {
          widget.onCropRectChanged?.call(newRect);
        }
        return;
      }
      // 双指切换
      if (details.pointerCount >= 2) {
        _isZooming = true;
        _initialScale = _scale;
        _initialOffset = _offset;
        _initialFocalPoint = details.localFocalPoint;
        return;
      }
      return;
    }

    // --- 画笔/马赛克统一 update ---
    if (widget.currentTool == EditorTool.pen || widget.currentTool == EditorTool.mosaic) {
      _onAnnotationScaleUpdate(details);
      return;
    }
  }

  void _onAnnotationScaleUpdate(ScaleUpdateDetails details) {
    // 双指或已缩放 → 缩放手势
    if (_isZooming || details.pointerCount >= 2) {
      if (!_isZooming) {
        _isZooming = true;
        _initialScale = _scale;
        _initialOffset = _offset;
        _initialFocalPoint = details.localFocalPoint;
        _pendingStartPoint = null;
        _currentPoints = [];
        _currentFingerPosition = null;
        _panStartPos = null;
      }

      setState(() {
        final newScale = (_initialScale * details.scale).clamp(1.0, 5.0);
        final fx = (_initialFocalPoint.dx - _initialOffset.dx) / _initialScale;
        final fy = (_initialFocalPoint.dy - _initialOffset.dy) / _initialScale;
        _scale = newScale;
        _offset = _constrainOffset(
          Offset(
            details.localFocalPoint.dx - fx * _scale,
            details.localFocalPoint.dy - fy * _scale,
          ),
          _scale,
        );
        _displayScale = _scale;
        _displayOffset = _offset;
      });
      return;
    }

    // 平移模式 → 单指拖动画布（独立约束，不影响裁剪/缩放模式）
    if (_isPanMode && _panStartPos != null) {
      setState(() {
        final dx = details.localFocalPoint.dx - _panStartPos!.dx;
        final dy = details.localFocalPoint.dy - _panStartPos!.dy;
        _offset = _constrainPanOffset(
          _initialOffset + Offset(dx, dy),
        );
        _displayOffset = _offset;
      });
      return;
    }

    // 标注模式 → 绘制
    final canDraw = widget.currentTool == EditorTool.mosaic ||
        (widget.currentTool == EditorTool.pen && widget.isPenActive);
    if (!canDraw) return;

    final contentPos = _screenToContent(details.localFocalPoint);
    final clamped = _clampToCanvas(contentPos);
    final normalized = _contentToNormalized(clamped);
    if (_currentPoints.isEmpty && _pendingStartPoint != null) {
      final startContent = _screenToContent(_pendingStartPoint!);
      final startNorm = _contentToNormalized(_clampToCanvas(startContent));
      _currentPoints.add(startNorm);
      _pendingStartPoint = null;
    }
    _currentPoints.add(normalized);
    _currentFingerPosition = clamped;
    _drawRepaint.value++;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _pendingStartPoint = null;

    // --- 裁剪模式 end ---
    if (widget.currentTool == EditorTool.crop) {
      if (_isCropDragging && _draggedHandle != _CropHandle.none) {
        final cropRect = widget.cropRect ?? _imageDisplayRect;
        final targetTransform = _computeAutoZoom(cropRect);
        _animateAutoZoom(
          fromScale: _scale,
          fromOffset: _offset,
          toScale: targetTransform.scale,
          toOffset: targetTransform.offset,
        );
      }
      _draggedHandle = _CropHandle.none;
      _isCropDragging = false;
      _isZooming = false;
      return;
    }

    // --- 画笔/马赛克统一 end ---
    if (widget.currentTool == EditorTool.pen || widget.currentTool == EditorTool.mosaic) {
      _onAnnotationScaleEnd();
      return;
    }
  }

  void _onAnnotationScaleEnd() {
    // 双指缩放结束
    if (_isZooming) {
      _isZooming = false;
      _panStartPos = null;
      return;
    }

    // 平移模式 → 双击切回标注模式
    if (_isPanMode && _panStartPos != null) {
      _panStartPos = null;
      final now = DateTime.now();
      if (now.difference(_lastPanTap).inMilliseconds < 350) {
        _isPanMode = false;
        widget.onPanModeChanged?.call(false);
      } else {
        _lastPanTap = now;
      }
      return;
    }

    // 标注模式 → 提交绘制
    if (_currentPoints.isNotEmpty) {
      if (widget.currentTool == EditorTool.mosaic) {
        final newAction = models.MosaicAction(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          points: List.from(_currentPoints),
          blockSize: widget.mosaicBlockSize / _scale,
        );
        final newActions = List<models.EditorAction>.from(widget.actions);
        if (widget.currentActionIndex < newActions.length - 1) {
          newActions.removeRange(
              widget.currentActionIndex + 1, newActions.length);
        }
        newActions.add(newAction);
        widget.onActionsChanged(newActions);
        setState(() {
          _currentPoints = [];
          _currentFingerPosition = null;
        });
        return;
      }
      if (widget.currentTool == EditorTool.pen) {
        final contentStrokeWidth = widget.penStrokeWidth / _scale;
        if (widget.isEraserMode) {
          final newAction = models.EraserAction(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            points: List.from(_currentPoints),
            strokeWidth: contentStrokeWidth,
          );
          final newActions = List<models.EditorAction>.from(widget.actions);
          if (widget.currentActionIndex < newActions.length - 1) {
            newActions.removeRange(
                widget.currentActionIndex + 1, newActions.length);
          }
          newActions.add(newAction);
          widget.onActionsChanged(newActions);
        } else {
          final newAction = models.PenAction(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            points: List.from(_currentPoints),
            color: widget.penColor,
            strokeWidth: contentStrokeWidth,
          );
          final newActions = List<models.EditorAction>.from(widget.actions);
          if (widget.currentActionIndex < newActions.length - 1) {
            newActions.removeRange(
                widget.currentActionIndex + 1, newActions.length);
          }
          newActions.add(newAction);
          widget.onActionsChanged(newActions);
        }
        setState(() {
          _currentPoints = [];
          _currentFingerPosition = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        _imageDisplayRect = _computeImageDisplayRect();

        // 裁剪首次激活时初始化裁剪矩形（与图片四边重合，无缩进）
        // 注意：必须在 _imageDisplayRect 计算完成后初始化，确保裁剪框与图片重合
        if (widget.cropRect == null &&
            widget.currentTool == EditorTool.crop &&
            _imageDisplayRect != Rect.zero) {
          final rect = _imageDisplayRect;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && widget.cropRect == null) {
              widget.onCropRectChanged?.call(rect);
            }
          });
        }

        // 回传画布尺寸给页面（裁剪时用，每次变化都更新）
        if (_canvasSize != Size.zero) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onCanvasSizeReady?.call(_canvasSize);
          });
        }

        // 构建变换矩阵（用显示值，支持动画过渡）
        final cx = _canvasSize.width / 2;
        final cy = _canvasSize.height / 2;
        final useRotation = widget.cropRotation != 0.0;
        final matrix = Matrix4.identity()
          ..setTranslationRaw(
              cx + _displayOffset.dx, cy + _displayOffset.dy, 0)
          ..multiply(Matrix4.diagonal3Values(
              _displayScale, _displayScale, 1.0));
        if (useRotation) {
          matrix.rotateZ(widget.cropRotation);
        }
        matrix.multiply(
            Matrix4.translationValues(-cx, -cy, 0));

        final showCropOverlay = widget.currentTool == EditorTool.crop;

        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: Container(
            color: Colors.black,
            child: ClipRect(
              child: Transform(
                transform: matrix,
                alignment: Alignment.topLeft,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.file(
                        File(widget.imagePath),
                        key: ValueKey('crop_img_${widget.imageVersion}'),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.broken_image,
                                    color: Colors.white54, size: 48),
                                SizedBox(height: 8),
                                Text(
                                  '图片加载失败',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 14),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    Positioned.fill(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _drawRepaint,
                        builder: (context, _, child) {
                          return CustomPaint(
                            painter: _AnnotationPainter(
                              actions: widget.actions,
                              currentActionIndex: widget.currentActionIndex,
                              currentPoints: _currentPoints,
                              currentColor: widget.penColor,
                              currentStrokeWidth: widget.penStrokeWidth / _scale,
                              currentTool: widget.currentTool,
                              isEraserMode: widget.isEraserMode,
                              fingerPosition: _currentFingerPosition,
                              mosaicBlockSize: widget.mosaicBlockSize / _scale,
                              imageDisplayRect: _imageDisplayRect,
                            ),
                          );
                        },
                      ),
                    ),
                    if (showCropOverlay)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _CropOverlayPainter(
                            cropRect: widget.cropRect ?? _imageDisplayRect,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 标注绘制器
class _AnnotationPainter extends CustomPainter {
  final List<models.EditorAction> actions;
  final int currentActionIndex;
  final List<Offset> currentPoints; // 归一化坐标 (0~1)
  final Color currentColor;
  final double currentStrokeWidth; // 归一化线宽
  final EditorTool currentTool;
  final bool isEraserMode;
  final Offset? fingerPosition;
  final double mosaicBlockSize; // 归一化块大小
  final Rect imageDisplayRect; // 图片在画布中的显示区域

  _AnnotationPainter({
    required this.actions,
    required this.currentActionIndex,
    required this.currentPoints,
    required this.currentColor,
    required this.currentStrokeWidth,
    required this.currentTool,
    this.isEraserMode = false,
    this.fingerPosition,
    required this.mosaicBlockSize,
    required this.imageDisplayRect,
  });

  /// 归一化图片坐标 (0~1) → 内容空间坐标
  Offset _normalizedToContent(Offset normalized) {
    return Offset(
      imageDisplayRect.left + normalized.dx * imageDisplayRect.width,
      imageDisplayRect.top + normalized.dy * imageDisplayRect.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // BlendMode.clear 必须在 saveLayer 内部才能工作。
    // 把所有画笔和橡皮擦都放在同一个 saveLayer 里，
    // 按时间顺序绘制：画笔先画，橡皮擦用 clear 挖洞，之后的画笔叠在上面。
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    for (int i = 0; i <= currentActionIndex && i < actions.length; i++) {
      final action = actions[i];

      if (action is models.PenAction) {
        _drawPenAction(canvas, action);
      } else if (action is models.EraserAction) {
        _drawEraserAction(canvas, action);
      }
    }

    // 绘制当前正在画的路径
    if (currentPoints.isNotEmpty && currentTool == EditorTool.pen) {
      if (isEraserMode) {
        _drawCurrentEraserPath(canvas);
      } else {
        _drawCurrentPenPath(canvas);
      }
    }

    // 绘制马赛克
    for (int i = 0; i <= currentActionIndex && i < actions.length; i++) {
      final action = actions[i];
      if (action is models.MosaicAction) {
        _drawMosaicAction(canvas, action);
      }
    }

    // 绘制当前正在画的马赛克路径
    if (currentPoints.isNotEmpty && currentTool == EditorTool.mosaic) {
      _drawCurrentMosaicPath(canvas);
    }

    canvas.restore();

    // 橡皮擦范围虚线圆圈
    if (isEraserMode && fingerPosition != null) {
      _drawEraserRangeCircle(canvas, fingerPosition!, currentStrokeWidth / 2);
    }
  }

  void _drawPenAction(Canvas canvas, models.PenAction action) {
    if (action.points.isEmpty) return;

    // 归一化线宽 → 内容空间线宽
    final contentStrokeWidth = action.strokeWidth;

    final paint = Paint()
      ..color = action.color
      ..strokeWidth = contentStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final contentPoints = action.points.map(_normalizedToContent).toList();
    final path = _createPathFromPoints(contentPoints);
    canvas.drawPath(path, paint);
  }

  void _drawEraserAction(Canvas canvas, models.EraserAction action) {
    if (action.points.isEmpty) return;

    final contentStrokeWidth = action.strokeWidth;

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = contentStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = BlendMode.clear;

    final contentPoints = action.points.map(_normalizedToContent).toList();
    final path = _createPathFromPoints(contentPoints);
    canvas.drawPath(path, paint);
  }

  void _drawCurrentEraserPath(Canvas canvas) {
    if (currentPoints.isEmpty) return;

    final contentStrokeWidth = currentStrokeWidth;

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = contentStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = BlendMode.clear;

    final contentPoints = currentPoints.map(_normalizedToContent).toList();
    final path = _createPathFromPoints(contentPoints);
    canvas.drawPath(path, paint);
  }

  void _drawEraserRangeCircle(Canvas canvas, Offset center, double radius) {
    final dashedPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawPath(
      _createDashedCircle(center, radius),
      dashedPaint,
    );
  }

  Path _createDashedCircle(Offset center, double radius) {
    final path = Path();
    const dashLength = 4.0;
    const gapLength = 4.0;
    final circumference = 2 * pi * radius;
    final totalSegments = circumference / (dashLength + gapLength);

    for (int i = 0; i < totalSegments; i++) {
      final startAngle = (i * (dashLength + gapLength)) / radius;
      final endAngle =
          ((i * (dashLength + gapLength)) + dashLength) / radius;

      path.addArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        endAngle - startAngle,
      );
    }

    return path;
  }

  void _drawCurrentPenPath(Canvas canvas) {
    if (currentPoints.isEmpty) return;

    final contentStrokeWidth = currentStrokeWidth;

    final paint = Paint()
      ..color = currentColor
      ..strokeWidth = contentStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final contentPoints = currentPoints.map(_normalizedToContent).toList();
    final path = _createPathFromPoints(contentPoints);
    canvas.drawPath(path, paint);
  }

  void _drawMosaicAction(Canvas canvas, models.MosaicAction action) {
    if (action.points.isEmpty) return;
    // 归一化块大小 → 内容空间
    final contentBlock = action.blockSize;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    for (final point in action.points) {
      final center = _normalizedToContent(point);
      canvas.drawRect(
        Rect.fromCenter(center: center, width: contentBlock, height: contentBlock),
        paint,
      );
    }
  }

  void _drawCurrentMosaicPath(Canvas canvas) {
    if (currentPoints.isEmpty) return;
    final contentBlock = mosaicBlockSize;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    for (final point in currentPoints) {
      final center = _normalizedToContent(point);
      canvas.drawRect(
        Rect.fromCenter(center: center, width: contentBlock, height: contentBlock),
        paint,
      );
    }
  }

  Path _createPathFromPoints(List<Offset> points) {
    final path = Path();
    if (points.length == 1) {
      path.moveTo(points[0].dx, points[0].dy);
      path.lineTo(points[0].dx + 0.1, points[0].dy + 0.1);
    } else {
      path.moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) {
    return true;
  }
}

class _AutoZoomResult {
  final double scale;
  final Offset offset;
  const _AutoZoomResult({required this.scale, required this.offset});
}

/// 裁剪覆盖层绘制器 — L形角标 + 白线边框
class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;

  _CropOverlayPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 半透明遮罩（裁剪框外部）
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), dimPaint);
    canvas.drawRect(cropRect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // 2. 九宫格辅助线（细白线）
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    final thirdW = cropRect.width / 3;
    final thirdH = cropRect.height / 3;
    for (int i = 1; i <= 2; i++) {
      final x = cropRect.left + thirdW * i;
      final y = cropRect.top + thirdH * i;
      canvas.drawLine(
          Offset(x, cropRect.top), Offset(x, cropRect.bottom), gridPaint);
      canvas.drawLine(
          Offset(cropRect.left, y), Offset(cropRect.right, y), gridPaint);
    }

    // 3. 白色裁剪边框（1.5px，干净利落）
    final borderPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cropRect, borderPaint);

    // 4. 四角 L 形角标（代替圆形手柄）
    const bracketLen = 20.0;
    const bracketWidth = 2.5;
    final bracketPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = bracketWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    _drawCornerBracket(canvas, cropRect.topLeft,
        Offset(bracketLen, 0), Offset(0, bracketLen), bracketPaint);
    _drawCornerBracket(canvas, cropRect.topRight,
        Offset(-bracketLen, 0), Offset(0, bracketLen), bracketPaint);
    _drawCornerBracket(canvas, cropRect.bottomLeft,
        Offset(bracketLen, 0), Offset(0, -bracketLen), bracketPaint);
    _drawCornerBracket(canvas, cropRect.bottomRight,
        Offset(-bracketLen, 0), Offset(0, -bracketLen), bracketPaint);

    // 5. 四边中点短线（拖动指示）
    const edgeMarkLen = 12.0;
    final edgeMarkPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final midTop = Offset(cropRect.center.dx, cropRect.top);
    final midBottom = Offset(cropRect.center.dx, cropRect.bottom);
    final midLeft = Offset(cropRect.left, cropRect.center.dy);
    final midRight = Offset(cropRect.right, cropRect.center.dy);

    canvas.drawLine(
        midTop + const Offset(-edgeMarkLen, 0),
        midTop + const Offset(edgeMarkLen, 0),
        edgeMarkPaint);
    canvas.drawLine(
        midBottom + const Offset(-edgeMarkLen, 0),
        midBottom + const Offset(edgeMarkLen, 0),
        edgeMarkPaint);
    canvas.drawLine(
        midLeft + const Offset(0, -edgeMarkLen),
        midLeft + const Offset(0, edgeMarkLen),
        edgeMarkPaint);
    canvas.drawLine(
        midRight + const Offset(0, -edgeMarkLen),
        midRight + const Offset(0, edgeMarkLen),
        edgeMarkPaint);
  }

  void _drawCornerBracket(Canvas canvas, Offset corner, Offset hDir,
      Offset vDir, Paint paint) {
    // 水平线
    canvas.drawLine(corner, corner + hDir, paint);
    // 垂直线
    canvas.drawLine(corner, corner + vDir, paint);
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) {
    return cropRect != oldDelegate.cropRect;
  }
}

/// 裁剪悬浮预览窗绘制器
