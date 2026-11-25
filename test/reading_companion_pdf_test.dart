import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/reader_pagination_preferences.dart';
import 'package:xiaoqi_app/widgets/message_selection_action_card.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';
import 'package:xiaoqi_app/widgets/reflow_document_pager.dart';

void main() {
  test(
    'PDF progress retains the source position and accepts page-only records',
    () {
      const detailed = PdfReaderAnchor(
        sourceId: '2',
        pageNumber: 42,
        blockId: 'pdf-page-42-line-8',
        characterOffset: 12,
        pageFraction: .55,
      );
      expect(readerAnchorFromJson(readerAnchorJson(detailed)), detailed);
      expect(
        readerAnchorFromJson('{"kind":"pdf","source_id":"2","page":42}'),
        const PdfReaderAnchor(sourceId: '2', pageNumber: 42),
      );
    },
  );

  testWidgets('task PDF with a blank cover reflows and restores its page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const savedPosition = PdfReaderAnchor(
      sourceId: '2',
      pageNumber: 2,
      blockId: 'pdf-page-2-line-0',
      characterOffset: 6,
    );
    await const ReaderPaginationPreferences().saveAnchor(
      bookId: 1,
      anchor: savedPosition,
    );
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('companion-pdf-'),
    ))!;
    final previousCache = Pdfrx.cacheDirectoryPath;
    Pdfrx.cacheDirectoryPath = directory.path;
    addTearDown(() async {
      Pdfrx.cacheDirectoryPath = previousCache;
      for (var attempt = 0; ; attempt++) {
        try {
          await directory.delete(recursive: true);
          break;
        } on FileSystemException catch (error) {
          if (!Platform.isWindows ||
              error.osError?.errorCode != 32 ||
              attempt >= 20) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final file = File('${directory.path}/book.pdf');
    await tester.runAsync(() => file.writeAsString(_samplePdf()));
    final reply = ValueNotifier('');
    addTearDown(reply.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReadingCompanion(
          bookId: 1,
          library: _PdfLibrary(file.path),
          messages: const [],
          streamingReply: reply,
          composerBuilder: (history) => history,
          onPassageOpened: (_) {},
          loadPreferredSourceId: (bookId) async {
            expect(bookId, 1);
            return 2;
          },
        ),
      ),
    );

    final viewer = find.byType(PdfViewer);
    final ebook = find.text('电子书');
    final ebookButton = find
        .ancestor(of: ebook, matching: find.byType(InkWell))
        .first;
    bool ebookReady() =>
        ebook.evaluate().isNotEmpty &&
        tester.widget<InkWell>(ebookButton).onTap != null;
    final ebookSpinner = find.descendant(
      of: ebookButton,
      matching: find.byType(CircularProgressIndicator),
    );
    Rect? waitingSegment;
    Rect? waitingLabel;
    final progress = find.ancestor(
      of: find.text('进度'),
      matching: find.byType(InkWell),
    );
    bool ready() =>
        viewer.evaluate().isNotEmpty &&
        tester.widget<PdfViewer>(viewer).controller!.isReady &&
        tester
            .widgetList<InkWell>(progress)
            .any((button) => button.onTap != null);
    for (var frame = 0; frame < 300 && (!ready() || !ebookReady()); frame++) {
      if (ebook.evaluate().isNotEmpty && ebookSpinner.evaluate().isNotEmpty) {
        waitingSegment = tester.getRect(ebookButton);
        waitingLabel = tester.getRect(ebook);
        expect(ebookReady(), isFalse);
        expect(find.text('准备中'), findsNothing);
        expect(find.byType(ReflowDocumentPager), findsNothing);
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
    expect(ebookReady(), isTrue);
    expect(tester.getRect(ebookButton), waitingSegment);
    expect(tester.getRect(ebook), waitingLabel);
    expect(find.byType(Slider), findsNothing);
    final viewport = tester.getRect(viewer);
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    final slider = tester.widgetList<Slider>(find.byType(Slider)).singleOrNull;
    expect(tester.getRect(viewer), viewport);
    expect(find.text('第 2 页 / 共 3 页'), findsOneWidget);
    slider!.onChanged!(2.35);
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      closeTo(2.35, .001),
    );
    expect(tester.widget<PdfViewer>(viewer).controller!.pageNumber, 2);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final controller = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .controller!;
    expect(ebook, findsOneWidget);
    expect(viewer, findsOneWidget);
    expect(find.byType(ReflowDocumentPager), findsNothing);
    await tester.tap(ebook);
    await tester.pumpAndSettle();
    expect(find.text('Read this page.').hitTestable(), findsWidgets);
    final restored = tester
        .widget<ReflowDocumentPager>(find.byType(ReflowDocumentPager))
        .initialAnchor;
    expect(restored?.blockId, savedPosition.blockId);
    expect(restored?.characterOffset, savedPosition.characterOffset);
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(3);
    await tester.pumpAndSettle();
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    expect(find.text('第 3 页 / 共 3 页'), findsOneWidget);
    await tester.tap(find.text('返回第 2 页'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ReflowDocumentPager>(find.byType(ReflowDocumentPager))
          .initialAnchor,
      restored,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    for (final label in ['字号', '边距', '行距', '左右平移', '仿真翻页']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['字号', '边距', '行距']) {
      final control = find.descendant(
        of: find.byKey(ValueKey(label)),
        matching: find.byType(Slider),
      );
      await tester.ensureVisible(control);
      double actualSetting() {
        final pager = tester.widget<ReflowDocumentPager>(
          find.byType(ReflowDocumentPager),
        );
        final style = pager.textStyleBuilder!(
          const TextStyle(fontSize: 17, height: 1.7),
        );
        return switch (label) {
          '字号' => style.fontSize!,
          '行距' => style.height!,
          _ => pager.verticalPadding.left,
        };
      }

      final before = actualSetting();
      final marker = tester.getCenter(find.bySemanticsLabel('恢复默认$label'));
      final gesture = await tester.startGesture(marker);
      await gesture.moveBy(const Offset(32, 0));
      await gesture.moveBy(const Offset(36, 0));
      await tester.pump();
      expect(
        actualSetting(),
        greaterThan(before),
        reason: '$label changes the live page before release',
      );
      await gesture.up();
      await tester.pump();
      await tester.tapAt(marker);
      await tester.pumpAndSettle();
      expect(actualSetting(), before);
      expect(
        tester
            .widget<ReflowDocumentPager>(find.byType(ReflowDocumentPager))
            .initialAnchor,
        restored,
      );
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final pdf = find.text('PDF');
    final pdfButton = find
        .ancestor(of: pdf, matching: find.byType(InkWell))
        .first;
    final pdfRect = tester.getRect(pdfButton);
    await tester.tap(pdf);
    await tester.pump();
    expect(tester.getRect(pdfButton), pdfRect);
    if (viewer.evaluate().isEmpty) {
      expect(
        find.descendant(
          of: pdfButton,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(tester.widget<InkWell>(pdfButton).onTap, isNull);
    }
    for (var frame = 0; frame < 120 && viewer.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 12)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(ReflowDocumentPager), findsNothing);
    expect(tester.widget<PdfViewer>(viewer).controller, same(controller));
    expect(controller.pageNumber, 2);
    expect(
      await const ReaderPaginationPreferences().loadAnchor(
        bookId: 1,
        sourceId: 2,
      ),
      savedPosition,
    );
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(3);
    await tester.pumpAndSettle();
    expect(controller.pageNumber, 3);
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回第 2 页'));
    await tester.pumpAndSettle();
    expect(controller.pageNumber, 2);
    expect(
      await const ReaderPaginationPreferences().loadAnchor(
        bookId: 1,
        sourceId: 2,
      ),
      savedPosition,
    );
    for (
      var frame = 0;
      frame < 100 && !controller.document.pages[1].isLoaded;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 24));
    }
    expect(controller.document.pages[1].isLoaded, isTrue);
    final raw = await tester.runAsync(
      () => controller.document.pages[1].loadText(),
    );
    expect(raw?.fullText, contains('Read this page.'));
    await controller.goToPage(
      pageNumber: 2,
      anchor: PdfPageAnchor.center,
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
    final text = controller.documentToGlobal(
      controller
          .calcRectForRectInsidePage(pageNumber: 2, rect: raw!.charRects[1])
          .center,
    )!;
    expect(
      tester.getRect(find.byType(PdfViewer)).contains(text),
      isTrue,
      reason: 'Fixture glyph must be visible in the initial viewport',
    );
    await tester.longPressAt(text);
    for (
      var frame = 0;
      frame < 80 && find.byType(MessageSelectionActionCard).evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      controller.textSelectionDelegate.hasSelectedText,
      isTrue,
      reason: 'Long press must create a PDF text selection',
    );
    expect(find.byType(MessageSelectionActionCard), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('注释'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    // The PDFium worker releases the OS handle on its own isolate. Flush
    // notifications back to the widget-test zone before cleaning the file.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(slider.value, 2);
    expect(tester.takeException(), isNull);
  });
}

String _samplePdf() {
  const pages = 3;
  const stream = 'BT /F1 24 Tf 64 280 Td (Read this page.) Tj ET\n';
  const contents = '/Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R ';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pages /Kids [3 0 R 4 0 R 5 0 R] >>',
    for (var page = 0; page < pages; page++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] '
          '${page == 0 ? '' : contents}>>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${stream.length} >>\nstream\n${stream}endstream',
  ];
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = output.length;
  final size = objects.length + 1;
  output.write('xref\n0 $size\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return output.toString();
}

class _PdfLibrary extends BookLibraryService {
  _PdfLibrary(this.path);

  final String path;

  @override
  Future<BookLibraryItem?> getBookLibraryItem(int bookId) async => null;

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [
    for (final id in [3, 2])
      BookSourceRecord(
        id: id,
        bookId: bookId,
        kind: 'book_file',
        displayName: 'book-$id.pdf',
        filePath: path,
        fileSize: 0,
        contentHash: '',
        status: 'ready',
        isPrimary: id == 3,
        createdAt: '',
        updatedAt: '',
      ),
  ];
}
