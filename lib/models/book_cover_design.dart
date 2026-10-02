import 'package:flutter/material.dart';

/// Curated cover directions. The artwork is kept separate from typography so
/// book titles and authors remain crisp, editable and localizable in Flutter.
class BookCoverTemplateDefinition {
  const BookCoverTemplateDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.assetPath,
    required this.colors,
    required this.accent,
    required this.titleColor,
  });

  final String id;
  final String name;
  final String description;
  final String assetPath;
  final List<Color> colors;
  final Color accent;
  final Color titleColor;

  static const values = <BookCoverTemplateDefinition>[
    BookCoverTemplateDefinition(
      id: 'healing',
      name: '治愈风景',
      description: '雾蓝湖光与晨雾，适合心理、哲学与文学',
      assetPath: 'assets/images/book_cover_healing.png',
      colors: [Color(0xFFE9E2D2), Color(0xFF9EBDB7)],
      accent: Color(0xFF4E766D),
      titleColor: Color(0xFF1B2B27),
    ),
    BookCoverTemplateDefinition(
      id: 'healing_meadow',
      name: '治愈风景 · 草甸',
      description: '雨后草甸与远山，轻盈开阔',
      assetPath: 'assets/images/book_cover_healing_2.png',
      colors: [Color(0xFFEDE2CD), Color(0xFF9DB7B1)],
      accent: Color(0xFF607C74),
      titleColor: Color(0xFF253B35),
    ),
    BookCoverTemplateDefinition(
      id: 'healing_cove',
      name: '治愈风景 · 海湾',
      description: '安静海湾与晨光，适合随笔',
      assetPath: 'assets/images/book_cover_healing_3.png',
      colors: [Color(0xFFF2E6D2), Color(0xFFA8C5C1)],
      accent: Color(0xFF5D817E),
      titleColor: Color(0xFF29423F),
    ),
    BookCoverTemplateDefinition(
      id: 'healing_birch',
      name: '治愈风景 · 桦林',
      description: '林间长椅与光线，柔和安定',
      assetPath: 'assets/images/book_cover_healing_4.png',
      colors: [Color(0xFFF0E7D4), Color(0xFFA3B79C)],
      accent: Color(0xFF667C61),
      titleColor: Color(0xFF304336),
    ),
    BookCoverTemplateDefinition(
      id: 'animation',
      name: '手绘动画',
      description: '有故事感的手绘场景，适合成长与旅行',
      assetPath: 'assets/images/book_cover_animation.png',
      colors: [Color(0xFFEFE0B9), Color(0xFF9EB5A0)],
      accent: Color(0xFF9A6C32),
      titleColor: Color(0xFF283D3B),
    ),
    BookCoverTemplateDefinition(
      id: 'animation_bicycle',
      name: '手绘动画 · 单车',
      description: '湖边单车与风，适合旅行与成长',
      assetPath: 'assets/images/book_cover_animation_2.png',
      colors: [Color(0xFFECE0C5), Color(0xFF9EB5A0)],
      accent: Color(0xFFAD6A46),
      titleColor: Color(0xFF2A4540),
    ),
    BookCoverTemplateDefinition(
      id: 'animation_train',
      name: '手绘动画 · 火车',
      description: '云间列车与山谷，适合探索与远行',
      assetPath: 'assets/images/book_cover_animation_3.png',
      colors: [Color(0xFFE8E0C7), Color(0xFF91A8AC)],
      accent: Color(0xFF557B83),
      titleColor: Color(0xFF2B3F4A),
    ),
    BookCoverTemplateDefinition(
      id: 'animation_window',
      name: '手绘动画 · 窗灯',
      description: '晚风、窗灯与风筝，适合故事与回忆',
      assetPath: 'assets/images/book_cover_animation_4.png',
      colors: [Color(0xFFD9D4CF), Color(0xFF556579)],
      accent: Color(0xFFB26A48),
      titleColor: Color(0xFFF4E4C8),
    ),
    BookCoverTemplateDefinition(
      id: 'line',
      name: '简笔插画',
      description: '留白与手绘线条，适合生活、随笔与阅读',
      assetPath: 'assets/images/book_cover_line.png',
      colors: [Color(0xFFF3EDE0), Color(0xFFD6DCCB)],
      accent: Color(0xFF6A7867),
      titleColor: Color(0xFF26312B),
    ),
    BookCoverTemplateDefinition(
      id: 'line_cafe',
      name: '简笔插画 · 咖啡桌',
      description: '窗边咖啡与书，适合生活与阅读',
      assetPath: 'assets/images/book_cover_line_2.png',
      colors: [Color(0xFFF3EBDD), Color(0xFFD7D9C8)],
      accent: Color(0xFF7D866E),
      titleColor: Color(0xFF32382F),
    ),
    BookCoverTemplateDefinition(
      id: 'line_balcony',
      name: '简笔插画 · 阳台',
      description: '植物、折椅与午后光，适合随笔',
      assetPath: 'assets/images/book_cover_line_3.png',
      colors: [Color(0xFFF2ECDD), Color(0xFFC7D0C0)],
      accent: Color(0xFF71806D),
      titleColor: Color(0xFF303A32),
    ),
    BookCoverTemplateDefinition(
      id: 'line_desk',
      name: '简笔插画 · 书桌',
      description: '台灯、书本与枝叶，适合学习与思考',
      assetPath: 'assets/images/book_cover_line_4.png',
      colors: [Color(0xFFF1E8D9), Color(0xFFC8C9B8)],
      accent: Color(0xFF7B806E),
      titleColor: Color(0xFF31362F),
    ),
  ];

  static BookCoverTemplateDefinition forId(String id) {
    for (final template in values) {
      if (template.id == id) return template;
    }
    // Records created with the previous catalogue gracefully move to the
    // first new direction instead of rendering a broken/empty cover.
    return values.first;
  }

  static BookCoverTemplateDefinition recommendedFor(String title) {
    final hash = title.runes.fold<int>(0, (value, rune) => value + rune);
    return values[hash.abs() % values.length];
  }
}
