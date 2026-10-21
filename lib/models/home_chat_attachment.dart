import 'dart:io';
import 'chat_annotation.dart';

/// A private local copy attached to a home chat message.
class HomeChatAttachment {
  static const Object _unchanged = Object();

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
    this.drawingDraftPath,
    this.drawingDraftScope,
    this.remoteAttachmentId,
    this.contentHash,
    this.preparationCoverage = '',
    this.preparationPhase = '',
    this.preparationPageCount,
    this.preparationCompletedPages,
    this.preparationExpiresAt,
    this.originalImagePath,
    this.originalImageName,
    this.annotationImagePath,
    this.imageAnnotations = const [],
    this.annotationSnapshotDirty = false,
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
  final String? drawingDraftPath;
  final String? drawingDraftScope;
  final String? remoteAttachmentId;
  final String? contentHash;
  final String preparationCoverage;
  final String preparationPhase;
  final int? preparationPageCount;
  final int? preparationCompletedPages;
  final DateTime? preparationExpiresAt;
  final String? originalImagePath;
  final String? originalImageName;
  final String? annotationImagePath;
  final List<ChatAnnotation> imageAnnotations;
  final bool annotationSnapshotDirty;

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
    'drawing_draft_path': drawingDraftPath,
    'drawing_draft_scope': drawingDraftScope,
    'remote_attachment_id': remoteAttachmentId,
    'content_hash': contentHash,
    'preparation_coverage': preparationCoverage,
    'preparation_phase': preparationPhase,
    'preparation_page_count': preparationPageCount,
    'preparation_completed_pages': preparationCompletedPages,
    'preparation_expires_at': preparationExpiresAt?.toUtc().toIso8601String(),
    if (originalImagePath != null) 'original_image_path': originalImagePath,
    if (originalImageName != null) 'original_image_name': originalImageName,
    if (annotationImagePath != null)
      'annotation_image_path': annotationImagePath,
    if (imageAnnotations.isNotEmpty)
      'image_annotations': imageAnnotations.map((a) => a.toJson()).toList(),
    if (annotationSnapshotDirty) 'annotation_snapshot_dirty': true,
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
      drawingDraftPath: raw['drawing_draft_path']?.toString(),
      drawingDraftScope: raw['drawing_draft_scope']?.toString(),
      remoteAttachmentId: raw['remote_attachment_id']?.toString(),
      contentHash: raw['content_hash']?.toString(),
      preparationCoverage: raw['preparation_coverage']?.toString() ?? '',
      preparationPhase: raw['preparation_phase']?.toString() ?? '',
      preparationPageCount: int.tryParse(
        raw['preparation_page_count']?.toString() ?? '',
      ),
      preparationCompletedPages: int.tryParse(
        raw['preparation_completed_pages']?.toString() ?? '',
      ),
      preparationExpiresAt: DateTime.tryParse(
        raw['preparation_expires_at']?.toString() ?? '',
      ),
      originalImagePath: raw['original_image_path'] as String?,
      originalImageName: raw['original_image_name'] as String?,
      annotationImagePath: raw['annotation_image_path'] as String?,
      imageAnnotations: raw['image_annotations'] is List
          ? (raw['image_annotations'] as List)
                .map(ChatAnnotation.fromJson)
                .toList()
          : const [],
      annotationSnapshotDirty: raw['annotation_snapshot_dirty'] == true,
    );
  }

  HomeChatAttachment copyWith({
    String? path,
    int? byteLength,
    String? extractedText,
    String? sourceLabel,
    List<String>? pageImagePaths,
    Object? drawingDraftPath = _unchanged,
    Object? drawingDraftScope = _unchanged,
    Object? remoteAttachmentId = _unchanged,
    String? contentHash,
    String? preparationCoverage,
    String? preparationPhase,
    int? preparationPageCount,
    int? preparationCompletedPages,
    DateTime? preparationExpiresAt,
    List<ChatAnnotation>? imageAnnotations,
    bool? annotationSnapshotDirty,
  }) => HomeChatAttachment(
    id: id,
    name: name,
    path: path ?? this.path,
    mimeType: mimeType,
    byteLength: byteLength ?? this.byteLength,
    source: source,
    sourceAssetId: sourceAssetId,
    extractedText: extractedText ?? this.extractedText,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    pageImagePaths: pageImagePaths ?? this.pageImagePaths,
    drawingDraftPath: identical(drawingDraftPath, _unchanged)
        ? this.drawingDraftPath
        : drawingDraftPath as String?,
    drawingDraftScope: identical(drawingDraftScope, _unchanged)
        ? this.drawingDraftScope
        : drawingDraftScope as String?,
    remoteAttachmentId: identical(remoteAttachmentId, _unchanged)
        ? this.remoteAttachmentId
        : remoteAttachmentId as String?,
    contentHash: contentHash ?? this.contentHash,
    preparationCoverage: preparationCoverage ?? this.preparationCoverage,
    preparationPhase: preparationPhase ?? this.preparationPhase,
    preparationPageCount: preparationPageCount ?? this.preparationPageCount,
    preparationCompletedPages:
        preparationCompletedPages ?? this.preparationCompletedPages,
    preparationExpiresAt: preparationExpiresAt ?? this.preparationExpiresAt,
    originalImagePath: originalImagePath,
    originalImageName: originalImageName,
    annotationImagePath: annotationImagePath,
    imageAnnotations: imageAnnotations ?? this.imageAnnotations,
    annotationSnapshotDirty:
        annotationSnapshotDirty ?? this.annotationSnapshotDirty,
  );
}
