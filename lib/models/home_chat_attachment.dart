import 'dart:io';

/// A private local copy attached to a home chat message.
class HomeChatAttachment {
  const HomeChatAttachment({
    required this.id,
    required this.name,
    required this.path,
    required this.mimeType,
    required this.byteLength,
    required this.source,
    this.sourceAssetId,
    this.extractedText = '',
    this.sourceLabel = '',
    this.pageImagePaths = const [],
  });

  final String id;
  final String name;
  final String path;
  final String mimeType;
  final int byteLength;
  final String source;
  final String? sourceAssetId;
  final String extractedText;
  final String sourceLabel;
  final List<String> pageImagePaths;

  bool get isImage => mimeType.startsWith('image/');
  bool get exists => File(path).existsSync();

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'mime_type': mimeType,
    'byte_length': byteLength,
    'source': source,
    'source_asset_id': sourceAssetId,
    'extracted_text': extractedText,
    'source_label': sourceLabel,
    'page_image_paths': pageImagePaths,
  };

  factory HomeChatAttachment.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('附件数据无效');
    return HomeChatAttachment(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      path: raw['path']?.toString() ?? '',
      mimeType: raw['mime_type']?.toString() ?? 'application/octet-stream',
      byteLength: int.tryParse(raw['byte_length']?.toString() ?? '') ?? 0,
      source: raw['source']?.toString() ?? 'file',
      sourceAssetId: raw['source_asset_id']?.toString(),
      extractedText: raw['extracted_text']?.toString() ?? '',
      sourceLabel: raw['source_label']?.toString() ?? '',
      pageImagePaths: raw['page_image_paths'] is List
          ? (raw['page_image_paths'] as List)
                .map((path) => path.toString())
                .toList()
          : const [],
    );
  }

  HomeChatAttachment copyWith({
    String? extractedText,
    String? sourceLabel,
    List<String>? pageImagePaths,
  }) => HomeChatAttachment(
    id: id,
    name: name,
    path: path,
    mimeType: mimeType,
    byteLength: byteLength,
    source: source,
    sourceAssetId: sourceAssetId,
    extractedText: extractedText ?? this.extractedText,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    pageImagePaths: pageImagePaths ?? this.pageImagePaths,
  );
}
