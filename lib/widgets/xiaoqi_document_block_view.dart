import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../config/note_page_theme.dart';
import '../models/ocr_layout.dart';
import '../models/xiaoqi_document.dart';
import 'book_page_document_view.dart';

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
    this.tableRowsOverride,
    this.continuation = false,
    this.onSelectionChanged,
    this.editable = false,
    this.controller,
    this.onTextChanged,
  });

  final XiaoqiDocumentBlock block;
  final XiaoqiDocumentAsset? asset;
  final String? textOverride;
  final List<List<String>>? tableRowsOverride;
  final bool continuation;
  final ValueChanged<bool>? onSelectionChanged;
  final bool editable;
  final TextEditingController? controller;
  final ValueChanged<String>? onTextChanged;

  @override
  Widget build(BuildContext context) {
    final text = textOverride ?? block.text;
    switch (block.kind) {
      case 'heading':
        return _textSurface(
          text,
          style: TextStyle(
            color: NotePageTheme.ink,
            fontSize: block.level <= 1 ? 21 : 18,
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
        );
      case 'list_item':
        return _textSurface(
          continuation ? text : '• $text',
          style: const TextStyle(
            color: NotePageTheme.bookText,
            fontSize: 17,
            height: 1.6,
          ),
          padding: const EdgeInsets.only(bottom: 8),
          editableText: text,
        );
      case 'quote':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: NotePageTheme.gold, width: 3)),
            color: NotePageTheme.soft,
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
            color: const Color(0xFFF0F1F2),
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
          onSelectionChanged: onSelectionChanged,
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
        return XiaoqiDocumentImageBlock(
          block: block,
          asset: asset,
          textOverride: textOverride,
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
  }) => Padding(
    padding: padding,
    child: _textFieldOrSelectable(editableText ?? text, style),
  );

  Widget _textFieldOrSelectable(String text, TextStyle style) {
    if (editable && controller != null) {
      return TextField(
        controller: controller,
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
    return SelectableText(
      text,
      style: style,
      onSelectionChanged: (selection, _) =>
          onSelectionChanged?.call(!selection.isCollapsed),
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
    this.onSelectionChanged,
  });

  final XiaoqiDocumentBlock block;
  final String? textOverride;
  final List<List<String>>? rowsOverride;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final rawRows = rowsOverride ?? _decodeRows(block);
    if (rawRows == null || rawRows.isEmpty) {
      return _fallback(textOverride ?? block.text);
    }
    final columnCount = rawRows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border.all(color: NotePageTheme.lineStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Table(
        border: TableBorder.symmetric(
          inside: BorderSide(color: NotePageTheme.lineStrong),
        ),
        children: [
          for (final row in rawRows)
            TableRow(
              children: [
                for (var index = 0; index < columnCount; index++)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      index < row.length ? row[index] : '',
                      style: const TextStyle(
                        color: NotePageTheme.bookText,
                        fontSize: 15,
                        height: 1.45,
                      ),
                      onSelectionChanged: (selection, _) =>
                          onSelectionChanged?.call(!selection.isCollapsed),
                    ),
                  ),
              ],
            ),
        ],
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
      style: const TextStyle(
        color: NotePageTheme.bookText,
        fontSize: 16,
        height: 1.55,
      ),
      onSelectionChanged: (selection, _) =>
          onSelectionChanged?.call(!selection.isCollapsed),
    ),
  );
}

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

List<List<String>>? _decodeRows(XiaoqiDocumentBlock block) {
  final rawRows = block.attributes['rows'];
  if (rawRows == null) return null;
  try {
    final decoded = jsonDecode(rawRows);
    if (decoded is! List) return null;
    final rows = decoded
        .whereType<List>()
        .map((row) => row.map((cell) => cell.toString()).toList(growable: false))
        .where((row) => row.isNotEmpty)
        .toList(growable: false);
    return rows.isEmpty ? null : rows;
  } on Object {
    return null;
  }
}
