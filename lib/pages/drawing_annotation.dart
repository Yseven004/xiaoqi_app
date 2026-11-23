part of 'drawing_board_page.dart';

/// An editable, transparent drawing in the coordinate space of one reader anchor.
/// The host owns persistence; the drawing plugin owns its drawable format.
class DrawingAnnotationLayer {
  DrawingAnnotationLayer({
    required this.size,
    this.document,
    this.initial = const [],
  });

  final Size size;
  Map<String, Object?>? document;
  final List<Drawable> initial;
  List<Drawable>? _items;
  Future<List<Drawable>>? _loading;
  int _attachments = 0;
  bool changed = false;
  final _images = <ui.Image>{};

  Future<List<Drawable>> _load() async {
    final items = _items;
    if (items != null) return items;
    final source = document;
    if (source == null) return _items = initial;
    return _loading ??= _decode(source);
  }

  Future<List<Drawable>> _decode(Map<String, Object?> source) async {
    final items = await DrawableJsonCodec().decode(source);
    _rememberImages(items);
    _items = items;
    _releaseDetached();
    return items;
  }

  void _rememberImages(Iterable<Drawable> items) {
    for (final item in items) {
      if (item is ImageDrawable) _images.add(item.image);
      if (item is ObjectGroupDrawable) _rememberImages(item.drawables);
    }
  }

  void _replace(List<Drawable> items) {
    _items = List.unmodifiable(items);
    changed = true;
  }

  Future<Map<String, Object?>> encode() =>
      DrawableJsonCodec().encode(_items ?? initial);

  void saved(Map<String, Object?> encoded) {
    document = encoded;
    changed = false;
    _releaseDetached();
  }

  void _releaseDetached() {
    if (_attachments > 0 || changed) return;
    for (final image in _images) {
      image.dispose();
    }
    _images.clear();
    _items = null;
    _loading = null;
  }

  void dispose() {
    changed = false;
    _releaseDetached();
  }
}

/// One compact tool palette controls the currently touched page or text block.
class DrawingAnnotationTools extends ChangeNotifier {
  final _boards = <_DrawingBoardPageState>{};
  final _legacyBoards = <_DrawingBoardPageState>{};
  final _viewportKey = GlobalKey();
  _DrawingBoardPageState? _active;
  var _viewportSize = Size.zero;
  bool _scheduled = false;
  bool _disposed = false;
  bool _canAdoptLegacy = false;
  var _brush = (
    color: _DrawingBoardPageState._ink,
    width: 5.0,
    eraserWidth: 30.0,
    tool: 1,
  );

  void begin({required Color color}) {
    _brush = (color: color, width: 5, eraserWidth: 30, tool: 1);
    _canAdoptLegacy = true;
  }

  void _applyBrush(_DrawingBoardPageState board) {
    board._selectedColor = _brush.color;
    board._penStrokeWidth = _brush.width;
    board._eraserStrokeWidth = _brush.eraserWidth;
    board._tool = _brush.tool;
    board._controller.freeStyleColor = _brush.color;
    board._controller.freeStyleStrokeWidth = board._activeStrokeWidth;
    board._syncFreeStyleMode();
  }

  void _attach(_DrawingBoardPageState board) {
    if (board.widget.legacyAnnotation) {
      _legacyBoards.add(board);
      _refresh();
      return;
    }
    _boards.add(board);
    _applyBrush(board);
    _refresh();
  }

  void _refresh() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      final source = _active;
      if (source != null) {
        final next = (
          color: source._selectedColor,
          width: source._penStrokeWidth,
          eraserWidth: source._eraserStrokeWidth,
          tool: source._tool,
        );
        if (next != _brush) {
          _brush = next;
          for (final board in _boards) {
            if (board != source) _applyBrush(board);
          }
        }
      }
      final render = _viewportKey.currentContext?.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        final board = _visibleBoard(
          render.localToGlobal(Offset.zero) & render.size,
        );
        if (_canAdoptLegacy &&
            board != null &&
            board.widget.adoptsLegacyAnnotations) {
          _adoptLegacyObjects(board);
        }
      }
      notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _detach(_DrawingBoardPageState board) {
    _legacyBoards.remove(board);
    _boards.remove(board);
    if (_active == board) _active = null;
    _refresh();
  }

  void _adoptLegacyObjects(_DrawingBoardPageState target) {
    final targetPainter = target._controller.painterKey.currentContext
        ?.findRenderObject();
    if (!target._canEdit ||
        targetPainter is! RenderBox ||
        !targetPainter.attached ||
        !targetPainter.hasSize) {
      return;
    }
    final targetBounds = Offset.zero & targetPainter.size;
    final targetLayer = target.widget.annotation!;
    for (final source in _legacyBoards) {
      final sourcePainter = source._controller.painterKey.currentContext
          ?.findRenderObject();
      if (!source._ready ||
          sourcePainter is! RenderBox ||
          !sourcePainter.attached ||
          !sourcePainter.hasSize) {
        continue;
      }
      final sourceLayer = source.widget.annotation!;
      Offset intoTarget(Offset point) =>
          targetPainter.globalToLocal(sourcePainter.localToGlobal(point));
      final scale =
          (intoTarget(const Offset(0, 1)) - intoTarget(Offset.zero)).distance;
      if (!scale.isFinite || scale <= 0) continue;
      final migrated = <ObjectDrawable>[];
      final objects = source._controller.value.drawables
          .whereType<ObjectDrawable>()
          .toList();
      for (final object in objects) {
        if (object is! ImageDrawable && object is! TextDrawable) continue;
        if (sourceLayer._items?.contains(object) != true) continue;
        final position = intoTarget(object.position);
        final size = object.getSize(maxWidth: sourcePainter.size.width) * scale;
        final bounds = Rect.fromCenter(
          center: position,
          width: size.width,
          height: size.height,
        );
        final rotated = target._rotatedBounds(bounds, object.rotationAngle);
        if (!rotated.isFinite ||
            rotated.left < targetBounds.left ||
            rotated.top < targetBounds.top ||
            rotated.right > targetBounds.right ||
            rotated.bottom > targetBounds.bottom) {
          continue;
        }
        if (!source._controller.removeDrawable(object, newAction: false))
          continue;
        final objectScale = object.scale * scale;
        if (object is ImageDrawable) {
          final image = object.image.clone();
          targetLayer._images.add(image);
          migrated.add(
            object.copyWith(
              position: position,
              scale: objectScale,
              image: image,
            ),
          );
        } else {
          migrated.add(object.copyWith(position: position, scale: objectScale));
        }
      }
      // Both layers go through the reader's existing atomic save.
      if (migrated.isNotEmpty) {
        target._controller.insertDrawables(0, migrated, newAction: false);
      }
    }
  }

  void _select(_DrawingBoardPageState board) {
    if (_active == board) return;
    final previous = _active;
    _active = board;
    if (previous != null && previous.mounted) {
      previous._suspendTools();
    }
    _refresh();
  }

  _DrawingBoardPageState? _visibleBoard(Rect viewport) {
    _DrawingBoardPageState? nearest;
    double distance = double.infinity;
    for (final board in _boards) {
      final render = board._canvasCardKey.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final bounds = MatrixUtils.transformRect(
        render.getTransformTo(null),
        Offset.zero & render.size,
      );
      if (!bounds.overlaps(viewport)) continue;
      if (_active == board) return board;
      final score =
          (bounds.intersect(viewport).center - viewport.center).distanceSquared;
      if (score < distance) {
        nearest = board;
        distance = score;
      }
    }
    return _active = nearest;
  }

  void commitText() {
    _canAdoptLegacy = false;
    for (final board in _boards.toList()) {
      if (board.mounted && board._textEditing) board._commitInlineText();
    }
  }

  bool get busy => _boards.any((board) => board._imagePicking);

  Widget controls({required VoidCallback? onFinish}) => SafeArea(
    child: LayoutBuilder(
      builder: (context, bounds) {
        if (_viewportSize != bounds.biggest) {
          _viewportSize = bounds.biggest;
          _refresh();
        }
        return ListenableBuilder(
          listenable: this,
          builder: (context, _) {
            final size = bounds.biggest;
            final board = _active;
            return Stack(
              key: _viewportKey,
              children: [
                if (board != null) ...board._drawingPopovers(size),
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (board != null) ...[
                        if (size.width >= 340) const SizedBox(width: 58),
                        board._buildToolPill(38, 19),
                        const SizedBox(width: 10),
                      ],
                      SizedBox.square(
                        dimension: 48,
                        child: Material(
                          color: const Color(0xFFF0F4F7),
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: '完成涂鸦',
                            onPressed: busy ? null : onFinish,
                            icon: SvgPicture.asset(
                              'assets/icons/drawing/check.svg',
                              width: 20,
                              height: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    ),
  );

  @override
  void dispose() {
    _disposed = true;
    _boards.clear();
    _legacyBoards.clear();
    super.dispose();
  }
}
