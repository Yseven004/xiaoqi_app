import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../config/colors.dart';
import 'models/editor_state.dart';
import 'models/editor_action.dart' as models;
import 'widgets/editor_toolbar.dart';
import 'widgets/editor_canvas.dart';
import 'widgets/crop_confirm_bar.dart';
import 'widgets/annotation_confirm_bar.dart';
import 'services/image_processor.dart';

/// 照片编辑器页面
class PhotoEditorPage extends StatefulWidget {
  final String imagePath;
  final Function(String editedPath)? onCompleted;
  final VoidCallback? onCancelled;

  const PhotoEditorPage({
    super.key,
    required this.imagePath,
    this.onCompleted,
    this.onCancelled,
  });

  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  // 当前选中的工具
  EditorTool _currentTool = EditorTool.none;

  // 编辑器状态
  EditorState _editorState = EditorState.idle;

  // 操作历史栈
  final List<models.EditorAction> _historyStack = [];
  int _currentHistoryIndex = -1;

  // 画笔相关状态
  Color _penColor = Colors.black;
  double _penStrokeWidth = 4.0;
  bool _isEraserMode = false;
  bool _isPenActive = false; // 需点击颜色后才激活绘图

  // 马赛克相关状态
  double _mosaicBlockSize = 10.0;

  // 裁剪相关状态
  Rect? _cropRect;                  // 裁剪矩形（内容空间坐标）
  double _cropRotation = 0.0;       // 累计旋转角度（弧度）
  Rect? _cropInitialRect;           // 初始裁剪矩形（用于还原）
  Size? _originalImageSize;         // 原始图片像素尺寸
  bool _isCropProcessing = false;   // 裁剪处理中
  final ValueNotifier<int> _cropResetNotifier = ValueNotifier(0);
  int _imageVersion = 0; // 图片版本号，裁剪后递增强制刷新缓存

  /// 当前编辑中的图片路径，裁剪后会指向临时文件
  /// null 表示使用原始图片 widget.imagePath
  String? _workingImagePath;

  /// 画笔/马赛克是否处于平移模式（缩放后单指拖拽画布）
  bool _isPanMode = false;

  @override
  void initState() {
    super.initState();
    _readImageDimensions();
  }

  /// 读取原始图片尺寸
  Future<void> _readImageDimensions() async {
    try {
      final file = File(widget.imagePath);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image != null && mounted) {
        setState(() {
          _originalImageSize = Size(
            image.width.toDouble(),
            image.height.toDouble(),
          );
        });
      }
    } catch (_) {
      // 读取失败则裁剪时无法正确映射坐标，但不影响其他功能
    }
  }

  @override
  void dispose() {
    _cropResetNotifier.dispose();
    super.dispose();
  }

  /// 切换工具
  void _onToolSelected(EditorTool tool) {
    setState(() {
      if (_currentTool == tool) {
        _currentTool = EditorTool.none;
        _editorState = EditorState.idle;
        _isPenActive = false;
        _cropRect = null;
        _cropRotation = 0.0;
      } else {
        _currentTool = tool;
        _isPenActive = false;
        if (tool == EditorTool.crop) {
          _editorState = EditorState.cropping;
        } else {
          _editorState = EditorState.idle;
          _cropRect = null;
          _cropRotation = 0.0;
        }
      }
    });
  }

  /// 撤销操作
  void _onUndo() {
    if (_currentHistoryIndex >= 0) {
      setState(() {
        _currentHistoryIndex--;
      });
    }
  }

  /// 重做操作
  void _onRedo() {
    if (_currentHistoryIndex < _historyStack.length - 1) {
      setState(() {
        _currentHistoryIndex++;
      });
    }
  }

  /// 取消编辑
  void _onCancel() {
    widget.onCancelled?.call();
    Navigator.of(context).pop();
  }

  /// 完成编辑
  Future<void> _onComplete() async {
    String resultPath = _workingImagePath ?? widget.imagePath;

    // 导出带标注的图片
    final actionsToExport =
        _historyStack.sublist(0, _currentHistoryIndex + 1);

    if (actionsToExport.isNotEmpty && _originalImageSize != null) {
      try {
        resultPath = await ImageProcessor.applyAnnotations(
          imagePath: resultPath,
          actions: actionsToExport,
          canvasSize: _cachedCanvasSize ?? Size.zero,
          originalImageSize: _originalImageSize!,
        );
      } catch (_) {
        // 导出失败仍返回原图
      }
    }
    if (!mounted) return;
    widget.onCompleted?.call(resultPath);
    Navigator.of(context).pop();
  }

  /// 更新画笔颜色（首次点击激活，再点同一颜色关闭）
  void _onPenColorChanged(Color color) {
    setState(() {
      _isEraserMode = false;
      if (!_isPenActive) {
        // 未激活 → 激活并选中颜色
        _isPenActive = true;
        _penColor = color;
      } else if (_penColor == color) {
        // 已激活且是同一颜色 → 关闭
        _isPenActive = false;
      } else {
        // 已激活且是不同颜色 → 切换颜色
        _penColor = color;
      }
    });
  }

  /// 更新画笔粗细
  void _onPenStrokeWidthChanged(double width) {
    setState(() {
      _penStrokeWidth = width;
    });
  }

  /// 更新马赛克粗细
  void _onMosaicBlockSizeChanged(double size) {
    setState(() {
      _mosaicBlockSize = size;
    });
  }

  // --- 裁剪相关方法 ---

  /// 90度旋转：每次点击旋转 π/2
  void _onCropRotate90() {
    setState(() {
      _cropRotation = (_cropRotation + pi / 2) % (2 * pi);
    });
  }

  /// 裁剪矩形变化回调
  void _onCropRectChanged(Rect rect) {
    setState(() {
      _cropRect = rect;
      _cropInitialRect ??= rect;
    });
  }

  /// 旋转角度变化回调
  void _onCropRotationChanged(double angle) {
    setState(() {
      _cropRotation = angle;
    });
  }

  /// 还原：重置裁剪矩形和旋转角度
  void _onCropReset() {
    setState(() {
      _cropRect = _cropInitialRect;
      _cropRotation = 0.0;
    });
    _cropResetNotifier.value++;
  }

  /// × 取消裁剪：清空所有编辑历史+裁剪状态，回到主编辑器（原始图片）
  void _onCropCancel() {
    setState(() {
      _workingImagePath = null;
      _historyStack.clear();
      _currentHistoryIndex = -1;
      _cropRect = null;
      _cropInitialRect = null;
      _cropRotation = 0.0;
      _currentTool = EditorTool.none;
      _editorState = EditorState.idle;
    });
  }

  /// 确认裁剪：先烘焙已有标注，再在后台 isolate 裁剪图片
  Future<void> _onCropConfirm() async {
    if (_cropRect == null || _originalImageSize == null || _isCropProcessing) {
      return;
    }

    setState(() => _isCropProcessing = true);

    try {
      // 如果有标注历史，先烘焙到当前图片上
      final actionsToExport =
          _historyStack.sublist(0, _currentHistoryIndex + 1);

      if (actionsToExport.isNotEmpty) {
        final bakedPath = await ImageProcessor.applyAnnotations(
          imagePath: _workingImagePath ?? widget.imagePath,
          actions: actionsToExport,
          canvasSize: _cachedCanvasSize ?? Size.zero,
          originalImageSize: _originalImageSize!,
        );
        _workingImagePath = bakedPath;
      }

      // 再裁剪已标注的图片
      final result = await ImageProcessor.applyCropAndRotation(
        imagePath: _workingImagePath ?? widget.imagePath,
        cropRect: _cropRect!,
        canvasSize: _cachedCanvasSize ?? Size.zero,
        originalImageSize: _originalImageSize!,
        rotationAngle: _cropRotation,
      );

      if (!mounted) return;

      PaintingBinding.instance.imageCache.evict(
        FileImage(File(result.path)),
      );

      setState(() {
        if (result.width > 0 && result.height > 0) {
          _originalImageSize = Size(
            result.width.toDouble(),
            result.height.toDouble(),
          );
        }
        _workingImagePath = result.path;
        _imageVersion++;

        _historyStack.clear();
        _currentHistoryIndex = -1;

        _cropRect = null;
        _cropInitialRect = null;
        _cropRotation = 0.0;
        _currentTool = EditorTool.none;
        _editorState = EditorState.idle;
        _isCropProcessing = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isCropProcessing = false);
      }
    }
  }

  // EditorCanvas 回传的画布尺寸（裁剪时需要）
  Size? _cachedCanvasSize;

  // 子工具栏实际高度（用于占位，防止画布跳动）
  final GlobalKey _subToolbarKey = GlobalKey();
  double _lastSubToolbarHeight = 0;

  /// 裁剪是否准备就绪（显示确认栏的条件）
  bool get _isCropReady =>
      _currentTool == EditorTool.crop && _cropRect != null;

  /// 是否在标注模式（画笔或马赛克）
  bool get _isAnnotationMode =>
      _currentTool == EditorTool.pen || _currentTool == EditorTool.mosaic;

  /// √ 确认标注：保留标注，回到主编辑器
  void _onAnnotationConfirm() {
    setState(() {
      _currentTool = EditorTool.none;
      _editorState = EditorState.idle;
      _isPenActive = false;
    });
  }

  /// × 取消标注：清空所有标注历史，回到主编辑器（原始图片）
  void _onAnnotationCancel() {
    setState(() {
      _historyStack.clear();
      _currentHistoryIndex = -1;
      _currentTool = EditorTool.none;
      _editorState = EditorState.idle;
      _isPenActive = false;
    });
  }

  /// 处理返回手势 / 物理返回键：逐步退回到主编辑器，再退出页面
  void _handleBack() {
    if (_isCropReady) {
      // 裁剪模式 → 取消裁剪，回到主编辑器
      _onCropCancel();
    } else if (_isAnnotationMode) {
      // 画笔/马赛克模式 → 确认标注，回到主编辑器
      _onAnnotationConfirm();
    } else {
      // 主编辑器 → 取消，退回预览页
      _onCancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = PopScope(
      canPop: _currentTool == EditorTool.none,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            // 顶栏
            _buildTopBar(),

            // 照片画布区域
            Expanded(
              child: _buildCanvasArea(),
            ),

            // 子工具栏（画笔/马赛克时显示）
            _buildSubToolbar(),

            // 底部工具栏 / 裁剪确认栏 / 标注确认栏
            if (_isCropReady)
              CropConfirmBar(
                onCancel: _onCropCancel,
                onConfirm: _onCropConfirm,
              )
            else if (_isAnnotationMode)
              AnnotationConfirmBar(
                onCancel: _onAnnotationCancel,
                onConfirm: _onAnnotationConfirm,
              )
            else
              EditorToolbar(
                currentTool: _currentTool,
                onToolSelected: _onToolSelected,
                onUndo: _onUndo,
                onRedo: _onRedo,
                canUndo: _currentHistoryIndex >= 0,
                canRedo: _currentHistoryIndex < _historyStack.length - 1,
                onCancel: _onCancel,
                onComplete: _onComplete,
              ),
          ],
        ),
      ),
    );

    // 测量子工具栏高度（用于占位，防止画布跳动）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final keyContext = _subToolbarKey.currentContext;
      if (keyContext != null) {
        final box = keyContext.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          _lastSubToolbarHeight = box.size.height;
        }
      }
    });

    return result;
  }

  /// 构建顶栏
  Widget _buildTopBar() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: 16,
        right: 16,
        bottom: 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 取消按钮
          GestureDetector(
            onTap: _onCancel,
            child: const Text(
              '取消',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                decoration: TextDecoration.none,
              ),
            ),
          ),

          // 撤销/重做按钮
          Row(
            children: [
              // 撤销按钮
              GestureDetector(
                onTap: _currentHistoryIndex >= 0 ? _onUndo : null,
                child: Icon(
                  Icons.undo,
                  color: _currentHistoryIndex >= 0
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.3),
                  size: 28,
                ),
              ),
              const SizedBox(width: 20),
              // 重做按钮
              GestureDetector(
                onTap: _currentHistoryIndex < _historyStack.length - 1
                    ? _onRedo
                    : null,
                child: Icon(
                  Icons.redo,
                  color: _currentHistoryIndex < _historyStack.length - 1
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.3),
                  size: 28,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建画布区域
  Widget _buildCanvasArea() {
    return EditorCanvas(
      imagePath: _workingImagePath ?? widget.imagePath,
      currentTool: _currentTool,
      editorState: _editorState,
      penColor: _penColor,
      penStrokeWidth: _penStrokeWidth,
      mosaicBlockSize: _mosaicBlockSize,
      actions: _historyStack,
      currentActionIndex: _currentHistoryIndex,
      isEraserMode: _isEraserMode,
      isPenActive: _isPenActive,
      // 裁剪参数
      cropRect: _cropRect,
      cropRotation: _cropRotation,
      originalImageSize: _originalImageSize,
      onCropRectChanged: _onCropRectChanged,
      onCropRotationChanged: _onCropRotationChanged,
      cropResetNotifier: _cropResetNotifier,
      imageVersion: _imageVersion,
      onPanModeChanged: (pan) {
        setState(() => _isPanMode = pan);
      },
      onCanvasSizeReady: (size) {
        _cachedCanvasSize = size;
      },
      onActionsChanged: (newActions) {
        setState(() {
          _historyStack.clear();
          _historyStack.addAll(newActions);
          _currentHistoryIndex = _historyStack.length - 1;
        });
      },
    );
  }

  /// 构建子工具栏
  Widget _buildSubToolbar() {
    // 裁剪模式下显示裁剪子工具栏
    if (_currentTool == EditorTool.crop) {
      return _buildCropSubToolbar();
    }

    // 画笔或马赛克工具选中时显示子工具栏
    if (_currentTool == EditorTool.pen || _currentTool == EditorTool.mosaic) {
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _isPanMode ? 0.3 : 1.0,
        child: Container(
          key: _subToolbarKey,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: _currentTool == EditorTool.pen
              ? _buildPenSubToolbar()
              : _buildMosaicSubToolbar(),
        ),
      );
    }

    // 有标注时保持子工具栏占位高度，防止画布跳动
    if (_currentHistoryIndex >= 0) {
      return SizedBox(height: _lastSubToolbarHeight);
    }

    return const SizedBox.shrink();
  }

  /// 构建裁剪子工具栏
  Widget _buildCropSubToolbar() {
    final hasChanges = (_cropInitialRect != null &&
            _cropRect != _cropInitialRect) ||
        _cropRotation != 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 功能按钮行
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 旋转按钮（每次点击旋转90°）
              _CropToolbarButton(
                onTap: _onCropRotate90,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedRotation(
                      turns: _cropRotation / (2 * pi),
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOut,
                      child: const Icon(
                        Icons.rotate_right,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '旋转',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 还原按钮
              _CropToolbarButton(
                onTap: hasChanges ? _onCropReset : null,
                isEnabled: hasChanges,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.refresh,
                      color: hasChanges ? Colors.white : Colors.white38,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '还原',
                      style: TextStyle(
                        color: hasChanges ? Colors.white : Colors.white38,
                        fontSize: 13,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建画笔子工具栏
  Widget _buildPenSubToolbar() {
    // 颜色列表：黑、白、红、浅粉、黄、浅绿、深绿、蓝
    final colors = [
      Colors.black,
      Colors.white,
      Colors.red,
      Colors.pink.shade100,
      Colors.yellow,
      Colors.green.shade100,
      Colors.green.shade800,
      Colors.blue,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 激活提示
        if (!_isPenActive)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '点击颜色开始绘制',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '再次点击当前颜色可关闭绘制',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        // 颜色行
        SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 橡皮擦图标
              GestureDetector(
                onTap: () {
                  setState(() {
                    _isPenActive = true; // 激活绘图才能擦除
                    _isEraserMode = !_isEraserMode;
                  });
                },
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isEraserMode ? AppColors.accent : Colors.transparent,
                    border: Border.all(
                      color: _isEraserMode ? AppColors.accent : Colors.white.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    PhosphorIconsRegular.eraser,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
              // 分隔线
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: Colors.white.withValues(alpha: 0.4),
              ),
              // 颜色圆形
              ...colors.map((color) => _buildColorCircle(color)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 粗细滑块
        Row(
          children: [
            const Text(
              '小',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: _penStrokeWidth,
                min: 1.0,
                max: 20.0,
                activeColor: AppColors.accent,
                inactiveColor: Colors.white.withValues(alpha: 0.3),
                onChanged: _onPenStrokeWidthChanged,
              ),
            ),
            const Text(
              '大',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建马赛克子工具栏
  Widget _buildMosaicSubToolbar() {
    return Row(
      children: [
        const Text(
          '小',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
        Expanded(
          child: Slider(
            value: _mosaicBlockSize,
            min: 5.0,
            max: 30.0,
            activeColor: AppColors.accent,
            inactiveColor: Colors.white.withValues(alpha: 0.3),
            onChanged: _onMosaicBlockSizeChanged,
          ),
        ),
        const Text(
          '大',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }

  /// 构建颜色圆形
  Widget _buildColorCircle(Color color) {
    final isSelected = _isPenActive && _penColor == color && !_isEraserMode;

    return GestureDetector(
      onTap: () => _onPenColorChanged(color),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isPenActive ? color : color.withValues(alpha: 0.35),
          border: Border.all(
            color: isSelected
                ? AppColors.accent
                : Colors.white.withValues(alpha: _isPenActive ? 0.3 : 0.15),
            width: isSelected ? 3 : 2,
          ),
        ),
      ),
    );
  }
}

/// 裁剪工具栏按钮 - 带透明白色高亮效果
class _CropToolbarButton extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  final bool isEnabled;

  const _CropToolbarButton({
    required this.onTap,
    required this.child,
    this.isEnabled = true,
  });

  @override
  State<_CropToolbarButton> createState() => _CropToolbarButtonState();
}

class _CropToolbarButtonState extends State<_CropToolbarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final baseAlpha = widget.isEnabled ? 0.1 : 0.05;
    final pressedAlpha = widget.isEnabled ? 0.25 : 0.05;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.isEnabled ? (_) => setState(() => _isPressed = true) : null,
      onTapUp: widget.isEnabled ? (_) => setState(() => _isPressed = false) : null,
      onTapCancel: widget.isEnabled ? () => setState(() => _isPressed = false) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Colors.white.withValues(
            alpha: _isPressed ? pressedAlpha : baseAlpha,
          ),
          border: Border.all(
            color: Colors.white.withValues(
              alpha: widget.isEnabled ? 0.3 : 0.1,
            ),
            width: 1.5,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
