import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';

void main() {
  testWidgets('a horizontal PDF swipe settles on exactly one page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reading-companion.turn': 'horizontal',
    });
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('companion-pdf-paging-'),
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
              attempt == 20) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final file = File('${directory.path}/pages.pdf');
    await tester.runAsync(() => file.writeAsString(_fourPagePdf()));
    final reply = ValueNotifier('');
    addTearDown(reply.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ReadingCompanion(
          bookId: 1,
          library: _PagingLibrary(file.path),
          messages: const [],
          streamingReply: reply,
          composerBuilder: (history) => history,
          onPassageOpened: (_) {},
        ),
      ),
    );

    final viewer = find.byType(PdfViewer);
    PdfViewerController? readyController() {
      if (viewer.evaluate().isEmpty) return null;
      final controller = tester.widget<PdfViewer>(viewer).controller!;
      return controller.isReady &&
              controller.pageNumber != null &&
              controller.document.pages.every((page) => page.isLoaded)
          ? controller
          : null;
    }

    for (var frame = 0; frame < 120 && readyController() == null; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    final controller = readyController()!;
    final viewport = tester.getRect(viewer);
    void expectSettledPage(int number) {
      expect(controller.pageNumber, number);
      final page = controller.layout.pageLayouts[number - 1];
      expect(controller.centerPosition.dx, closeTo(page.center.dx, 1));
    }

    expectSettledPage(1);
    await tester.timedDragFrom(
      viewport.center,
      const Offset(-60, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();
    expectSettledPage(1);

    await tester.flingFrom(
      Offset(viewport.right - 64, viewport.center.dy),
      const Offset(-570, 0),
      3000,
    );
    await tester.pumpAndSettle();
    expectSettledPage(2);

    await tester.timedDragFrom(
      viewport.center,
      const Offset(245, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();
    expectSettledPage(1);

    await tester.pumpWidget(const SizedBox.shrink());
    // Page detection may still be waiting for an early progressive load.
    // Advance its timeout in the test clock before releasing the PDF file.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    for (var frame = 0; frame < 5; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}

String _fourPagePdf() {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] >>',
    ...List.filled(
      4,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] >>',
    ),
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

class _PagingLibrary extends BookLibraryService {
  _PagingLibrary(this.path);

  final String path;

  @override
  Future<BookLibraryItem?> getBookLibraryItem(int bookId) async => null;

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [
    BookSourceRecord(
      id: 1,
      bookId: bookId,
      kind: 'book_file',
      displayName: 'pages.pdf',
      filePath: path,
      fileSize: 0,
      contentHash: '',
      status: 'ready',
      isPrimary: true,
      createdAt: '',
      updatedAt: '',
    ),
  ];
}
