import 'dart:convert';

import 'xiaoqi_document.dart';

enum ReaderPaginationMode { horizontal, vertical }

extension ReaderPaginationModeLabels on ReaderPaginationMode {
  String get label => switch (this) {
    ReaderPaginationMode.horizontal => '左右平移',
    ReaderPaginationMode.vertical => '上下滑动',
  };
}

/// A stable position in a source. Screen-page indexes are intentionally not
/// stored here because reflowable documents change pagination with the viewport
/// and text scale.
sealed class ReaderAnchor {
  const ReaderAnchor({required this.sourceId});

  final String sourceId;
}

final class PdfReaderAnchor extends ReaderAnchor {
  const PdfReaderAnchor({required super.sourceId, required this.pageNumber});

  final int pageNumber;

  @override
  bool operator ==(Object other) =>
      other is PdfReaderAnchor &&
      other.sourceId == sourceId &&
      other.pageNumber == pageNumber;

  @override
  int get hashCode => Object.hash(sourceId, pageNumber);
}

final class FlowReaderAnchor extends ReaderAnchor {
  const FlowReaderAnchor({
    required super.sourceId,
    required this.chapterId,
    this.blockId,
    this.characterOffset = 0,
  });

  final String chapterId;
  final String? blockId;
  final int characterOffset;

  @override
  bool operator ==(Object other) =>
      other is FlowReaderAnchor &&
      other.sourceId == sourceId &&
      other.chapterId == chapterId &&
      other.blockId == blockId &&
      other.characterOffset == characterOffset;

  @override
  int get hashCode =>
      Object.hash(sourceId, chapterId, blockId, characterOffset);
}

String readerAnchorJson(ReaderAnchor anchor) => switch (anchor) {
  PdfReaderAnchor(:final pageNumber) => jsonEncode({
    'kind': 'pdf',
    'source_id': anchor.sourceId,
    'page': pageNumber,
  }),
  FlowReaderAnchor(
    :final chapterId,
    :final blockId,
    :final characterOffset,
  ) => jsonEncode({
    'kind': 'flow',
    'source_id': anchor.sourceId,
    'chapter_id': chapterId,
    'block_id': blockId,
    'character_offset': characterOffset,
  }),
};

ReaderAnchor? readerAnchorFromJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final value = jsonDecode(raw);
    if (value is! Map) return null;
    final sourceId = value['source_id'] as String?;
    if (sourceId == null || sourceId.isEmpty) return null;
    if (value['kind'] == 'pdf') {
      final page = (value['page'] as num?)?.toInt();
      return page == null
          ? null
          : PdfReaderAnchor(sourceId: sourceId, pageNumber: page);
    }
    if (value['kind'] == 'flow') {
      final chapterId = value['chapter_id'] as String?;
      return chapterId == null || chapterId.isEmpty
          ? null
          : FlowReaderAnchor(
              sourceId: sourceId,
              chapterId: chapterId,
              blockId: value['block_id'] as String?,
              characterOffset:
                  (value['character_offset'] as num?)?.toInt() ?? 0,
            );
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Progress exposed by a reader backend. The generated screen page is always
/// available after pagination; original page fields are only populated when
/// the source contains explicit page markers.
class ReaderPaginationProgress {
  const ReaderPaginationProgress({
    required this.currentScreenPage,
    required this.screenPageCount,
    this.originalPageLabel,
    this.originalPageCount,
  });

  final int currentScreenPage;
  final int screenPageCount;
  final String? originalPageLabel;
  final int? originalPageCount;

  bool get hasOriginalPagination =>
      originalPageCount != null && originalPageCount! > 0;
}

/// A renderable portion of an original document block.
///
/// The original block remains the source of truth. A slice only records the
/// range shown on one screen page.
class ReaderBlockSlice {
  const ReaderBlockSlice({
    required this.block,
    required this.text,
    this.startOffset = 0,
    this.endOffset,
    this.tableRows,
    this.continuation = false,
  });

  final XiaoqiDocumentBlock block;
  final String text;
  final int startOffset;
  final int? endOffset;
  final List<List<String>>? tableRows;
  final bool continuation;
}

class ReaderPageSlice {
  const ReaderPageSlice({
    required this.chapterId,
    required this.chapterTitle,
    required this.blocks,
    this.showChapterTitle = false,
    this.mayOverflow = false,
    this.originalPageLabel,
  });

  final String chapterId;
  final String chapterTitle;
  final List<ReaderBlockSlice> blocks;
  final bool showChapterTitle;
  final bool mayOverflow;
  final String? originalPageLabel;
}
