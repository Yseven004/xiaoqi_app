/// Formats currently accepted by the user-facing book source import flow.
///
/// Legacy source formats remain normalized/readable so existing records are
/// not invalidated when the import scope is narrowed.
const supportedBookSourceFormats = <String>{'pdf', 'epub'};

const supportedBookSourceFileExtensions = <String>['pdf', 'epub'];

class BookSourceRecord {
  const BookSourceRecord({
    required this.id,
    required this.bookId,
    required this.kind,
    required this.displayName,
    required this.filePath,
    required this.fileSize,
    required this.contentHash,
    required this.status,
    this.format = 'pdf',
    this.isPrimary = false,
    this.catalogStatus = 'not_started',
    this.catalogSourceKind = '',
    this.catalogJson = '[]',
    this.catalogUpdatedAt = '',
    this.catalogParserVersion = 0,
    this.catalogRunId = '',
    this.originUri = '',
    this.canonicalUri = '',
    this.capturedAt = '',
    this.packageManifestPath = '',
    this.sourceVersionId = '',
    this.documentParserVersion = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final int bookId;
  final String kind;
  final String displayName;
  final String filePath;
  final int fileSize;
  final String contentHash;
  final String status;
  final String format;
  final bool isPrimary;
  final String catalogStatus;
  final String catalogSourceKind;
  final String catalogJson;
  final String catalogUpdatedAt;
  final int catalogParserVersion;
  final String catalogRunId;
  final String originUri;
  final String canonicalUri;
  final String capturedAt;
  final String packageManifestPath;
  final String sourceVersionId;
  final int documentParserVersion;
  final String createdAt;
  final String updatedAt;

  factory BookSourceRecord.fromMap(Map<String, dynamic> map) {
    final displayName = map['display_name'] as String? ?? '';
    final filePath = map['file_path'] as String? ?? '';
    return BookSourceRecord(
      id: map['id'] as int,
      bookId: map['book_id'] as int,
      kind: map['kind'] as String? ?? 'book_file',
      displayName: displayName,
      filePath: filePath,
      fileSize: map['file_size'] as int? ?? 0,
      contentHash: map['content_hash'] as String? ?? '',
      status: map['status'] as String? ?? 'ready',
      format:
          (map['format'] as String? ??
                  inferBookSourceFormat(displayName, filePath))
              .toLowerCase(),
      isPrimary: (map['is_primary'] as num?)?.toInt() == 1,
      catalogStatus: map['catalog_status'] as String? ?? 'not_started',
      catalogSourceKind: map['catalog_source_kind'] as String? ?? '',
      catalogJson: map['catalog_json'] as String? ?? '[]',
      catalogUpdatedAt: map['catalog_updated_at'] as String? ?? '',
      catalogParserVersion: map['catalog_parser_version'] as int? ?? 0,
      catalogRunId: map['catalog_run_id'] as String? ?? '',
      originUri: map['origin_uri'] as String? ?? '',
      canonicalUri: map['canonical_uri'] as String? ?? '',
      capturedAt: map['captured_at'] as String? ?? '',
      packageManifestPath: map['package_manifest_path'] as String? ?? '',
      sourceVersionId: map['source_version_id'] as String? ?? '',
      documentParserVersion: map['document_parser_version'] as int? ?? 0,
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
    );
  }
}

String inferBookSourceFormat(String displayName, [String filePath = '']) {
  final candidate = displayName.trim().isNotEmpty ? displayName : filePath;
  final dot = candidate.lastIndexOf('.');
  if (dot < 0 || dot == candidate.length - 1) return 'pdf';
  return normalizeBookSourceFormat(candidate.substring(dot + 1));
}

String normalizeBookSourceFormat(String value) {
  switch (value.trim().toLowerCase()) {
    case 'md':
    case 'markdown':
      return 'markdown';
    case 'htm':
    case 'html':
      return 'html';
    default:
      return value.trim().toLowerCase();
  }
}

class BookSourceImportResult {
  const BookSourceImportResult({
    required this.source,
    required this.reusedExisting,
  });

  final BookSourceRecord source;
  final bool reusedExisting;
}
