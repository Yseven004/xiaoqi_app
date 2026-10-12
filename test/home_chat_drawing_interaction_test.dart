import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/pages/drawing_board_page.dart';
import 'package:xiaoqi_app/services/home_chat_drawing_draft_store.dart';
import 'package:xiaoqi_app/widgets/home_chat_attachment_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late File drawingImage;
  late Uint8List drawingImageBytes;
  late int drawingImageByteLength;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'xiaoqi-drawing-widget-test-',
    );
    drawingImage = File('${tempDirectory.path}/drawing.png');
    final imageData = await rootBundle.load(
      'assets/icons/editor/draw_ballpoint.png',
    );
    drawingImageBytes = Uint8List.fromList(
      imageData.buffer.asUint8List(
        imageData.offsetInBytes,
        imageData.lengthInBytes,
      ),
    );
    await drawingImage.writeAsBytes(drawingImageBytes);
    drawingImageByteLength = await drawingImage.length();
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('drawing control icons are registered as app assets', () async {
    final check = await rootBundle.load('assets/icons/drawing/check.svg');
    final eraser = await rootBundle.load('assets/icons/drawing/eraser.svg');
    expect(check.lengthInBytes, greaterThan(0));
    expect(eraser.lengthInBytes, greaterThan(0));
  });

  testWidgets('tapping a drawing preview edits it instead of removing it', (
    tester,
  ) async {
    final attachment = HomeChatAttachment(
      id: 'drawing-1',
      name: '绘图.png',
      path: drawingImage.path,
      mimeType: 'image/png',
      byteLength: drawingImageByteLength,
      source: 'drawing',
      drawingDraftPath: '${tempDirectory.path}/draft.json',
    );
    var editCount = 0;
    var removeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeChatAttachmentTray(
            attachments: [attachment],
            onEditDrawing: (_) => editCount += 1,
            onRemove: (_) => removeCount += 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is FileImage,
    );
    await tester.tapAt(tester.getRect(preview).center);

    expect(editCount, 1);
    expect(removeCount, 0);
  });

  testWidgets('compact drawing toolbar has no overlapping hit targets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'compact-toolbar-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final eraserFinder = find.byKey(const ValueKey('drawing-tool-4'));
    final eraser = tester.getRect(eraserFinder);
    final historyMenu = tester.getRect(
      find.byKey(const ValueKey('drawing-undo')),
    );
    final expandRect = tester.getRect(
      find.byKey(const ValueKey('drawing-expand')),
    );
    expect(eraser.left, greaterThanOrEqualTo(0));
    expect(eraser.right, lessThanOrEqualTo(tester.view.physicalSize.width));
    expect(eraser.overlaps(historyMenu), isFalse);
    expect(eraser.overlaps(expandRect), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finish check and card stay fixed when keyboard opens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'finish-button-keyboard-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finishFinder = find.byKey(const ValueKey('drawing-finish-button'));
    final checkFinder = find.byKey(const ValueKey('drawing-finish-check'));
    final cardFinder = find.byKey(const ValueKey('drawing-canvas-card'));
    final initialButtonRect = tester.getRect(finishFinder);
    final initialCardRect = tester.getRect(cardFinder);
    expect(initialButtonRect.size, const Size(44, 44));
    expect(tester.getRect(checkFinder).size, const Size(22, 22));

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();

    expect(tester.getRect(finishFinder), initialButtonRect);
    expect(tester.getRect(cardFinder), initialCardRect);
    expect(tester.getRect(checkFinder).size, const Size(22, 22));
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawing card follows portrait and landscape paper ratios', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'drawing-card-ratio-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cardFinder = find.byKey(const ValueKey('drawing-canvas-card'));
    var cardRect = tester.getRect(cardFinder);
    expect(cardRect.width / cardRect.height, closeTo(0.75, 0.01));

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    cardRect = tester.getRect(cardFinder);
    expect(cardRect.width / cardRect.height, closeTo(1.6, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow popovers stay compact and do not pass taps to canvas', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'drawing-popover-hit-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cardRect = tester.getRect(
      find.byKey(const ValueKey('drawing-canvas-card')),
    );
    await tester.tap(find.byKey(const ValueKey('drawing-tool-color')));
    await tester.pumpAndSettle();
    final colorPopup = find.byKey(const ValueKey('drawing-color-popover'));
    final colorPopupRect = tester.getRect(colorPopup);
    expect(colorPopupRect.width, lessThanOrEqualTo(cardRect.width));
    expect(cardRect.contains(colorPopupRect.topLeft), isTrue);
    expect(cardRect.contains(colorPopupRect.bottomRight), isTrue);

    await tester.tapAt(Offset(cardRect.center.dx, cardRect.center.dy));
    await tester.pumpAndSettle();
    expect(colorPopup, findsNothing);
    final undoButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('drawing-undo')),
    );
    expect(undoButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('drawing-tool-4')));
    await tester.pumpAndSettle();
    final eraserPopup = find.byKey(const ValueKey('drawing-eraser-popover'));
    final eraserPopupRect = tester.getRect(eraserPopup);
    expect(eraserPopupRect.width, lessThanOrEqualTo(cardRect.width));
    expect(cardRect.contains(eraserPopupRect.topLeft), isTrue);
    expect(cardRect.contains(eraserPopupRect.bottomRight), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text input opens on field tap and blank tap inserts it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'drawing-inline-text-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('drawing-tool-2')));
    await tester.pumpAndSettle();
    final textFieldFinder = find.byKey(
      const ValueKey('drawing-inline-text-field'),
    );
    expect(textFieldFinder, findsOneWidget);
    final inlineTextBorder = tester.widget<CustomPaint>(
      find
          .ancestor(of: textFieldFinder, matching: find.byType(CustomPaint))
          .first,
    );
    expect(inlineTextBorder.foregroundPainter, isNotNull);
    var field = tester.widget<TextField>(textFieldFinder);
    expect(field.focusNode!.hasFocus, isFalse);

    await tester.tap(textFieldFinder);
    await tester.pump();
    field = tester.widget<TextField>(textFieldFinder);
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(textFieldFinder, '你好，小奇');
    await tester.pump();

    final cardRect = tester.getRect(
      find.byKey(const ValueKey('drawing-canvas-card')),
    );
    await tester.tapAt(
      Offset(
        cardRect.left + cardRect.width * .75,
        cardRect.top + cardRect.height * .7,
      ),
    );
    await tester.pumpAndSettle();

    expect(textFieldFinder, findsNothing);
    expect(
      find.byKey(const ValueKey('drawing-selected-object-frame')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pen and eraser stroke widths keep separate selections', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'drawing-independent-strokes-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final penStroke = find.byKey(const ValueKey('drawing-pen-stroke-2'));
    final eraserStroke = find.byKey(const ValueKey('drawing-eraser-stroke-30'));

    await tester.tap(find.byKey(const ValueKey('drawing-tool-color')));
    await tester.pumpAndSettle();
    await tester.tap(penStroke);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('drawing-tool-4')));
    await tester.pumpAndSettle();
    await tester.tap(eraserStroke);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drawing-tool-4')));
    await tester.pumpAndSettle();
    final eraserDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: eraserStroke,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(eraserDecoration.border, isNotNull);

    final cardRect = tester.getRect(
      find.byKey(const ValueKey('drawing-canvas-card')),
    );
    await tester.tapAt(cardRect.center);
    await tester.pumpAndSettle();

    // Opening the pen popover while eraser is active must still remember the
    // last pen width rather than reflecting the eraser width.
    await tester.tap(find.byKey(const ValueKey('drawing-tool-color')));
    await tester.pumpAndSettle();
    final penDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: penStroke,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(penDecoration.border, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'image picker gates other tools, then supports selection and rotation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pickerResult = Completer<Uint8List?>();
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        MaterialApp(
          home: DrawingBoardPage(
            conversationId: 'drawing-image-transform-test',
            accountScope: 'test',
            draftStore: _FakeDrawingDraftStore(),
            imagePicker: (_) => pickerResult.future,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('drawing-tool-5')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('drawing-tool-2'))),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('drawing-inline-text-field')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('drawing-tool-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上传图片'));
      await tester.pump();

      final textTool = tester.widget<InkWell>(
        find.byKey(const ValueKey('drawing-tool-2')),
      );
      expect(textTool.onTap, isNull);
      expect(find.text('上传图片'), findsNothing);
      expect(
        find.byKey(const ValueKey('drawing-inline-text-field')),
        findsNothing,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('drawing-tool-color')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<AbsorbPointer>(
              find.byKey(const ValueKey('drawing-canvas-edit-lock')),
            )
            .absorbing,
        isTrue,
      );
      expect(
        tester
            .widget<AbsorbPointer>(
              find.byKey(const ValueKey('drawing-object-edit-lock')),
            )
            .absorbing,
        isTrue,
      );

      pickerResult.complete(drawingImageBytes);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('图片导入失败'), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('drawing-tool-2')))
            .onTap,
        isNotNull,
      );
      expect(
        tester
            .widget<AbsorbPointer>(
              find.byKey(const ValueKey('drawing-canvas-edit-lock')),
            )
            .absorbing,
        isFalse,
      );

      final frameFinder = find.byKey(
        const ValueKey('drawing-selected-object-frame'),
      );
      final rotationHandleFinder = find.byKey(
        const ValueKey('drawing-image-rotation-handle'),
      );
      final deleteButtonFinder = find.byKey(
        const ValueKey('drawing-delete-image'),
      );
      expect(frameFinder, findsOneWidget);
      expect(rotationHandleFinder, findsOneWidget);
      expect(deleteButtonFinder, findsNothing);

      final cardRect = tester.getRect(
        find.byKey(const ValueKey('drawing-canvas-card')),
      );
      final frame = tester.widget<TransformableBox>(frameFinder);
      final imageRect = frame.rect.shift(cardRect.topLeft);
      final rotationHandleRect = tester.getRect(rotationHandleFinder);
      expect(rotationHandleRect.top, greaterThanOrEqualTo(imageRect.bottom));
      expect(cardRect.contains(rotationHandleRect.topLeft), isTrue);
      expect(cardRect.contains(rotationHandleRect.bottomRight), isTrue);

      final initialRotation = frame.rotation;
      await tester.tap(rotationHandleFinder);
      await tester.pumpAndSettle();
      final tappedFrame = tester.widget<TransformableBox>(frameFinder);
      expect(
        (tappedFrame.rotation - initialRotation).abs(),
        closeTo(math.pi / 12, .001),
      );

      final tappedImageRect = tappedFrame.rect.shift(cardRect.topLeft);
      final tappedRotationHandleRect = tester.getRect(rotationHandleFinder);
      final gesture = await tester.startGesture(
        tappedRotationHandleRect.center,
      );
      final center = tappedImageRect.center;
      final start = tappedRotationHandleRect.center - center;
      const rotationDelta = .45;
      final destination =
          center +
          Offset(
            start.dx * math.cos(rotationDelta) -
                start.dy * math.sin(rotationDelta),
            start.dx * math.sin(rotationDelta) +
                start.dy * math.cos(rotationDelta),
          );
      await gesture.moveTo(
        destination,
        timeStamp: const Duration(milliseconds: 180),
      );
      await tester.pump(const Duration(milliseconds: 180));
      await gesture.up();
      await tester.pumpAndSettle();
      final rotatedFrame = tester.widget<TransformableBox>(frameFinder);
      expect(rotatedFrame.rotation.abs(), greaterThan(.1));

      await tester.tapAt(tappedImageRect.center);
      await tester.pumpAndSettle();
      expect(deleteButtonFinder, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled image picker unlocks tools without stealing focus', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pickerResult = Completer<Uint8List?>();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'drawing-image-cancel-test',
          accountScope: 'test',
          draftStore: _FakeDrawingDraftStore(),
          imagePicker: (_) => pickerResult.future,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('drawing-tool-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传图片'));
    await tester.pump();
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('drawing-tool-2')))
          .onTap,
      isNull,
    );

    pickerResult.complete(null);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('上传图片'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('drawing-tool-2')));
    await tester.pumpAndSettle();
    final textField = tester.widget<TextField>(
      find.byKey(const ValueKey('drawing-inline-text-field')),
    );
    expect(textField.focusNode!.hasFocus, isFalse);

    await tester.tap(find.byKey(const ValueKey('drawing-inline-text-field')));
    await tester.pump();
    expect(textField.focusNode!.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _FakeDrawingDraftStore extends HomeChatDrawingDraftStore {
  _FakeDrawingDraftStore() : super(accountScope: 'test');

  @override
  Future<HomeChatDrawingDraft> open(
    String conversationId, {
    String? draftPath,
  }) async => HomeChatDrawingDraft(
    path: draftPath ?? '/test-drafts/$conversationId.json',
    document: const {'schemaVersion': 1, 'drawables': <Object?>[]},
    isEditing: draftPath != null,
  );

  @override
  Future<String?> save(
    String draftPath,
    Map<String, Object?> document, {
    Uint8List? backgroundBytes,
  }) async => null;

  @override
  Future<void> finish(String conversationId, String draftPath) async {}

  @override
  Future<void> reactivate(String conversationId, String draftPath) async {}

  @override
  Future<void> discard(
    String conversationId,
    HomeChatDrawingDraft draft,
  ) async {}
}
