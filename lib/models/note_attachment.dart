class NoteAttachment {
  const NoteAttachment({
    this.id,
    this.noteId,
    required this.name,
    required this.relativePath,
    required this.kind,
    this.mimeType,
    required this.position,
    required this.createdAt,
  });

  final int? id;
  final int? noteId;
  final String name;
  final String relativePath;
  final String kind;
  final String? mimeType;
  final int position;
  final String createdAt;

  factory NoteAttachment.fromMap(Map<String, Object?> map) {
    return NoteAttachment(
      id: map['id'] as int?,
      noteId: map['note_id'] as int?,
      name: map['name'] as String? ?? '',
      relativePath: map['relative_path'] as String? ?? '',
      kind: map['kind'] as String? ?? 'file',
      mimeType: map['mime_type'] as String?,
      position: map['position'] as int? ?? 0,
      createdAt: map['created_at'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap({int? forNoteId}) => {
    if (id != null) 'id': id,
    'note_id': forNoteId ?? noteId,
    'name': name,
    'relative_path': relativePath,
    'kind': kind,
    'mime_type': mimeType,
    'position': position,
    'created_at': createdAt,
  };

  NoteAttachment copyWith({int? id, int? noteId, int? position}) =>
      NoteAttachment(
        id: id ?? this.id,
        noteId: noteId ?? this.noteId,
        name: name,
        relativePath: relativePath,
        kind: kind,
        mimeType: mimeType,
        position: position ?? this.position,
        createdAt: createdAt,
      );
}
