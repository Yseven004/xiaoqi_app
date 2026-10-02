import 'dart:convert';

/// The format-neutral document contract consumed by readers and AI adapters.
///
/// EPUB is the first non-PDF producer. Keeping this model independent from
/// EPUB's OPF/XHTML vocabulary means later parsers can feed the same pipeline.
class XiaoqiDocument {
  const XiaoqiDocument({
    required this.format,
    required this.title,
    required this.author,
    required this.language,
    required this.chapters,
    this.assets = const [],
    this.originalPageCount,
    this.annotations = const {},
  });

  final String format;
  final String title;
  final String author;
  final String language;
  final List<XiaoqiDocumentChapter> chapters;
  final List<XiaoqiDocumentAsset> assets;
  final Map<String, Object?> annotations;

  /// Number of pages from the source publication, when the source carries
  /// explicit pagination markers. This is intentionally nullable: reflowable
  /// sources such as plain TXT or digital-only EPUB often do not have a
  /// stable original page count.
  final int? originalPageCount;

  Map<String, dynamic> toMap({bool includeAnnotations = false}) => {
    'format': format,
    'title': title,
    'author': author,
    'language': language,
    'chapters': chapters.map((chapter) => chapter.toMap()).toList(),
    'assets': assets.map((asset) => asset.toMap()).toList(),
    if (originalPageCount != null) 'originalPageCount': originalPageCount,
    if (includeAnnotations && annotations.isNotEmpty)
      'annotations': annotations,
  };

  String toJson({bool includeAnnotations = false}) =>
      jsonEncode(toMap(includeAnnotations: includeAnnotations));

  factory XiaoqiDocument.fromMap(Map<String, dynamic> map) => XiaoqiDocument(
    format: map['format'] as String? ?? '',
    title: map['title'] as String? ?? '',
    author: map['author'] as String? ?? '',
    language: map['language'] as String? ?? '',
    chapters: (map['chapters'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => XiaoqiDocumentChapter.fromMap(item.cast<String, dynamic>()),
        )
        .toList(growable: false),
    assets: (map['assets'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => XiaoqiDocumentAsset.fromMap(item.cast<String, dynamic>()),
        )
        .toList(growable: false),
    originalPageCount: _optionalInt(
      map['originalPageCount'] ?? map['original_page_count'],
    ),
    annotations: _objectMap(map['annotations']),
  );

  factory XiaoqiDocument.fromJson(String value) => XiaoqiDocument.fromMap(
    (jsonDecode(value) as Map).cast<String, dynamic>(),
  );
}

int? _optionalInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

class XiaoqiDocumentChapter {
  const XiaoqiDocumentChapter({
    required this.id,
    required this.title,
    required this.href,
    required this.html,
    required this.plainText,
    required this.order,
    this.blocks = const [],
    this.sourceLocator = '',
  });

  final String id;
  final String title;
  final String href;
  final String html;
  final String plainText;
  final int order;
  final List<XiaoqiDocumentBlock> blocks;
  final String sourceLocator;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'href': href,
    'html': html,
    'plainText': plainText,
    'order': order,
    'blocks': blocks.map((block) => block.toMap()).toList(),
    'sourceLocator': sourceLocator,
  };

  factory XiaoqiDocumentChapter.fromMap(Map<String, dynamic> map) =>
      XiaoqiDocumentChapter(
        id: map['id'] as String? ?? '',
        title: map['title'] as String? ?? '',
        href: map['href'] as String? ?? '',
        html: map['html'] as String? ?? '',
        plainText: map['plainText'] as String? ?? '',
        order: (map['order'] as num?)?.toInt() ?? 0,
        blocks: (map['blocks'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  XiaoqiDocumentBlock.fromMap(item.cast<String, dynamic>()),
            )
            .toList(growable: false),
        sourceLocator: map['sourceLocator'] as String? ?? '',
      );
}

class XiaoqiDocumentBlock {
  const XiaoqiDocumentBlock({
    required this.id,
    required this.kind,
    required this.text,
    this.level = 0,
    this.language = '',
    this.sourceLocator = '',
    this.assetId = '',
    this.attributes = const {},
    this.originalPageLabel,
  });

  final String id;
  final String kind;
  final String text;
  final int level;
  final String language;
  final String sourceLocator;
  final String assetId;
  final Map<String, String> attributes;

  /// Label of the source page introduced by a `page_break` block. Labels are
  /// strings because print editions may use Roman numerals or other schemes.
  final String? originalPageLabel;

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind,
    'text': text,
    'level': level,
    'language': language,
    'sourceLocator': sourceLocator,
    'assetId': assetId,
    'attributes': attributes,
    if (originalPageLabel != null) 'originalPageLabel': originalPageLabel,
  };

  factory XiaoqiDocumentBlock.fromMap(Map<String, dynamic> map) =>
      XiaoqiDocumentBlock(
        id: map['id'] as String? ?? '',
        kind: map['kind'] as String? ?? 'paragraph',
        text: map['text'] as String? ?? '',
        level: (map['level'] as num?)?.toInt() ?? 0,
        language: map['language'] as String? ?? '',
        sourceLocator: map['sourceLocator'] as String? ?? '',
        assetId: map['assetId'] as String? ?? '',
        attributes: (map['attributes'] as Map? ?? const {}).map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
        originalPageLabel:
            map['originalPageLabel']?.toString() ??
            map['original_page_label']?.toString(),
      );
}

class XiaoqiDocumentAsset {
  const XiaoqiDocumentAsset({
    required this.id,
    required this.mimeType,
    required this.bytes,
    this.altText = '',
    this.sourceLocator = '',
  });

  final String id;
  final String mimeType;
  final List<int> bytes;
  final String altText;
  final String sourceLocator;

  Map<String, dynamic> toMap() => {
    'id': id,
    'mimeType': mimeType,
    'bytes': base64Encode(bytes),
    'altText': altText,
    'sourceLocator': sourceLocator,
  };

  factory XiaoqiDocumentAsset.fromMap(Map<String, dynamic> map) =>
      XiaoqiDocumentAsset(
        id: map['id'] as String? ?? '',
        mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
        bytes: base64Decode(map['bytes'] as String? ?? ''),
        altText: map['altText'] as String? ?? '',
        sourceLocator: map['sourceLocator'] as String? ?? '',
      );
}
