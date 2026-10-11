import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/pages/drawing_board_page.dart';
import 'package:xiaoqi_app/widgets/home_chat_attachment_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late File drawingImage;
  late int drawingImageByteLength;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'xiaoqi-drawing-widget-test-',
    );
    drawingImage = File('${tempDirectory.path}/drawing.png');
    await drawingImage.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      ),
    );
    drawingImageByteLength = await drawingImage.length();
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
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
      const MaterialApp(
        home: DrawingBoardPage(
          conversationId: 'compact-toolbar-test',
          accountScope: 'test',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final eraser = tester.getRect(find.byTooltip('橡皮擦'));
    final toolbarScroll = find
        .ancestor(
          of: find.byTooltip('橡皮擦'),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    final visibleEraser = eraser.intersect(tester.getRect(toolbarScroll));
    final historyMenu = tester.getRect(find.byTooltip('撤销和重做'));
    expect(visibleEraser.overlaps(historyMenu), isFalse);
    expect(tester.takeException(), isNull);
  });
}
