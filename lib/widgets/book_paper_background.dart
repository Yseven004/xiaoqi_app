import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';

/// Warm paper surface used by the approved book-learning visual direction.
/// Editorial detail pages use a generated paper/light bitmap so the grain and
/// botanical shadow stay natural instead of looking like repeated vector marks.
class BookPaperBackground extends StatelessWidget {
  const BookPaperBackground({
    super.key,
    required this.child,
    this.showTexture = true,
    this.showBotanicalShadow = false,
    this.warmEditorial = false,
  });

  final Widget child;
  final bool showTexture;
  final bool showBotanicalShadow;
  final bool warmEditorial;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: warmEditorial ? null : BookFlowTheme.canvas,
      gradient: warmEditorial
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF3EAD9), Color(0xFFFAF6EC), Color(0xFFF7F0E3)],
              stops: [0, .48, 1],
            )
          : null,
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (warmEditorial)
          Positioned.fill(
            child: Image.asset(
              'assets/images/book_detail_background.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) =>
                  const CustomPaint(painter: _EditorialLightPainter()),
            ),
          ),
        if (warmEditorial)
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x08FFFFFF),
                      Color(0x12FFFFFF),
                      Color(0x07FFFFFF),
                      Color(0x0DFFFFFF),
                    ],
                    stops: [0, .26, .62, 1],
                  ),
                ),
              ),
            ),
          ),
        if (showTexture && !warmEditorial)
          const IgnorePointer(child: CustomPaint(painter: _PaperPainter())),
        if (showBotanicalShadow && !warmEditorial)
          const Positioned(
            right: -12,
            top: 24,
            width: 242,
            height: 276,
            child: IgnorePointer(
              child: CustomPaint(painter: _BotanicalShadowPainter()),
            ),
          ),
        child,
      ],
    ),
  );
}

/// Builds the uneven light of a sunlit reading desk: a soft edge vignette,
/// one broad window beam, and a few blown-out highlights between the leaves.
class _EditorialLightPainter extends CustomPainter {
  const _EditorialLightPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final vignette = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-.08, -.46),
        radius: 1.08,
        colors: [Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0x176F593D)],
        stops: [0, .66, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);

    final beam = Path()
      ..moveTo(size.width * .70, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * .36)
      ..lineTo(size.width * .50, size.height * .17)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..color = const Color(0x24FFFDF5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );

    final flare = Paint()
      ..color = const Color(0x34FFFFFF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .88, size.height * .09),
        width: size.width * .25,
        height: size.width * .12,
      ),
      flare,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .72, size.height * .18),
        width: size.width * .19,
        height: size.width * .09,
      ),
      flare,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorialLightPainter oldDelegate) => false;
}

class _PaperPainter extends CustomPainter {
  const _PaperPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final fiber = Paint()
      ..color = const Color(0x0D8D7453)
      ..strokeWidth = .42
      ..strokeCap = StrokeCap.round;
    final fleck = Paint()..color = const Color(0x0A675440);
    for (var row = 0; row < size.height ~/ 36 + 1; row++) {
      for (var col = 0; col < size.width ~/ 42 + 1; col++) {
        final seed = row * 31 + col * 17;
        final x = col * 42.0 + (seed % 19);
        final y = row * 36.0 + (seed % 13);
        final length = 2.0 + seed % 5;
        canvas.drawLine(Offset(x, y), Offset(x + length, y + .5), fiber);
        if (seed % 3 == 0) canvas.drawCircle(Offset(x + 13, y + 9), .55, fleck);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPainter oldDelegate) => false;
}

class _BotanicalShadowPainter extends CustomPainter {
  const _BotanicalShadowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    _drawPlant(
      canvas,
      size,
      color: const Color(0x22605843),
      blur: 18,
      offset: const Offset(-3, 5),
      branchWidth: 7,
    );
    _drawPlant(
      canvas,
      size,
      color: const Color(0x2B554F3E),
      blur: 6,
      offset: const Offset(0, 1),
      branchWidth: 3.2,
    );
  }

  void _drawPlant(
    Canvas canvas,
    Size size, {
    required Color color,
    required double blur,
    required Offset offset,
    required double branchWidth,
  }) {
    final paint = Paint()
      ..color = color
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = branchWidth;
    final branch = Path()
      ..moveTo(size.width * 1.04, -8)
      ..cubicTo(
        size.width * .93,
        size.height * .20,
        size.width * .75,
        size.height * .43,
        size.width * .42,
        size.height * .92,
      );
    canvas.drawPath(branch, paint);

    final twigA = Path()
      ..moveTo(size.width * .86, size.height * .27)
      ..quadraticBezierTo(
        size.width * .66,
        size.height * .23,
        size.width * .52,
        size.height * .12,
      );
    final twigB = Path()
      ..moveTo(size.width * .70, size.height * .52)
      ..quadraticBezierTo(
        size.width * .88,
        size.height * .49,
        size.width * .98,
        size.height * .38,
      );
    canvas.drawPath(twigA, paint..strokeWidth = branchWidth * .55);
    canvas.drawPath(twigB, paint);

    paint.style = PaintingStyle.fill;
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .82, size.height * .10),
      74,
      25,
      -.42,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .62, size.height * .16),
      68,
      23,
      -.12,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .91, size.height * .22),
      76,
      25,
      .45,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .68, size.height * .32),
      82,
      27,
      -.56,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .91, size.height * .42),
      72,
      24,
      .36,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .56, size.height * .51),
      77,
      25,
      -.48,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .74, size.height * .62),
      71,
      23,
      .40,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .42, size.height * .72),
      70,
      23,
      -.45,
    );
    _drawLeaf(
      canvas,
      paint,
      Offset(size.width * .58, size.height * .82),
      62,
      21,
      .38,
    );
    canvas.restore();
  }

  void _drawLeaf(
    Canvas canvas,
    Paint paint,
    Offset center,
    double width,
    double height,
    double angle,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final leaf = Path()
      ..moveTo(-width * .5, 0)
      ..quadraticBezierTo(0, -height * .72, width * .5, 0)
      ..quadraticBezierTo(0, height * .72, -width * .5, 0)
      ..close();
    canvas.drawPath(leaf, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BotanicalShadowPainter oldDelegate) => false;
}
