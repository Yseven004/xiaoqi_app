import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../config/note_page_theme.dart';
import '../models/ocr_layout.dart';
import 'book_page_document_view.dart';

typedef PdfPageTextFocusCallback =
    void Function(int pageNumber, PdfRect pageRect);

TextStyle pdfPageTextStyle(OcrBlock block, double height, {Color? color}) {
  final base = BookPageDocumentView.styleFor(block);
  final charHeightRatio = double.tryParse(
    block.attributes['pdf_char_height_ratio'] ?? '',
  );
  final measuredSize = charHeightRatio == null
      ? math.max(base.fontSize ?? 16.5, height * .72)
      : height * charHeightRatio;
  return base.copyWith(
    color: color ?? base.color,
    // Prefer the original PDF character height when available. Older OCR
    // notes fall back to the shared document style instead of shrinking on
    // activation.
    fontSize: math.max(8, measuredSize).toDouble(),
    height: base.height ?? 1.05,
  );
}

PdfPageLayout horizontalPdfPageLayout(
  List<PdfPage> pages,
  PdfViewerParams params,
) {
  if (pages.isEmpty) {
    return PdfPageLayout(pageLayouts: const [], documentSize: Size.zero);
  }
  final height =
      pages.fold<double>(
        0,
        (current, page) => math.max(current, page.height).toDouble(),
      ) +
      params.margin * 2;
  final layouts = <Rect>[];
  var x = params.margin;
  for (final page in pages) {
    layouts.add(
      Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height),
    );
    x += page.width + params.margin;
  }
  return PdfPageLayout(pageLayouts: layouts, documentSize: Size(x, height));
}

/// Shared PDF page surface used by the reader and the structured editor.
///
/// The PDF page remains the visual base. Text changes are persisted as
/// [BookPageDocument.editedBlocks] and rendered only as coordinate patches.
class PdfPageCanvas extends StatelessWidget {
  const PdfPageCanvas({
    super.key,
    required this.documentRef,
    required this.controller,
    required this.document,
    required this.initialPageNumber,
    this.editable = false,
    this.editableTextBuilder,
    this.activeTextBlockIdListenable,
    this.onPageChanged,
    this.horizontal = false,
    this.layoutPages,
    this.pageOverlaysBuilder,
    this.calculateInitialZoom,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.onKey,
    this.onViewSizeChanged,
    this.onDocumentLoadFinished,
    this.onViewerReady,
    this.loadingBannerBuilder,
    this.errorBannerBuilder,
    this.onTextFocus,
    this.annotationLayerBuilder,
    this.verticalCacheExtent,
    this.margin = 8,
  });

  final PdfDocumentRef documentRef;
  final PdfViewerController controller;
  final BookPageDocument document;
  final int initialPageNumber;
  final bool editable;
  final BookPageDocumentTextBuilder? editableTextBuilder;
  final ValueNotifier<int?>? activeTextBlockIdListenable;
  final ValueChanged<int?>? onPageChanged;
  final bool horizontal;
  final PdfPageLayoutFunction? layoutPages;
  final PdfPageOverlaysBuilder? pageOverlaysBuilder;
  final PdfViewerCalculateZoomFunction? calculateInitialZoom;
  final GestureScaleStartCallback? onInteractionStart;
  final GestureScaleEndCallback? onInteractionEnd;
  final PdfViewerOnKeyCallback? onKey;
  final PdfViewerViewSizeChanged? onViewSizeChanged;
  final PdfDocumentLoadFinished? onDocumentLoadFinished;
  final PdfViewerReadyCallback? onViewerReady;
  final PdfViewerLoadingBannerBuilder? loadingBannerBuilder;
  final PdfViewerErrorBannerBuilder? errorBannerBuilder;
  final PdfPageTextFocusCallback? onTextFocus;
  final Widget? Function(BuildContext context, Rect pageRect, PdfPage page)?
  annotationLayerBuilder;
  final double? verticalCacheExtent;
  final double margin;

  @override
  Widget build(BuildContext context) => PdfViewer(
    documentRef,
    controller: controller,
    initialPageNumber: initialPageNumber,
    params: PdfViewerParams(
      backgroundColor: NotePageTheme.canvas,
      margin: horizontal ? 0 : margin,
      layoutPages: layoutPages,
      pageAnchor: horizontal ? PdfPageAnchor.center : PdfPageAnchor.top,
      pageAnchorEnd: horizontal ? PdfPageAnchor.center : PdfPageAnchor.bottom,
      underflowAnchor: horizontal ? PdfPageAnchor.center : null,
      panAxis: horizontal ? PanAxis.aligned : PanAxis.free,
      scrollHorizontallyByMouseWheel: horizontal,
      horizontalCacheExtent: horizontal ? 1.5 : 1.0,
      verticalCacheExtent: horizontal ? .25 : (verticalCacheExtent ?? 1.0),
      pageOverlaysBuilder:
          pageOverlaysBuilder ??
          ((context, pageRect, page) =>
              _buildOverlays(context, pageRect, page)),
      calculateInitialZoom:
          calculateInitialZoom ??
          ((pdf, viewerController, fitZoom, coverZoom) {
            if (!viewerController.isReady) return fitZoom;
            final layouts = viewerController.layout.pageLayouts;
            if (layouts.isEmpty) return fitZoom;
            final index =
                initialPageNumber.clamp(1, layouts.length).toInt() - 1;
            final pageWidth = layouts[index].width;
            return pageWidth <= 0
                ? fitZoom
                : viewerController.viewSize.width / pageWidth;
          }),
      onPageChanged: onPageChanged,
      onInteractionStart: onInteractionStart,
      onInteractionEnd: onInteractionEnd,
      onKey: onKey,
      onViewSizeChanged: onViewSizeChanged,
      onDocumentLoadFinished: onDocumentLoadFinished,
      onViewerReady: onViewerReady,
      loadingBannerBuilder: loadingBannerBuilder,
      errorBannerBuilder: errorBannerBuilder,
    ),
  );

  List<Widget> _buildOverlays(
    BuildContext context,
    Rect pageRect,
    PdfPage page,
  ) {
    final pageNumber = page.pageNumber;
    final documentPageNumber = int.tryParse(document.pageNumber?.trim() ?? '');
    if (pageNumber != (documentPageNumber ?? initialPageNumber)) {
      return const <Widget>[];
    }
    final widgets = <Widget>[];
    final originalById = <int, OcrBlock>{
      for (final block in document.blocks) block.id: block,
    };
    final edited = document.editedBlocks;
    if (edited != null) {
      for (final block in edited) {
        final original = originalById[block.id];
        if (original == null ||
            original.text == block.text ||
            block.isFigure ||
            block.isTable ||
            block.width <= 0 ||
            block.height <= 0) {
          continue;
        }
        final height = block.height * pageRect.height;
        widgets.add(
          Positioned(
            left: block.x * pageRect.width,
            top: block.y * pageRect.height,
            width: block.width * pageRect.width,
            height: block.height * pageRect.height,
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.white,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    block.text,
                    maxLines: null,
                    overflow: TextOverflow.clip,
                    style: pdfPageTextStyle(
                      block,
                      height,
                      color: NotePageTheme.bookText,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    void addAnnotationLayer() {
      final annotationLayer = annotationLayerBuilder?.call(
        context,
        pageRect,
        page,
      );
      if (annotationLayer != null) {
        widgets.add(Positioned.fill(child: annotationLayer));
      }
    }

    if (!editable || editableTextBuilder == null) {
      addAnnotationLayer();
      return widgets;
    }
    final renderedById = <int, OcrBlock>{
      for (final block in document.renderBlocks) block.id: block,
    };
    final activeBlockId = activeTextBlockIdListenable?.value;
    if (activeTextBlockIdListenable != null) {
      bool activateTextBlock(PdfOverlayInteractionDetails details) {
        final blockId = _textBlockIdAtGlobalPosition(
          details.globalPosition,
          page: page,
        );
        if (blockId == null) {
          activeTextBlockIdListenable!.value = null;
          return false;
        }
        activeTextBlockIdListenable!.value = blockId;
        return true;
      }

      widgets.add(
        Positioned.fill(
          child: PdfOverlayInteractionRegion(
            onTap: activateTextBlock,
            onDoubleTap: activateTextBlock,
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    for (final original in document.blocks) {
      final block = renderedById[original.id] ?? original;
      if (activeTextBlockIdListenable != null && block.id != activeBlockId) {
        continue;
      }
      if (block.isFigure ||
          block.isTable ||
          block.isFurniture ||
          original.text.trim().isEmpty ||
          block.width <= 0 ||
          block.height <= 0) {
        continue;
      }
      final width = block.width * pageRect.width;
      final height = block.height * pageRect.height;
      final pageRectInPdf = Rect.fromLTWH(
        block.x * pageRect.width,
        block.y * pageRect.height,
        width,
        height,
      ).toPdfRect(page: page, scaledPageSize: pageRect.size);
      widgets.add(
        Positioned(
          left: block.x * pageRect.width,
          top: block.y * pageRect.height,
          width: math.max(width, 24).toDouble(),
          child: _PdfEditableTextRegion(
            key: ValueKey('pdf-edit-$pageNumber-${block.id}'),
            block: block,
            style: pdfPageTextStyle(block, height),
            minimumWidth: math.max(width, 24).toDouble(),
            minimumHeight: math.max(height, 24).toDouble(),
            activeTextBlockIdListenable: activeTextBlockIdListenable,
            changed: block.text != original.text,
            editableTextBuilder: editableTextBuilder!,
            onFocus: onTextFocus == null
                ? null
                : () => onTextFocus!(pageNumber, pageRectInPdf),
          ),
        ),
      );
    }
    addAnnotationLayer();
    return widgets;
  }

  int? _textBlockIdAtGlobalPosition(
    Offset globalPosition, {
    required PdfPage page,
  }) {
    final documentPosition = controller.globalToDocument(globalPosition);
    final layouts = controller.layout.pageLayouts;
    final pageIndex = page.pageNumber - 1;
    if (pageIndex < 0 || pageIndex >= layouts.length) return null;
    final pageLayout = layouts[pageIndex];
    if (documentPosition == null ||
        !pageLayout.contains(documentPosition) ||
        pageLayout.width <= 0 ||
        pageLayout.height <= 0) {
      return null;
    }
    final normalized = Offset(
      (documentPosition.dx - pageLayout.left) / pageLayout.width,
      (documentPosition.dy - pageLayout.top) / pageLayout.height,
    );
    const hitPadding = .012;
    final matches = document.renderBlocks
        .where((block) {
          if (block.isFigure || block.isTable || block.isFurniture) {
            return false;
          }
          if (block.text.trim().isEmpty) return false;
          return normalized.dx >= block.x - hitPadding &&
              normalized.dx <= block.x + block.width + hitPadding &&
              normalized.dy >= block.y - hitPadding &&
              normalized.dy <= block.y + block.height + hitPadding;
        })
        .toList(growable: false);
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final aDistance =
          (Offset(a.x + a.width / 2, a.y + a.height / 2) - normalized)
              .distanceSquared;
      final bDistance =
          (Offset(b.x + b.width / 2, b.y + b.height / 2) - normalized)
              .distanceSquared;
      return aDistance.compareTo(bDistance);
    });
    return matches.first.id;
  }
}

class _PdfEditableTextRegion extends StatefulWidget {
  const _PdfEditableTextRegion({
    super.key,
    required this.block,
    required this.style,
    required this.minimumWidth,
    required this.minimumHeight,
    this.activeTextBlockIdListenable,
    required this.changed,
    required this.editableTextBuilder,
    this.onFocus,
  });

  final OcrBlock block;
  final TextStyle style;
  final double minimumWidth;
  final double minimumHeight;
  final ValueNotifier<int?>? activeTextBlockIdListenable;
  final bool changed;
  final BookPageDocumentTextBuilder editableTextBuilder;
  final VoidCallback? onFocus;

  @override
  State<_PdfEditableTextRegion> createState() => _PdfEditableTextRegionState();
}

class _PdfEditableTextRegionState extends State<_PdfEditableTextRegion> {
  bool _activated = false;
  FocusNode? _focusNode;

  @override
  void dispose() {
    widget.activeTextBlockIdListenable?.removeListener(_onActiveBlockChanged);
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode?.hasFocus ?? false) widget.onFocus?.call();
  }

  void _onActiveBlockChanged() {
    if (!mounted) return;
    final active = widget.activeTextBlockIdListenable?.value == widget.block.id;
    if (!active) {
      _disposeFocusNode();
    } else {
      _ensureFocusNode();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode?.requestFocus();
      });
    }
    setState(() {});
  }

  void _ensureFocusNode() {
    if (_focusNode != null) return;
    _focusNode = FocusNode(debugLabel: 'pdf-block-${widget.block.id}')
      ..addListener(_onFocusChanged);
    _activated = true;
  }

  void _disposeFocusNode() {
    _focusNode?.unfocus();
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode?.dispose();
    _focusNode = null;
    _activated = false;
  }

  @override
  void initState() {
    super.initState();
    widget.activeTextBlockIdListenable?.addListener(_onActiveBlockChanged);
    if (_isControlledActive) {
      _ensureFocusNode();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode?.requestFocus();
      });
    }
  }

  bool get _isControlledActive =>
      widget.activeTextBlockIdListenable?.value == widget.block.id;

  void _activate() {
    if (_activated) return;
    _ensureFocusNode();
    widget.activeTextBlockIdListenable?.value = widget.block.id;
    setState(() => _activated = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode!.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.activeTextBlockIdListenable == null ||
        widget.activeTextBlockIdListenable!.value == widget.block.id;
    if (!_activated || !active) {
      // Keep scrolling cheap: inactive fragments are hit boxes, not a full
      // TextField tree. The PDF remains the source of truth until activation.
      return PdfOverlayInteractionRegion(
        onTap: (_) {
          _activate();
          return true;
        },
        child: SizedBox(
          width: widget.minimumWidth,
          height: widget.minimumHeight,
        ),
      );
    }
    return ColoredBox(
      color: Colors.white,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: widget.minimumWidth,
          minHeight: widget.minimumHeight,
        ),
        child: widget.editableTextBuilder(
          context,
          widget.block,
          widget.style,
          _focusNode,
        ),
      ),
    );
  }
}
