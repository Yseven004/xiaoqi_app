import 'package:flutter/material.dart';

import '../models/page_annotation.dart';
import 'book_ink_path.dart';

/// Page or paragraph-local ink. The host owns drafts and commits them when the
/// drawing toolbar is closed, so virtualized PDF overlays may be rebuilt.
class CompanionInkSurface extends StatefulWidget {
  const CompanionInkSurface({
    super.key,
    required this.strokes,
    required this.enabled,
    required this.erasing,
    required this.color,
    required this.onChanged,
    this.onNavigate,
    this.onNavigationEnd,
  });

  final List<PageStroke> strokes;
  final bool enabled;
  final bool erasing;
  final Color color;
  final ValueChanged<List<PageStroke>> onChanged;
  final ValueChanged<ScaleUpdateDetails>? onNavigate;
  final ValueChanged<double>? onNavigationEnd;

  @override
  State<CompanionInkSurface> createState() => _CompanionInkSurfaceState();
}

class _CompanionInkSurfaceState extends State<CompanionInkSurface> {
  List<Offset> _points = [];
  bool _navigating = false;
  final _pointers = <int>{};
  double _scale = 1;

  Offset _normalize(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0, 1).toDouble(),
    (point.dy / size.height).clamp(0, 1).toDouble(),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
      final preview = _points.isEmpty || widget.erasing
          ? null
          : _stroke(_points);
      final ink = CustomPaint(
        painter: CompanionInkPainter(widget.strokes, preview),
        child: const SizedBox.expand(),
      );
      if (!widget.enabled) return IgnorePointer(child: ink);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (details) {
          _navigating = _navigating || details.pointerCount >= 2;
          setState(
            () => _points = _navigating
                ? []
                : [_normalize(details.localFocalPoint, size)],
          );
        },
        onScaleUpdate: (details) {
          if (details.pointerCount >= 2) {
            if (!_navigating) {
              setState(() {
                _navigating = true;
                _points = [];
              });
            }
            _scale = details.scale;
            widget.onNavigate?.call(details);
          } else if (!_navigating) {
            final point = _normalize(details.localFocalPoint, size);
            if (_points.lastOrNull != point) {
              setState(() => _points = [..._points, point]);
            }
          }
        },
        onScaleEnd: (_) {
          final points = _points;
          setState(() => _points = []);
          if (_navigating) {
            return;
          }
          if (points.isEmpty) return;
          if (widget.erasing) {
            final strokes = widget.strokes.where((stroke) {
              return !stroke.points.any(
                (point) => points.any((eraser) {
                  final dx = (point.dx - eraser.dx) * size.width;
                  final dy = (point.dy - eraser.dy) * size.height;
                  return dx * dx + dy * dy <= 18 * 18;
                }),
              );
            }).toList();
            if (strokes.length != widget.strokes.length) {
              widget.onChanged(strokes);
            }
          } else {
            widget.onChanged([...widget.strokes, _stroke(points)]);
          }
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointers.isEmpty) {
              _navigating = false;
              _scale = 1;
            }
            _pointers.add(event.pointer);
            if (_pointers.length > 1) {
              setState(() {
                _navigating = true;
                _points = [];
              });
            }
          },
          onPointerUp: (event) {
            _pointers.remove(event.pointer);
            if (_pointers.isEmpty && _navigating) {
              widget.onNavigationEnd?.call(_scale);
            }
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            setState(() {
              _navigating = true;
              _points = [];
            });
          },
          child: ink,
        ),
      );
    },
  );

  PageStroke _stroke(List<Offset> points) => PageStroke(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    tool: StrokeTool.ballpoint,
    colorValue: widget.color.toARGB32(),
    width: 3,
    opacity: 1,
    points: points,
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
