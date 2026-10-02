import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/book_cover_design.dart';
import '../models/book_recognition.dart';

/// Palette derived from the book's own cover so the physical book layers
/// (spine, fold, shadow) stay in the cover's color family instead of using
/// a hard-coded scheme.
class BookCoverPalette {
  const BookCoverPalette({
    required this.shade,
    required this.foldLight,
    required this.foldShade,
    required this.shadow,
  });

  /// Darkened cover tone used for curvature and cast-shadow shading.
  final Color shade;
  final Color foldLight;
  final Color foldShade;
  final Color shadow;

  static const fallback = BookCoverPalette(
    shade: Color(0xFF3F5A52),
    foldLight: Color(0x59FFFFFF),
    foldShade: Color(0x8C30382F),
    shadow: Color(0xFF3A2B1D),
  );

  static Future<BookCoverPalette> fromBook(BookRecord book) async {
    // Template covers use the curated accent/colors directly: fast and
    // always in the artwork's color family.
    if (book.coverType == 'template') {
      final template = BookCoverTemplateDefinition.forId(book.coverTemplate);
      return fromColors(template.colors, template.accent);
    }

    // Local photos and remote covers sample the actual artwork.
    final bytes = await _coverBytes(book);
    if (bytes != null) {
      final sampled = await _sample(bytes);
      if (sampled != null) return sampled;
    }
    return fallback;
  }

  static Future<Uint8List?> _coverBytes(BookRecord book) async {
    // Remote covers are already fetched by BookCover's Image.network. Do not
    // start a second HttpClient request just to derive the decorative palette.
    if (book.coverPath.isEmpty) return null;
    try {
      return await File(book.coverPath).readAsBytes();
    } catch (_) {}
    return null;
  }

  static Future<BookCoverPalette?> _sample(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;

      final width = image.width;
      final height = image.height;
      final pixels = data.buffer.asUint8List();

      Color average(int x0, int y0, int x1, int y1) {
        var r = 0, g = 0, b = 0, n = 0;
        for (var y = y0; y < y1; y += 2) {
          for (var x = x0; x < x1; x += 2) {
            final i = (y * width + x) * 4;
            r += pixels[i];
            g += pixels[i + 1];
            b += pixels[i + 2];
            n++;
          }
        }
        if (n == 0) return Colors.white;
        return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
      }

      final leftEdge = average(0, 0, (width * .08).round(), height);
      final overall = average(0, 0, width, height);
      image.dispose();
      return fromColors([overall, leftEdge], leftEdge);
    } catch (_) {
      return null;
    }
  }

  static BookCoverPalette fromColors(List<Color> colors, Color accent) {
    final base = accent;
    return BookCoverPalette(
      // Cooler, darker tone for curvature and cast shading.
      shade: Color.lerp(base, const Color(0xFF2C3731), .45)!,
      foldLight: const Color(0x59FFFFFF),
      foldShade: Color.lerp(base, const Color(0xFF111C18), .55)!.withValues(
        alpha: .72,
      ),
      shadow: Color.lerp(base, const Color(0xFF241A10), .55)!,
    );
  }
}
