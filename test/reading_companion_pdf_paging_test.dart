import 'dart:io';

import 'companion_pdf_preparation_support.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';
import 'package:xiaoqi_app/widgets/reflow_document_pager.dart';

void main() {
  for (final vertical in [false, true]) {
    testWidgets(
      'a ${vertical ? 'vertical' : 'horizontal'} PDF swipe settles on exactly one page',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reading-companion.turn': vertical ? 'vertical' : 'horizontal',
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
        await tester.runAsync(
          () => file.writeAsString(_pagingPdf(mixed: vertical)),
        );
        final reply = ValueNotifier('');
        addTearDown(reply.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ReadingCompanion(
              bookId: 1,
              library: _PagingLibrary(file.path, hasAlternate: vertical),
              messages: const [],
              streamingReply: reply,
              composerBuilder: (history) => history,
              onPassageOpened: (_) {},
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
        PdfViewerController? readyController() {
          if (viewer.evaluate().isEmpty) return null;
          final controller = tester.widget<PdfViewer>(viewer).controller!;
          return controller.isReady &&
                  controller.pageNumber != null &&
                  controller.document.pages.every((page) => page.isLoaded)
              ? controller
              : null;
        }

        for (
          var frame = 0;
          frame < 450 && (readyController() == null || !ebookReady());
          frame++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        final controller = readyController()!;
        expect(ebookReady(), isTrue);
        final segment = tester.getRect(ebookButton);
        Future<void> expectStableFrames() async {
          for (var frame = 0; frame < 48; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              ebookReady(),
              isTrue,
              reason: 'The prepared format changed on frame $frame',
            );
            expect(tester.getRect(ebookButton), segment);
            expect(
              find.descendant(
                of: ebookButton,
                matching: find.byType(CircularProgressIndicator),
              ),
              findsNothing,
            );
          }
        }

        final viewport = tester.getRect(viewer);
        void expectSettledPage(int number) {
          expect(controller.pageNumber, number);
          final page = controller.layout.pageLayouts[number - 1];
          expect(controller.centerPosition.dx, closeTo(page.center.dx, 1));
          if (vertical) {
            expect(controller.centerPosition.dy, closeTo(page.center.dy, 1));
            final visible = controller.visibleRect;
            expect(controller.layout.pageLayouts.where(visible.overlaps), [
              page,
            ]);
          }
        }

        Offset swipe(double distance) =>
            vertical ? Offset(0, distance) : Offset(distance, 0);
        expectSettledPage(1);
        await tester.timedDragFrom(
          viewport.center,
          swipe(-60),
          const Duration(milliseconds: 500),
        );
        await tester.pumpAndSettle();
        expectSettledPage(1);

        await tester.flingFrom(
          vertical
              ? Offset(viewport.center.dx, viewport.bottom - 105)
              : Offset(viewport.right - 64, viewport.center.dy),
          swipe(vertical ? -420 : -570),
          3000,
        );
        final pdf = find.text('PDF');
        // Request the newly paged location, then keep the original format
        // before a frame can install that location in the hidden reader.
        expect(ebook.hitTestable(), findsOneWidget);
        expect(pdf.hitTestable(), findsOneWidget);
        await tester.tap(ebook);
        await tester.tap(pdf);
        await expectStableFrames();
        await tester.pumpAndSettle();
        expectSettledPage(2);
        expect(find.text('阅读资料'), findsNothing);
        expect(find.byType(ReflowDocumentPager), findsNothing);

        await tester.timedDragFrom(
          viewport.center,
          swipe(245),
          const Duration(milliseconds: 500),
        );
        await expectStableFrames();
        await tester.pumpAndSettle();
        expectSettledPage(1);

        // Page 11 is outside the original vertical window. Both formats have
        // already been prepared; only the hidden reader's location changes.
        await tester.tap(find.text('进度'));
        await tester.pump();
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(11);
        slider.onChangeEnd!(11);
        await expectStableFrames();
        expectSettledPage(11);
        await tester.tap(ebook);
        await tester.pumpAndSettle();
        expect(find.byType(PdfViewer), findsNothing);
        final installed = tester
            .widget<ReflowDocumentPager>(find.byType(ReflowDocumentPager))
            .initialAnchor;
        expect(installed?.blockId, startsWith('pdf-page-11-'));

        // The old native PDF raster may still complete after this cancellation.
        await tester.tap(pdf);
        await tester.tap(ebook);
        for (var frame = 0; frame < 30; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(viewer, findsNothing);
          expect(find.text('阅读资料'), findsNothing);
        }
        await tester.tap(ebook);
        await tester.pumpAndSettle();
        if (vertical) {
          expect(find.text('阅读资料'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        } else {
          expect(find.text('阅读资料'), findsNothing);
          expect(viewer, findsNothing);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        // Page detection may still be waiting for an early progressive load.
        // Advance its timeout in the test clock before releasing the PDF file.
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        await finishCompanionPdfPreparation(tester);
        for (var frame = 0; frame < 5; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

String _pagingPdf({required bool mixed}) {
  const pages = 12;
  const firstPage = 3;
  const font = firstPage + pages;
  const stream = 'BT /F1 16 Tf 18 110 Td (Prepared PDF page.) Tj ET\n';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pages /Kids [${List.generate(pages, (i) => "${i + firstPage} 0 R").join(" ")}] >>',
    for (var i = 0; i < pages; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${mixed && i == 1 ? "620 220" : "400 600"}] '
          '/Resources << /Font << /F1 $font 0 R >> >> /Contents ${font + 1} 0 R >>',
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

class _PagingLibrary extends BookLibraryService {
  _PagingLibrary(this.path, {required this.hasAlternate});

  final String path;
  final bool hasAlternate;

  @override
  Future<BookLibraryItem?> getBookLibraryItem(int bookId) async => null;

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [
    for (final id in [1, if (hasAlternate) 2])
      BookSourceRecord(
        id: id,
        bookId: bookId,
        kind: 'book_file',
        displayName: 'pages-$id.pdf',
        filePath: path,
        fileSize: 0,
        contentHash: '',
        status: 'ready',
        isPrimary: id == 1,
        createdAt: '',
        updatedAt: '',
      ),
  ];
}
