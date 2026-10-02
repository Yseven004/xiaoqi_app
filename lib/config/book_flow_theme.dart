import 'package:flutter/material.dart';

abstract final class BookFlowTheme {
  // Shared book-flow tokens.
  static const canvas = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceElevated = Color(0xFFFFFEFA);
  static const surfaceSoft = Color(0xFFF0EDE6);
  static const ink = Color(0xFF1A1A1A);
  static const inkSecondary = Color(0xFF666666);
  static const muted = Color(0xFF999999);
  static const line = Color(0xFFE5E1D8);
  static const lineStrong = Color(0xFFD7D1C6);
  static const primary = Color(0xFF1B4332);
  static const primaryStrong = Color(0xFF173F30);
  static const primarySoft = Color(0xFFE6EEE8);

  // Detail-page-only editorial surfaces. Keeping them separate prevents the
  // warm paper direction from unintentionally restyling capture and forms.
  static const detailCanvas = Color(0xFFF7F1E5);
  static const detailSurfaceElevated = Color(0xFFFFFCF5);
  static const detailSurfaceSoft = Color(0xFFF3ECDF);
  static const detailLine = Color(0xFFE7DED0);
  static const detailLineStrong = Color(0xFFD5C8B8);
  static const detailPrimary = Color(0xFF174C3C);
  static const ochre = Color(0xFFE85913);
  static const ochreSoft = Color(0xFFF4E4CF);
  static const bookGold = Color(0xFFA6741E);
  static const warning = Color(0xFFD28A3F);
  static const warningSoft = Color(0xFFF8EAD8);
  static const camera = Color(0xFF111C19);
  static const danger = Color(0xFFB34A42);

  static const cardShadow = [
    BoxShadow(color: Color(0x0F1B4332), blurRadius: 12, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const detailCardShadow = [
    BoxShadow(color: Color(0x10174436), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x0A523D25), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const buttonShadow = [
    BoxShadow(color: Color(0x241B4332), blurRadius: 10, offset: Offset(0, 3)),
    BoxShadow(color: Color(0x12000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  static const coverShadow = [
    BoxShadow(color: Color(0x26000000), blurRadius: 24, offset: Offset(-8, 8)),
  ];

  static const detailCoverShadow = [
    // A broad warm cast shadow makes the cover feel grounded by a real light
    // source. The negative x offset intentionally pulls the shadow left of
    // the spine, while the y offset lets it spill below the book.
    BoxShadow(
      color: Color(0x3D6E5640),
      blurRadius: 34,
      spreadRadius: 1,
      offset: Offset(-11, 16),
    ),
    BoxShadow(
      color: Color(0x1F6E5640),
      blurRadius: 52,
      spreadRadius: 3,
      offset: Offset(-17, 24),
    ),
    BoxShadow(color: Color(0x1E3B2818), blurRadius: 10, offset: Offset(-2, 5)),
    BoxShadow(color: Color(0x16000000), blurRadius: 2, offset: Offset(0, 2)),
  ];

  static const pageTitle = TextStyle(
    color: ink,
    fontSize: 18,
    height: 1.4,
    fontWeight: FontWeight.w700,
  );

  static const heading = TextStyle(
    color: ink,
    fontSize: 18,
    height: 1.35,
    fontWeight: FontWeight.w700,
  );

  static const body = TextStyle(
    color: inkSecondary,
    fontSize: 14,
    height: 1.55,
  );

  static const caption = TextStyle(color: muted, fontSize: 13, height: 1.4);

  static ButtonStyle primaryButtonStyle() => FilledButton.styleFrom(
    backgroundColor: primary,
    foregroundColor: Colors.white,
    disabledBackgroundColor: primary.withValues(alpha: .35),
    minimumSize: const Size.fromHeight(52),
    elevation: 0,
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  );
}
