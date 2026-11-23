import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/companion_pdf_reflow.dart';
import 'package:xiaoqi_app/widgets/reflow_document_pager.dart';

void main() {
  for (final mode in ReaderPaginationMode.values) {
    testWidgets(
      'converted PDF can read across original pages in ${mode.name}',
      (tester) async {
        const first = CompanionReflowPage(2, [
          CompanionReflowLine('第七章 海岸', Rect.fromLTWH(.2, .1, .5, .05)),
          CompanionReflowLine('原页末尾。', Rect.fromLTWH(.1, .3, .5, .03)),
        ]);
        const next = CompanionReflowPage(3, [
          CompanionReflowLine('下一页开头。', Rect.fromLTWH(.1, .1, .5, .03)),
        ]);
        final anchor = FlowReaderAnchor(
          sourceId: 'source',
          chapterId: CompanionReflowPage.readingChapterId,
          blockId: first.entryNear(.10)?.blockId,
        );
        final pages = ValueNotifier([first]);
        addTearDown(pages.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: pages,
                builder: (context, value, _) => ReflowDocumentPager(
                  document: CompanionReflowPage.readingWindow(value, 10),
                  sourceId: anchor.sourceId,
                  initialChapterId: anchor.chapterId,
                  initialAnchor: anchor,
                  mode: mode,
                  blockBuilder: (context, slice, _) => Text(slice.text),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = find.text('第七章 海岸');
        expect(title, findsOneWidget);
        final origin = tester.getTopLeft(title);
        pages.value = [first, next];
        final nextParagraph = find.text('下一页开头。');
        for (
          var frame = 0;
          frame < 60 && nextParagraph.evaluate().isEmpty;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(tester.getTopLeft(title), origin);
        expect(find.text('全文'), findsNothing);
        expect(nextParagraph.hitTestable(), findsOneWidget);
        if (mode == ReaderPaginationMode.horizontal) {
          expect(
            find.descendant(
              of: find.byKey(const Key('book_body_document_page_0')),
              matching: nextParagraph,
            ),
            findsOneWidget,
          );
        }
        expect(
          CompanionReflowPage.pageForBlock(next.entryNear(.1)?.blockId),
          3,
        );
      },
    );
  }

  testWidgets('prepending PDF text leaves the current screen in place', (
    tester,
  ) async {
    final before = CompanionReflowPage(1, [
      CompanionReflowLine(
        List.filled(300, 'Earlier paragraph.').join(' '),
        const Rect.fromLTWH(.1, .15, .8, .4),
      ),
    ]);
    const current = CompanionReflowPage(2, [
      CompanionReflowLine('当前章节的开头。', Rect.fromLTWH(.1, .15, .8, .03)),
    ]);
    final anchor = FlowReaderAnchor(
      sourceId: 'source',
      chapterId: CompanionReflowPage.readingChapterId,
      blockId: current.entryNear(0)?.blockId,
    );
    final pages = ValueNotifier([current]);
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: pages,
            builder: (context, value, _) => ReflowDocumentPager(
              document: CompanionReflowPage.readingWindow(value, 2),
              sourceId: anchor.sourceId,
              initialChapterId: anchor.chapterId,
              initialAnchor: anchor,
              mode: ReaderPaginationMode.horizontal,
              blockBuilder: (context, slice, _) => Text(slice.text),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final currentLine = find.text('当前章节的开头。');
    final origin = tester.getTopLeft(currentLine);
    pages.value = [before, current];
    double screen() =>
        tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    for (var frame = 0; frame < 120 && screen() < 1; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(currentLine.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(currentLine), origin);
    }
    expect(screen(), greaterThanOrEqualTo(1));
  });
}
