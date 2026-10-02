import 'dart:ui';
import 'editor_state.dart';

/// 编辑动作抽象基类
abstract class EditorAction {
  String get id;
  EditorTool get tool;
}

/// 画笔动作（存储归一化图片坐标 0~1）
class PenAction extends EditorAction {
  @override
  final String id;
  @override
  final EditorTool tool = EditorTool.pen;
  final List<Offset> points; // 归一化坐标 (0~1)
  final Color color;
  final double strokeWidth; // 归一化线宽

  PenAction({
    required this.id,
    required this.points,
    required this.color,
    required this.strokeWidth,
  });
}

/// 马赛克动作（存储归一化图片坐标 0~1）
class MosaicAction extends EditorAction {
  @override
  final String id;
  @override
  final EditorTool tool = EditorTool.mosaic;
  final List<Offset> points; // 归一化坐标 (0~1)
  final double blockSize; // 归一化块大小

  MosaicAction({
    required this.id,
    required this.points,
    required this.blockSize,
  });
}

/// 裁剪动作
class CropAction extends EditorAction {
  @override
  final String id;
  @override
  final EditorTool tool = EditorTool.crop;
  final Rect cropRect;

  CropAction({
    required this.id,
    required this.cropRect,
  });
}

/// 橡皮擦动作（存储归一化图片坐标 0~1）
class EraserAction extends EditorAction {
  @override
  final String id;
  @override
  final EditorTool tool = EditorTool.pen;
  final List<Offset> points; // 归一化坐标 (0~1)
  final double strokeWidth; // 归一化线宽

  EraserAction({
    required this.id,
    required this.points,
    required this.strokeWidth,
  });
}
