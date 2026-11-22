import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book_source.dart';
import 'ai_service.dart';
import 'database_service.dart';

/// Translates bounded groups of the visible source text. A cache entry belongs to
/// the specific local source and original text, including its parser revision.
class ReadingCompanionTranslation {
  const ReadingCompanionTranslation(this.source);

  final BookSourceRecord source;

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
