import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/emotion_type.dart';

// 小七表情人脸绘制工具
//
// 提供所有8种眼睛和8种嘴巴的底层绘制方法。
// 基于60×60规范坐标，眼睛半径5px、描边3px，确保在米灰外壳上清晰可见。

/// 静态人脸绘制工具类
class EmotionFacePainter {
  EmotionFacePainter._();

  // ==================== 眼睛绘制 ====================

  static void drawEyes(Canvas canvas, EyeType eyeType, double lx, double rx, double y, double scale) {
    switch (eyeType) {
      case EyeType.crescent:
        _drawCrescent(canvas, lx, rx, y, scale);
      case EyeType.dots:
        _drawDots(canvas, lx, rx, y, scale);
      case EyeType.asymmetric:
        _drawAsymmetric(canvas, lx, rx, y, scale);
      case EyeType.horizontalLine:
        _drawHorizontalLine(canvas, lx, rx, y, scale);
      case EyeType.droopy:
        _drawDroopy(canvas, lx, rx, y, scale);
      case EyeType.largeWithHighlight:
        _drawLarge(canvas, lx, rx, y, scale);
      case EyeType.furrowed:
        _drawFurrowed(canvas, lx, rx, y, scale);
      case EyeType.tearShine:
        _drawTearShine(canvas, lx, rx, y, scale);
    }
  }

  // --- 通用 paint 工厂 ---

  static Paint _strokePaint(double scale) => Paint()
    ..color = AppColors.textPrimary
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.0 * scale
    ..strokeCap = StrokeCap.round;

  static Paint _fillPaint() => Paint()
    ..color = AppColors.textPrimary
    ..style = PaintingStyle.fill;

  // --- E1 月牙眼：向上弯曲的粗弧线 ---
  static void _drawCrescent(Canvas c, double lx, double rx, double y, double s) {
    final p = _strokePaint(s);
    final r = 6.0 * s;
    c.drawArc(Rect.fromCircle(center: Offset(lx, y), radius: r), math.pi * 1.15, math.pi * 0.85, false, p);
    c.drawArc(Rect.fromCircle(center: Offset(rx, y), radius: r), math.pi * 1.15, math.pi * 0.85, false, p);
  }

  // --- E2 圆点眼：大实心圆 ---
  static void _drawDots(Canvas c, double lx, double rx, double y, double s) {
    final p = _fillPaint();
    c.drawCircle(Offset(lx, y), 5.0 * s, p);
    c.drawCircle(Offset(rx, y), 5.0 * s, p);
  }

  // --- E3 不对称眼睛：左大右小 ---
  static void _drawAsymmetric(Canvas c, double lx, double rx, double y, double s) {
    final p = _fillPaint();
    c.drawCircle(Offset(lx, y), 5.0 * s, p);
    c.drawCircle(Offset(rx, y - 2.0 * s), 3.5 * s, p);
  }

  // --- E4 横线眼：粗短线 ---
  static void _drawHorizontalLine(Canvas c, double lx, double rx, double y, double s) {
    final p = _strokePaint(s);
    final hw = 5.0 * s;
    c.drawLine(Offset(lx - hw, y), Offset(lx + hw, y), p);
    c.drawLine(Offset(rx - hw, y), Offset(rx + hw, y), p);
  }

  // --- E5 下垂眼：向外下方倾斜的粗线 ---
  static void _drawDroopy(Canvas c, double lx, double rx, double y, double s) {
    final p = _strokePaint(s);
    final len = 5.0 * s;
    final dy = 3.0 * s;
    c.drawLine(Offset(lx - len, y - dy), Offset(lx + len, y + dy), p);
    c.drawLine(Offset(rx - len, y + dy), Offset(rx + len, y - dy), p);
  }

  // --- E6 放大圆眼+高光 ---
  static void _drawLarge(Canvas c, double lx, double rx, double y, double s) {
    final ep = _fillPaint();
    c.drawCircle(Offset(lx, y), 6.0 * s, ep);
    c.drawCircle(Offset(rx, y), 6.0 * s, ep);
    final hp = Paint()..color = AppColors.onAccent..style = PaintingStyle.fill;
    c.drawCircle(Offset(lx + 2.0 * s, y - 2.0 * s), 2.5 * s, hp);
    c.drawCircle(Offset(rx + 2.0 * s, y - 2.0 * s), 2.5 * s, hp);
  }

  // --- E7 皱眉眼：粗眉线下压 + 大圆点 ---
  static void _drawFurrowed(Canvas c, double lx, double rx, double y, double s) {
    final ep = _fillPaint();
    c.drawCircle(Offset(lx, y), 5.0 * s, ep);
    c.drawCircle(Offset(rx, y), 5.0 * s, ep);
    final bp = _strokePaint(s);
    final bl = 6.0 * s;
    final by = y - 6.0 * s;
    c.drawLine(Offset(lx - bl, by - s), Offset(lx + bl, by + s), bp);
    c.drawLine(Offset(rx - bl, by + s), Offset(rx + bl, by - s), bp);
  }

  // --- E8 泪光眼：大圆点 + 高光 + 泪滴 ---
  static void _drawTearShine(Canvas c, double lx, double rx, double y, double s) {
    final ep = _fillPaint();
    c.drawCircle(Offset(lx, y), 5.0 * s, ep);
    c.drawCircle(Offset(rx, y), 5.0 * s, ep);
    final hp = Paint()..color = AppColors.onAccent..style = PaintingStyle.fill;
    c.drawCircle(Offset(lx + 1.5 * s, y - 1.5 * s), 2.0 * s, hp);
    c.drawCircle(Offset(rx + 1.5 * s, y - 1.5 * s), 2.0 * s, hp);
    final tp = Paint()
      ..color = AppColors.accent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.round;
    c.drawArc(Rect.fromCircle(center: Offset(lx + 2.5 * s, y + 3.0 * s), radius: 3.0 * s), math.pi * 0.5, math.pi * 0.6, false, tp);
    c.drawArc(Rect.fromCircle(center: Offset(rx + 2.5 * s, y + 3.0 * s), radius: 3.0 * s), math.pi * 0.5, math.pi * 0.6, false, tp);
  }

  // ==================== 嘴巴绘制 ====================

  static void drawMouth(Canvas canvas, MouthType mouthType, double x, double y, double scale) {
    switch (mouthType) {
      case MouthType.upturned:
        _drawUpturned(canvas, x, y, scale);
      case MouthType.slightUpturn:
        _drawSlightUpturn(canvas, x, y, scale);
      case MouthType.flat:
        _drawFlat(canvas, x, y, scale);
      case MouthType.circle:
        _drawMouthCircle(canvas, x, y, scale);
      case MouthType.downward:
        _drawDownward(canvas, x, y, scale);
      case MouthType.bigMouth:
        _drawBigMouth(canvas, x, y, scale);
      case MouthType.wavy:
        _drawWavy(canvas, x, y, scale);
      case MouthType.smile:
        _drawSmile(canvas, x, y, scale);
    }
  }

  // --- 上扬嘴巴（E1/E2）：U形，控制点在下方→两端上扬 ---
  static void _drawUpturned(Canvas c, double x, double y, double s) {
    final p = Path();
    final w = 7.0 * s;
    final h = 5.0 * s;
    p.moveTo(x - w, y - h * 0.6);
    p.quadraticBezierTo(x, y + h * 0.4, x + w, y - h * 0.6);
    c.drawPath(p, _strokePaint(s));
  }

  // --- E2 微上扬嘴巴：浅U形 ---
  static void _drawSlightUpturn(Canvas c, double x, double y, double s) {
    final p = Path();
    final w = 6.0 * s;
    final h = 3.5 * s;
    p.moveTo(x - w, y - h * 0.5);
    p.quadraticBezierTo(x, y + h * 0.5, x + w, y - h * 0.5);
    c.drawPath(p, _strokePaint(s));
  }

  // --- E3 抿嘴：粗水平线 ---
  static void _drawFlat(Canvas c, double x, double y, double s) {
    final hw = 6.0 * s;
    c.drawLine(Offset(x - hw, y), Offset(x + hw, y), _strokePaint(s));
  }

  // --- E4 圆形嘴巴（O嘴）---
  static void _drawMouthCircle(Canvas c, double x, double y, double s) {
    c.drawCircle(Offset(x, y), 4.5 * s, _fillPaint());
  }

  // --- E5 下弯嘴巴：∩形，控制点在上方→两端下垂 ---
  static void _drawDownward(Canvas c, double x, double y, double s) {
    final p = Path();
    final w = 7.0 * s;
    final h = 5.0 * s;
    p.moveTo(x - w, y + h * 0.6);
    p.quadraticBezierTo(x, y - h * 0.4, x + w, y + h * 0.6);
    c.drawPath(p, _strokePaint(s));
  }

  // --- E6 大嘴巴：宽大U形上扬 ---
  static void _drawBigMouth(Canvas c, double x, double y, double s) {
    final p = Path();
    final w = 8.0 * s;
    final h = 6.0 * s;
    p.moveTo(x - w, y - h * 0.6);
    p.quadraticBezierTo(x, y + h * 0.4, x + w, y - h * 0.6);
    c.drawPath(p, _strokePaint(s));
  }

  // --- E7 波浪嘴 ---
  static void _drawWavy(Canvas c, double x, double y, double s) {
    final p = Paint()
      ..color = AppColors.textPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final w = 6.0 * s;
    final h = 3.0 * s;
    path.moveTo(x - w - s, y);
    path.lineTo(x - w * 0.5, y + h);
    path.lineTo(x, y);
    path.lineTo(x + w * 0.5, y + h);
    path.lineTo(x + w + s, y);
    c.drawPath(path, p);
  }

  // --- E8 微笑：柔和U形上扬 ---
  static void _drawSmile(Canvas c, double x, double y, double s) {
    final p = Path();
    final w = 6.5 * s;
    final h = 4.0 * s;
    p.moveTo(x - w, y - h * 0.5);
    p.quadraticBezierTo(x, y + h * 0.5, x + w, y - h * 0.5);
    c.drawPath(p, _strokePaint(s));
  }
}
