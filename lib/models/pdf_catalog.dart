import 'dart:convert';

class PdfCatalogEntry {
  const PdfCatalogEntry({
    required this.id,
    required this.title,
    required this.level,
    this.pdfPage,
    this.printedPage,
    this.printedPageLabel,
    this.sourcePdfPage,
    this.parentId,
    this.nodeType = 'section',
    this.order = 0,
    this.pdfEndPage,
    this.confidence = 0,
    this.sourceLeft = 0,
    this.sourceTop = 0,
    this.sourceRight = 0,
    this.sourceBottom = 0,
    required this.sourceKind,
    this.status = 'candidate',
  });

  final String id;
  final String title;
  final int level;
  final int? pdfPage;
  final int? printedPage;
  /// Original page label as printed by the source (e.g. "iv", "A-3").
  /// [printedPage] is retained as a numeric compatibility/calibration field.
  final String? printedPageLabel;
  /// Physical PDF page containing the source catalog line/image.
  final int? sourcePdfPage;
  /// Stable parent node ID. Null means a top-level book node.
  final String? parentId;
  final String nodeType;
  final int order;
  int get sourceOrdinal => order;
  final int? pdfEndPage;
  final double confidence;
  final double sourceLeft;
  final double sourceTop;
  final double sourceRight;
  final double sourceBottom;
  final String sourceKind;
  final String status;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'level': level,
    'pdf_page': pdfPage,
    'printed_page': printedPage,
    'printed_page_label': printedPageLabel,
    'source_pdf_page': sourcePdfPage,
    'parent_id': parentId,
    'node_type': nodeType,
    'order': order,
    'source_ordinal': order,
    'pdf_end_page': pdfEndPage,
    'confidence': confidence,
    'source_left': sourceLeft,
    'source_top': sourceTop,
    'source_right': sourceRight,
    'source_bottom': sourceBottom,
    'source_kind': sourceKind,
    'status': status,
  };

  factory PdfCatalogEntry.fromJson(Map<String, dynamic> json) {
    return PdfCatalogEntry(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      // Keep deep, valid source outlines intact. The parser applies its own
      // defensive depth limit for malformed input; deserialization must not
      // flatten a legitimate document to eight levels.
      level: _asInt(json['level'], fallback: 1).clamp(1, 32).toInt(),
      pdfPage: _asNullableInt(json['pdf_page'] ?? json['pdfPage']),
      printedPage: _asNullableInt(json['printed_page'] ?? json['printedPage']),
      printedPageLabel:
          (json['printed_page_label'] ?? json['printedPageLabel'])?.toString(),
      sourcePdfPage: _asNullableInt(
        json['source_pdf_page'] ?? json['sourcePdfPage'],
      ),
      parentId: (json['parent_id'] ?? json['parentId'])?.toString(),
      nodeType: (json['node_type'] ?? json['nodeType'] ?? 'section').toString(),
      order: _asInt(
        json['order'] ?? json['source_ordinal'] ?? json['sourceOrdinal'],
        fallback: 0,
      ),
      pdfEndPage: _asNullableInt(
        json['pdf_end_page'] ?? json['pdfEndPage'],
      ),
      confidence: _asDouble(json['confidence']),
      sourceLeft: _asDouble(json['source_left'] ?? json['sourceLeft']),
      sourceTop: _asDouble(json['source_top'] ?? json['sourceTop']),
      sourceRight: _asDouble(json['source_right'] ?? json['sourceRight']),
      sourceBottom: _asDouble(json['source_bottom'] ?? json['sourceBottom']),
      sourceKind: (json['source_kind'] ?? json['sourceKind'] ?? 'unknown')
          .toString(),
      status: (json['status'] ?? 'candidate').toString(),
    );
  }

  PdfCatalogEntry copyWith({
    int? pdfPage,
    String? status,
    String? parentId,
    String? printedPageLabel,
    String? nodeType,
    int? order,
    int? pdfEndPage,
    double? confidence,
    double? sourceLeft,
    double? sourceTop,
    double? sourceRight,
    double? sourceBottom,
  }) => PdfCatalogEntry(
    id: id,
    title: title,
    level: level,
    pdfPage: pdfPage ?? this.pdfPage,
    printedPage: printedPage,
    printedPageLabel: printedPageLabel ?? this.printedPageLabel,
    sourcePdfPage: sourcePdfPage,
    parentId: parentId ?? this.parentId,
    nodeType: nodeType ?? this.nodeType,
    order: order ?? this.order,
    pdfEndPage: pdfEndPage ?? this.pdfEndPage,
    confidence: confidence ?? this.confidence,
    sourceLeft: sourceLeft ?? this.sourceLeft,
    sourceTop: sourceTop ?? this.sourceTop,
    sourceRight: sourceRight ?? this.sourceRight,
    sourceBottom: sourceBottom ?? this.sourceBottom,
    sourceKind: sourceKind,
    status: status ?? this.status,
  );
}

class PdfCatalogParseResult {
  const PdfCatalogParseResult({
    required this.pageCount,
    required this.entries,
    required this.sourceKind,
  });

  final int pageCount;
  final List<PdfCatalogEntry> entries;
  final String sourceKind;

  String get status {
    if (entries.isEmpty) return 'empty';
    return entries.every(
          (entry) => entry.pdfPage != null && entry.status == 'candidate',
        )
        ? 'ready'
        : 'needs_review';
  }

  String toJson() =>
      jsonEncode(entries.map((entry) => entry.toJson()).toList());
}

int _asInt(Object? value, {required int fallback}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value) {
  final number = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;
  return number.clamp(0, double.infinity).toDouble();
}

int? _asNullableInt(Object? value) {
  if (value == null) return null;
  return int.tryParse(value.toString());
}
