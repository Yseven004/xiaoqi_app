import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
import 'package:xiaoqi_app/services/reading_task_context.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';
import 'package:xiaoqi_app/widgets/reading_space_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('companion slides beside home and keeps its sidebar context', (
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
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('companion-navigation-'),
    ))!;
    addTearDown(() async {
      // Windows may briefly retain an EPUB handle after the reader unmounts.
      for (var attempt = 0; ; attempt++) {
        try {
          await directory.delete(recursive: true);
          return;
        } on FileSystemException catch (error) {
          if (!Platform.isWindows ||
              error.osError?.errorCode != 32 ||
              attempt >= 10) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final db = (await tester.runAsync(() async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      DatabaseService().useDatabaseForTesting(database);
      await DatabaseService().createForTesting(database);
      final bookId = await BookLibraryService().saveBook(
        BookRecord(title: '伴读测试书'),
      );
      final secondBookId = await BookLibraryService().saveBook(
        BookRecord(title: '另一本在读书'),
      );
      await BookLibraryService().setBookInReadingSpace(bookId, true);
      await BookLibraryService().setBookInReadingSpace(secondBookId, true);
      await _addChapter(database, directory, bookId, '第一份资料');
      await _addChapter(database, directory, secondBookId, '第二份资料');
      await _addChapter(database, directory, secondBookId, '第三份资料');
      await AiConversationHistoryService.instance.save(
        AiConversationRecord.empty(bookId: bookId, bookName: '伴读测试书').copyWith(
          title: '常规读书记录',
          nodes: [
            AiConversationMessage(
              text: '上次的阅读问题',
              isUser: true,
              createdAt: DateTime(2026, 11, 20),
            ),
          ],
        ),
      );
      await _saveLegacyCompanion(
        bookId,
        title: '旧伴读记录',
        source: '第一份资料.epub',
        quote: '之前选中的一段话',
      );
      await _saveLegacyCompanion(
        bookId,
        title: '资料已移除的对话',
        source: '已移除的资料.epub',
        quote: '资料移除后保留的引文',
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
    final missingTarget = find.text('当前未在“阅读任务”选中目标资料，请先选择相应资料');
    await _waitFor(tester, missingTarget);
    expect(find.byType(ReadingCompanion), findsNothing);
    expect(find.text('阅读任务'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(missingTarget, findsNothing);

    await _checkModeHistory(tester, visible: '常规读书记录', hidden: '旧伴读记录');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _selectSidebarBook(tester, '另一本在读书');
    final multiSourceHome = find.text('《另一本在读书》');
    await _waitFor(tester, multiSourceHome);
    await tester.tap(find.byTooltip('沉浸伴读'));
    await _waitFor(tester, missingTarget);
    expect(find.byType(ReadingCompanion), findsNothing);
    expect(multiSourceHome, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await _selectSidebarBook(tester, '伴读测试书');
    final homeMessage = find.text('上次的阅读问题');
    await _waitFor(tester, homeMessage);
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
    final initialHomeX = tester.getCenter(homeMessage).dx;
    await tester.tap(find.byTooltip('沉浸伴读'));
    final reader = find.byType(ReadingCompanion);
    await _waitFor(tester, reader, settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getCenter(homeMessage).dx, lessThan(initialHomeX));
    final firstReaderX = tester.getTopLeft(reader).dx;
    expect(firstReaderX, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(reader).dx, inExclusiveRange(0, firstReaderX));
    await _waitFor(tester, find.text('目录'));
    expect(tester.getTopLeft(reader).dx, 0);
    expect(find.text('创建图像'), findsNothing);
    final initialReader = tester.state(reader);
    final body = find.text('这是一段测试原文。');
    await _waitFor(tester, body);
    await tester.tap(body);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsNothing);
    expect(find.byTooltip('AI 问答'), findsNothing);
    expect(find.bySemanticsLabel('打开侧边栏'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(body);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);
    expect(find.byTooltip('AI 问答'), findsOneWidget);
    expect(tester.state(reader), same(initialReader));
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: body,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == const Color(0xFF191B1E),
        ),
      ),
      findsWidgets,
    );
    await tester.tap(find.text('默认'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final doodle = find.widgetWithText(TextButton, '涂鸦');
    await _waitFor(tester, doodle);
    await tester.tap(doodle);
    await tester.pumpAndSettle();
    final finishInk = find.widgetWithText(FilledButton, '完成');
    expect(finishInk, findsOneWidget);
    await tester.dragFrom(tester.getCenter(body), const Offset(65, 4));
    await tester.pumpAndSettle();
    final center = tester.getCenter(body);
    final finger = await tester.startGesture(center);
    await finger.moveBy(const Offset(24, 1));
    final secondFinger = await tester.startGesture(
      center + const Offset(48, 1),
    );
    await secondFinger.moveBy(const Offset(18, 0));
    await secondFinger.up();
    await finger.up();
    await tester.pumpAndSettle();
    await tester.tap(finishInk);
    await _waitFor(tester, doodle);
    final inkCount = await tester.runAsync(() async {
      final rows = await db.query('companion_ink');
      final drawing = jsonDecode(rows.single['drawing']! as String) as Map;
      return (drawing['strokes'] as List).length;
    });
    expect(inkCount, 1);
    await tester.tap(find.bySemanticsLabel('打开侧边栏'));
    await _waitFor(tester, find.byType(ReadingSpaceSidebar));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(reader), same(initialReader));
    expect(find.byTooltip('退出伴读'), findsOneWidget);

    await _checkModeHistory(tester, visible: '旧伴读记录', hidden: '常规读书记录');
    await tester.tap(find.text('旧伴读记录'));
    Finder inReader(String text) => find.descendant(
      of: reader,
      matching: find.text(text, findRichText: true),
    );
    await _waitFor(tester, inReader('之前的伴读问题'));
    expect(inReader('之前保存的回答'), findsOneWidget);
    expect(inReader('之前选中的一段话'), findsOneWidget);
    expect(tester.state(reader), same(initialReader));
    expect(find.byTooltip('退出伴读'), findsOneWidget);
    final companionInput = find.descendant(
      of: reader,
      matching: find.byType(TextField),
    );
    final companionSend = find.descendant(
      of: reader,
      matching: find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '发送',
      ),
    );
    await tester.enterText(companionInput, '继续讨论');
    await tester.pump();
    expect(tester.widget<IconButton>(companionSend).onPressed, isNotNull);
    await tester.enterText(companionInput, '');
    tester.testTextInput.hide();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _openBookHistory(tester);
    await tester.tap(find.text('资料已移除的对话'));
    await _waitFor(tester, inReader('资料移除后保留的引文'));
    expect(inReader('之前保存的回答'), findsOneWidget);
    expect(inReader('无法定位这段对话的原资料，可查看已保存的记录'), findsOneWidget);
    expect(companionInput, findsNothing);
    expect(companionSend, findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _exerciseCompanionHistory(tester, companionInput, companionSend);

    await _selectSidebarBook(tester, '另一本在读书');
    await _waitFor(tester, find.text('第三份资料.epub'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(reader), same(initialReader));
    expect(
      tester.widget<ReadingCompanion>(reader).target!.source.displayName,
      '第一份资料.epub',
    );

    await _selectSidebarBook(tester, '另一本在读书');
    await _waitFor(tester, find.text('第三份资料.epub'));
    await tester.tap(find.text('第三份资料.epub'));
    await _waitFor(
      tester,
      find.byWidgetPredicate(
        (widget) =>
            widget is ReadingCompanion &&
            widget.target?.source.displayName == '第三份资料.epub',
      ),
    );
    await _waitFor(tester, find.text('目录'));
    expect(find.byTooltip('退出伴读'), findsOneWidget);

    await tester.tap(find.byTooltip('退出伴读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(reader).dx, greaterThan(0));
    await tester.pumpAndSettle();
    expect(reader, findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byTooltip('沉浸伴读'));
    await _waitFor(tester, reader, settle: false);
    expect(tester.getTopLeft(reader).dx, 0);
    await _waitFor(tester, find.text('目录'));
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

Future<void> _exerciseCompanionHistory(
  WidgetTester tester,
  Finder input,
  Finder send,
) async {
  final history = AiConversationHistoryService.instance;
  final reader = find.byType(ReadingCompanion);
  Future<List<AiConversationRecord>> records() => history.list(
    bookId: tester.widget<ReadingCompanion>(reader).bookId,
    companionMode: true,
  );
  final originalIds = (await records()).map((record) => record.id).toSet();

  Future<void> newFreeChat() async {
    await tester.tap(find.bySemanticsLabel('打开侧边栏'));
    final newChat = find.descendant(
      of: find.byType(ReadingSpaceSidebar),
      matching: find.text('新建会话'),
    );
    await _waitFor(tester, newChat);
    await tester.tap(newChat);
    await _waitFor(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is ReadingCompanion && widget.messages.isEmpty,
      ),
    );
    await _waitFor(tester, input);
    expect(find.byType(ReadingSpaceSidebar), findsNothing);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  }

  Future<AiConversationRecord> submit(String question) async {
    await tester.enterText(input, question);
    await tester.pump();
    await _waitFor(
      tester,
      find.descendant(
        of: reader,
        matching: find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == '发送' && w.onPressed != null,
        ),
      ),
      settle: false,
    );
    await tester.tap(send);
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      final saved = (await records())
          .where(
            (record) =>
                record.messages.any((m) => m.isUser && m.text == question),
          )
          .firstOrNull;
      if (saved != null) return saved;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    throw TestFailure('首问未写入伴读历史：$question');
  }

  await newFreeChat();
  await tester.enterText(input, '还没发出的自由问题');
  await tester.tap(find.byTooltip('关闭问答'));
  await tester.pumpAndSettle();
  expect((await records()).map((record) => record.id).toSet(), originalIds);

  final passage = find.byWidgetPredicate(
    (widget) => widget is SelectableText && widget.data == '这是一段测试原文。',
  );
  final selectionState = tester.state<EditableTextState>(
    find.descendant(of: passage, matching: find.byType(EditableText)),
  );
  final editable = selectionState.renderEditable;
  final caret = editable.getLocalRectForCaret(const TextPosition(offset: 3));
  await tester.longPressAt(
    editable.localToGlobal(caret.center + const Offset(2, 0)),
  );
  final ask = find.widgetWithText(TextButton, 'AI');
  await _waitFor(tester, ask);
  final value = selectionState.textEditingValue;
  final selectedText = value.selection.textInside(value.text);
  await tester.tap(ask);
  await _waitFor(tester, input);
  await _waitFor(
    tester,
    find.descendant(
      of: reader,
      matching: find.byWidgetPredicate(
        (w) => w is Text && w.data == selectedText,
      ),
    ),
  );
  expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  expect((await records()).map((record) => record.id).toSet(), originalIds);

  // Exercise the real local send/save path. The widget binding isolates HTTP.
  FlutterSecureStorage.setMockInitialValues({
    'xiaoqi.capabilities.device_token.v1': 'companion-test',
    'xiaoqi.auth.method.v1': 'email',
    'xiaoqi.auth.email.v1': 'reader@example.com',
  });
  final selected = await submit('我的选段问题');
  final savedPassage = selected.messages.first.readingPassage!;
  final quote = savedPassage
      .split('\n')
      .where((line) => line.startsWith('> '))
      .single
      .substring(2);
  expect(quote, isNotEmpty);
  expect(quote, selectedText);

  await newFreeChat();
  expect(
    find.descendant(of: reader, matching: find.text('我的选段问题')),
    findsNothing,
  );
  final free = await submit('我的自由问题');
  expect(free.id, isNot(selected.id));
  expect(free.companionSourceId, selected.companionSourceId);
  expect(free.messages.where((m) => m.isUser).single.readingPassage, isNull);
  expect((await records()).length, originalIds.length + 2);

  await _openBookHistory(tester);
  final sidebar = find.byType(ReadingSpaceSidebar);
  Finder row(String label) =>
      find.descendant(of: sidebar, matching: find.text(label));
  expect(
    tester.getCenter(row(free.displayTitle)).dy,
    lessThan(tester.getCenter(row(selected.displayTitle)).dy),
  );
  expect(row(quote), findsOneWidget);
  await tester.tap(row(selected.displayTitle));
  await _waitFor(
    tester,
    find.descendant(
      of: reader,
      matching: find.text('我的选段问题', findRichText: true),
    ),
  );
  await _waitFor(tester, input);
  final followup = await submit('继续追问刚才的原文');
  expect(followup.id, selected.id);
  expect(
    followup.messages.lastWhere((m) => m.isUser).readingPassage,
    savedPassage,
  );
  expect((await records()).length, originalIds.length + 2);
  await _openBookHistory(tester);
  expect(
    tester.getCenter(row(selected.displayTitle)).dy,
    lessThan(tester.getCenter(row(free.displayTitle)).dy),
  );
  await tester.tap(row(free.displayTitle));
  await _waitFor(
    tester,
    find.descendant(
      of: reader,
      matching: find.text('我的自由问题', findRichText: true),
    ),
  );
  await _waitFor(tester, input);
  expect(
    find.descendant(of: reader, matching: find.text('继续追问刚才的原文')),
    findsNothing,
  );
  await tester.tap(find.byTooltip('关闭问答'));
  await tester.pumpAndSettle();
  await _openBookHistory(tester);
  expect(
    tester.getCenter(row(free.displayTitle)).dy,
    lessThan(tester.getCenter(row(selected.displayTitle)).dy),
    reason: '只打开一条历史也应该更新最近使用顺序',
  );
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _checkModeHistory(
  WidgetTester tester, {
  required String visible,
  required String hidden,
}) async {
  await _openBookHistory(tester);
  expect(find.text(visible), findsOneWidget);
  expect(find.text(hidden), findsNothing);

  await tester.tap(find.bySemanticsLabel('搜索阅读空间'));
  await tester.pumpAndSettle();
  final search = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == '搜索会话',
  );
  await tester.enterText(search, hidden);
  await tester.pumpAndSettle();
  expect(find.text('无搜索结果'), findsOneWidget);
  await tester.enterText(search, '记录');
  await tester.pumpAndSettle();
  expect(find.text(visible, findRichText: true).hitTestable(), findsOneWidget);
  expect(find.text(hidden, findRichText: true).hitTestable(), findsNothing);
  await tester.tap(find.text('取消'));
  await tester.pumpAndSettle();
}

Future<void> _openBookHistory(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('打开侧边栏'));
  final expandBook = find.bySemanticsLabel('展开伴读测试书');
  await _waitFor(tester, expandBook);
  await tester.tap(expandBook);
  await tester.pumpAndSettle();
  await tester.tap(find.text('对话记录'));
  await tester.pumpAndSettle();
}

Future<void> _saveLegacyCompanion(
  int bookId, {
  required String title,
  required String source,
  required String quote,
}) async {
  final saved =
      AiConversationRecord.empty(bookId: bookId, bookName: '伴读测试书')
          .copyWith(
            title: title,
            messages: [
              AiConversationMessage(
                text: '之前的伴读问题',
                readingPassage: readingPassageMarkdown(
                  source: source,
                  locator: '第一章',
                  text: quote,
                ),
                isUser: true,
                createdAt: DateTime(2026, 11, 20),
              ),
              AiConversationMessage(
                text: '之前保存的回答',
                isUser: false,
                createdAt: DateTime(2026, 11, 20, 0, 1),
              ),
            ],
          )
          .toJson()
        ..remove('reading_companion');
  await AiConversationHistoryService.instance.save(
    AiConversationRecord.fromJson(saved),
  );
}

Future<void> _selectSidebarBook(WidgetTester tester, String title) async {
  await tester.tap(find.bySemanticsLabel('打开侧边栏'));
  final book = find.descendant(
    of: find.byType(ReadingSpaceSidebar),
    matching: find.text(title),
  );
  await _waitFor(tester, book);
  await tester.tap(book);
}

Future<void> _addChapter(
  Database database,
  Directory directory,
  int bookId,
  String title,
) async {
  final files = {
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    'book.opf':
        '<package><metadata><title>$title</title></metadata>'
        '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="chapter"/></spine></package>',
    'chapter.xhtml':
        '<html><head><title>$title</title></head><body><p>这是一段测试原文。</p></body></html>',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  final file = File('${directory.path}/$title.epub');
  final data = ZipEncoder().encode(archive);
  await file.writeAsBytes(data);
  await database.insert('book_sources', {
    'book_id': bookId,
    'format': 'epub',
    'display_name': '$title.epub',
    'file_path': file.path,
    'file_size': data.length,
    'content_hash': title,
    'status': 'ready',
    'created_at': '2026-11-20',
    'updated_at': '2026-11-20',
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

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  for (var attempt = 0; attempt < 80 && !finder.tryEvaluate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
  if (settle) await tester.pumpAndSettle();
}
