import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/book_category.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_library_query.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/pages/book_learning_shell_page.dart';
import 'package:xiaoqi_app/pages/book_learning_space_page.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/widgets/book_pdf_import_sheet.dart';

final class _PickedFile extends PlatformFile {
  @override
  String get name => 'sample.pdf';

  @override
  int lengthSync() => 123;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BookLibraryItem _item(int id, String title) => BookLibraryItem(
  book: BookRecord(id: id, title: title),
  noteCount: 0,
  recognizedPageCount: 0,
  activeDaysInLast30Days: 0,
  isPinned: false,
  categories: const [],
);

class _Library extends BookLibraryService {
  List<BookLibraryItem> items = List.generate(
    40,
    (i) => _item(i + 1, '测试书籍 $i'),
  );
  int reads = 0;

  @override
  Future<List<BookCategory>> listCategories() async => [];

  @override
  Future<List<BookLibraryItem>> listBooks({
    BookLibraryQuery query = const BookLibraryQuery(),
  }) async {
    reads++;
    return items
        .where((item) => item.book.title.contains(query.searchText))
        .toList();
  }

  @override
  Future<BookLibraryItem?> getBookLibraryItem(int bookId) async =>
      items.where((item) => item.book.id == bookId).firstOrNull;

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [];

  @override
  Future<void> recordStudyActivity(
    int bookId, {
    String action = 'open',
  }) async {}
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: 'Expected UI state did not become ready');
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('book-interaction-');
    db = await databaseFactoryFfi.openDatabase('${root.path}/books.db');
    DatabaseService().useDatabaseForTesting(db);
    await DatabaseService().createForTesting(db);
  });

  tearDown(() async {
    DatabaseService().useDatabaseForTesting(null);
    await db.close();
    await root.delete(recursive: true);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'return preserves library state and refreshes data (reduceMotion=$reduceMotion)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final library = _Library();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reduceMotion),
              child: child!,
            ),
            home: BookLearningShellPage(bookLibraryService: library),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.text('测试书籍 0').evaluate().isNotEmpty,
        );
        final page = find.byType(BookLearningSpacePage);
        final originalState = tester.state(page);
        await tester.enterText(
          find.descendant(of: page, matching: find.byType(TextField)),
          '测试',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        final scroll = find.descendant(
          of: page,
          matching: find.byType(CustomScrollView),
        );
        await tester.drag(scroll, const Offset(0, -420));
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: scroll, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        final oldOffset = position.pixels;
        expect(oldOffset, greaterThan(0));
        tester.widget<BookLearningSpacePage>(page).onOpenBook(1);
        await _pumpUntil(
          tester,
          () => find.byTooltip('更多书籍操作').evaluate().isNotEmpty,
        );
        library.items[0] = _item(1, '测试书籍已修改');
        final readsBeforeReturn = library.reads;
        await tester.tap(find.byTooltip('返回阅读空间'));
        await _pumpUntil(tester, () => library.reads > readsBeforeReturn);
        expect(tester.state(page), same(originalState));
        expect(position.pixels, closeTo(oldOffset, .1));
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: page, matching: find.byType(TextField)),
              )
              .controller!
              .text,
          '测试',
        );
        await tester.drag(
          find.descendant(of: page, matching: find.byType(CustomScrollView)),
          const Offset(0, 1000),
        );
        await tester.pumpAndSettle();
        expect(find.text('测试书籍已修改'), findsWidgets);

        tester.widget<BookLearningSpacePage>(page).onOpenBook(1);
        await _pumpUntil(
          tester,
          () => find.byTooltip('更多书籍操作').evaluate().isNotEmpty,
        );
        library.items.removeWhere((item) => item.book.id == 1);
        final readsBeforeSystemBack = library.reads;
        await tester.binding.handlePopRoute();
        await _pumpUntil(tester, () => library.reads > readsBeforeSystemBack);
        expect(tester.state(page), same(originalState));
        expect(find.text('测试书籍已修改'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'existing book selection waits for explicit import confirmation',
    (tester) async {
      BookPdfImportSelection? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showBookPdfImportSheet(
                    context: context,
                    file: _PickedFile(),
                    books: [_item(1, '第一本'), _item(2, '第二本')],
                  );
                },
                child: const Text('导入'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('第二本').last);
      await tester.tap(find.text('第二本').last);
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.ensureVisible(find.text('确认关联并导入'));
      await tester.tap(find.text('确认关联并导入'));
      await tester.pumpAndSettle();
      expect(result?.bookId, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320dp library toolbar fits at 200 percent text size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = _Library()..items = [];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: BookLearningSpacePage(
            bookLibraryService: library,
            onOpenBook: (_) {},
            onCreateBook: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('多选编辑'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('add source actions grow at 200 percent text size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BookAddAction? result;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showBookAddSourceSheet(context),
              child: const Text('添加'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('扫描或输入 ISBN'));
    await tester.tap(find.text('扫描或输入 ISBN'));
    await tester.pumpAndSettle();
    expect(result, BookAddAction.scan);
  });
}
