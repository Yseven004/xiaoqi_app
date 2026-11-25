import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/models/companion_source_range.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/companion_pdf_reflow.dart';
import 'package:xiaoqi_app/services/reading_companion_translation.dart';

CompanionPdfTextRun run({
  required String original,
  required int source,
  required int display,
  required int length,
  int page = 1,
}) {
  final bounds = trimCompanionRange(original, 0, original.length)!;
  return (
    displayStart: display,
    length: length,
    page: page,
    sourceStart: source,
    precedingTextEnd: original.substring(0, source).trimRight().length,
    firstTextOffset: bounds.start,
    lastTextEnd: bounds.end,
    textHash: companionTextHash(original),
  );
}

void main() {
  test('repeated PDF text uses actual offsets in both directions', () {
    const original = 'repeat\nrepeat';
    final projection = CompanionPdfTextProjection('repeat repeat', [
      run(original: original, source: 0, display: 0, length: 6),
      run(original: original, source: 7, display: 7, length: 6),
    ]);
    final second = projection.sourceRange(7, 13)!;
    expect(second.pages.single.start, 7);
    expect(projection.displayRange(second), (start: 7, end: 13));
    expect(CompanionSourceRange.fromJson(second.toJson())?.key, second.key);
    final untrusted = CompanionPdfSourceRange([
      (page: 1, start: 7, end: 13, textHash: 'wrong text version'),
    ]);
    expect(projection.displayRange(untrusted), isNull);
  });

  test('reflow rejects OCR overlap or skipped native characters', () {
    const original = 'left missing right';
    final projection = CompanionPdfTextProjection('left ocr right', [
      run(original: original, source: 0, display: 0, length: 4),
      run(original: original, source: 13, display: 9, length: 5),
    ]);
    expect(projection.sourceRange(0, 14), isNull);
    final skipped = CompanionPdfTextProjection('left right', [
      run(original: original, source: 0, display: 0, length: 4),
      run(original: original, source: 13, display: 5, length: 5),
    ]);
    expect(skipped.sourceRange(0, 10), isNull);
    expect(
      skipped.displayRange(
        CompanionPdfSourceRange([
          (page: 1, start: 0, end: 18, textHash: companionTextHash(original)),
        ]),
      ),
      isNull,
    );
  });

  test('cached runs survive page merge and map a cross-page selection', () {
    const first = 'left side of the text';
    const second = 'continues here.';
    final left = CompanionReflowLine(
      first,
      const Rect.fromLTWH(.1, .82, .8, .04),
      pdfTextRuns: [
        run(original: first, source: 0, display: 0, length: first.length),
      ],
    );
    final right = CompanionReflowLine(
      second,
      const Rect.fromLTWH(.1, .11, .8, .04),
      pdfTextRuns: [
        run(
          original: second,
          source: 0,
          display: 0,
          length: second.length,
          page: 2,
        ),
      ],
    );
    final document = CompanionReflowPage.readingWindow([
      CompanionReflowPage(1, [CompanionReflowLine.fromJson(left.toJson())]),
      CompanionReflowPage(2, [CompanionReflowLine.fromJson(right.toJson())]),
    ], 2);
    final joined = document.chapters.single.blocks.single;
    final projection = CompanionReflowPage.sourceProjection(joined);
    final source = projection.sourceRange(5, joined.text.length - 1)!;
    expect(source.pages.map((page) => page.page), [1, 2]);
    expect(source.pages.first.start, 5);
    expect(source.pages.last.end, second.length - 1);
    expect(projection.displayRange(source), (
      start: 5,
      end: joined.text.length - 1,
    ));
  });

  test('complete translated units share an exact original range', () {
    const original = 'First sentence. Second sentence!\n\nThird sentence.';
    final units = CompanionTranslationText.sourceUnits(original);
    final aligned = CompanionTranslationText.fromUnits(original, units, [
      '第一句。',
      '第二句！',
      '第三句。',
    ]);
    expect(aligned.text, '第一句。 第二句！\n\n第三句。');
    final second = aligned.text.indexOf('第二句！');
    final projected = aligned.sourceRange(second, second + 4)!;
    expect(
      original.substring(projected.start, projected.end),
      'Second sentence!',
    );
    expect(aligned.translatedRange(projected.start, projected.end), (
      start: second,
      end: second + 4,
    ));
    expect(aligned.sourceRange(second + 1, second + 4), isNull);
    expect(aligned.translatedRange(projected.start, projected.end - 1), isNull);
  });

  test('canonical selection identity omits view and device-local ids', () {
    final source = CompanionPdfSourceRange([
      (page: 1, start: 2, end: 4, textHash: 'structured-source'),
    ]);
    CompanionAnnotationSelection selection(
      int local,
      String version,
      String view,
    ) => CompanionAnnotationSelection(
      bookId: local,
      sourceId: local,
      sourceVersion: version,
      anchor: PdfReaderAnchor(sourceId: '$local', pageNumber: 1),
      locator: '第 1 页',
      quote: view,
      view: view,
      canonicalRange: source,
    );
    final annotation = selection(17, 'edition', 'translated');
    expect(annotation.key, selection(27, 'edition', 'reflow').key);
    expect(
      annotation.key,
      isNot(selection(27, 'another edition', 'reflow').key),
    );
    expect(
      CompanionAnnotationSelection.fromJson(
        annotation.toJson(),
        bookId: 2,
        sourceId: 3,
      ).canonicalRange?.key,
      source.key,
    );
  });
}
