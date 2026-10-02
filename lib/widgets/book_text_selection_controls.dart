import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Text-selection handles for the structured book reader.
///
/// The pencil is a frozen asset taken from the selected visual reference. The
/// framework still owns the gesture hit target and drag semantics; this class
/// only supplies the visible handle and its anchor points.
class BookPencilTextSelectionControls extends MaterialTextSelectionControls {
  BookPencilTextSelectionControls({this.textDirection = TextDirection.ltr});

  /// The paragraph direction Flutter uses to map start/end handles onto
  /// [TextSelectionHandleType.left] and [TextSelectionHandleType.right].
  final TextDirection textDirection;

  static const String assetPath =
      'assets/icons/editor/selection_pencil_handle.png';

  /// The translucent charcoal used for selected text across the app.
  static const Color selectionColor = Color(0x33202124);

  /// A collapsed selection uses this thin caret and no visible handle.
  static const Color cursorColor = Colors.black;

  /// Native selection paint stays transparent in editable fields; the soft
  /// per-line backdrop below supplies the visible selected state.
  static const Color editableSelectionColor = Colors.transparent;

  static const Size _handleSize = Size(34, 34);

  // Asset-space metadata, measured once from the frozen 78x78 source image.
  // This is the pencil's actual graphite point, not a screen-position tweak.
  // Keeping it normalized makes the anchor stay correct if the visible handle
  // size changes later.
  static const Size _assetSize = Size(78, 78);
  static const Offset _assetTip = Offset(12.5, 72.5);
  static const double _imageInset = 1;

  static Offset get _untransformedTip {
    final imageSize = _handleSize.shortestSide - (_imageInset * 2);
    return Offset(
      _imageInset + (_assetTip.dx / _assetSize.width * imageSize),
      _imageInset + (_assetTip.dy / _assetSize.height * imageSize),
    );
  }

  bool _isStartHandle(TextSelectionHandleType type) {
    return switch (textDirection) {
      TextDirection.ltr => type == TextSelectionHandleType.left,
      TextDirection.rtl => type == TextSelectionHandleType.right,
    };
  }

  ({bool flipX, bool flipY}) _flipsFor(TextSelectionHandleType type) {
    final isStart = _isStartHandle(type);
    return switch ((textDirection, isStart)) {
      // Start pencils extend above and away from the paragraph; end pencils
      // extend below and away from it.
      (TextDirection.ltr, true) => (flipX: true, flipY: false),
      (TextDirection.ltr, false) => (flipX: false, flipY: true),
      (TextDirection.rtl, true) => (flipX: false, flipY: false),
      (TextDirection.rtl, false) => (flipX: true, flipY: true),
    };
  }

  Offset _tipFor(TextSelectionHandleType type) {
    final tip = _untransformedTip;
    final flips = _flipsFor(type);
    return Offset(
      flips.flipX ? _handleSize.width - tip.dx : tip.dx,
      flips.flipY ? _handleSize.height - tip.dy : tip.dy,
    );
  }

  @override
  Size getHandleSize(double textLineHeight) => _handleSize;

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textHeight, [
    VoidCallback? onTap,
  ]) {
    if (type == TextSelectionHandleType.collapsed) {
      // A collapsed selection is an insertion caret, not a text range. Keep
      // the handle slot empty so the pencil never appears in cursor state.
      return const SizedBox.shrink();
    }
    final image = Image.asset(
      assetPath,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      excludeFromSemantics: true,
    );
    // The pencil body must extend away from the text after its graphite point
    // touches the selection. Flutter swaps left/right types for RTL, so use
    // both the handle type and paragraph direction to orient the same asset.
    final flips = _flipsFor(type);
    final directedImage = Transform.flip(
      flipX: flips.flipX,
      flipY: flips.flipY,
      child: image,
    );
    return SizedBox(
      width: _handleSize.width,
      height: _handleSize.height,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.translucent,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: RepaintBoundary(child: directedImage),
        ),
      ),
    );
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    if (type == TextSelectionHandleType.collapsed) return Offset.zero;
    final tip = _tipFor(type);
    // RenderEditable's handle LayerLinks are already located at the bottom of
    // the first/last selected glyph box. Move the logical start tip up by
    // exactly that glyph's measured height; the logical end tip stays on the
    // bottom edge. The remaining x/y values only map the transformed asset's
    // real tip into its 34dp box. No global position is recomputed here.
    return _isStartHandle(type) ? Offset(tip.dx, tip.dy + textLineHeight) : tip;
  }
}

final BookPencilTextSelectionControls bookPencilTextSelectionControls =
    BookPencilTextSelectionControls();

/// Paints the selected range as separate, softly diffused graphite bands.
///
/// [TextField] keeps its native editing, cursor, toolbar and drag behavior.
/// Only its native hard selection rectangle is made transparent; this painter
/// listens directly to the controller and repaints inside an isolated layer.
class BookTextSelectionBackdrop extends StatefulWidget {
  const BookTextSelectionBackdrop({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  State<BookTextSelectionBackdrop> createState() =>
      _BookTextSelectionBackdropState();
}

class _BookTextSelectionBackdropState extends State<BookTextSelectionBackdrop> {
  final _paintKey = GlobalKey();
  final ValueNotifier<List<Rect>> _selectionRects = ValueNotifier<List<Rect>>(
    const <Rect>[],
  );
  bool _geometrySyncPending = false;
  RenderEditable? _editable;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(covariant BookTextSelectionBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _editable = null;
    _onControllerChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _selectionRects.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final selection = widget.controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      // Normal typing and long-press backspace keep a collapsed caret. Avoid
      // scheduling RenderEditable geometry work on every repeated key event;
      // there is no selection wash to paint in this state.
      _replaceRects(const <Rect>[]);
      return;
    }
    _scheduleGeometrySync();
  }

  void _scheduleGeometrySync() {
    if (_geometrySyncPending) return;
    _geometrySyncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometrySyncPending = false;
      if (mounted) _syncGeometry();
    });
  }

  void _syncGeometry() {
    final selection = widget.controller.selection;
    final paintBox = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    final cachedEditable = _editable;
    final editable = cachedEditable != null && cachedEditable.attached
        ? cachedEditable
        : paintBox == null
        ? null
        : _findRenderEditable(paintBox);
    _editable = editable;
    if (paintBox == null ||
        editable == null ||
        !selection.isValid ||
        selection.isCollapsed) {
      _replaceRects(const <Rect>[]);
      return;
    }

    final boxes = editable.getBoxesForSelection(selection);
    final visibleBoxes = boxes
        .where((box) => box.right > box.left && box.bottom > box.top)
        .toList(growable: false);
    final endpoints = editable.getEndpointsForSelection(selection);
    final transform = editable.getTransformTo(paintBox);
    final next = <Rect>[];
    for (var index = 0; index < visibleBoxes.length; index++) {
      final box = visibleBoxes[index];
      var left = box.left;
      var right = box.right;
      // Some Android text layouts return a full visual line for the first or
      // last box even with BoxWidthStyle.tight. Clamp only those edge boxes
      // back to RenderEditable's own selection endpoints. These endpoints and
      // the boxes share one local coordinate system and one TextPainter source.
      if (index == 0 && endpoints.isNotEmpty) {
        final startX = endpoints.first.point.dx;
        if (startX > left && startX < right) {
          if (box.direction == TextDirection.ltr) {
            left = startX;
          } else {
            right = startX;
          }
        }
      }
      if (index == visibleBoxes.length - 1 && endpoints.length == 2) {
        final endX = endpoints.last.point.dx;
        if (endX > left && endX < right) {
          if (box.direction == TextDirection.ltr) {
            right = endX;
          } else {
            left = endX;
          }
        }
      }
      if (right > left) {
        next.add(
          MatrixUtils.transformRect(
            transform,
            Rect.fromLTRB(left, box.top, right, box.bottom),
          ),
        );
      }
    }
    _replaceRects(next);
  }

  void _replaceRects(List<Rect> next) {
    final current = _selectionRects.value;
    if (current.length == next.length && _sameRects(current, next)) {
      return;
    }
    _selectionRects.value = next;
  }

  bool _sameRects(List<Rect> left, List<Rect> right) {
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  RenderEditable? _findRenderEditable(RenderObject root) {
    if (root is RenderEditable) return root;
    RenderEditable? result;
    root.visitChildren((child) {
      result ??= _findRenderEditable(child);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _paintKey,
      child: CustomPaint(
        painter: _BookTextSelectionPainter(rects: _selectionRects),
        child: widget.child,
      ),
    );
  }
}

class _BookTextSelectionPainter extends CustomPainter {
  _BookTextSelectionPainter({required this.rects}) : super(repaint: rects);

  final ValueListenable<List<Rect>> rects;

  static final Paint _glowPaint = Paint()
    ..color = const Color(0x1C19232B)
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4);

  static final Paint _washPaint = Paint()..color = const Color(0x0719232B);

  @override
  void paint(Canvas canvas, Size size) {
    for (final box in rects.value) {
      final rect = Rect.fromLTRB(
        box.left - 1.5,
        box.top - 1.5,
        box.right + 1.5,
        box.bottom + 1.5,
      );
      final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(rounded, _glowPaint);
      canvas.drawRRect(rounded, _washPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BookTextSelectionPainter oldDelegate) {
    return oldDelegate.rects != rects;
  }
}
