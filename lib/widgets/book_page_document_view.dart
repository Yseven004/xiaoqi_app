import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../config/note_page_theme.dart';
import '../models/ocr_layout.dart';
import 'book_text_selection_controls.dart';

typedef BookPageDocumentTextBuilder =
    Widget Function(
      BuildContext context,
      OcrBlock block,
      TextStyle style,
      FocusNode? focusNode,
    );

/// 结构化书页渲染器。它只消费 [BookPageDocument]，不解释 Markdown。
class BookPageDocumentView extends StatelessWidget {
  const BookPageDocumentView({
    super.key,
    required this.document,
    this.compact = false,
    this.editableTextBuilder,
  });

  final BookPageDocument document;
  final bool compact;
  final BookPageDocumentTextBuilder? editableTextBuilder;

  @override
  Widget build(BuildContext context) {
    final headers = document.renderBlocks
        .where((block) => block.type == 'page_header')
        .toList(growable: false);
    final sidebars = document.renderBlocks
        .where((block) => block.type == 'sidebar')
        .toList(growable: false);
    final content = document.contentBlocks;
    final pageNumber = document.pageNumber?.trim() ?? '';

    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: sidebars.any((block) => block.x < .5) ? 34 : 0,
            right: sidebars.any((block) => block.x >= .5) ? 34 : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final header in headers) ...[
                Center(
                  child: Text(
                    header.text,
                    textAlign: TextAlign.center,
                    style: _styleFor(header, header: true),
                  ),
                ),
                SizedBox(height: compact ? 10 : 14),
              ],
              if (content.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Text(
                      '暂无识别内容',
                      style: TextStyle(color: NotePageTheme.muted),
                    ),
                  ),
                )
              else
                for (final block in content)
                  _BlockView(
                    block: block,
                    compact: compact,
                    editableTextBuilder: editableTextBuilder,
                  ),
              if (pageNumber.isNotEmpty) ...[
                SizedBox(height: compact ? 14 : 20),
                Center(
                  key: const Key('book_page_number'),
                  child: Text(
                    pageNumber,
                    style: const TextStyle(
                      color: NotePageTheme.muted,
                      fontSize: 12.5,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        for (var i = 0; i < sidebars.length; i++)
          Positioned(
            left: sidebars[i].x < .5 ? i * 20.0 : null,
            right: sidebars[i].x < .5 ? null : i * 20.0,
            top: 18,
            child: Text(
              sidebars[i].text
                  .replaceAll(RegExp(r'\s+'), '')
                  .split('')
                  .join('\n'),
              textAlign: TextAlign.center,
              style: _styleFor(sidebars[i], sidebar: true),
            ),
          ),
      ],
    );
  }

  static TextStyle _styleFor(
    OcrBlock block, {
    bool header = false,
    bool sidebar = false,
  }) {
    final isLight = block.isLight;
    return TextStyle(
      color: isLight || header || sidebar
          ? NotePageTheme.inkSecondary
          : NotePageTheme.bookText,
      fontSize: sidebar
          ? 12.5
          : header
          ? 13
          : block.isTitle
          ? 20
          : 16.5,
      height: sidebar
          ? 1.18
          : block.isTitle
          ? 1.5
          : 1.75,
      letterSpacing: header ? .3 : null,
      fontFamily: NotePageTheme.bookFont,
      fontWeight: block.isBold
          ? FontWeight.w700
          : isLight
          ? FontWeight.w300
          : FontWeight.w400,
      fontStyle: block.isItalic ? FontStyle.italic : FontStyle.normal,
    );
  }

  static TextStyle styleFor(OcrBlock block) => _styleFor(block);
}

class _BlockView extends StatelessWidget {
  const _BlockView({
    required this.block,
    required this.compact,
    this.editableTextBuilder,
  });

  final OcrBlock block;
  final bool compact;
  final BookPageDocumentTextBuilder? editableTextBuilder;

  @override
  Widget build(BuildContext context) {
    final text = block.text.trim();
    final style = BookPageDocumentView._styleFor(block);
    // Tables and figures keep their content outside `text`, so an empty text
    // must never hide them. Check both before the empty-text guard.
    if (block.isFigure) {
      return Padding(
        key: Key('book_page_figure_${block.id}'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: BookPageDocumentFigureView(block: block, style: style),
      );
    }
    if (block.isTable) {
      return Padding(
        key: Key('book_page_table_${block.id}'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: _TableBlockView(block: block, style: style),
      );
    }
    if (editableTextBuilder != null && !block.isFurniture) {
      return editableTextBuilder!(context, block, style, null);
    }
    if (text.isEmpty) return const SizedBox.shrink();
    if (block.type == 'quote') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          color: NotePageTheme.ochreSoft,
          border: Border.fromBorderSide(
            BorderSide(color: NotePageTheme.ochre, width: 1.2),
          ),
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        child: _IndentedText(block: block, style: style, compact: compact),
      );
    }
    if (block.type == 'list_item') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('• $text', style: style),
      );
    }
    if (block.type == 'code') {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F1F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: _IndentedText(block: block, style: style, compact: compact),
      );
    }
    return Padding(
      key: Key('book_page_block_${block.id}'),
      padding: EdgeInsets.only(
        top: block.isTitle ? 10 : 5,
        bottom: block.isTitle ? 7 : 5,
      ),
      child: _IndentedText(block: block, style: style, compact: compact),
    );
  }
}

class BookPageDocumentFigureView extends StatelessWidget {
  const BookPageDocumentFigureView({super.key, required this.block, this.style});

  final OcrBlock block;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? BookPageDocumentView._styleFor(block);
    final path = block.imageData?.trim() ?? '';
    final file = path.isEmpty || path.startsWith('data:') ? null : File(path);
    final hasLegacyCrop = file != null && file.existsSync();
    final inlineBytes = _decodeImageData(path);
    final hasInlineImage = inlineBytes != null;
    final hasScene = block.hasRenderableFigure;
    final isFormula = block.figureKind == 'formula';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 96, maxHeight: 440),
          decoration: BoxDecoration(
            color: NotePageTheme.card,
            border: Border.all(
              color: NotePageTheme.ochre.withValues(alpha: .38),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: hasScene
              ? _VectorFigureView(block: block)
              : isFormula
              ? _FormulaFigureView(block: block, style: effectiveStyle)
              : hasInlineImage
              ? Image.memory(
                  inlineBytes,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  filterQuality: FilterQuality.medium,
                  semanticLabel: block.text.trim().isEmpty
                      ? '文档图片'
                      : block.text,
                )
              : hasLegacyCrop
              ? Image.file(
                  file,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                )
              : const Padding(
                  padding: EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.insert_chart_outlined,
                        color: NotePageTheme.ochre,
                      ),
                      SizedBox(height: 6),
                      Text(
                        '图示结构提取不完整，请查看原图对照',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: NotePageTheme.muted),
                      ),
                    ],
                  ),
                ),
        ),
        if (block.text.trim().isNotEmpty && !isFormula)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(
              block.text.trim(),
              textAlign: TextAlign.center,
              style: effectiveStyle.copyWith(fontSize: 14.5, height: 1.5),
            ),
          ),
      ],
    );
  }
}

// ponytail: a small process cache avoids decoding the same inline asset on
// every rebuild; a real LRU can replace it only if many pages exceed 24 assets.
final _inlineImageCache = <String, Uint8List>{};

Uint8List? _decodeImageData(String value) {
  if (!value.startsWith('data:')) return null;
  final cached = _inlineImageCache[value];
  if (cached != null) return cached;
  final separator = value.indexOf(',');
  if (separator < 0) return null;
  try {
    final bytes = Uint8List.fromList(
      base64Decode(value.substring(separator + 1)),
    );
    if (_inlineImageCache.length >= 24) {
      _inlineImageCache.remove(_inlineImageCache.keys.first);
    }
    _inlineImageCache[value] = bytes;
    return bytes;
  } on Object {
    return null;
  }
}

class _FormulaFigureView extends StatelessWidget {
  const _FormulaFigureView({required this.block, required this.style});

  final OcrBlock block;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final storedLatex = block.attributes['latex']?.trim() ?? '';
    final latex = storedLatex.isEmpty ? block.text.trim() : storedLatex;
    if (latex.isEmpty) return const SizedBox.shrink();
    try {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Center(
          child: Math.tex(
            latex,
            mathStyle: MathStyle.display,
            textStyle: style.copyWith(fontSize: 17),
          ),
        ),
      );
    } on Object {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: SelectableText(
          block.text,
          textAlign: TextAlign.center,
          style: style.copyWith(fontSize: 15),
        ),
      );
    }
  }
}

class _VectorFigureView extends StatelessWidget {
  const _VectorFigureView({required this.block});

  final OcrBlock block;

  @override
  Widget build(BuildContext context) {
    final labels = block.figureElements
        .where((element) => element.isText)
        .map((element) => element.text.trim())
        .where((text) => text.isNotEmpty)
        .join('，');
    return Semantics(
      image: true,
      label: labels.isEmpty ? '结构化图示' : '结构化图示：$labels',
      child: AspectRatio(
        aspectRatio: block.figureAspectRatio,
        child: CustomPaint(
          key: Key('book_page_vector_figure_${block.id}'),
          painter: _FigureScenePainter(block.figureElements),
        ),
      ),
    );
  }
}

class _FigureScenePainter extends CustomPainter {
  const _FigureScenePainter(this.elements);

  final List<FigureElement> elements;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = math.max(8.0, math.min(size.width, size.height) * .035);
    final area = Rect.fromLTWH(
      inset,
      inset,
      math.max(1, size.width - inset * 2),
      math.max(1, size.height - inset * 2),
    );
    for (final element in elements) {
      if (element.isText) {
        _paintText(canvas, area, element);
      } else {
        _paintShape(canvas, area, element);
      }
    }
  }

  void _paintShape(Canvas canvas, Rect area, FigureElement element) {
    final stroke = Paint()
      ..color = NotePageTheme.bookText
      ..style = element.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = element.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rect = Rect.fromLTWH(
      area.left + element.x * area.width,
      area.top + element.y * area.height,
      element.width * area.width,
      element.height * area.height,
    );
    switch (element.kind) {
      case 'rect':
        canvas.drawRect(rect, stroke);
        break;
      case 'rounded_rect':
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          stroke,
        );
        break;
      case 'ellipse':
        canvas.drawOval(rect, stroke);
        break;
      case 'line':
      case 'arrow':
      case 'polyline':
      case 'curve':
        final points = [
          for (final point in element.points)
            Offset(
              area.left + point.x * area.width,
              area.top + point.y * area.height,
            ),
        ];
        if (points.length < 2) return;
        final path = element.kind == 'curve'
            ? _smoothPath(points)
            : (Path()..moveTo(points.first.dx, points.first.dy));
        if (element.kind != 'curve') {
          for (final point in points.skip(1)) {
            path.lineTo(point.dx, point.dy);
          }
        }
        canvas.drawPath(path, stroke);
        if (element.kind == 'arrow') {
          _paintArrowHead(
            canvas,
            points[points.length - 2],
            points.last,
            stroke,
          );
        }
        break;
      default:
        break;
    }
  }

  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length - 1; index++) {
      final current = points[index];
      final next = points[index + 1];
      final midpoint = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, midpoint.dx, midpoint.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  void _paintArrowHead(Canvas canvas, Offset before, Offset tip, Paint paint) {
    final angle = math.atan2(tip.dy - before.dy, tip.dx - before.dx);
    const length = 8.0;
    const spread = .55;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        tip.dx - length * math.cos(angle - spread),
        tip.dy - length * math.sin(angle - spread),
      )
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        tip.dx - length * math.cos(angle + spread),
        tip.dy - length * math.sin(angle + spread),
      );
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  void _paintText(Canvas canvas, Rect area, FigureElement element) {
    final rect = Rect.fromLTWH(
      area.left + element.x * area.width,
      area.top + element.y * area.height,
      math.max(1, element.width * area.width),
      math.max(1, element.height * area.height),
    );
    final align = switch (element.textAlign) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      _ => TextAlign.center,
    };
    var fontSize = switch (element.textRole) {
      'title' => 16.0,
      'caption' => 12.0,
      'secondary' => 11.0,
      _ => 13.0,
    };
    late TextPainter painter;
    do {
      painter = TextPainter(
        text: TextSpan(
          text: element.text,
          style: TextStyle(
            color: element.textRole == 'secondary'
                ? NotePageTheme.inkSecondary
                : NotePageTheme.bookText,
            fontFamily: NotePageTheme.bookFont,
            fontSize: fontSize,
            height: 1.2,
            fontWeight: element.textRole == 'title'
                ? FontWeight.w700
                : FontWeight.w400,
          ),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width);
      fontSize -= 1;
    } while (fontSize >= 8 && painter.height > rect.height);
    final top = rect.top + math.max(0, (rect.height - painter.height) / 2);
    painter.paint(canvas, Offset(rect.left, top));
  }

  @override
  bool shouldRepaint(covariant _FigureScenePainter oldDelegate) =>
      oldDelegate.elements != elements;
}

/// Keeps cells that share a source row together. A table that is wider than a
/// phone remains horizontally scrollable instead of being flattened into a
/// vertical sequence of unrelated paragraphs.
class _TableBlockView extends StatelessWidget {
  const _TableBlockView({required this.block, required this.style});

  final OcrBlock block;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final rows = block.tableRows;
    final columnCount = rows.fold<int>(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    if (columnCount == 0) return const SizedBox.shrink();

    return Semantics(
      label: '表格，共 ${rows.length} 行 $columnCount 列',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          // Two-column comparisons fit the page. Three or more columns retain
          // a legible cell width and may scroll sideways on a narrow phone.
          final minimumWidth = columnCount <= 2
              ? availableWidth
              : columnCount * 108.0;
          final tableWidth = availableWidth > minimumWidth
              ? availableWidth
              : minimumWidth;
          final columnWidth = tableWidth / columnCount;
          return DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: NotePageTheme.ochre.withValues(alpha: .4),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SingleChildScrollView(
                key: Key('book_page_table_scroll_${block.id}'),
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: tableWidth,
                  child: Table(
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    columnWidths: {
                      for (var index = 0; index < columnCount; index++)
                        index: FixedColumnWidth(columnWidth),
                    },
                    border: TableBorder.symmetric(
                      inside: BorderSide(
                        color: NotePageTheme.ochre.withValues(alpha: .26),
                      ),
                    ),
                    children: [
                      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                        TableRow(
                          decoration: rowIndex < block.tableHeaderRowCount
                              ? const BoxDecoration(
                                  color: NotePageTheme.ochreSoft,
                                )
                              : null,
                          children: [
                            for (
                              var columnIndex = 0;
                              columnIndex < columnCount;
                              columnIndex++
                            )
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 8,
                                ),
                                child: Text(
                                  columnIndex < rows[rowIndex].length
                                      ? rows[rowIndex][columnIndex]
                                      : '',
                                  style: style.copyWith(
                                    fontSize: 14.5,
                                    height: 1.5,
                                    fontWeight:
                                        rowIndex < block.tableHeaderRowCount
                                        ? FontWeight.w700
                                        : style.fontWeight,
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IndentedText extends StatelessWidget {
  const _IndentedText({
    required this.block,
    required this.style,
    required this.compact,
  });

  final OcrBlock block;
  final TextStyle style;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final indentWidth = block.firstLineIndent > 0
        ? (style.fontSize ?? 16) * block.firstLineIndent
        : 0.0;
    final textSpan = TextSpan(
      children: [
        if (indentWidth > 0) WidgetSpan(child: SizedBox(width: indentWidth)),
        TextSpan(text: block.text.trim(), style: style),
      ],
    );

    // SelectableText.rich deliberately receives only TextSpan children. A
    // WidgetSpan cannot participate in Flutter's text selection model, so
    // indented legacy blocks retain their static renderer while normal book
    // paragraphs gain the custom pencil handles and E-style dark selection.
    if (compact || indentWidth > 0) {
      return Text.rich(textSpan, softWrap: true);
    }
    return SelectableText.rich(
      textSpan,
      showCursor: true,
      cursorColor: BookPencilTextSelectionControls.cursorColor,
      cursorWidth: 1.5,
      cursorRadius: Radius.zero,
      selectionColor: BookPencilTextSelectionControls.selectionColor,
      selectionControls: bookPencilTextSelectionControls,
      selectionHeightStyle: ui.BoxHeightStyle.tight,
      selectionWidthStyle: ui.BoxWidthStyle.tight,
      enableInteractiveSelection: true,
    );
  }
}
