const Object _noteSentinel = Object();

class Note {
  final int? id;
  final int? notebookId;
  final String type;
  final String title;
  final String content;
  final String contentDelta;
  final String sourceType;
  final String photoPath;
  final String originalPhotoPath;
  final String pdfPath;
  final String bookName;
  final String bookPage;
  final int? bookId;
  final int? capturePageId;
  final int? parentNoteId;
  final String? annotationsJson;
  final String? pageGroupId;
  final int? pageGroupIndex;
  final String? captureBatchId;
  final String? groupId;
  final int? groupIndex;
  final String? capturedAt;
  final int? captureSequence;
  final bool isDoublePage;
  final String sourcePhotoPath;
  final String createdAt;
  final String updatedAt;
  final bool isPinned;
  final String? pinnedAt;
  final int isDeleted;

  const Note({
    this.id,
    this.notebookId,
    required this.type,
    this.title = '',
    this.content = '',
    this.contentDelta = '',
    this.sourceType = 'text_note',
    this.photoPath = '',
    this.originalPhotoPath = '',
    this.pdfPath = '',
    this.bookName = '',
    this.bookPage = '',
    this.bookId,
    this.capturePageId,
    this.parentNoteId,
    this.annotationsJson,
    this.pageGroupId,
    this.pageGroupIndex,
    this.captureBatchId,
    this.groupId,
    this.groupIndex,
    this.capturedAt,
    this.captureSequence,
    this.isDoublePage = false,
    this.sourcePhotoPath = '',
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
    this.pinnedAt,
    this.isDeleted = 0,
  });

  factory Note.fromMap(Map<String, dynamic> map) {
    final type = map['type'] as String? ?? 'text';
    return Note(
      id: map['id'] as int?,
      notebookId: map['notebook_id'] as int?,
      type: type,
      title: map['title'] as String? ?? '',
      content: map['content'] as String? ?? '',
      contentDelta: map['content_delta'] as String? ?? '',
      sourceType:
          map['source_type'] as String? ??
          (type == 'photo' || type == 'annotated_note'
              ? 'photo_analysis'
              : type == 'ai_generated'
              ? 'ai_generated'
              : 'text_note'),
      photoPath: map['photo_path'] as String? ?? '',
      originalPhotoPath:
          map['original_photo_path'] as String? ??
          map['photo_path'] as String? ??
          '',
      pdfPath: map['pdf_path'] as String? ?? '',
      bookName: map['book_name'] as String? ?? '',
      bookPage: map['book_page'] as String? ?? '',
      bookId: map['book_id'] as int?,
      capturePageId: map['capture_page_id'] as int?,
      parentNoteId: map['parent_note_id'] as int?,
      annotationsJson: map['annotations_json'] as String?,
      pageGroupId:
          (map['group_id'] as String?) ?? (map['page_group_id'] as String?),
      pageGroupIndex:
          (map['group_index'] as int?) ?? (map['page_group_index'] as int?),
      captureBatchId: map['capture_batch_id'] as String?,
      groupId:
          (map['group_id'] as String?) ?? (map['page_group_id'] as String?),
      groupIndex:
          (map['group_index'] as int?) ?? (map['page_group_index'] as int?),
      capturedAt: map['captured_at'] as String?,
      captureSequence: map['capture_sequence'] as int?,
      isDoublePage: (map['is_double_page'] as int? ?? 0) == 1,
      sourcePhotoPath: map['source_photo_path'] as String? ?? '',
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
      isPinned: (map['is_pinned'] as int? ?? 0) == 1,
      pinnedAt: map['pinned_at'] as String?,
      isDeleted: map['is_deleted'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null && id! > 0) 'id': id,
      'notebook_id': notebookId,
      'type': type,
      'title': title,
      'content': content,
      'content_delta': contentDelta,
      'source_type': sourceType,
      'photo_path': photoPath,
      'original_photo_path': originalPhotoPath,
      'pdf_path': pdfPath,
      'book_name': bookName,
      'book_page': bookPage,
      'book_id': bookId,
      'capture_page_id': capturePageId,
      'parent_note_id': parentNoteId,
      if (annotationsJson != null) 'annotations_json': annotationsJson,
      'page_group_id': pageGroupId,
      'page_group_index': pageGroupIndex,
      'capture_batch_id': captureBatchId,
      'group_id': groupId ?? pageGroupId,
      'group_index': groupIndex ?? pageGroupIndex,
      'captured_at': capturedAt ?? createdAt,
      'capture_sequence': captureSequence,
      'is_double_page': isDoublePage ? 1 : 0,
      'source_photo_path': sourcePhotoPath,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'is_pinned': isPinned ? 1 : 0,
      'pinned_at': pinnedAt,
      'is_deleted': isDeleted,
    };
  }

  Note copyWith({
    int? id,
    int? notebookId,
    String? type,
    String? title,
    String? content,
    String? contentDelta,
    String? sourceType,
    String? photoPath,
    String? originalPhotoPath,
    String? pdfPath,
    String? bookName,
    String? bookPage,
    int? bookId,
    int? capturePageId,
    int? parentNoteId,
    String? annotationsJson,
    String? pageGroupId,
    int? pageGroupIndex,
    String? captureBatchId,
    String? groupId,
    int? groupIndex,
    String? capturedAt,
    int? captureSequence,
    bool? isDoublePage,
    String? sourcePhotoPath,
    String? createdAt,
    String? updatedAt,
    bool? isPinned,
    Object? pinnedAt = _noteSentinel,
    int? isDeleted,
    bool clearBookAssociation = false,
    bool clearId = false,
  }) {
    return Note(
      id: clearId ? null : id ?? this.id,
      notebookId: notebookId ?? this.notebookId,
      type: type ?? this.type,
      title: title ?? this.title,
      content: content ?? this.content,
      contentDelta: contentDelta ?? this.contentDelta,
      sourceType: sourceType ?? this.sourceType,
      photoPath: photoPath ?? this.photoPath,
      originalPhotoPath: originalPhotoPath ?? this.originalPhotoPath,
      pdfPath: pdfPath ?? this.pdfPath,
      bookName: clearBookAssociation ? '' : bookName ?? this.bookName,
      bookPage: bookPage ?? this.bookPage,
      bookId: clearBookAssociation ? null : bookId ?? this.bookId,
      capturePageId: capturePageId ?? this.capturePageId,
      parentNoteId: parentNoteId ?? this.parentNoteId,
      annotationsJson: annotationsJson ?? this.annotationsJson,
      pageGroupId: pageGroupId ?? this.pageGroupId,
      pageGroupIndex: pageGroupIndex ?? this.pageGroupIndex,
      captureBatchId: captureBatchId ?? this.captureBatchId,
      groupId: groupId ?? this.groupId,
      groupIndex: groupIndex ?? this.groupIndex,
      capturedAt: capturedAt ?? this.capturedAt,
      captureSequence: captureSequence ?? this.captureSequence,
      isDoublePage: isDoublePage ?? this.isDoublePage,
      sourcePhotoPath: sourcePhotoPath ?? this.sourcePhotoPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isPinned: isPinned ?? this.isPinned,
      pinnedAt: identical(pinnedAt, _noteSentinel)
          ? this.pinnedAt
          : pinnedAt as String?,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  @override
  String toString() {
    return 'Note(id: $id, notebookId: $notebookId, type: $type, '
        'title: $title, content: $content, '
        'photoPath: $photoPath, originalPhotoPath: $originalPhotoPath, '
        'bookName: $bookName, bookPage: $bookPage, '
        'parentNoteId: $parentNoteId, pageGroupId: $pageGroupId, '
        'pageGroupIndex: $pageGroupIndex, isDoublePage: $isDoublePage, '
        'createdAt: $createdAt, '
        'updatedAt: $updatedAt, isPinned: $isPinned, '
        'isDeleted: $isDeleted)';
  }
}
