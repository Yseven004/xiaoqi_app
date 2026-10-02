import 'dart:convert';

import 'package:flutter/material.dart';

import '../config/note_page_theme.dart';
import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../plugins/document_recognition/markdown_blocks_codec.dart';
import 'book_page_document_view.dart';

/// 统一的只读书页内容面板。
///
/// 新书页优先读取结构化 [BookPageDocument]；Markdown 和纯文本只用于历史
/// 笔记的兼容回退，不会覆盖已保存的 OCR 结构数据。
class BookPageDocumentContent extends StatelessWidget {
  const BookPageDocumentContent({
    super.key,
    required this.note,
    this.compact = false,
  });

  final Note note;
  final bool compact;

  static BookPageDocument documentFor(Note note) {
    final raw = note.annotationsJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final document = BookPageDocument.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (document.renderBlocks.any(
          (block) =>
              block.text.trim().isNotEmpty || block.isTable || block.isFigure,
        )) {
          return document;
        }
        if (document.compatibilityMarkdown.isNotEmpty) {
          return document.copyWith(
            blocks: MarkdownBlocksCodec.fromMarkdown(
              document.compatibilityMarkdown,
            ),
          );
        }
      } catch (_) {
        // Preserve the original note and continue through the read-only
        // compatibility path below.
      }
    }
    return BookPageDocument(
      blocks: MarkdownBlocksCodec.fromMarkdown(note.content),
      compatibilityMarkdown: note.content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 260),
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
      decoration: BoxDecoration(
        color: NotePageTheme.card,
        borderRadius: BorderRadius.circular(10),
        boxShadow: NotePageTheme.cardShadow,
      ),
      child: BookPageDocumentView(
        document: documentFor(note),
        compact: compact,
      ),
    );
  }
}
