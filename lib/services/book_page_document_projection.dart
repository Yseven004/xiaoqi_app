import 'dart:convert';

import '../models/ocr_layout.dart';
import '../models/xiaoqi_document.dart';

/// Projects a reflowable source chapter into the page-document contract used
/// by the existing editor. Rich objects stay blocks; only their surrounding
/// text is editable by the block editor.
class BookPageDocumentProjection {
  const BookPageDocumentProjection._();

  static BookPageDocument chapterToPageDocument(
    XiaoqiDocumentChapter chapter, {
    List<XiaoqiDocumentAsset> assets = const [],
  }) {
    final assetById = <String, XiaoqiDocumentAsset>{
      for (final asset in assets) asset.id: asset,
    };
    final blocks = <OcrBlock>[];
    if (chapter.title.trim().isNotEmpty) {
      blocks.add(
        OcrBlock(
          id: 0,
          sourceId: '${chapter.id}:title',
          sourceLocator: chapter.sourceLocator,
          text: chapter.title.trim(),
          type: 'title',
          x: .08,
          y: .08,
          width: .84,
          height: .08,
          fontWeightRole: 'bold',
        ),
      );
    }

    final sourceBlocks = chapter.blocks.isEmpty
        ? [
            XiaoqiDocumentBlock(
              id: '${chapter.id}:paragraph:0',
              kind: 'paragraph',
              text: chapter.plainText,
            ),
          ]
        : chapter.blocks;
    var pageIndex = 0;
    for (final source in sourceBlocks) {
      if (source.kind == 'page_break') continue;
      final isObject = _isObject(source.kind);
      if (!isObject && source.text.trim().isEmpty) continue;
      final id = blocks.length + 1;
      final asset = assetById[source.assetId];
      blocks.add(
        OcrBlock(
          id: id,
          sourceId: source.id,
          sourceLocator: source.sourceLocator,
          text: source.text,
          type: _typeFor(source.kind),
          x: .08,
          y: (.18 + pageIndex * .08).clamp(0.0, .92),
          width: .84,
          height: isObject ? .24 : .07,
          firstLineIndent: source.attributes['firstLineIndent'] == '2' ? 2 : 0,
          fontWeightRole: source.kind == 'heading' ? 'bold' : 'regular',
          tableRows: _tableRows(source),
          figureKind: _figureKind(source.kind),
          figureAspectRatio: _figureAspectRatio(source),
          figureElements: _figureElements(source),
          imageData: asset == null || asset.bytes.isEmpty
              ? null
              : _dataUri(asset),
          attributes: source.attributes,
        ),
      );
      pageIndex++;
    }
    return BookPageDocument(
      schemaVersion: 2,
      blocks: List.unmodifiable(blocks),
      compatibilityMarkdown: chapter.plainText,
    );
  }

  static bool _isObject(String kind) => const {
    'image',
    'figure',
    'chart',
    'math',
    'formula',
    'table',
  }.contains(kind);

  static String _typeFor(String kind) {
    switch (kind) {
      case 'table':
        return 'table';
      case 'chart':
        return 'chart';
      case 'image':
      case 'figure':
        return 'figure';
      case 'math':
      case 'formula':
        return 'formula';
      case 'list_item':
        return 'list_item';
      case 'quote':
        return 'quote';
      case 'code':
        return 'code';
      case 'secondary':
        return 'secondary';
      default:
        return 'paragraph';
    }
  }

  static String _figureKind(String kind) {
    switch (kind) {
      case 'chart':
        return 'chart';
      case 'math':
      case 'formula':
        return 'formula';
      case 'callout':
        return 'callout';
      case 'illustration':
        return 'illustration';
      default:
        return 'diagram';
    }
  }

  static double _figureAspectRatio(XiaoqiDocumentBlock block) {
    final explicit = double.tryParse(
      block.attributes['figureAspectRatio'] ??
          block.attributes['figure_aspect_ratio'] ??
          '',
    );
    if (explicit != null && explicit > 0) {
      return explicit.clamp(.5, 4).toDouble();
    }
    return 1.6;
  }

  static List<List<String>> _tableRows(XiaoqiDocumentBlock block) {
    final raw = block.attributes['rows'];
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final row in decoded)
          if (row is List) [for (final cell in row) cell.toString()],
      ];
    } on Object {
      return const [];
    }
  }

  static List<FigureElement> _figureElements(XiaoqiDocumentBlock block) {
    final raw = block.attributes['figure_elements'];
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            FigureElement.fromJson(Map<String, dynamic>.from(item)),
      ];
    } on Object {
      return const [];
    }
  }

  static String _dataUri(XiaoqiDocumentAsset asset) =>
      'data:${asset.mimeType};base64,${base64Encode(asset.bytes)}';
}
