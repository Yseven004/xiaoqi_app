import 'package:flutter/material.dart';

import '../models/page_annotation.dart';
import 'book_ink_path.dart';

/// Two fingers navigate the document while the drawing plugin handles one pen
/// or finger in its own coordinate space.
class CompanionInkNavigation extends StatefulWidget {
  const CompanionInkNavigation({
    super.key,
    required this.child,
    required this.onNavigate,
    required this.onNavigationEnd,
  });
  final Widget child;
  final ValueChanged<ScaleUpdateDetails> onNavigate;
  final ValueChanged<double> onNavigationEnd;
  @override
  State<CompanionInkNavigation> createState() => _CompanionInkNavigationState();
}

class _CompanionInkNavigationState extends State<CompanionInkNavigation> {
  final _positions = <int, Offset>{};
  double _initialDistance = 0;
  double _scale = 1;
  Offset _center = Offset.zero;

  void _down(PointerDownEvent event) {
    _positions[event.pointer] = event.position;
    if (_positions.length != 2) return;
    final pair = _positions.values.toList();
    _center = (pair[0] + pair[1]) / 2;
    _initialDistance = (pair[0] - pair[1]).distance;
    _scale = 1;
  }

  void _move(PointerMoveEvent event) {
    if (!_positions.containsKey(event.pointer)) return;
    _positions[event.pointer] = event.position;
    if (_positions.length != 2 || _initialDistance <= 0) return;
    final pair = _positions.values.toList();
    final center = (pair[0] + pair[1]) / 2;
    _scale = (pair[0] - pair[1]).distance / _initialDistance;
    widget.onNavigate(
      ScaleUpdateDetails(
        focalPoint: center,
        focalPointDelta: center - _center,
        scale: _scale,
        pointerCount: 2,
      ),
    );
    _center = center;
  }

  void _end(PointerEvent event) {
    _positions.remove(event.pointer);
    if (_positions.length >= 2 || _initialDistance <= 0) return;
    _initialDistance = 0;
    widget.onNavigationEnd(_scale);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _end,
    onPointerCancel: _end,
    child: widget.child,
  );
}

class CompanionInkPainter extends CustomPainter {
  const CompanionInkPainter(this.strokes, [this.preview]);

  final List<PageStroke> strokes;
  final PageStroke? preview;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in [...strokes, ?preview]) {
      if (stroke.points.isEmpty) continue;
      final brush = Paint()
        ..color = Color(stroke.colorValue).withValues(alpha: stroke.opacity)
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final first = stroke.points.first;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(first.dx * size.width, first.dy * size.height),
          stroke.width / 2,
          brush..style = PaintingStyle.fill,
        );
        continue;
      }
      canvas.drawPath(
        smoothInkPath(
          stroke.points
              .map(
                (point) =>
                    Offset(point.dx * size.width, point.dy * size.height),
              )
              .toList(),
        ),
        brush,
      );
    }
  }

  @override
  bool shouldRepaint(CompanionInkPainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.preview != preview;
}
