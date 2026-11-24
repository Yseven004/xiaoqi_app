import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import '../plugins/document_recognition/fast_ocr_plugin.dart';

part 'companion_pdf_text_styles.dart';
part 'companion_pdf_objects.dart';
part 'companion_pdf_preparation.dart';

typedef CompanionPdfLink = ({Rect bounds, String target});

/// A source page, in reading order, with geometry in original page fractions.
class CompanionReflowPage {
  static const readingChapterId = 'pdf-reflow-body';
  static final _chapterHeading = RegExp(
    r'^(?:第[\s零〇一二三四五六七八九十百千万萬两兩\d０-９]+([卷篇部章节節回])|(chapter|part|section)\s+(?:\d+|[ivxlcdm]+)\b)',
    caseSensitive: false,
  );
  static final _sentenceEnd = RegExp(r'''[。！？.!?][”」』’"）)]*$''');
  static final _han = RegExp(r'[\u3400-\u9fff]');
  // Short CJK titles can include names, product numbers or Latin words.
  static final _shortTitle = RegExp(
    r'^[\u3400-\u9fffA-Za-zＡ-Ｚａ-ｚ0-9０-９]+(?:[\s　·・‧\-]+[\u3400-\u9fffA-Za-zＡ-Ｚａ-ｚ0-9０-９]+)*$',
  );
  static final _pageFolio = RegExp(
    r'^(?:[–—-]\s*)?[0-9０-９]{1,4}(?:\s*[–—-])?$',
  );

  const CompanionReflowPage(
    this.number,
    this.lines, {
    this.keepOriginal = false,
    this.pictures = const [],
    this.links = const [],
    this._selectablePictures,
  });

  final int number;
  final List<CompanionReflowLine> lines;
  final bool keepOriginal;
  final List<CompanionPagePicture> pictures;
  final List<CompanionPdfLink> links;
  final List<CompanionPagePicture>? _selectablePictures;
  List<CompanionPagePicture> get selectablePictures =>
      _selectablePictures ?? (keepOriginal ? const [] : pictures);
  int get imageByteCount =>
      pictures.fold(0, (sum, picture) => sum + picture.asset.bytes.length);
  bool get canRead =>
      pictures.isNotEmpty || (!keepOriginal && lines.isNotEmpty);

  String get text => lines.map((line) => line.text).join('\n');
  String get chapterId => 'pdf-page-$number';

  List<_ReflowParagraph> get _paragraphs {
    final textLines = [
      for (final (index, line) in lines.indexed)
        if (!_isPageFolio(line) &&
            !pictures.any((item) => item.bounds.contains(line.bounds.center)))
          (index: index, line: line),
    ];
    final body = _bodyLines(textLines.map((item) => item.line));
    final bodySize = _median(body.map((line) => line.typeSize));
    final leftMargin = _median(body.map((line) => line.bounds.left));
    final rightMargin = _median(body.map((line) => line.bounds.right));
    final paragraphs = <_ReflowParagraph>[];
    CompanionReflowLine? preceding;
    var precedingLevel = 0;
    for (var i = 0; i < textLines.length; i++) {
      final (index: index, line: line) = textLines[i];
      final previous = preceding;
      final next = i + 1 < textLines.length ? textLines[i + 1].line : null;
      final level = _headingLevel(line, previous, next, bodySize);
      if (previous == null ||
          pictures.any(
            (item) =>
                item.bounds.center.dy > previous.bounds.center.dy &&
                item.bounds.center.dy < line.bounds.center.dy,
          ) ||
          _startsParagraph(
            line,
            previous,
            level,
            precedingLevel,
            rightMargin,
          )) {
        paragraphs.add(
          _ReflowParagraph(
            '$chapterId-line-$index',
            line,
            level,
            centered:
                level > 0 &&
                _centeredHeading(line.bounds, leftMargin, rightMargin),
          ),
        );
      } else {
        final paragraph = paragraphs.last;
        if (paragraph.centered &&
            !_centeredHeading(line.bounds, leftMargin, rightMargin)) {
          paragraph.centered = false;
        }
        paragraph.append(line);
      }
      preceding = line;
      precedingLevel = level;
    }
    return paragraphs;
  }

  static bool _isPageFolio(CompanionReflowLine line) {
    final bounds = line.bounds;
    return line.paragraphTag == null &&
        bounds.width < .08 &&
        bounds.height < .033 &&
        (bounds.center.dx - .5).abs() < .035 &&
        (bounds.bottom <= .05 || bounds.top >= .91) &&
        _pageFolio.hasMatch(line.text);
  }

  static List<CompanionReflowLine> _bodyLines(
    Iterable<CompanionReflowLine> input,
  ) => [
    for (final line in input)
      if (line.headingLevel == 0 &&
          line.bounds.width >= .45 &&
          line.text.length >= 12 &&
          !_chapterHeading.hasMatch(line.text) &&
          !_caption.hasMatch(line.text) &&
          !_listMarker.hasMatch(line.text))
        line,
  ];

  static double? _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    return sorted.isEmpty ? null : sorted[sorted.length ~/ 2];
  }

  static bool _centeredHeading(Rect box, double? bodyLeft, double? bodyRight) {
    final left = bodyLeft ?? 0.0;
    final right = bodyRight ?? 1.0;
    final width = right - left;
    // A near-full line shares the column midpoint even when left aligned.
    return box.left - left > .06 * width &&
        right - box.right > .06 * width &&
        (box.center.dx - (left + right) / 2).abs() <= .045 * width;
  }

  static int _headingLevel(
    CompanionReflowLine line,
    CompanionReflowLine? previous,
    CompanionReflowLine? next,
    double? bodySize,
  ) {
    if (line.paragraphTag != null) return line.headingLevel;
    final text = line.text;
    if (text.length > 72 ||
        _caption.hasMatch(text) ||
        _listMarker.hasMatch(text) ||
        _sentenceEnd.hasMatch(text)) {
      return 0;
    }
    if (_dateLine.hasMatch(text) ||
        _yearCredit.hasMatch(text) ||
        text.contains('（上）') ||
        text.contains('（下）')) {
      return 0;
    }
    final numbered = _chapterHeading.firstMatch(text);
    if (numbered != null) {
      return const {'节', '節'}.contains(numbered.group(1)) ||
              numbered.group(2)?.toLowerCase() == 'section'
          ? 2
          : 1;
    }
    if (bodySize == null || bodySize <= 0 || next == null) return 0;
    // A short line can be the end of an ordinary paragraph. Require layout
    // separation and a typeface cue before promoting it.
    final placeAbove =
        previous == null ||
        line.bounds.top - previous.bounds.bottom >= bodySize * .45;
    final placeBelow = next.bounds.top - line.bounds.bottom >= bodySize * .18;
    final scale = line.typeSize / bodySize;
    final isolatedSection =
        previous != null &&
        text.length >= 2 &&
        text.length <= 12 &&
        _han.hasMatch(text) &&
        _shortTitle.hasMatch(text) &&
        next.text.length >= 12 &&
        line.bounds.width < .32 &&
        line.bounds.top - previous.bounds.bottom >= bodySize * .85 &&
        next.bounds.top - line.bounds.bottom >= bodySize * .85;
    if (!placeAbove ||
        !placeBelow ||
        line.bounds.width > .65 ||
        (scale < 1.16 && !line.isMostlyBold && !isolatedSection)) {
      return 0;
    }
    if (scale >= 1.65) return 1;
    if (scale >= 1.30) return 2;
    return 3;
  }

  static bool _startsParagraph(
    CompanionReflowLine line,
    CompanionReflowLine previous,
    int level,
    int previousLevel,
    double? rightMargin,
  ) {
    if (line.paragraphTag != null && previous.paragraphTag != null) {
      return line.paragraphTag != previous.paragraphTag;
    }
    final height = math.max(line.bounds.height, previous.bounds.height);
    final differentOcrParagraph =
        line.ocrParagraph != null &&
        previous.ocrParagraph != null &&
        line.ocrParagraph != previous.ocrParagraph;
    return level > 0 ||
        previousLevel > 0 ||
        _caption.hasMatch(line.text) ||
        _caption.hasMatch(previous.text) ||
        _listMarker.hasMatch(line.text) ||
        differentOcrParagraph ||
        line.bounds.top - previous.bounds.bottom > height * .76 ||
        line.bounds.left - previous.bounds.left > height * .85 ||
        (rightMargin != null &&
            rightMargin - previous.bounds.right > height * 2.5 &&
            _sentenceEnd.hasMatch(previous.text));
  }

  static final _dateLine = RegExp(r'[0-9０-９]{4}\s*年\s*[0-9０-９]{1,2}\s*月');
  static final _yearCredit = RegExp(r'[0-9０-９]{4}\s*年$');
  static final _caption = RegExp(
    r'^(?:(?:图|圖|表)\s*[0-9０-９一二三四五六七八九十]+|(?:fig(?:ure)?\.?|table)\s*\d)',
    caseSensitive: false,
  );
  static final _listMarker = RegExp(
    r'^(?:[•●■▪]|[-–]\s|[（(][0-9０-９]+[)）]|[0-9０-９]+[、)]|\d+\.\s)',
  );

  ({String blockId, int offset})? entryNear(double? top) {
    if (top == null) return null;
    final entries = [
      for (final paragraph in _paragraphs)
        for (final entry in paragraph.lines)
          (
            bottom: entry.line.bounds.bottom,
            id: paragraph.id,
            offset: entry.offset,
          ),
      for (final picture in pictures)
        (bottom: picture.bounds.bottom, id: picture.asset.id, offset: 0),
    ]..sort((a, b) => a.bottom.compareTo(b.bottom));
    if (entries.isNotEmpty) {
      final entry = entries.firstWhere(
        (item) => item.bottom >= top,
        orElse: () => entries.last,
      );
      return (blockId: entry.id, offset: entry.offset);
    }
    return null;
  }

  double? originalTop(String? blockId, int? offset) {
    if (blockId == null || offset == null || offset < 0) return null;
    for (final picture in pictures) {
      if (picture.asset.id == blockId) return picture.bounds.top;
    }
    for (final paragraph in _paragraphs) {
      if (paragraph.id == blockId) {
        if (offset > paragraph.body.length) return null;
        return paragraph.lines
            .lastWhere((entry) => entry.offset <= offset)
            .line
            .bounds
            .top;
      }
    }
    return null;
  }

  static XiaoqiDocument readingWindow(
    Iterable<CompanionReflowPage> pages,
    int pageCount,
  ) {
    final blocks = <XiaoqiDocumentBlock>[];
    CompanionReflowPage? previous;
    for (final page in pages) {
      final items = page._blocks();
      if (items.isNotEmpty &&
          blocks.isNotEmpty &&
          previous != null &&
          page.number == previous.number + 1 &&
          _continuesAcrossPage(blocks.last, items.first, previous, page)) {
        final first = items.removeAt(0);
        final last = blocks.removeLast();
        final prefix =
            last.text + _ReflowParagraph.separator(last.text, first.text);
        blocks.add(
          XiaoqiDocumentBlock(
            id: last.id,
            kind: last.kind,
            level: last.level,
            text: prefix + first.text,
            sourceLocator: last.sourceLocator,
            originalPageLabel: last.originalPageLabel,
            attributes: {
              ...last.attributes,
              ..._boldAttributes([
                ...last.boldRanges,
                for (final range in first.boldRanges)
                  (
                    start: prefix.length + range.start,
                    end: prefix.length + range.end,
                  ),
              ]),
              if (last.attributes.containsKey('linkRanges') ||
                  first.attributes.containsKey('linkRanges'))
                'linkRanges': jsonEncode([
                  ...jsonDecode(last.attributes['linkRanges'] ?? '[]') as List,
                  for (final row
                      in jsonDecode(first.attributes['linkRanges'] ?? '[]')
                          as List)
                    [
                      prefix.length + (row[0] as int),
                      prefix.length + (row[1] as int),
                      row[2],
                    ],
                ]),
              first.id: prefix.length.toString(),
            },
          ),
        );
      }
      blocks.addAll(items);
      previous = page;
    }
    return XiaoqiDocument(
      format: 'pdf-reflow',
      title: '',
      author: '',
      language: '',
      originalPageCount: pageCount,
      assets: [
        for (final page in pages)
          for (final picture in page.pictures) picture.asset,
      ],
      chapters: [
        XiaoqiDocumentChapter(
          id: readingChapterId,
          title: '',
          href: readingChapterId,
          html: '',
          plainText: pages.map((page) => page.text).join('\n\n'),
          order: 0,
          blocks: blocks,
        ),
      ],
    );
  }

  List<XiaoqiDocumentBlock> _blocks() {
    final items = <({double top, XiaoqiDocumentBlock block})>[
      for (final paragraph in _paragraphs)
        (
          top: paragraph.lines.first.line.bounds.top,
          block: XiaoqiDocumentBlock(
            id: paragraph.id,
            kind: paragraph.headingLevel > 0 ? 'heading' : 'paragraph',
            level: paragraph.headingLevel,
            text: paragraph.body.toString(),
            sourceLocator: 'page:$number',
            originalPageLabel: '$number',
            attributes: {
              if (paragraph.centered) 'textAlign': 'center',
              ..._boldAttributes(paragraph.boldRanges),
              if (paragraph.lines.any((e) => e.line.linkRanges.isNotEmpty))
                'linkRanges': jsonEncode([
                  for (final entry in paragraph.lines)
                    for (final link in entry.line.linkRanges)
                      [
                        entry.offset + link.start,
                        entry.offset + link.end,
                        link.target,
                      ],
                ]),
            },
          ),
        ),
      for (final picture in pictures)
        (
          top: picture.bounds.top,
          block: XiaoqiDocumentBlock(
            id: picture.asset.id,
            kind: 'image',
            assetId: picture.asset.id,
            text: '',
            originalPageLabel: '$number',
            sourceLocator: picture.asset.sourceLocator,
            attributes: {
              'aspectRatio': picture.aspectRatio.toString(),
              if (picture.minimumReadableWidth case final width?)
                'minimumReadableWidth': width.toString(),
              if (picture.bounds == const Rect.fromLTWH(0, 0, 1, 1))
                'originalPageImage': 'true',
            },
          ),
        ),
    ]..sort((a, b) => a.top.compareTo(b.top));
    return items.map((item) => item.block).toList();
  }

  static bool _continuesAcrossPage(
    XiaoqiDocumentBlock end,
    XiaoqiDocumentBlock start,
    CompanionReflowPage previous,
    CompanionReflowPage next,
  ) {
    if (end.kind != 'paragraph' ||
        start.kind != 'paragraph' ||
        _caption.hasMatch(end.text) ||
        _caption.hasMatch(start.text) ||
        _listMarker.hasMatch(start.text)) {
      return false;
    }
    final lastParagraph = previous._paragraphs.last;
    final firstParagraph = next._paragraphs.first;
    final last = lastParagraph.lines.last.line.bounds;
    final first = firstParagraph.lines.first.line.bounds;
    final precedingBody = _bodyLines(previous.lines);
    final followingBody = _bodyLines(next.lines);
    final bodyRight = _median(precedingBody.map((line) => line.bounds.right));
    final bodyLeft = _median(followingBody.map((line) => line.bounds.left));
    final endsWithSentence = _sentenceEnd.hasMatch(end.text);
    return (!endsWithSentence ||
            (precedingBody.length >= 3 &&
                bodyRight != null &&
                last.right >= bodyRight - last.height * .8)) &&
        (bodyLeft == null || first.left <= bodyLeft + first.height * .6) &&
        last.bottom > .65 &&
        first.top < .35 &&
        last.width > .48 &&
        (first.left - last.left).abs() <= .025;
  }

  static Map<String, String> _boldAttributes(List<DocumentBoldRange> ranges) =>
      {
        if (ranges.isNotEmpty)
          'boldRanges': jsonEncode([
            for (final range in ranges) [range.start, range.end],
          ]),
      };

  /// Map a position in a joined paragraph back to its original PDF block.
  static ({String blockId, int offset})? sourcePosition(
    XiaoqiDocument document,
    String? blockId,
    int offset,
  ) {
    if (blockId == null) return null;
    for (final block in document.chapters.first.blocks) {
      if (block.id != blockId) continue;
      var id = blockId;
      var base = 0;
      for (final entry in block.attributes.entries) {
        if (!entry.key.startsWith('pdf-page-')) continue;
        final start = int.parse(entry.value);
        if (start > offset) break;
        id = entry.key;
        base = start;
      }
      return (blockId: id, offset: offset - base);
    }
    return null;
  }

  /// Map an original PDF block to its containing paragraph in this window.
  static ({String blockId, int offset})? displayPosition(
    XiaoqiDocument document,
    String? blockId,
    int offset,
  ) {
    if (blockId == null) return null;
    for (final block in document.chapters.first.blocks) {
      if (block.id == blockId) return (blockId: blockId, offset: offset);
      final base = int.tryParse(block.attributes[blockId] ?? '');
      if (base != null) return (blockId: block.id, offset: base + offset);
    }
    return null;
  }

  static int? pageForBlock(String? blockId) {
    final match = blockId == null ? null : _pageInBlock.firstMatch(blockId);
    return int.tryParse(match?.group(1) ?? '');
  }

  static final _pageInBlock = RegExp(r'^pdf-page-(\d+)-(?:line|image)-');
}

class _ReflowParagraph {
  _ReflowParagraph(
    this.id,
    CompanionReflowLine first,
    this.headingLevel, {
    required this.centered,
  }) : body = StringBuffer(first.text),
       lines = [(line: first, offset: 0)];

  final String id;
  final int headingLevel;
  bool centered;
  final StringBuffer body;
  final List<({CompanionReflowLine line, int offset})> lines;
  List<DocumentBoldRange> get boldRanges => [
    for (final (line: line, offset: offset) in lines)
      for (final range in line.boldRanges)
        (start: offset + range.start, end: offset + range.end),
  ];
  static final _eastAsian = RegExp(
    r'[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]',
  );
  static String separator(String previous, String next) {
    final last = previous.substring(previous.length - 1);
    final first = next.substring(0, 1);
    if (_eastAsian.hasMatch(last) ||
        _eastAsian.hasMatch(first) ||
        '([{-/'.contains(last) ||
        '.,;:!?)]}'.contains(first)) {
      return '';
    }
    return ' ';
  }

  void append(CompanionReflowLine line) {
    final previous = lines.last.line.text;
    body.write(separator(previous, line.text));
    lines.add((line: line, offset: body.length));
    body.write(line.text);
  }
}

class CompanionPagePicture {
  const CompanionPagePicture(
    this.bounds,
    this.aspectRatio,
    this.asset, {
    this.minimumReadableWidth,
    this.cachePath,
  });

  final Rect bounds;
  final double aspectRatio;
  final XiaoqiDocumentAsset asset;
  final double? minimumReadableWidth;
  final String? cachePath;
  bool get isTable => minimumReadableWidth != null;

  CompanionPagePicture withBytes(Uint8List bytes, {String? cachePath}) =>
      CompanionPagePicture(
        bounds,
        aspectRatio,
        XiaoqiDocumentAsset(
          id: asset.id,
          mimeType: asset.mimeType,
          bytes: bytes,
          altText: asset.altText,
          sourceLocator: asset.sourceLocator,
        ),
        minimumReadableWidth: minimumReadableWidth,
        cachePath: cachePath,
      );

  Map<String, dynamic> toJson() => {
    'box': [bounds.left, bounds.top, bounds.right, bounds.bottom],
    'aspect': aspectRatio,
    'asset': asset.toMap(),
    if (minimumReadableWidth != null) 'tableWidth': minimumReadableWidth,
  };
  factory CompanionPagePicture.fromJson(
    Map<String, dynamic> map, {
    String? cachePath,
  }) {
    final box = (map['box'] as List).cast<num>();
    return CompanionPagePicture(
      Rect.fromLTRB(
        box[0].toDouble(),
        box[1].toDouble(),
        box[2].toDouble(),
        box[3].toDouble(),
      ),
      (map['aspect'] as num).toDouble(),
      XiaoqiDocumentAsset.fromMap(map['asset'] as Map<String, dynamic>),
      minimumReadableWidth: (map['tableWidth'] as num?)?.toDouble(),
      cachePath: cachePath,
    );
  }
}

class CompanionReflowLine {
  const CompanionReflowLine(
    this.text,
    this.bounds, {
    this.recognized = false,
    this.fontSize,
    this.paragraphTag,
    this.headingLevel = 0,
    this.ocrParagraph,
    this.boldRanges = const [],
    this.linkRanges = const [],
  });

  final String text;
  final Rect bounds;
  final bool recognized;
  final double? fontSize;
  final int? paragraphTag;
  final int headingLevel;
  final String? ocrParagraph;
  final List<DocumentBoldRange> boldRanges;
  final List<DocumentLinkRange> linkRanges;

  double get typeSize => fontSize ?? bounds.height;
  bool get isMostlyBold =>
      boldRanges.fold(0, (length, range) => length + range.end - range.start) >=
      text.length * .75;

  List<Object> toJson() => [
    text,
    bounds.left,
    bounds.top,
    bounds.right,
    bounds.bottom,
    recognized,
    {
      if (fontSize != null) 'fontSize': fontSize,
      if (paragraphTag != null) 'paragraphTag': paragraphTag,
      if (headingLevel > 0) 'headingLevel': headingLevel,
      if (ocrParagraph != null) 'ocrParagraph': ocrParagraph,
      if (linkRanges.isNotEmpty)
        'links': [
          for (final link in linkRanges) [link.start, link.end, link.target],
        ],
      if (boldRanges.isNotEmpty)
        'boldRanges': [
          for (final range in boldRanges) [range.start, range.end],
        ],
    },
  ];

  static CompanionReflowLine fromJson(List<dynamic> row) {
    final style = row.length > 6 ? row[6] as Map : const {};
    return CompanionReflowLine(
      row[0] as String,
      Rect.fromLTRB(
        (row[1] as num).toDouble(),
        (row[2] as num).toDouble(),
        (row[3] as num).toDouble(),
        (row[4] as num).toDouble(),
      ),
      recognized: row[5] as bool,
      fontSize: (style['fontSize'] as num?)?.toDouble(),
      paragraphTag: style['paragraphTag'] as int?,
      headingLevel: style['headingLevel'] as int? ?? 0,
      ocrParagraph: style['ocrParagraph'] as String?,
      linkRanges: [
        for (final row in style['links'] as List? ?? const [])
          (start: row[0] as int, end: row[1] as int, target: row[2] as String),
      ],
      boldRanges: [
        for (final range in (style['boldRanges'] as List? ?? const []))
          (start: range[0] as int, end: range[1] as int),
      ],
    );
  }
}

/// Single owner for extraction and OCR. The same page request joins existing
/// work, and a foreground page can supersede background prefetch.
class CompanionPdfReflow {
  CompanionPdfReflow(BookSourceRecord source)
    : _source = source,
      _cacheKey = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                source.id,
                source.sourceVersionId,
                source.contentHash,
                source.filePath,
              ]),
            ),
          )
          .toString();

  /// Called after a PDF has been saved; opening the reader joins this same work.
  static Future<void> get pendingPreparations async {
    await Future.wait([
      for (final work in _preparingBooks.values)
        work.then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  /// Gives the visible PDF's pan or seek a head start on the native worker.
  static void deferBackgroundPreparation() => _deferPdfPreparation();

  static void prepareInBackground(BookSourceRecord source) {
    if (normalizeBookSourceFormat(source.format) != 'pdf') return;
    unawaited(
      CompanionPdfReflow(
        source,
      ).prepareBook().then<void>((_) {}, onError: (Object _) {}),
    );
  }

  final String _cacheKey;
  final BookSourceRecord _source;
  Future<PreparedCompanionPdf> prepareBook({
    int? loadedPageCount,
    bool? allowsCopying,
  }) => _prepareCompanionBook(
    this,
    loadedPageCount: loadedPageCount,
    allowsCopying: allowsCopying,
  );

  final _ocr = NativeFastOcrPlugin();
  final _results = <int, CompanionReflowPage>{};
  int _cachedImageBytes = 0;
  final _jobs = <int, _ReflowJob>{};
  int _sequence = 0;
  late final Future<Directory> _directory = () async {
    final cache = Pdfrx.cacheDirectoryPath;
    final root = cache == null
        ? await getTemporaryDirectory()
        : Directory(cache);
    return Directory(
      '${root.path}/companion-reflow-v4/$_cacheKey',
    ).create(recursive: true);
  }();

  CompanionReflowPage? cached(int page) => _results[page];

  Future<void> invalidatePage(int number) async {
    if (number < 1) return;
    final previous = _results.remove(number);
    _cachedImageBytes -= previous?.imageByteCount ?? 0;
    final directory = await _directory;
    for (final name in ['$number.json', 'complete.json']) {
      final file = File('${directory.path}/$name');
      if (await file.exists()) await file.delete();
    }
  }

  Future<CompanionReflowPage?> load(
    PdfViewerController viewer,
    int number, {
    bool prefetch = false,
  }) async {
    final existing = _results[number];
    if (existing != null) return existing;
    final active = _jobs[number];
    if (active != null) {
      if (!prefetch) active.prefetch = false;
      return active.result;
    }
    if (!prefetch) {
      for (final entry in _jobs.entries.toList()) {
        if (entry.value.prefetch) _cancel(entry.key, entry.value);
      }
    }
    final job = _ReflowJob(
      '$_cacheKey-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
      prefetch: prefetch,
    );
    _jobs[number] = job;
    job.result = _readOrExtract(viewer, number, job);
    try {
      return await job.result;
    } finally {
      if (identical(_jobs[number], job)) _jobs.remove(number);
    }
  }

  void cancel({int? exceptPage}) {
    for (final entry in _jobs.entries.toList()) {
      if (entry.key != exceptPage) _cancel(entry.key, entry.value);
    }
  }

  void _cancel(int number, _ReflowJob job) {
    _jobs.remove(number);
    job.cancelled = true;
    job.render?.cancel();
    if (job.recognizing) unawaited(_ocr.cancelRecognition(job.id));
  }

  Future<CompanionReflowPage?> _readOrExtract(
    PdfViewerController viewer,
    int number,
    _ReflowJob job,
  ) async {
    if (!viewer.isReady) return null;
    return viewer.useDocument<CompanionReflowPage?>(
      (document) => _readPage(document, number, job),
    );
  }

  Future<CompanionReflowPage?> _readPage(
    PdfDocument document,
    int number,
    _ReflowJob job,
  ) async {
    final preparing = job.preparingBook;
    if (document.permissions?.allowsCopying == false) {
      return CompanionReflowPage(number, const [], keepOriginal: true);
    }
    if (number < 1 || number > document.pages.length) return null;
    File? cacheFile;
    try {
      final directory = await _directory;
      cacheFile = File(
        '${directory.path}${Platform.pathSeparator}$number.json',
      );
      if (await cacheFile.exists()) {
        final cached = await _decodeCache(cacheFile, number);
        if (job.cancelled) return null;
        if (preparing || cached.pictures.isEmpty) {
          return preparing ? cached : _remember(cached);
        }
        final pictures = <CompanionPagePicture>[];
        for (final picture in cached.pictures) {
          pictures.add(
            picture.withBytes(await File(picture.cachePath!).readAsBytes()),
          );
        }
        return _remember(
          CompanionReflowPage(
            number,
            cached.lines,
            keepOriginal: cached.keepOriginal,
            links: cached.links,
            pictures: pictures,
            selectablePictures: cached.keepOriginal
                ? cached.selectablePictures
                : null,
          ),
        );
      }
    } on Object {
      // The cache is expendable. Always attempt to read the original file.
    }
    if (preparing) await _waitForPdfReadingIdle();
    if (job.cancelled) return null;
    final page = await document.pages[number - 1].waitForLoaded(
      timeout: const Duration(seconds: 8),
    );
    if (job.cancelled || page == null) return null;
    final original = page is _RecognizedPdfPage ? page.original : page;
    PdfPageText? structured;
    try {
      structured = await original.loadStructuredText();
    } on Exception {
      // Broken text maps still have a readable rendered page.
    }
    if (preparing) await _waitForPdfReadingIdle();
    if (job.cancelled) return null;
    var annotations = const <PdfLink>[];
    try {
      annotations = await original.loadLinks(enableAutoLinkDetection: false);
    } on Exception {
      /* Optional PDF annotations. */
    }
    final links = <CompanionPdfLink>[];
    for (final link in annotations) {
      final pageNumber = link.dest?.pageNumber;
      final uri = link.url;
      final target =
          pageNumber != null &&
              pageNumber >= 1 &&
              pageNumber <= document.pages.length
          ? 'pdf-page:$pageNumber'
          : uri != null &&
                (uri.scheme == 'https' || uri.scheme == 'http') &&
                uri.host.isNotEmpty &&
                uri.userInfo.isEmpty
          ? uri.toString()
          : null;
      if (target == null) continue;
      for (final rect in link.rects) {
        final box = rect.toRect(page: page);
        links.add((
          bounds: Rect.fromLTRB(
            box.left / page.width,
            box.top / page.height,
            box.right / page.width,
            box.bottom / page.height,
          ),
          target: target,
        ));
      }
    }
    if (preparing && structured != null) await _waitForPdfReadingIdle();
    final lines = structured == null
        ? <CompanionReflowLine>[]
        : _nativeLines(
            page,
            structured,
            await _loadPdfGlyphStyles(original, structured.fullText),
            links,
          );
    if (job.cancelled) return null;
    const whole = Rect.fromLTWH(0, 0, 1, 1);
    final canRecognize = Platform.isAndroid || Platform.isIOS;
    var keepOriginal =
        structured?.fragments.any(
          (fragment) =>
              fragment.direction == PdfTextDirection.vrtl ||
              fragment.direction == PdfTextDirection.rtl,
        ) ??
        false;
    var persistResult = true;
    final corruptGlyphs = RegExp(r'[\u0000\ufffd-\uffff\ue000-\uf8ff]');
    if (lines.any((line) => corruptGlyphs.hasMatch(line.text))) {
      // Encoding defects can affect part of a page. Retain valid native
      // lines, and keep the rest of the printed area available as pixels.
      lines.removeWhere((line) => corruptGlyphs.hasMatch(line.text));
    }
    if (preparing) await _waitForPdfReadingIdle();
    final embedded = await _embeddedPdfImages(original);
    var layout = await _pictureRegions(page, lines, embedded, job);
    if (canRecognize &&
        !job.cancelled &&
        !keepOriginal &&
        layout.regions.isNotEmpty) {
      final captions = lines.where(
        (line) => CompanionReflowPage._caption.hasMatch(line.text),
      );
      final missing = layout.regions
          .where((region) => region.columns == 0)
          .map((region) => region.bounds)
          .where(
            (r) =>
                r.width >= .35 &&
                r.height >= .075 &&
                !captions.any(
                  (line) =>
                      (line.bounds.top - r.bottom).abs() < .06 ||
                      (line.bounds.bottom - r.top).abs() < .04,
                ),
          )
          .toList();
      var added = false;
      try {
        for (final region in missing) {
          if (job.cancelled) return null;
          final recognized = await _recognize(page, job, region);
          if (!recognized.reliable ||
              (region != whole &&
                  recognized.lines
                          .where((line) => line.text.trim().length >= 6)
                          .length <
                      2)) {
            continue;
          }
          for (final line in recognized.lines) {
            if (!lines.any((native) => _duplicates(native, line))) {
              lines.add(line);
              added = true;
            }
          }
        }
        if (added) {
          lines.sort(_readingOrder);
          layout = await _pictureRegions(page, lines, embedded, job);
        }
      } on FastOcrUnavailableException {
        // Preserve the missing region as a picture, retry after models update.
        persistResult = false;
      } on FastOcrCancelledException {
        return null;
      } on Exception {
        // A transient OCR or raster I/O failure must not hide the source.
        persistResult = false;
      }
    }
    if (job.cancelled) return null;
    if (preparing && !persistResult) {
      throw const FormatException('文字识别暂不可用');
    }
    lines.sort(_readingOrder);
    final objects = layout.regions
        .where((region) => region.bounds != whole)
        .toList(growable: false);
    keepOriginal =
        keepOriginal ||
        !persistResult ||
        layout.keepOriginal ||
        lines.isEmpty ||
        _isComplex(
          lines
              .where(
                (line) => !objects.any(
                  (region) => region.bounds.contains(line.bounds.center),
                ),
              )
              .toList(),
        );
    final pictures = <CompanionPagePicture>[];
    final selectable = <CompanionPagePicture>[];
    for (final (index, region) in objects.indexed) {
      if (job.cancelled) return null;
      final picture = _pictureMetadata(page, region, number, '$index', lines);
      selectable.add(picture);
      if (!keepOriginal) {
        final bytes = await _picturePng(page, job, 1560, region.bounds);
        if (bytes == null) {
          if (job.cancelled) return null;
          keepOriginal = true;
          pictures.clear();
        } else {
          pictures.add(picture.withBytes(bytes));
        }
      }
    }
    if (keepOriginal) {
      final bytes = await _picturePng(page, job, 1560, whole);
      if (job.cancelled) return null;
      if (bytes == null) return null;
      pictures.add(
        _pictureMetadata(
          page,
          const _PdfPictureRegion(whole),
          number,
          'page',
          lines,
        ).withBytes(bytes),
      );
    }
    if (job.cancelled) return null;
    final result = CompanionReflowPage(
      number,
      List.unmodifiable(lines),
      keepOriginal: keepOriginal,
      links: links,
      pictures: List.unmodifiable(pictures),
      selectablePictures: keepOriginal ? List.unmodifiable(selectable) : null,
    );
    if (cacheFile != null && persistResult) {
      try {
        final stored = await _saveCache(cacheFile, result, job.id);
        return preparing ? stored : _remember(result);
      } on FileSystemException {
        if (preparing) rethrow;
      }
    }
    if (preparing) throw const FileSystemException('无法写入电子书缓存');
    return persistResult ? _remember(result) : result;
  }

  CompanionReflowPage _remember(CompanionReflowPage result) {
    final old = _results.remove(result.number);
    _cachedImageBytes -= old?.imageByteCount ?? 0;
    final bytes = result.imageByteCount;
    while (_results.isNotEmpty &&
        (_results.length >= 24 ||
            _cachedImageBytes + bytes > 32 * 1024 * 1024)) {
      _cachedImageBytes -= _results.remove(_results.keys.first)!.imageByteCount;
    }
    _cachedImageBytes += bytes;
    return _results[result.number] = result;
  }

  static Future<CompanionReflowPage> _decodeCache(File file, int number) async {
    final encoded = await file.readAsString();
    final path = file.path;
    return encoded.length > 64000
        ? _decodeLargeCache(encoded, path, number)
        : _decodePageCache(encoded, path, number);
  }

  static Future<CompanionReflowPage> _decodeLargeCache(
    String encoded,
    String path,
    int number,
  ) => Isolate.run(() => _decodePageCache(encoded, path, number));

  static Future<CompanionReflowPage> _decodePageCache(
    String encoded,
    String path,
    int number,
  ) async {
    final data = jsonDecode(encoded) as Map;
    final pictures = <CompanionPagePicture>[];
    for (final (index, item) in (data['pictures'] as List).indexed) {
      final image = File('$path.$index.png');
      final stat = await image.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != item['length']) {
        throw const FormatException('电子书图片缓存不完整');
      }
      pictures.add(
        CompanionPagePicture.fromJson(
          item as Map<String, dynamic>,
          cachePath: image.path,
        ),
      );
    }
    return CompanionReflowPage(
      number,
      (data['lines'] as List)
          .map((row) => CompanionReflowLine.fromJson(row as List))
          .toList(),
      keepOriginal: data['keepOriginal'] == true,
      links: [
        for (final row in data['links'] as List? ?? const [])
          (
            bounds: Rect.fromLTRB(
              (row[0] as num).toDouble(),
              (row[1] as num).toDouble(),
              (row[2] as num).toDouble(),
              (row[3] as num).toDouble(),
            ),
            target: row[4] as String,
          ),
      ],
      pictures: pictures,
      selectablePictures: (data['selectablePictures'] as List?)
          ?.map((e) => CompanionPagePicture.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<CompanionReflowPage> _saveCache(
    File file,
    CompanionReflowPage result,
    String id,
  ) async {
    final pictures = <CompanionPagePicture>[];
    final descriptors = <Map<String, dynamic>>[];
    for (final (index, picture) in result.pictures.indexed) {
      final image = File('${file.path}.$index.png');
      final bytes = picture.asset.bytes;
      final staging = File('${image.path}.$id.tmp');
      try {
        await staging.writeAsBytes(bytes);
        await staging.rename(image.path);
      } finally {
        if (await staging.exists()) await staging.delete();
      }
      final stored = picture.withBytes(Uint8List(0), cachePath: image.path);
      pictures.add(stored);
      descriptors.add({...stored.toJson(), 'length': bytes.length});
    }
    final staging = File('${file.path}.$id.tmp');
    try {
      await staging.writeAsString(
        jsonEncode({
          'keepOriginal': result.keepOriginal,
          'links': [
            for (final l in result.links)
              [
                l.bounds.left,
                l.bounds.top,
                l.bounds.right,
                l.bounds.bottom,
                l.target,
              ],
          ],
          'pictures': descriptors,
          if (result.keepOriginal)
            'selectablePictures': result.selectablePictures
                .map((p) => p.toJson())
                .toList(),
          'lines': result.lines.map((line) => line.toJson()).toList(),
        }),
      );
      await staging.rename(file.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
    return CompanionReflowPage(
      result.number,
      result.lines,
      keepOriginal: result.keepOriginal,
      links: result.links,
      pictures: pictures,
      selectablePictures: result.keepOriginal
          ? result.selectablePictures
          : null,
    );
  }

  static int _readingOrder(CompanionReflowLine a, CompanionReflowLine b) {
    final top = a.bounds.top.compareTo(b.bounds.top);
    return top == 0 ? a.bounds.left.compareTo(b.bounds.left) : top;
  }

  // PDFium's word fragments retain their character spans. Build rows by
  // baseline and order fragments within each row, keeping large gutters intact.
  static List<CompanionReflowLine> _nativeLines(
    PdfPage page,
    PdfPageText raw,
    List<_PdfGlyphStyle?>? styles,
    List<CompanionPdfLink> links,
  ) {
    final words = <({PdfPageTextFragment run, Rect box})>[];
    for (final fragment in raw.fragments) {
      if (fragment.text.trim().isEmpty || fragment.bounds.isEmpty) continue;
      final box = fragment.bounds.toRect(page: page);
      words.add((run: fragment, box: box));
    }
    words.sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));
    final result = <CompanionReflowLine>[];
    for (var start = 0; start < words.length;) {
      final first = words[start];
      var end = start + 1;
      while (end < words.length &&
          (words[end].box.center.dy - first.box.center.dy).abs() <
              math.min(first.box.height, words[end].box.height) * .45) {
        end++;
      }
      final row = words.sublist(start, end)
        ..sort((a, b) => a.box.left.compareTo(b.box.left));
      Rect? box;
      var text = StringBuffer();
      final sizes = <double>[];
      final tags = <_PdfTextTag, int>{};
      final bold = <DocumentBoldRange>[];
      final glyphLinks = <DocumentLinkRange>[];
      var styledGlyphs = 0;
      PdfPageTextFragment? previous;
      void finish() {
        if (box == null || text.isEmpty) return;
        _PdfTextTag? tag;
        for (final entry in tags.entries) {
          if (entry.value * 4 >= styledGlyphs * 3) {
            tag = entry.key;
            break;
          }
        }
        result.add(
          CompanionReflowLine(
            text.toString().trim(),
            Rect.fromLTRB(
              box.left / page.width,
              box.top / page.height,
              box.right / page.width,
              box.bottom / page.height,
            ),
            fontSize: CompanionReflowPage._median(sizes),
            paragraphTag: tag?.id,
            headingLevel: tag?.heading ?? 0,
            boldRanges: List.unmodifiable(bold),
            linkRanges: List.unmodifiable(glyphLinks),
          ),
        );
      }

      for (final word in row) {
        if (box != null &&
            word.box.left - box.right >
                math.max(page.width * .032, word.box.height * 1.7)) {
          finish();
          box = null;
          previous = null;
          text = StringBuffer();
          sizes.clear();
          tags.clear();
          bold.clear();
          glyphLinks.clear();
          styledGlyphs = 0;
        }
        if (previous != null) {
          final gap = word.run.index >= previous.end
              ? raw.fullText.substring(previous.end, word.run.index)
              : '';
          if (gap.isNotEmpty && gap.trim().isEmpty) {
            text.write(
              gap.contains('\n') || gap.contains('\r')
                  ? _ReflowParagraph.separator(
                      previous.text.trim(),
                      word.run.text.trim(),
                    )
                  : gap,
            );
          } else if (box != null &&
              word.box.left - box.right > word.box.height * .18) {
            text.write(
              _ReflowParagraph.separator(
                previous.text.trim(),
                word.run.text.trim(),
              ),
            );
          }
        }
        box = box?.expandToInclude(word.box) ?? word.box;
        final fragment = word.run.text;
        final value = fragment.trim();
        final sourceStart =
            word.run.index + fragment.length - fragment.trimLeft().length;
        if (links.isNotEmpty) {
          for (
            var i = 0;
            i < value.length && sourceStart + i < raw.charRects.length;
            i++
          ) {
            final center = raw.charRects[sourceStart + i]
                .toRect(page: page)
                .center;
            final point = Offset(
              center.dx / page.width,
              center.dy / page.height,
            );
            final hit = links
                .where((l) => l.bounds.contains(point))
                .firstOrNull;
            if (hit == null) continue;
            final start = text.length + i;
            final previous = glyphLinks.lastOrNull;
            if (previous != null &&
                previous.target == hit.target &&
                previous.end == start) {
              glyphLinks[glyphLinks.length - 1] = (
                start: previous.start,
                end: start + 1,
                target: hit.target,
              );
            } else {
              glyphLinks.add((
                start: start,
                end: start + 1,
                target: hit.target,
              ));
            }
          }
        }
        if (styles != null) {
          for (var i = 0; i < value.length; i++) {
            final style = styles[sourceStart + i];
            if (style == null) continue;
            styledGlyphs++;
            if (style.size > 0) sizes.add(style.size);
            final tag = style.tag;
            if (tag != null) {
              tags.update(tag, (count) => count + 1, ifAbsent: () => 1);
            }
            if (style.bold) {
              final start = text.length + i;
              if (bold.isNotEmpty && bold.last.end == start) {
                final previous = bold.removeLast();
                bold.add((start: previous.start, end: start + 1));
              } else {
                bold.add((start: start, end: start + 1));
              }
            }
          }
        }
        text.write(value);
        previous = word.run;
      }
      finish();
      start = end;
    }
    return result..sort(_readingOrder);
  }

  // Recover diagrams made from paths as well as embedded bitmaps. Sparse thin
  // lines may be all that connects a tree, so also use an adjacent caption to
  // enclose the original figure, including any native text inside its boxes.
  Future<({List<_PdfPictureRegion> regions, bool keepOriginal})>
  _pictureRegions(
    PdfPage page,
    List<CompanionReflowLine> lines,
    List<Rect> embedded,
    _ReflowJob job,
  ) async {
    const whole = _PdfPictureRegion(_pdfWholePage);
    final image = await _render(page, job, 800);
    if (image == null) return (regions: [whole], keepOriginal: true);
    late final ({List<Rect> bands, List<_PdfPictureRegion> objects}) scan;
    try {
      scan = await _scanPageObjects(
        TransferableTypedData.fromList([image.pixels]),
        image.width,
        image.height,
        lines,
        embedded,
      );
    } finally {
      image.dispose();
    }
    if (job.cancelled) {
      return (regions: const <_PdfPictureRegion>[], keepOriginal: false);
    }
    final bands = scan.bands;
    final regions = <_PdfPictureRegion>[...scan.objects];
    final rasterRegions = bands
        .where(
          (b) =>
              (b.height >= .016 && b.width >= .04) ||
              (b.width >= .20 && b.height >= .004),
        )
        .toList();
    if (lines.isEmpty ||
        rasterRegions.any((r) => r.height > .84 && r.width > .85)) {
      return (regions: [whole, ...regions], keepOriginal: true);
    }
    for (var i = 0; i < lines.length; i++) {
      final caption = lines[i];
      if (!CompanionReflowPage._caption.hasMatch(caption.text)) continue;
      if (_tableCaption.hasMatch(caption.text)) continue;
      if (regions.any((region) => _isBesideCaption(region.bounds, caption))) {
        continue;
      }
      if (i == 0) continue;
      final preceding = lines
          .take(i)
          .where(
            (line) =>
                line.bounds.width > .4 &&
                line.text.length > 12 &&
                line.bounds.bottom <= caption.bounds.top,
          );
      final top = preceding.isEmpty ? 0.0 : preceding.last.bounds.bottom;
      final bottom = caption.bounds.top;
      if (bottom - top < .055 || bottom - top > .6) continue;
      final nearby = bands
          .where((b) => b.center.dy > top && b.center.dy < bottom)
          .toList();
      if (nearby.isEmpty) continue;
      rasterRegions.add(nearby.reduce((a, b) => a.expandToInclude(b)));
    }
    rasterRegions.sort((a, b) => a.top.compareTo(b.top));
    final merged = <Rect>[];
    for (final region in rasterRegions) {
      // Keep every native word whose glyphs touch this raster band on a single
      // side of the boundary. It either remains readable text or is in the crop.
      var box = region.inflate(.004).intersect(_pdfWholePage);
      for (final line in lines) {
        if (line.bounds.overlaps(box) &&
            !CompanionReflowPage._caption.hasMatch(line.text)) {
          box = box.expandToInclude(line.bounds);
        }
      }
      box = box.inflate(.002).intersect(_pdfWholePage);
      if (merged.isNotEmpty && merged.last.overlaps(box)) {
        merged.last = merged.last.expandToInclude(box);
      } else {
        merged.add(box);
      }
    }
    regions.addAll(merged.map(_PdfPictureRegion.new));
    regions.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final uncertain = lines.any(
      (line) =>
          CompanionReflowPage._caption.hasMatch(line.text) &&
          !regions.any(
            (region) =>
                (!_tableCaption.hasMatch(line.text) || region.columns > 0) &&
                _isBesideCaption(region.bounds, line),
          ),
    );
    final sideNotes = regions.any(
      (region) =>
          lines.any((line) => _needsOriginalLayout(region.bounds, line)),
    );
    return (regions: regions, keepOriginal: uncertain || sideNotes);
  }

  static List<Rect> _scanBands(
    Uint8List pixels,
    int width,
    int height,
    List<Rect> excluded,
  ) {
    final bands = <Rect>[];
    for (var y = 0; y < height; y++) {
      final dy = (y + .5) / height;
      final covered = excluded
          .where((bounds) => dy >= bounds.top && dy <= bounds.bottom)
          .toList();
      var left = width, right = -1, count = 0;
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        if (pixels[offset] > 227 &&
            pixels[offset + 1] > 227 &&
            pixels[offset + 2] > 227) {
          continue;
        }
        final dx = (x + .5) / width;
        if (covered.any((bounds) => dx >= bounds.left && dx <= bounds.right)) {
          continue;
        }
        left = math.min(left, x);
        right = x;
        count++;
      }
      if (count == 0) continue;
      final row = Rect.fromLTRB(
        left / width,
        y / height,
        (right + 1) / width,
        (y + 1) / height,
      );
      if (bands.isNotEmpty && row.top - bands.last.bottom < .023) {
        bands.last = bands.last.expandToInclude(row);
      } else {
        bands.add(row);
      }
    }
    return bands;
  }

  /// Rasterizes the complete original object independently of viewer zoom.
  Future<Uint8List?> renderPicture(
    PdfDocument document,
    int pageNumber,
    CompanionPagePicture picture, {
    bool forExport = false,
  }) async {
    if (document.permissions?.allowsCopying == false ||
        pageNumber < 1 ||
        pageNumber > document.pages.length ||
        picture.asset.sourceLocator != 'page:$pageNumber') {
      return null;
    }
    final page = await document.pages[pageNumber - 1].waitForLoaded(
      timeout: const Duration(seconds: 8),
    );
    if (page == null) return null;
    final bounds = picture.bounds.intersect(_pdfWholePage);
    if (bounds.isEmpty) return null;
    final pageEdge = math.max(page.width, page.height);
    final objectEdge = math.max(
      bounds.width * page.width,
      bounds.height * page.height,
    );
    final target = forExport ? 3200.0 : 2304.0;
    return _picturePng(
      page,
      _ReflowJob('picture-preview', prefetch: false),
      math.min(8192.0, target * pageEdge / objectEdge),
      bounds,
    );
  }

  static CompanionPagePicture _pictureMetadata(
    PdfPage page,
    _PdfPictureRegion region,
    int number,
    String index,
    List<CompanionReflowLine> lines,
  ) {
    final bounds = region.bounds;
    final isTable = region.columns > 0;
    final cellHeights = [
      for (final line in lines)
        if (bounds.contains(line.bounds.center) &&
            !CompanionReflowPage._caption.hasMatch(line.text) &&
            line.bounds.height > .003)
          line.bounds.height,
    ]..sort();
    final tableWidth = !isTable
        ? null
        : cellHeights.isEmpty
        ? region.columns * 72.0
        : math.max(
            region.columns * 56.0,
            13 *
                page.width *
                bounds.width /
                (page.height * cellHeights[cellHeights.length ~/ 2]),
          );
    return CompanionPagePicture(
      bounds,
      page.width * bounds.width / (page.height * bounds.height),
      XiaoqiDocumentAsset(
        id: 'pdf-page-$number-image-$index',
        mimeType: 'image/png',
        bytes: const [],
        altText: bounds == _pdfWholePage
            ? '第 $number 页原貌'
            : isTable
            ? '第 $number 页表格'
            : '第 $number 页原图',
        sourceLocator: 'page:$number',
      ),
      minimumReadableWidth: tableWidth,
    );
  }

  Future<Uint8List?> _picturePng(
    PdfPage page,
    _ReflowJob job,
    double maxEdge,
    Rect region,
  ) async {
    final raster = await _render(page, job, maxEdge, region: region);
    if (raster == null) return null;
    try {
      if (job.cancelled) return null;
      final bitmap = await raster.createImage();
      try {
        final png = await bitmap.toByteData(format: ImageByteFormat.png);
        if (png == null || job.cancelled) return null;
        return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } finally {
        bitmap.dispose();
      }
    } finally {
      raster.dispose();
    }
  }

  Future<PdfImage?> _render(
    PdfPage page,
    _ReflowJob job,
    double maxEdge, {
    Rect region = const Rect.fromLTWH(0, 0, 1, 1),
  }) async {
    if (job.preparingBook) await _waitForPdfReadingIdle();
    if (job.cancelled) return null;
    final scale = maxEdge / math.max(page.width, page.height);
    final token = page.createCancellationToken();
    job.render = token;
    final width = math.max(1.0, (page.width * scale).roundToDouble());
    final height = math.max(1.0, (page.height * scale).roundToDouble());
    final x = (width * region.left).floor();
    final y = (height * region.top).floor();
    return page.render(
      fullWidth: width,
      fullHeight: height,
      x: x,
      y: y,
      width: math.max(1, (width * region.right).ceil() - x),
      height: math.max(1, (height * region.bottom).ceil() - y),
      backgroundColor: 0xffffffff,
      annotationRenderingMode: PdfAnnotationRenderingMode.none,
      cancellationToken: token,
    );
  }

  Future<({List<CompanionReflowLine> lines, bool reliable})> _recognize(
    PdfPage page,
    _ReflowJob job,
    Rect region,
  ) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}companion-${job.id}.png',
    );
    final raster = await _render(page, job, 2400, region: region);
    const empty = (lines: <CompanionReflowLine>[], reliable: false);
    if (raster == null) return empty;
    try {
      if (job.cancelled) return empty;
      final image = await raster.createImage();
      try {
        final png = await image.toByteData(format: ImageByteFormat.png);
        if (job.cancelled || png == null) return empty;
        await file.writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
      if (job.preparingBook) await _waitForPdfReadingIdle();
      if (job.cancelled) return empty;
      job.recognizing = true;
      final result = await _ocr.recognizePage(file.path, jobId: job.id);
      if (job.cancelled || result.imageWidth < 1 || result.imageHeight < 1) {
        return empty;
      }
      final lowConfidence = result.lines
          .where((line) => line.confidence < .70)
          .length;
      final paragraphs = {
        for (final (index, block) in result.blocks.indexed)
          for (final line in block.lines)
            line: '${region.top}:${region.left}:$index',
      };
      return (
        reliable:
            result.lines.isNotEmpty &&
            lowConfidence * 4 <= result.lines.length &&
            !result.lines.any(
              (line) => line.text.trim().isNotEmpty && line.confidence < .50,
            ),
        lines: [
          for (final line in result.lines)
            if (line.text.isNotEmpty &&
                line.width > 0 &&
                line.height > 0 &&
                line.confidence >= .50)
              CompanionReflowLine(
                line.text,
                Rect.fromLTRB(
                  region.left + region.width * line.left / result.imageWidth,
                  region.top + region.height * line.top / result.imageHeight,
                  region.left + region.width * line.right / result.imageWidth,
                  region.top + region.height * line.bottom / result.imageHeight,
                ),
                recognized: true,
                ocrParagraph: paragraphs[line],
              ),
        ],
      );
    } finally {
      job.recognizing = false;
      raster.dispose();
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Temporary rasters are managed by the operating system.
      }
    }
  }

  static bool _duplicates(CompanionReflowLine native, CompanionReflowLine ocr) {
    final overlap = native.bounds.intersect(ocr.bounds);
    if (overlap.isEmpty) return false;
    final smaller = math.min(
      native.bounds.width * native.bounds.height,
      ocr.bounds.width * ocr.bounds.height,
    );
    return overlap.width * overlap.height > smaller * .55 ||
        native.text.replaceAll(' ', '') == ocr.text.replaceAll(' ', '');
  }

  static bool _isComplex(List<CompanionReflowLine> lines) {
    var parallel = 0;
    for (var index = 1; index < lines.length; index++) {
      final first = lines[index - 1].bounds;
      final second = lines[index].bounds;
      if ((first.center.dy - second.center.dy).abs() <
              math.min(first.height, second.height) * .65 &&
          (first.right < second.left - .02 ||
              second.right < first.left - .02)) {
        parallel++;
      }
    }
    return parallel >= 3;
  }
}

class _ReflowJob {
  _ReflowJob(this.id, {required this.prefetch, this.preparingBook = false});

  final String id;
  final bool preparingBook;
  bool prefetch;
  bool cancelled = false;
  bool recognizing = false;
  PdfPageRenderCancellationToken? render;
  late final Future<CompanionReflowPage?> result;
}

/// Gives the existing PDF viewer a text layer for recognized page regions
/// while the native document continues to own rendering and file permissions.
class CompanionSelectionDocument extends PdfDocument {
  CompanionSelectionDocument(this.original)
    : super(sourceName: original.sourceName) {
    _subscription = original.events.listen(
      _events.add,
      onError: _events.addError,
    );
  }

  final PdfDocument original;
  final _events = StreamController<PdfDocumentEvent>.broadcast(sync: true);
  late final StreamSubscription<PdfDocumentEvent> _subscription;
  final _recognized = <int, _RecognizedPdfPage>{};
  List<PdfPage>? _basePages;
  List<PdfPage> _pages = const [];

  void install(CompanionReflowPage reflow) {
    if (permissions?.allowsCopying == false ||
        _recognized.containsKey(reflow.number) ||
        !reflow.lines.any((line) => line.recognized)) {
      return;
    }
    final page = original.pages[reflow.number - 1];
    final replacement = _RecognizedPdfPage(page, reflow);
    _recognized[reflow.number] = replacement;
    _basePages = null;
    _events.add(
      PdfDocumentPageStatusChangedEvent(
        this,
        changes: {
          reflow.number: PdfPageStatusChange.modified(page: replacement),
        },
      ),
    );
  }

  @override
  List<PdfPage> get pages {
    final originalPages = original.pages;
    if (_recognized.isEmpty) return originalPages;
    if (!identical(_basePages, originalPages)) {
      _basePages = originalPages;
      _pages = List.unmodifiable(
        originalPages.map((page) {
          final recognized = _recognized[page.pageNumber];
          return recognized != null && identical(recognized.original, page)
              ? recognized
              : page;
        }),
      );
    }
    return _pages;
  }

  @override
  set pages(List<PdfPage> value) => original.pages = [
    for (final page in value) page is _RecognizedPdfPage ? page.original : page,
  ];

  @override
  PdfPermissions? get permissions => original.permissions;

  @override
  bool get isEncrypted => original.isEncrypted;

  @override
  Stream<PdfDocumentEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    await Future.wait<void>([
      _subscription.cancel(),
      _events.close(),
      original.dispose(),
    ]);
  }

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) => original.loadPagesProgressively(
    onPageLoadProgress: onPageLoadProgress,
    data: data,
    loadUnitDuration: loadUnitDuration > _pdfMetadataSlice
        ? _pdfMetadataSlice
        : loadUnitDuration,
  );

  @override
  Future<List<PdfOutlineNode>> loadOutline() => original.loadOutline();

  @override
  bool isIdenticalDocumentHandle(Object? other) =>
      original.isIdenticalDocumentHandle(
        other is CompanionSelectionDocument ? other.original : other,
      );

  @override
  Future<bool> assemble() => original.assemble();

  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) => original.encodePdf(
    incremental: incremental,
    removeSecurity: removeSecurity,
  );

  @override
  Future<T> useNativeDocumentHandle<T>(
    FutureOr<T> Function(int nativeDocumentHandle) task,
  ) => original.useNativeDocumentHandle(task);

  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) =>
      original.reloadPages(pageNumbersToReload: pageNumbersToReload);
}

class _RecognizedPdfPage implements PdfPage {
  _RecognizedPdfPage(this.original, this.reflow);

  final PdfPage original;
  final CompanionReflowPage reflow;

  @override
  PdfDocument get document => original.document;
  @override
  int get pageNumber => original.pageNumber;
  @override
  double get width => original.width;
  @override
  double get height => original.height;
  @override
  PdfPageRotation get rotation => original.rotation;
  @override
  bool get isLoaded => original.isLoaded;

  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      original.createCancellationToken();

  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) => original.loadLinks(
    compact: compact,
    enableAutoLinkDetection: enableAutoLinkDetection,
  );

  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) => original.render(
    x: x,
    y: y,
    width: width,
    height: height,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    backgroundColor: backgroundColor,
    rotationOverride: rotationOverride,
    annotationRenderingMode: annotationRenderingMode,
    flags: flags,
    cancellationToken: cancellationToken,
  );

  @override
  Future<PdfPageRawText?> loadText() async {
    final raw = await original.loadText();
    final text = StringBuffer();
    final boxes = <PdfRect>[];
    for (final line in reflow.lines) {
      final bounds = line.bounds;
      final match = line.recognized || raw == null
          ? -1
          : raw.fullText.indexOf(line.text);
      final count = line.text.length;
      text.writeln(line.text);
      for (var index = 0; index < count; index++) {
        if (match >= 0 && match + index < raw!.charRects.length) {
          boxes.add(raw.charRects[match + index]);
          continue;
        }
        boxes.add(
          Rect.fromLTRB(
            width * (bounds.left + bounds.width * index / count),
            height * bounds.top,
            width * (bounds.left + bounds.width * (index + 1) / count),
            height * bounds.bottom,
          ).toPdfRect(page: original),
        );
      }
      boxes.add(PdfRect.empty);
    }
    return PdfPageRawText(text.toString(), boxes);
  }
}
