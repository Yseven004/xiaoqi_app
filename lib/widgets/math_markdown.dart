import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../config/colors.dart';

/// 渲染含 LaTeX 公式的 Markdown（demo 级文档还原）。
///
/// - 行内公式 `$...$` → 内联数学符号
/// - 行间公式 `$$...$$` → 展示型数学符号（居中、较大）
/// - 其余 Markdown 语法（标题/列表/表格/引用/代码）由 flutter_markdown 渲染
///
/// PaddleOCR-VL 返回的 markdown 字段里，公式通常以 `$...$` / `$$...$$` 给出，
/// 本组件把它们交给 flutter_math_fork 渲染成规整数学符号；解析失败时退化为原文，
/// 不影响整页。
class MathMarkdown extends StatelessWidget {
  final String data;
  final MarkdownStyleSheet? styleSheet;

  const MathMarkdown({super.key, required this.data, this.styleSheet});

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: true,
      // 先注册行间公式语法，再注册行内，保证 $$...$$ 优先匹配
      inlineSyntaxes: [_DisplayMathSyntax(), _InlineMathSyntax()],
      builders: {
        'displaymath': _MathBuilder(true),
        'math': _MathBuilder(false),
      },
      styleSheet: styleSheet ?? _defaultStyle,
      sizedImageBuilder: _buildMarkdownImage,
    );
  }

  /// PaddleOCR 图表块洗成 data:image/jpeg;base64,... 后由此渲染。
  Widget _buildMarkdownImage(MarkdownImageConfig config) {
    final uri = config.uri;
    final alt = config.alt;
    final raw = uri.toString();
    if (uri.scheme == 'data' || raw.startsWith('data:')) {
      try {
        final comma = raw.indexOf(',');
        if (comma > 0) {
          final b64 = raw.substring(comma + 1);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Image.memory(
              base64Decode(b64),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Text(alt ?? '［图表］'),
            ),
          );
        }
      } catch (_) {}
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Image.network(uri.toString(), fit: BoxFit.contain),
      );
    }
    return const SizedBox.shrink();
  }
}

final _defaultStyle = MarkdownStyleSheet(
  p: TextStyle(fontSize: 16, height: 1.7, color: AppColors.textPrimary),
  h1: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      color: AppColors.textPrimary,
      height: 1.3),
  h2: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: AppColors.textPrimary,
      height: 1.3),
  h3: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: AppColors.textPrimary,
      height: 1.3),
  listBullet: TextStyle(fontSize: 16, color: AppColors.textPrimary),
  strong: TextStyle(fontWeight: FontWeight.bold),
  blockquote: TextStyle(
      fontSize: 15,
      color: AppColors.textSecondary,
      fontStyle: FontStyle.italic,
      height: 1.6),
  tableHead: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary),
  tableBody: TextStyle(fontSize: 14, color: AppColors.textPrimary),
  code: TextStyle(
      fontFamily: 'monospace', fontSize: 14, backgroundColor: Color(0x11000000)),
);

/// 行间公式 `$$...$$`
class _DisplayMathSyntax extends md.InlineSyntax {
  _DisplayMathSyntax() : super(r'\$\$([\s\S]+?)\$\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('displaymath', match[1]!));
    return true;
  }
}

/// 行内公式 `$...$`
class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax() : super(r'\$([^\$\n]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math', match[1]!));
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  final bool display;
  _MathBuilder(this.display);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent.trim();
    try {
      return Math.tex(
        tex,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
      );
    } catch (_) {
      // 公式解析失败：退化为原文，避免整页崩
      return Text(tex, style: preferredStyle);
    }
  }
}
