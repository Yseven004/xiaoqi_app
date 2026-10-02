import '../../models/ocr_layout.dart';

/// 兼容 Markdown ⇄ [OcrBlock] 双向转换器。
///
/// 识别插件的主输出是 [BookPageDocument]；历史数据、导出和旧插件仍需要：
/// - [fromMarkdown]：把识别结果解析为顺序块（标题/列表/引用/段落）。
///   坐标不做 1:1 还原，按阅读顺序自上而下均匀布局（兼容降级模式）。
/// - [toMarkdown]：用户编辑块文本后拼回 Markdown，落库与展示保持同源。
class MarkdownBlocksCodec {
  MarkdownBlocksCodec._();

  static const double _marginX = 0.08;
  static const double _blockHeight = 0.05;
  static const double _blockGap = 0.015;

  static const _titlePrefixes = [
    '# ',
    '## ',
    '### ',
    '#### ',
    '##### ',
    '###### ',
  ];

  /// 把整页 Markdown 按行解析为顺序 [OcrBlock] 列表。
  ///
  /// 空行合并为相邻块之间的间隔；行内文字（含 emoji）原样保留，不做任何
  /// 改写或过滤。无法识别的行一律归为 paragraph，保证不丢内容。
  static List<OcrBlock> fromMarkdown(String markdown) {
    final blocks = <OcrBlock>[];
    var pendingText = <String>[];
    var pendingType = 'paragraph';
    var pendingFirstLineIndent = 0;

    void flush() {
      if (pendingText.isEmpty) return;
      var text = pendingText.join('\n').trim();
      pendingText = <String>[];
      if (text.isEmpty) return;
      var weight = pendingType == 'title' ? 'bold' : 'regular';
      var style = 'normal';
      var resolvedType = pendingType;
      if (text.length >= 4 && text.startsWith('**') && text.endsWith('**')) {
        text = text.substring(2, text.length - 2).trim();
        weight = 'bold';
      } else if (text.length >= 2 &&
          text.startsWith('*') &&
          text.endsWith('*')) {
        text = text.substring(1, text.length - 1).trim();
        // 旧协议曾用 Markdown emphasis 表示整段浅色细体。
        weight = 'light';
        resolvedType = pendingType == 'paragraph' ? 'secondary' : pendingType;
      }
      blocks.add(
        OcrBlock(
          id: blocks.length + 1,
          text: text,
          type: resolvedType,
          x: _marginX,
          y: _layoutY(blocks.length),
          width: 1 - _marginX * 2,
          height: _blockHeight,
          firstLineIndent: pendingFirstLineIndent,
          fontWeightRole: weight,
          fontStyleRole: style,
        ),
      );
    }

    for (final rawLine in markdown.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        flush();
        pendingFirstLineIndent = 0;
        continue;
      }
      final firstLineIndent = _leadingFullWidthSpaces(line) >= 2 ? 2 : 0;
      final trimmed = line.trimLeft();
      final type = _classifyLine(trimmed);
      if (pendingText.isNotEmpty && type != pendingType) {
        flush();
      }
      if (pendingText.isEmpty) pendingFirstLineIndent = firstLineIndent;
      pendingType = type;
      pendingText.add(_stripPrefix(trimmed, type));
    }
    flush();
    return blocks;
  }

  /// 把顺序 [OcrBlock] 列表拼回整页 Markdown。
  static String toMarkdown(List<OcrBlock> blocks) {
    final lines = <String>[];
    for (final block in blocks) {
      if (block.type == 'page_header' || block.type == 'sidebar') {
        continue;
      }
      if (block.isTable) {
        for (final row in block.tableRows) {
          lines.add(row.join(' | '));
        }
        lines.add('');
        continue;
      }
      final text = block.text.trim();
      if (text.isEmpty) continue;
      final indent = block.firstLineIndent >= 2 ? '\u3000\u3000' : '';
      lines.addAll([
        switch (block.type) {
          'title' => '$indent${_titlePrefixes.first}$text',
          'list_item' => '$indent- $text',
          'quote' => '$indent> $text',
          'secondary' => '$indent*$text*',
          _ => '$indent$text',
        },
        '',
      ]);
    }
    return lines.join('\n').trim();
  }

  static String _classifyLine(String line) {
    if (_titlePrefixes.any(line.startsWith)) return 'title';
    if (line.startsWith('> ')) return 'quote';
    if (line.startsWith('- ') ||
        line.startsWith('* ') ||
        line.startsWith('+ ') ||
        RegExp(r'^\d+[.、]\s').hasMatch(line)) {
      return 'list_item';
    }
    return 'paragraph';
  }

  static String _stripPrefix(String line, String type) {
    switch (type) {
      case 'title':
        for (final prefix in _titlePrefixes) {
          if (line.startsWith(prefix)) return line.substring(prefix.length);
        }
        return line;
      case 'quote':
        return line.startsWith('> ')
            ? line.substring(2)
            : line.startsWith('>')
            ? line.substring(1)
            : line;
      case 'list_item':
        if (line.startsWith('- ')) return line.substring(2);
        if (line.startsWith('* ')) return line.substring(2);
        if (line.startsWith('+ ')) return line.substring(2);
        return line.replaceFirst(RegExp(r'^\d+[.、]\s*'), '');
      default:
        return line;
    }
  }

  static int _leadingFullWidthSpaces(String value) {
    var count = 0;
    for (final rune in value.runes) {
      if (rune != 0x3000) break;
      count++;
    }
    return count;
  }

  static double _layoutY(int index) =>
      0.05 + index * (_blockHeight + _blockGap);
}
