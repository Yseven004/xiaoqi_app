import 'package:flutter/painting.dart';

import '../models/xiaoqi_document.dart';

String documentListPrefix(XiaoqiDocumentBlock block, bool continuation) {
  if (block.kind != 'list_item') return '';
  final level = (int.tryParse(block.attributes['listDepth'] ?? '') ?? 0).clamp(
    0,
    8,
  );
  final indent = '　' * level;
  final mark = block.attributes['listMarker'] ?? '•';
  return continuation ? indent : '$indent$mark ';
}

double documentHeadingFontSize(XiaoqiDocumentBlock block) {
  if (!block.id.startsWith('pdf-page-')) return block.level <= 1 ? 21 : 18;
  return switch (block.level) {
    <= 1 => 24,
    2 => 21,
    3 => 19,
    _ => 18,
  };
}

TextSpan documentTextSpan(
  String text,
  TextStyle style,
  List<DocumentBoldRange> ranges,
  int textOffset, {
  Color? emphasisColor,
}) {
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  final children = <TextSpan>[];
  var cursor = 0;
  for (final range in ranges) {
    final start = (range.start - textOffset).clamp(cursor, text.length).toInt();
    final end = (range.end - textOffset).clamp(start, text.length).toInt();
    if (end == start) continue;
    if (start > cursor) {
      children.add(TextSpan(text: text.substring(cursor, start)));
    }
    children.add(
      TextSpan(
        text: text.substring(start, end),
        style: TextStyle(fontWeight: FontWeight.w700, color: emphasisColor),
      ),
    );
    cursor = end;
  }
  if (cursor < text.length) {
    children.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: style, children: children);
}
