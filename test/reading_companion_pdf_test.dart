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
    await tester.runAsync(() => file.writeAsString(_blankPdf()));
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
    final slider = tester.widgetList<Slider>(find.byType(Slider)).singleOrNull;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(pageLabel, '2 / 3');
    expect(slider?.value, 2);
    expect(tester.takeException(), isNull);
  });
}

String _blankPdf() {
  const pages = 3;
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pages /Kids [3 0 R 4 0 R 5 0 R] >>',
    for (var page = 0; page < pages; page++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] >>',
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
