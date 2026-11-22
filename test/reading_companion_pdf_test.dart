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

void main() {
  testWidgets('task PDF is preferred and its restored page is shown', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await const ReaderPaginationPreferences().saveAnchor(
      bookId: 1,
      anchor: const PdfReaderAnchor(sourceId: '2', pageNumber: 2),
    );
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('companion-pdf-'),
    ))!;
    final previousCache = Pdfrx.cacheDirectoryPath;
    Pdfrx.cacheDirectoryPath = directory.path;
    addTearDown(() async {
      Pdfrx.cacheDirectoryPath = previousCache;
      await directory.delete(recursive: true);
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

    final footer = find.textContaining(' / 3');
    for (var frame = 0; frame < 100 && footer.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    final pageLabel = tester.widgetList<Text>(footer).singleOrNull?.data;
    await tester.tap(find.text('进度'));
    await tester.pumpAndSettle();
    final slider = tester.widgetList<Slider>(find.byType(Slider)).singleOrNull;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final controller = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .controller!;
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
    await tester.pumpAndSettle();
    expect(pageLabel, '2 / 3');
    expect(slider?.value, 2);
    expect(tester.takeException(), isNull);
  });
}

String _samplePdf() {
  const pages = 3;
  const stream = 'BT /F1 24 Tf 64 280 Td (Read this page.) Tj ET\n';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pages /Kids [3 0 R 4 0 R 5 0 R] >>',
    for (var page = 0; page < pages; page++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] '
          '/Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>',
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
