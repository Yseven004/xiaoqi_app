class Notebook {
  const Notebook({
    this.id,
    required this.name,
    this.bookId,
    this.isDefault = false,
    this.category = '默认分类',
    this.description = '',
    this.coverIndex = 0,
    this.coverPath = '',
    this.homeSlot,
    this.isPinned = false,
    this.pinnedAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.deletedHomeSlot,
    this.deletedWasPinned = false,
    this.deletedPinnedAt,
    this.isArchived = false,
    this.isDeleted = false,
    this.noteCount = 0,
  });

  final int? id;
  final String name;
  final int? bookId;
  final bool isDefault;
  final String category;
  final String description;
  final int coverIndex;
  final String coverPath;
  final int? homeSlot;
  final bool isPinned;
  final String? pinnedAt;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;
  final int? deletedHomeSlot;
  final bool deletedWasPinned;
  final String? deletedPinnedAt;
  final bool isArchived;
  final bool isDeleted;
  final int noteCount;

  bool get isActive => !isArchived && !isDeleted;
  bool get showsOnHome => homeSlot != null && isActive;

  factory Notebook.fromMap(Map<String, dynamic> map) {
    return Notebook(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '未命名笔记本',
      bookId: map['book_id'] as int?,
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      category: map['category'] as String? ?? '默认分类',
      description: map['description'] as String? ?? '',
      coverIndex: map['cover_index'] as int? ?? 0,
      coverPath: map['cover_path'] as String? ?? '',
      homeSlot: map['home_slot'] as int?,
      isPinned: (map['is_pinned'] as int? ?? 0) == 1,
      pinnedAt: map['pinned_at'] as String?,
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
      deletedAt: map['deleted_at'] as String?,
      deletedHomeSlot: map['deleted_home_slot'] as int?,
      deletedWasPinned: (map['deleted_was_pinned'] as int? ?? 0) == 1,
      deletedPinnedAt: map['deleted_pinned_at'] as String?,
      isArchived: (map['is_archived'] as int? ?? 0) == 1,
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
      noteCount: map['note_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null && id! > 0) 'id': id,
      'name': name,
      'book_id': bookId,
      'is_default': isDefault ? 1 : 0,
      'category': category,
      'description': description,
      'cover_index': coverIndex,
      'cover_path': coverPath,
      'home_slot': homeSlot,
      'is_pinned': isPinned ? 1 : 0,
      'pinned_at': pinnedAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
      'deleted_home_slot': deletedHomeSlot,
      'deleted_was_pinned': deletedWasPinned ? 1 : 0,
      'deleted_pinned_at': deletedPinnedAt,
      'is_archived': isArchived ? 1 : 0,
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  Notebook copyWith({
    int? id,
    String? name,
    Object? bookId = _sentinel,
    bool? isDefault,
    String? category,
    String? description,
    int? coverIndex,
    String? coverPath,
    Object? homeSlot = _sentinel,
    bool? isPinned,
    Object? pinnedAt = _sentinel,
    String? createdAt,
    String? updatedAt,
    Object? deletedAt = _sentinel,
    Object? deletedHomeSlot = _sentinel,
    bool? deletedWasPinned,
    Object? deletedPinnedAt = _sentinel,
    bool? isArchived,
    bool? isDeleted,
    int? noteCount,
  }) {
    return Notebook(
      id: id ?? this.id,
      name: name ?? this.name,
      bookId: identical(bookId, _sentinel) ? this.bookId : bookId as int?,
      isDefault: isDefault ?? this.isDefault,
      category: category ?? this.category,
      description: description ?? this.description,
      coverIndex: coverIndex ?? this.coverIndex,
      coverPath: coverPath ?? this.coverPath,
      homeSlot: identical(homeSlot, _sentinel)
          ? this.homeSlot
          : homeSlot as int?,
      isPinned: isPinned ?? this.isPinned,
      pinnedAt: identical(pinnedAt, _sentinel)
          ? this.pinnedAt
          : pinnedAt as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: identical(deletedAt, _sentinel)
          ? this.deletedAt
          : deletedAt as String?,
      deletedHomeSlot: identical(deletedHomeSlot, _sentinel)
          ? this.deletedHomeSlot
          : deletedHomeSlot as int?,
      deletedWasPinned: deletedWasPinned ?? this.deletedWasPinned,
      deletedPinnedAt: identical(deletedPinnedAt, _sentinel)
          ? this.deletedPinnedAt
          : deletedPinnedAt as String?,
      isArchived: isArchived ?? this.isArchived,
      isDeleted: isDeleted ?? this.isDeleted,
      noteCount: noteCount ?? this.noteCount,
    );
  }
}

const Object _sentinel = Object();
