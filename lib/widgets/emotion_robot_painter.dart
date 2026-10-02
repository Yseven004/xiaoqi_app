import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/emotion_type.dart';
import 'emotion_robot_face.dart';

// 小七表情机器人 CustomPainter
//
// 负责外壳、光晕绘制，动画变换，以及分派眼睛/嘴巴绘制。

class EmotionRobotPainter extends CustomPainter {
  final EmotionType emotionType;
  final double animationValue;
  final double opacity;
  final double blinkProgress; // 0=睁眼 1=闭眼
  final double eyeOffsetX;    // 瞳孔水平偏移（-1~1，规范坐标）

  EmotionRobotPainter({
    required this.emotionType,
    required this.animationValue,
    required this.opacity,
    this.blinkProgress = 0.0,
    this.eyeOffsetX = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.0) return;

    final scale = size.width / 60.0;
    final config = emotionType.animationConfig;
    final center = Offset(30.0 * scale, 30.0 * scale);
    final shellRadius = 28.0 * scale;

    canvas.save();
    canvas.translate(center.dx, center.dy);

    // 基础动画变换
    _applyAnimation(canvas, config, scale);

    // 透明度（含呼吸效果）
    final effectiveOpacity = _effectiveOpacity();
    final layerPaint = Paint()..color = Colors.white.withValues(alpha: effectiveOpacity);
    canvas.saveLayer(
      Rect.fromCircle(center: Offset.zero, radius: shellRadius + 8 * scale),
      layerPaint,
    );

    // 光晕（E8）
    _drawGlow(canvas, scale);
    // 外壳
    _drawShell(canvas, shellRadius);

    if (effectiveOpacity > 0.05) {
      // 眼睛：相对中心，带眼球偏移
      final eyeY = -7.0 * scale;
      final offsetX = eyeOffsetX * 2.0 * scale;
      final leftX = -8.0 * scale + offsetX;
      final rightX = 8.0 * scale + offsetX;
      EmotionFacePainter.drawEyes(canvas, emotionType.eyeType, leftX, rightX, eyeY, scale);

      // 眨眼：在眼睛上画闭合线
      if (blinkProgress > 0.0) {
        _drawBlink(canvas, leftX, rightX, eyeY, scale);
      }

      // 嘴巴：相对中心 (0, 8)
      EmotionFacePainter.drawMouth(canvas, emotionType.mouthType, 0.0, 8.0 * scale, scale);
    }

    canvas.restore(); // layer
    canvas.restore(); // initial
  }

  // ---- 动画变换 ----

  void _applyAnimation(Canvas canvas, AnimationConfig config, double scale) {
    final t = animationValue;
    final twoPi = 2.0 * math.pi;
    final sinVal = math.sin(t * twoPi);

    switch (config.type) {
      case BaseAnimationType.shake:
      case BaseAnimationType.sway:
      case BaseAnimationType.fastShake:
        canvas.rotate(config.amplitude * math.pi / 180.0 * sinVal);
      case BaseAnimationType.float:
        canvas.translate(0, config.amplitude * scale * sinVal);
      case BaseAnimationType.tremble:
        canvas.translate(config.amplitude * scale * math.sin(t * 5.0 * twoPi), 0);
      case BaseAnimationType.jump:
        _applyJump(canvas, config, scale, t, twoPi);
      case BaseAnimationType.scale:
        canvas.scale(1.0 + config.amplitude * (sinVal * 0.5 + 0.5), 1.0 + config.amplitude * (sinVal * 0.5 + 0.5));
      case BaseAnimationType.breathe:
        break; // 透明度处理
    }
  }

  void _applyJump(Canvas canvas, AnimationConfig config, double scale, double t, double twoPi) {
    final progress = (t * twoPi) % twoPi;
    if (progress < math.pi) {
      final up = progress / math.pi;
      canvas.translate(0, -config.amplitude * scale * math.sin(up * math.pi / 2));
    } else {
      final down = (progress - math.pi) / math.pi;
      canvas.translate(0, config.amplitude * scale * 0.3 * math.exp(-3.0 * down) * math.sin(down * math.pi * 3));
    }
  }

  // ---- 透明度 ----

  double _effectiveOpacity() {
    if (emotionType.animationConfig.type == BaseAnimationType.breathe) {
      final b = 0.85 + 0.15 * (math.sin(animationValue * 2.0 * math.pi) * 0.5 + 0.5);
      return opacity * b;
    }
    return opacity;
  }

  // ---- 光晕 ----

  void _drawGlow(Canvas canvas, double scale) {
    if (emotionType != EmotionType.e8Touched) return;
    final g = 0.15 + 0.15 * (math.sin(animationValue * 2.0 * math.pi) * 0.5 + 0.5);
    canvas.drawCircle(
      Offset.zero,
      30.0 * scale,
      Paint()
        ..color = AppColors.accent.withValues(alpha: g)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0),
    );
  }

  // ---- 眨眼 ----

  void _drawBlink(Canvas canvas, double lx, double rx, double y, double scale) {
    // 眨眼：画粗线模拟眼睑闭合，比眼睛宽
    final lidPaint = Paint()
      ..color = AppColors.robotShell
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.0 * scale * blinkProgress
      ..strokeCap = StrokeCap.round;
    final halfW = 6.0 * scale;
    canvas.drawLine(Offset(lx - halfW, y), Offset(lx + halfW, y), lidPaint);
    canvas.drawLine(Offset(rx - halfW, y), Offset(rx + halfW, y), lidPaint);
  }

  // ---- 外壳 ----

  void _drawShell(Canvas canvas, double r) {
    canvas.drawCircle(Offset.zero, r, Paint()..color = AppColors.robotShell..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant EmotionRobotPainter old) {
    return old.emotionType != emotionType ||
        old.animationValue != animationValue ||
        old.opacity != opacity ||
        old.blinkProgress != blinkProgress ||
        old.eyeOffsetX != eyeOffsetX;
  }
}
