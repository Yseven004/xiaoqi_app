import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_painter/flutter_painter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as raster;
import 'package:image_picker/image_picker.dart';

import '../services/home_chat_drawing_draft_store.dart';

class HomeChatDrawingResult {
  const HomeChatDrawingResult({
    required this.pngBytes,
    required this.draftPath,
  });

  final Uint8List pngBytes;
  final String draftPath;
}

/// Lets an image viewer export its inline drawing surface without navigation.
class DrawingSurfaceController {
  _DrawingBoardPageState? _state;
  bool get hasChanges =>
      _state?._controller.performedActions.isNotEmpty ?? false;
  Future<HomeChatDrawingResult?> export() async => _state?._exportForHost();
  Future<Uint8List?> snapshot() =>
      _state?._renderExport() ?? Future<Uint8List?>.value();
  void suspendTools() => _state?._suspendTools();
}

class DrawingBoardPage extends StatefulWidget {
  const DrawingBoardPage({
    required this.conversationId,
    this.accountScope = 'local',
    this.draftPath,
    this.draftStore,
    this.imagePicker,
    this.imageAspectRatio,
    this.embedded = false,
    this.surfaceController,
    this.showToolbar = true,
    super.key,
  });

  final String conversationId;
  final String accountScope;
  final String? draftPath;
  final HomeChatDrawingDraftStore? draftStore;
  final Future<Uint8List?> Function(ImageSource source)? imagePicker;
  final double? imageAspectRatio;
  final bool embedded;
  final DrawingSurfaceController? surfaceController;
  final bool showToolbar;

  @override
  State<DrawingBoardPage> createState() => _DrawingBoardPageState();
}

class _DrawingBoardPageState extends State<DrawingBoardPage>
    with WidgetsBindingObserver {
  static const _paper = Color(0xFFFFFFFF);
  static const _ink = Color(0xFF252525);
  late final HomeChatDrawingDraftStore _store;
  final _textFocusNode = FocusNode();
  final _inlineTextController = TextEditingController();
  final _inlineTextKey = GlobalKey();
  final _canvasCardKey = GlobalKey();
  final _controller = PainterController(
    settings: PainterSettings(
      text: TextSettings(textStyle: const TextStyle(fontSize: 30, color: _ink)),
      freeStyle: const FreeStyleSettings(color: _ink, strokeWidth: 5),
      shape: ShapeSettings(
        paint: Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6,
      ),
      // The board is a fixed paper surface. Zooming belongs to the explicit
      // expand action, not to an infinite/pannable canvas.
      scale: const ScaleSettings(enabled: false, minScale: 1, maxScale: 1),
    ),
    background: const ColorBackgroundDrawable(color: _paper),
  );
  final _codec = DrawableJsonCodec();
  final Set<ui.Image> _ownedDrawableImages = <ui.Image>{};
  Timer? _saveTimer;
  late final Future<void> _restoreFuture;
  HomeChatDrawingDraft? _draft;
  Uint8List? _backgroundBytes;
  String? _backgroundPath;
  ui.Image? _backgroundImage;
  Color _selectedColor = _ink;
  double _penStrokeWidth = 5;
  double _eraserStrokeWidth = 30;
  bool _ready = false;
  bool _saving = false;
  bool _closing = false;
  bool _imagePicking = false;
  bool _backgroundNeedsWrite = false;
  bool _expanded = false;
  bool _colorPopoverOpen = false;
  bool _imagePopoverOpen = false;
  bool _eraserPopoverOpen = false;
  bool _textEditing = false;
  Size _canvasSize = Size.zero;
  Size _canvasViewSize = Size.zero;
  Size? _imageSceneSize;
  ObjectDrawable? _selectedObject;
  bool _showImageDeleteButton = false;
  ObjectDrawable? _transformBaseDrawable;
  Rect? _transformBaseRect;
  bool _transformHasRecordedAction = false;
  double _rotationStartPointerAngle = 0;
  double _rotationStartObjectAngle = 0;
  Offset? _eraserCursorPosition;
  bool _eraserCursorVisible = false;
  String? _saveError;
  Future<void> Function()? _retryOperation;
  int _tool = 1;
  int _saveRevision = 0;
  List<Drawable> _observedDrawables = const [];
  Object? _observedBackground;
  Future<void> _saveQueue = Future<void>.value();

  bool get _canEdit =>
      _ready && _draft != null && !_saving && !_closing && !_imagePicking;

  static const _strokeOptions = <double>[2, 5, 9, 16];
  static const _eraserStrokeOptions = <double>[9, 18, 30];

  double get _activeStrokeWidth =>
      _tool == 4 ? _eraserStrokeWidth : _penStrokeWidth;

  static const _popoverPalette = <Color>[
    Color(0xFF111111),
    Color(0xFFC52C38),
    Color(0xFFED6530),
    Color(0xFFF2A51A),
    Color(0xFF2F9B55),
    Color(0xFF315BC8),
    Color(0xFF6848D2),
  ];

  @override
  void initState() {
    super.initState();
    widget.surfaceController?._state = this;
    _store =
        widget.draftStore ??
        HomeChatDrawingDraftStore(accountScope: widget.accountScope);
    WidgetsBinding.instance.addObserver(this);
    _controller.textSettings = _controller.textSettings.copyWith(
      focusNode: _textFocusNode,
    );
    _controller.objectSettings = _controller.objectSettings.copyWith(
      showScaleRotationControlsResolver: () => false,
    );
    _controller.freeStyleMode = FreeStyleMode.draw;
    _controller.addListener(_onControllerChanged);
    _textFocusNode.addListener(_onTextFocusChanged);
    _restoreFuture = _restoreDraft();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureCanvas());
  }

  @override
  void dispose() {
    if (identical(widget.surfaceController?._state, this)) {
      widget.surfaceController?._state = null;
    }
    _saveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _textFocusNode.removeListener(_onTextFocusChanged);
    _textFocusNode.dispose();
    _inlineTextController.dispose();
    _controller.dispose();
    _backgroundImage?.dispose();
    for (final image in _ownedDrawableImages) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveTimer?.cancel();
      _enqueueSave();
    }
  }

  Future<void> _restoreDraft() async {
    try {
      final draft = await _store.open(
        widget.conversationId,
        draftPath: widget.draftPath,
      );
      final storedSize = draft.document['canvasSize'];
      if (widget.embedded &&
          storedSize is List &&
          storedSize.length == 2 &&
          storedSize.every((v) => v is num && v.isFinite && v > 0)) {
        _imageSceneSize = Size(
          (storedSize[0] as num).toDouble(),
          (storedSize[1] as num).toDouble(),
        );
      }
      if (draft.backgroundBytes case final bytes?) {
        await _setBackground(bytes, persist: false);
        _backgroundPath = draft.document['backgroundPath'] as String?;
      }
      final drawables = await _codec.decode(draft.document);
      if (drawables.isNotEmpty) {
        _controller.addDrawables(drawables);
        _controller.performedActions.clear();
        _controller.unperformedActions.clear();
      }
      _draft = draft;
      _observedDrawables = List<Drawable>.of(_controller.value.drawables);
      _observedBackground = _controller.value.background;
      _retryOperation = null;
      if (!mounted) return;
      setState(() => _ready = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureCanvas());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _saveError = '草稿读取失败：$error';
        _retryOperation = _restoreDraft;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureCanvas());
    }
  }

  void _onTextFocusChanged() {
    if (mounted) setState(() {});
  }

  void _measureCanvas() {
    final renderObject = _controller.painterKey.currentContext
        ?.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.size.isFinite &&
        !renderObject.size.isEmpty &&
        renderObject.size != _canvasSize) {
      setState(() => _canvasSize = renderObject.size);
    }
  }

  void _onControllerChanged() {
    if (!_ready || _draft == null) return;
    final drawables = _controller.value.drawables;
    final background = _controller.value.background;
    final selected = _selectedObject;
    if (selected != null && !drawables.contains(selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_selectedObject, selected)) _deselectObject();
      });
    }
    if (listEquals(_observedDrawables, drawables) &&
        identical(_observedBackground, background)) {
      return;
    }
    _observedDrawables = List<Drawable>.of(drawables);
    _observedBackground = background;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _enqueueSave);
  }

  void _enqueueSave() {
    final revision = ++_saveRevision;
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      if (!mounted || revision != _saveRevision) return;
      try {
        await _saveDraft();
      } catch (_) {}
    });
  }

  Future<void> _saveDraft() async {
    final draft = _draft;
    if (draft == null) return;
    try {
      final document = await _codec.encode(_controller.value.drawables);
      final saved = <String, Object?>{
        ...document,
        'backgroundPath': _backgroundPath,
        if (!_currentCanvasSize.isEmpty)
          'canvasSize': [_currentCanvasSize.width, _currentCanvasSize.height],
      };
      final savedBackgroundPath = await _store.save(
        draft.path,
        saved,
        backgroundBytes: _backgroundNeedsWrite ? _backgroundBytes : null,
      );
      if (_backgroundNeedsWrite) {
        _backgroundPath = savedBackgroundPath;
        _backgroundNeedsWrite = false;
      }
      _retryOperation = null;
      if (mounted && _saveError != null) {
        setState(() => _saveError = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saveError = '绘图草稿保存失败：$error';
          _retryOperation = _saveDraft;
        });
      }
      rethrow;
    }
  }

  bool get _hasContent =>
      _controller.value.drawables.isNotEmpty || _backgroundBytes != null;

  Future<void> _importBackground() async {
    await _pickImage(ImageSource.gallery);
  }

  Future<void> _captureBackground() async {
    await _pickImage(ImageSource.camera);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (!_canEdit || _imagePicking) return;
    setState(() {
      _imagePicking = true;
      _imagePopoverOpen = false;
      _colorPopoverOpen = false;
      _eraserPopoverOpen = false;
    });
    try {
      final pickedBytes = widget.imagePicker == null
          ? await _pickImageBytes(source)
          : await widget.imagePicker!(source);
      if (pickedBytes == null) return;
      final decoded = raster.decodeImage(pickedBytes);
      if (decoded == null) throw const FormatException('无法读取这张图片');
      final scaled = decoded.width > 2048 || decoded.height > 2048
          ? raster.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? 2048 : null,
              height: decoded.height > decoded.width ? 2048 : null,
              interpolation: raster.Interpolation.linear,
            )
          : decoded;
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(raster.encodePng(scaled)),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final image = frame.image;
      _ownedDrawableImages.add(image);
      final canvasSize = _currentCanvasSize.isEmpty
          ? _canvasViewSize
          : _currentCanvasSize;
      if (canvasSize.isEmpty) {
        image.dispose();
        _ownedDrawableImages.remove(image);
        throw const FormatException('画板尚未准备好，请重试');
      }
      final maxWidth = canvasSize.width * .68;
      final maxHeight = canvasSize.height * .48;
      final factor = math.min(maxWidth / image.width, maxHeight / image.height);
      final imageDrawable = ImageDrawable.fittedToSize(
        image: image,
        position: Offset(canvasSize.width / 2, canvasSize.height / 2),
        size: Size(image.width * factor, image.height * factor),
        erasable: false,
      );
      _controller.addDrawables([imageDrawable]);
      _selectObject(imageDrawable, revealImageActions: false);
      _retryOperation = null;
      if (mounted && _saveError != null) setState(() => _saveError = null);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saveError = '图片导入失败：$error';
          _retryOperation = () => _pickImage(source);
        });
      }
    } finally {
      if (mounted) setState(() => _imagePicking = false);
    }
  }

  Future<Uint8List?> _pickImageBytes(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 92,
    );
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  Size get _currentCanvasSize {
    final renderObject = _controller.painterKey.currentContext
        ?.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.size.isFinite &&
        !renderObject.size.isEmpty) {
      return renderObject.size;
    }
    return _canvasSize;
  }

  Future<void> _setBackground(Uint8List bytes, {bool persist = true}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    _backgroundImage?.dispose();
    _backgroundImage = frame.image;
    _backgroundBytes = bytes;
    _controller.background = ImageBackgroundDrawable(
      image: frame.image,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      backgroundColor: _paper,
    );
    if (persist) _onControllerChanged();
  }

  Future<void> _selectTool(int tool) async {
    if (tool == 2) {
      _beginInlineText();
      return;
    }
    if (_textEditing) _commitInlineText();
    _textFocusNode.unfocus();
    _deselectObject();
    if (tool != 4) _hideEraserCursor();
    setState(() {
      _tool = tool;
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
    _controller.shapeFactory = null;
    switch (tool) {
      case 1:
        _controller.freeStyleStrokeWidth = _penStrokeWidth;
        _controller.freeStyleMode = FreeStyleMode.draw;
      case 4:
        _controller.freeStyleStrokeWidth = _eraserStrokeWidth;
        _controller.freeStyleMode = FreeStyleMode.erase;
      default:
        _controller.freeStyleMode = FreeStyleMode.none;
    }
  }

  void _beginInlineText() {
    if (!_canEdit) return;
    _deselectObject();
    _textFocusNode.unfocus();
    _inlineTextController.clear();
    setState(() {
      _tool = 2;
      _textEditing = true;
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
    _controller.freeStyleMode = FreeStyleMode.none;
  }

  void _commitInlineText() {
    if (!_textEditing) return;
    final text = _inlineTextController.text.trim();
    final canvasSize = _currentCanvasSize.isEmpty
        ? _canvasViewSize
        : _currentCanvasSize;
    ObjectDrawable? drawable;
    if (text.isNotEmpty && !canvasSize.isEmpty) {
      final fieldObject = _inlineTextKey.currentContext?.findRenderObject();
      final painterObject = _controller.painterKey.currentContext
          ?.findRenderObject();
      var position = Offset(canvasSize.width / 2, canvasSize.height * .38);
      if (fieldObject is RenderBox && painterObject is RenderBox) {
        final globalCenter = fieldObject.localToGlobal(
          fieldObject.size.center(Offset.zero),
        );
        position = painterObject.globalToLocal(globalCenter);
      }
      drawable = TextDrawable(
        text: text,
        position: position,
        style: TextStyle(fontSize: 18, color: _selectedColor),
        textAlign: TextAlign.left,
      );
      _controller.addDrawables([drawable]);
    }
    _inlineTextController.clear();
    if (mounted) {
      setState(() {
        _textEditing = false;
        _tool = 1;
      });
      _textFocusNode.unfocus();
    }
    if (drawable != null) {
      _selectObject(drawable);
    } else {
      _controller.freeStyleMode = FreeStyleMode.draw;
    }
  }

  void _selectObject(
    ObjectDrawable drawable, {
    bool revealImageActions = true,
  }) {
    if (!_controller.value.drawables.contains(drawable)) return;
    _textFocusNode.unfocus();
    _controller.deselectObjectDrawable();
    _controller.freeStyleMode = FreeStyleMode.none;
    setState(() {
      _selectedObject = drawable;
      _showImageDeleteButton = drawable is ImageDrawable && revealImageActions;
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
  }

  void _deselectObject() {
    if (_selectedObject == null && _controller.selectedObjectDrawable == null) {
      return;
    }
    setState(() {
      _selectedObject = null;
      _showImageDeleteButton = false;
    });
    _controller.deselectObjectDrawable();
    _controller.freeStyleMode = switch (_tool) {
      4 => FreeStyleMode.erase,
      1 => FreeStyleMode.draw,
      _ => FreeStyleMode.none,
    };
  }

  void _handlePainterObjectSelection(ObjectDrawable? drawable) {
    if (drawable == null) {
      _deselectObject();
      return;
    }
    _selectObject(drawable);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_controller.selectedObjectDrawable, drawable)) {
        _controller.deselectObjectDrawable();
      }
    });
  }

  Rect _displayRectForObject(ObjectDrawable drawable, Size displaySize) {
    final coordinateSize = _currentCanvasSize;
    if (coordinateSize.isEmpty || displaySize.isEmpty) return Rect.zero;
    final scaleX = displaySize.width / coordinateSize.width;
    final scaleY = displaySize.height / coordinateSize.height;
    final size = drawable.getSize(maxWidth: coordinateSize.width);
    return Rect.fromCenter(
      center: Offset(
        drawable.position.dx * scaleX,
        drawable.position.dy * scaleY,
      ),
      width: size.width * scaleX,
      height: size.height * scaleY,
    );
  }

  Offset _displayToCanvas(Offset point, Size displaySize) {
    final coordinateSize = _currentCanvasSize;
    if (coordinateSize.isEmpty || displaySize.isEmpty) return point;
    return Offset(
      point.dx * coordinateSize.width / displaySize.width,
      point.dy * coordinateSize.height / displaySize.height,
    );
  }

  void _startObjectTransform(ObjectDrawable drawable, Size displaySize) {
    if (!identical(_selectedObject, drawable)) _selectObject(drawable);
    _transformBaseDrawable = drawable;
    _transformBaseRect = _displayRectForObject(drawable, displaySize);
    _transformHasRecordedAction = false;
  }

  void _startObjectRotation(
    ObjectDrawable drawable,
    Size displaySize,
    Offset globalPosition,
  ) {
    _startObjectTransform(drawable, displaySize);
    final rect = _transformBaseRect;
    if (rect == null) return;
    final pointer = _globalToCanvasPosition(globalPosition);
    _rotationStartPointerAngle = math.atan2(
      pointer.dy - rect.center.dy,
      pointer.dx - rect.center.dx,
    );
    _rotationStartObjectAngle = drawable.rotationAngle;
  }

  void _updateObjectRotation(Offset globalPosition, Size displaySize) {
    final rect = _transformBaseRect;
    if (rect == null) return;
    final pointer = _globalToCanvasPosition(globalPosition);
    final pointerAngle = math.atan2(
      pointer.dy - rect.center.dy,
      pointer.dx - rect.center.dx,
    );
    final delta = pointerAngle - _rotationStartPointerAngle;
    final normalizedDelta = math.atan2(math.sin(delta), math.cos(delta));
    _applyObjectTransform(
      rect,
      displaySize,
      rotation: _rotationStartObjectAngle + normalizedDelta,
    );
  }

  void _rotateObjectBy(
    ObjectDrawable drawable,
    Size displaySize, {
    double delta = math.pi / 12,
  }) {
    if (!_canEdit) return;
    _startObjectTransform(drawable, displaySize);
    final base = _transformBaseDrawable;
    final rect = _transformBaseRect;
    if (base == null || rect == null) {
      _endObjectTransform();
      return;
    }
    _applyObjectTransform(
      rect,
      displaySize,
      rotation: base.rotationAngle + delta,
    );
    _endObjectTransform();
  }

  Offset _globalToCanvasPosition(Offset globalPosition) {
    final renderObject = _canvasCardKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox) {
      return renderObject.globalToLocal(globalPosition);
    }
    return globalPosition;
  }

  void _applyObjectTransform(
    Rect displayRect,
    Size displaySize, {
    double? rotation,
  }) {
    final base = _transformBaseDrawable ?? _selectedObject;
    final baseRect = _transformBaseRect;
    if (base == null || baseRect == null || baseRect.width <= 0) return;
    final current = _controller.value.drawables
        .whereType<ObjectDrawable>()
        .firstWhere(
          (drawable) => identical(drawable, _selectedObject),
          orElse: () => base,
        );
    final scaleFactor = displayRect.width / baseRect.width;
    final replacement = base.copyWith(
      position: _displayToCanvas(displayRect.center, displaySize),
      rotation: rotation ?? current.rotationAngle,
      scale: (base.scale * scaleFactor).clamp(.05, 20).toDouble(),
    );
    if (!_controller.replaceDrawable(
      current,
      replacement,
      newAction: !_transformHasRecordedAction,
    )) {
      return;
    }
    _transformHasRecordedAction = true;
    setState(() => _selectedObject = replacement);
  }

  void _endObjectTransform() {
    _transformBaseDrawable = null;
    _transformBaseRect = null;
    _transformHasRecordedAction = false;
  }

  Rect _rotatedBounds(Rect rect, double angle) {
    if (angle == 0) return rect;
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    final points =
        <Offset>[
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
        ].map((point) {
          final offset = point - rect.center;
          return rect.center +
              Offset(
                offset.dx * cosine - offset.dy * sine,
                offset.dx * sine + offset.dy * cosine,
              );
        }).toList();
    final left = points.map((point) => point.dx).reduce(math.min);
    final top = points.map((point) => point.dy).reduce(math.min);
    final right = points.map((point) => point.dx).reduce(math.max);
    final bottom = points.map((point) => point.dy).reduce(math.max);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Widget _buildObjectInteractions(Size displaySize) =>
      ValueListenableBuilder<PainterControllerValue>(
        valueListenable: _controller,
        builder: (context, value, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            for (final drawable in value.drawables.whereType<ObjectDrawable>())
              if (!(_tool == 4 && drawable.erasable))
                _buildObjectInteraction(drawable, displaySize),
          ],
        ),
      );

  Widget _buildObjectInteraction(ObjectDrawable drawable, Size displaySize) {
    final rect = _displayRectForObject(drawable, displaySize);
    if (rect.isEmpty || !rect.isFinite) return const SizedBox.shrink();
    final selected = identical(_selectedObject, drawable);
    if (!selected) {
      return Positioned.fromRect(
        rect: rect,
        child: Transform.rotate(
          angle: drawable.rotationAngle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectObject(drawable),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    final safeInset = math.min(
      46.0,
      math.min(displaySize.width, displaySize.height) / 4,
    );
    final clampWidth = math.max(1.0, displaySize.width - safeInset * 2);
    final clampHeight = math.max(1.0, displaySize.height - safeInset * 2);
    final rotatedBounds = _rotatedBounds(rect, drawable.rotationAngle);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        TransformableBox(
          key: const ValueKey('drawing-selected-object-frame'),
          rect: rect,
          rotation: drawable.rotationAngle,
          clampingRect: Rect.fromLTWH(
            safeInset,
            safeInset,
            clampWidth,
            clampHeight,
          ),
          constraints: BoxConstraints(
            minWidth: 28,
            minHeight: 28,
            maxWidth: clampWidth,
            maxHeight: clampHeight,
          ),
          resizeModeResolver: () => ResizeMode.scale,
          // Keep the hit target comfortable while rendering a much lighter
          // visual handle. The compact center dot avoids the heavy eight-dot
          // look without making resize gestures difficult to start.
          handleTapSize: 18,
          draggable: true,
          resizable: true,
          // Rotation is handled by the larger, dedicated control below the
          // image so it remains easy to find and cannot overlap resize handles.
          rotatable: false,
          cornerHandleBuilder: (_, _) => _buildSelectionHandle(),
          sideHandleBuilder: (_, _) => _buildSelectionHandle(),
          contentBuilder: (_, _, _) => CustomPaint(
            painter: const _DashedSelectionPainter(),
            child: const SizedBox.expand(),
          ),
          onTap: () => _selectObject(drawable),
          onDragStart: (_) => _startObjectTransform(drawable, displaySize),
          onResizeStart: (_, _) => _startObjectTransform(drawable, displaySize),
          onChanged: (result, _) => _applyObjectTransform(
            result.rect,
            displaySize,
            rotation: _selectedObject?.rotationAngle ?? drawable.rotationAngle,
          ),
          onDragEnd: (_) => _endObjectTransform(),
          onResizeEnd: (_, _) => _endObjectTransform(),
          onDragCancel: _endObjectTransform,
          onResizeCancel: (_) => _endObjectTransform(),
        ),
        if (drawable is ImageDrawable && _showImageDeleteButton)
          Positioned(
            left: (rotatedBounds.right + 4)
                .clamp(4.0, displaySize.width - 40)
                .toDouble(),
            top: (rotatedBounds.top - 18)
                .clamp(4.0, displaySize.height - 40)
                .toDouble(),
            child: _buildDeleteImageButton(),
          ),
        if (drawable is ImageDrawable)
          Positioned(
            left: (rotatedBounds.center.dx - 18)
                .clamp(4.0, displaySize.width - 40)
                .toDouble(),
            top: (rotatedBounds.bottom + 8)
                .clamp(4.0, displaySize.height - 40)
                .toDouble(),
            child: GestureDetector(
              key: const ValueKey('drawing-image-rotation-handle'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _rotateObjectBy(drawable, displaySize),
              onPanStart: (details) => _startObjectRotation(
                drawable,
                displaySize,
                details.globalPosition,
              ),
              onPanUpdate: (details) =>
                  _updateObjectRotation(details.globalPosition, displaySize),
              onPanEnd: (_) => _endObjectTransform(),
              onPanCancel: _endObjectTransform,
              child: _buildRotationHandle(),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectionHandle() => Center(
    child: Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF3B82F6), width: 1.25),
      ),
    ),
  );

  Widget _buildRotationHandle() => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xFFD7DCE2)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: const Icon(Icons.rotate_right_rounded, size: 18, color: _ink),
  );

  Widget _buildDeleteImageButton() => Material(
    color: Colors.white,
    shape: const CircleBorder(),
    elevation: 2,
    child: IconButton(
      key: const ValueKey('drawing-delete-image'),
      tooltip: '删除图片',
      onPressed: () {
        final drawable = _selectedObject;
        if (drawable == null) return;
        _controller.removeDrawable(drawable);
        _selectedObject = null;
        _showImageDeleteButton = false;
        _controller.freeStyleMode = FreeStyleMode.draw;
        setState(() {});
      },
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: _drawingIcon(
        'assets/icons/chat_note_editor/trash.svg',
        const Color(0xFFE53935),
        19,
      ),
    ),
  );

  void _chooseColor(Color color) {
    setState(() => _selectedColor = color);
    _controller.freeStyleColor = color;
    _controller.shapeSettings = _controller.shapeSettings.copyWith(
      paint: Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _penStrokeWidth,
    );
    _controller.textSettings = _controller.textSettings.copyWith(
      textStyle: TextStyle(fontSize: 30, color: color),
    );
  }

  void _choosePenStrokeWidth(double value) {
    setState(() => _penStrokeWidth = value);
    if (_tool == 4) return;
    _controller.freeStyleStrokeWidth = value;
    _controller.shapeSettings = _controller.shapeSettings.copyWith(
      paint: Paint()
        ..color = _selectedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = value,
    );
  }

  void _chooseEraserStrokeWidth(double value) {
    setState(() => _eraserStrokeWidth = value);
    if (_tool == 4) _controller.freeStyleStrokeWidth = value;
  }

  void _toggleColorPopover() {
    if (!_canEdit) return;
    setState(() {
      _colorPopoverOpen = !_colorPopoverOpen;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
  }

  void _toggleImagePopover() {
    if (!_canEdit) return;
    if (_textEditing) _commitInlineText();
    _textFocusNode.unfocus();
    _deselectObject();
    setState(() {
      _imagePopoverOpen = !_imagePopoverOpen;
      _colorPopoverOpen = false;
      _eraserPopoverOpen = false;
    });
  }

  void _toggleEraserPopover() {
    if (!_canEdit) return;
    if (_textEditing) _commitInlineText();
    _textFocusNode.unfocus();
    _deselectObject();
    setState(() {
      _tool = 4;
      _controller.freeStyleMode = FreeStyleMode.erase;
      _eraserPopoverOpen = !_eraserPopoverOpen;
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
    });
    _controller.freeStyleStrokeWidth = _eraserStrokeWidth;
  }

  void _clearCanvas() {
    if (!_canEdit) return;
    _controller.clearDrawables();
    _selectedObject = null;
    _showImageDeleteButton = false;
    _controller.deselectObjectDrawable();
    if (!widget.embedded) {
      _backgroundImage?.dispose();
      _backgroundImage = null;
      _backgroundBytes = null;
      _backgroundPath = null;
      _backgroundNeedsWrite = false;
      _controller.background = const ColorBackgroundDrawable(color: _paper);
    }
    setState(() {
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
    _controller.freeStyleMode = _tool == 4
        ? FreeStyleMode.erase
        : FreeStyleMode.draw;
    _onControllerChanged();
  }

  Future<void> _finish() async {
    final result = await _exportForHost();
    if (result != null && mounted && !widget.embedded) {
      Navigator.of(context).pop(result);
    }
  }

  Future<HomeChatDrawingResult?> _exportForHost() async {
    if (_textEditing) _commitInlineText();
    if (!_canEdit || !_hasContent) return null;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      _saveTimer?.cancel();
      await _saveQueue.catchError((Object _) {});
      await _saveDraft();
      final result = await _renderExport();
      final draft = _draft;
      if (draft == null) throw const FormatException('绘图草稿不存在');
      return HomeChatDrawingResult(pngBytes: result, draftPath: draft.path);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saveError = '完成绘图失败：$error';
          _retryOperation = _finish;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return null;
  }

  Future<Uint8List> _renderExport() async {
    const sizes = <Size>[
      Size(1638, 2048),
      Size(1440, 1800),
      Size(1152, 1440),
      Size(960, 1200),
      Size(768, 960),
    ];
    for (final candidate in sizes) {
      final aspect = widget.imageAspectRatio;
      final size = aspect == null
          ? candidate
          : aspect >= 1
          ? Size(candidate.height, candidate.height / aspect)
          : Size(candidate.height * aspect, candidate.height);
      final canvas = await _controller.renderImage(size);
      try {
        final data = await canvas.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw const FormatException('绘图导出失败');
        final bytes = Uint8List.fromList(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        if (bytes.length <= 5 * 1024 * 1024) return bytes;
      } finally {
        canvas.dispose();
      }
    }
    throw const FormatException('图片超过 5 MB，请缩小底图后重试');
  }

  Future<void> _close() async {
    if (_closing || _saving) return;
    setState(() => _closing = true);
    _textFocusNode.unfocus();
    await _restoreFuture;
    if (!mounted) return;
    _saveTimer?.cancel();
    ++_saveRevision;
    await _saveQueue.catchError((Object _) {});
    final draft = _draft;
    if (draft != null) {
      try {
        await _store.discard(widget.conversationId, draft);
      } catch (error) {
        if (mounted) {
          setState(() {
            _saveError = '放弃绘图失败：$error';
            _closing = false;
          });
        }
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _retryLastOperation() async {
    final operation = _retryOperation;
    if (operation == null) return;
    setState(() => _saveError = null);
    try {
      await operation();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (widget.embedded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          _canvasViewSize = constraints.biggest;
          _imageSceneSize ??= constraints.biggest;
          return _buildCanvasCard(colors, constraints.biggest);
        },
      );
    }
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            const Positioned.fill(
              child: ModalBarrier(color: Color(0x33000000), dismissible: false),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, screen) {
                  final availableWidth = screen.maxWidth;
                  final availableHeight = screen.maxHeight;
                  final isPortrait = availableHeight >= availableWidth;
                  final aspectRatio =
                      widget.imageAspectRatio ?? (isPortrait ? 3 / 4 : 8 / 5);
                  final maxWidth = availableWidth * .9;
                  final maxHeight = availableHeight * .76;
                  final defaultWidth = math.min(
                    maxWidth,
                    maxHeight * aspectRatio,
                  );
                  final defaultHeight = defaultWidth / aspectRatio;
                  final expandedWidth = widget.imageAspectRatio == null
                      ? availableWidth
                      : math.min(availableWidth, availableHeight * aspectRatio);
                  final width = _expanded ? expandedWidth : defaultWidth;
                  final height = _expanded
                      ? (widget.imageAspectRatio == null
                            ? availableHeight
                            : expandedWidth / aspectRatio)
                      : defaultHeight;

                  return Center(
                    child: AnimatedContainer(
                      key: const ValueKey('drawing-canvas-card'),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeInOutCubic,
                      width: width,
                      height: height,
                      decoration: BoxDecoration(
                        color: _paper,
                        borderRadius: BorderRadius.circular(
                          _expanded ? 16 : 20,
                        ),
                        border: Border.all(color: const Color(0xFFD7DCE2)),
                        boxShadow: _expanded
                            ? null
                            : const [
                                BoxShadow(
                                  color: Color(0x1A000000),
                                  blurRadius: 20,
                                  offset: Offset(0, 8),
                                ),
                              ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          _canvasViewSize = size;
                          return _buildCanvasCard(colors, size);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvasCard(ColorScheme colors, Size size) => Stack(
    key: _canvasCardKey,
    fit: StackFit.expand,
    children: [
      if (_ready)
        Positioned.fill(
          child: Listener(
            onPointerDown: (event) => _updateEraserCursor(event.localPosition),
            onPointerMove: (event) => _updateEraserCursor(event.localPosition),
            onPointerUp: (_) => _hideEraserCursor(),
            onPointerCancel: (_) => _hideEraserCursor(),
            child: AbsorbPointer(
              key: const ValueKey('drawing-canvas-edit-lock'),
              absorbing: !_canEdit,
              child: Builder(
                builder: (context) {
                  final painter = RepaintBoundary(
                    key: const ValueKey('drawing-canvas-repaint-boundary'),
                    child: FlutterPainter(
                      controller: _controller,
                      onSelectedObjectDrawableChanged:
                          _handlePainterObjectSelection,
                    ),
                  );
                  if (!widget.embedded) return painter;
                  return FittedBox(
                    fit: BoxFit.fill,
                    child: SizedBox(
                      width: _imageSceneSize!.width,
                      height: _imageSceneSize!.height,
                      child: painter,
                    ),
                  );
                },
              ),
            ),
          ),
        )
      else
        const SizedBox.expand(),
      if (_ready)
        Positioned.fill(
          child: AbsorbPointer(
            key: const ValueKey('drawing-object-edit-lock'),
            absorbing: !_canEdit,
            child: _buildObjectInteractions(size),
          ),
        ),
      if (_eraserCursorVisible && _eraserCursorPosition != null)
        Positioned(
          left: _eraserCursorPosition!.dx - _eraserCursorDiameter / 2,
          top: _eraserCursorPosition!.dy - _eraserCursorDiameter / 2,
          child: IgnorePointer(
            child: Container(
              width: _eraserCursorDiameter,
              height: _eraserCursorDiameter,
              decoration: BoxDecoration(
                color: const Color(0x183A4654),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x80515D69), width: 1.2),
              ),
            ),
          ),
        ),
      if (_textEditing) _buildInlineTextEditor(size),
      if (widget.showToolbar)
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: _buildToolbar(colors, size),
        ),
      if (_colorPopoverOpen || _imagePopoverOpen || _eraserPopoverOpen)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismissPopovers,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      if (_colorPopoverOpen)
        Positioned(
          top: 60,
          left: 12,
          right: 12,
          child: Center(child: _buildColorPopover(size.width)),
        ),
      if (_imagePopoverOpen)
        Positioned(
          top: 60,
          left: 12,
          right: 12,
          child: Center(child: _buildImagePopover(size.width)),
        ),
      if (_eraserPopoverOpen)
        Positioned(
          top: 60,
          left: 12,
          right: 12,
          child: Center(child: _buildEraserPopover(size.width)),
        ),
      if (_saveError != null)
        Positioned(
          left: 16,
          right: 16,
          top: 62,
          child: Material(
            color: const Color(0xFFFFF3F0),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _saveError!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _retryOperation == null
                        ? null
                        : _retryLastOperation,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (!widget.embedded)
        Positioned(right: 14, bottom: 14, child: _buildFinishButton()),
    ],
  );

  double get _eraserCursorDiameter {
    final displaySize = _canvasViewSize;
    final coordinateSize = _currentCanvasSize;
    if (displaySize.isEmpty || coordinateSize.isEmpty) {
      return _activeStrokeWidth;
    }
    final scale = math.max(
      displaySize.width / coordinateSize.width,
      displaySize.height / coordinateSize.height,
    );
    return _activeStrokeWidth * scale;
  }

  void _updateEraserCursor(Offset position) {
    if (_tool != 4 || !_canEdit) return;
    setState(() {
      _eraserCursorPosition = position;
      _eraserCursorVisible = true;
    });
  }

  void _hideEraserCursor() {
    if (!_eraserCursorVisible) return;
    setState(() {
      _eraserCursorVisible = false;
      _eraserCursorPosition = null;
    });
  }

  void _dismissPopovers() {
    if (!(_colorPopoverOpen || _imagePopoverOpen || _eraserPopoverOpen)) return;
    setState(() {
      _colorPopoverOpen = false;
      _imagePopoverOpen = false;
      _eraserPopoverOpen = false;
    });
  }

  void _suspendTools() {
    if (_textEditing) _commitInlineText();
    _textFocusNode.unfocus();
    _dismissPopovers();
    _hideEraserCursor();
    _deselectObject();
  }

  Widget _buildInlineTextEditor(Size canvasSize) => Positioned.fill(
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        final renderObject = _inlineTextKey.currentContext?.findRenderObject();
        if (renderObject is! RenderBox) return;
        final topLeft = renderObject.localToGlobal(Offset.zero);
        if (!(topLeft & renderObject.size).contains(event.position)) {
          _commitInlineText();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: canvasSize.height * .31,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = math.min(
                  320.0,
                  math.max(0.0, canvasSize.width - 40),
                );
                return Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: IntrinsicWidth(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: math.min(120.0, maxWidth),
                          maxWidth: maxWidth,
                        ),
                        child: CustomPaint(
                          key: _inlineTextKey,
                          foregroundPainter: const _DashedSelectionPainter(),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: TextField(
                              key: const ValueKey('drawing-inline-text-field'),
                              controller: _inlineTextController,
                              focusNode: _textFocusNode,
                              enabled: _canEdit,
                              autofocus: false,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              onTap: () {
                                if (_canEdit && !_textFocusNode.hasFocus) {
                                  _textFocusNode.requestFocus();
                                }
                              },
                              minLines: 1,
                              maxLines: null,
                              style: TextStyle(
                                color: _selectedColor,
                                fontSize: 18,
                                height: 1.35,
                              ),
                              cursorColor: _selectedColor,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 8,
                                ),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildToolbar(ColorScheme colors, Size cardSize) => LayoutBuilder(
    builder: (context, constraints) {
      final ultraCompact = cardSize.width < 300;
      final compact = cardSize.width < 420;
      final sideWidth = ultraCompact
          ? 26.0
          : compact
          ? 36.0
          : 44.0;
      final toolSize = ultraCompact
          ? 26.0
          : compact
          ? 38.0
          : 44.0;
      final iconSize = ultraCompact
          ? 18.0
          : compact
          ? 20.0
          : 23.0;
      return SizedBox(
        height: 48,
        child: Row(
          children: [
            ValueListenableBuilder<PainterControllerValue>(
              valueListenable: _controller,
              builder: (_, _, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _toolbarIconButton(
                    key: const ValueKey('drawing-undo'),
                    tooltip: '撤销',
                    icon:
                        'assets/icons/chat_note_editor/arrow-counter-clockwise.svg',
                    color: _controller.canUndo ? _ink : const Color(0xFF9CA3AA),
                    onPressed: _canEdit && _controller.canUndo
                        ? _controller.undo
                        : null,
                    width: sideWidth,
                    iconSize: iconSize,
                  ),
                  _toolbarIconButton(
                    key: const ValueKey('drawing-redo'),
                    tooltip: '重做',
                    icon: 'assets/icons/chat_note_editor/arrow-clockwise.svg',
                    color: _controller.canRedo ? _ink : const Color(0xFF9CA3AA),
                    onPressed: _canEdit && _controller.canRedo
                        ? _controller.redo
                        : null,
                    width: sideWidth,
                    iconSize: iconSize,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _buildToolPill(toolSize, iconSize),
                ),
              ),
            ),
            if (!widget.embedded)
              _toolbarIconButton(
                key: const ValueKey('drawing-expand'),
                tooltip: _expanded ? '还原画板' : '放大画板',
                icon: 'assets/images/home_composer_expand.svg',
                color: _ink,
                onPressed: _canEdit
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                width: sideWidth,
                iconSize: iconSize,
              ),
          ],
        ),
      );
    },
  );

  Widget _buildToolPill(double toolSize, double iconSize) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      boxShadow: const [
        BoxShadow(
          color: Color(0x3A26384A),
          blurRadius: 20,
          spreadRadius: 1,
          offset: Offset(0, 7),
        ),
        BoxShadow(
          color: Color(0xA6FFFFFF),
          blurRadius: 5,
          offset: Offset(0, -1),
        ),
      ],
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xF2FFFFFF), Color(0xB8CAD7E5), Color(0xE6FFFFFF)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: .80),
                    const Color(0xFFE6EEF6).withValues(alpha: .67),
                    const Color(0xFFDCE6F0).withValues(alpha: .73),
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _pillToolButton(
                          tool: 1,
                          tooltip: '画笔',
                          icon: 'assets/icons/capabilities/brush.svg',
                          slotSize: toolSize,
                          iconSize: iconSize,
                          onTap: () => _selectTool(1),
                        ),
                        _pillToolButton(
                          tool: 2,
                          tooltip: '文字',
                          icon: 'assets/icons/chat_note_editor/text-aa.svg',
                          slotSize: toolSize,
                          iconSize: iconSize,
                          onTap: () => _selectTool(2),
                        ),
                        _pillToolButton(
                          tool: 5,
                          tooltip: '图片',
                          icon: 'assets/icons/capabilities/image.svg',
                          slotSize: toolSize,
                          iconSize: iconSize,
                          onTap: _toggleImagePopover,
                        ),
                        _pillToolButton(
                          tool: 4,
                          tooltip: '橡皮',
                          icon: 'assets/icons/drawing/eraser.svg',
                          slotSize: toolSize,
                          iconSize: iconSize,
                          onTap: _toggleEraserPopover,
                        ),
                        _pillColorButton(toolSize, iconSize),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 22,
                    right: 22,
                    top: 2,
                    child: IgnorePointer(
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(alpha: .98),
                              Colors.white.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 1,
                    child: IgnorePointer(
                      child: Container(
                        height: 1,
                        color: const Color(0x39566B80),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _pillToolButton({
    required int tool,
    required String tooltip,
    required String icon,
    required double slotSize,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    final selected = _tool == tool;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? const Color(0xFFE7F0FF) : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          key: ValueKey('drawing-tool-$tool'),
          onTap: _canEdit ? onTap : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: slotSize,
            height: slotSize,
            child: Center(
              child: _drawingIcon(
                icon,
                selected ? const Color(0xFF1769D2) : _ink,
                iconSize,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pillColorButton(double slotSize, double iconSize) => Tooltip(
    message: '颜色与笔尖粗细',
    child: Material(
      color: _colorPopoverOpen ? const Color(0xFFE7F0FF) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        key: const ValueKey('drawing-tool-color'),
        onTap: _canEdit ? _toggleColorPopover : null,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: slotSize,
          height: slotSize,
          child: Center(
            child: Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                color: _selectedColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Color(0x20000000), blurRadius: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _toolbarIconButton({
    Key? key,
    required String tooltip,
    required String icon,
    required Color color,
    required VoidCallback? onPressed,
    required double width,
    required double iconSize,
  }) => Tooltip(
    message: tooltip,
    child: IconButton(
      key: key,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      constraints: BoxConstraints.tightFor(width: width, height: 44),
      icon: _drawingIcon(icon, color, iconSize),
    ),
  );

  Widget _buildColorPopover(double cardWidth) => _popoverSurface(
    key: const ValueKey('drawing-color-popover'),
    width: math.min(320.0, math.max(1.0, cardWidth - 24)),
    height: 64,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final width in _strokeOptions) _strokeDot(width),
          const SizedBox(width: 8),
          const SizedBox(
            height: 28,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xFFD9DCE0),
            ),
          ),
          const SizedBox(width: 8),
          for (final color in _popoverPalette) _colorDot(color),
        ],
      ),
    ),
  );

  Widget _strokeDot(double width) => InkWell(
    key: ValueKey('drawing-pen-stroke-${width.toStringAsFixed(0)}'),
    onTap: () {
      _choosePenStrokeWidth(width);
      setState(() => _colorPopoverOpen = false);
    },
    borderRadius: BorderRadius.circular(20),
    child: SizedBox(
      width: 32,
      height: 48,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: width + 5,
          height: width + 5,
          decoration: BoxDecoration(
            color: _ink,
            shape: BoxShape.circle,
            border: width == _penStrokeWidth
                ? Border.all(color: const Color(0xFF2F73E8), width: 2)
                : null,
          ),
        ),
      ),
    ),
  );

  Widget _colorDot(Color color) => InkWell(
    onTap: () {
      _chooseColor(color);
      setState(() => _colorPopoverOpen = false);
    },
    borderRadius: BorderRadius.circular(20),
    child: SizedBox(
      width: 32,
      height: 48,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: color == _selectedColor ? 23 : 20,
          height: color == _selectedColor ? 23 : 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: color == _selectedColor
                ? Border.all(color: Colors.white, width: 2)
                : null,
            boxShadow: color == _selectedColor
                ? const [
                    BoxShadow(
                      color: Color(0x442F73E8),
                      blurRadius: 0,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    ),
  );

  Widget _buildImagePopover(double cardWidth) => _popoverSurface(
    key: const ValueKey('drawing-image-popover'),
    width: math.min(176.0, math.max(1.0, cardWidth - 24)),
    height: 108,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _imageAction(
          icon: Icons.camera_alt_outlined,
          label: '拍照',
          onTap: () {
            setState(() => _imagePopoverOpen = false);
            _captureBackground();
          },
        ),
        _imageAction(
          iconAsset: 'assets/icons/capabilities/image.svg',
          label: '上传图片',
          onTap: () {
            setState(() => _imagePopoverOpen = false);
            _importBackground();
          },
        ),
      ],
    ),
  );

  Widget _imageAction({
    IconData? icon,
    String? iconAsset,
    required String label,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SizedBox(width: 6),
          SizedBox(
            width: 26,
            child: Center(
              child: iconAsset != null
                  ? _drawingIcon(iconAsset, _ink, 21)
                  : Icon(icon, color: _ink, size: 21),
            ),
          ),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: _ink, fontSize: 15)),
        ],
      ),
    ),
  );

  Widget _buildEraserPopover(double cardWidth) => _popoverSurface(
    key: const ValueKey('drawing-eraser-popover'),
    width: math.min(232.0, math.max(1.0, cardWidth - 24)),
    height: 64,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final width in _eraserStrokeOptions) _eraserDot(width),
          const SizedBox(width: 8),
          const SizedBox(
            height: 28,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xFFD9DCE0),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '清空画布',
            child: IconButton(
              onPressed: _clearCanvas,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              icon: _drawingIcon(
                'assets/icons/chat_note_editor/trash.svg',
                const Color(0xFFE53935),
                20,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _eraserDot(double width) => InkWell(
    key: ValueKey('drawing-eraser-stroke-${width.toStringAsFixed(0)}'),
    onTap: () {
      _chooseEraserStrokeWidth(width);
      setState(() => _eraserPopoverOpen = false);
    },
    borderRadius: BorderRadius.circular(20),
    child: SizedBox(
      width: 44,
      height: 48,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: width + 5,
          height: width + 5,
          decoration: BoxDecoration(
            color: Color(0xFFADB3BA),
            shape: BoxShape.circle,
            border: width == _eraserStrokeWidth
                ? Border.all(color: const Color(0xFF3B82F6), width: 2)
                : null,
          ),
        ),
      ),
    ),
  );

  Widget _popoverSurface({
    Key? key,
    required double width,
    required double height,
    required Widget child,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {},
    child: Material(
      key: key,
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x24000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE0E4E9)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: ClipRect(child: child),
        ),
      ),
    ),
  );

  Widget _buildFinishButton() => ValueListenableBuilder<PainterControllerValue>(
    valueListenable: _controller,
    builder: (_, _, _) {
      final canFinish =
          _canEdit &&
          (_hasContent ||
              (_textEditing && _inlineTextController.text.trim().isNotEmpty));
      return Semantics(
        button: true,
        enabled: canFinish,
        label: '完成绘图',
        child: Tooltip(
          message: '完成',
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              key: const ValueKey('drawing-finish-button'),
              onTap: canFinish
                  ? () {
                      if (_textEditing) _commitInlineText();
                      unawaited(_finish());
                    }
                  : null,
              customBorder: const CircleBorder(),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFD0D5DB)),
                ),
                child: _saving
                    ? const Center(
                        child: SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Center(
                        child: KeyedSubtree(
                          key: const ValueKey('drawing-finish-check'),
                          child: _drawingIcon(
                            'assets/icons/drawing/check.svg',
                            canFinish
                                ? const Color(0xFF252525)
                                : const Color(0xFF858B92),
                            22,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _drawingIcon(String path, Color color, [double size = 21]) =>
      SvgPicture.asset(
        path,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        semanticsLabel: null,
      );
}

class _DashedSelectionPainter extends CustomPainter {
  const _DashedSelectionPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 1 || size.height <= 1) return;
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect.deflate(.7), const Radius.circular(5)),
      );
    final paint = Paint()
      ..color = const Color(0xFF4C94F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + 5, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedSelectionPainter oldDelegate) => false;
}
