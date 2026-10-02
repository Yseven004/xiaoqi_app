import 'package:flutter/material.dart';

class NotebookTheme {
  NotebookTheme._();

  static const lightBackground = Color(0xFFF7F5F1);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightInk = Color(0xFF24211E);
  static const lightMuted = Color(0xFF756F68);
  static const lightDivider = Color(0xFFE6E0D8);
  static const accent = Color(0xFF9A6544);
  static const accentSoft = Color(0xFFF0E3D7);
  static const danger = Color(0xFFB5473D);

  static const nightBackground = Color(0xFF17161A);
  static const nightSurface = Color(0xFF211F24);
  static const nightInk = Color(0xFFF5F0E9);
  static const nightMuted = Color(0xFFB8B0A8);
  static const nightDivider = Color(0xFF3A363F);
  static const nightAccent = Color(0xFFD6A97E);

  static const covers = <List<Color>>[
    [Color(0xFFD9A977), Color(0xFF9F654E)],
    [Color(0xFF94B6AB), Color(0xFF4F817D)],
    [Color(0xFFC59AA2), Color(0xFF79576D)],
    [Color(0xFFE1BF76), Color(0xFFAA6C3C)],
    [Color(0xFFB4A6CB), Color(0xFF696291)],
    [Color(0xFFB5C5DC), Color(0xFF637B9D)],
    [Color(0xFFDCAE90), Color(0xFF9C5C4D)],
    [Color(0xFF9EBC8F), Color(0xFF5B7C63)],
    [Color(0xFF8FB6C6), Color(0xFF3F728B)],
    [Color(0xFFD2B589), Color(0xFF8B6A3F)],
    [Color(0xFFA6B2D2), Color(0xFF5D668E)],
    [Color(0xFFE2A2A6), Color(0xFF9A535C)],
    [Color(0xFFC3BD97), Color(0xFF77714D)],
    [Color(0xFF9CC5B2), Color(0xFF547F68)],
    [Color(0xFFC8A2CF), Color(0xFF725883)],
    [Color(0xFFD2B2A1), Color(0xFF8A6152)],
  ];

  static LinearGradient coverGradient(int index) {
    final colors = covers[index.abs() % covers.length];
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    );
  }
}
