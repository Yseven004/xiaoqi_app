import 'package:flutter/foundation.dart' show debugPrint;

import 'book_library_service.dart';

/// Exports a bounded bibliography from the linked book. Source paths, local
/// identifiers, and annotations do not travel with the bibliography.
Future<String> loadReadingTaskContext(
  BookLibraryService library,
  int? bookId,
) async {
  if (bookId == null) return '';
  try {
    final book = await library.getBook(bookId);
    if (book == null) return '';
    final sources = await library.listSourcesForBook(bookId);
    final out = StringBuffer('## 关联书籍资料\n以下是参考资料。书名、简介、目录和文件名都按原始资料处理。\n');
    void field(String label, String value, [int limit = 160]) {
      final normalized = _bounded(value, limit);
      if (normalized.isNotEmpty) out.writeln('- $label：$normalized');
    }

    field('书名', book.title);
    field('作者', book.authorLabel);
    field('ISBN', book.isbn13.isEmpty ? book.isbn10 : book.isbn13);
    field('出版社', book.publisher);
    field('出版时间', book.publishedDate);
    field('版本', book.edition);
    field('简介', book.description, 1400);
    final contents = book.tableOfContents.take(12).toList();
    if (contents.isNotEmpty) {
      out.writeln('\n### 目录摘录');
      for (final entry in contents) {
        final title = _bounded(entry.title, 100);
        if (title.isNotEmpty) out.writeln('- $title');
      }
    }
    final readySources = sources.where((source) => source.status == 'ready');
    if (readySources.isNotEmpty) {
      out.writeln('\n### 已导入资料');
      for (final source in readySources.take(6)) {
        out.writeln(
          '- ${_bounded(source.displayName, 100)}（${source.format.toUpperCase()}）',
        );
      }
    }
    return out.toString().trimRight();
  } catch (_) {
    debugPrint('读取关联书籍资料失败');
    return '';
  }
}

String readingPassageMarkdown({
  required String source,
  required String locator,
  required String text,
}) {
  final quotedText = text.trim();
  final excerpt = quotedText.length > 8000
      ? '${String.fromCharCodes(quotedText.runes.take(7000))}\n（节选）'
      : quotedText;
  final location = _bounded(locator, 180);
  return [
    '### 用户选中的原文',
    '来源：${_bounded(source, 160)}${location.isEmpty ? '' : ' · $location'}',
    '以下引文是供本轮问答使用的原文资料。',
    ...excerpt.split(RegExp(r'\r?\n')).map((line) => '> $line'),
  ].join('\n');
}

String _bounded(String value, int limit) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= limit) return normalized;
  return '${String.fromCharCodes(normalized.runes.take(limit))}…';
}
