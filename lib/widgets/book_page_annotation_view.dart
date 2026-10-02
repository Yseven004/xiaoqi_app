import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/note_page_theme.dart';
import '../models/page_annotation.dart';
import '../services/page_image_asset_store.dart';

/// Read-only rendering of every persisted page annotation.
///
/// The annotation layer is deliberately separate from the OCR document. It
/// keeps the source text immutable while allowing the reader and editor to
/// share the same normalized image, stroke, and text-object coordinates.
class BookPageAnnotationView extends StatelessWidget {
  const BookPageAnnotationView({
    super.key,
    required this.document,
    required this.imageStore,
  });

  final PageAnnotationDocument document;
  final PageImageAssetStore imageStore;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ReadOnlyStrokePainter(document.strokes),
                ),
              ),
            ),
            for (final text in document.texts) _positionedText(text, size),
            for (final image in document.images) _positionedImage(image, size),
          ],
        );
      },
    );
  }

  Widget _positionedImage(PageImageObject image, Size size) {
    final maxWidth = _maxImageWidth(image, size);
    final width = image.width.clamp(0.01, maxWidth).toDouble() * size.width;
    final height = width / image.aspectRatio;
    final center = Offset(
      image.center.dx
          .clamp(width / size.width / 2, 1 - width / size.width / 2)
          .toDouble(),
      image.center.dy
          .clamp(height / size.height / 2, 1 - height / size.height / 2)
          .toDouble(),
    );
    final rect = Rect.fromCenter(
      center: Offset(center.dx * size.width, center.dy * size.height),
      width: width,
      height: height,
    );
    return Positioned(
      key: Key('book_page_annotation_image_${image.id}'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: PageImageDisplay(image: image, imageStore: imageStore),
    );
  }

  double _maxImageWidth(PageImageObject image, Size size) {
    if (size.width <= 0 || size.height <= 0) return .01;
    final horizontal = 2 * math.min(image.center.dx, 1 - image.center.dx);
    final vertical =
        2 *
        math.min(image.center.dy, 1 - image.center.dy) *
        size.height *
        image.aspectRatio /
        size.width;
    return math
        .max(.01, math.min(1, math.min(horizontal, vertical)))
        .toDouble();
  }

  Widget _positionedText(PageTextObject text, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(text.center.dx * size.width, text.center.dy * size.height),
      width: text.width * size.width * text.scale,
      height: text.height * size.height * text.scale,
    );
    final textStyle = TextStyle(
      color: Color(text.colorValue),
      fontFamily: text.fontFamily,
      fontSize: text.fontSize * text.scale,
      fontWeight: text.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
      decoration: text.underline ? TextDecoration.underline : null,
      letterSpacing: text.letterSpacing,
      height: text.lineSpacing,
      shadows: text.shadow
          ? const [Shadow(color: Colors.black26, blurRadius: 2)]
          : null,
    );
    return Positioned(
      key: Key('book_page_annotation_text_${text.id}'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Transform.rotate(
        angle: text.rotation,
        child: Align(
          alignment: switch (text.alignment) {
            'right' => Alignment.centerRight,
            'center' => Alignment.center,
            _ => Alignment.centerLeft,
          },
          child: Text(
            text.text,
            textAlign: switch (text.alignment) {
              'right' => TextAlign.right,
              'center' => TextAlign.center,
              _ => TextAlign.left,
            },
            style: textStyle,
          ),
        ),
      ),
    );
  }
}

class PageImageDisplay extends StatefulWidget {
  const PageImageDisplay({
    super.key,
    required this.image,
    required this.imageStore,
    this.onTap,
  });

  final PageImageObject image;
  final PageImageAssetStore imageStore;
  final VoidCallback? onTap;

  @override
  State<PageImageDisplay> createState() => _PageImageDisplayState();
}

class _PageImageDisplayState extends State<PageImageDisplay> {
  late Future<File?> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = widget.imageStore.resolve(widget.image.assetPath);
  }

  @override
  void didUpdateWidget(covariant PageImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.assetPath != widget.image.assetPath ||
        !identical(oldWidget.imageStore, widget.imageStore)) {
      _fileFuture = widget.imageStore.resolve(widget.image.assetPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _PageImageLoadingPlaceholder();
        }
        final file = snapshot.data;
        if (file == null) return const _MissingPageImage();
        return Image.file(
          file,
          key: Key('page_image_file_${widget.image.id}'),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          cacheWidth: _stableDecodeWidth(),
          gaplessPlayback: true,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const _MissingPageImage(),
        );
      },
    );
    final child = widget.onTap == null
        ? image
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: image,
          );
    return Semantics(
      image: true,
      label: widget.image.originalName.isEmpty
          ? '书页图片'
          : '书页图片：${widget.image.originalName}',
      child: child,
    );
  }

  int _stableDecodeWidth() => widget.image.pixelWidth.clamp(1, 2048).toInt();
}

class _MissingPageImage extends StatelessWidget {
  const _MissingPageImage();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: NotePageTheme.card,
        border: Border.all(color: NotePageTheme.line),
      ),
      child: const Center(
        child: Text(
          '图片不可用',
          style: TextStyle(color: NotePageTheme.muted, fontSize: 13),
        ),
      ),
    );
  }
}

class _PageImageLoadingPlaceholder extends StatelessWidget {
  const _PageImageLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Color(0xFFF7F5F1));
  }
}

class _ReadOnlyStrokePainter extends CustomPainter {
  const _ReadOnlyStrokePainter(this.strokes);

  final List<PageStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.tool == StrokeTool.eraser || stroke.points.isEmpty) {
        continue;
      }
      final paint = Paint()
        ..color = Color(stroke.colorValue).withValues(alpha: stroke.opacity)
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.points.length == 1) {
        final point = stroke.points.single;
        canvas.drawCircle(
          Offset(point.dx * size.width, point.dy * size.height),
          math.max(stroke.width / 2, 1),
          Paint()
            ..color = Color(
              stroke.colorValue,
            ).withValues(alpha: stroke.opacity),
        );
        continue;
      }
      for (var i = 1; i < stroke.points.length; i++) {
        final from = Offset(
          stroke.points[i - 1].dx * size.width,
          stroke.points[i - 1].dy * size.height,
        );
        final to = Offset(
          stroke.points[i].dx * size.width,
          stroke.points[i].dy * size.height,
        );
        canvas.drawLine(from, to, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ReadOnlyStrokePainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}
