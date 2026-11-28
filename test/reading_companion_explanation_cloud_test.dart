import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/reading_companion_evidence.dart';
import 'package:xiaoqi_app/widgets/reading_companion_explanation.dart';

const _canvasSize = Size(800, 1280);
const _viewport = Rect.fromLTWH(20, 64, 760, 1138);
const _selection = Rect.fromLTWH(180, 724, 420, 44);
const _cloudKey = ValueKey('cloud-under-review');
const _captureKey = ValueKey('cloud-review-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('ReadingCompanionTest')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await font.load();
  });

  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = _canvasSize;
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets(
    'settled explanation cloud can be compared with the approved GIF',
    (tester) async {
      await _showCloud(tester, _approvedAnswer);
      await tester.pumpAndSettle();
      await _captureIfRequested(tester, 'after-settled.png');

      expect(find.byKey(_cloudKey), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
      expect(find.text('下一条'), findsNothing);
      expect(find.text('继续聊'), findsOneWidget);
      final cloudRect = tester.getRect(find.byKey(_cloudKey));
      final actionCenters = [
        tester.getCenter(find.text('重新生成')),
        tester.getCenter(find.text('继续聊')),
      ];
      expect(actionCenters[0].dx, lessThan(actionCenters[1].dx));
      expect(actionCenters.every((point) => cloudRect.contains(point)), isTrue);
      final close = tester.getRect(
        find.byKey(const ValueKey('cloud-close-action')),
      );
      final body = tester.getRect(
        find.byKey(const ValueKey('cloud-explanation-body-viewport')),
      );
      expect(body.right, lessThanOrEqualTo(close.left - 8));
      expect(body.top - cloudRect.top, closeTo(cloudRect.height * .225, 1));
      expect(close.center.dx, lessThan(cloudRect.right - 80));
      expect(close.center.dy, greaterThan(cloudRect.top + 48));
    },
  );

  testWidgets('answer switching stays centered between cloud actions', (
    tester,
  ) async {
    const size = Size(390, 844);
    const viewport = Rect.fromLTWH(0, 0, 390, 844);
    const selection = Rect.fromLTWH(24, 530, 342, 48);
    final view = tester.binding.platformDispatcher.views.single;
    view.physicalSize = size;
    view.devicePixelRatio = 1;

    await _showCloud(
      tester,
      _approvedAnswer,
      showSwitch: true,
      canvasSize: size,
      viewport: viewport,
      selection: selection,
    );
    await tester.pumpAndSettle();

    final regenerate = tester.getCenter(find.text('重新生成'));
    final switchAnswer = tester.getCenter(find.text('下一条'));
    final continueChat = tester.getCenter(find.text('继续聊'));
    final cloud = tester.getRect(find.byKey(_cloudKey));
    expect(regenerate.dx, lessThan(switchAnswer.dx));
    expect(switchAnswer.dx, lessThan(continueChat.dx));
    expect(switchAnswer.dx, closeTo(cloud.center.dx, 12));
  });

  testWidgets('phone width leaves enough room for text and footer actions', (
    tester,
  ) async {
    const phoneSize = Size(390, 844);
    const phoneViewport = Rect.fromLTWH(0, 0, 390, 844);
    const phoneSelection = Rect.fromLTWH(24, 530, 342, 48);
    final view = tester.binding.platformDispatcher.views.single;
    view.physicalSize = phoneSize;
    view.devicePixelRatio = 1;

    await _showCloud(
      tester,
      _approvedAnswer,
      canvasSize: phoneSize,
      viewport: phoneViewport,
      selection: phoneSelection,
    );
    await tester.pumpAndSettle();

    final cloud = tester.getRect(find.byKey(_cloudKey));
    final body = tester.getRect(
      find.byKey(const ValueKey('cloud-explanation-body-viewport')),
    );
    expect(cloud.width, closeTo(343.2, 0.1));
    expect(body.height, greaterThanOrEqualTo(70));
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.text('继续聊'), findsOneWidget);
  });

  testWidgets('large text switches the footer to horizontal scrolling', (
    tester,
  ) async {
    const size = Size(320, 844);
    const viewport = Rect.fromLTWH(0, 0, 320, 844);
    const selection = Rect.fromLTWH(10, 570, 300, 48);
    final view = tester.binding.platformDispatcher.views.single;
    view.physicalSize = size;
    view.devicePixelRatio = 1;

    await _showCloud(
      tester,
      _approvedAnswer,
      showSwitch: true,
      canvasSize: size,
      viewport: viewport,
      selection: selection,
      textScaler: const TextScaler.linear(2),
    );
    await tester.pumpAndSettle();

    final footer = find.byKey(const ValueKey('cloud-footer-overflow-scroll'));
    expect(footer, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('继续聊'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(footer).contains(tester.getCenter(find.text('继续聊'))),
      isTrue,
    );
  });

  testWidgets('compact pending state does not turn into continue chat', (
    tester,
  ) async {
    var continued = false;
    await _showCloud(
      tester,
      _approvedAnswer,
      pending: true,
      canvasSize: const Size(200, 600),
      viewport: const Rect.fromLTWH(0, 0, 200, 600),
      selection: const Rect.fromLTWH(20, 420, 150, 40),
      onContinueAction: () => continued = true,
    );
    await tester.pump(const Duration(milliseconds: 520));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const ValueKey('cloud-compact-progress-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('cloud-compact-continue-action')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('cloud-compact-progress-action')),
    );
    expect(continued, isFalse);
    await tester.ensureVisible(
      find.byKey(const ValueKey('cloud-compact-continue-action')),
    );
    await tester.tap(
      find.byKey(const ValueKey('cloud-compact-continue-action')),
    );
    expect(continued, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact failure keeps the old explanation entry', (
    tester,
  ) async {
    var continued = false;
    await _showCloud(
      tester,
      _approvedAnswer,
      failed: true,
      canvasSize: const Size(200, 600),
      viewport: const Rect.fromLTWH(0, 0, 200, 600),
      selection: const Rect.fromLTWH(20, 420, 150, 40),
      onContinueAction: () => continued = true,
    );
    await tester.pumpAndSettle();

    expect(find.text('重试解释'), findsOneWidget);
    expect(find.text('查看解释'), findsOneWidget);
    await tester.ensureVisible(find.text('查看解释'));
    await tester.tap(find.text('查看解释'));
    expect(continued, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entry grows from a fixed tail tip at the approved pace', (
    tester,
  ) async {
    await _showCloud(tester, _approvedAnswer);
    final cloudContext = tester.element(
      find.byType(ReadingCompanionExplanationCloud),
    );
    expect(MediaQuery.disableAnimationsOf(cloudContext), isFalse);
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byType(TweenAnimationBuilder<double>),
          )
          .duration,
      const Duration(milliseconds: 1480),
    );
    await tester.pump();

    final motion = find.byKey(const ValueKey('cloud-entry-growth'));
    final tail = find.byKey(const ValueKey('cloud-selection-tail'));
    Transform current() => tester.widget<Transform>(motion);
    final tip =
        tester.getBottomLeft(tail) + Offset(tester.getRect(tail).width / 2, 0);
    expect(current().transform.entry(0, 0), closeTo(.18, .01));
    expect(current().transform.entry(1, 1), closeTo(.33, .01));

    await tester.pump(const Duration(milliseconds: 760));
    expect(current().transform.entry(0, 0), closeTo(.66, .02));
    final movingTip =
        tester.getBottomLeft(tail) + Offset(tester.getRect(tail).width / 2, 0);
    expect((movingTip - tip).distance, lessThan(.01));
    expect(find.text(_approvedAnswer), findsNothing);

    await tester.pump(const Duration(milliseconds: 440));
    expect(current().transform.entry(0, 0), 1);
    expect(find.text(_approvedAnswer), findsNothing);
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.text(_approvedAnswer), findsOneWidget);
  });

  testWidgets('streaming and settled buttons stay in place without shadows', (
    tester,
  ) async {
    final regenerateAction = find.byKey(
      const ValueKey('cloud-regenerate-action'),
    );
    final continueAction = find.byKey(const ValueKey('cloud-continue-action'));
    await _showCloud(tester, _approvedAnswer);
    await tester.pumpAndSettle();
    final idleRegenerate = tester.getRect(regenerateAction);
    final idleContinue = tester.getRect(continueAction);
    await _showCloud(tester, _approvedAnswer, pending: true);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('生成中…'), findsOneWidget);
    final regenerate = tester.widget<TextButton>(
      find.byKey(const ValueKey('cloud-regenerate-action')),
    );
    final regenerateRect = tester.getRect(
      find.byKey(const ValueKey('cloud-regenerate-action')),
    );
    expect(regenerateRect, idleRegenerate);
    expect(tester.getRect(continueAction), idleContinue);
    final progressCenter = tester.getCenter(
      find.byType(CircularProgressIndicator),
    );
    expect(regenerateRect.contains(progressCenter), isTrue);
    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('cloud-close-action')),
    );
    expect(
      regenerate.style!.overlayColor!.resolve({WidgetState.pressed}),
      Colors.transparent,
    );
    expect(regenerate.style!.splashFactory, NoSplash.splashFactory);
    expect(
      close.style!.overlayColor!.resolve({WidgetState.pressed}),
      Colors.transparent,
    );
    expect(close.style!.splashFactory, NoSplash.splashFactory);
    expect(
      regenerate.style!.overlayColor!.resolve({WidgetState.focused}),
      isNot(Colors.transparent),
    );
    await _captureIfRequested(tester, 'after-loading.png');
  });

  testWidgets(
    'the cloud can copy the current explanation or a long-pressed selection',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      String? copied;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _showCloud(tester, _approvedAnswer, answerVersion: 1);
      await tester.pumpAndSettle();
      const visibleAnswer = 'First second';
      await _showCloud(tester, visibleAnswer, answerVersion: 2);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('cloud-copy-action')));
      await tester.pump();
      expect(copied, visibleAnswer);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final body = find.text(visibleAnswer);
      await tester.longPressAt(tester.getTopLeft(body) + const Offset(12, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 'First');
    },
  );

  testWidgets(
    'regeneration keeps the cloud in place and restores prior evidence',
    (tester) async {
      final evidence = ReadingCompanionEvidence.fromPayload([
        {'source_version': 'a' * 64, 'page': 2, 'locator': 'PDF 第 2 页'},
        {
          'source_version': 'a' * 64,
          'page': 2,
          'locator': 'PDF 第 2 页',
          'quote': '同一页的另一段',
        },
      ]);
      await _showCloud(tester, _approvedAnswer, evidence: evidence);
      await tester.pumpAndSettle();
      final cloud = find.byKey(_cloudKey);
      final position = tester.getRect(cloud);
      final sources = find.text('原文出处');
      expect(find.text('查看原文 · PDF 第 2 页'), findsNothing);
      await tester.ensureVisible(sources);
      await tester.tap(sources);
      await tester.pumpAndSettle();
      expect(find.text('查看原文 · PDF 第 2 页'), findsOneWidget);
      await tester.ensureVisible(sources);
      await tester.tap(sources);
      await tester.pumpAndSettle();
      await _showCloud(
        tester,
        _approvedAnswer,
        pending: true,
        regenerating: true,
        evidence: evidence,
      );
      expect(
        find.byKey(const ValueKey('cloud-regeneration-placeholder')),
        findsOneWidget,
      );
      expect(find.text(_approvedAnswer), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.getRect(cloud), position);
      await _showCloud(
        tester,
        _approvedAnswer,
        failed: true,
        evidence: evidence,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cloud-regeneration-placeholder')),
        findsNothing,
      );
      await tester.ensureVisible(sources);
      await tester.tap(sources);
      await tester.pumpAndSettle();
      expect(find.text('查看原文 · PDF 第 2 页'), findsOneWidget);
    },
  );

  testWidgets('new answer versions reset the explanation scroll position', (
    tester,
  ) async {
    final firstAnswer = List.filled(18, _approvedAnswer).join('\n\n');
    await _showCloud(tester, firstAnswer, answerVersion: 1);
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('cloud-explanation-body-viewport'));
    final scrollable = find.descendant(
      of: body,
      matching: find.byType(Scrollable),
    );
    await tester.drag(body, const Offset(0, -320));
    await tester.pumpAndSettle();
    final scrolledPosition = tester.state<ScrollableState>(scrollable.first);
    expect(scrolledPosition.position.pixels, greaterThan(0));

    final secondAnswer = List.filled(18, '这是另一版解释的开头。').join('\n\n');
    await _showCloud(tester, secondAnswer, answerVersion: 2);
    await tester.pumpAndSettle();
    final resetPosition = tester.state<ScrollableState>(scrollable.first);
    expect(resetPosition.position.pixels, 0);
    expect(tester.getTopLeft(find.text(secondAnswer)).dy, greaterThan(0));
  });

  testWidgets('irregular multiline selection can use a clear side gap', (
    tester,
  ) async {
    const viewport = Rect.fromLTWH(20, 0, 700, 550);
    const lines = [
      Rect.fromLTWH(40, 60, 640, 20),
      Rect.fromLTWH(60, 86, 130, 20),
      Rect.fromLTWH(40, 112, 160, 20),
    ];
    const bounds = Rect.fromLTWH(40, 60, 640, 72);
    await _showCloud(
      tester,
      _approvedAnswer,
      canvasSize: const Size(800, 800),
      viewport: viewport,
      selection: bounds,
      selectionRects: lines,
    );
    await tester.pumpAndSettle();

    final cloud = tester.getRect(find.byKey(_cloudKey));
    expect(cloud.width, greaterThan(222));
    expect(cloud.left, greaterThan(lines.last.right));
    expect(cloud.top, lessThan(bounds.bottom));
    final sideTail = tester.widget<Positioned>(
      find.byKey(const ValueKey('cloud-selection-tail')),
    );
    expect(sideTail.top, closeTo(lines[2].center.dy - cloud.top - 9, 1));
    expect(cloud.left + sideTail.left!, closeTo(lines[2].right + 2, 1));
    expect(sideTail.width, greaterThan(16));
    expect(sideTail.left! + sideTail.width!, greaterThan(0));
    expect(tester.takeException(), isNull);
    await _captureIfRequested(tester, 'after-multiline-side.png');
  });

  testWidgets(
    'left side tail joins the cloud outline and points to selection',
    (tester) async {
      const viewport = Rect.fromLTWH(20, 0, 700, 550);
      const selection = Rect.fromLTWH(500, 112, 160, 20);
      await _showCloud(
        tester,
        _approvedAnswer,
        canvasSize: const Size(800, 800),
        viewport: viewport,
        selection: selection,
        selectionRects: const [selection],
      );
      await tester.pumpAndSettle();

      final cloud = tester.getRect(find.byKey(_cloudKey));
      expect(cloud.right, lessThan(selection.left));
      final sideTail = tester.widget<Positioned>(
        find.byKey(const ValueKey('cloud-selection-tail')),
      );
      expect(cloud.top + sideTail.top! + 9, closeTo(selection.center.dy, 1));
      expect(
        cloud.left + sideTail.left! + sideTail.width!,
        closeTo(selection.left - 2, 1),
      );
      expect(sideTail.width, greaterThan(16));
      expect(tester.takeException(), isNull);
      await _captureIfRequested(tester, 'after-left-side.png');
    },
  );

  testWidgets('above and below tails point to the nearest selected line', (
    tester,
  ) async {
    const aboveViewport = Rect.fromLTWH(20, 0, 700, 800);
    const aboveLines = [
      Rect.fromLTWH(40, 300, 460, 20),
      Rect.fromLTWH(40, 340, 640, 20),
    ];
    await _showCloud(
      tester,
      _approvedAnswer,
      canvasSize: const Size(800, 800),
      viewport: aboveViewport,
      selection: const Rect.fromLTWH(40, 300, 640, 60),
      selectionRects: aboveLines,
    );
    await tester.pumpAndSettle();

    final aboveTail = tester.widget<Positioned>(
      find.byKey(const ValueKey('cloud-selection-tail')),
    );
    expect(aboveTail.left, closeTo(236, 1));

    const belowViewport = Rect.fromLTWH(20, 0, 700, 550);
    const belowLines = [
      Rect.fromLTWH(40, 60, 640, 20),
      Rect.fromLTWH(40, 100, 460, 20),
    ];
    await _showCloud(
      tester,
      _approvedAnswer,
      canvasSize: const Size(800, 800),
      viewport: belowViewport,
      selection: const Rect.fromLTWH(40, 60, 640, 60),
      selectionRects: belowLines,
    );
    await tester.pumpAndSettle();

    final belowTail = tester.widget<Positioned>(
      find.byKey(const ValueKey('cloud-selection-tail')),
    );
    expect(belowTail.left, closeTo(236, 1));
  });

  testWidgets('long explanation scroll stays inside its cloud viewport', (
    tester,
  ) async {
    await _showCloud(tester, List.filled(18, _approvedAnswer).join('\n\n'));
    await tester.pumpAndSettle();

    final cloud = find.byKey(_cloudKey);
    final body = find.byKey(const ValueKey('cloud-explanation-body-viewport'));
    final initialCloudRect = tester.getRect(cloud);
    final initialBodyRect = tester.getRect(body);
    expect(
      initialBodyRect.left - initialCloudRect.left,
      greaterThanOrEqualTo(53),
    );
    expect(
      initialCloudRect.right - initialBodyRect.right,
      greaterThanOrEqualTo(53),
    );
    final answerText = find
        .descendant(of: body, matching: find.byType(Text))
        .first;
    final initialTextTop = tester.getTopLeft(answerText).dy;

    await tester.drag(body, const Offset(0, -72));
    await tester.pumpAndSettle();

    expect(tester.getRect(cloud), initialCloudRect);
    expect(tester.getRect(body), initialBodyRect);
    expect(tester.getTopLeft(answerText).dy, lessThan(initialTextTop));
    await _captureIfRequested(tester, 'after-long-answer-scroll.png');
  });
}

Future<void> _showCloud(
  WidgetTester tester,
  String text, {
  bool pending = false,
  bool regenerating = false,
  bool failed = false,
  bool showSwitch = false,
  Size canvasSize = _canvasSize,
  Rect viewport = _viewport,
  Rect selection = _selection,
  List<Rect> selectionRects = const [],
  Object? answerVersion,
  TextScaler textScaler = TextScaler.noScaling,
  List<ReadingCompanionEvidence> evidence = const [],
  VoidCallback? onContinueAction,
}) async {
  final highlightedRects = selectionRects.isEmpty
      ? [selection]
      : selectionRects;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'ReadingCompanionTest'),
      home: MediaQuery(
        data: MediaQueryData(
          size: canvasSize,
          devicePixelRatio: 1,
          disableAnimations: false,
          textScaler: textScaler,
        ),
        child: Scaffold(
          body: RepaintBoundary(
            key: _captureKey,
            child: ColoredBox(
              color: Colors.white,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    left: 40,
                    right: 40,
                    top: 200,
                    child: Text(
                      '第07节 女王大学\n\n安大略省金斯顿，1990—1991年\n'
                      '他把选择范围缩小到离多伦多较近的两所大学。\n\n'
                      '劳资关系\n\n马斯克的大学入学考试成绩并不亮眼。',
                      style: TextStyle(fontSize: 20, height: 1.6),
                    ),
                  ),
                  for (final rect in highlightedRects)
                    Positioned.fromRect(
                      rect: rect,
                      child: const IgnorePointer(
                        child: ColoredBox(color: Color(0x443D526C)),
                      ),
                    ),
                  ReadingCompanionExplanationCloud(
                    key: _cloudKey,
                    viewport: viewport,
                    selection: selection,
                    selectionRects: selectionRects,
                    answerVersion: answerVersion,
                    dark: false,
                    text: text,
                    pending: pending,
                    regenerating: regenerating,
                    failed: failed,
                    onDismiss: () {},
                    onRegenerate: () {},
                    onContinue: onContinueAction ?? () {},
                    onSwitchAnswer: showSwitch ? () {} : null,
                    showingPrevious: showSwitch,
                    evidence: evidence,
                    onOpenEvidence: evidence.isEmpty ? null : (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _captureIfRequested(WidgetTester tester, String fileName) async {
  if (const String.fromEnvironment('CLOUD_REVIEW_CAPTURE') != fileName) return;

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final path =
        '${Directory.current.path}/.codex-artifacts/design-review/$fileName';
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

const _approvedAnswer = '他把择校范围缩小到离多伦多较近的两所大学。距离是当时的一个考虑因素。';
