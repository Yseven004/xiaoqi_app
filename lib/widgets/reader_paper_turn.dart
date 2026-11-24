import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A visual layer over the existing pager. Only a completed turn changes the
/// pager's position. Until then both live pages stay in their original places.
class ReaderPaperTurn extends StatefulWidget {
  const ReaderPaperTurn({
    super.key,
    required this.enabled,
    required this.revision,
    required this.page,
    required this.pageCount,
    required this.paper,
    required this.buildAdjacentPage,
    required this.onTurn,
    required this.child,
    this.onTurnStart,
    this.onTurnActivityChanged,
  });

  final bool enabled;
  final Object revision;
  final int page;
  final int pageCount;
  final Color paper;
  final Widget Function(BuildContext, int) buildAdjacentPage;
  final ValueChanged<int> onTurn;
  final Widget child;
  final VoidCallback? onTurnStart;
  final ValueChanged<bool>? onTurnActivityChanged;

  @override
  State<ReaderPaperTurn> createState() => _ReaderPaperTurnState();
}

/// Wide tables and figures own their horizontal drag inside the reader.
class ReaderPaperTurnLocalDrag extends StatelessWidget {
  const ReaderPaperTurnLocalDrag({super.key, required this.child});

  final Widget child;

  void _reserve(BuildContext context, PointerEvent event) {
    context.findAncestorStateOfType<_ReaderPaperTurnState>()?._localPointer =
        event.pointer;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => _reserve(context, event),
    onPointerPanZoomStart: (event) => _reserve(context, event),
    child: child,
  );
}

class _ReaderPaperTurnState extends State<ReaderPaperTurn>
    with SingleTickerProviderStateMixin {
  late final _settle = AnimationController(vsync: this)..addListener(_tick);
  final _fold = ValueNotifier<_PaperFold?>(null);
  Offset? _origin;
  int? _localPointer;
  int? _trackedPointer;
  Offset? _pointerOrigin;
  Offset? _pointerPosition;
  _PaperTurnDrag? _recognizer;
  int? _target;
  _PaperFold? _settleFrom;
  bool _commit = false;
  bool _turnStarted = false;

  @override
  void didUpdateWidget(covariant ReaderPaperTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.revision != widget.revision) _clear();
  }

  @override
  void dispose() {
    _reportIdle();
    _settle.dispose();
    _fold.dispose();
    super.dispose();
  }

  void _clear() {
    _settle.stop();
    _origin = null;
    _target = null;
    _settleFrom = null;
    _fold.value = null;
    _reportIdle();
  }

  void _reportIdle() {
    if (!_turnStarted) return;
    _turnStarted = false;
    widget.onTurnActivityChanged?.call(false);
  }

  void _start(DragStartDetails details) {
    if (_settle.isAnimating && !_commit) setState(_clear);
    if (_target != null) return;
    _origin = details.localPosition;
    _turnStarted = false;
  }

  void _drag(DragUpdateDetails details) {
    final origin = _origin;
    final size = context.size;
    if (origin == null || size == null || size.isEmpty || _settle.isAnimating) {
      return;
    }
    // Flutter's first HorizontalDrag update reports the horizontal component
    // of the initial movement. Keep the real touch's vertical travel too.
    final position = _pointerPosition ?? details.localPosition;
    final delta = position - origin;
    final currentTarget = _target;
    if (currentTarget == null ||
        (currentTarget > widget.page ? delta.dx > 10 : delta.dx < -10)) {
      if (delta.dx.abs() < 2) return;
      final target = widget.page + (delta.dx < 0 ? 1 : -1);
      if (target < 0 || target >= widget.pageCount) {
        _fold.value = null;
        return;
      }
      setState(() => _target = target);
      if (!_turnStarted) {
        _turnStarted = true;
        widget.onTurnActivityChanged?.call(true);
        widget.onTurnStart?.call();
      }
    }
    final forward = _target! > widget.page;
    final travelled = forward ? -delta.dx : delta.dx;
    _fold.value = _PaperFold(
      forward: forward,
      progress: (travelled / size.width).clamp(0.0, 1.0),
      touchHeight: (origin.dy / size.height).clamp(0.0, 1.0),
      verticalTravel: (delta.dy / size.height).clamp(-.40, .40),
    );
  }

  void _finish(double velocity, {bool cancelled = false}) {
    // A second gesture can enter the arena while the first one settles.
    if (_origin == null) return;
    _origin = null;
    final from = _fold.value;
    final size = context.size;
    if (from == null || _target == null || size == null) {
      if (_target != null) setState(_clear);
      return;
    }
    if (from.progress == 0) {
      setState(_clear);
      return;
    }
    final speed = from.forward ? -velocity : velocity;
    final distance = from.progress * size.width;
    final threshold = (size.width * .22).clamp(44.0, 125.0);
    final flickDistance = (size.width * .045).clamp(18.0, 32.0);
    _commit =
        !cancelled &&
        speed > -280 &&
        (distance >= threshold ||
            (speed >= 330 &&
                distance >= flickDistance &&
                distance + speed * .10 >= threshold * .80));
    _settleFrom = from;
    _settle.duration = Duration(
      milliseconds: _commit
          ? (150 - speed.clamp(0.0, 1500.0) * .033).round()
          : (90 + from.progress * 44).round(),
    );
    _settle.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _settle.status != AnimationStatus.completed) return;
      final target = _target;
      final commit = _commit;
      if (commit && target != null) widget.onTurn(target);
      if (mounted) setState(_clear);
    });
  }

  void _tick() {
    final from = _settleFrom;
    if (from == null) return;
    final t = Curves.easeOutCubic.transform(_settle.value);
    _fold.value = _PaperFold(
      forward: from.forward,
      progress: from.progress + ((_commit ? 1.0 : 0.0) - from.progress) * t,
      touchHeight: from.touchHeight,
      verticalTravel: from.verticalTravel,
    );
  }

  void _pointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    _trackPointer(event);
  }

  void _trackPointer(PointerEvent event) {
    if (_trackedPointer != null || _localPointer == event.pointer) return;
    _trackedPointer = event.pointer;
    _pointerOrigin = event.localPosition;
    _pointerPosition = event.localPosition;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_trackedPointer == event.pointer) {
      _pointerPosition = event.localPosition;
      _recognizer?.prioritizeTouch(
        event,
        event.localPosition - _pointerOrigin!,
      );
    }
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_trackedPointer == event.pointer) {
      _pointerPosition = event.localPosition + event.localPan;
    }
  }

  void _releasePointer(PointerEvent event) {
    if (_trackedPointer != event.pointer) return;
    if (event is PointerCancelEvent) _finish(0, cancelled: true);
    _trackedPointer = null;
    _pointerOrigin = null;
    _pointerPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    return Listener(
      // An accepted Flutter drag can report onEnd for a system cancel.
      // Handle the raw event before the drag recognizer can commit the page.
      onPointerDown: widget.enabled ? _pointerDown : null,
      onPointerMove: widget.enabled ? _pointerMove : null,
      onPointerPanZoomStart: widget.enabled ? _trackPointer : null,
      onPointerPanZoomUpdate: widget.enabled ? _panZoomUpdate : null,
      onPointerPanZoomEnd: _releasePointer,
      onPointerUp: _releasePointer,
      onPointerCancel: _releasePointer,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        gestures: {
          if (widget.enabled)
            _PaperTurnDrag:
                GestureRecognizerFactoryWithHandlers<_PaperTurnDrag>(
                  () => _recognizer = _PaperTurnDrag(
                    debugOwner: this,
                    canTrack: (pointer) =>
                        _localPointer != pointer && _trackedPointer == null,
                    touchTravel: () =>
                        switch ((_pointerOrigin, _pointerPosition)) {
                          (final Offset start, final Offset end) => end - start,
                          _ => null,
                        },
                  ),
                  (recognizer) {
                    recognizer
                      ..gestureSettings = settings
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onlyAcceptDragOnThreshold = true
                      ..onStart = _start
                      ..onUpdate = _drag
                      ..onCancel = () => _finish(0, cancelled: true);
                    recognizer.onEnd = (details) =>
                        _finish(details.primaryVelocity ?? 0);
                  },
                ),
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (target != null)
              IgnorePointer(
                child: ExcludeSemantics(
                  child: ClipPath(
                    clipper: _RevealedPaper(_fold),
                    child: RepaintBoundary(
                      child: widget.buildAdjacentPage(context, target),
                    ),
                  ),
                ),
              ),
            if (target != null)
              IgnorePointer(
                child: CustomPaint(painter: _PaperBack(_fold, widget.paper)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PaperTurnDrag extends HorizontalDragGestureRecognizer {
  _PaperTurnDrag({
    required super.debugOwner,
    required this.canTrack,
    required this.touchTravel,
  });

  final bool Function(int) canTrack;
  final Offset? Function() touchTravel;

  double _touchThreshold() =>
      computeHitSlop(PointerDeviceKind.touch, gestureSettings) * .62;

  bool _horizontalEnough(Offset travel) =>
      travel.dy.abs() <= travel.dx.abs() * 1.10;

  void prioritizeTouch(PointerMoveEvent event, Offset travel) {
    if (event.kind != PointerDeviceKind.touch ||
        event.buttons != kPrimaryButton ||
        travel.dx.abs() <= _touchThreshold() ||
        !_horizontalEnough(travel)) {
      return;
    }
    // Hit-test listeners see the move before the arena's participants receive
    // it through the pointer router. If one input sample crosses both drag
    // thresholds, reserve the swipe before the text recognizer can win it.
    // An already accepted long press and an excluded wide object stay intact.
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  @override
  bool isPointerAllowed(PointerEvent event) =>
      canTrack(event.pointer) && super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      canTrack(event.pointer) && super.isPointerPanZoomAllowed(event);

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? deviceTouchSlop,
  ) {
    if (kind != PointerDeviceKind.touch) {
      return super.hasSufficientGlobalDistanceToAccept(kind, deviceTouchSlop);
    }
    // Android's SelectableText competes at the normal horizontal slop, even
    // when the text is unfocused. Recognize a deliberate finger swipe before
    // it, while vertical moves and small moves for taps/long-press still wait.
    final travel = touchTravel();
    return globalDistanceMoved.abs() > _touchThreshold() &&
        (travel == null || _horizontalEnough(travel));
  }
}

class _PaperFold {
  _PaperFold({
    required this.forward,
    required this.progress,
    required this.touchHeight,
    required this.verticalTravel,
  });

  final bool forward;
  final double progress;
  final double touchHeight;
  final double verticalTravel;
  Size? _geometrySize;
  _FoldGeometry? _geometry;

  _FoldGeometry geometry(Size size) {
    if (_geometrySize == size) return _geometry!;
    // Both directions share one mirrored coordinate system. An upward pull
    // lifts the lower corner. A sideways pull at mid-page stays near vertical.
    final corner = (touchHeight - .5) * 2;
    final cornerBias = .79 * corner.sign * math.pow(corner.abs(), .78);
    final pullAngle = math.atan2(
      -verticalTravel * size.height,
      size.width * (.07 + progress),
    );
    final tilt =
        (cornerBias + pullAngle * .8).clamp(-1.02, 1.02) *
        (1 - progress * progress * .70);
    final normal = Offset(math.cos(tilt), math.sin(tilt));
    final furthest =
        size.width * normal.dx + math.max(0.0, size.height * normal.dy);
    final nearest = math.min(0.0, size.height * normal.dy);
    // Keep the crease close to the touch motion instead of accelerating it
    // away from the finger. The reflected sheet is wide through the middle.
    final sweep = progress * (1.12 - .12 * progress);
    final crease = furthest - (furthest - nearest) * sweep;
    _geometrySize = size;
    return _geometry = _FoldGeometry(
      size,
      normal,
      crease,
      forward,
      1.07 - .27 * progress,
    );
  }
}

class _FoldGeometry {
  _FoldGeometry(
    this.size,
    this.normal,
    this.crease,
    this.forward,
    this.backCompression,
  );

  final Size size;
  final Offset normal;
  final double crease;
  final bool forward;
  final double backCompression;

  Offset toScreen(Offset point) =>
      forward ? point : Offset(size.width - point.dx, point.dy);

  double distance(Offset p) => p.dx * normal.dx + p.dy * normal.dy - crease;

  late final List<Offset> _lifted = _clipSheet();
  late final double _reach = _lifted.fold(
    0.0,
    (furthest, point) => math.max(furthest, distance(point)),
  );

  List<Offset> _clipSheet() {
    final corners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(size.width, size.height),
      Offset(0, size.height),
    ];
    final result = <Offset>[];
    for (var i = 0; i < corners.length; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % corners.length];
      final from = distance(a);
      final to = distance(b);
      if (from >= 0) result.add(a);
      if ((from < 0) != (to < 0)) {
        result.add(Offset.lerp(a, b, from / (from - to))!);
      }
    }
    return result;
  }

  late final Path revealed = _outline(backside: false);
  late final Path back = _outline(backside: true);
  double get backWidth => math.max(4.0, _reach * backCompression);

  Path _outline({required bool backside}) {
    final count = _lifted.length;
    if (count < 3) return Path();
    final onCrease = _lifted.map((p) => distance(p).abs() < .001).toList();
    final vertices = _lifted.map((p) {
      if (!backside) return p;
      return p - normal * (math.max(0.0, distance(p)) * (1 + backCompression));
    }).toList();
    final starts = <Offset>[];
    final ends = <Offset>[];
    for (var i = 0; i < count; i++) {
      final point = vertices[i];
      final round = backside && !onCrease[i] ? .09 : 0.0;
      starts.add(Offset.lerp(point, vertices[(i + count - 1) % count], round)!);
      ends.add(Offset.lerp(point, vertices[(i + 1) % count], round)!);
    }
    final first = toScreen(starts.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (var i = 0; i < count; i++) {
      final corner = toScreen(vertices[i]);
      final end = toScreen(ends[i]);
      path.quadraticBezierTo(corner.dx, corner.dy, end.dx, end.dy);
      final next = (i + 1) % count;
      final destination = toScreen(starts[next]);
      if (onCrease[i] && onCrease[next]) {
        // Both faces use the same bowed crease, so their seam stays joined
        // during a nearly straight side swipe and a diagonal corner turn.
        final length = (ends[i] - starts[next]).distance;
        final bow = math.min(
          length * .13,
          math.min(_reach * .22, size.width * .07),
        );
        final control = toScreen(
          Offset.lerp(ends[i], starts[next], .5)! + normal * bow,
        );
        path.quadraticBezierTo(
          control.dx,
          control.dy,
          destination.dx,
          destination.dy,
        );
      } else {
        path.lineTo(destination.dx, destination.dy);
      }
    }
    return path..close();
  }

  Offset gradientPoint(double signedDistance) =>
      toScreen(normal * (crease + signedDistance));
}

class _RevealedPaper extends CustomClipper<Path> {
  _RevealedPaper(this.fold) : super(reclip: fold);

  final ValueNotifier<_PaperFold?> fold;

  @override
  Path getClip(Size size) {
    final value = fold.value;
    if (value == null || value.progress <= 0) return Path();
    if (value.progress >= 1) return Path()..addRect(Offset.zero & size);
    return value.geometry(size).revealed;
  }

  @override
  bool shouldReclip(covariant _RevealedPaper oldClipper) =>
      oldClipper.fold != fold;
}

class _PaperBack extends CustomPainter {
  _PaperBack(this.fold, this.paper) : super(repaint: fold);

  final ValueNotifier<_PaperFold?> fold;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final value = fold.value;
    if (value == null || value.progress <= 0 || value.progress >= 1) return;
    final g = value.geometry(size);
    final dark = ThemeData.estimateBrightnessForColor(paper) == Brightness.dark;
    final shadow = math.sin(math.pi * value.progress).clamp(0.0, 1.0);
    final folded = g.back;
    final backWidth = g.backWidth;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Canvas gradients use a line normal to the crease even on diagonal turns.
    canvas.drawPath(
      g.revealed,
      Paint()
        ..shader = ui.Gradient.linear(
          g.gradientPoint(0),
          g.gradientPoint(25 + backWidth * .14),
          [Colors.black.withValues(alpha: shadow * .43), Colors.transparent],
        ),
    );
    canvas.drawShadow(
      folded,
      Colors.black.withValues(alpha: shadow * .37),
      5,
      false,
    );
    final near = Color.lerp(
      paper,
      dark ? Colors.black : const Color(0xFFC8C1B6),
      .65,
    )!;
    final crest = Color.lerp(paper, Colors.white, dark ? .14 : .72)!;
    final lip = Color.lerp(paper, Colors.black, dark ? .19 : .17)!;
    canvas.drawPath(
      folded,
      Paint()
        ..shader = ui.Gradient.linear(
          g.gradientPoint(0),
          g.gradientPoint(-backWidth),
          [near, crest, paper, lip],
          const [0, .24, .72, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PaperBack oldDelegate) =>
      oldDelegate.fold != fold || oldDelegate.paper != paper;
}
