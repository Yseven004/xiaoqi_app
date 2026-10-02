import 'package:flutter/material.dart';

/// 笔记页新 UI（模板 A「编辑室」）设计令牌。
///
/// 基于书籍笔记空间 [BookFlowTheme] 的色板延伸：暖白纸感画布、墨绿主色、
/// 赭橙点缀、金线圆形标注；书页正文用系统衬线体（serif）还原书页排版。
/// UI 文字沿用系统默认无衬线体，与书籍空间保持一致。
abstract final class NotePageTheme {
  NotePageTheme._();

  // ── 画布与纸面 ──────────────────────────────────────────
  /// 页面底色（更偏白的暖米色，托起白色卡片）
  static const Color canvas = Color(0xFFFCFAF5);

  /// 白纸卡片（纯白）
  static const Color card = Color(0xFFFFFFFF);

  /// 浅纸色（输入条、按压态）
  static const Color soft = Color(0xFFF3ECDF);

  // ── 线条 ────────────────────────────────────────────────
  static const Color line = Color(0xFFE7DED0);

  static const Color lineStrong = Color(0xFFD5C8B8);

  // ── 墨色 ────────────────────────────────────────────────
  static const Color ink = Color(0xFF1A1A1A);

  static const Color inkSecondary = Color(0xFF666666);

  static const Color muted = Color(0xFF999999);

  // ── 强调色（书籍空间主色板） ────────────────────────────
  /// 墨绿（主按钮、选中态）
  static const Color green = Color(0xFF174C3C);

  /// 墨绿深（文字）
  static const Color greenDeep = Color(0xFF1B4332);

  /// 墨绿浅底（选中胶囊、我方气泡）
  static const Color greenSoft = Color(0xFFE6EEE8);

  /// 赭橙（点缀、语音、AI 高亮）
  static const Color ochre = Color(0xFFE85913);

  /// 赭橙浅底（引用条）
  static const Color ochreSoft = Color(0xFFF4E4CF);

  /// 书金（圆形标注框线）
  static const Color gold = Color(0xFFA6741E);

  // ── 批注色 ──────────────────────────────────────────────
  /// 红线（AI 批注）
  static const Color red = Color(0xFFE53935);

  /// 暖黄气泡（解释 / 我的想法）
  static const Color bubbleYellow = Color(0xFFFFF8E1);

  static const Color bubbleYellowBorder = Color(0xFFFFE082);

  /// 浅紫气泡（质疑 / AI 追问）
  static const Color bubblePurple = Color(0xFFF3E5F5);

  static const Color bubblePurpleBorder = Color(0xFFCE93D8);

  // ── 书页正文 ────────────────────────────────────────────
  /// 正文墨色（比 UI 墨色略暖、略浅，接近铅字）
  static const Color bookText = Color(0xFF2B2B2B);

  /// 书页正文衬线字体：交给系统衬线体（Android→Noto Serif CJK，
  /// iOS→Songti），避免引入大体积中文字体资源。
  static const String bookFont = 'serif';

  // ── 阴影 ────────────────────────────────────────────────
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x1A174C3C), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x0F523D25), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> popShadow = [
    BoxShadow(
      color: Color(0x382E1405),
      blurRadius: 28,
      offset: Offset(0, 10),
    ),
  ];
}
