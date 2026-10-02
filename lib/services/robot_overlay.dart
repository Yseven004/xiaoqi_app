import 'package:flutter/material.dart';

// 小七悬浮窗可见性控制
//
// 默认可见，图片全屏预览时隐藏。

class RobotOverlay {
  RobotOverlay._();

  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  static void hide() => visible.value = false;
  static void show() => visible.value = true;
}
