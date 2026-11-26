import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_library_query.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/widgets/book_source_import.dart';
import 'package:xiaoqi_app/widgets/reading_task_material_dialog.dart';
import 'package:xiaoqi_app/widgets/reading_task_switcher.dart';

void main() {
  testWidgets('re-tapping the current book opens the centered material card', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('reading-choice-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final library = _Library([
      _source(scratch, id: 1, name: '电子书原文'),
      _source(scratch, id: 2, name: '阅读笔记'),
    ]);
    SharedPreferences.setMockInitialValues({});
    final history = AiConversationHistoryService(
      preferences: await SharedPreferences.getInstance(),
    );
    final selectionGate = Completer<void>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.binding.setSurfaceSize(const Size(360, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                height: 62,
                child: ReadingTaskSwitcher(
                  library: library,
                  composerFocusNode: focus,
                  selectedBookId: 1,
                  selectedBookName: _book.book.title,
                  onSelectBook: (_) => fail('current book was re-activated'),
                  onOpenBookMaterials: (book) => showReadingTaskMaterialsDialog(
                    context,
                    book: book,
                    library: library,
                    bookId: 1,
                    sourceId: 1,
                    onSelect: (id) async {
                      await selectionGate.future;
                      await history.selectReadingSource(
                        'reading-task-a',
                        bookId: 1,
                        sourceId: id,
                      );
                    },
                  ),
                  onSearchFocusChanged: (_) {},
                  onStartIndependent: () {},
                  onAddBook: (_) async => null,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('《样例书》'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '查看《样例书》的关联资料',
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(tester.getCenter(dialog), const Offset(180, 325));
    expect(find.text('新建阅读任务'), findsNothing);
    expect(find.text('导入资料'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

    await tester.tap(find.text('导入资料'));
    await tester.pumpAndSettle();
    for (final item in ['本机导入', '微信导入', '网上找书']) {
      expect(find.text(item), findsOneWidget);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    final buttonLabel = find.text('导入资料');
    final importButton = find.widgetWithText(FilledButton, '导入资料');
    final buttonBounds = tester.getRect(importButton);
    final buttonBackground = _importButtonBackground(tester, '导入资料');
    final buttonForeground = DefaultTextStyle.of(
      tester.element(buttonLabel),
    ).style.color;
    await tester.tap(find.text('阅读笔记'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(tester.widget<FilledButton>(importButton).onPressed, isNull);
    expect(tester.getRect(importButton), buttonBounds);
    expect(_importButtonBackground(tester, '导入资料'), buttonBackground);
    expect(
      DefaultTextStyle.of(tester.element(buttonLabel)).style.color,
      buttonForeground,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    selectionGate.complete();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await history.readingSourceId('reading-task-a', 1) == 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(tester.widget<FilledButton>(importButton).onPressed, isNotNull);
    expect(tester.getRect(importButton), buttonBounds);
    _expectSelected('阅读笔记');
    expect(await history.readingSourceId('reading-task-a', 1), 2);
    expect(await history.readingSourceId('reading-task-b', 1), isNull);
    expect(await history.readingSourceId('reading-task-a', 2), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed material load retries without retaining unavailable rows',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('reading-choice-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final library = _Library([
        _source(scratch, id: 1, name: '尚未就绪', status: 'processing'),
        _source(scratch, id: 2, name: '新导入的资料'),
      ])..failLoad = true;
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReadingTaskMaterialsDialog(
                  context,
                  book: _book,
                  library: library,
                  bookId: 1,
                  sourceId: 99,
                  onSelect: (id) async {
                    selected = id;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      library.failLoad = false;
      await tester.tap(find.text('读取资料失败，点击重试'));
      await tester.pumpAndSettle();
      expect(find.text('已关联的资料已移除'), findsOneWidget);
      expect(find.text('EPUB · 暂不可用'), findsOneWidget);
      await tester.tap(find.text('尚未就绪'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.text('新导入的资料'));
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 50 && selected == null; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(find.byType(Dialog), findsOneWidget);
      _expectSelected('新导入的资料');
      expect(find.text('已关联的资料已移除'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual import shows progress then selects the new row in place',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final scratch = Directory.systemTemp.createTempSync('reading-import-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final imported = _source(scratch, id: 2, name: '追加资料');
      final library = _Library([_source(scratch, id: 1, name: '原有资料')]);
      final progress = library.pendingImport =
          Completer<BookSourceImportResult>();
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReadingTaskMaterialsDialog(
                  context,
                  book: _book,
                  library: library,
                  bookId: 1,
                  sourceId: 1,
                  onSelect: (id) async => selected = id,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入资料'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('微信导入'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(
        routeExistingBookSharedMedia([
          SharedMediaFile(
            path: imported.filePath,
            type: SharedMediaType.file,
            mimeType: 'application/epub+zip',
          ),
        ]),
        isEmpty,
      );
      await tester.pumpAndSettle();
      expect(library.importStarted, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '仅保存在本机'));
      for (var attempt = 0; attempt < 50 && !library.importStarted; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(library.importStarted, isTrue);
      expect(find.text('正在导入'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(button.onPressed, isNull);
      expect(_importButtonBackground(tester, '正在导入'), const Color(0xFFE5E5E5));
      expect(selected, isNull);
      _expectSelected('原有资料');

      library.sources.add(imported);
      progress.complete(
        BookSourceImportResult(source: imported, reusedExisting: false),
      );
      for (var attempt = 0; attempt < 50 && selected == null; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(find.text('关联资料'), findsOneWidget);
      expect(find.text('原有资料'), findsOneWidget);
      _expectSelected('追加资料');
      expect(find.text('导入资料'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}

Color? _importButtonBackground(WidgetTester tester, String label) => tester
    .widget<Material>(
      find.descendant(
        of: find.widgetWithText(FilledButton, label),
        matching: find.byType(Material),
      ),
    )
    .color;

void _expectSelected(String name) => expect(
  find.descendant(
    of: find.widgetWithText(ListTile, name),
    matching: find.byIcon(Icons.radio_button_checked),
  ),
  findsOneWidget,
);

final _book = BookLibraryItem(
  book: BookRecord(id: 1, title: '样例书'),
  noteCount: 0,
  recognizedPageCount: 0,
  activeDaysInLast30Days: 0,
  isPinned: false,
  categories: const [],
);

BookSourceRecord _source(
  Directory scratch, {
  required int id,
  required String name,
  String status = 'ready',
}) {
  final file = File('${scratch.path}/$id.epub')..writeAsStringSync('fixture');
  return BookSourceRecord(
    id: id,
    bookId: 1,
    kind: 'book_file',
    displayName: name,
    filePath: file.path,
    fileSize: file.lengthSync(),
    contentHash: 'test-$id',
    status: status,
    format: 'epub',
    createdAt: '',
    updatedAt: '',
  );
}

class _Library implements BookLibraryService {
  _Library(this.sources);

  final List<BookSourceRecord> sources;
  bool failLoad = false;
  bool importStarted = false;
  Completer<BookSourceImportResult>? pendingImport;

  @override
  Future<List<BookLibraryItem>> listBooks({
    BookLibraryQuery query = const BookLibraryQuery(),
  }) async => [_book];

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async {
    if (failLoad) throw StateError('test unavailable');
    return sources;
  }

  @override
  Future<BookSourceImportResult> importBookSourceForBook({
    required int bookId,
    required String sourcePath,
    required String displayName,
    required String format,
  }) {
    importStarted = true;
    return pendingImport!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
