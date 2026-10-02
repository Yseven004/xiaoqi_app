import 'dart:convert';

import 'reader_pagination.dart';
import 'note.dart';

enum CapturePlacementKind { unlinked, replacePdfPage, relatedFlowPosition }

enum BookImageImportAction { capture, upload }

enum CaptureInputKind { camera, gallery, legacyUnknown }

extension CaptureInputKindLabels on CaptureInputKind {
  String get storageValue => switch (this) {
    CaptureInputKind.camera => 'camera',
    CaptureInputKind.gallery => 'gallery',
    CaptureInputKind.legacyUnknown => 'legacy_unknown',
  };

  String get displayLabel => switch (this) {
    CaptureInputKind.camera => '拍摄',
    CaptureInputKind.gallery => '相册',
    CaptureInputKind.legacyUnknown => '旧数据',
  };

}

CaptureInputKind captureInputKindFromStorage(String? value) => switch (value) {
  'camera' => CaptureInputKind.camera,
  'gallery' => CaptureInputKind.gallery,
  _ => CaptureInputKind.legacyUnknown,
};

class CapturePlacementContext {
  const CapturePlacementContext({
    required this.sourceId,
    required this.sourceName,
    required this.sourceFormat,
    required this.anchor,
  });

  final int sourceId;
  final String sourceName;
  final String sourceFormat;
  final ReaderAnchor anchor;

  bool get isPdf => sourceFormat == 'pdf' && anchor is PdfReaderAnchor;
}

class CapturePagePlacement {
  const CapturePagePlacement({
    required this.kind,
    this.anchor,
  });

  final CapturePlacementKind kind;
  final ReaderAnchor? anchor;

  bool get isLinked => kind != CapturePlacementKind.unlinked && anchor != null;
}

class CaptureSourceLinkRecord {
  const CaptureSourceLinkRecord({
    required this.id,
    required this.capturePageId,
    required this.targetSourceId,
    required this.targetSourceVersionId,
    required this.anchorKind,
    required this.anchorJson,
    required this.anchorKey,
    required this.mode,
    required this.createdAt,
    required this.updatedAt,
    this.detachedAt,
    this.detachReason = '',
    this.replacesLinkId,
  });

  final int id;
  final int capturePageId;
  final int targetSourceId;
  final String targetSourceVersionId;
  final String anchorKind;
  final String anchorJson;
  final String anchorKey;
  final String mode;
  final String createdAt;
  final String updatedAt;
  final String? detachedAt;
  final String detachReason;
  final int? replacesLinkId;

  factory CaptureSourceLinkRecord.fromMap(Map<String, dynamic> map) {
    return CaptureSourceLinkRecord(
      id: map['id'] as int,
      capturePageId: map['capture_page_id'] as int,
      targetSourceId: map['target_source_id'] as int,
      targetSourceVersionId:
          map['target_source_version_id'] as String? ?? '',
      anchorKind: map['anchor_kind'] as String? ?? '',
      anchorJson: map['anchor_json'] as String? ?? '{}',
      anchorKey: map['anchor_key'] as String? ?? '',
      mode: map['mode'] as String? ?? 'related',
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
      detachedAt: map['detached_at'] as String?,
      detachReason: map['detach_reason'] as String? ?? '',
      replacesLinkId: map['replaces_link_id'] as int?,
    );
  }

  bool get isActive => detachedAt == null || detachedAt!.isEmpty;

  ReaderAnchor? toAnchor() {
    try {
      final json = jsonDecode(anchorJson);
      if (json is! Map) return null;
      final sourceId = targetSourceId.toString();
      if (anchorKind == 'pdf_page') {
        final page = (json['page'] as num?)?.toInt();
        return page == null
            ? null
            : PdfReaderAnchor(sourceId: sourceId, pageNumber: page);
      }
      if (anchorKind == 'flow') {
        final chapterId = json['chapter_id'] as String?;
        if (chapterId == null || chapterId.isEmpty) return null;
        return FlowReaderAnchor(
          sourceId: sourceId,
          chapterId: chapterId,
          blockId: json['block_id'] as String?,
          characterOffset: (json['character_offset'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class BookImageRecognitionEntry {
  const BookImageRecognitionEntry({
    required this.capturePageId,
    required this.batchId,
    required this.pageOrder,
    required this.inputKind,
    this.status = 'captured',
    this.batchStatus = 'processing',
    this.errorMessage = '',
    this.targetSourceName = '',
    this.note,
    this.link,
  });

  final int capturePageId;
  final String batchId;
  final int pageOrder;
  final CaptureInputKind inputKind;
  final String status;
  final String batchStatus;
  final String errorMessage;
  final String targetSourceName;
  final Note? note;
  final CaptureSourceLinkRecord? link;

  String get title {
    final value = note?.title.trim() ?? '';
    return value.isEmpty ? '图片识别文本 #$capturePageId' : value;
  }

  BookImageRecognitionEntry copyWith({String? batchStatus}) {
    return BookImageRecognitionEntry(
      capturePageId: capturePageId,
      batchId: batchId,
      pageOrder: pageOrder,
      inputKind: inputKind,
      status: status,
      batchStatus: batchStatus ?? this.batchStatus,
      errorMessage: errorMessage,
      targetSourceName: targetSourceName,
      note: note,
      link: link,
    );
  }
}

String captureAnchorKind(ReaderAnchor anchor) => switch (anchor) {
  PdfReaderAnchor() => 'pdf_page',
  FlowReaderAnchor() => 'flow',
};

String captureAnchorJson(ReaderAnchor anchor) => switch (anchor) {
  PdfReaderAnchor(:final pageNumber) => jsonEncode({'page': pageNumber}),
  FlowReaderAnchor(
    :final chapterId,
    :final blockId,
    :final characterOffset,
  ) => jsonEncode({
    'chapter_id': chapterId,
    'block_id': blockId,
    'character_offset': characterOffset,
  }),
};

String captureAnchorKey(ReaderAnchor anchor) => switch (anchor) {
  PdfReaderAnchor(:final pageNumber) => 'pdf:$pageNumber',
  FlowReaderAnchor(:final chapterId, :final blockId, :final characterOffset) =>
    'flow:$chapterId:${blockId ?? ''}:$characterOffset',
};

String capturePlacementJson(CapturePagePlacement placement) {
  final anchor = placement.anchor;
  return jsonEncode({
    'kind': placement.kind.name,
    if (anchor != null) ...{
      'source_id': anchor.sourceId,
      'anchor_kind': captureAnchorKind(anchor),
      'anchor_json': jsonDecode(captureAnchorJson(anchor)),
    },
  });
}

CapturePagePlacement? capturePlacementFromJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final value = jsonDecode(raw);
    if (value is! Map) return null;
    final kind = CapturePlacementKind.values.where(
      (item) => item.name == value['kind'],
    ).firstOrNull;
    if (kind == null) return null;
    final anchorKind = value['anchor_kind'] as String?;
    final anchorValue = value['anchor_json'];
    if (anchorKind == null || anchorValue is! Map) {
      return CapturePagePlacement(kind: kind);
    }
    final sourceId = value['source_id'] as String? ?? '';
    ReaderAnchor? anchor;
    if (anchorKind == 'pdf_page') {
      anchor = PdfReaderAnchor(
        sourceId: sourceId,
        pageNumber: (anchorValue['page'] as num?)?.toInt() ?? 1,
      );
    } else if (anchorKind == 'flow') {
      final chapterId = anchorValue['chapter_id'] as String?;
      if (chapterId != null && chapterId.isNotEmpty) {
        anchor = FlowReaderAnchor(
          sourceId: sourceId,
          chapterId: chapterId,
          blockId: anchorValue['block_id'] as String?,
          characterOffset:
              (anchorValue['character_offset'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return CapturePagePlacement(kind: kind, anchor: anchor);
  } catch (_) {
    return null;
  }
}
