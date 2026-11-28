import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/widgets/annotation_sheet.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_controls.dart';
import 'package:xiaoqi_app/widgets/companion_annotation_sheet.dart';

const _shortText = '这一段留给第二遍。';
const _quote = '难懂的段落，值得慢读。';
const _longQuote = '难懂的段落，值得慢读。有时正是那些一时难以理解的地方，蕴含着更深的思考与视野。';
const _captureKey = ValueKey('annotation-review-capture');
const _font = 'NotoSansCJKSC';
final _audioEvents = <String, MockStreamHandlerEventSink>{};
int _playRequests = 0;

void _mockAudio() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (_) async => null,
  );
  messenger.setMockStreamHandler(
    const EventChannel('xyz.luan/audioplayers.global/events'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (call) async {
      final id = (call.arguments as Map)['playerId'] as String;
      if (call.method == 'create') {
        messenger.setMockStreamHandler(
          EventChannel('xyz.luan/audioplayers/events/$id'),
          MockStreamHandler.inline(
            onListen: (_, events) {
              _audioEvents[id] = events;
            },
            onCancel: (_) {
              _audioEvents.remove(id);
            },
          ),
        );
      } else if (call.method == 'setSourceUrl') {
        _audioEvents[id]!.success({'event': 'audio.onPrepared', 'value': true});
        _audioEvents[id]!.success({
          'event': 'audio.onDuration',
          'value': 14000,
        });
      } else if (call.method == 'getDuration') {
        return 14000;
      } else if (call.method == 'getCurrentPosition') {
        return 0;
      } else if (call.method == 'resume') {
        _playRequests++;
      }
      return null;
    },
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_ANNOTATIONS')) return;
  final previousShadows = debugDisableShadows;
  try {
    // Widget tests normally replace elevated shadows with thick outlines.
    // Paint the real Material shadow when exporting component review images.
    debugDisableShadows = false;
    for (final element in find.byType(PhysicalShape).evaluate()) {
      element.renderObject!.markNeedsPaint();
    }
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('.codex-artifacts/annotation-design-review')
          ..createSync(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = previousShadows;
  }
}

Future<void> _host(
  WidgetTester tester,
  Size size,
  void Function(BuildContext) open, {
  bool settleOnOpen = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
          fontFamily: _font,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF96764C)),
          scaffoldBackgroundColor: Colors.white,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              title: const Text('阅读空间'),
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '真正的阅读，并不只是追求速度。它更像一次与作者的对话，需要我们放慢节奏，在字里行间停一停、想一想。\n\n$_longQuote\n\n当我们愿意在阅读中多停留一会儿，往往会发现，原本晦涩的内容，也会慢慢变得清晰而有意义。',
                    style: TextStyle(fontSize: 18, height: 1.8),
                  ),
                  TextButton(
                    onPressed: () => open(context),
                    child: const Text('打开注释'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开注释'));
  if (settleOnOpen) await _settle(tester);
}

void _expectSingleLineQuote(WidgetTester tester, [String quote = _quote]) {
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byType(AnnotationQuoteLine),
      matching: find.byType(Text),
    ),
  );
  expect(text.maxLines, 1);
  expect(text.softWrap, isFalse);
  expect(text.data, quote.replaceAll(RegExp(r'\s+'), ' '));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory fixtureDirectory;
  late String imagePath;
  late String audioPath;
  late Database db;
  late CompanionAnnotationSelection selection;
  const store = CompanionAnnotationStore();

  setUpAll(() async {
    // The plugin keeps a process-wide initialization future. Complete it in
    // the suite's real async zone, rather than the first widget test's clock.
    _mockAudio();
    await AudioPlayer.global.ensureInitialized();
    for (final family in [_font, 'Ahem', 'Roboto']) {
      await (FontLoader(
            family,
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
    fixtureDirectory = await Directory.systemTemp.createTemp(
      'xiaoqi-annotation-visual-',
    );
    imagePath = '${fixtureDirectory.path}/white-image.png';
    audioPath = '${fixtureDirectory.path}/audio-fixture.m4a';
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(80, 80);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(imagePath).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    // Only the platform metadata response is mocked; this is not an audio codec test.
    await File(audioPath).writeAsBytes([1, 2, 3]);
  });
  tearDownAll(() async => fixtureDirectory.delete(recursive: true));

  setUp(() async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    _audioEvents.clear();
    _playRequests = 0;
    _mockAudio();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final service = DatabaseService()..useDatabaseForTesting(db);
    await service.createForTesting(db);
    final bookId = await db.insert('books', {
      'canonical_key': 'annotation-visual-fixture',
      'title': '阅读示例',
      'created_at': '2026-11-25',
      'updated_at': '2026-11-25',
    });
    selection = CompanionAnnotationSelection(
      bookId: bookId,
      sourceId: 1,
      sourceVersion: 'visual-fixture',
      anchor: const PdfReaderAnchor(sourceId: '1', pageNumber: 1),
      locator: '第1页',
      quote: _quote,
    );
  });
  tearDown(() async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    DatabaseService().useDatabaseForTesting(null);
    await db.close();
  });

  testWidgets('an open annotation sheet follows window width changes', (
    tester,
  ) async {
    const contentKey = ValueKey('rotating-annotation-sheet');
    await _host(tester, const Size(390, 844), (context) {
      unawaited(
        showAnnotationSheet<void>(
          context,
          builder: (_) => const SizedBox(key: contentKey, height: 64),
        ),
      );
    });
    final content = find.byKey(contentKey);
    expect(tester.getSize(content).width, 390);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await _settle(tester);
    expect(tester.getSize(content).width, 844);
    expect(tester.getBottomLeft(content).dy, 210);
  });

  testWidgets('companion editor follows keyboard frames through photo picker', (
    tester,
  ) async {
    const size = Size(390, 844);
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final messenger = tester.binding.defaultBinaryMessenger;
    final picker = Completer<List<String>>();
    var picking = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickMultiImage');
      picking = true;
      return picker.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await _host(tester, size, (context) {
      unawaited(
        editCompanionAnnotation(context, scope: 'local', selection: selection),
      );
    }, settleOnOpen: false);

    final quote = find.byType(AnnotationQuoteLine);
    Future<void> checkInset(double inset) async {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getBottomLeft(quote).dy,
        closeTo(size.height - inset - 1, .5),
      );
    }

    for (final inset in [0.0, 100.0, 200.0, 300.0]) {
      await checkInset(inset);
    }
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focus.hasPrimaryFocus, isTrue);

    await tester.tap(find.byTooltip('添加图片'));
    await tester.pump();
    expect(picking, isTrue);
    for (final inset in [200.0, 100.0, 0.0]) {
      await checkInset(inset);
    }
    expect(focus.hasPrimaryFocus, isTrue);

    tester.testTextInput.log.clear();
    picker.complete([]);
    await tester.pump();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );
    for (final inset in [100.0, 200.0, 300.0]) {
      await checkInset(inset);
    }
    await tester.pump(const Duration(milliseconds: 20));

    for (final inset in [200.0, 100.0, 0.0]) {
      await checkInset(inset);
    }
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('home annotation keeps its draft and follows keyboard frames', (
    tester,
  ) async {
    const size = Size(390, 844);
    final picker = Completer<void>();
    var picking = false;
    await _host(tester, size, (context) {
      unawaited(
        showChatAnnotationComposer(
          context,
          initialText: _shortText,
          quote: _quote,
          onPickImages: (_) async {
            picking = true;
            await picker.future;
            return [];
          },
        ),
      );
    }, settleOnOpen: false);

    Future<void> checkInset(double inset) async {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getBottomLeft(find.byType(AnnotationQuoteLine)).dy,
        closeTo(size.height - inset, .5),
      );
    }

    await checkInset(140);
    await checkInset(300);
    await tester.tap(find.byTooltip('添加解释图'));
    await tester.pump();
    expect(picking, isTrue);
    await checkInset(180);
    await checkInset(0);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasPrimaryFocus, isTrue);
    expect(field.controller!.text, _shortText);

    picker.complete();
    await tester.pump();
    await checkInset(180);
    await checkInset(300);
    await tester.pump(const Duration(milliseconds: 20));
  });

  for (final size in [const Size(390, 844), const Size(800, 1280)]) {
    final width = size.width.toInt();
    testWidgets('detail and privacy preserve hierarchy at $width', (
      tester,
    ) async {
      final entry = CompanionAnnotation(
        id: 'fixture',
        revision: 'fixture-v1',
        selection: selection,
        text: _shortText,
        images: [imagePath],
        audio: [audioPath],
      );
      await _host(tester, size, (context) {
        unawaited(
          editCompanionAnnotation(
            context,
            scope: 'local',
            selection: selection,
            initial: entry,
          ),
        );
      });
      _expectSingleLineQuote(tester);
      expect(find.text('0:14'), findsOneWidget);
      expect(
        _playRequests,
        0,
        reason: 'Reading duration metadata must never autoplay.',
      );
      final field = find.byType(TextField);
      final body = tester.getRect(field);
      expect(tester.widget<TextField>(field).controller?.text, _shortText);
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isFalse);
      expect(find.byTooltip('编辑注释'), findsNothing);
      final audio = tester.getRect(find.text('0:14'));
      expect((body.center.dy - audio.center.dy).abs(), lessThan(10));
      final thumbnail = tester.getRect(find.byType(AnnotationThumbnails));
      expect(thumbnail.top, greaterThan(body.bottom));
      final action = tester.getRect(find.text('加入笔记库'));
      expect(action.top, greaterThan(thumbnail.bottom));
      final libraryButton = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('加入笔记库'),
          matching: find.byType(TextButton),
        ),
      );
      expect(
        libraryButton.style!.foregroundColor!.resolve({}),
        const Color(0xFF232427),
      );
      await _capture(tester, 'companion-detail-$width');

      final trigger = tester.getRect(find.text('私密'));
      await tester.tap(find.text('私密'));
      await tester.pump();
      final menuEntries = find.byType(PopupMenuItem<String>);
      expect(menuEntries, findsNWidgets(5));
      final firstFrame = tester.getRect(menuEntries.last);
      await _settle(tester);
      final lastItem = tester.getRect(menuEntries.last);
      expect(lastItem, firstFrame, reason: 'The menu opens at its full size.');
      expect(
        lastItem.bottom,
        lessThan(trigger.top),
        reason: 'The popup must leave its trigger visible.',
      );
      final selected = find.descendant(
        of: menuEntries.at(1),
        matching: find.text('私密'),
      );
      final tick = find.descendant(
        of: menuEntries.at(1),
        matching: find.byType(SvgPicture),
      );
      expect(
        tester.getRect(tick).center.dx,
        greaterThan(tester.getRect(selected).center.dx),
      );
      final unavailable = find.text('暂未开放');
      expect(unavailable, findsNWidgets(3));
      final rightEdges = [
        for (var i = 0; i < 3; i++) tester.getRect(unavailable.at(i)).right,
      ];
      expect(rightEdges[0], closeTo(rightEdges[1], 0.5));
      expect(rightEdges[1], closeTo(rightEdges[2], 0.5));
      await _capture(tester, 'companion-privacy-$width');
      await tester.tap(find.text('私密').last);
      await _settle(tester);
      if (width == 390) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _settle(tester);
        await tester.tap(find.text('私密'));
        await _settle(tester);
        final group = find.text('共读小组');
        final label = tester.widget<Text>(group);
        expect(label.style?.fontSize, 14);
        expect(MediaQuery.textScalerOf(tester.element(group)).scale(14), 28);
        expect(
          tester.getRect(group).right,
          lessThanOrEqualTo(tester.getRect(find.text('暂未开放').last).left),
        );
      }
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });

    testWidgets('long quote stays one line and remains readable at $width', (
      tester,
    ) async {
      final longSelection = CompanionAnnotationSelection(
        bookId: selection.bookId,
        sourceId: selection.sourceId,
        sourceVersion: selection.sourceVersion,
        anchor: selection.anchor,
        locator: selection.locator,
        quote: _longQuote,
      );
      await _host(tester, size, (context) {
        unawaited(
          editCompanionAnnotation(
            context,
            scope: 'local',
            selection: longSelection,
            initial: CompanionAnnotation(
              id: 'long-quote-fixture',
              revision: 'fixture-v1',
              selection: longSelection,
              text: _shortText,
              images: const [],
              audio: const [],
            ),
          ),
        );
      });
      _expectSingleLineQuote(tester, _longQuote);
      expect(
        tester.getSize(find.byType(AnnotationQuoteLine)).height,
        lessThan(40 * size.width / 390),
      );
      await tester.tap(find.byType(AnnotationQuoteLine));
      await _settle(tester);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        _longQuote,
        reason: 'Clipping the preview must never truncate the stored quote.',
      );
      await tester.tap(find.text('关闭'));
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });

    testWidgets(
      'editor keeps text and audio inline and saves existing edits on Back at $width',
      (tester) async {
        final entry = (await tester.runAsync(
          () => store.save(
            scope: 'local',
            selection: selection,
            text: _shortText,
            images: [imagePath],
            audio: [audioPath],
          ),
        ))!;
        CompanionAnnotation? result;
        var closed = false;
        await _host(tester, size, (context) {
          unawaited(
            editCompanionAnnotation(
              context,
              scope: 'local',
              selection: selection,
              initial: entry,
            ).then((value) {
              result = value;
              closed = true;
            }),
          );
        });
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await _settle(tester);
        _expectSingleLineQuote(tester);
        expect(find.text('0:14'), findsOneWidget);
        final fieldRect = tester.getRect(find.byType(TextField));
        final audioRect = tester.getRect(find.text('0:14'));
        expect((fieldRect.center.dy - audioRect.center.dy).abs(), lessThan(10));
        expect(audioRect.left, greaterThan(fieldRect.left));
        final quoteRect = tester.getRect(find.byType(AnnotationQuoteLine));
        expect(quoteRect.bottom, lessThanOrEqualTo(size.height - 300 + 1));
        await _capture(tester, 'companion-editor-inset300-$width');
        const editedText = '返回时保存这次修改';
        await tester.enterText(find.byType(TextField), editedText);
        await _settle(tester);
        expect(find.text('取消'), findsNothing);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(closed, isTrue);
        expect(result?.id, entry.id);
        expect(result?.text, editedText);
        expect(find.byType(TextField), findsNothing);
        final saved = await tester.runAsync(
          () => store.list('local', selection.bookId),
        );
        expect(saved!.single.text, editedText);
        expect(saved.single.images, [imagePath]);
        expect(saved.single.audio, [audioPath]);
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
      },
    );
  }

  for (final size in [const Size(390, 844), const Size(800, 1280)]) {
    final width = size.width.toInt();
    testWidgets(
      'new annotation requires Save and does not create a library note at $width',
      (tester) async {
        CompanionAnnotation? result;
        var closed = false;
        await _host(tester, size, (context) {
          unawaited(
            editCompanionAnnotation(
              context,
              scope: 'local',
              selection: selection,
            ).then((value) {
              result = value;
              closed = true;
            }),
          );
        });
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
              .onPressed,
          isNull,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await _settle(tester);
        expect(find.text('取消'), findsNothing);
        final input = tester.getRect(find.byType(TextField));
        final microphone = tester.getRect(find.byTooltip('开始录音'));
        final plus = tester.getRect(find.byTooltip('添加图片'));
        expect((input.center.dy - microphone.center.dy).abs(), lessThan(1));
        expect((input.center.dy - plus.center.dy).abs(), lessThan(1));
        final quote = tester.getRect(find.byType(AnnotationQuoteLine));
        expect(quote.top, greaterThan(input.bottom));
        await tester.enterText(find.byType(TextField), '尚未保存的新注释');
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(closed, isTrue);
        expect(result, isNull);
        expect(find.byType(TextField), findsNothing);
        expect(
          await tester.runAsync(() => store.list('local', selection.bookId)),
          isEmpty,
        );
        tester.view.resetViewInsets();
        await _settle(tester);
        await tester.tap(find.text('打开注释'));
        await _settle(tester);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '',
        );
        await tester.enterText(find.byType(TextField), '独立保存的阅读注释');
        await _settle(tester);
        await _capture(tester, 'companion-new-inset300-$width');
        await tester.tap(find.text('保存'));
        await _settle(tester);
        expect(result?.text, '独立保存的阅读注释');
        final rows = await tester.runAsync(() => db.query('notes'));
        expect(rows, isEmpty);
        final entries = await tester.runAsync(
          () => store.list('local', selection.bookId),
        );
        expect(entries!.single.id, result!.id);
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
      },
    );
  }
}
