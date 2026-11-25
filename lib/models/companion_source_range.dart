import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

typedef CompanionTextRange = ({int start, int end});
typedef CompanionPdfRange = ({int page, int start, int end, String textHash});

/// A half-open range in a source-version coordinate system. Device-local IDs,
/// layout line breaks and the translation's wording do not define its identity.
sealed class CompanionSourceRange {
  const CompanionSourceRange();

  List<Object> toJson();
  String get key => jsonEncode(toJson());

  static CompanionSourceRange? fromJson(Object? value) {
    if (value is! List || value.isEmpty) return null;
    if (value case [
      'flow',
      final String chapter,
      final String block,
      final int start,
      final int end,
      final String hash,
    ]) {
      if (start < 0 || end <= start || hash.isEmpty) return null;
      return CompanionFlowSourceRange(
        chapter: chapter,
        block: block,
        start: start,
        end: end,
        textHash: hash,
      );
    }
    if (value case ['pdf', final List pages]) {
      final ranges = <CompanionPdfRange>[];
      for (final row in pages) {
        if (row
            case [
              final int page,
              final int start,
              final int end,
              final String hash,
            ]
            when page > (ranges.lastOrNull?.page ?? 0) &&
                start >= 0 &&
                end > start &&
                hash.isNotEmpty) {
          ranges.add((page: page, start: start, end: end, textHash: hash));
        } else {
          return null;
        }
      }
      if (ranges.isNotEmpty) return CompanionPdfSourceRange(ranges);
    }
    return null;
  }
}

final class CompanionFlowSourceRange extends CompanionSourceRange {
  const CompanionFlowSourceRange({
    required this.chapter,
    required this.block,
    required this.start,
    required this.end,
    required this.textHash,
  });

  final String chapter;
  final String block;
  final int start;
  final int end;
  final String textHash;

  @override
  List<Object> toJson() => ['flow', chapter, block, start, end, textHash];
}

final class CompanionPdfSourceRange extends CompanionSourceRange {
  CompanionPdfSourceRange(Iterable<CompanionPdfRange> pages)
    : pages = List.unmodifiable(pages);

  final List<CompanionPdfRange> pages;

  @override
  List<Object> toJson() => [
    'pdf',
    [
      for (final page in pages)
        [page.page, page.start, page.end, page.textHash],
    ],
  ];
}

String companionTextHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();

CompanionTextRange? trimCompanionRange(String text, int start, int end) {
  if (start < 0 || end > text.length || end <= start) return null;
  final selected = text.substring(start, end);
  final left = selected.trimLeft();
  final trimmed = left.trimRight();
  if (trimmed.isEmpty) return null;
  final first = start + selected.length - left.length;
  return (start: first, end: first + trimmed.length);
}

/// A contiguous run copied verbatim from pdfrx's structured text. Separators
/// inserted by reflow have no run. Source-space gaps can only be crossed when
/// the extraction recorded that those gaps contain whitespace.
typedef CompanionPdfTextRun = ({
  int displayStart,
  int length,
  int page,
  int sourceStart,
  int precedingTextEnd,
  int firstTextOffset,
  int lastTextEnd,
  String textHash,
});

extension CompanionPdfTextRunData on CompanionPdfTextRun {
  CompanionPdfTextRun shifted(int offset) => (
    displayStart: displayStart + offset,
    length: length,
    page: page,
    sourceStart: sourceStart,
    precedingTextEnd: precedingTextEnd,
    firstTextOffset: firstTextOffset,
    lastTextEnd: lastTextEnd,
    textHash: textHash,
  );

  List<Object> toJson() => [
    displayStart,
    length,
    page,
    sourceStart,
    precedingTextEnd,
    firstTextOffset,
    lastTextEnd,
    textHash,
  ];
}

List<CompanionPdfTextRun> companionPdfTextRunsFromJson(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row case [
        final int displayStart,
        final int length,
        final int page,
        final int sourceStart,
        final int precedingTextEnd,
        final int firstTextOffset,
        final int lastTextEnd,
        final String hash,
      ])
        (
          displayStart: displayStart,
          length: length,
          page: page,
          sourceStart: sourceStart,
          precedingTextEnd: precedingTextEnd,
          firstTextOffset: firstTextOffset,
          lastTextEnd: lastTextEnd,
          textHash: hash,
        ),
];

class CompanionPdfTextProjection {
  const CompanionPdfTextProjection(this.text, this.runs);

  final String text;
  final List<CompanionPdfTextRun> runs;

  CompanionPdfSourceRange? sourceRange(int start, int end) {
    final visible = trimCompanionRange(text, start, end);
    if (visible == null) return null;
    final pages = <CompanionPdfRange>[];
    var cursor = visible.start;
    CompanionPdfTextRun? previous;
    for (final run in runs) {
      final from = math.max(visible.start, run.displayStart);
      final to = math.min(visible.end, run.displayStart + run.length);
      if (from >= to) continue;
      if (from < cursor || text.substring(cursor, from).trim().isNotEmpty) {
        return null;
      }
      cursor = to;
      final originalStart = run.sourceStart + from - run.displayStart;
      final originalEnd = originalStart + to - from;
      final current = pages.lastOrNull;
      if (current?.page == run.page) {
        if (current!.textHash != run.textHash ||
            originalStart < current.end ||
            run.precedingTextEnd > current.end) {
          return null;
        }
        pages[pages.length - 1] = (
          page: run.page,
          start: current.start,
          end: originalEnd,
          textHash: run.textHash,
        );
      } else {
        if (current != null &&
            (run.page != current.page + 1 ||
                current.end != previous!.lastTextEnd ||
                originalStart != run.firstTextOffset)) {
          return null;
        }
        pages.add((
          page: run.page,
          start: originalStart,
          end: originalEnd,
          textHash: run.textHash,
        ));
      }
      previous = run;
    }
    if (pages.isEmpty ||
        text.substring(cursor, visible.end).trim().isNotEmpty) {
      return null;
    }
    return CompanionPdfSourceRange(pages);
  }

  /// Computes only the portion displayed in this block. Each candidate is
  /// checked by projecting back, so an ambiguous order or inserted OCR text
  /// cannot join disjoint native content under one line.
  CompanionTextRange? displayRange(CompanionPdfSourceRange source) {
    int? first;
    int? last;
    for (final run in runs) {
      final page = source.pages
          .where(
            (item) => item.page == run.page && item.textHash == run.textHash,
          )
          .firstOrNull;
      if (page == null) continue;
      final start = math.max(page.start, run.sourceStart);
      final end = math.min(page.end, run.sourceStart + run.length);
      if (start >= end) continue;
      first ??= run.displayStart + start - run.sourceStart;
      last = run.displayStart + end - run.sourceStart;
    }
    if (first == null || last == null) return null;
    final roundTrip = sourceRange(first, last);
    if (roundTrip == null ||
        roundTrip.pages.any(
          (actual) => !source.pages.any(
            (allowed) =>
                actual.page == allowed.page &&
                actual.textHash == allowed.textHash &&
                actual.start >= allowed.start &&
                actual.end <= allowed.end,
          ),
        )) {
      return null;
    }
    return (start: first, end: last);
  }
}
