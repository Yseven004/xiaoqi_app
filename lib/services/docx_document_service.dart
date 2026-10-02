import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/ocr_layout.dart';
import '../models/xiaoqi_document.dart';
import 'document_archive_safety.dart';

/// Reads the stable, text-oriented subset of WordprocessingML.
///
/// The original OOXML package remains the source of truth. This parser only
/// derives a navigable document and never executes macros, relationships, or
/// external resources.
class DocxDocumentService {
  const DocxDocumentService();

  static const maxCompressedBytes = 50 * 1024 * 1024;
  static const maxExpandedBytes = 250 * 1024 * 1024;
  static const maxEntries = 5000;

  Future<XiaoqiDocument> parseFile(String filePath) async {
    final file = File(filePath);
    final length = await file.length();
    if (length > maxCompressedBytes) {
      throw const FormatException('DOCX 文件过大，暂不支持整理');
    }
    return parseBytes(await file.readAsBytes());
  }

  XiaoqiDocument parseBytes(List<int> bytes) {
    if (bytes.length > maxCompressedBytes) {
      throw const FormatException('DOCX 文件过大，暂不支持整理');
    }
    DocumentArchiveSafety.preflightZip(
      bytes,
      maxEntries: maxEntries,
      maxExpandedBytes: maxExpandedBytes,
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length > maxEntries) {
      throw const FormatException('DOCX 包含过多文件，无法安全整理');
    }

    var expandedBytes = 0;
    final entries = <String, ArchiveFile>{};
    for (final entry in archive) {
      final path = _normalizePath(entry.name);
      if (_isUnsafePath(entry.name)) {
        throw const FormatException('DOCX 包含不安全的文件路径');
      }
      if (!entry.isFile) continue;
      expandedBytes += entry.content.length;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('DOCX 解压后体积过大，无法安全整理');
      }
      entries[path] = entry;
    }

    final documentEntry = entries['word/document.xml'];
    if (documentEntry == null) {
      throw const FormatException('DOCX 缺少主文档内容');
    }

    final core = _parseOptionalXml(entries['docprops/core.xml']);
    final title = _firstText(core, 'title') ?? '';
    final author = _firstText(core, 'creator') ?? '';
    final language =
        _firstText(core, 'language') ??
        _firstAttributeValue(core, 'language', 'val');
    final styles = _parseStyles(_parseOptionalXml(entries['word/styles.xml']));
    final relationships = _parseRelationships(
      _parseOptionalXml(entries['word/_rels/document.xml.rels']),
    );
    final main = XmlDocument.parse(_decode(documentEntry.content));
    final body = _firstElement(main, 'body');
    if (body == null) {
      throw const FormatException('DOCX 主文档缺少正文');
    }

    final assets = <XiaoqiDocumentAsset>[];
    final blocks = <XiaoqiDocumentBlock>[];
    var blockIndex = 0;
    var tableIndex = 0;
    var originalPageNumber = 1;
    for (final child in body.children.whereType<XmlElement>()) {
      if (child.localName == 'p') {
        final pageBreakCount = _paragraphPageBreakCount(child);
        final paragraphBlocks = _paragraphBlocks(
          child,
          styles,
          relationships,
          entries,
          assets,
          blockIndex++,
          firstPageBreakLabel: originalPageNumber + 1,
        );
        blocks.addAll(paragraphBlocks);
        originalPageNumber += pageBreakCount;
        continue;
      }
      if (child.localName == 'tbl') {
        final table = _tableBlock(child, tableIndex++, blockIndex++);
        if (table != null) blocks.add(table);
      }
    }

    final chapters = _chapters(
      blocks,
      title: title,
      sourceLocator: 'word/document.xml',
    );
    return XiaoqiDocument(
      format: 'docx',
      title: title,
      author: author,
      language: language,
      chapters: chapters,
      assets: List.unmodifiable(assets),
      originalPageCount: originalPageNumber == 1 ? null : originalPageNumber,
    );
  }

  List<XiaoqiDocumentBlock> _paragraphBlocks(
    XmlElement paragraph,
    Map<String, int> styles,
    Map<String, _Relationship> relationships,
    Map<String, ArchiveFile> entries,
    List<XiaoqiDocumentAsset> assets,
    int index, {
    required int firstPageBreakLabel,
  }) {
    final pPr = _directChild(paragraph, 'pPr');
    final styleId = _directChild(pPr, 'pStyle')?.getAttribute('val') ?? '';
    final outline = int.tryParse(
      _directChild(pPr, 'outlineLvl')?.getAttribute('val') ?? '',
    );
    final level = outline == null ? (styles[styleId] ?? 0) : outline + 1;
    final isList = _directChild(pPr, 'numPr') != null;
    final text = _paragraphText(paragraph);
    final hasMath = paragraph.descendants.whereType<XmlElement>().any(
      (element) =>
          element.localName == 'oMath' || element.localName == 'oMathPara',
    );
    final hasChart = paragraph.descendants.whereType<XmlElement>().any(
      (element) => element.localName == 'chart',
    );
    final hasSymbol = paragraph.descendants.whereType<XmlElement>().any(
      (element) => element.localName == 'sym',
    );
    var symbolFont = '';
    var symbolChar = '';
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      if (element.localName != 'sym') continue;
      symbolFont = _attributeByLocalName(element, 'font') ?? '';
      symbolChar = _attributeByLocalName(element, 'char') ?? '';
      break;
    }
    final paraId = _attributeByLocalName(paragraph, 'paraId');
    final locator = 'word/document.xml#${paraId ?? 'p-$index'}';
    final kind = hasMath
        ? 'math'
        : hasChart
        ? 'chart'
        : level > 0
        ? 'heading'
        : isList
        ? 'list_item'
        : 'paragraph';
    final attributes = <String, String>{
      if (hasMath) 'objectSource': 'wordprocessingml_omml',
      if (hasChart) 'objectSource': 'drawingml_chart',
      if (hasMath) 'latex': _ommlToLatex(paragraph),
      if (hasSymbol) 'symbolSource': 'wordprocessingml_symbol',
      if (symbolFont.isNotEmpty) 'symbolFont': symbolFont,
      if (symbolChar.isNotEmpty) 'symbolChar': symbolChar,
      if (hasChart)
        'figure_elements': jsonEncode(
          _chartFigureElements(paragraph, relationships, entries),
        ),
    };
    final imageBlocks = <XiaoqiDocumentBlock>[];
    for (final blip in paragraph.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'blip',
    )) {
      final relationshipId = _attributeByLocalName(blip, 'embed');
      final relationship = relationshipId == null
          ? null
          : relationships[relationshipId];
      if (relationship == null || relationship.type != 'image') continue;
      final targetPath = _resolvePath('word', relationship.target);
      final image = entries[targetPath];
      if (image == null) continue;
      final assetId = 'docx:asset:$relationshipId';
      if (!assets.any((asset) => asset.id == assetId)) {
        assets.add(
          XiaoqiDocumentAsset(
            id: assetId,
            mimeType: _mimeType(targetPath),
            bytes: List.unmodifiable(image.content),
            altText: _imageDescription(paragraph),
            sourceLocator: locator,
          ),
        );
      }
      imageBlocks.add(
        XiaoqiDocumentBlock(
          id: 'docx:block:$index:image:${imageBlocks.length}',
          kind: 'image',
          text: _imageDescription(paragraph),
          assetId: assetId,
          sourceLocator: locator,
        ),
      );
    }

    final blocks = <XiaoqiDocumentBlock>[];
    final textPages = text.split('\f');
    final isObject = hasMath || hasChart || imageBlocks.isNotEmpty;
    for (var pageIndex = 0; pageIndex < textPages.length; pageIndex++) {
      if (pageIndex > 0) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: 'docx:page-break:$index:${pageIndex - 1}',
            kind: 'page_break',
            text: '',
            originalPageLabel: '${firstPageBreakLabel + pageIndex - 1}',
            sourceLocator:
                'word/document.xml#page-break-$index-${pageIndex - 1}',
          ),
        );
      }
      final pageText = textPages[pageIndex].trim();
      if (pageText.isEmpty && !isObject) continue;
      blocks.add(
        XiaoqiDocumentBlock(
          id: pageIndex == 0
              ? 'docx:block:$index'
              : 'docx:block:$index:$pageIndex',
          kind: kind,
          text: pageText.isEmpty && kind == 'chart' ? '图表对象' : pageText,
          level: level,
          sourceLocator: locator,
          attributes: attributes,
        ),
      );
    }
    // A paragraph can contain text and an image. Keep text/page-break blocks
    // before images so reading order remains deterministic.
    return List.unmodifiable([...blocks, ...imageBlocks]);
  }

  int _paragraphPageBreakCount(XmlElement paragraph) {
    var count = 0;
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      if (element.localName == 'lastRenderedPageBreak') {
        count++;
        continue;
      }
      if (element.localName != 'br') continue;
      final type = _attributeByLocalName(element, 'type')?.toLowerCase();
      if (type == 'page') count++;
    }
    return count;
  }

  XiaoqiDocumentBlock? _tableBlock(
    XmlElement table,
    int tableIndex,
    int blockIndex,
  ) {
    final rows = <List<String>>[];
    for (final row in table.children.whereType<XmlElement>().where(
      (element) => element.localName == 'tr',
    )) {
      final cells = <String>[];
      for (final cell in row.children.whereType<XmlElement>().where(
        (element) => element.localName == 'tc',
      )) {
        cells.add(_elementText(cell).trim());
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    return XiaoqiDocumentBlock(
      id: 'docx:block:$blockIndex',
      kind: 'table',
      text: rows.map((row) => row.join(' | ')).join('\n'),
      sourceLocator: 'word/document.xml#tbl-$tableIndex',
      attributes: {
        'rows': jsonEncode(rows),
        'rowCount': '${rows.length}',
        'columnCount':
            '${rows.map((row) => row.length).fold<int>(0, (max, count) => count > max ? count : max)}',
      },
    );
  }

  List<XiaoqiDocumentChapter> _chapters(
    List<XiaoqiDocumentBlock> blocks, {
    required String title,
    required String sourceLocator,
  }) {
    final chapters = <XiaoqiDocumentChapter>[];
    var currentTitle = title.trim().isEmpty ? '全文' : title.trim();
    var currentBlocks = <XiaoqiDocumentBlock>[];

    void flush() {
      if (currentBlocks.isEmpty) return;
      chapters.add(
        XiaoqiDocumentChapter(
          id: 'docx:chapter:${chapters.length}',
          title: currentTitle,
          href: sourceLocator,
          sourceLocator: sourceLocator,
          html: '',
          plainText: currentBlocks
              .map((block) => block.text)
              .where((text) => text.trim().isNotEmpty)
              .join('\n\n'),
          order: chapters.length,
          blocks: List.unmodifiable(currentBlocks),
        ),
      );
      currentBlocks = [];
    }

    for (final block in blocks) {
      if (block.kind == 'heading' &&
          block.level <= 1 &&
          currentBlocks.isNotEmpty) {
        flush();
        currentTitle = block.text;
      }
      currentBlocks.add(block);
    }
    flush();
    if (chapters.isEmpty) {
      chapters.add(
        XiaoqiDocumentChapter(
          id: 'docx:chapter:0',
          title: currentTitle,
          href: sourceLocator,
          sourceLocator: sourceLocator,
          html: '',
          plainText: '',
          order: 0,
        ),
      );
    }
    return List.unmodifiable(chapters);
  }

  Map<String, int> _parseStyles(XmlDocument? document) {
    final result = <String, int>{};
    if (document == null) return result;
    for (final style in document.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'style',
    )) {
      final id = _attributeByLocalName(style, 'styleId');
      if (id == null) continue;
      final outline = _directChild(style, 'pPr') == null
          ? null
          : int.tryParse(
              _directChild(
                    _directChild(style, 'pPr'),
                    'outlineLvl',
                  )?.getAttribute('val') ??
                  '',
            );
      final name = _directChild(style, 'name')?.getAttribute('val') ?? '';
      final headingLevel = outline ?? _headingLevel(id) ?? _headingLevel(name);
      if (headingLevel != null) result[id] = headingLevel;
    }
    return result;
  }

  Map<String, _Relationship> _parseRelationships(XmlDocument? document) {
    final result = <String, _Relationship>{};
    if (document == null) return result;
    for (final relationship
        in document.descendants.whereType<XmlElement>().where(
          (element) => element.localName == 'Relationship',
        )) {
      final id = _attributeByLocalName(relationship, 'Id');
      final target = _attributeByLocalName(relationship, 'Target');
      final type = _attributeByLocalName(relationship, 'Type') ?? '';
      if (id == null || target == null) continue;
      result[id] = _Relationship(
        target: target,
        type: type.endsWith('/image') ? 'image' : type,
      );
    }
    return result;
  }

  XmlDocument? _parseOptionalXml(ArchiveFile? entry) {
    if (entry == null) return null;
    try {
      return XmlDocument.parse(_decode(entry.content));
    } catch (_) {
      return null;
    }
  }

  String _paragraphText(XmlElement paragraph) {
    final buffer = StringBuffer();
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      switch (element.localName) {
        case 't':
          buffer.write(element.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br':
          buffer.write(
            _attributeByLocalName(element, 'type')?.toLowerCase() == 'page'
                ? '\f'
                : '\n',
          );
        case 'lastRenderedPageBreak':
          buffer.write('\f');
        case 'cr':
          buffer.write('\n');
        case 'noBreakHyphen':
          buffer.write('-');
        case 'sym':
          final value = _attributeByLocalName(element, 'char');
          final code = int.tryParse(value ?? '', radix: 16);
          if (code != null && code >= 0 && code <= 0x10ffff) {
            buffer.write(String.fromCharCode(code));
          }
      }
    }
    return buffer.toString();
  }

  String _elementText(XmlElement element) => element.descendants
      .whereType<XmlElement>()
      .where((child) => child.localName == 't')
      .map((child) => child.innerText)
      .join();

  String _ommlToLatex(XmlElement paragraph) {
    final root = paragraph.descendants.whereType<XmlElement>().where(
      (element) =>
          element.localName == 'oMath' || element.localName == 'oMathPara',
    );
    final math = root.isEmpty ? null : root.first;
    if (math == null) return '';
    return _ommlNodeToLatex(math).trim();
  }

  String _ommlNodeToLatex(XmlElement element) {
    switch (element.localName) {
      case 't':
        return element.innerText;
      case 'chr':
        return _attributeByLocalName(element, 'val') ?? '';
      case 'f':
        final numerator = _directChild(element, 'num');
        final denominator = _directChild(element, 'den');
        return '\\frac{${_ommlChildrenToLatex(numerator)}}{${_ommlChildrenToLatex(denominator)}}';
      case 'sSup':
        final base = _directChild(element, 'e');
        final sup = _directChild(element, 'sup');
        return '{${_ommlChildrenToLatex(base)}}^{${_ommlChildrenToLatex(sup)}}';
      case 'sSub':
        final base = _directChild(element, 'e');
        final sub = _directChild(element, 'sub');
        return '{${_ommlChildrenToLatex(base)}}_{${_ommlChildrenToLatex(sub)}}';
      case 'rad':
        final base = _directChild(element, 'e');
        return '\\sqrt{${_ommlChildrenToLatex(base)}}';
      default:
        return _ommlChildrenToLatex(element);
    }
  }

  String _ommlChildrenToLatex(XmlElement? element) {
    if (element == null) return '';
    return element.children
        .whereType<XmlElement>()
        .map(_ommlNodeToLatex)
        .join();
  }

  List<FigureElement> _chartFigureElements(
    XmlElement paragraph,
    Map<String, _Relationship> relationships,
    Map<String, ArchiveFile> entries,
  ) {
    for (final chart in paragraph.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'chart',
    )) {
      final relationshipId =
          _attributeByLocalName(chart, 'id') ??
          _attributeByLocalName(chart, 'embed');
      final relationship = relationshipId == null
          ? null
          : relationships[relationshipId];
      if (relationship == null) continue;
      final chartPath = _resolvePath('word', relationship.target);
      final chartEntry = entries[chartPath];
      if (chartEntry == null) continue;
      try {
        final document = XmlDocument.parse(_decode(chartEntry.content));
        final series = document.descendants.whereType<XmlElement>().where(
          (element) => element.localName == 'ser',
        );
        final values = <double>[];
        final labels = <String>[];
        for (final item in series) {
          final cache = item.descendants.whereType<XmlElement>().where(
            (element) => element.localName == 'numCache',
          );
          if (cache.isEmpty) continue;
          for (final point
              in cache.first.descendants.whereType<XmlElement>().where(
                (element) => element.localName == 'pt',
              )) {
            final value = _firstDescendantText(point, 'v');
            final number = double.tryParse(value);
            if (number != null) values.add(number);
          }
          if (labels.isEmpty) {
            final textCache = item.descendants.whereType<XmlElement>().where(
              (element) => element.localName == 'strCache',
            );
            if (textCache.isNotEmpty) {
              labels.addAll(
                textCache.first.descendants
                    .whereType<XmlElement>()
                    .where((element) => element.localName == 'v')
                    .map((element) => element.innerText.trim()),
              );
            }
          }
        }
        if (values.isEmpty) continue;
        final minValue = values.reduce((a, b) => a < b ? a : b);
        final maxValue = values.reduce((a, b) => a > b ? a : b);
        final span = (maxValue - minValue).abs() < .000001
            ? 1.0
            : maxValue - minValue;
        final count = values.length.toDouble();
        final chartType = document.descendants.whereType<XmlElement>().any(
          (element) =>
              element.localName == 'lineChart' ||
              element.localName == 'areaChart',
        );
        final elements = <FigureElement>[
          const FigureElement(
            kind: 'line',
            points: [FigurePoint(.08, .88), FigurePoint(.94, .88)],
          ),
          const FigureElement(
            kind: 'line',
            points: [FigurePoint(.08, .12), FigurePoint(.08, .88)],
          ),
        ];
        if (chartType) {
          final points = [
            for (var i = 0; i < values.length; i++)
              FigurePoint(
                values.length == 1 ? .5 : .1 + .8 * i / (values.length - 1),
                .84 - .68 * (values[i] - minValue) / span,
              ),
          ];
          if (points.length >= 2) {
            elements.add(FigureElement(kind: 'curve', points: points));
          }
        } else {
          for (var i = 0; i < values.length; i++) {
            final normalized = (values[i] - minValue) / span;
            elements.add(
              FigureElement(
                kind: 'rect',
                x: .1 + .8 * i / count,
                y: .84 - .68 * normalized,
                width: .55 * .8 / count,
                height: .68 * normalized,
                filled: true,
              ),
            );
          }
        }
        for (var i = 0; i < labels.length && i < values.length; i++) {
          elements.add(
            FigureElement(
              kind: 'text',
              text: labels[i],
              x: .06 + .8 * i / count,
              y: .9,
              width: .8 / count,
              height: .08,
            ),
          );
        }
        return elements;
      } on Object {
        // A malformed chart part remains a visible object placeholder.
      }
    }
    return const [];
  }

  String _firstDescendantText(XmlElement element, String localName) {
    for (final child in element.descendants.whereType<XmlElement>()) {
      if (child.localName == localName) return child.innerText.trim();
    }
    return '';
  }

  String _imageDescription(XmlElement paragraph) {
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      if (element.localName != 'docPr') continue;
      return _attributeByLocalName(element, 'descr') ??
          _attributeByLocalName(element, 'title') ??
          '文档图片';
    }
    return '文档图片';
  }

  XmlElement? _firstElement(XmlDocument document, String localName) {
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.localName == localName) return element;
    }
    return null;
  }

  XmlElement? _directChild(XmlElement? parent, String localName) {
    if (parent == null) return null;
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.localName == localName) return child;
    }
    return null;
  }

  String? _firstText(XmlDocument? document, String localName) {
    if (document == null) return null;
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.localName == localName &&
          element.innerText.trim().isNotEmpty) {
        return element.innerText.trim();
      }
    }
    return null;
  }

  String _firstAttributeValue(
    XmlDocument? document,
    String elementName,
    String attributeName,
  ) {
    if (document == null) return '';
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.localName != elementName) continue;
      return _attributeByLocalName(element, attributeName) ?? '';
    }
    return '';
  }

  String? _attributeByLocalName(XmlElement element, String localName) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return null;
  }

  int? _headingLevel(String value) {
    final match = RegExp(
      r'heading\s*([1-6])',
      caseSensitive: false,
    ).firstMatch(value);
    final level = int.tryParse(match?.group(1) ?? '');
    return level == null ? null : level;
  }

  String _resolvePath(String base, String target) {
    final raw = target.replaceAll('\\', '/');
    final parts = <String>[];
    for (final part in ('$base/$raw').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(Uri.decodeComponent(part));
    }
    return parts.join('/').toLowerCase();
  }

  String _normalizePath(String value) =>
      _resolvePath('', value).replaceFirst(RegExp(r'^/'), '');

  bool _isUnsafePath(String value) =>
      value.startsWith('/') ||
      value.contains('\\') ||
      value.split('/').contains('..');

  String _mimeType(String path) {
    switch (path.split('.').last.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      default:
        return 'application/octet-stream';
    }
  }

  String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);
}

class _Relationship {
  const _Relationship({required this.target, required this.type});

  final String target;
  final String type;
}
