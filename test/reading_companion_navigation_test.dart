import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/config/book_flow_theme.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/pages/home_page.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('companion exit and space switching restore the home composer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final originalSharing = ReceiveSharingIntent.instance;
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
    addTearDown(() => ReceiveSharingIntent.instance = originalSharing);
    const recorder = MethodChannel('com.llfbandit.record/messages');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(recorder, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(recorder, null));
    await tester.binding.setSurfaceSize(const Size(800, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = (await tester.runAsync(() async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      DatabaseService().useDatabaseForTesting(database);
      await DatabaseService().createForTesting(database);
      final bookId = await BookLibraryService().saveBook(
        BookRecord(title: '伴读测试书'),
      );
      await AiConversationHistoryService.instance.save(
        AiConversationRecord.empty(bookId: bookId, bookName: '伴读测试书').copyWith(
          nodes: [
            AiConversationMessage(
              text: '上次的阅读问题',
              isUser: true,
              createdAt: DateTime(2026, 11, 20),
            ),
          ],
        ),
      );
      return database;
    }))!;
    addTearDown(() async {
      DatabaseService().useDatabaseForTesting(null);
      await db.close();
    });

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读空间'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('沉浸伴读'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择书籍'));
    final book = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label?.startsWith('伴读测试书，') == true,
    );
    await _waitFor(tester, book);
    await tester.tap(book);
    await _waitFor(tester, find.text('打开本书资料'));
    await tester.tap(find.text('打开本书资料'));
    await _waitFor(tester, find.text('还没有导入资料'));
    await tester.binding.handlePopRoute();
    await _waitFor(tester, find.text('打开本书资料'));

    await tester.tap(find.byTooltip('退出伴读'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ReadingCompanion), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('上次的阅读问题'), findsOneWidget);
    final companionIcon = find.descendant(
      of: find.byTooltip('沉浸伴读'),
      matching: _svgAsset(BookFlowTheme.companionIconAsset),
    );
    final notesIcon = _svgAsset('assets/images/home_reply_note.svg');
    final newChatIcon = find.descendant(
      of: find.byTooltip('新建会话'),
      matching: _svgAsset('assets/images/home_new_conversation_icon.svg'),
    );
    for (final sibling in [notesIcon, newChatIcon]) {
      expect(tester.getSize(companionIcon), tester.getSize(sibling));
      expect(tester.getCenter(companionIcon).dy, tester.getCenter(sibling).dy);
    }

    await tester.tap(find.text('技能 / 插件'));
    await tester.pumpAndSettle();
    expect(find.text('创建图像'), findsOneWidget);
    await tester.tap(find.byTooltip('沉浸伴读'));
    await _waitFor(tester, find.text('打开本书资料'));
    expect(find.text('创建图像'), findsNothing);
    await tester.tap(find.text('阅读空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习空间'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ReadingCompanion), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('学习空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习空间'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}

Finder _svgAsset(String name) => find.byWidgetPredicate(
  (widget) =>
      widget is SvgPicture &&
      switch (widget.bytesLoader) {
        SvgAssetLoader(:final assetName) => assetName == name,
        _ => false,
      },
);

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80 && !finder.tryEvaluate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
  await tester.pumpAndSettle();
}
