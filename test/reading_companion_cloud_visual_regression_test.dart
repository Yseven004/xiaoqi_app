import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/widgets/reading_companion_explanation.dart';

const _canvasSize = Size(552, 734);
const _readerViewport = Rect.fromLTWH(18, 79, 516, 581);
const _selectionLines = [
  Rect.fromLTWH(47, 451, 397, 29),
  Rect.fromLTWH(47, 489, 341, 29),
];
const _approvedAnswer = '他把择校范围缩小到两所大学。\n两所学校都离多伦多较近。';
const _longAnswer =
    '这句话提到他把选择范围缩小到离多伦多较近的两所大学。\n\n'
    '结合前文，这个选择与他当时希望找到更适合自己的学习环境有关。\n\n'
    '如果继续看本节后面的经历，还能看到这段求学经历如何影响了他的专业选择。\n\n'
    '后面提到的课程和同学，也能帮助理解他为什么重视劳资关系和管理方式。\n\n'
    '这段话的重点是他的选择过程，而不是单纯列出学校的名称。\n\n'
    '再往后，文本会继续说明大学经历和他工作方式之间的联系。';
const _captureKey = ValueKey('cloud-visual-regression-capture');
const _cloudKey = ValueKey('cloud-visual-regression');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('ReadingCompanionVisualTest')
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

  testWidgets('cloud matches the approved reference placement', (tester) async {
    await _showCloud(tester, text: _approvedAnswer);
    await tester.pumpAndSettle();
    await _captureIfRequested(tester, 'baseline-final.png');

    final cloudRect = tester.getRect(find.byKey(_cloudKey));
    expect(cloudRect.center.dx, closeTo(_readerViewport.center.dx, 1));
    expect(cloudRect.height, closeTo(194, 1));
    final body = find.byKey(const ValueKey('cloud-explanation-body-viewport'));
    final answerText = find
        .descendant(of: body, matching: find.byType(Text))
        .first;
    expect(
      tester.getTopLeft(answerText).dx,
      closeTo(tester.getRect(body).left, 1),
    );
    expect(
      find.ancestor(
        of: body,
        matching: find.byKey(const ValueKey('cloud-outline-content-clip')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cloud remains closeable after growing while waiting for text', (
    tester,
  ) async {
    await _showCloud(tester, text: '', pending: true);
    await tester.pump();
    await _captureIfRequested(tester, 'cloud-growth-start.png');
    final close = find.byKey(const ValueKey('cloud-close-action'));
    final body = find.byKey(const ValueKey('cloud-explanation-body-viewport'));
    expect(close, findsNothing);
    expect(body, findsNothing);

    await tester.pump(const Duration(milliseconds: 240));
    await _captureIfRequested(tester, 'cloud-growth-240ms.png');
    await tester.pump(const Duration(milliseconds: 520));
    await _captureIfRequested(tester, 'cloud-growth-760ms.png');
    expect(close, findsNothing);

    await tester.pump(const Duration(milliseconds: 440));
    await _captureIfRequested(tester, 'cloud-growth-1200ms.png');
    expect(body, findsNothing);
    await tester.pump(const Duration(milliseconds: 280));
    expect(close.hitTestable(), findsOneWidget);
    expect(body, findsNothing);

    await _showCloud(tester, text: '回答到了。', pending: true);
    expect(body, findsOneWidget);
    expect(close.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _showCloud(tester, text: '两所候选学校都离多伦多较近。\n地理位置影响了他的选择。');
    await _captureIfRequested(tester, 'cloud-growth-answer.png');

    await _showCloud(tester, text: '回答到了。', pending: true, regenerating: true);
    await tester.pump(const Duration(milliseconds: 350));
    await _captureIfRequested(tester, 'cloud-growth-regeneration.png');
  });

  testWidgets('long answer remains clipped to the cloud while scrolling', (
    tester,
  ) async {
    await _showCloud(tester, text: _longAnswer);
    await tester.pumpAndSettle();

    final cloudFinder = find.byKey(_cloudKey);
    final cloudRect = tester.getRect(cloudFinder);
    final body = find.byKey(const ValueKey('cloud-explanation-body-viewport'));
    final scrollable = find.descendant(
      of: body,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      find.ancestor(
        of: body,
        matching: find.byKey(const ValueKey('cloud-outline-content-clip')),
      ),
      findsOneWidget,
    );

    await tester.drag(body, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(tester.getRect(cloudFinder), cloudRect);
    await _captureIfRequested(tester, 'after-scroll-middle.png');

    await tester.drag(body, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    await _captureIfRequested(tester, 'after-scroll-bottom.png');

    await tester.drag(body, const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(tester.getRect(cloudFinder), cloudRect);
    expect(tester.takeException(), isNull);
    await _captureIfRequested(tester, 'after-scroll-top.png');
  });
}

Future<void> _showCloud(
  WidgetTester tester, {
  String? text,
  bool pending = false,
  bool regenerating = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'ReadingCompanionVisualTest'),
      home: MediaQuery(
        data: const MediaQueryData(
          size: _canvasSize,
          devicePixelRatio: 1,
          disableAnimations: false,
          textScaler: TextScaler.noScaling,
        ),
        child: Scaffold(
          body: RepaintBoundary(
            key: _captureKey,
            child: ColoredBox(
              color: const Color(0xFFF7F7F7),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    left: 18,
                    right: 18,
                    top: 14,
                    height: 64,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(color: Color(0xFFE1E1E1)),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(28, 18, 18, 14),
                        child: Text('阅读空间', style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 50,
                    top: 105,
                    right: 50,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '第07节 女王大学',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 22, height: 1.25),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '安大略省金斯顿，1990—1991年\n'
                          '在多伦多的日子里，他开始考虑未来。\n申请之前，他反复比较过几所学校。',
                          style: TextStyle(fontSize: 16, height: 1.25),
                        ),
                      ],
                    ),
                  ),
                  for (final line in _selectionLines)
                    Positioned.fromRect(
                      rect: line,
                      child: const IgnorePointer(
                        child: ColoredBox(color: Color(0x443D526C)),
                      ),
                    ),
                  const Positioned(
                    left: 18,
                    right: 18,
                    bottom: 14,
                    height: 60,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          top: BorderSide(color: Color(0xFFE1E1E1)),
                        ),
                      ),
                      child: Center(child: Text('目录　　　 注释　　　 进度　　　 显示')),
                    ),
                  ),
                  ReadingCompanionExplanationCloud(
                    key: _cloudKey,
                    viewport: _readerViewport,
                    selection: Rect.fromLTRB(
                      _selectionLines.first.left,
                      _selectionLines.first.top,
                      _selectionLines.first.right,
                      _selectionLines.last.bottom,
                    ),
                    selectionRects: _selectionLines,
                    dark: false,
                    text: text ?? _approvedAnswer,
                    pending: pending,
                    regenerating: regenerating,
                    failed: false,
                    onDismiss: () {},
                    onRegenerate: () {},
                    onContinue: () {},
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
  const requested = String.fromEnvironment('CLOUD_REVIEW_CAPTURE');
  if (requested != fileName &&
      !(requested == 'motion' && fileName.startsWith('cloud-growth-'))) {
    return;
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '${Directory.current.path}/.codex-artifacts/design-review/$fileName',
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
