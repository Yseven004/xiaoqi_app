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
      final emphasis = blocks.last.boldRanges.single;
      expect(
        blocks.last.text.substring(emphasis.start, emphasis.end),
        'continues',
      );
      final native = (await tester.runAsync(
        () => controller.document.pages.first.loadStructuredText(),
      ))!;
      final projection = CompanionReflowPage.sourceProjection(blocks.last);
      final sourceRange = projection.sourceRange(emphasis.start, emphasis.end)!;
      final span = sourceRange.pages.single;
      expect(native.fullText.substring(span.start, span.end), 'continues');
      expect(projection.displayRange(sourceRange), (
        start: emphasis.start,
        end: emphasis.end,
      ));
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

  testWidgets('a wide PDF table keeps all columns with or without a sidebar', (
    tester,
  ) async {
    final previousCache = Pdfrx.cacheDirectoryPath;
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    addTearDown(() => Pdfrx.cacheDirectoryPath = previousCache);
    for (final withSidebar in [false, true]) {
      final controller = PdfViewerController();
      final source = BookSourceRecord.fromMap({
        'id': 1,
        'book_id': 1,
        'file_path': 'wide-table-$withSidebar',
        'source_version_id': DateTime.now().microsecondsSinceEpoch.toString(),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfViewer.data(
              _wideTablePdf(withSidebar),
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
      final reflow = CompanionPdfReflow(source);
      final page = (await tester.runAsync(() => reflow.load(controller, 1)))!;
      expect(page.keepOriginal, withSidebar);
      final table = page.selectablePictures.singleWhere(
        (picture) => picture.isTable,
      );
      expect(table.minimumReadableWidth, greaterThan(400));
      expect(table.bounds.left, lessThan(.065));
      expect(table.bounds.right, greaterThan(.815));
      expect(table.bounds.right, lessThan(.85));
      expect(table.bounds.bottom, greaterThan(.35));
      final bytes = await tester.runAsync(
        () async => await controller.useDocument<Uint8List?>(
          (document) =>
              reflow.renderPicture(document, 1, table, forExport: true),
        ),
      );
      expect(bytes, isNotNull);
      final exportedBytes = bytes!;
      final exportedWidth = ByteData.sublistView(exportedBytes).getUint32(16);
      expect(exportedWidth, greaterThan(3000));
      final corners = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(exportedBytes);
        final frame = await codec.getNextFrame();
        try {
          final rgba = (await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return [
            for (final point in const [Offset(24, 460), Offset(328, 385)])
              _darkPixelNear(rgba, frame.image, table.bounds, point),
          ];
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
      });
      expect(corners, [true, true]);
      if (withSidebar) {
        expect(page.pictures.single.bounds, const Rect.fromLTWH(0, 0, 1, 1));
      } else {
        final blocks = CompanionReflowPage.readingWindow([
          page,
        ], 1).chapters.single.blocks;
        final image = blocks.singleWhere((block) => block.kind == 'image');
        expect(image.attributes['minimumReadableWidth'], isNotNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  test(
    'reflow keeps title levels, paragraph boundaries and inline emphasis',
    () {
      const page = CompanionReflowPage(2, [
        CompanionReflowLine('第二章 种子的旅行', Rect.fromLTWH(.10, .08, .5, .04)),
        CompanionReflowLine('第一节 风力传播', Rect.fromLTWH(.10, .16, .4, .03)),
        CompanionReflowLine(
          '风里的种子',
          Rect.fromLTWH(.10, .23, .16, .024),
          boldRanges: [(start: 0, end: 5)],
        ),
        CompanionReflowLine(
          '蒲公英的种子很轻。一阵风吹过，',
          Rect.fromLTWH(.15, .27, .68, .024),
        ),
        CompanionReflowLine('它们就离开了母株。', Rect.fromLTWH(.10, .306, .27, .024)),
        CompanionReflowLine(
          '枫树的种子带着一片薄翅，落下时会旋转。',
          Rect.fromLTWH(.15, .342, .68, .024),
          boldRanges: [(start: 9, end: 11)],
        ),
      ]);
      final blocks = CompanionReflowPage.readingWindow([
        page,
      ], 2).chapters.single.blocks;
      expect(blocks.map((block) => block.level), [1, 2, 3, 0, 0]);
      expect(blocks[2].text, '风里的种子');
      expect(blocks[3].text, '蒲公英的种子很轻。一阵风吹过，它们就离开了母株。');
      final range = blocks[4].boldRanges.single;
      expect(blocks[4].text.substring(range.start, range.end), '薄翅');
    },
  );

  test(
    'source alignment and isolated mixed-script headings survive reflow',
    () {
      const page = CompanionReflowPage(1, [
        CompanionReflowLine('第12节 深海航行', Rect.fromLTWH(.39, .08, .22, .024)),
        CompanionReflowLine('试验室 ２０２１年', Rect.fromLTWH(.175, .13, .16, .019)),
        CompanionReflowLine(
          '研究团队对新的船舶做了测试。',
          Rect.fromLTWH(.125, .17, .74, .019),
        ),
        CompanionReflowLine('A7航行方案', Rect.fromLTWH(.175, .21, .12, .019)),
        CompanionReflowLine(
          '接下来由工程师带领团队继续试验。',
          Rect.fromLTWH(.175, .25, .69, .019),
        ),
        CompanionReflowLine('杰克·陈', Rect.fromLTWH(.175, .29, .09, .019)),
        CompanionReflowLine(
          '这项工程涉及许多来自不同领域的人。',
          Rect.fromLTWH(.175, .33, .69, .019),
        ),
        CompanionReflowLine('测试A2', Rect.fromLTWH(.125, .351, .09, .019)),
      ]);
      final blocks = CompanionReflowPage.readingWindow([
        page,
      ], 1).chapters.single.blocks;
      final headings = blocks.where((b) => b.kind == 'heading').toList();
      expect(headings.map((b) => b.text), ['第12节 深海航行', 'A7航行方案', '杰克·陈']);
      expect(headings.map((b) => b.attributes['textAlign']), [
        'center',
        null,
        null,
      ]);
      expect(blocks.last.text, endsWith('测试A2'));
    },
  );

  test(
    'source paragraph tags keep wrapped headings and separate body paragraphs',
    () {
      const page = CompanionReflowPage(1, [
        CompanionReflowLine(
          'A title',
          Rect.fromLTWH(.1, .1, .4, .024),
          paragraphTag: 1,
          headingLevel: 2,
        ),
        CompanionReflowLine(
          'on two lines',
          Rect.fromLTWH(.1, .136, .4, .024),
          paragraphTag: 1,
          headingLevel: 2,
        ),
        CompanionReflowLine(
          'A sentence without punctuation',
          Rect.fromLTWH(.1, .172, .5, .024),
          paragraphTag: 2,
        ),
        CompanionReflowLine(
          'Another paragraph starts here.',
          Rect.fromLTWH(.1, .208, .5, .024),
          paragraphTag: 3,
        ),
      ]);
      final blocks = CompanionReflowPage.readingWindow([
        page,
      ], 1).chapters.single.blocks;
      expect(blocks.map((block) => block.level), [2, 0, 0]);
      expect(blocks.first.text, 'A title on two lines');
      expect(blocks.last.text, 'Another paragraph starts here.');
    },
  );

  test(
    'cross-page paragraph anchors resolve on both sides of a window update',
    () {
      const before = CompanionReflowPage(4, [
        CompanionReflowLine('这是跨页段落的', Rect.fromLTWH(.1, .82, .8, .04)),
        CompanionReflowLine('42', Rect.fromLTWH(.48, .94, .04, .022)),
      ]);
      const after = CompanionReflowPage(5, [
        CompanionReflowLine(
          '下半句。',
          Rect.fromLTWH(.1, .12, .8, .04),
          boldRanges: [(start: 0, end: 3)],
        ),
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
      final merged = joined.chapters.single.blocks.single;
      final range = merged.boldRanges.single;
      expect(merged.text.substring(range.start, range.end), '下半句');
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
BT /F1 14 Tf 42 260 Td (The next paragraph ) Tj /F2 14 Tf (continues) Tj /F1 14 Tf ( here.) Tj ET
''';
  return _singlePagePdf(page);
}

Uint8List _wideTablePdf(bool withSidebar) {
  final page = StringBuffer('''
BT /F1 14 Tf 42 535 Td (A table of eight columns follows.) Tj ET
BT /F1 12 Tf 24 481 Td (Table 1 Measurements) Tj ET
1.2 w
''');
  for (final y in [460, 435, 410, 385]) {
    page.writeln('24 $y m 328 $y l S');
  }
  for (var index = 0; index <= 8; index++) {
    final x = 24 + index * 38;
    page.writeln('$x 460 m $x 385 l S');
    if (index == 8) continue;
    for (var row = 0; row < 3; row++) {
      page.writeln(
        'BT /F1 11 Tf ${x + 5} ${443 - row * 25} Td (${index + row * 10}) Tj ET',
      );
    }
  }
  if (withSidebar) {
    page.writeln('BT /F1 10 Tf 342 423 Td (Side note) Tj ET');
  }
  page.writeln('BT /F1 14 Tf 42 325 Td (Reading continues.) Tj ET');
  return _singlePagePdf(page.toString());
}

Uint8List _singlePagePdf(String page) {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>',
    '<< /Length ${page.length} >>\nstream\n${page}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>',
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
