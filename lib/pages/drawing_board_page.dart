import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
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

class DrawingBoardPage extends StatefulWidget {
  const DrawingBoardPage({
    required this.conversationId,
    this.accountScope = 'local',
    this.draftPath,
    super.key,
  });

  final String conversationId;
  final String accountScope;
  final String? draftPath;

  @override
  State<DrawingBoardPage> createState() => _DrawingBoardPageState();
}

class _DrawingBoardPageState extends State<DrawingBoardPage>
    with WidgetsBindingObserver {
  static const _paper = Color(0xFFFFFFFF);
  static const _ink = Color(0xFF252525);
  static const _palette = <Color>[
    Color(0xFF111111),
    Color(0xFF656A70),
    Color(0xFF82451F),
    Color(0xFFC52C38),
    Color(0xFFED6530),
    Color(0xFFF2A51A),
    Color(0xFF2F9B55),
    Color(0xFF168A83),
    Color(0xFF1F9CBC),
    Color(0xFF315BC8),
    Color(0xFF6848D2),
    Color(0xFF9C42BB),
    Color(0xFFD44286),
  ];
  static const _paletteLabels = <String>[
    '黑色',
    '灰色',
    '棕色',
    '红色',
    '橙色',
    '黄色',
    '绿色',
    '青色',
    '湖蓝色',
    '蓝色',
    '紫色',
    '浅紫色',
    '粉色',
  ];

  late final HomeChatDrawingDraftStore _store;
  final _textFocusNode = FocusNode();
  final _controller = PainterController(
    settings: PainterSettings(
      text: TextSettings(textStyle: const TextStyle(fontSize: 30, color: _ink)),
      freeStyle: const FreeStyleSettings(color: _ink, strokeWidth: 6),
      shape: ShapeSettings(
        paint: Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6,
      ),
      scale: const ScaleSettings(enabled: true, minScale: 1, maxScale: 5),
    ),
    background: const ColorBackgroundDrawable(color: _paper),
  );
  final _codec = DrawableJsonCodec();
  Timer? _saveTimer;
  late final Future<void> _restoreFuture;
  HomeChatDrawingDraft? _draft;
  Uint8List? _backgroundBytes;
  String? _backgroundPath;
  ui.Image? _backgroundImage;
  Color _selectedColor = _ink;
  double _strokeWidth = 6;
  bool _ready = false;
  bool _saving = false;
  bool _closing = false;
  bool _changed = false;
  bool _backgroundNeedsWrite = false;
  String? _saveError;
  Future<void> Function()? _retryOperation;
  int _tool = 1;
  int _saveRevision = 0;
  List<Drawable> _observedDrawables = const [];
  Object? _observedBackground;
  Future<void> _saveQueue = Future<void>.value();

  bool get _canEdit => _ready && _draft != null && !_saving && !_closing;

  @override
  void initState() {
    super.initState();
    _store = HomeChatDrawingDraftStore(accountScope: widget.accountScope);
    WidgetsBinding.instance.addObserver(this);
    _controller.textSettings = _controller.textSettings.copyWith(
      focusNode: _textFocusNode,
    );
    _controller.addListener(_onControllerChanged);
    _textFocusNode.addListener(_onTextFocusChanged);
    _restoreFuture = _restoreDraft();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _textFocusNode.removeListener(_onTextFocusChanged);
    _textFocusNode.dispose();
    _controller.dispose();
    _backgroundImage?.dispose();
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _saveError = '草稿读取失败：$error';
        _retryOperation = _restoreDraft;
      });
    }
  }

  void _onTextFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (!_ready || _draft == null) return;
    final drawables = _controller.value.drawables;
    final background = _controller.value.background;
    if (listEquals(_observedDrawables, drawables) &&
        identical(_observedBackground, background)) {
      return;
    }
    _observedDrawables = List<Drawable>.of(drawables);
    _observedBackground = background;
    _changed = true;
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
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
      );
      if (picked == null) return;
      final decoded = raster.decodeImage(await picked.readAsBytes());
      if (decoded == null) throw const FormatException('无法读取这张图片');
      final scaled = decoded.width > 2048 || decoded.height > 2048
          ? raster.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? 2048 : null,
              height: decoded.height > decoded.width ? 2048 : null,
              interpolation: raster.Interpolation.linear,
            )
          : decoded;
      await _setBackground(Uint8List.fromList(raster.encodePng(scaled)));
      _backgroundNeedsWrite = true;
      _onControllerChanged();
      _retryOperation = null;
      if (mounted && _saveError != null) setState(() => _saveError = null);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saveError = '图片导入失败：$error';
          _retryOperation = _importBackground;
        });
      }
    }
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
    _textFocusNode.unfocus();
    setState(() => _tool = tool);
    _controller.shapeFactory = null;
    _controller.freeStyleMode = switch (tool) {
      1 => FreeStyleMode.draw,
      4 => FreeStyleMode.erase,
      _ => FreeStyleMode.none,
    };
    if (tool == 2) _controller.addText();
  }

  void _chooseColor(Color color) {
    setState(() => _selectedColor = color);
    _controller.freeStyleColor = color;
    _controller.shapeSettings = _controller.shapeSettings.copyWith(
      paint: Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth,
    );
    _controller.textSettings = _controller.textSettings.copyWith(
      textStyle: TextStyle(fontSize: 30, color: color),
    );
  }

  void _chooseStrokeWidth(double value) {
    setState(() => _strokeWidth = value);
    _controller.freeStyleStrokeWidth = value;
    _controller.shapeSettings = _controller.shapeSettings.copyWith(
      paint: Paint()
        ..color = _selectedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = value,
    );
  }

  void _setShape(ShapeFactory factory) {
    _textFocusNode.unfocus();
    setState(() => _tool = 3);
    _controller.freeStyleMode = FreeStyleMode.none;
    _controller.shapeSettings = _controller.shapeSettings.copyWith(
      factory: factory,
      paint: Paint()
        ..color = _selectedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth,
    );
  }

  Future<void> _finish() async {
    if (!_canEdit || !_hasContent) return;
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
      if (mounted) {
        Navigator.of(
          context,
        ).pop(HomeChatDrawingResult(pngBytes: result, draftPath: draft.path));
      }
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
  }

  Future<Uint8List> _renderExport() async {
    const sizes = <Size>[
      Size(1638, 2048),
      Size(1440, 1800),
      Size(1152, 1440),
      Size(960, 1200),
      Size(768, 960),
    ];
    for (final size in sizes) {
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
    if (_changed || (_draft?.wasResumed == true && _hasContent)) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃更改？'),
          content: const Text('尚未完成的绘图将被放弃。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃更改'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) {
        if (mounted) setState(() => _closing = false);
        return;
      }
    }
    _saveTimer?.cancel();
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
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LayoutBuilder(
          builder: (context, screen) {
            final isTablet = screen.maxWidth >= 720;
            final board = SafeArea(
              child: Column(
                children: [
                  _buildToolbar(colors),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        alignment: Alignment.center,
                        children: [
                          if (_ready)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                                maxHeight: constraints.maxHeight,
                              ),
                              child: AspectRatio(
                                aspectRatio: 0.8,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: ColoredBox(
                                    color: _paper,
                                    child: AbsorbPointer(
                                      absorbing: !_canEdit,
                                      child: FlutterPainter(
                                        controller: _controller,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            const SizedBox.expand(),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: SizedBox(
                                  width: 188,
                                  child: Slider(
                                    min: 2,
                                    max: 32,
                                    value: _strokeWidth,
                                    activeColor: _ink,
                                    inactiveColor: const Color(0xFFD0D0D0),
                                    onChanged: _canEdit
                                        ? _chooseStrokeWidth
                                        : null,
                                    semanticFormatterCallback: (value) =>
                                        '线条粗细 ${value.round()}',
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_saveError != null)
                            Positioned(
                              left: 18,
                              right: 18,
                              top: 8,
                              child: Material(
                                color: const Color(0xFFFFF3F0),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    6,
                                    6,
                                    6,
                                  ),
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
                        ],
                      ),
                    ),
                  ),
                  _buildPalette(),
                  const SizedBox(height: 8),
                ],
              ),
            );
            if (!isTablet) {
              return ColoredBox(color: const Color(0xFFECEDEF), child: board);
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0x66000000)),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 960,
                      maxHeight: screen.maxHeight > 860
                          ? 860
                          : screen.maxHeight,
                    ),
                    child: Material(
                      color: const Color(0xFFECEDEF),
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: board,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildToolbar(ColorScheme colors) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 390;
      final toolButtonWidth = compact ? 36.0 : 40.0;
      final iconSize = compact ? 18.0 : 21.0;
      final toolGroup = Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _toolButton(
              0,
              'assets/icons/drawing/mouse-pointer-2.svg',
              '选择',
              buttonWidth: toolButtonWidth,
              iconSize: iconSize,
            ),
            _toolButton(
              1,
              'assets/icons/capabilities/brush.svg',
              '手绘',
              buttonWidth: toolButtonWidth,
              iconSize: iconSize,
            ),
            _toolButton(
              2,
              'assets/icons/chat_note_editor/text-aa.svg',
              '文字',
              buttonWidth: toolButtonWidth,
              iconSize: iconSize,
            ),
            PopupMenuButton<int>(
              tooltip: '形状',
              enabled: _canEdit,
              onSelected: (value) => _setShape(switch (value) {
                0 => ArrowFactory(),
                1 => RectangleFactory(),
                _ => OvalFactory(),
              }),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 0, child: Text('箭头')),
                PopupMenuItem(value: 1, child: Text('矩形')),
                PopupMenuItem(value: 2, child: Text('圆形')),
              ],
              child: SizedBox(
                width: toolButtonWidth,
                height: 44,
                child: _drawingIcon(
                  'assets/icons/drawing/shapes.svg',
                  _tool == 3 ? colors.primary : _ink,
                  iconSize,
                ),
              ),
            ),
            _toolButton(
              4,
              'assets/icons/drawing/eraser.svg',
              '橡皮擦',
              buttonWidth: toolButtonWidth,
              iconSize: iconSize,
            ),
          ],
        ),
      );
      if (compact) {
        return SizedBox(
          height: 58,
          child: Row(
            children: [
              IconButton(
                tooltip: '关闭绘图',
                onPressed: _closing || _saving ? null : _close,
                icon: _drawingIcon(
                  'assets/icons/chat_note_editor/x.svg',
                  _ink,
                  22,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                padding: EdgeInsets.zero,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, available) =>
                      available.maxWidth < toolButtonWidth * 5 + 48
                      ? SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: toolGroup,
                        )
                      : Center(child: toolGroup),
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: PopupMenuButton<int>(
                  tooltip: '撤销和重做',
                  enabled: _canEdit,
                  onSelected: (value) {
                    if (value == 0) {
                      _controller.undo();
                    } else {
                      _controller.redo();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 0,
                      enabled: _controller.canUndo,
                      child: const Text('撤销'),
                    ),
                    PopupMenuItem(
                      value: 1,
                      enabled: _controller.canRedo,
                      child: const Text('重做'),
                    ),
                  ],
                  child: Center(
                    child: _drawingIcon(
                      'assets/icons/chat_note_editor/dots-three-vertical.svg',
                      _ink,
                      20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return SizedBox(
        height: 58,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: '关闭绘图',
                onPressed: _closing || _saving ? null : _close,
                icon: _drawingIcon(
                  'assets/icons/chat_note_editor/x.svg',
                  _ink,
                  22,
                ),
              ),
            ),
            Center(child: toolGroup),
            Align(
              alignment: Alignment.centerRight,
              child: ValueListenableBuilder<PainterControllerValue>(
                valueListenable: _controller,
                builder: (context, _, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '撤销',
                      onPressed: _canEdit && _controller.canUndo
                          ? _controller.undo
                          : null,
                      icon: _drawingIcon(
                        'assets/icons/chat_note_editor/arrow-counter-clockwise.svg',
                        _controller.canUndo ? _ink : const Color(0xFFB8BBC0),
                        iconSize,
                      ),
                      constraints: BoxConstraints.tightFor(
                        width: toolButtonWidth,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    IconButton(
                      tooltip: '重做',
                      onPressed: _canEdit && _controller.canRedo
                          ? _controller.redo
                          : null,
                      icon: _drawingIcon(
                        'assets/icons/chat_note_editor/arrow-clockwise.svg',
                        _controller.canRedo ? _ink : const Color(0xFFB8BBC0),
                        iconSize,
                      ),
                      constraints: BoxConstraints.tightFor(
                        width: toolButtonWidth,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _toolButton(
    int tool,
    String icon,
    String tooltip, {
    Future<void> Function()? onPressed,
    double buttonWidth = 40,
    double iconSize = 21,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: _canEdit ? onPressed ?? () => _selectTool(tool) : null,
    icon: _drawingIcon(
      icon,
      _tool == tool ? Theme.of(context).colorScheme.primary : _ink,
      iconSize,
    ),
    constraints: BoxConstraints.tightFor(width: buttonWidth, height: 44),
    padding: EdgeInsets.zero,
  );

  Widget _buildPalette() => SizedBox(
    height: 56,
    child: Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '导入底图',
                      onPressed: _canEdit ? _importBackground : null,
                      icon: _drawingIcon(
                        'assets/icons/capabilities/image.svg',
                        _ink,
                        21,
                      ),
                    ),
                    for (final color in _palette)
                      Semantics(
                        button: true,
                        selected: color == _selectedColor,
                        label:
                            '画笔颜色 ${_paletteLabels[_palette.indexOf(color)]}',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _canEdit ? () => _chooseColor(color) : null,
                          child: SizedBox(
                            width: 34,
                            height: 44,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 100),
                                width: color == _selectedColor ? 30 : 24,
                                height: color == _selectedColor ? 30 : 24,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: color == _selectedColor
                                        ? const Color(0xFF94999E)
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: '完成绘图',
          child: SizedBox(
            width: 50,
            height: 50,
            child: ValueListenableBuilder<PainterControllerValue>(
              valueListenable: _controller,
              builder: (context, _, _) => FilledButton(
                onPressed: _canEdit && _hasContent ? _finish : null,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  backgroundColor: _ink,
                  foregroundColor: Colors.white,
                ),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : _drawingIcon(
                        'assets/icons/drawing/check.svg',
                        Colors.white,
                        23,
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
    ),
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
