import 'dart:ui';

Path smoothInkPath(List<Offset> points) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  if (points.length == 1) return path;
  if (points.length == 2) {
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  // Pointer samples can be sparse when the UI thread is busy. Connecting
  // those samples with lineTo makes the renderer invent visibly straight
  // chords through a curved hand movement. Catmull-Rom controls preserve
  // every sample while keeping the tangent continuous through the curve.
  for (var index = 0; index < points.length - 1; index++) {
    final before = index == 0 ? points[index] : points[index - 1];
    final start = points[index];
    final end = points[index + 1];
    final after = index + 2 < points.length ? points[index + 2] : end;
    final firstControl = Offset(
      start.dx + (end.dx - before.dx) / 6,
      start.dy + (end.dy - before.dy) / 6,
    );
    final secondControl = Offset(
      end.dx - (after.dx - start.dx) / 6,
      end.dy - (after.dy - start.dy) / 6,
    );
    path.cubicTo(
      firstControl.dx,
      firstControl.dy,
      secondControl.dx,
      secondControl.dy,
      end.dx,
      end.dy,
    );
  }
  return path;
}
