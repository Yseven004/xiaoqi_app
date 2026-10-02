library;

/// A point in a figure-local 0~1 coordinate system.
class FigurePoint {
  const FigurePoint(this.x, this.y);

  final double x;
  final double y;

  factory FigurePoint.fromJson(Object? value) {
    if (value is List && value.length >= 2) {
      return FigurePoint(_unit(value[0]), _unit(value[1]));
    }
    if (value is Map) {
      return FigurePoint(_unit(value['x']), _unit(value['y']));
    }
    return const FigurePoint(0, 0);
  }

  List<double> toJson() => [x, y];

  static double _unit(Object? value) =>
      ((value as num?)?.toDouble() ?? 0).clamp(0, 1).toDouble();
}

/// One frontend-renderable primitive extracted from a source figure.
///
/// Coordinates are relative to the figure itself rather than to the page, so
/// the figure can be reflowed without keeping a raster crop. The deliberately
/// small vocabulary is stable across Flutter, exports and future migrations.
class FigureElement {
  const FigureElement({
    required this.kind,
    this.text = '',
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.points = const <FigurePoint>[],
    this.textRole = 'label',
    this.textAlign = 'center',
    this.strokeWidth = 1,
    this.filled = false,
  });

  final String kind;
  final String text;
  final double x;
  final double y;
  final double width;
  final double height;
  final List<FigurePoint> points;
  final String textRole;
  final String textAlign;
  final double strokeWidth;
  final bool filled;

  factory FigureElement.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    return FigureElement(
      kind: _normalizedKind(json['kind']?.toString() ?? ''),
      text: json['text']?.toString() ?? '',
      x: _unit(json['x']),
      y: _unit(json['y']),
      width: _unit(json['width']),
      height: _unit(json['height']),
      points: rawPoints is List
          ? [for (final point in rawPoints) FigurePoint.fromJson(point)]
          : const <FigurePoint>[],
      textRole: _normalizedTextRole(json['text_role']?.toString() ?? 'label'),
      textAlign: _normalizedTextAlign(
        json['text_align']?.toString() ?? 'center',
      ),
      strokeWidth: ((json['stroke_width'] as num?)?.toDouble() ?? 1)
          .clamp(.5, 4)
          .toDouble(),
      filled: json['filled'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (text.isNotEmpty) 'text': text,
    if (x != 0) 'x': x,
    if (y != 0) 'y': y,
    if (width != 0) 'width': width,
    if (height != 0) 'height': height,
    if (points.isNotEmpty)
      'points': points.map((point) => point.toJson()).toList(),
    if (kind == 'text') 'text_role': textRole,
    if (kind == 'text') 'text_align': textAlign,
    if (kind != 'text' && strokeWidth != 1) 'stroke_width': strokeWidth,
    if (kind != 'text' && filled) 'filled': true,
  };

  bool get isText => kind == 'text';

  bool get isDrawable => switch (kind) {
    'text' => text.trim().isNotEmpty && width > 0 && height > 0,
    'rect' || 'rounded_rect' || 'ellipse' => width > 0 && height > 0,
    'line' || 'arrow' || 'polyline' || 'curve' => points.length >= 2,
    _ => false,
  };

  static double _unit(Object? value) =>
      ((value as num?)?.toDouble() ?? 0).clamp(0, 1).toDouble();

  static String _normalizedKind(String value) {
    const allowed = {
      'text',
      'rect',
      'rounded_rect',
      'ellipse',
      'line',
      'arrow',
      'polyline',
      'curve',
    };
    return allowed.contains(value) ? value : '';
  }

  static String _normalizedTextRole(String value) =>
      const {'title', 'label', 'caption', 'secondary'}.contains(value)
      ? value
      : 'label';

  static String _normalizedTextAlign(String value) =>
      const {'left', 'center', 'right'}.contains(value) ? value : 'center';
}

/// 书页中的一个可独立排版内容块。
/// 坐标均为 0~1 的相对值，样式使用有限枚举而不是 Markdown 标记。
class OcrBlock {
  final int id;

  /// Stable identifier from the source document. [id] remains the legacy
  /// numeric page identifier used by older OCR notes.
  final String sourceId;
  final String sourceLocator;
  final String text;
  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final int firstLineIndent;
  final String fontWeightRole;
  final String fontStyleRole;

  /// A visual table or an unbordered set of columns whose cells are paired by
  /// row. Empty strings are meaningful: they preserve a visually blank cell.
  final List<List<String>> tableRows;
  final int tableHeaderRowCount;

  /// A normalized scene graph for frontend rendering of charts and diagrams.
  /// [imageData] remains read-only compatibility for already-saved v1 notes.
  final String figureKind;
  final double figureAspectRatio;
  final List<FigureElement> figureElements;
  final String? imageData;
  final Map<String, String> attributes;

  const OcrBlock({
    required this.id,
    this.sourceId = '',
    this.sourceLocator = '',
    required this.text,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.firstLineIndent = 0,
    this.fontWeightRole = 'regular',
    this.fontStyleRole = 'normal',
    this.tableRows = const <List<String>>[],
    this.tableHeaderRowCount = 0,
    this.figureKind = 'diagram',
    this.figureAspectRatio = 1.6,
    this.figureElements = const <FigureElement>[],
    this.imageData,
    this.attributes = const <String, String>{},
  });

  factory OcrBlock.fromJson(Map<String, dynamic> json) {
    final rows = _tableRows(json['table_rows']);
    return OcrBlock(
      id:
          (json['id'] as num?)?.toInt() ??
          (json['order'] as num?)?.toInt() ??
          0,
      sourceId: json['source_id']?.toString() ?? '',
      sourceLocator: json['source_locator']?.toString() ?? '',
      text: (json['text'] as String?) ?? '',
      type: _normalizedType((json['type'] as String?) ?? 'paragraph'),
      x: _coordinate(json['x']),
      y: _coordinate(json['y']),
      width: _coordinate(json['width']),
      height: _coordinate(json['height']),
      firstLineIndent: ((json['first_line_indent'] as num?)?.toInt() ?? 0)
          .clamp(0, 2),
      fontWeightRole: _normalizedWeight(
        (json['font_weight'] as String?) ?? 'regular',
      ),
      fontStyleRole: _normalizedStyle(
        (json['font_style'] as String?) ?? 'normal',
      ),
      tableRows: rows,
      tableHeaderRowCount: ((json['table_header_rows'] as num?)?.toInt() ?? 0)
          .clamp(0, rows.length),
      figureKind: _normalizedFigureKind(
        json['figure_kind']?.toString() ?? 'diagram',
      ),
      figureAspectRatio:
          ((json['figure_aspect_ratio'] as num?)?.toDouble() ?? 1.6)
              .clamp(.5, 4)
              .toDouble(),
      figureElements: _figureElements(json['figure_elements']),
      imageData: json['image_data'] as String?,
      attributes: (json['attributes'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    if (sourceId.isNotEmpty) 'source_id': sourceId,
    if (sourceLocator.isNotEmpty) 'source_locator': sourceLocator,
    'text': text,
    'type': type,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'first_line_indent': firstLineIndent,
    'font_weight': fontWeightRole,
    'font_style': fontStyleRole,
    if (tableRows.isNotEmpty) 'table_rows': tableRows,
    if (tableRows.isNotEmpty && tableHeaderRowCount > 0)
      'table_header_rows': tableHeaderRowCount,
    if (isFigure) 'figure_kind': figureKind,
    if (figureElements.isNotEmpty) 'figure_aspect_ratio': figureAspectRatio,
    if (figureElements.isNotEmpty)
      'figure_elements': figureElements
          .map((element) => element.toJson())
          .toList(),
    if (imageData != null) 'image_data': imageData,
    if (attributes.isNotEmpty) 'attributes': attributes,
  };

  OcrBlock copyWith({
    int? id,
    String? sourceId,
    String? sourceLocator,
    String? text,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    int? firstLineIndent,
    String? fontWeightRole,
    String? fontStyleRole,
    List<List<String>>? tableRows,
    int? tableHeaderRowCount,
    String? figureKind,
    double? figureAspectRatio,
    List<FigureElement>? figureElements,
    String? imageData,
    Map<String, String>? attributes,
  }) => OcrBlock(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    sourceLocator: sourceLocator ?? this.sourceLocator,
    text: text ?? this.text,
    type: type ?? this.type,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    firstLineIndent: firstLineIndent ?? this.firstLineIndent,
    fontWeightRole: fontWeightRole ?? this.fontWeightRole,
    fontStyleRole: fontStyleRole ?? this.fontStyleRole,
    tableRows: tableRows ?? this.tableRows,
    tableHeaderRowCount: tableHeaderRowCount ?? this.tableHeaderRowCount,
    figureKind: figureKind ?? this.figureKind,
    figureAspectRatio: figureAspectRatio ?? this.figureAspectRatio,
    figureElements: figureElements ?? this.figureElements,
    imageData: imageData ?? this.imageData,
    attributes: attributes ?? this.attributes,
  );

  bool get isTitle => type == 'title';
  bool get isParagraph => type == 'paragraph' || type == 'secondary';
  bool get isListItem => type == 'list_item';
  bool get isQuote => type == 'quote';
  bool get isTable => type == 'table' && tableRows.isNotEmpty;
  bool get isFigure => type == 'figure' || type == 'chart' || type == 'formula';
  bool get hasRenderableFigure =>
      isFigure && figureElements.any((element) => element.isDrawable);
  bool get isFurniture => type == 'page_header' || type == 'sidebar';
  bool get isLight => fontWeightRole == 'light' || type == 'secondary';
  bool get isBold => fontWeightRole == 'bold' || type == 'title';
  bool get isItalic => fontStyleRole == 'italic';

  /// Text-only consumers retain every table cell without pretending the
  /// original visual layout is a paragraph.
  String get readableText {
    if (isTable) return tableRows.map((row) => row.join('\t')).join('\n');
    if (!isFigure) return text;
    return <String>{
      text.trim(),
      ...figureElements
          .where((element) => element.isText)
          .map((element) => element.text.trim()),
    }.where((value) => value.isNotEmpty).join('\n');
  }

  static double _coordinate(Object? value) =>
      ((value as num?)?.toDouble() ?? 0).clamp(0, 1).toDouble();

  static String _normalizedType(String value) {
    const allowed = {
      'title',
      'paragraph',
      'secondary',
      'list_item',
      'quote',
      'code',
      'figure',
      'chart',
      'formula',
      'table',
      'page_header',
      'sidebar',
    };
    return allowed.contains(value) ? value : 'paragraph';
  }

  static String _normalizedWeight(String value) =>
      const {'light', 'regular', 'bold'}.contains(value) ? value : 'regular';

  static String _normalizedStyle(String value) =>
      const {'normal', 'italic'}.contains(value) ? value : 'normal';

  static String _normalizedFigureKind(String value) =>
      const {
        'diagram',
        'chart',
        'callout',
        'illustration',
        'formula',
      }.contains(value)
      ? value
      : 'diagram';

  static List<FigureElement> _figureElements(Object? value) {
    if (value is! List) return const <FigureElement>[];
    return [
      for (final item in value)
        if (item is Map)
          FigureElement.fromJson(Map<String, dynamic>.from(item)),
    ].where((element) => element.isDrawable).toList(growable: false);
  }

  /// Small vision models sometimes drift from the strict `List<List<String>>`
  /// contract: rows arrive as pipe-joined strings, the whole table as one
  /// markdown-ish string, or a `|---|---|` separator row sneaks in. Parse all
  /// of those tolerant shapes so a slightly malformed table still survives
  /// instead of collapsing into an invisible block.
  static List<List<String>> _tableRows(Object? value) {
    if (value is! List) {
      if (value is String) {
        return _padRows(_rowsFromMarkdownishString(value));
      }
      return const <List<String>>[];
    }
    return _padRows(
      [
        for (final row in value)
          if (row is List)
            _normalizeRow([
              for (final cell in row) cell?.toString().trim() ?? '',
            ])
          else if (row is String)
            _rowFromString(row),
      ].where((row) => !_isSeparatorRow(row)).toList(),
    );
  }

  /// Blank fill rows must keep the same cell count as the header so the
  /// rendered grid preserves the original column structure.
  static List<List<String>> _padRows(List<List<String>> rows) {
    if (rows.isEmpty) return rows;
    final width = rows.fold<int>(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    if (width <= 1) return rows;
    return [
      for (final row in rows)
        row.length >= width
            ? row
            : [...row, ...List.filled(width - row.length, '')],
    ];
  }

  static List<List<String>> _rowsFromMarkdownishString(String value) {
    return [
      for (final line in value.trim().split('\n')) _rowFromString(line),
    ].where((row) => !_isSeparatorRow(row)).toList();
  }

  static List<String> _rowFromString(String row) {
    var trimmed = row.trim();
    if (trimmed.isEmpty) return const [''];
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1).trimLeft();
    if (trimmed.endsWith('|')) {
      trimmed = trimmed.substring(0, trimmed.length - 1).trimRight();
    }
    return _normalizeRow(
      trimmed.isEmpty ? const [''] : trimmed.split(RegExp(r'\s*[|｜\t]\s*')),
    );
  }

  static List<String> _normalizeRow(List<String> cells) => [
    for (final cell in cells) cell.trim(),
  ];

  static bool _isSeparatorRow(List<String> row) {
    // An all-empty row is a legitimate blank fill row, not a separator; only
    // drop rows that actually look like markdown alignment rules.
    final hasRule = row.any(
      (cell) =>
          RegExp(r'^:?-{2,}:?$').hasMatch(cell) ||
          RegExp(r'^:?={2,}:?$').hasMatch(cell),
    );
    if (!hasRule) return false;
    return row.every(
      (cell) =>
          cell.isEmpty ||
          RegExp(r'^:?-{2,}:?$').hasMatch(cell) ||
          RegExp(r'^:?={2,}:?$').hasMatch(cell),
    );
  }
}

/// 文档识别插件的正式输出协议。
/// [compatibilityMarkdown] 只用于旧数据兼容，界面必须消费 [blocks]。
class BookPageDocument {
  final int schemaVersion;
  final List<OcrBlock> blocks;

  /// Original OCR/layout blocks. User edits live in [editedBlocks] so the
  /// source page can always be inspected and restored.
  final List<OcrBlock>? editedBlocks;
  final String? pageNumber;
  final String compatibilityMarkdown;

  const BookPageDocument({
    this.schemaVersion = 1,
    required this.blocks,
    this.editedBlocks,
    this.pageNumber,
    this.compatibilityMarkdown = '',
  });

  factory BookPageDocument.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'] ?? json['ocr_layout'];
    final rawEditedBlocks = json['edited_blocks'];
    return BookPageDocument(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      blocks: _parseBlocks(rawBlocks),
      editedBlocks: rawEditedBlocks is List
          ? _parseBlocks(rawEditedBlocks)
          : null,
      pageNumber: json['page_number']?.toString(),
      compatibilityMarkdown:
          (json['compatibility_markdown'] ?? json['markdown'])?.toString() ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': editedBlocks == null ? schemaVersion : 2,
    'document_type': 'book_page',
    'blocks': blocks.map((block) => block.toJson()).toList(),
    // 迁移期保留旧字段，已安装版本仍能读取新笔记。
    'ocr_layout': blocks.map((block) => block.toJson()).toList(),
    if (editedBlocks != null)
      'edited_blocks': editedBlocks!.map((block) => block.toJson()).toList(),
    if (pageNumber != null && pageNumber!.trim().isNotEmpty)
      'page_number': pageNumber,
    if (compatibilityMarkdown.isNotEmpty)
      'compatibility_markdown': compatibilityMarkdown,
  };

  /// Blocks used for the current visible page. The original [blocks] remain
  /// immutable source evidence when an edited copy exists.
  List<OcrBlock> get renderBlocks => editedBlocks ?? blocks;

  List<OcrBlock> get contentBlocks =>
      renderBlocks.where((block) => !block.isFurniture).toList(growable: false);

  String get plainText => contentBlocks
      .map((block) => block.readableText.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  BookPageDocument copyWith({
    List<OcrBlock>? blocks,
    List<OcrBlock>? editedBlocks,
    String? pageNumber,
    String? compatibilityMarkdown,
  }) => BookPageDocument(
    schemaVersion: schemaVersion,
    blocks: blocks ?? this.blocks,
    editedBlocks: editedBlocks ?? this.editedBlocks,
    pageNumber: pageNumber ?? this.pageNumber,
    compatibilityMarkdown: compatibilityMarkdown ?? this.compatibilityMarkdown,
  );

  static List<OcrBlock> _parseBlocks(Object? value) {
    if (value is! List) return const <OcrBlock>[];
    return [
      for (final item in value)
        if (item is Map) OcrBlock.fromJson(Map<String, dynamic>.from(item)),
    ];
  }
}

/// 旧名称兼容层。新代码优先使用 [BookPageDocument]。
class AnnotatedNoteData {
  final List<OcrBlock> ocrLayout;
  final List<OcrBlock>? editedBlocks;
  final String? pageNumber;
  final String markdown;

  const AnnotatedNoteData({
    required this.ocrLayout,
    this.editedBlocks,
    this.pageNumber,
    this.markdown = '',
  });

  factory AnnotatedNoteData.fromJson(Map<String, dynamic> json) {
    final document = BookPageDocument.fromJson(json);
    return AnnotatedNoteData.fromDocument(document);
  }

  factory AnnotatedNoteData.fromDocument(BookPageDocument document) =>
      AnnotatedNoteData(
        ocrLayout: document.blocks,
        editedBlocks: document.editedBlocks,
        pageNumber: document.pageNumber,
        markdown: document.compatibilityMarkdown,
      );

  BookPageDocument get document => BookPageDocument(
    blocks: ocrLayout,
    editedBlocks: editedBlocks,
    pageNumber: pageNumber,
    compatibilityMarkdown: markdown,
  );

  Map<String, dynamic> toJson() => document.toJson();

  AnnotatedNoteData copyWith({
    List<OcrBlock>? ocrLayout,
    List<OcrBlock>? editedBlocks,
    String? pageNumber,
    String? markdown,
  }) => AnnotatedNoteData(
    ocrLayout: ocrLayout ?? this.ocrLayout,
    editedBlocks: editedBlocks ?? this.editedBlocks,
    pageNumber: pageNumber ?? this.pageNumber,
    markdown: markdown ?? this.markdown,
  );
}
