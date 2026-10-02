import 'package:flutter/material.dart';

import '../config/colors.dart';

class CameraLevelIndicator extends StatelessWidget {
  const CameraLevelIndicator({super.key, required this.tilt});

  /// Normalized device tilt on each axis, constrained to [-1, 1].
  final Offset tilt;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        key: const Key('camera_level_indicator'),
        size: const Size.square(44),
        painter: _CameraLevelPainter(tilt),
      ),
    );
  }
}

class _CameraLevelPainter extends CustomPainter {
  _CameraLevelPainter(this.tilt);

  final Offset tilt;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    final level = tilt.distance <= 0.18;
    final color = level ? AppColors.scanTrack : Colors.white70;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black38
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
    canvas.drawLine(
      Offset(center.dx - 6, center.dy),
      Offset(center.dx + 6, center.dy),
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 6),
      Offset(center.dx, center.dy + 6),
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..strokeWidth = 1,
    );
    final dot = Offset(
      center.dx + tilt.dx.clamp(-1.0, 1.0) * (radius - 7),
      center.dy + tilt.dy.clamp(-1.0, 1.0) * (radius - 7),
    );
    canvas.drawCircle(dot, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CameraLevelPainter oldDelegate) =>
      oldDelegate.tilt != tilt;
}
