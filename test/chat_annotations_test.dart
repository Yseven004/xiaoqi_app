import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_painter/flutter_painter.dart';
import 'package:xiaoqi_app/models/chat_annotation.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/pages/drawing_board_page.dart';
import 'package:xiaoqi_app/services/home_chat_drawing_draft_store.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_controls.dart';
import 'package:xiaoqi_app/widgets/chat_image_gallery.dart';
import 'package:xiaoqi_app/widgets/message_selection_action_card.dart';

Future<Uint8List> pictureBytes({int width = 120, int height = 80}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xFFEEEEEE), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) fail('等待界面状态超时');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'quote matching keeps the selected repeated occurrence after reflow',
    () {
      const text = '重复原文\n前一段\n重复\n  原文\n结尾';
      final location = locateChatQuote(text, '重复 原文', 11);
      expect(location, isNotNull);
      expect(location!.start, 9);
      expect(
        text
            .substring(location.start, location.end)
            .replaceAll(RegExp(r'\s+'), ' '),
        '重复 原文',
      );
      expect(locateChatQuote(text, '已消失的原文', 0), isNull);
    },
  );

  test('local attachment copies keep original and editable metadata', () {
    final a = HomeChatAttachment(
      id: 'image-a',
      name: '标注.png',
      path: '/snapshot.png',
      mimeType: 'image/png',
      byteLength: 100,
      source: 'drawing',
      originalImagePath: '/original.jpg',
      originalImageName: '原图.jpg',
      annotationImagePath: '/clean.png',
      annotationSnapshotDirty: true,
      imageAnnotations: const [
        ChatAnnotation(
          id: 'pin',
          attachmentId: 'image-a',
          comment: '改这里',
          x: .2,
          y: .7,
        ),
      ],
    );
    final restored = HomeChatAttachment.fromJson(
      jsonDecode(jsonEncode(a.toJson())),
    ).copyWith(remoteAttachmentId: 'remote');
    expect(restored.originalImagePath, '/original.jpg');
    expect(restored.originalImageName, '原图.jpg');
    expect(restored.annotationImagePath, '/clean.png');
    expect(restored.imageAnnotations.single.x, .2);
    expect(restored.annotationSnapshotDirty, isTrue);
    expect(
      restored.copyWith(annotationSnapshotDirty: false).annotationSnapshotDirty,
      isFalse,
    );
    expect(restored.copyWith(imageAnnotations: []).imageAnnotations, isEmpty);
  });

  test(
    'annotation-only prompt binds image numbering separately for each image',
    () {
      final text = appendChatAnnotations(
        '',
        const [
          ChatAnnotation(
            id: 't',
            messageId: 'reply-v2',
            quote: '原文\n下一行',
            startOffset: 4,
            endOffset: 10,
            sourceHash: 'hash',
          ),
          ChatAnnotation(
            id: 'a1',
            attachmentId: 'a',
            comment: '左边',
            x: .1,
            y: .4,
          ),
          ChatAnnotation(
            id: 'b1',
            attachmentId: 'b',
            comment: '右边',
            x: .9,
            y: .4,
          ),
          ChatAnnotation(
            id: 'a2',
            attachmentId: 'a',
            comment: '下方',
            x: .5,
            y: .8,
          ),
        ],
        attachmentNames: const {'a': 'A.png', 'b': 'B.png'},
      );
      expect(text, startsWith('请根据以下注释'));
      expect(text, contains('> 原文\n> 下一行'));
      expect(text, contains('图片：A.png；图中编号 2'));
      expect(text, contains('图片：B.png；图中编号 1'));
      expect(text, contains('从左 10.0%'));
      expect(
        ChatAnnotation.fromJson(const {'id': 'bad', 'x': 2, 'y': -1}).x,
        1,
      );
    },
  );

  test(
    'numbered export preserves aspect and never modifies original bytes',
    () async {
      final original = await pictureBytes();
      final copy = Uint8List.fromList(original);
      final output = await renderChatAnnotatedImage(original, const [
        ChatAnnotation(id: 'p', attachmentId: 'a', x: .5, y: .5, comment: '这里'),
      ]);
      expect(original, orderedEquals(copy));
      expect(output, isNot(orderedEquals(original)));
      final codec = await ui.instantiateImageCodec(output);
      final frame = await codec.getNextFrame();
      codec.dispose();
      expect(frame.image.width, 120);
      expect(frame.image.height, 80);
      frame.image.dispose();
      final tiny = await pictureBytes(width: 1, height: 1);
      expect(
        await renderChatAnnotatedImage(tiny, const [
          ChatAnnotation(id: 'p', attachmentId: 'a'),
        ]),
        isNotEmpty,
      );
    },
  );

  test(
    'image editing fork does not replace the normal active drawing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'xiaoqi-annotation-fork-',
      );
      try {
        final store = HomeChatDrawingDraftStore(
          rootDirectory: directory,
          accountScope: 'test',
        );
        final original = await store.open('conversation');
        await store.save(original.path, const {
          'schemaVersion': 1,
          'drawables': [],
        }, backgroundBytes: await pictureBytes());
        final fork = await store.fork(
          'conversation',
          sourcePath: original.path,
          backgroundBytes: await pictureBytes(),
        );
        expect(fork.path, isNot(original.path));
        expect((await store.open('conversation')).path, original.path);
        await store.delete('conversation', fork.path);
        expect(await File(original.path).exists(), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('text anchors follow reflow and open the latest comment', (
    tester,
  ) async {
    var width = 300.0;
    var comment = '原评论';
    String? opened;
    Widget screen() => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ChatTextAnnotationLayer(
              annotations: [
                ChatAnnotation(
                  id: 'quote',
                  quote: '目标原文',
                  comment: comment,
                  startOffset: 10,
                ),
              ],
              onTapAnnotation: (annotation, _) => opened = annotation.comment,
              child: const Text('这是稍长的开头。目标原文。后面还有一些内容，供换行使用。'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.byType(ChatAnnotationPin), findsOneWidget);
    void expectPinOnQuote() {
      final paragraph = tester.renderObject<RenderBox>(
        find.text('这是稍长的开头。目标原文。后面还有一些内容，供换行使用。'),
      );
      final boxes = chatTextQuoteBoxes(
        paragraph,
        const ChatAnnotation(id: 'quote', quote: '目标原文', startOffset: 10),
      );
      expect(
        tester.getTopLeft(find.byType(ChatAnnotationPin)) +
            ChatAnnotationPin.textAnchor,
        paragraph.localToGlobal(boxes.last.bottomRight),
      );
    }

    expectPinOnQuote();
    final before = tester.getTopLeft(find.byType(ChatAnnotationPin));
    width = 140;
    comment = '已修改评论';
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(ChatAnnotationPin)), isNot(before));
    expectPinOnQuote();
    await tester.tap(find.byType(ChatAnnotationPin));
    expect(opened, '已修改评论');
  });

  testWidgets(
    'dismissing an unsubmitted comment cancels without blocking the outside tap',
    (tester) async {
      String? comment;
      var completed = false;
      var outsideTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () async {
                      comment = await showChatAnnotationComment(
                        context,
                        initialText: '',
                        anchor: const Offset(300, 300),
                      );
                      completed = true;
                    },
                    child: const Text('注释'),
                  ),
                  TextButton(
                    onPressed: () => outsideTaps++,
                    child: const Text('其他原文'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('注释'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留这段评论');
      expect(tester.getTopLeft(find.byType(ChatAnnotationInput)).dy, 308);
      await tester.tap(find.text('其他原文'));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(comment, isNull);
      expect(outsideTaps, 1);
      expect(find.byType(ChatAnnotationInput), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only explicit submission commits a nonempty comment', (
    tester,
  ) async {
    String? comment;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                comment = await showChatAnnotationComment(
                  context,
                  initialText: '',
                  anchor: const Offset(300, 200),
                );
              },
              child: const Text('注释'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('注释'));
    await tester.pumpAndSettle();
    IconButton submit() => tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '确认评论',
      ),
    );
    expect(submit().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    expect(submit().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  已保存注释  ');
    await tester.pump();
    expect(comment, isNull);
    expect(submit().onPressed, isNotNull);
    await tester.tap(find.byTooltip('确认评论'));
    await tester.pumpAndSettle();
    expect(comment, '已保存注释');
    expect(find.byType(ChatAnnotationInput), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsaved text draft has no numbered pin', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTextAnnotationLayer(
            annotations: [],
            draft: const ChatAnnotation(id: 'draft', quote: '选中原文'),
            onTapAnnotation: (_, _) {},
            child: const Text('这里是选中原文。'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatAnnotationPin), findsNothing);
  });

  testWidgets(
    'review editing follows the keyboard and cancels on keyboard dismissal',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      String? comment;
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              resizeToAvoidBottomInset: false,
              body: TextButton(
                onPressed: () async {
                  comment = await showChatAnnotationComment(
                    context,
                    initialText: '原注释',
                    anchor: Offset.zero,
                    dockToKeyboard: true,
                  );
                  completed = true;
                },
                child: const Text('修改'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('修改'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(ChatAnnotationInput)).bottom, 692);
      await tester.enterText(find.byType(TextField), '尚未保存');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(comment, isNull);
      expect(find.byType(ChatAnnotationInput), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection menu places annotation between note and copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageSelectionActionCard(
            primaryLabel: '做笔记',
            primaryAsset: 'assets/images/home_reply_note.svg',
            onPrimaryAction: () {},
            onAnnotate: () {},
            onCopy: () {},
          ),
        ),
      ),
    );
    expect(
      tester.getCenter(find.text('做笔记')).dx,
      lessThan(tester.getCenter(find.text('注释')).dx),
    );
    expect(
      tester.getCenter(find.text('注释')).dx,
      lessThan(tester.getCenter(find.text('复制')).dx),
    );
  });

  testWidgets(
    'gallery keeps comments per image and finishes all changed images',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = await tester.runAsync(pictureBytes);
      List<ChatImageEdit>? completed;
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatImageGallery(
            images: [
              ChatImageSource(
                id: 'a',
                name: 'A.png',
                loadOriginal: () async => bytes!,
              ),
              ChatImageSource(
                id: 'b',
                name: 'B.png',
                loadOriginal: () async => bytes!,
              ),
            ],
            initialIndex: 0,
            conversationId: 'test',
            accountScope: 'test',
            onComplete: (edits) async {
              if (attempts++ == 0) throw StateError('测试保存失败');
              completed = edits;
            },
          ),
        ),
      );
      await waitFor(
        tester,
        () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('注释'));
      await tester.pump();
      await tester.tapAt(
        tester.getRect(find.byType(InteractiveViewer).first).center,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '第一张评论');
      await tester.tap(find.byTooltip('确认评论'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () =>
            find.text('2 / 2').evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('gallery-viewer:b'))
                .evaluate()
                .isNotEmpty,
      );
      await tester.tapAt(
        tester.getRect(find.byKey(const ValueKey('gallery-viewer:b'))).center,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '第二张评论');
      await tester.tap(find.byTooltip('确认评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(completed, isNull);
      expect(find.text('2 条注释'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注释'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(completed, hasLength(2));
      expect(completed![0].annotations.single.comment, '第一张评论');
      expect(completed![1].annotations.single.comment, '第二张评论');
      expect(completed![0].originalBytes, orderedEquals(bytes!));
    },
  );

  testWidgets(
    'marking stays in the image viewer without a board card or route',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('xiaoqi-inline-drawing-'),
      ))!;
      final binding =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      binding.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      addTearDown(() async {
        binding.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final bytes = await tester.runAsync(pictureBytes);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatImageGallery(
            images: [
              ChatImageSource(
                id: 'inline',
                name: '原图.png',
                loadOriginal: () async => bytes!,
              ),
            ],
            initialIndex: 0,
            conversationId: 'test',
            accountScope: 'test',
            onComplete: (_) async {},
          ),
        ),
      );
      await waitFor(
        tester,
        () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('标注'));
      await waitFor(
        tester,
        () => find
            .byKey(const ValueKey('inline-drawing:inline'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(DrawingBoardPage), findsOneWidget);
      expect(find.byKey(const ValueKey('drawing-canvas-card')), findsNothing);
      expect(find.byKey(const ValueKey('drawing-finish-button')), findsNothing);
      expect(find.byKey(const ValueKey('drawing-tool-1')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await waitFor(
        tester,
        () =>
            find
                .byKey(const ValueKey('drawing-canvas-edit-lock'))
                .evaluate()
                .isNotEmpty &&
            !tester
                .widget<AbsorbPointer>(
                  find.byKey(const ValueKey('drawing-canvas-edit-lock')),
                )
                .absorbing,
      );
      final painter = tester.widget<FlutterPainter>(
        find.byType(FlutterPainter),
      );
      final start = tester.getRect(find.byType(FlutterPainter)).center;
      await tester.dragFrom(start, const Offset(70, 30));
      await tester.pump();
      expect(painter.controller.value.drawables, isNotEmpty);
      final surface = tester
          .widget<DrawingBoardPage>(find.byType(DrawingBoardPage))
          .surfaceController!;
      final exported = await tester.runAsync(surface.export);
      expect(exported, isNotNull);
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final resized = await tester.runAsync(surface.export);
      expect(resized!.pngBytes, orderedEquals(exported!.pngBytes));
      final imageRect = tester.getRect(
        find.byKey(const ValueKey('inline-drawing:inline')),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('inline-drawing:inline'))),
        imageRect,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      final ratio = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(exported.pngBytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        final ratio = frame.image.width / frame.image.height;
        frame.image.dispose();
        return ratio;
      });
      expect(ratio, closeTo(1.5, .002));
      await tester.tap(find.byKey(const ValueKey('drawing-tool-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空画布'));
      await tester.pumpAndSettle();
      expect(painter.controller.value.drawables, isEmpty);
      expect(
        painter.controller.value.background,
        isA<ImageBackgroundDrawable>(),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
