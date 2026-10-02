class AiWebSource {
  const AiWebSource({
    required this.id,
    required this.title,
    required this.finalUrl,
    required this.contentHash,
    required this.fetchedAt,
    required this.snapshotPath,
    this.excerpt = '',
    this.visualSnapshotPath = '',
    this.ownership = 'temporary',
    this.bookSourceId,
    this.sourceVersionId = '',
  });

  final String id;
  final String title;
  final String finalUrl;
  final String contentHash;
  final DateTime fetchedAt;
  final String snapshotPath;
  final String visualSnapshotPath;
  final String excerpt;
  final String ownership;
  final int? bookSourceId;
  final String sourceVersionId;

  AiWebSource copyWith({
    String? ownership,
    int? bookSourceId,
    String? sourceVersionId,
    String? snapshotPath,
    String? visualSnapshotPath,
  }) => AiWebSource(
    id: id,
    title: title,
    finalUrl: finalUrl,
    contentHash: contentHash,
    fetchedAt: fetchedAt,
    snapshotPath: snapshotPath ?? this.snapshotPath,
    visualSnapshotPath: visualSnapshotPath ?? this.visualSnapshotPath,
    excerpt: excerpt,
    ownership: ownership ?? this.ownership,
    bookSourceId: bookSourceId ?? this.bookSourceId,
    sourceVersionId: sourceVersionId ?? this.sourceVersionId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'final_url': finalUrl,
    'content_hash': contentHash,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'snapshot_path': snapshotPath,
    if (visualSnapshotPath.isNotEmpty) 'visual_snapshot_path': visualSnapshotPath,
    'ownership': ownership,
    if (bookSourceId != null) 'book_source_id': bookSourceId,
    if (sourceVersionId.isNotEmpty) 'source_version_id': sourceVersionId,
    if (excerpt.isNotEmpty) 'excerpt': excerpt,
  };

  factory AiWebSource.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid web source');
    return AiWebSource(
      id: raw['id']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      finalUrl: raw['final_url']?.toString() ?? '',
      contentHash: raw['content_hash']?.toString() ?? '',
      fetchedAt:
          DateTime.tryParse(raw['fetched_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      snapshotPath: raw['snapshot_path']?.toString() ?? '',
      visualSnapshotPath: raw['visual_snapshot_path']?.toString() ?? '',
      excerpt: raw['excerpt']?.toString() ?? '',
      ownership: raw['ownership']?.toString() ?? 'temporary',
      bookSourceId: (raw['book_source_id'] as num?)?.toInt(),
      sourceVersionId: raw['source_version_id']?.toString() ?? '',
    );
  }
}
