import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
import 'package:xiaoqi_app/models/reading_companion_evidence.dart';
import 'package:xiaoqi_app/pages/home_page.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/services/reading_task_context.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';
import 'package:xiaoqi_app/widgets/reading_companion_explanation.dart';
import 'package:xiaoqi_app/widgets/reading_space_sidebar.dart';
import 'package:xiaoqi_app/widgets/reflow_document_pager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('explanation cloud uses above, side, then lower space', (
    tester,
  ) async {
    const cloud = ValueKey('selection-cloud');
    const viewport = Rect.fromLTWH(20, 20, 700, 550);
    const belowMiddle = Rect.fromLTWH(110, 260, 210, 40);
    const nearTop = Rect.fromLTWH(110, 55, 210, 40);
    const fullLine = Rect.fromLTWH(50, 55, 660, 40);
    var continued = false;
    ReadingCompanionEvidence? opened;
    final evidence = ReadingCompanionEvidence.fromPayload([
      {'source_version': 'a' * 64, 'page': 2, 'locator': 'PDF 第 2 页'},
    ]);

    Future<Rect> show(Rect selection) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ReadingCompanionExplanationCloud(
                  key: cloud,
                  viewport: viewport,
                  selection: selection,
                  dark: false,
                  text: '这里的作者正在解释一个选择。',
                  pending: false,
                  failed: false,
                  onDismiss: () {},
                  onRegenerate: () {},
                  onContinue: () => continued = true,
                  evidence: evidence,
                  onOpenEvidence: (entry) => opened = entry,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byKey(cloud));
    }

    expect((await show(belowMiddle)).bottom, lessThan(belowMiddle.top));
    expect((await show(nearTop)).left, greaterThan(nearTop.right));
    expect((await show(fullLine)).top, greaterThan(fullLine.bottom));
    await tester.tap(find.text('继续聊'));
    expect(continued, isTrue);
    await tester.tap(find.textContaining('原文出处'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看原文 · PDF 第 2 页'));
    await tester.tap(find.text('查看原文 · PDF 第 2 页'));
    expect(opened?.page, 2);
  });

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
    final body = find.text('这是一段测试原文。');
    await _waitFor(tester, body);
    expect(tester.getTopLeft(reader).dx, 0);
    expect(find.text('创建图像'), findsNothing);
    final initialReader = tester.state(reader);
    final pager = find.byType(ReflowDocumentPager);
    final initialPager = tester.state(pager);
    final immersiveBodyRect = tester.getRect(body);
    final blank = tester.getRect(pager).center;
    expect(find.text('目录'), findsOneWidget);
    expect(find.byTooltip('AI 问答'), findsOneWidget);
    expect(find.bySemanticsLabel('打开侧边栏'), findsOneWidget);
    await tester.tapAt(blank);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsNothing);
    expect(tester.state(pager), same(initialPager));
    expect(find.byTooltip('AI 问答'), findsNothing);
    expect(find.bySemanticsLabel('打开侧边栏'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(body);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);
    expect(tester.getRect(body), immersiveBodyRect);
    await tester.tapAt(blank);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsNothing);
    await tester.tapAt(blank);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);
    expect(find.byTooltip('AI 问答'), findsOneWidget);
    expect(tester.state(reader), same(initialReader));
    expect(tester.state(pager), same(initialPager));
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暗夜'));
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
    await tester.tap(find.text('白天'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final doodle = find.widgetWithText(TextButton, '涂鸦');
    await _waitFor(tester, doodle);
    await tester.tap(doodle);
    await tester.pumpAndSettle();
    final finishInk = find.byTooltip('完成涂鸦');
    expect(finishInk, findsOneWidget);
    expect(find.text('目录'), findsNothing);
    final inkViewport = tester.getRect(reader);
    await tester.tap(find.byTooltip('文字'));
    await tester.pumpAndSettle();
    final inkTextField = find.byKey(
      const ValueKey('drawing-inline-text-field'),
    );
    await tester.showKeyboard(inkTextField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getRect(reader), inkViewport);
    expect(tester.getRect(body), immersiveBodyRect);
    expect(tester.widget<TextField>(inkTextField).focusNode!.hasFocus, isTrue);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(inkTextField, findsNothing);
    expect(tester.getRect(reader), inkViewport);
    await tester.tap(find.byTooltip('画笔'));
    await tester.pump();
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
    for (int i = 0; i < 100 && finishInk.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 12)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('目录'), findsNothing);
    await tester.tap(body);
    await _waitFor(tester, doodle);
    final inkCount = await tester.runAsync(() async {
      final rows = await db.query('companion_ink');
      final drawing = jsonDecode(rows.single['drawing']! as String) as Map;
      final document = drawing['drawingDocument'] as Map;
      return (document['drawables'] as List).length;
    });
    expect(inkCount, 1);
    await tester.tap(find.bySemanticsLabel('打开侧边栏'));
    await _waitFor(tester, find.byType(ReadingSpaceSidebar));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(reader), same(initialReader));
    expect(
      find.descendant(of: reader, matching: find.text('阅读空间')),
      findsOneWidget,
    );

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
    expect(
      find.descendant(of: reader, matching: find.text('阅读空间')),
      findsOneWidget,
    );
    final evidenceDisclosure = find.textContaining('原文出处');
    await _waitFor(tester, evidenceDisclosure);
    await tester.tap(evidenceDisclosure);
    final evidenceLink = find.widgetWithText(TextButton, '查看原文 · 第一章');
    await _waitFor(tester, evidenceLink);
    await tester.tap(evidenceLink);
    await _waitFor(tester, body);
    expect(
      find.byKey(const ValueKey('companion-discussion-page')),
      findsNothing,
    );
    expect(
      tester.widget<ReflowDocumentPager>(pager).initialAnchor?.blockId,
      isNotNull,
    );

    final bookId = tester.widget<ReadingCompanion>(reader).bookId!;
    const editionText = '这里是另一版资料的原文。';
    await tester.runAsync(() async {
      await _addChapter(db, directory, bookId, '原文版本', text: editionText);
      await _saveLegacyCompanion(
        bookId,
        title: '跨版本出处',
        source: '第一份资料.epub',
        quote: '之前选中的一段话',
        evidenceSource: '原文版本.epub',
        evidenceQuote: editionText,
      );
    });
    await _openBookHistory(tester);
    await tester.tap(find.text('跨版本出处'));
    await _waitFor(tester, evidenceLink);
    await tester.tap(evidenceLink);
    await _waitFor(tester, find.text(editionText));
    expect(
      tester.widget<ReadingCompanion>(reader).target!.source.displayName,
      '原文版本.epub',
    );
    await _waitFor(
      tester,
      find.byWidgetPredicate(
        (widget) =>
            widget is ReflowDocumentPager &&
            widget.initialAnchor?.blockId != null,
      ),
    );

    await _openBookHistory(tester);
    await tester.tap(find.text('旧伴读记录'));
    await _waitFor(tester, inReader('之前的伴读问题'));
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
      settle: false,
    );
    // Wait for the real file and database work before settling animations.
    await _waitFor(tester, body);
    await _waitFor(tester, find.text('目录'));
    expect(
      find.descendant(of: reader, matching: find.text('阅读空间')),
      findsOneWidget,
    );

    final spaceButton = find.descendant(
      of: reader,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '切换空间，当前为阅读空间',
      ),
    );
    final buttonRect = tester.getRect(spaceButton);
    await tester.tap(spaceButton);
    await tester.pumpAndSettle();
    final exitLabel = find.text('退出伴读');
    final menu = find
        .ancestor(of: exitLabel, matching: find.byType(SingleChildScrollView))
        .first;
    final menuRect = tester.getRect(menu);
    expect(menuRect.center.dx, closeTo(buttonRect.center.dx, 1));
    expect(menuRect.top, closeTo(buttonRect.bottom + 6, 1));
    expect(
      tester.getTopLeft(exitLabel).dx,
      closeTo(tester.getTopLeft(find.text('学习空间')).dx, 1),
    );
    Finder menuIcon(IconData icon) =>
        find.descendant(of: menu, matching: find.byIcon(icon));
    expect(
      tester.getCenter(menuIcon(Icons.exit_to_app)).dx,
      closeTo(tester.getCenter(menuIcon(Icons.check)).dx, 1),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    final compactMenu = tester.getRect(menu);
    final idealLeft = tester.getCenter(spaceButton).dx - compactMenu.width / 2;
    expect(
      compactMenu.left,
      closeTo(idealLeft.clamp(8, 382 - compactMenu.width), 1),
    );
    await tester.binding.setSurfaceSize(const Size(800, 1280));
    await tester.pumpAndSettle();
    await tester.tap(exitLabel);
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
    await _waitFor(tester, body);
    expect(find.text('目录'), findsOneWidget);
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
    await _returnFromDiscussion(tester);
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
  await tester.tap(find.widgetWithText(TextButton, '原文'));
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
  final customQuestion = find.widgetWithText(TextButton, '自定义提问');
  await _waitFor(tester, customQuestion);
  await tester.tap(customQuestion);
  await _waitFor(tester, input);
  final readerViewport = tester.getRect(reader);
  final documentViewport = tester.getRect(find.byType(ReflowDocumentPager));
  await _waitFor(
    tester,
    find.descendant(
      of: reader,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Text && w.data == selectedText.replaceAll(RegExp(r'\s+'), ' '),
      ),
    ),
  );
  await tester.showKeyboard(input);
  final chatPage = find.byKey(const ValueKey('companion-discussion-page'));
  expect(tester.getRect(chatPage), readerViewport);
  final keyboardInset = 420.0 * tester.view.devicePixelRatio;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  await tester.pumpAndSettle();
  expect(tester.getRect(reader), readerViewport);
  expect(tester.getRect(find.byType(ReflowDocumentPager)), documentViewport);
  final keyboardTop =
      readerViewport.bottom - keyboardInset / tester.view.devicePixelRatio;
  expect(tester.getRect(chatPage), readerViewport);
  expect(tester.getRect(input).bottom, lessThanOrEqualTo(keyboardTop));
  tester.testTextInput.hide();
  tester.widget<TextField>(input).focusNode!.unfocus();
  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
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
  final savedOrigin = AiConversationRecord.fromJson(
    selected.toJson(),
  ).companionPassageOrigin;
  expect(savedOrigin?.quote, selectedText);

  await tester.tap(find.byKey(const ValueKey('companion-discussion-quote')));
  await _waitFor(tester, find.text('原文选段'));
  await tester.tap(find.text('返回原文'));
  final markedPassage = find.byWidgetPredicate((widget) {
    if (widget is! SelectableText) return false;
    final marked = widget.textSpan?.children?.whereType<TextSpan>().where(
      (span) => span.style?.backgroundColor != null,
    );
    return marked?.map((span) => span.text).join() == selectedText;
  });
  await _waitFor(tester, markedPassage);
  expect(chatPage, findsNothing);

  final markedEditor = tester.state<EditableTextState>(
    find.descendant(of: markedPassage, matching: find.byType(EditableText)),
  );
  final markedRender = markedEditor.renderEditable;
  final markedCaret = markedRender.getLocalRectForCaret(
    const TextPosition(offset: 3),
  );
  await tester.longPressAt(
    markedRender.localToGlobal(markedCaret.center + const Offset(2, 0)),
  );
  await _waitFor(tester, ask);
  final activeSelection = markedEditor.textEditingValue.selection;
  expect(activeSelection.isCollapsed, isFalse);
  await tester.pump(const Duration(seconds: 7));
  expect(markedPassage, findsOneWidget);
  expect(markedEditor.textEditingValue.selection, activeSelection);
  markedEditor.userUpdateTextEditingValue(
    markedEditor.textEditingValue.copyWith(
      selection: TextSelection.collapsed(offset: activeSelection.extentOffset),
    ),
    SelectionChangedCause.tap,
  );
  await tester.pumpAndSettle();
  expect(markedPassage, findsNothing);

  await tester.tap(find.byTooltip('AI 问答'));
  await _waitFor(
    tester,
    find.descendant(of: chatPage, matching: find.text('我的选段问题')),
  );
  expect(
    find.byKey(const ValueKey('companion-discussion-quote')),
    findsOneWidget,
  );
  expect((await records()).length, originalIds.length + 1);

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

  await tester.tap(
    find.descendant(of: chatPage, matching: find.bySemanticsLabel('打开侧边栏')),
  );
  final sidebar = find.byType(ReadingSpaceSidebar);
  Finder row(String label) =>
      find.descendant(of: sidebar, matching: find.text(label));
  await _waitFor(tester, row(free.displayTitle));
  expect(chatPage, findsOneWidget);
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
  await tester.tap(find.widgetWithText(TextButton, '原文'));
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
  await _returnFromDiscussion(tester);
  await tester.tap(find.bySemanticsLabel('打开侧边栏'));
  final expandBook = find.bySemanticsLabel('展开伴读测试书');
  await _waitFor(tester, expandBook);
  await tester.tap(expandBook);
  await tester.pumpAndSettle();
  await tester.tap(find.text('对话记录'));
  await tester.pumpAndSettle();
}

Future<void> _returnFromDiscussion(WidgetTester tester) async {
  final discussion = find.byKey(const ValueKey('companion-discussion-page'));
  if (discussion.evaluate().isEmpty) return;
  await tester.tap(
    find.descendant(
      of: discussion,
      matching: find.widgetWithText(TextButton, '原文'),
    ),
  );
  await tester.pumpAndSettle();
  expect(discussion, findsNothing);
}

Future<void> _saveLegacyCompanion(
  int bookId, {
  required String title,
  required String source,
  required String quote,
  String? evidenceSource,
  String evidenceQuote = '这是一段测试原文。',
}) async {
  final local = (await BookLibraryService().listSourcesForBook(bookId))
      .where((item) => item.displayName == (evidenceSource ?? source))
      .firstOrNull;
  final evidence = ReadingCompanionEvidence.fromPayload([
    if (local != null)
      {
        'source_version': local.contentHash,
        'chapter_id': 'chapter',
        'href': 'chapter.xhtml',
        'locator': '第一章',
        'quote': evidenceQuote,
      },
  ]);
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
                readingEvidence: evidence,
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
  await _returnFromDiscussion(tester);
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
  String title, {
  String text = '这是一段测试原文。',
}) async {
  final files = {
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    'book.opf':
        '<package><metadata><title>$title</title></metadata>'
        '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="chapter"/></spine></package>',
    'chapter.xhtml':
        '<html><head><title>$title</title></head><body><p>$text</p></body></html>',
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
    'content_hash': sha256.convert(data).toString(),
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
