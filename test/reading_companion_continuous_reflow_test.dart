import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/models/xiaoqi_document.dart';
import 'package:xiaoqi_app/services/companion_pdf_reflow.dart';
import 'package:xiaoqi_app/widgets/companion_pdf_object_view.dart';
import 'package:xiaoqi_app/widgets/reflow_document_pager.dart';

void main() {
  testWidgets(
    'live preview bounds a legacy plain chapter and starts at its saved character',
    (tester) async {
      final text =
          List.filled(1000, 'Long paragraph. ').join() +
          List.filled(1800, 'read🙂').join();
      final book = XiaoqiDocument(
        format: 'epub',
        title: 'Book',
        author: '',
        language: 'en',
        chapters: [
          XiaoqiDocumentChapter(
            id: 'one',
            title: 'Chapter',
            href: '',
            html: '',
            plainText: text,
            order: 0,
          ),
        ],
      );
      const anchor = FlowReaderAnchor(
        sourceId: 'legacy',
        chapterId: 'one',
        blockId: 'one:plain',
        characterOffset: 16005,
      );
      final moving = ValueNotifier(false);
      addTearDown(moving.dispose);
      final rendered = <ReaderBlockSlice>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 380,
              child: ValueListenableBuilder(
                valueListenable: moving,
                builder: (_, active, _) {
                  TextStyle style(TextStyle base) =>
                      base.copyWith(fontSize: active ? 14 : 20, height: 1.6);
                  return ReflowDocumentPager(
                    document: book,
                    sourceId: 'legacy',
                    initialChapterId: 'one',
                    mode: ReaderPaginationMode.horizontal,
                    initialAnchor: anchor,
                    previewTypography: active,
                    textStyleBuilder: style,
                    blockBuilder: (_, slice, _) {
                      if (active) rendered.add(slice);
                      return Text(
                        slice.text,
                        key: ValueKey(slice.startOffset),
                        style: style(const TextStyle()),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      moving.value = true;
      await tester.pump();
      final visibleAnchor = find.byKey(const ValueKey(16004));
      expect(visibleAnchor.hitTestable(at: Alignment.topLeft), findsOneWidget);
      final span = rendered.firstWhere((part) => part.startOffset == 16004);
      expect(span.text, startsWith(text.substring(16004, 16016)));
      expect(span.text.length, lessThan(2500));
      expect(
        span.text.runes.where((code) => code >= 0xD800 && code <= 0xDFFF),
        isEmpty,
      );
      expect(tester.getBottomLeft(visibleAnchor).dy, greaterThanOrEqualTo(350));
    },
  );

  testWidgets(
    'switching from horizontal book to vertical window keeps original page 47',
    (tester) async {
      final pages = List.generate(
        56,
        (index) => CompanionReflowPage(index + 1, [
          CompanionReflowLine(
            'Original ${index + 1}: ${List.filled(25, 'Line of text.').join(' ')}',
            const Rect.fromLTWH(.1, .15, .8, .4),
          ),
        ]),
      );
      final whole = CompanionReflowPage.readingWindow(pages, pages.length);
      final window = CompanionReflowPage.readingWindow(
        pages.sublist(42, 51),
        pages.length,
      );
      final id = pages[46].entryNear(.15)!.blockId;
      final mode = ValueNotifier(ReaderPaginationMode.horizontal);
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 320,
              child: ValueListenableBuilder(
                valueListenable: mode,
                builder: (_, value, _) {
                  final doc = value == ReaderPaginationMode.vertical
                      ? window
                      : whole;
                  final at = CompanionReflowPage.displayPosition(doc, id, 8)!;
                  return ReflowDocumentPager(
                    document: doc,
                    sourceId: 'source',
                    initialChapterId: CompanionReflowPage.readingChapterId,
                    initialAnchor: FlowReaderAnchor(
                      sourceId: 'source',
                      chapterId: CompanionReflowPage.readingChapterId,
                      blockId: at.blockId,
                      characterOffset: at.offset,
                    ),
                    mode: value,
                    onVisibleBlocksChanged: (_) {},
                    blockBuilder: (_, slice, _) => SelectableText(
                      slice.text,
                      key: ValueKey((slice.block.id, slice.startOffset)),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      mode.value = ReaderPaginationMode.vertical;
      await tester.pumpAndSettle();
      final target = find.byKey(ValueKey((id, 0)));
      final body = tester.getRect(find.byType(ReflowDocumentPager));
      expect(target.hitTestable(at: Alignment.topLeft), findsOneWidget);
      expect(tester.getTopLeft(target).dy, closeTo(body.top + 18, 5));
      expect(
        find
            .byKey(ValueKey((pages[42].entryNear(.15)!.blockId, 0)))
            .hitTestable(),
        findsNothing,
      );
    },
  );

  testWidgets(
    'live typography and reset retain a late PDF paragraph on every frame',
    (tester) async {
      final pages = List.generate(
        56,
        (index) => CompanionReflowPage(index + 1, [
          CompanionReflowLine(
            'Source ${index + 1}. ${List.filled(20, 'Reading here.').join(' ')}',
            const Rect.fromLTWH(.1, .15, .8, .4),
          ),
        ]),
      );
      final document = CompanionReflowPage.readingWindow(pages, pages.length);
      final source = pages[46].entryNear(.15)!;
      final display = CompanionReflowPage.displayPosition(
        document,
        source.blockId,
        8,
      )!;
      final anchor = FlowReaderAnchor(
        sourceId: 'source',
        chapterId: CompanionReflowPage.readingChapterId,
        blockId: display.blockId,
        characterOffset: display.offset,
      );
      final settings = ValueNotifier((
        font: 17.0,
        margin: 24.0,
        line: 1.7,
        moving: false,
      ));
      addTearDown(settings.dispose);
      final reports = <FlowReaderAnchor>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: settings,
              builder: (context, value, _) {
                TextStyle style(TextStyle base) =>
                    base.copyWith(fontSize: value.font, height: value.line);
                return ReflowDocumentPager(
                  document: document,
                  sourceId: 'source',
                  mode: ReaderPaginationMode.horizontal,
                  initialChapterId: anchor.chapterId,
                  initialAnchor: anchor,
                  previewTypography: value.moving,
                  textStyleBuilder: style,
                  verticalPadding: EdgeInsets.symmetric(
                    horizontal: value.margin,
                    vertical: 12,
                  ),
                  blockBuilder: (_, slice, _) => Text(
                    slice.text,
                    key: ValueKey((slice.block.id, slice.startOffset)),
                    style: style(const TextStyle()),
                  ),
                  onAnchorChanged: reports.add,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pager = find.byType(PageView);
      int screen() => tester.widget<PageView>(pager).controller!.page!.round();
      final defaultPage = screen();
      expect(defaultPage, greaterThan(5));
      expect(
        readerAnchorJson(reports.last),
        readerAnchorJson(anchor),
        reason: 'Initial anchor',
      );
      for (final value in [
        (font: 25.0, margin: 65.0, line: 2.1, moving: true),
        (font: 25.0, margin: 65.0, line: 2.1, moving: false),
        (font: 14.0, margin: 15.0, line: 1.4, moving: true),
        (font: 14.0, margin: 15.0, line: 1.4, moving: false),
        (font: 17.0, margin: 24.0, line: 1.7, moving: false),
      ]) {
        settings.value = value;
        for (var frame = 0; frame < 35; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            screen(),
            greaterThan(0),
            reason: 'The cover must never replace the current text',
          );
          expect(
            readerAnchorJson(reports.last),
            readerAnchorJson(anchor),
            reason:
                'Layout $value frame $frame must retain its source character',
          );
          final shown = find.descendant(
            of: find.byKey(Key('book_body_document_page_${screen()}')),
            matching: find.byType(Text),
          );
          if (value.moving) {
            expect(
              find
                  .byKey(ValueKey((display.blockId, display.offset)))
                  .hitTestable(),
              findsOneWidget,
              reason:
                  'The saved paragraph stays visible while the finger is down',
            );
          }
          expect(
            tester
                .widgetList<Text>(shown)
                .any(
                  (text) =>
                      text.style?.fontSize == value.font &&
                      text.style?.height == value.line,
                ),
            isTrue,
          );
        }
        await tester.pumpAndSettle();
      }
      expect(screen(), defaultPage);
    },
  );

  testWidgets('a tall PDF figure fits on one horizontal reading screen', (
    tester,
  ) async {
    const picture = CompanionPagePicture(
      Rect.fromLTWH(.4, .1, .2, .8),
      .25,
      XiaoqiDocumentAsset(id: 'tall-figure', mimeType: 'image/png', bytes: []),
    );
    const page = CompanionReflowPage(1, [], pictures: [picture]);
    CompanionPagePicture? previewed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 440,
              child: ReflowDocumentPager(
                document: CompanionReflowPage.readingWindow([page], 1),
                sourceId: 'source',
                initialChapterId: CompanionReflowPage.readingChapterId,
                mode: ReaderPaginationMode.horizontal,
                blockBuilder: (_, _, _) => CompanionPdfObjectView(
                  picture: picture,
                  pageObjects: const [],
                  isOriginalPage: false,
                  onPreview: (selected) => previewed = selected,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final target = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == '预览图片',
    );
    final image = tester.getRect(target);
    final viewport = tester.getRect(find.byType(ReflowDocumentPager));
    expect(image.width / image.height, closeTo(picture.aspectRatio, .001));
    expect(image.center.dx, closeTo(viewport.center.dx, 1));
    expect(image.top, closeTo(viewport.top + 18, 1));
    expect(image.bottom, closeTo(viewport.bottom - 28 - 12, 1));
    final pageScroll = find.ancestor(
      of: target,
      matching: find.byType(SingleChildScrollView),
    );
    expect(
      tester.widget<SingleChildScrollView>(pageScroll).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    await tester.tapAt(Offset(image.center.dx, image.bottom - 2));
    expect(previewed, same(picture));
  });

  testWidgets('a wide table drag does not turn the book at its edge', (
    tester,
  ) async {
    const picture = CompanionPagePicture(
      Rect.fromLTWH(.05, .2, .9, .25),
      4,
      XiaoqiDocumentAsset(id: 'wide-table', mimeType: 'image/png', bytes: []),
      minimumReadableWidth: 1200,
    );
    const page = CompanionReflowPage(1, [], pictures: [picture]);
    var attemptsToTurnBook = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReflowDocumentPager(
            document: CompanionReflowPage.readingWindow([page], 2),
            sourceId: 'source',
            initialChapterId: CompanionReflowPage.readingChapterId,
            mode: ReaderPaginationMode.horizontal,
            onNextDocument: () => attemptsToTurnBook++,
            blockBuilder: (context, slice, _) => CompanionPdfObjectView(
              picture: picture,
              pageObjects: const [],
              isOriginalPage: false,
              onPreview: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final table = find.descendant(
      of: find.byType(CompanionPdfObjectView),
      matching: find.byType(Scrollable),
    );
    await tester.drag(table, const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(table).position.pixels,
      greaterThan(0),
    );
    expect(attemptsToTurnBook, 0);
  });

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
