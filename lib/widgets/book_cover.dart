import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book_cover_design.dart';
import '../models/book_recognition.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.fit = BoxFit.cover,
    this.borderRadius = 12,
    this.builtInSpineShading = true,
    this.topLeftRadius,
    this.topRightRadius,
    this.bottomRightRadius,
    this.bottomLeftRadius,
  });

  final BookRecord book;
  final BoxFit fit;
  final double borderRadius;
  final bool builtInSpineShading;
  final double? topLeftRadius;
  final double? topRightRadius;
  final double? bottomRightRadius;
  final double? bottomLeftRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.only(
      topLeft: Radius.circular(topLeftRadius ?? borderRadius),
      topRight: Radius.circular(topRightRadius ?? borderRadius),
      bottomRight: Radius.circular(bottomRightRadius ?? borderRadius),
      bottomLeft: Radius.circular(bottomLeftRadius ?? borderRadius),
    );
    return Semantics(
      image: true,
      label: '${book.title}封面',
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep a complete local cover underneath every image source. Some
            // catalogue/CDN responses decode successfully but contain only
            // transparent pixels, so Image.errorBuilder is never invoked.
            _FallbackBookCover(book: book),
            _imageLayer(),
            IgnorePointer(
              child: CustomPaint(
                painter: _BookFinishPainter(
                  showSpineShading: builtInSpineShading,
                  radius: radius,
                ),
              ),
            ),
            if (builtInSpineShading)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 10,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0x5C17231E),
                          Color(0x1F17231E),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0, .55, 1],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _imageLayer() {
    if (book.coverType == 'template') {
      final template = BookCoverTemplateDefinition.forId(book.coverTemplate);
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            template.assetPath,
            fit: fit,
            cacheWidth: 720,
            cacheHeight: 1080,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          _EditableCoverTypography(book: book, template: template),
        ],
      );
    }
    if (book.coverPath.isNotEmpty) {
      return Image.file(
        File(book.coverPath),
        fit: fit,
        cacheWidth: 720,
        cacheHeight: 1080,
        filterQuality: FilterQuality.low,
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) =>
            wasSynchronouslyLoaded || frame != null
            ? child
            : const SizedBox.shrink(),
        errorBuilder: (_, _, _) => _remoteImageLayer(),
      );
    }
    return _remoteImageLayer();
  }

  Widget _remoteImageLayer() {
    if (book.coverType == 'uploaded') return const SizedBox.shrink();
    // The catalogue/provider URL is the selected source for this book. Try it
    // before the legacy Open Library ISBN guess; the latter can be unreachable
    // on Android and otherwise delays or hides a valid returned cover.
    if (book.coverUrl.isNotEmpty) {
      return _networkImage(
        _httpsCoverUrl(book.coverUrl),
        onError: _emptyCoverLayer,
      );
    }
    return _emptyCoverLayer();
  }

  Widget _emptyCoverLayer() => const SizedBox.shrink();

  Widget _networkImage(String url, {required Widget Function() onError}) {
    return Image.network(
      url,
      fit: fit,
      cacheWidth: 720,
      cacheHeight: 1080,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, wasSynchronouslyLoaded) =>
          wasSynchronouslyLoaded || frame != null
          ? child
          : const SizedBox.shrink(),
      errorBuilder: (_, _, _) => onError(),
    );
  }

  /// Google Books and older stored records can contain an `http` thumbnail
  /// URL. Android rejects clear-text traffic by default, while the same CDN is
  /// available over HTTPS.
  static String _httpsCoverUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) return value.trim();
    return uri.scheme.toLowerCase() == 'http'
        ? uri.replace(scheme: 'https').toString()
        : uri.toString();
  }
}

/// Keeps generated artwork text-free while rendering crisp, editable book
/// metadata on top of the title-safe area reserved in each asset.
class _EditableCoverTypography extends StatelessWidget {
  const _EditableCoverTypography({required this.book, required this.template});

  final BookRecord book;
  final BookCoverTemplateDefinition template;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 100 || constraints.maxHeight < 175;
      final tiny = constraints.maxWidth < 90 || constraints.maxHeight < 125;
      return Align(
        alignment: const Alignment(0, -.28),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tiny ? 7 : (compact ? 10 : 18),
          ),
          child: SizedBox(
            width: constraints.maxWidth * .9,
            height: constraints.maxHeight * .42,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    book.title.trim().isEmpty ? '待确认书籍' : book.title,
                    maxLines: tiny ? 3 : 4,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: template.titleColor,
                      fontSize: tiny ? 11 : (compact ? 14 : 19),
                      height: 1.22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .25,
                      shadows: const [
                        Shadow(color: Color(0x22000000), blurRadius: 2),
                      ],
                    ),
                  ),
                  if (!compact && book.authorLabel.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: 24,
                      height: 1,
                      color: template.accent.withValues(alpha: .7),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      book.authorLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: template.titleColor.withValues(alpha: .78),
                        fontSize: 10,
                        height: 1.3,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _FallbackBookCover extends StatelessWidget {
  const _FallbackBookCover({required this.book});

  final BookRecord book;

  @override
  Widget build(BuildContext context) {
    final template = book.coverType == 'template'
        ? BookCoverTemplateDefinition.forId(book.coverTemplate)
        : BookCoverTemplateDefinition.recommendedFor(book.title);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 100 || constraints.maxHeight < 175;
        final tiny = constraints.maxWidth < 90 || constraints.maxHeight < 125;
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: template.colors,
                ),
              ),
            ),
            CustomPaint(
              painter: _CoverTexturePainter(
                accent: template.accent,
                templateId: template.id,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: compact ? 6 : 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      template.accent.withValues(alpha: .55),
                      template.accent.withValues(alpha: .08),
                    ],
                  ),
                ),
              ),
            ),
            if (book.coverType != 'template')
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tiny ? 6 : (compact ? 10 : 16),
                  tiny ? 8 : (compact ? 12 : 18),
                  tiny ? 5 : (compact ? 8 : 13),
                  tiny ? 7 : (compact ? 10 : 16),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .08),
                    border: Border.all(
                      color: template.accent.withValues(alpha: .28),
                    ),
                    borderRadius: BorderRadius.circular(compact ? 5 : 8),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tiny ? 3 : (compact ? 5 : 10),
                      vertical: tiny ? 4 : (compact ? 8 : 14),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: constraints.maxWidth * .9,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              book.title.trim().isEmpty ? '待确认书籍' : book.title,
                              maxLines: tiny ? 4 : (compact ? 4 : 5),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: template.titleColor,
                                fontSize: tiny ? 11 : (compact ? 14 : 18),
                                height: tiny ? 1.2 : 1.35,
                                fontWeight: FontWeight.w700,
                                letterSpacing: .3,
                              ),
                            ),
                            if (!compact && book.authorLabel.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                width: 24,
                                height: 1,
                                color: template.accent.withValues(alpha: .65),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                book.authorLabel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: template.titleColor.withValues(
                                    alpha: .78,
                                  ),
                                  fontSize: 10,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
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

class _CoverTexturePainter extends CustomPainter {
  const _CoverTexturePainter({required this.accent, required this.templateId});

  final Color accent;
  final String templateId;

  @override
  void paint(Canvas canvas, Size size) {
    final distantInk = Paint()
      ..color = accent.withValues(alpha: .14)
      ..style = PaintingStyle.fill;
    final farRidge = Path()
      ..moveTo(0, size.height * .62)
      ..quadraticBezierTo(
        size.width * .23,
        size.height * .52,
        size.width * .48,
        size.height * .61,
      )
      ..quadraticBezierTo(
        size.width * .72,
        size.height * .49,
        size.width,
        size.height * .58,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(farRidge, distantInk);

    if (templateId == 'blueprint') {
      final grid = Paint()
        ..color = accent.withValues(alpha: .13)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5;
      for (var x = 0.08; x < 1; x += .12) {
        canvas.drawLine(
          Offset(size.width * x, size.height * .08),
          Offset(size.width * x, size.height * .92),
          grid,
        );
      }
      for (var y = 0.12; y < 1; y += .12) {
        canvas.drawLine(
          Offset(size.width * .06, size.height * y),
          Offset(size.width * .94, size.height * y),
          grid,
        );
      }
    }

    final nearInk = Paint()
      ..color = accent.withValues(alpha: .28)
      ..style = PaintingStyle.fill;
    final nearRidge = Path()
      ..moveTo(0, size.height * .76)
      ..quadraticBezierTo(
        size.width * .28,
        size.height * .64,
        size.width * .58,
        size.height * .75,
      )
      ..quadraticBezierTo(
        size.width * .79,
        size.height * .68,
        size.width,
        size.height * .72,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(nearRidge, nearInk);

    final mist = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00FFFFFF), Color(0x80FFFFFF), Color(0x12FFFFFF)],
        stops: [0, .56, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, mist);

    final wash = Paint()
      ..color = accent.withValues(alpha: .10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    final fleck = Paint()..color = accent.withValues(alpha: .08);
    for (var i = 0; i < 7; i++) {
      final y = size.height * (.12 + i * .13);
      final wave = Path()
        ..moveTo(size.width * .08, y)
        ..quadraticBezierTo(
          size.width * .45,
          y - 5 + (i.isEven ? 3 : -3),
          size.width * .94,
          y + 2,
        );
      canvas.drawPath(wave, wash);
    }
    final fleckRows = size.width < 140 ? 3 : 7;
    final fleckColumns = size.width < 140 ? 3 : 5;
    for (var row = 0; row < fleckRows; row++) {
      for (var col = 0; col < fleckColumns; col++) {
        final seed = row * 17 + col * 11;
        canvas.drawCircle(
          Offset(
            size.width * (.12 + col * .19),
            size.height * (.08 + row * .145) + seed % 5,
          ),
          .6,
          fleck,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CoverTexturePainter oldDelegate) =>
      oldDelegate.accent != accent;
}

/// Adds a reusable physical-cover finish to every image source. The source
/// image stays untouched; this layer supplies the shared matte coating,
/// spine shading, edge highlights, and subtle print grain.
class _BookFinishPainter extends CustomPainter {
  const _BookFinishPainter({
    required this.showSpineShading,
    this.radius = const BorderRadius.all(Radius.circular(9)),
  });

  final bool showSpineShading;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final matte = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0x22FFFFFF), Color(0x05FFFFFF), Color(0x14000000)],
        stops: [0, .46, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, matte);

    final diffuse = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-.78, -.82),
        radius: 1.15,
        colors: [Color(0x18FFFFFF), Color(0x00FFFFFF)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, diffuse);

    if (showSpineShading) {
      final spine = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0x260D1915), Color(0x0E0D1915), Color(0x000D1915)],
          stops: [0, .18, .46],
        ).createShader(Rect.fromLTWH(0, 0, size.width * .22, size.height));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width * .22, size.height),
        spine,
      );
    }

    final bottomRim = Paint()
      ..shader =
          const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00FFFFFF), Color(0x18FFFFFF), Color(0x22000000)],
            stops: [.38, .74, 1],
          ).createShader(
            Rect.fromLTWH(0, size.height * .86, size.width, size.height * .14),
          );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * .86, size.width, size.height * .14),
      bottomRim,
    );

    final grain = Paint()
      ..color = const Color(0x18FFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = .38;
    final grainRows = size.width < 140 ? 6 : 18;
    final grainColumns = size.width < 140 ? 5 : 12;
    for (var row = 0; row < grainRows; row++) {
      for (var col = 0; col < grainColumns; col++) {
        final seed = row * 73 + col * 37;
        final x = ((seed * 17) % 1000) / 1000 * size.width;
        final y = ((seed * 29) % 1000) / 1000 * size.height;
        final length = .45 + (seed % 4) * .35;
        canvas.drawLine(Offset(x, y), Offset(x + length, y + .12), grain);
      }
    }

    final rim = Paint()
      ..color = const Color(0x34FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .75;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(.5, .5, size.width - 1, size.height - 1),
        topLeft: radius.topLeft,
        topRight: radius.topRight,
        bottomRight: radius.bottomRight,
        bottomLeft: radius.bottomLeft,
      ),
      rim,
    );
  }

  @override
  bool shouldRepaint(covariant _BookFinishPainter oldDelegate) =>
      oldDelegate.showSpineShading != showSpineShading ||
      oldDelegate.radius != radius;
}
