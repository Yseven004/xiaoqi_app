import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../config/note_page_theme.dart';
import '../models/ocr_layout.dart';
import '../models/xiaoqi_document.dart';
import 'book_page_document_view.dart';
import 'document_text_style.dart';
import 'reader_paper_turn.dart';

/// The single visual contract for reflowable document blocks.
///
/// Reader and editor pages intentionally use this widget so that adding an
/// editable surface cannot silently replace images, tables, or formulas with
/// plain text. Text editing is opt-in; non-text blocks remain visible even
/// when they are read-only.
class XiaoqiDocumentBlockView extends StatelessWidget {
  const XiaoqiDocumentBlockView({
    super.key,
    required this.block,
    this.asset,
    this.textOverride,
    this.textOffset,
    this.tableRowsOverride,
    this.continuation = false,
    this.onSelectionChanged,
    this.onTextTap,
    this.onLinkTap,
    this.headingColor,
    this.darkReader = false,
    this.onObjectPreview,
    this.contextMenuBuilder,
    this.selectionControls,
    this.textStyleBuilder,
    this.annotationRanges = const [],
    this.onOpenAnnotations,
    this.editable = false,
    this.controller,
    this.onTextChanged,
  });

  final XiaoqiDocumentBlock block;
  final XiaoqiDocumentAsset? asset;
  final String? textOverride;
  final int? textOffset;
  final List<List<String>>? tableRowsOverride;
  final bool continuation;
  final ValueChanged<bool>? onSelectionChanged;
  final VoidCallback? onTextTap;
  final ValueChanged<String>? onLinkTap;
  final Color? headingColor;
  final bool darkReader;
  final VoidCallback? onObjectPreview;

  Color? get _emphasisColor => darkReader ? const Color(0xFFFFFCF4) : null;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextSelectionControls? selectionControls;
  final TextStyle Function(TextStyle)? textStyleBuilder;

  /// Half-open offsets in the text displayed by this widget, including slices.
  final List<({int start, int end, String id})> annotationRanges;
  final ValueChanged<List<String>>? onOpenAnnotations;
  final bool editable;
  final TextEditingController? controller;
  final ValueChanged<String>? onTextChanged;

  bool get _centeredHeading =>
      block.kind == 'heading' && block.attributes['textAlign'] == 'center';

  @override
  Widget build(BuildContext context) {
    final text = textOverride ?? block.text;
    switch (block.kind) {
      case 'heading':
        return Semantics(
          headingLevel: continuation ? null : block.level.clamp(1, 6).toInt(),
          child: _textSurface(
            text,
            style: TextStyle(
              color: NotePageTheme.ink,
              fontSize: documentHeadingFontSize(block),
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
            padding: EdgeInsets.only(
              top: continuation
                  ? 0
                  : block.level <= 1
                  ? 8
                  : 14,
              bottom: 6,
            ),
          ),
        );
      case 'list_item':
        const listStyle = TextStyle(
          color: NotePageTheme.bookText,
          fontSize: 17,
          height: 1.6,
        );
        final prefix = documentListPrefix(block, continuation);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (prefix.isNotEmpty)
                Text(
                  prefix,
                  style: textStyleBuilder?.call(listStyle) ?? listStyle,
                ),
              Expanded(child: _textFieldOrSelectable(text, listStyle)),
            ],
          ),
        );
      case 'caption':
        return _textSurface(
          text,
          style: const TextStyle(
            color: NotePageTheme.inkSecondary,
            fontSize: 14,
            height: 1.45,
          ),
          padding: const EdgeInsets.only(bottom: 12),
        );
      case 'quote':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: darkReader
                    ? const Color(0xFFC8AA69)
                    : NotePageTheme.gold,
                width: 3,
              ),
            ),
            color: darkReader ? const Color(0xFF383124) : NotePageTheme.soft,
          ),
          child: _textFieldOrSelectable(
            text,
            const TextStyle(
              color: NotePageTheme.bookText,
              fontSize: 16,
              height: 1.6,
            ),
          ),
        );
      case 'code':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color(darkReader ? 0xFF262A30 : 0xFFF0F1F2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: _textFieldOrSelectable(
            text,
            const TextStyle(
              color: NotePageTheme.ink,
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.5,
            ),
          ),
        );
      case 'divider':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(color: NotePageTheme.lineStrong),
        );
      case 'table':
        return XiaoqiDocumentTableBlock(
          block: block,
          textOverride: textOverride,
          rowsOverride: tableRowsOverride,
          rowOffset: textOffset ?? 0,
          onPreview: onObjectPreview,
          textStyleBuilder: textStyleBuilder,
          onLinkTap: onLinkTap,
          onSelectionChanged: onSelectionChanged,
          contextMenuBuilder: contextMenuBuilder,
        );
      case 'math':
      case 'formula':
        return _MathBlock(block: block, text: text);
      case 'chart':
        final figure = _chartFigureBlock(block);
        if (figure != null) {
          return BookPageDocumentFigureView(block: figure);
        }
        return XiaoqiDocumentImageBlock(
          block: block,
          asset: asset,
          textOverride: textOverride,
        );
      case 'image':
      case 'figure':
        final image = XiaoqiDocumentImageBlock(
          block: block,
          asset: asset,
          textOverride: textOverride,
        );
        final link = block.attributes['imageLink'];
        final followLink = link == null || onLinkTap == null
            ? null
            : () => onLinkTap!(link);
        final preview = onObjectPreview;
        if (followLink == null) {
          return preview == null
              ? image
              : Semantics(
                  button: true,
                  label: '预览图片',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: preview,
                    child: image,
                  ),
                );
        }
        final linkedImage = Semantics(
          link: true,
          child: InkWell(onTap: followLink, child: image),
        );
        if (preview == null) return linkedImage;
        return Stack(
          children: [
            linkedImage,
            PositionedDirectional(
              top: 6,
              end: 6,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: '预览图片',
                  onPressed: preview,
                  icon: SvgPicture.asset(
                    'assets/images/home_composer_expand.svg',
                    width: 18,
                    height: 18,
                    colorFilter: const ColorFilter.mode(
                      Color(0xFF262626),
                      BlendMode.srcIn,
                    ),
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
          ],
        );
      default:
        return _textSurface(
          text,
          style: const TextStyle(
            color: NotePageTheme.bookText,
            fontSize: 17,
            height: 1.7,
          ),
          padding: const EdgeInsets.only(bottom: 12),
        );
    }
  }

  Widget _textSurface(
    String text, {
    required TextStyle style,
    required EdgeInsets padding,
    String? editableText,
  }) {
    final child = _textFieldOrSelectable(editableText ?? text, style);
    return Padding(
      padding: padding,
      child: _centeredHeading
          ? SizedBox(
              width: double.infinity,
              child: DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                child: child,
              ),
            )
          : child,
    );
  }

  Widget _textFieldOrSelectable(String text, TextStyle style) {
    if (editable && controller != null) {
      return TextField(
        controller: controller,
        textAlign: _centeredHeading ? TextAlign.center : TextAlign.start,
        minLines: 1,
        maxLines: null,
        style: style,
        onChanged: onTextChanged,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      );
    }
    final mappedStyle = textStyleBuilder?.call(style) ?? style;
    final effectiveStyle = block.kind == 'heading' && headingColor != null
        ? mappedStyle.copyWith(color: headingColor)
        : mappedStyle;
    final offset = textOffset ?? (text == block.text ? 0 : null);
    final ranges = offset == null
        ? const <DocumentBoldRange>[]
        : block.boldRanges;
    void selectionChanged(TextSelection selection, SelectionChangedCause? _) =>
        onSelectionChanged?.call(!selection.isCollapsed);
    final links = offset == null || onLinkTap == null
        ? const <DocumentLinkRange>[]
        : block.linkRanges;
    if (links.isNotEmpty || annotationRanges.isNotEmpty) {
      return _LinkedDocumentText(
        text: text,
        offset: offset ?? 0,
        bold: ranges,
        emphasisColor: _emphasisColor,
        links: links,
        style: effectiveStyle,
        onLinkTap: onLinkTap,
        onTextTap: onTextTap,
        selectionControls: selectionControls,
        contextMenuBuilder: contextMenuBuilder,
        onSelectionChanged: selectionChanged,
        annotations: annotationRanges,
        onOpenAnnotations: onOpenAnnotations,
      );
    }
    if (ranges.isNotEmpty) {
      return SelectableText.rich(
        documentTextSpan(
          text,
          effectiveStyle,
          ranges,
          offset!,
          emphasisColor: _emphasisColor,
        ),
        onTap: onTextTap,
        selectionControls: selectionControls,
        contextMenuBuilder: contextMenuBuilder ?? _standardDocumentContextMenu,
        onSelectionChanged: selectionChanged,
      );
    }
    return SelectableText(
      text,
      onTap: onTextTap,
      selectionControls: selectionControls,
      style: effectiveStyle,
      contextMenuBuilder: contextMenuBuilder ?? _standardDocumentContextMenu,
      onSelectionChanged: selectionChanged,
    );
  }
}

class _LinkedDocumentText extends StatefulWidget {
  const _LinkedDocumentText({
    required this.text,
    required this.offset,
    required this.bold,
    this.emphasisColor,
    required this.links,
    required this.style,
    required this.onLinkTap,
    required this.onTextTap,
    required this.selectionControls,
    required this.contextMenuBuilder,
    required this.onSelectionChanged,
    this.annotations = const [],
    this.onOpenAnnotations,
  });
  final String text;
  final int offset;
  final List<DocumentBoldRange> bold;
  final Color? emphasisColor;
  final List<DocumentLinkRange> links;
  final TextStyle style;
  final ValueChanged<String>? onLinkTap;
  final VoidCallback? onTextTap;
  final TextSelectionControls? selectionControls;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SelectionChangedCallback onSelectionChanged;
  final List<({int start, int end, String id})> annotations;
  final ValueChanged<List<String>>? onOpenAnnotations;

  @override
  State<_LinkedDocumentText> createState() => _LinkedDocumentTextState();
}

/// The PDF translation uses a single selectable page so cross-sentence text
/// gestures keep their existing behavior.
class CompanionAnnotationTextView extends StatelessWidget {
  const CompanionAnnotationTextView({
    required this.text,
    required this.style,
    required this.annotations,
    required this.onOpenAnnotations,
    required this.onSelectionChanged,
    this.onTap,
    this.selectionControls,
    this.contextMenuBuilder,
    super.key,
  });

  final String text;
  final TextStyle style;
  final List<({int start, int end, String id})> annotations;
  final ValueChanged<List<String>>? onOpenAnnotations;
  final SelectionChangedCallback onSelectionChanged;
  final VoidCallback? onTap;
  final TextSelectionControls? selectionControls;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  Widget build(BuildContext context) => _LinkedDocumentText(
    text: text,
    offset: 0,
    bold: const [],
    links: const [],
    style: style,
    onLinkTap: null,
    onTextTap: onTap,
    selectionControls: selectionControls,
    contextMenuBuilder: contextMenuBuilder,
    onSelectionChanged: onSelectionChanged,
    annotations: annotations,
    onOpenAnnotations: onOpenAnnotations,
  );
}

class _LinkedDocumentTextState extends State<_LinkedDocumentText> {
  final recognizers = <String, TapGestureRecognizer>{};
  @override
  void dispose() {
    for (final r in recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.offset, end = start + widget.text.length;
    final links = widget.links
        .where((r) => r.start < end && r.end > start)
        .toList();
    final bold = widget.bold
        .where((r) => r.start < end && r.end > start)
        .toList();
    final annotations = [
      for (final range in widget.annotations)
        if (range.start < widget.text.length && range.end > 0)
          (start: start + range.start, end: start + range.end, id: range.id),
    ];
    final activeRecognizers = <String>{};
    final boundaries = <int>{start, end};
    for (final r in [
      ...bold,
      ...links.map((r) => (start: r.start, end: r.end)),
      ...annotations.map((r) => (start: r.start, end: r.end)),
    ]) {
      boundaries.add(r.start.clamp(start, end));
      boundaries.add(r.end.clamp(start, end));
    }
    final sorted = boundaries.toList()..sort();
    final children = <TextSpan>[];
    for (var i = 1; i < sorted.length; i++) {
      final from = sorted[i - 1], to = sorted[i];
      final target = links
          .where((r) => r.start <= from && r.end >= to)
          .firstOrNull
          ?.target;
      final strong = bold.any((r) => r.start <= from && r.end >= to);
      final annotationIds = [
        for (final range in annotations)
          if (range.start <= from && range.end >= to) range.id,
      ];
      final annotated = annotationIds.isNotEmpty;
      TapGestureRecognizer? tap;
      if (target != null && annotated && widget.onOpenAnnotations != null) {
        final key =
            'linked-annotation:${jsonEncode([target, ...annotationIds])}';
        activeRecognizers.add(key);
        tap = recognizers.putIfAbsent(key, TapGestureRecognizer.new)
          ..onTap = () async {
            final openAnnotation = await showModalBottomSheet<bool>(
              context: context,
              builder: (context) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: const Text('查看注释'),
                      onTap: () => Navigator.pop(context, true),
                    ),
                    ListTile(
                      title: const Text('打开链接'),
                      onTap: () => Navigator.pop(context, false),
                    ),
                  ],
                ),
              ),
            );
            if (!mounted) return;
            if (openAnnotation == true) {
              widget.onOpenAnnotations?.call(annotationIds);
            } else if (openAnnotation == false) {
              widget.onLinkTap?.call(target);
            }
          };
      } else if (target != null) {
        final key = 'link:$target';
        activeRecognizers.add(key);
        tap = recognizers.putIfAbsent(key, TapGestureRecognizer.new)
          ..onTap = () => widget.onLinkTap?.call(target);
      } else if (annotated && widget.onOpenAnnotations != null) {
        final key = 'annotation:${annotationIds.join(',')}';
        activeRecognizers.add(key);
        tap = recognizers.putIfAbsent(key, TapGestureRecognizer.new)
          ..onTap = () => widget.onOpenAnnotations?.call(annotationIds);
      }
      children.add(
        TextSpan(
          text: widget.text.substring(from - start, to - start),
          recognizer: tap,
          style: TextStyle(
            fontWeight: strong ? FontWeight.w700 : null,
            decoration: target != null || annotated
                ? TextDecoration.underline
                : null,
            decorationStyle: annotated ? TextDecorationStyle.dashed : null,
            decorationColor: annotated ? const Color(0xFFA4BD83) : null,
            color: target == null
                ? (strong ? widget.emphasisColor : null)
                : ThemeData.estimateBrightnessForColor(
                        widget.style.color ?? Colors.black,
                      ) ==
                      Brightness.light
                ? const Color(0xFF91BBFF)
                : const Color(0xFF255898),
          ),
        ),
      );
    }
    for (final key
        in recognizers.keys
            .where((key) => !activeRecognizers.contains(key))
            .toList()) {
      recognizers.remove(key)?.dispose();
    }
    return SelectableText.rich(
      TextSpan(style: widget.style, children: children),
      onTap: widget.onTextTap,
      selectionControls: widget.selectionControls,
      contextMenuBuilder:
          widget.contextMenuBuilder ?? _standardDocumentContextMenu,
      onSelectionChanged: widget.onSelectionChanged,
    );
  }
}

OcrBlock? _chartFigureBlock(XiaoqiDocumentBlock block) {
  final raw = block.attributes['figure_elements'];
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final elements = [
      for (final item in decoded)
        if (item is Map)
          FigureElement.fromJson(Map<String, dynamic>.from(item)),
    ];
    if (!elements.any((element) => element.isDrawable)) return null;
    return OcrBlock(
      id: 1,
      text: block.text,
      type: 'chart',
      x: .08,
      y: .08,
      width: .84,
      height: .3,
      figureKind: 'chart',
      figureElements: elements,
    );
  } on Object {
    return null;
  }
}

class XiaoqiDocumentTableBlock extends StatelessWidget {
  const XiaoqiDocumentTableBlock({
    super.key,
    required this.block,
    this.textOverride,
    this.rowsOverride,
    this.rowOffset = 0,
    this.onPreview,
    this.onLinkTap,
    this.textStyleBuilder,
    this.onSelectionChanged,
    this.contextMenuBuilder,
  });

  final XiaoqiDocumentBlock block;
  final String? textOverride;
  final List<List<String>>? rowsOverride;
  final int rowOffset;
  final VoidCallback? onPreview;
  final ValueChanged<String>? onLinkTap;
  final TextStyle Function(TextStyle)? textStyleBuilder;
  final ValueChanged<bool>? onSelectionChanged;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    final rawRows = rowsOverride ?? documentTableRows(block);
    if (rawRows == null || rawRows.isEmpty) {
      return _fallback(textOverride ?? block.text);
    }
    final columnCount = rawRows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final headerRows = int.tryParse(block.attributes['headerRows'] ?? '') ?? 0;
    const base = TextStyle(
      color: NotePageTheme.bookText,
      fontSize: 15,
      height: 1.45,
    );
    final style = textStyleBuilder?.call(base) ?? base;
    final rawLinks = block.attributes['cellLinks'];
    Map links = const {};
    if (rawLinks != null) {
      try {
        final parsed = jsonDecode(rawLinks);
        if (parsed is Map) links = parsed;
      } on FormatException {
        /* Older edits may lack valid ranges. */
      }
    }
    Widget cell(int row, int column) {
      final text = column < rawRows[row].length ? rawRows[row][column] : '';
      final cellStyle = row + rowOffset < headerRows
          ? style.copyWith(fontWeight: FontWeight.w700)
          : style;
      final ranges = links['${row + rowOffset}:$column'];
      void selection(TextSelection value, SelectionChangedCause? _) =>
          onSelectionChanged?.call(!value.isCollapsed);
      final marked = ranges is List
          ? [
              for (final item in ranges)
                if (item case [
                  final int s,
                  final int e,
                  final String target,
                ] when s >= 0 && s < e && e <= text.length)
                  (start: s, end: e, target: target),
            ]
          : const <DocumentLinkRange>[];
      return Padding(
        padding: const EdgeInsets.all(10),
        child: marked.isEmpty || onLinkTap == null
            ? SelectableText(
                text,
                style: cellStyle,
                onTap: onPreview,
                contextMenuBuilder:
                    contextMenuBuilder ?? _standardDocumentContextMenu,
                onSelectionChanged: selection,
              )
            : _LinkedDocumentText(
                text: text,
                offset: 0,
                bold: const [],
                links: marked,
                style: cellStyle,
                onLinkTap: onLinkTap!,
                onTextTap: onPreview,
                selectionControls: null,
                contextMenuBuilder: contextMenuBuilder,
                onSelectionChanged: selection,
              ),
      );
    }

    final table = Table(
      border: TableBorder.all(color: NotePageTheme.lineStrong),
      children: [
        for (var r = 0; r < rawRows.length; r++)
          TableRow(
            children: [for (var c = 0; c < columnCount; c++) cell(r, c)],
          ),
      ],
    );
    final scrollingTable = LayoutBuilder(
      builder: (_, bounds) {
        final minWidth = columnCount * 96.0;
        if (!bounds.hasBoundedWidth || minWidth <= bounds.maxWidth) {
          return table;
        }
        return ReaderPaperTurnLocalDrag(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minWidth, child: table),
          ),
        );
      },
    );
    final preview = onPreview;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: preview == null
          ? scrollingTable
          : Semantics(
              button: true,
              label: '预览表格',
              onTap: preview,
              child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: preview,
                child: scrollingTable,
              ),
            ),
    );
  }

  Widget _fallback(String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NotePageTheme.soft,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: NotePageTheme.lineStrong),
    ),
    child: SelectableText(
      text,
      onTap: onPreview,
      style: const TextStyle(
        color: NotePageTheme.bookText,
        fontSize: 16,
        height: 1.55,
      ),
      contextMenuBuilder: contextMenuBuilder ?? _standardDocumentContextMenu,
      onSelectionChanged: (selection, _) =>
          onSelectionChanged?.call(!selection.isCollapsed),
    ),
  );
}

Widget _standardDocumentContextMenu(
  BuildContext context,
  EditableTextState editable,
) => AdaptiveTextSelectionToolbar.editableText(editableTextState: editable);

class XiaoqiDocumentImageBlock extends StatelessWidget {
  const XiaoqiDocumentImageBlock({
    super.key,
    required this.block,
    required this.asset,
    this.textOverride,
  });

  final XiaoqiDocumentBlock block;
  final XiaoqiDocumentAsset? asset;
  final String? textOverride;

  @override
  Widget build(BuildContext context) {
    final currentAsset = asset;
    if (currentAsset == null || currentAsset.bytes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          (textOverride ?? block.text).isEmpty
              ? '文档图片暂时无法显示'
              : (textOverride ?? block.text),
          style: const TextStyle(color: NotePageTheme.inkSecondary),
        ),
      );
    }
    if (currentAsset.mimeType == 'image/svg+xml') {
      final bytes = currentAsset.bytes;
      final ratio =
          double.tryParse(block.attributes['aspectRatio'] ?? '') ?? 1.5;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AspectRatio(
          aspectRatio: ratio.isFinite && ratio > 0 ? ratio : 1.5,
          child: ColoredBox(
            color: Colors.white,
            child: SvgPicture.memory(
              bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
              fit: BoxFit.contain,
              semanticsLabel: currentAsset.altText.isEmpty
                  ? '文档插图'
                  : currentAsset.altText,
              errorBuilder: (_, _, _) => Text(
                currentAsset.altText.isEmpty
                    ? '文档图片暂时无法显示'
                    : currentAsset.altText,
              ),
            ),
          ),
        ),
      );
    }
    final aspect = double.tryParse(block.attributes['aspectRatio'] ?? '');
    if (aspect != null && aspect.isFinite && aspect > 0) {
      final bytes = currentAsset.bytes;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Image.memory(
            bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
            fit: BoxFit.contain,
            semanticLabel: currentAsset.altText,
            errorBuilder: (_, _, _) => const Text('文档图片暂时无法显示'),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: NotePageTheme.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image.memory(
              Uint8List.fromList(currentAsset.bytes),
              fit: BoxFit.contain,
              width: double.infinity,
              semanticLabel: currentAsset.altText.trim().isEmpty
                  ? '文档图片'
                  : currentAsset.altText,
              errorBuilder: (_, _, _) => const Text('文档图片暂时无法显示'),
            ),
          ),
          if (currentAsset.altText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              currentAsset.altText,
              style: const TextStyle(
                color: NotePageTheme.inkSecondary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MathBlock extends StatelessWidget {
  const _MathBlock({required this.block, required this.text});

  final XiaoqiDocumentBlock block;
  final String text;

  @override
  Widget build(BuildContext context) {
    final latex = block.attributes['latex']?.trim() ?? text.trim();
    if (latex.isEmpty) return const SizedBox.shrink();
    try {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Center(
          child: Math.tex(
            latex,
            mathStyle: MathStyle.display,
            textStyle: const TextStyle(fontSize: 17),
          ),
        ),
      );
    } on Object {
      return SelectableText(
        text,
        style: const TextStyle(color: NotePageTheme.inkSecondary),
      );
    }
  }
}

List<List<String>>? documentTableRows(XiaoqiDocumentBlock block) {
  final rawRows = block.attributes['rows'];
  if (rawRows == null) return null;
  try {
    final decoded = jsonDecode(rawRows);
    if (decoded is! List) return null;
    final rows = decoded
        .whereType<List>()
        .map(
          (row) => row.map((cell) => cell.toString()).toList(growable: false),
        )
        .where((row) => row.isNotEmpty)
        .toList(growable: false);
    return rows.isEmpty ? null : rows;
  } on Object {
    return null;
  }
}
