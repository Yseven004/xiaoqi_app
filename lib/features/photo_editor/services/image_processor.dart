import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';
import 'package:image/image.dart' as img;
import '../models/editor_action.dart';

/// 图片处理工具 —— 裁剪 + 旋转 + 标注导出
class ImageProcessor {
  /// 根据裁剪矩形（画布内容空间坐标）和旋转角度处理图片
  ///
  /// 重活（解码/裁剪/旋转/编码）在后台 isolate 执行，不阻塞 UI。
  /// 返回裁剪后的文件路径和图片尺寸。
  static Future<CropResult> applyCropAndRotation({
    required String imagePath,
    required Rect cropRect,
    required Size canvasSize,
    required Size originalImageSize,
    required double rotationAngle,
  }) async {
    // --- 坐标映射（主 isolate，纯数学，不读文件）---
    final canvasAspect = canvasSize.width / canvasSize.height;
    final imgAspect = originalImageSize.width / originalImageSize.height;

    double displayW, displayH, offsetX = 0, offsetY = 0;
    if (imgAspect > canvasAspect) {
      displayW = canvasSize.width;
      displayH = canvasSize.width / imgAspect;
      offsetY = (canvasSize.height - displayH) / 2;
    } else {
      displayH = canvasSize.height;
      displayW = canvasSize.height * imgAspect;
      offsetX = (canvasSize.width - displayW) / 2;
    }

    final scaleX = originalImageSize.width / displayW;
    final scaleY = originalImageSize.height / displayH;

    final pixelX =
        ((cropRect.left - offsetX) * scaleX).round().clamp(0, 999999);
    final pixelY =
        ((cropRect.top - offsetY) * scaleY).round().clamp(0, 999999);
    final pixelW = (cropRect.width * scaleX).round().clamp(1, 999999);
    final pixelH = (cropRect.height * scaleY).round().clamp(1, 999999);

    final needsRotation =
        (rotationAngle % (2 * math.pi)).abs() > 0.001;
    final rotationDegrees = needsRotation
        ? -(rotationAngle * 180 / math.pi)
        : 0.0;

    // --- 重活在后台 isolate 执行 ---
    final params = _CropWorkParams(
      imagePath: imagePath,
      pixelX: pixelX,
      pixelY: pixelY,
      pixelW: pixelW,
      pixelH: pixelH,
      needsRotation: needsRotation,
      rotationDegrees: rotationDegrees,
    );

    final result = await Isolate.run(() => _cropWork(params));
    return result;
  }

  /// 将标注（画笔、橡皮擦、马赛克）绘制到图片上并保存为新文件
  static Future<String> applyAnnotations({
    required String imagePath,
    required List<EditorAction> actions,
    required Size canvasSize,
    required Size originalImageSize,
  }) async {
    if (actions.isEmpty || canvasSize == Size.zero) return imagePath;

    final file = File(imagePath);
    final bytes = await file.readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) return imagePath;

    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    final displayRect = _computeDisplayRect(canvasSize, originalImageSize);
    final strokeWidthScale = originalImageSize.width / displayRect.width;

    for (final action in actions) {
      if (action is PenAction) {
        _drawPenOnImage(image, action, imgW, imgH, strokeWidthScale);
      } else if (action is EraserAction) {
        _drawEraserOnImage(image, action, imgW, imgH, strokeWidthScale);
      } else if (action is MosaicAction) {
        _drawMosaicOnImage(image, action, imgW, imgH, strokeWidthScale);
      }
    }

    final ext = imagePath.endsWith('.png') ? '.png' : '.jpg';
    final newPath = imagePath.replaceAll(
      RegExp(r'\.[^.]+$'),
      '_edited_${DateTime.now().millisecondsSinceEpoch}$ext',
    );

    final outputBytes = ext == '.png'
        ? img.encodePng(image)
        : img.encodeJpg(image, quality: 95);
    await File(newPath).writeAsBytes(outputBytes);

    return newPath;
  }

  /// 计算 BoxFit.contain 下图片在画布中的显示区域
  static Rect _computeDisplayRect(Size canvasSize, Size imageSize) {
    final canvasAspect = canvasSize.width / canvasSize.height;
    final imgAspect = imageSize.width / imageSize.height;
    if (imgAspect > canvasAspect) {
      final h = canvasSize.width / imgAspect;
      final top = (canvasSize.height - h) / 2;
      return Rect.fromLTWH(0, top, canvasSize.width, h);
    } else {
      final w = canvasSize.height * imgAspect;
      final left = (canvasSize.width - w) / 2;
      return Rect.fromLTWH(left, 0, w, canvasSize.height);
    }
  }

  static void _drawPenOnImage(
    img.Image image, PenAction action,
    double imgW, double imgH, double strokeWidthScale,
  ) {
    if (action.points.isEmpty) return;
    final color = img.ColorRgb8(
      (action.color.r * 255).round().clamp(0, 255),
      (action.color.g * 255).round().clamp(0, 255),
      (action.color.b * 255).round().clamp(0, 255),
    );
    final strokeWidth = (action.strokeWidth * strokeWidthScale).round().clamp(1, 200);
    for (int i = 0; i < action.points.length - 1; i++) {
      final p1 = action.points[i];
      final p2 = action.points[i + 1];
      img.drawLine(image,
          x1: (p1.dx * imgW).toInt(), y1: (p1.dy * imgH).toInt(),
          x2: (p2.dx * imgW).toInt(), y2: (p2.dy * imgH).toInt(),
          color: color, thickness: strokeWidth);
    }
    final radius = (strokeWidth / 2).round().clamp(1, 50);
    for (final point in action.points) {
      img.fillCircle(image,
          x: (point.dx * imgW).toInt(), y: (point.dy * imgH).toInt(),
          radius: radius, color: color);
    }
  }

  static void _drawEraserOnImage(
    img.Image image, EraserAction action,
    double imgW, double imgH, double strokeWidthScale,
  ) {
    if (action.points.isEmpty) return;
    final strokeWidth = (action.strokeWidth * strokeWidthScale).round().clamp(1, 200);
    final radius = (strokeWidth / 2).round().clamp(1, 100);
    for (final point in action.points) {
      final cx = (point.dx * imgW).toInt();
      final cy = (point.dy * imgH).toInt();
      for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
          if (dx * dx + dy * dy > radius * radius) continue;
          final px = cx + dx;
          final py = cy + dy;
          if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
            // JPG 无透明通道，原图已存在，无需额外操作
          }
        }
      }
    }
  }

  static void _drawMosaicOnImage(
    img.Image image, MosaicAction action,
    double imgW, double imgH, double strokeWidthScale,
  ) {
    if (action.points.isEmpty) return;
    final pixelBlockSize = (action.blockSize * strokeWidthScale).round().clamp(4, 200);
    final affectedPixels = <Offset>{};
    for (final point in action.points) {
      final cx = (point.dx * imgW).toInt();
      final cy = (point.dy * imgH).toInt();
      final half = pixelBlockSize ~/ 2;
      for (int dy = -half; dy <= half; dy++) {
        for (int dx = -half; dx <= half; dx++) {
          final px = cx + dx;
          final py = cy + dy;
          if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
            affectedPixels.add(Offset(px.toDouble(), py.toDouble()));
          }
        }
      }
    }
    if (affectedPixels.isEmpty) return;
    var minX = image.width, maxX = 0, minY = image.height, maxY = 0;
    for (final p in affectedPixels) {
      if (p.dx.toInt() < minX) minX = p.dx.toInt();
      if (p.dx.toInt() > maxX) maxX = p.dx.toInt();
      if (p.dy.toInt() < minY) minY = p.dy.toInt();
      if (p.dy.toInt() > maxY) maxY = p.dy.toInt();
    }
    for (int by = minY; by <= maxY; by += pixelBlockSize) {
      for (int bx = minX; bx <= maxX; bx += pixelBlockSize) {
        final bw = math.min(pixelBlockSize, image.width - bx);
        final bh = math.min(pixelBlockSize, image.height - by);
        if (bw <= 0 || bh <= 0) continue;
        int r = 0, g = 0, b = 0, count = 0;
        for (int dy = 0; dy < bh; dy += 2) {
          for (int dx = 0; dx < bw; dx += 2) {
            final pixel = image.getPixel(bx + dx, by + dy);
            r += pixel.r.toInt();
            g += pixel.g.toInt();
            b += pixel.b.toInt();
            count++;
          }
        }
        if (count == 0) continue;
        final avgColor = img.ColorRgb8(r ~/ count, g ~/ count, b ~/ count);
        for (int dy = 0; dy < bh; dy++) {
          for (int dx = 0; dx < bw; dx++) {
            final px = bx + dx;
            final py = by + dy;
            if (affectedPixels.contains(Offset(px.toDouble(), py.toDouble()))) {
              image.setPixel(px, py, avgColor);
            }
          }
        }
      }
    }
    for (final p in affectedPixels) {
      final px = p.dx.toInt();
      final py = p.dy.toInt();
      if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
        final orig = image.getPixel(px, py);
        final r = (orig.r * 0.45 + 255 * 0.55).round().clamp(0, 255);
        final g = (orig.g * 0.45 + 255 * 0.55).round().clamp(0, 255);
        final b = (orig.b * 0.45 + 255 * 0.55).round().clamp(0, 255);
        image.setPixel(px, py, img.ColorRgb8(r, g, b));
      }
    }
  }
}

/// 裁剪结果
class CropResult {
  final String path;
  final int width;
  final int height;

  const CropResult({
    required this.path,
    required this.width,
    required this.height,
  });
}

/// 传递给后台 isolate 的裁剪参数（只含基本类型）
class _CropWorkParams {
  final String imagePath;
  final int pixelX;
  final int pixelY;
  final int pixelW;
  final int pixelH;
  final bool needsRotation;
  final double rotationDegrees;

  const _CropWorkParams({
    required this.imagePath,
    required this.pixelX,
    required this.pixelY,
    required this.pixelW,
    required this.pixelH,
    required this.needsRotation,
    required this.rotationDegrees,
  });
}

/// 后台 isolate 执行的裁剪重活
CropResult _cropWork(_CropWorkParams p) {
  final bytes = File(p.imagePath).readAsBytesSync();
  var image = img.decodeImage(bytes);
  if (image == null) {
    return CropResult(path: p.imagePath, width: 0, height: 0);
  }

  final cropX = p.pixelX.clamp(0, image.width - 1);
  final cropY = p.pixelY.clamp(0, image.height - 1);
  final cropW = p.pixelW.clamp(1, image.width - cropX);
  final cropH = p.pixelH.clamp(1, image.height - cropY);

  image = img.copyCrop(image, x: cropX, y: cropY, width: cropW, height: cropH);

  if (p.needsRotation) {
    image = img.copyRotate(image, angle: p.rotationDegrees);
  }

  final ext = p.imagePath.endsWith('.png') ? '.png' : '.jpg';
  final newPath = p.imagePath.replaceAll(
    RegExp(r'\.[^.]+$'),
    '_cropped_${DateTime.now().millisecondsSinceEpoch}$ext',
  );
  final outputBytes = img.encodeJpg(image, quality: 95);
  File(newPath).writeAsBytesSync(outputBytes);

  return CropResult(path: newPath, width: image.width, height: image.height);
}