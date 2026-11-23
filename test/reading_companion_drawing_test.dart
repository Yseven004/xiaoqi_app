import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/pages/drawing_board_page.dart';

void main() {
  testWidgets(
    'reader capsule edits the active anchored drawing and restores it',
    (tester) async {
      final tools = DrawingAnnotationTools();
      final layer = DrawingAnnotationLayer(size: const Size(640, 480));
      Map<String, Object?>? stored;
      var anchor = layer;
      final capture = GlobalKey();
      Widget reader() => MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: capture,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF576A81)),
                DrawingBoardPage.annotation(
                  key: ObjectKey(anchor),
                  layer: anchor,
                  annotationTools: tools,
                ),
                tools.controls(
                  onFinish: () async {
                    tools.commitText();
                    stored = await anchor.encode();
                    anchor.saved(stored!);
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(reader());
      await tester.pumpAndSettle();

      final visiblePaper = await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return data.getUint32((image.width * 150 + 30) * 4);
        } finally {
          image.dispose();
        }
      });
      expect(visiblePaper, 0x576A81FF);

      expect(find.byTooltip('撤销'), findsNothing);
      expect(find.byTooltip('重做'), findsNothing);
      final imageTool = tester.getCenter(find.byTooltip('图片'));
      final finish = tester.getCenter(find.byTooltip('完成涂鸦'));
      expect(finish.dy, closeTo(imageTool.dy, 1));
      expect(finish.dx, greaterThan(imageTool.dx));
      expect(finish.dx - imageTool.dx, lessThan(150));
      await tester.tap(find.byTooltip('图片'));
      await tester.pumpAndSettle();
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('上传图片'), findsOneWidget);
      await tester.tapAt(const Offset(35, 220));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('文字'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('drawing-inline-text-field')),
        '海岸观测',
      );
      final textField = find.byKey(const ValueKey('drawing-inline-text-field'));
      final textPosition = tester.getCenter(textField);
      await tester.tap(find.byTooltip('完成涂鸦'));
      await tester.pumpAndSettle();
      final items = stored!['drawables'] as List;
      expect(items.single['type'], 'text');
      expect(items.single['data']['text'], '海岸观测');

      anchor = DrawingAnnotationLayer(size: layer.size, document: stored);
      await tester.pumpWidget(reader());
      await tester.pumpAndSettle();
      await tester.tapAt(textPosition);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(textField).controller!.text, '海岸观测');
      await tester.enterText(textField, '修订的观测记录');
      await tester.tap(find.byTooltip('画笔'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(60, 250), const Offset(90, 40));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('完成涂鸦'));
      await tester.pumpAndSettle();
      expect(
        (stored!['drawables'] as List).map((item) => item['type']),
        containsAll(['text', 'freeStyle']),
      );
      final editedText = (stored!['drawables'] as List).singleWhere(
        (item) => item['type'] == 'text',
      );
      expect(editedText['data']['text'], '修订的观测记录');
      await tester.pumpWidget(const SizedBox.shrink());
      tools.dispose();
    },
  );
}
