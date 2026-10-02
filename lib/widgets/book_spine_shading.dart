import 'package:flutter/material.dart';

import '../models/book_recognition.dart';
import '../utils/book_cover_palette.dart';
import 'book_cover.dart';

/// Transparent physical shading for a wrapped cover: a convex spine band
/// with outer-edge seam, central spine crease, fold seam with catch-light,
/// and top/bottom rim lines. All structure stays in the cover's own palette
/// (no separate spine color) and the rounded left corners match the cover.
class BookSpineShadingPainter extends CustomPainter {
  const BookSpineShadingPainter({
    required this.palette,
    required this.foldX,
  });

  final BookCoverPalette palette;
  final double foldX;

  @override
  void paint(Canvas canvas, Size size) {
    // Clip to the same rounded corner as the cover so the shading never
    // paints square dark corners outside the artwork.
    final clipRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, size.width, size.height),
      topLeft: const Radius.circular(8),
      bottomLeft: const Radius.circular(8),
    );
    canvas.save();
    canvas.clipRRect(clipRect);

    // 0) The rounded outer edge of the book (the "book edge"): a faint
    // band with a dark seam just inside it, giving the edge visible
    // thickness before the spine surface begins.
    final spineStart = 1.4;
    final edgeBand = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          palette.shade.withValues(alpha: .10),
          palette.shade.withValues(alpha: .22),
        ],
      ).createShader(Rect.fromLTWH(0, 0, spineStart, size.height));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, spineStart, size.height),
      edgeBand,
    );
    final edgeSeam = Paint()
      ..color = palette.foldShade.withValues(alpha: .30)
      ..strokeWidth = .8;
    canvas.drawLine(
      Offset(1.35, 0),
      Offset(1.35, size.height),
      edgeSeam,
    );

    // 1) Spine curvature: a real spine is slightly convex, so the band
    // darkens at both hinge edges and stays lighter across the middle,
    // then the cover fades away from the fold.
    final spineSurfaceWidth = size.width - spineStart;
    final midStop = ((foldX - spineStart) / spineSurfaceWidth * .5).clamp(
      0.0,
      1.0,
    ).toDouble();
    final hingeStop = ((foldX - spineStart) / spineSurfaceWidth).clamp(
      0.0,
      1.0,
    ).toDouble();
    final curve = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          palette.shade.withValues(alpha: .22), // spine outer edge
          const Color(0x00000000), // spine center bulge
          palette.shade.withValues(alpha: .30), // cover fold / hinge
          const Color(0x00000000),
        ],
        stops: [0, midStop, hingeStop, 1],
      ).createShader(
        Rect.fromLTWH(spineStart, 0, spineSurfaceWidth, size.height),
      );
    canvas.drawRect(
      Rect.fromLTWH(spineStart, 0, spineSurfaceWidth, size.height),
      curve,
    );

    // 2) Central spine crease: one subtle full-height line down the middle
    // of the spine band.
    final centerX = spineStart + (foldX - spineStart) * .5;
    final crease = Paint()
      ..color = palette.foldShade.withValues(alpha: .12)
      ..strokeWidth = .55;
    canvas.drawLine(
      Offset(centerX, 0),
      Offset(centerX, size.height),
      crease,
    );

    // 3) Hinge fold: a soft shadow seam exactly at the cover/spine junction,
    // a fainter seam on the cover side, plus a thin catch-light just inside
    // the spine. Both run the full height of the book; the rounded clip
    // keeps the ends clean.
    final seam = Paint()
      ..color = palette.foldShade.withValues(alpha: .34)
      ..strokeWidth = .8;
    canvas.drawLine(
      Offset(foldX - .3, 0),
      Offset(foldX - .3, size.height),
      seam,
    );
    final coverSeam = Paint()
      ..color = palette.foldShade.withValues(alpha: .14)
      ..strokeWidth = .7;
    canvas.drawLine(
      Offset(foldX + .55, 0),
      Offset(foldX + .55, size.height),
      coverSeam,
    );
    final light = Paint()
      ..color = palette.foldLight
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(foldX - 1.5, 0),
      Offset(foldX - 1.5, size.height),
      light,
    );

    // 4) Top rim: a horizontal catch-light along the head of the spine with
    // a soft 2px falloff, mirroring the sample's top highlight line.
    final topLight = Paint()
      ..color = palette.foldLight.withValues(alpha: .48)
      ..strokeWidth = .9;
    canvas.drawLine(
      Offset(spineStart, .8),
      Offset(foldX, .8),
      topLight,
    );
    final topBandWidth = (foldX - spineStart).clamp(0.0, size.width).toDouble();
    final topBand = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          palette.foldLight.withValues(alpha: .18),
          const Color(0x00FFFFFF),
        ],
      ).createShader(
        Rect.fromLTWH(spineStart, 0, topBandWidth, 2.2),
      );
    canvas.drawRect(
      Rect.fromLTWH(spineStart, 0, topBandWidth, 2.2),
      topBand,
    );

    // 5) Bottom rim: a horizontal shadow along the tail of the spine with a
    // soft 2px falloff, mirroring the sample's bottom shadow line.
    final bottomShade = Paint()
      ..color = palette.foldShade.withValues(alpha: .24)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(spineStart, size.height - .9),
      Offset(foldX, size.height - .9),
      bottomShade,
    );
    final bottomBandWidth = (foldX - spineStart)
        .clamp(0.0, size.width)
        .toDouble();
    final bottomBand = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x00000000),
          palette.foldShade.withValues(alpha: .14),
        ],
      ).createShader(
        Rect.fromLTWH(
          spineStart,
          size.height - 2.2,
          bottomBandWidth,
          2.2,
        ),
      );
    canvas.drawRect(
      Rect.fromLTWH(
        spineStart,
        size.height - 2.2,
        bottomBandWidth,
        2.2,
      ),
      bottomBand,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BookSpineShadingPainter oldDelegate) =>
      oldDelegate.palette != palette || oldDelegate.foldX != foldX;
}

/// A book cover with the physical "wrapped cover" look: asymmetric corners
/// (rounded spine side, near-square fore-edge), cover-derived palette, and
/// transparent spine shading. Intentionally has no cast shadow.
class BookCoverStyled extends StatefulWidget {
  const BookCoverStyled({
    super.key,
    required this.book,
    this.borderRadius = 8,
    this.leftRadius,
    this.rightRadius = 5,
  });

  final BookRecord book;
  final double borderRadius;
  final double? leftRadius;
  final double rightRadius;

  @override
  State<BookCoverStyled> createState() => _BookCoverStyledState();
}

class _BookCoverStyledState extends State<BookCoverStyled> {
  BookCoverPalette _palette = BookCoverPalette.fallback;

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  Future<void> _loadPalette() async {
    final palette = await BookCoverPalette.fromBook(widget.book);
    if (mounted) setState(() => _palette = palette);
  }

  @override
  Widget build(BuildContext context) {
    final leftRadius = widget.leftRadius ?? widget.borderRadius;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
          return BookCover(
            book: widget.book,
            borderRadius: widget.borderRadius,
          );
        }
        final spineWidth = (width * .075).clamp(8.0, 11.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: BookCover(
                book: widget.book,
                borderRadius: widget.borderRadius,
                topLeftRadius: leftRadius,
                bottomLeftRadius: leftRadius,
                topRightRadius: widget.rightRadius,
                bottomRightRadius: widget.rightRadius,
                builtInSpineShading: false,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              width: spineWidth + 2,
              height: height,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: BookSpineShadingPainter(
                    palette: _palette,
                    foldX: spineWidth,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
