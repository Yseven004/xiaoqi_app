import 'book_source.dart';
import 'xiaoqi_document.dart';

/// A location returned by the book retrieval tool. A version is the hash of
/// the original file, independent of local IDs and of the reader's pagination.
final class ReadingCompanionEvidence {
  const ReadingCompanionEvidence._({
    required this.sourceVersion,
    required this.locator,
    required this.quote,
    required this.showsAsA2ui,
    this.page,
    this.chapterId,
    this.href,
  });

  final String sourceVersion;
  final String locator;
  final String quote;
  final bool showsAsA2ui;
  final int? page;
  final String? chapterId;
  final String? href;

  String get label => locator.isNotEmpty
      ? locator
      : page == null
      ? '电子书原文'
      : 'PDF 原页 $page';

  bool matchesSource(BookSourceRecord source) =>
      source.status == 'ready' &&
      source.contentHash.toLowerCase() == sourceVersion &&
      normalizeBookSourceFormat(source.format) ==
          (page == null ? 'epub' : 'pdf');

  String get identity => '$sourceVersion|${page ?? chapterId ?? href}|$quote';

  Map<String, Object?> toJson() => {
    'source_version': sourceVersion,
    'locator': locator,
    'quote': quote,
    if (showsAsA2ui) 'presentation': 'a2ui',
    if (page != null) 'page': page,
    if (chapterId != null) 'chapter_id': chapterId,
    if (href != null) 'href': href,
  };

  static ReadingCompanionEvidence? fromJson(Map<Object?, Object?> data) {
    String? read(String name, int length) {
      final value = data[name];
      if (value is! String || value.length > length) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final version = read('source_version', 64)?.toLowerCase();
    if (version == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(version)) {
      return null;
    }
    final page = data['page'];
    final chapter = read('chapter_id', 512);
    final href = read('href', 1024);
    if (page != null) {
      if (page is! int ||
          page < 1 ||
          page > 20000 ||
          chapter != null ||
          href != null) {
        return null;
      }
    } else if (chapter == null && href == null) {
      return null;
    }
    return ReadingCompanionEvidence._(
      sourceVersion: version,
      locator: read('locator', 300) ?? '',
      quote: read('quote', 4000) ?? '',
      showsAsA2ui: data['presentation'] == 'a2ui',
      page: page as int?,
      chapterId: chapter,
      href: href,
    );
  }

  static List<ReadingCompanionEvidence> fromPayload(Object? payload) {
    if (payload is! List) return const [];
    return merge(payload.take(32).whereType<Map>().map(fromJson).nonNulls);
  }

  static List<ReadingCompanionEvidence> merge(
    Iterable<ReadingCompanionEvidence> evidence,
  ) {
    final distinct = <String, ReadingCompanionEvidence>{};
    for (final item in evidence) {
      final existing = distinct[item.identity];
      if (existing != null) {
        if (item.showsAsA2ui && !existing.showsAsA2ui) {
          distinct[item.identity] = item;
        }
      } else if (distinct.length < 8) {
        distinct[item.identity] = item;
      }
    }
    return List.unmodifiable(distinct.values);
  }

  /// The spine ID is authoritative where available. A supplied path must
  /// agree. Fall back to the path only when the document has no matching ID.
  XiaoqiDocumentChapter? resolveChapter(XiaoqiDocument document) {
    if (page != null || document.format != 'epub') return null;
    final id = chapterId;
    final link = href;
    final path = link?.split('#').first;
    if (id != null) {
      final prefixed = id.startsWith('epub:') ? id : 'epub:$id';
      final matches = document.chapters.where(
        (chapter) => chapter.id == prefixed,
      );
      if (matches.length == 1) {
        final chapter = matches.single;
        return path == null || path == chapter.href ? chapter : null;
      }
      if (matches.isNotEmpty) return null;
    }
    if (path == null || path.isEmpty) return null;
    final matches = document.chapters.where((chapter) => chapter.href == path);
    return matches.length == 1 ? matches.single : null;
  }
}

/// Retains offsets in the displayed source while ignoring formatting
/// whitespace introduced by the two parsers. Multiple hits stay ambiguous.
({int start, int end})? uniqueReadingEvidenceRange(
  String source,
  String quote,
) {
  final needle = quote.replaceAll(_evidenceWhitespace, '');
  if (needle.runes.length < 3 || source.isEmpty) return null;
  final visible = StringBuffer();
  final offsets = <int>[];
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (_evidenceWhitespace.hasMatch(character)) continue;
    visible.write(character);
    offsets.add(index);
  }
  final value = visible.toString();
  final start = value.indexOf(needle);
  if (start < 0 || value.indexOf(needle, start + 1) >= 0) return null;
  return (start: offsets[start], end: offsets[start + needle.length - 1] + 1);
}

final _evidenceWhitespace = RegExp(r'[\s\u00a0\u3000]');

/// EPUB precision requires one occurrence in one original block. Repeated
/// text or text spanning multiple blocks falls back to the chapter.
({String blockId, int start, int end})? resolveReadingEvidenceBlock(
  XiaoqiDocumentChapter chapter,
  String quote,
) {
  final needle = quote.replaceAll(_evidenceWhitespace, '');
  if (needle.runes.length < 3) return null;
  ({String blockId, int start, int end})? match;
  for (final block in chapter.blocks) {
    if (block.text.isEmpty ||
        !block.text.replaceAll(_evidenceWhitespace, '').contains(needle)) {
      continue;
    }
    final range = uniqueReadingEvidenceRange(block.text, quote);
    if (range == null || match != null) return null;
    match = (blockId: block.id, start: range.start, end: range.end);
  }
  return match;
}
