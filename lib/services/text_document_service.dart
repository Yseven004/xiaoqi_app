import 'dart:convert';
import 'dart:io';

import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';

/// Converts TXT and Markdown sources into the shared XiaoqiDocument model.
///
/// The original bytes remain in the source file. This adapter only derives
/// navigable blocks for the reader and later AI ingestion.
class TextDocumentService {
  const TextDocumentService();

  Future<XiaoqiDocument> parseFile(
    String filePath, {
    required String format,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    return parseBytes(bytes, format: format);
  }

  XiaoqiDocument parseBytes(List<int> bytes, {required String format}) {
    final normalized = normalizeBookSourceFormat(format);
    if (normalized != 'txt' && normalized != 'markdown') {
      throw UnsupportedError('暂不支持解析 .$format 文件');
    }
    final raw = _decodeText(bytes);
    final originalPageCount = raw.contains('\f')
        ? raw.split('\f').length
        : null;
    final chapters = normalized == 'markdown'
        ? _parseMarkdown(raw)
        : [_singleTextChapter(raw)];
    return XiaoqiDocument(
      format: normalized,
      title: '',
      author: '',
      language: '',
      chapters: List.unmodifiable(chapters),
      originalPageCount: originalPageCount,
    );
  }

  XiaoqiDocumentChapter _singleTextChapter(String raw) {
    final blocks = <XiaoqiDocumentBlock>[];
    var index = 0;
    final pages = raw.replaceAll('\r\n', '\n').split('\f');
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      if (pageIndex > 0) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'txt:page-break:${pageIndex + 1}',
            kind: 'page_break',
            text: '',
            originalPageLabel: '${pageIndex + 1}',
          ),
        );
      }
      for (final paragraph
          in pages[pageIndex]
              .split(RegExp(r'\n\s*\n'))
              .map((part) => part.trim())
              .where((part) => part.isNotEmpty)) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'txt:block:${index++}',
            kind: 'paragraph',
            text: paragraph,
          ),
        );
      }
    }
    return XiaoqiDocumentChapter(
      id: 'txt:full-text',
      title: '全文',
      href: '',
      html: '',
      plainText: blocks.map((block) => block.text).join('\n\n'),
      order: 0,
      blocks: List.unmodifiable(blocks),
    );
  }

  List<XiaoqiDocumentChapter> _parseMarkdown(String raw) {
    final lines = <String>[];
    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      final pieces = line.split('\f');
      for (var index = 0; index < pieces.length; index++) {
        if (index > 0) lines.add(_pageBreakSentinel);
        lines.add(pieces[index]);
      }
    }
    final chapters = <XiaoqiDocumentChapter>[];
    final blocks = <XiaoqiDocumentBlock>[];
    String? chapterTitle;
    var chapterIndex = 0;
    var blockIndex = 0;
    var originalPageNumber = 1;
    final plainLines = <String>[];

    void flushChapter() {
      if (blocks.isEmpty && chapterTitle == null) return;
      final title = chapterTitle ?? '全文';
      chapters.add(
        XiaoqiDocumentChapter(
          id: 'markdown:chapter:${chapterIndex++}',
          title: title,
          href: '',
          html: '',
          plainText: plainLines.join('\n\n').trim(),
          order: chapters.length,
          blocks: List.unmodifiable(List.of(blocks)),
        ),
      );
      blocks.clear();
      plainLines.clear();
      chapterTitle = null;
    }

    var cursor = 0;
    while (cursor < lines.length) {
      final line = lines[cursor];
      final heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        if (level == 1 && (blocks.isNotEmpty || chapterTitle != null)) {
          flushChapter();
        }
        chapterTitle ??= heading.group(2)!.trim();
        final block = XiaoqiDocumentBlock(
          id: 'markdown:block:${blockIndex++}',
          kind: 'heading',
          text: heading.group(2)!.trim(),
          level: level,
        );
        blocks.add(block);
        plainLines.add(block.text);
        cursor++;
        continue;
      }

      if (line.trim().isEmpty) {
        cursor++;
        continue;
      }

      if (line == _pageBreakSentinel) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'markdown:page-break:${blockIndex++}',
            kind: 'page_break',
            text: '',
            originalPageLabel: '${++originalPageNumber}',
          ),
        );
        cursor++;
        continue;
      }

      final fence = RegExp(r'^\s*```\s*(.*)$').firstMatch(line);
      if (fence != null) {
        final codeLines = <String>[];
        final language = fence.group(1)?.trim() ?? '';
        cursor++;
        while (cursor < lines.length &&
            !lines[cursor].trim().startsWith('```')) {
          codeLines.add(lines[cursor]);
          cursor++;
        }
        if (cursor < lines.length) cursor++;
        final text = codeLines.join('\n');
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'markdown:block:${blockIndex++}',
            kind: 'code',
            text: text,
            language: language,
          ),
        );
        plainLines.add(text);
        continue;
      }

      final list = RegExp(r'^\s*(?:[-+*]|\d+[.)])\s+(.+)$').firstMatch(line);
      if (list != null) {
        final text = list.group(1)!.trim();
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'markdown:block:${blockIndex++}',
            kind: 'list_item',
            text: text,
          ),
        );
        plainLines.add(text);
        cursor++;
        continue;
      }

      if (line.trimLeft().startsWith('>')) {
        final text = line.trimLeft().substring(1).trim();
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'markdown:block:${blockIndex++}',
            kind: 'quote',
            text: text,
          ),
        );
        plainLines.add(text);
        cursor++;
        continue;
      }

      if (RegExp(r'^\s*(?:---+|\*\*\*+|___+)\s*$').hasMatch(line)) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'markdown:block:${blockIndex++}',
            kind: 'divider',
            text: '',
          ),
        );
        cursor++;
        continue;
      }

      final paragraphLines = <String>[line.trim()];
      cursor++;
      while (cursor < lines.length &&
          lines[cursor].trim().isNotEmpty &&
          lines[cursor] != _pageBreakSentinel &&
          !RegExp(r'^(#{1,6})\s+').hasMatch(lines[cursor]) &&
          !RegExp(r'^\s*(?:[-+*]|\d+[.)])\s+').hasMatch(lines[cursor]) &&
          !lines[cursor].trimLeft().startsWith('>') &&
          !lines[cursor].trimLeft().startsWith('```')) {
        paragraphLines.add(lines[cursor].trim());
        cursor++;
      }
      final text = paragraphLines.join(' ');
      blocks.add(
        XiaoqiDocumentBlock(
          id: 'markdown:block:${blockIndex++}',
          kind: 'paragraph',
          text: text,
        ),
      );
      plainLines.add(text);
    }
    flushChapter();
    if (chapters.isEmpty) return [_singleTextChapter(raw)];
    return chapters;
  }

  String _decodeText(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final codeUnits = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      codeUnits.add(
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(codeUnits);
  }
}

const _pageBreakSentinel = '\u0000xiaoqi-page-break\u0000';
