import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/companion_source_range.dart';
import '../models/reader_pagination.dart';
import '../services/companion_annotation_store.dart';
import '../services/companion_pdf_reflow.dart';

const companionAnnotationUnderline = Color(0xFFA4BD83);

({int firstPage, int lastPage, int startOffset, int endOffset})?
legacyCompanionPdfRange(CompanionAnnotationSelection selection) {
  final first = selection.anchor;
  final last = selection.endAnchor ?? first;
  final start = selection.startOffset;
  final end = selection.endOffset;
  if (selection.view != 'original' ||
      first is! PdfReaderAnchor ||
      last is! PdfReaderAnchor ||
      first.sourceId != last.sourceId ||
      first.pageNumber < 1 ||
      last.pageNumber < first.pageNumber ||
      start == null ||
      start < 0 ||
      end == null ||
      end <= 0 ||
      (first.pageNumber == last.pageNumber && start >= end)) {
    return null;
  }
  return (
    firstPage: first.pageNumber,
    lastPage: last.pageNumber,
    startOffset: start,
    endOffset: end,
  );
}

class CompanionPdfAnnotationOverlay extends StatefulWidget {
  const CompanionPdfAnnotationOverlay({
    required this.page,
    required this.pageSize,
    required this.annotations,
    required this.onOpen,
    super.key,
  });

  final PdfPage page;
  final Size pageSize;
  final List<CompanionAnnotation> annotations;
  final ValueChanged<List<CompanionAnnotation>>? onOpen;

  @override
  State<CompanionPdfAnnotationOverlay> createState() =>
      _CompanionPdfAnnotationOverlayState();
}

class _CompanionPdfAnnotationOverlayState
    extends State<CompanionPdfAnnotationOverlay> {
  late Future<({PdfPageText display, PdfPageText? native})> _text = _loadText();

  Future<({PdfPageText display, PdfPageText? native})> _loadText() async {
    final page = widget.page;
    final display = await page.loadStructuredText();
    final original = companionNativePdfPage(page);
    if (identical(original, page)) return (display: display, native: display);
    try {
      return (display: display, native: await original.loadStructuredText());
    } on Exception {
      return (display: display, native: null);
    }
  }

  @override
  void didUpdateWidget(covariant CompanionPdfAnnotationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) _text = _loadText();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _text,
    builder: (context, snapshot) {
      final text = snapshot.data;
      if (snapshot.connectionState != ConnectionState.done ||
          text == null ||
          text.display.pageNumber != widget.page.pageNumber) {
        return const SizedBox.shrink();
      }
      final segments = <(Rect, CompanionAnnotation)>[];
      final displayHash = companionTextHash(text.display.fullText);
      final nativeHash = identical(text.native, text.display)
          ? displayHash
          : text.native == null
          ? null
          : companionTextHash(text.native!.fullText);
      for (final annotation in widget.annotations) {
        final selection = annotation.selection;
        final canonical = selection.canonicalRange is CompanionPdfSourceRange;
        final pageText = canonical ? text.native : text.display;
        final pageHash = canonical ? nativeHash : displayHash;
        if (pageText == null || pageHash == null) continue;
        final maximum = math.min(
          pageText.fullText.length,
          pageText.charRects.length,
        );
        final native = _rangeForPage(selection, pageText, pageHash, maximum);
        if (native == null) continue;
        final range = PdfPageTextRange(
          pageText: pageText,
          start: native.start,
          end: native.end,
        );
        for (final line in range.enumerateFragmentBoundingRects()) {
          final rect = line.bounds.toRect(
            page: widget.page,
            scaledPageSize: widget.pageSize,
          );
          if (!rect.isEmpty) segments.add((rect, annotation));
        }
      }
      if (segments.isEmpty) return const SizedBox.shrink();
      return PdfOverlayInteractionRegion(
        onTap: widget.onOpen == null
            ? null
            : (details) {
                final box = context.findRenderObject();
                if (box is! RenderBox) return false;
                final point = box.globalToLocal(details.globalPosition);
                final matches = {
                  for (final (rect, annotation) in segments)
                    if (rect.inflate(2).contains(point))
                      annotation.id: annotation,
                };
                if (matches.isEmpty) return false;
                widget.onOpen!(matches.values.toList());
                return true;
              },
        child: CustomPaint(
          painter: _AnnotationDashPainter([
            for (final (rect, _) in segments) rect,
          ]),
        ),
      );
    },
  );

  CompanionTextRange? _rangeForPage(
    CompanionAnnotationSelection selection,
    PdfPageText page,
    String pageHash,
    int maximum,
  ) {
    final canonical = selection.canonicalRange;
    if (canonical is CompanionPdfSourceRange) {
      final span = canonical.pages
          .where((item) => item.page == page.pageNumber)
          .firstOrNull;
      if (span == null ||
          span.textHash != pageHash ||
          span.start < 0 ||
          span.end > maximum ||
          span.start >= span.end) {
        return null;
      }
      return (start: span.start, end: span.end);
    }
    final legacy = legacyCompanionPdfRange(selection);
    if (legacy == null ||
        page.pageNumber < legacy.firstPage ||
        page.pageNumber > legacy.lastPage ||
        selection.pdfPageTextHashes[page.pageNumber] != pageHash) {
      return null;
    }
    final start = page.pageNumber == legacy.firstPage ? legacy.startOffset : 0;
    final end = page.pageNumber == legacy.lastPage ? legacy.endOffset : maximum;
    if (start >= end || end > maximum) {
      return null;
    }
    if (legacy.firstPage == legacy.lastPage &&
        page.fullText.substring(start, end).trim() != selection.quote.trim()) {
      return null;
    }
    return (start: start, end: end);
  }
}

class _AnnotationDashPainter extends CustomPainter {
  const _AnnotationDashPainter(this.ranges);

  final List<Rect> ranges;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = companionAnnotationUnderline
      ..strokeWidth = 1;
    for (final rect in ranges) {
      final y = rect.bottom + 1;
      for (var x = rect.left; x < rect.right; x += 6) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(rect.right, x + 3.5), y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationDashPainter oldDelegate) =>
      ranges != oldDelegate.ranges;
}
