import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // 主背景色（暖米色）
  static const Color background = Color(0xFFFFF8F2);

  // 呼吸背景色阶：从安静档到最亮档保持暖米色体系，避免动效改变页面基调。
  static const Color backgroundCalm = Color(0xFFF3E9DF);
  static const Color backgroundBreathNormal = Color(0xFFFFF4EA);
  static const Color backgroundBreathBright = Color(0xFFFFFBF6);
  static const Color backgroundBreathMax = Color(0xFFFFFFFF);

  // 卡片背景色
  static const Color card = Color(0xFFFFFFFF);

  // 暖铜色——FAB/保存按钮/强调
  static const Color accent = Color(0xFFD4A574);

  // accent 上的文字/图标颜色
  static const Color onAccent = Color(0xFFFFFFFF);

  // 输入框 hint 文字
  static const Color hint = Color(0xFFBDBDBD);

  // 禁用态背景
  static const Color disabled = Color(0xFFE0E0E0);

  // 温暖墨色——标题/正文
  static const Color textPrimary = Color(0xFF2C2C2C);

  // 中灰——内容摘要/次要信息
  static const Color textSecondary = Color(0xFF666666);

  // 警示红——删除按钮
  static const Color error = Color(0xFFE53935);

  // 占位图背景
  static const Color placeholder = Color(0xFFEEEEEE);

  // 卡片阴影
  static const Color shadow = Color(0x1F000000);

  // 情绪机器人外壳与投影
  static const Color robotShell = Color(0xFFE4D5C7);
  static const Color robotShadow = Color(0x26000000);

  // 笔记本纸张色（主界面背景）
  static const Color notebookPaper = Color(0xFFF5F3EF);

  // 主界面专用色彩
  static const Color backgroundDark = Color(0xFF1A1A1A);
  static const Color cardSecondaryDark = Color(0xFF252320);
  static const Color cardWideDark = Color(0xFF201F1C);
  static const Color toggleDayBg = Color(0xFFF0EDE8);
  static const Color toggleNightBg = Color(0xFF2A2824);
  static const Color textOnDark = Color(0xFFF5F0E8);
  static const Color iconLight = Color(0xFF2C2A26);
  static const Color textTertiary = Color(0xFF999999);
  static const Color accentGradientEnd = Color(0xFFC4956A);
  static const Color decorationLine = Color(0xFFF0EDE8);
  static const Color notebookInk = Color(0xFF2C2A26);
  static const Color notebookMargin = Color(0xFFE8B4B8);
  static const Color cardMuted = Color(0xFFF0EDE8);

  // 批注气泡颜色
  static const Color bubbleL1 = Color(0xFFFFF8E1); // 暖黄（解释、问答）
  static const Color bubbleL1Border = Color(0xFFFFE082);
  static const Color bubbleL2 = Color(0xFFF5F5F5); // 灰色（默认/物理标记）
  static const Color bubbleL2Border = Color(0xFFE0E0E0);
  static const Color bubbleL3 = Color(0xFFF3E5F5); // 浅紫（质疑、追问、总结）
  static const Color bubbleL3Border = Color(0xFFCE93D8);
  static const Color annotationRed = Color(0xFFE53935); // 标注红色（下划线、圈词）
  static const Color pageBackground = Color(0xFFFBFAF8); // 书页底色
  static const Color numberingColor = Color(0xFFFF7043); // 编号/星号橙色

  /// 扫描取景跟踪框描边（对齐扫描王青绿）
  static const Color scanTrack = Color(0xFF4ADE80);

  /// 扫描取景跟踪框半透明填充
  static const Color scanTrackFill = Color(0x594ADE80); // ~35% alpha
}
