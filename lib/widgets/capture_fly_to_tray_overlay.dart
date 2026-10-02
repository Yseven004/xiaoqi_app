import 'dart:io';

import 'package:flutter/material.dart';

/// Fallback end rect when tray not laid out yet (first capture).
/// [barBottomRight] = bottom bar trailing area global bottom-right-ish point.
Rect estimateStagingThumbEndRect(Size screen, EdgeInsets padding) {
  const thumb = 52.0;
  const gap = 6.0;
  const completeH = 25.0; // 6+6 padding + ~13 text in 「完成」 pill
  const barH = 88.0;
  const padR = 16.0;
  const padB = 14.0;
  // Tray column (thumb + gap + complete) is vertically centered in the 88px bar.
  final barBottom = screen.height - padding.bottom - padB;
  final columnH = thumb + gap + completeH;
  final thumbBottom = barBottom - (barH - columnH) / 2 - gap - completeH;
  final right = screen.width - padding.right - padR;
  return Rect.fromLTWH(right - thumb, thumbBottom - thumb, thumb, thumb);
}

/// Quark-style flash → hold → fly-to-tray overlay (420ms timeline).
class CaptureFlyToTrayOverlay extends StatelessWidget {
  const CaptureFlyToTrayOverlay({
    super.key,
    required this.path,
    required this.animation,
    required this.startRect,
    required this.endRect,
    this.startRadius = 12,
    this.endRadius = 8,
  });

  static const double flashEnd = 80 / 420;
  static const double holdEnd = 140 / 420;

  final String path;
  final Animation<double> animation;
  final Rect startRect;
  final Rect endRect;
  final double startRadius;
  final double endRadius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      key: const Key('capture_fly_overlay'),
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value.clamp(0.0, 1.0);
          final flash = _flashOpacity(t);
          final flyT = t <= holdEnd
              ? 0.0
              : Curves.easeInOutCubic.transform(
                  ((t - holdEnd) / (1 - holdEnd)).clamp(0.0, 1.0),
                );
          final rect = Rect.lerp(startRect, endRect, flyT)!;
          final radius = uiLerp(startRadius, endRadius, flyT);

          return Stack(
            fit: StackFit.expand,
            children: [
              if (flash > 0)
                Positioned.fromRect(
                  rect: startRect,
                  child: ColoredBox(color: Colors.white.withValues(alpha: flash)),
                ),
              Positioned.fromRect(
                rect: rect,
                child: RepaintBoundary(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: Color(0xFF333333)),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static double _flashOpacity(double t) {
    if (t >= flashEnd) return 0;
    final p = t / flashEnd;
    // Peak mid-flash then ease out.
    return p < 0.5 ? p * 2 * 0.85 : (1 - p) * 2 * 0.85;
  }
}

double uiLerp(double a, double b, double t) => a + (b - a) * t;
