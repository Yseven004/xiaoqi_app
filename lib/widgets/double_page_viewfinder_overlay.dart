import 'dart:ui';

import 'package:flutter/material.dart';

class DoublePageViewfinderOverlay extends StatelessWidget {
  const DoublePageViewfinderOverlay({
    super.key,
    this.isLandscape = false,
    this.contentTurns = 0,
    this.swapped = false,
    this.onSwap,
  });

  static const _motionDuration = Duration(milliseconds: 300);
  static const _markerExtent = 60.0;
  static const _nearDividerRatio = .335;
  static const _farDividerRatio = 1 - _nearDividerRatio;

  final bool isLandscape;
  final double contentTurns;
  final bool swapped;
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    final first = swapped ? '②' : '①';
    final second = swapped ? '①' : '②';

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final firstCenter = isLandscape
            ? Offset(size.width * _nearDividerRatio, size.height * .5)
            : Offset(size.width * .5, size.height * _nearDividerRatio);
        final secondCenter = isLandscape
            ? Offset(size.width * _farDividerRatio, size.height * .5)
            : Offset(size.width * .5, size.height * _farDividerRatio);

        return Stack(
          key: const Key('double_page_overlay'),
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            IgnorePointer(
              child: CustomPaint(
                key: const Key('double_page_divider'),
                painter: _GuideLinePainter(isLandscape: isLandscape),
              ),
            ),
            _AnimatedMarker(
              key: const ValueKey('double_page_marker_first'),
              center: firstCenter,
              extent: _markerExtent,
              label: first,
              turns: contentTurns,
            ),
            _AnimatedMarker(
              key: const ValueKey('double_page_marker_second'),
              center: secondCenter,
              extent: _markerExtent,
              label: second,
              turns: contentTurns,
            ),
            if (onSwap != null)
              Align(
                alignment: Alignment.center,
                child: Semantics(
                  button: true,
                  label: '交换①②分区',
                  child: SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: Material(
                        color: Colors.white,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const Key('double_page_swap_button'),
                          customBorder: const CircleBorder(),
                          onTap: onSwap,
                          child: SizedBox.square(
                            dimension: 32,
                            child: Icon(
                              isLandscape ? Icons.swap_horiz : Icons.swap_vert,
                              color: Colors.black,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AnimatedMarker extends StatelessWidget {
  const _AnimatedMarker({
    super.key,
    required this.center,
    required this.extent,
    required this.label,
    required this.turns,
  });

  final Offset center;
  final double extent;
  final String label;
  final double turns;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: DoublePageViewfinderOverlay._motionDuration,
      curve: Curves.easeOutCubic,
      left: center.dx - extent / 2,
      top: center.dy - extent / 2,
      width: extent,
      height: extent,
      child: IgnorePointer(
        child: Center(
          child: AnimatedRotation(
            turns: turns,
            duration: DoublePageViewfinderOverlay._motionDuration,
            curve: Curves.easeOutCubic,
            child: _PageMarker(label: label),
          ),
        ),
      ),
    );
  }
}

class _GuideLinePainter extends CustomPainter {
  const _GuideLinePainter({required this.isLandscape});

  static const _edgeInset = 18.0;
  static const _tickLength = 92.0;
  final bool isLandscape;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .64)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    if (isLandscape) {
      final x = size.width / 2;
      canvas.drawLine(
        Offset(x, _edgeInset),
        Offset(x, size.height - _edgeInset),
        paint,
      );
      canvas.drawLine(
        Offset(x - _tickLength / 2, _edgeInset),
        Offset(x + _tickLength / 2, _edgeInset),
        paint,
      );
      canvas.drawLine(
        Offset(x - _tickLength / 2, size.height - _edgeInset),
        Offset(x + _tickLength / 2, size.height - _edgeInset),
        paint,
      );
      return;
    }

    final y = size.height / 2;
    canvas.drawLine(
      Offset(_edgeInset, y),
      Offset(size.width - _edgeInset, y),
      paint,
    );
    canvas.drawLine(
      Offset(_edgeInset, y - _tickLength / 2),
      Offset(_edgeInset, y + _tickLength / 2),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - _edgeInset, y - _tickLength / 2),
      Offset(size.width - _edgeInset, y + _tickLength / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GuideLinePainter oldDelegate) =>
      oldDelegate.isLandscape != isLandscape;
}

class DoublePageGuide extends StatelessWidget {
  const DoublePageGuide({super.key, this.isLandscape = false});

  final bool isLandscape;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              key: const Key('double_page_guide'),
              constraints: const BoxConstraints(maxWidth: 360),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .56),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: .14),
                  width: 1,
                ),
              ),
              child: Text(
                isLandscape ? '书籍的左右两页分别对应①/②分区' : '书籍的上下两页分别对应①/②分区',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageMarker extends StatelessWidget {
  const _PageMarker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: const Color(0xFF5B5B5B).withValues(alpha: .72),
        fontSize: 56,
        height: 1,
        fontWeight: FontWeight.w700,
        shadows: const [Shadow(color: Color(0x33FFFFFF), blurRadius: 3)],
      ),
    );
  }
}
