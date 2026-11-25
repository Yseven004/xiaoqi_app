import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book_source.dart';
import '../models/companion_source_range.dart';
import 'ai_service.dart';
import 'database_service.dart';

/// Translates bounded groups of the visible source text. A cache entry belongs to
/// the specific local source and original text, including its parser revision.
class ReadingCompanionTranslation {
  const ReadingCompanionTranslation(this.source);

  final BookSourceRecord source;

  Future<List<CompanionTranslationText>> translateAligned(
    List<String> originals, {
    Future<List<List<String>>> Function()? legacyParagraphs,
  }) async {
    final ranges = originals.map(CompanionTranslationText.sourceUnits).toList();
    final List<String> translated;
    try {
      translated = await translate([
        for (final (index, units) in ranges.indexed)
          for (final unit in units)
            originals[index].substring(unit.start, unit.end),
      ]);
    } on Exception {
      final groups = legacyParagraphs == null
          ? [
              for (final original in originals) [original.trim()],
            ]
          : await legacyParagraphs();
      if (groups.length != originals.length) rethrow;
      final legacy = await _legacyCachedTranslations(groups);
      if (legacy == null) rethrow;
      return [
        for (final (index, text) in legacy.indexed)
          CompanionTranslationText._(
            originals[index],
            text,
            const [],
            const [],
          ),
      ];
    }
    var offset = 0;
    return [
      for (final (index, units) in ranges.indexed)
        CompanionTranslationText.fromUnits(originals[index], units, [
          for (var count = 0; count < units.length; count++)
            translated[offset++],
        ]),
    ];
  }

  Future<List<String>?> _legacyCachedTranslations(
    List<List<String>> groups,
  ) async {
    final db = await DatabaseService().database;
    final result = <String>[];
    for (final paragraphs in groups) {
      final translated = <String>[];
      for (final paragraph in paragraphs) {
        if (paragraph.isEmpty) continue;
        final rows = await db.query(
          'companion_translations',
          columns: ['body'],
          where: 'cache_key = ?',
          whereArgs: [_key(paragraph)],
          limit: 1,
        );
        final body = rows.singleOrNull?['body'];
        if (body is! String || body.isEmpty) return null;
        translated.add(body);
      }
      result.add(translated.join('\n\n'));
    }
    return result;
  }

  String _key(String text) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'deepseek-flash:zh-CN:1',
            source.id,
            source.sourceVersionId,
            source.contentHash,
            source.documentParserVersion,
            text,
          ]),
        ),
      )
      .toString();

  Future<List<String>> translate(List<String> paragraphs) async {
    final db = await DatabaseService().database;
    final keys = paragraphs.map(_key).toList();
    final found = <String, String>{};
    final missing = <String, String>{};
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      if (found.containsKey(key) || missing.containsKey(key)) continue;
      final rows = await db.query(
        'companion_translations',
        columns: ['body'],
        where: 'cache_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) {
        missing[key] = paragraphs[i];
      } else {
        found[key] = rows.single['body']! as String;
      }
    }

    if (missing.isNotEmpty) {
      final parts = <String>[];
      final counts = <int>[];
      for (final text in missing.values) {
        final runes = text.runes.toList();
        final start = parts.length;
        for (var offset = 0; offset < runes.length; offset += 2400) {
          parts.add(String.fromCharCodes(runes.skip(offset).take(2400)));
        }
        counts.add(parts.length - start);
      }
      final translated = <String>[];
      var batch = <String>[];
      var length = 0;
      for (final part in parts) {
        if (batch.isNotEmpty && length + part.length > 5000) {
          translated.addAll(await AiService().translateReadingText(batch));
          batch = [];
          length = 0;
        }
        batch.add(part);
        length += part.length;
      }
      if (batch.isNotEmpty) {
        translated.addAll(await AiService().translateReadingText(batch));
      }
      final savedAt = DateTime.now().millisecondsSinceEpoch;
      final transaction = db.batch();
      var offset = 0;
      var index = 0;
      for (final key in missing.keys) {
        final count = counts[index++];
        final body = translated.skip(offset).take(count).join('\n');
        offset += count;
        found[key] = body;
        transaction.insert('companion_translations', {
          'cache_key': key,
          'source_id': source.id,
          'body': body,
          'saved_at': savedAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      transaction.rawDelete(
        '''
        DELETE FROM companion_translations WHERE cache_key IN (
          SELECT cache_key FROM companion_translations
          WHERE source_id = ? ORDER BY saved_at DESC LIMIT -1 OFFSET 384
        )
      ''',
        [source.id],
      );
      await transaction.commit(noResult: true);
    }
    return [for (final key in keys) found[key]!];
  }

  /// The toggle needs only a local distinction between supported foreign prose
  /// and Chinese prose. Japanese kana and Korean Hangul take priority over Han.
  static bool isForeign(String text, {String language = ''}) {
    final code = language.toLowerCase().split(RegExp('[-_]')).first;
    if (const {'en', 'ja', 'ko'}.contains(code)) return true;
    if (code == 'zh') return false;
    var latin = 0;
    var han = 0;
    var kanaOrHangul = 0;
    for (final rune in text.runes.take(2400)) {
      if ((rune >= 0x3040 && rune <= 0x30ff) ||
          (rune >= 0xac00 && rune <= 0xd7a3)) {
        kanaOrHangul++;
      } else if (rune >= 0x3400 && rune <= 0x9fff) {
        han++;
      } else if ((rune >= 65 && rune <= 90) || (rune >= 97 && rune <= 122)) {
        latin++;
      }
    }
    return kanaOrHangul >= 4 || (latin >= 30 && latin > han * 3);
  }
}

/// Each translated string is an independently requested source unit in the
/// ordered translation API. Coordinates within a translated unit have no
/// deterministic correspondences. Only complete aligned units can project.
class CompanionTranslationText {
  CompanionTranslationText._(
    this.source,
    this.text,
    this._source,
    this._translated,
  );

  final String source;
  final String text;
  final List<CompanionTextRange> _source;
  final List<CompanionTextRange> _translated;

  static final _boundaries = RegExp(
    r'''(?:[。！？!?]+["”’」』）)\]]*|\.+["”’」』）)\]]*(?=\s|$)|\n[ \t]*\n)''',
  );

  static List<CompanionTextRange> sourceUnits(String source) {
    final result = <CompanionTextRange>[];
    var start = 0;
    void add(int end) {
      final range = trimCompanionRange(source, start, end);
      if (range != null) result.add(range);
      start = end;
    }

    for (final boundary in _boundaries.allMatches(source)) {
      add(boundary.end);
    }
    add(source.length);
    return result;
  }

  factory CompanionTranslationText.fromUnits(
    String source,
    List<CompanionTextRange> units,
    List<String> translations,
  ) {
    if (units.length != translations.length) {
      throw const FormatException('翻译结果与原文单元数量不同');
    }
    final text = StringBuffer();
    final ranges = <CompanionTextRange>[];
    for (final (index, value) in translations.indexed) {
      final translated = value.trim();
      if (translated.isEmpty) throw const FormatException('翻译结果为空');
      if (index != 0) {
        final separator = source.substring(
          units[index - 1].end,
          units[index].start,
        );
        if (separator.contains('\n\n') ||
            RegExp(r'\n\s*\n').hasMatch(separator)) {
          text.write('\n\n');
        } else {
          text.write(' ');
        }
      }
      final start = text.length;
      text.write(translated);
      ranges.add((start: start, end: text.length));
    }
    return CompanionTranslationText._(source, text.toString(), units, ranges);
  }

  CompanionTextRange? sourceRange(int start, int end) =>
      _align(text, start, end, _translated, _source);

  CompanionTextRange? translatedRange(int start, int end) =>
      _align(source, start, end, _source, _translated);

  static CompanionTextRange? _align(
    String text,
    int start,
    int end,
    List<CompanionTextRange> from,
    List<CompanionTextRange> to,
  ) {
    final range = trimCompanionRange(text, start, end);
    if (range == null) return null;
    final first = from.indexWhere((unit) => unit.start == range.start);
    final last = from.indexWhere((unit) => unit.end == range.end);
    if (first < 0 || last < first) return null;
    return (start: to[first].start, end: to[last].end);
  }
}
