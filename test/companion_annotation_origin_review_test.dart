import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/models/xiaoqi_document.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/services/reading_companion_translation.dart';
import 'package:xiaoqi_app/widgets/companion_note_origin.dart';
import 'package:xiaoqi_app/widgets/companion_pdf_annotation_overlay.dart';
import 'package:xiaoqi_app/widgets/xiaoqi_document_block_view.dart';

const _digest =
    '0123456789012345678901234567890123456789012345678901234567890123';

BookSourceRecord _source(int id, {int bookId = 1, String hash = _digest}) =>
    BookSourceRecord.fromMap({
      'id': id,
      'book_id': bookId,
      'file_path': '/local/$id.pdf',
      'content_hash': hash,
      'source_version_id': 'version-$id',
    });

CompanionAnnotationSelection _selection({
  String view = 'original',
  String? translation,
  int lastPage = 4,
}) => CompanionAnnotationSelection(
  bookId: 1,
  sourceId: 12,
  sourceVersion: 'version-12',
  anchor: const PdfReaderAnchor(sourceId: '12', pageNumber: 3),
  endAnchor: PdfReaderAnchor(sourceId: '12', pageNumber: lastPage),
  startOffset: 500,
  endOffset: 10,
  locator: '第 3–4 页',
  quote: '保留完整引文',
  view: view,
  translationVersion: translation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'annotation offsets are local to translated and original slices',
    (tester) async {
      for (final (text, originalOffset) in [('续页译文重复', null), ('续页原文重复', 5)]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: XiaoqiDocumentBlockView(
                block: const XiaoqiDocumentBlock(
                  id: 'block',
                  kind: 'paragraph',
                  text: '第一句原文续页原文重复',
                ),
                textOverride: text,
                textOffset: originalOffset,
                annotationRanges: const [(start: 2, end: 4, id: 'first')],
                onOpenAnnotations: (_) {},
              ),
            ),
          ),
        );
        final selectable = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        final marked = selectable.textSpan!.children!
            .whereType<TextSpan>()
            .singleWhere(
              (span) =>
                  span.style?.decorationStyle == TextDecorationStyle.dashed,
            );
        expect(marked.text, text.substring(2, 4));
      }
    },
  );

  test('noncanonical PDF ranges compare offsets separately across pages', () {
    expect(legacyCompanionPdfRange(_selection()), (
      firstPage: 3,
      lastPage: 4,
      startOffset: 500,
      endOffset: 10,
    ));
    expect(legacyCompanionPdfRange(_selection(lastPage: 3)), isNull);
  });

  test('unaligned translation leaves quote but offers no source target', () {
    final selection = _selection(
      view: 'translation',
      translation: 'translation-snapshot',
    );
    expect(selection.quote, '保留完整引文');
    expect(
      resolveCompanionOriginSource(selection, selection.toJson(), [
        _source(12),
      ]),
      isNull,
    );
  });

  test('snapshot rebinds only to unique equal bytes in the same book', () {
    final selection = _selection();
    final locator = <String, dynamic>{
      ...selection.toJson(),
      'source_content_hash': _digest,
    };
    final rebound = resolveCompanionOriginSource(selection, locator, [
      _source(20),
      _source(21, bookId: 2),
    ])!;
    expect(rebound.selection.anchor.sourceId, '20');
    expect(rebound.selection.endAnchor!.sourceId, '20');
    expect(rebound.selection.sourceVersion, 'version-20');
    expect(rebound.selection.quote, selection.quote);
    expect(
      resolveCompanionOriginSource(selection, locator, [
        _source(21, bookId: 2),
      ]),
      isNull,
    );
    expect(
      resolveCompanionOriginSource(selection, locator, [
        _source(20),
        _source(22),
      ]),
      isNull,
    );
    expect(
      resolveCompanionOriginSource(selection, selection.toJson(), [
        _source(20),
      ]),
      isNull,
    );
  });

  test(
    'old whole-paragraph cache stays readable offline without guessed mapping',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final data = DatabaseService()..useDatabaseForTesting(db);
      addTearDown(() async {
        data.useDatabaseForTesting(null);
        await db.close();
      });
      await data.createForTesting(db);
      final source = _source(12);
      const paragraph = 'One sentence. A separate sentence.';
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'deepseek-flash:zh-CN:1',
                source.id,
                source.sourceVersionId,
                source.contentHash,
                source.documentParserVersion,
                paragraph,
              ]),
            ),
          )
          .toString();
      await db.insert('companion_translations', {
        'cache_key': key,
        'source_id': source.id,
        'body': '旧版段落译文',
        'saved_at': 1,
      });
      final restored = (await ReadingCompanionTranslation(
        source,
      ).translateAligned([paragraph])).single;
      expect(restored.text, '旧版段落译文');
      expect(restored.sourceRange(0, restored.text.length), isNull);
    },
  );
}
