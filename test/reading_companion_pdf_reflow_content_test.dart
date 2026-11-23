import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/companion_pdf_reflow.dart';

void main() {
  testWidgets(
    'a native PDF vector figure stays between its introduction and caption',
    (tester) async {
      final previousCache = Pdfrx.cacheDirectoryPath;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      addTearDown(() => Pdfrx.cacheDirectoryPath = previousCache);
      final controller = PdfViewerController();
      final source = BookSourceRecord.fromMap({
        'id': 1,
        'book_id': 1,
        'file_path': 'vector-pyramid-fixture',
        'source_version_id': DateTime.now().microsecondsSinceEpoch.toString(),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfViewer.data(
              _vectorPyramidPdf(),
              sourceName: source.filePath,
              controller: controller,
              useProgressiveLoading: false,
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 150 && !controller.isReady; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.isReady, isTrue);
      final page = (await tester.runAsync(
        () => CompanionPdfReflow(source).load(controller, 1),
      ))!;
      final document = CompanionReflowPage.readingWindow([page], 1);
      final blocks = document.chapters.single.blocks;
      final image = blocks.indexWhere((block) => block.kind == 'image');
      expect(image, greaterThan(0));
      expect(blocks[image - 1].text, contains('Introduction'));
      expect(blocks[image + 1].text, startsWith('Figure 2-1'));
      expect(blocks.last.text, contains('continues'));
      expect(document.assets.single.id, blocks[image].assetId);
      final picture = page.pictures.single;
      final ink = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          Uint8List.fromList(picture.asset.bytes),
        );
        final frame = await codec.getNextFrame();
        try {
          final rgba = (await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // The source PDF has a top box and two diagonal connecting lines.
          return [
            for (final point in [
              const Offset(200, 430),
              const Offset(157.5, 397.5),
              const Offset(242.5, 397.5),
            ])
              _darkPixelNear(rgba, frame.image, picture.bounds, point),
          ];
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
      });
      expect(ink, [true, true, true]);
      expect(page.originalTop(blocks[image].id, 0), inExclusiveRange(.15, .6));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test(
    'cross-page paragraph anchors resolve on both sides of a window update',
    () {
      const before = CompanionReflowPage(4, [
        CompanionReflowLine('这是跨页段落的', Rect.fromLTWH(.1, .82, .8, .04)),
      ]);
      const after = CompanionReflowPage(5, [
        CompanionReflowLine('下半句。', Rect.fromLTWH(.1, .12, .8, .04)),
      ]);
      final joined = CompanionReflowPage.readingWindow([before, after], 5);
      final single = CompanionReflowPage.readingWindow([after], 5);
      final source = after.entryNear(1)!;
      final combined = CompanionReflowPage.displayPosition(
        joined,
        source.blockId,
        2,
      )!;
      expect(joined.chapters.single.blocks.single.text, '这是跨页段落的下半句。');
      expect(
        CompanionReflowPage.sourcePosition(
          joined,
          combined.blockId,
          combined.offset,
        ),
        (blockId: source.blockId, offset: 2),
      );
      expect(CompanionReflowPage.displayPosition(single, source.blockId, 2), (
        blockId: source.blockId,
        offset: 2,
      ));
    },
  );
}

bool _darkPixelNear(
  ByteData bytes,
  ui.Image image,
  Rect bounds,
  Offset pdfPoint,
) {
  final cx = ((pdfPoint.dx / 400 - bounds.left) / bounds.width * image.width)
      .round();
  final cy =
      (((600 - pdfPoint.dy) / 600 - bounds.top) / bounds.height * image.height)
          .round();
  for (var y = cy - 3; y <= cy + 3; y++) {
    for (var x = cx - 3; x <= cx + 3; x++) {
      if (x >= 0 &&
          y >= 0 &&
          x < image.width &&
          y < image.height &&
          bytes.getUint8((y * image.width + x) * 4) < 90) {
        return true;
      }
    }
  }
  return false;
}

Uint8List _vectorPyramidPdf() {
  const page =
      '''BT /F1 14 Tf 42 535 Td (Introduction to the pyramid diagram.) Tj ET
1 w 180 430 40 22 re S 95 343 40 22 re S 265 343 40 22 re S
200 430 m 115 365 l S 200 430 m 285 365 l S
BT /F1 12 Tf 55 305 Td (Figure 2-1 Pyramid structure.) Tj ET
BT /F1 14 Tf 42 260 Td (The next paragraph continues here.) Tj ET
''';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${page.length} >>\nstream\n${page}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = [0];
  for (final object in objects) {
    offsets.add(out.length);
    out.write('${offsets.length - 1} 0 obj\n$object\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Root 1 0 R /Size ${offsets.length} >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(out.toString()));
}
