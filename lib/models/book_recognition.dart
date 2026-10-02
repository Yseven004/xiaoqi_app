import 'dart:convert';

enum BookMatchConfidence { high, medium, low, unknown }

/// A verified, displayable entry in a book's table of contents.
class BookTocEntry {
  const BookTocEntry({
    required this.title,
    this.level = 1,
    this.index = 0,
    this.sourceId = '',
  });

  final String title;
  final int level;
  final int index;
  final String sourceId;

  factory BookTocEntry.fromJson(Map<String, dynamic> json) => BookTocEntry(
    title: (json['title'] ?? '').toString().trim(),
    level: _asInt(json['level'], fallback: 1).clamp(1, 8),
    index: _asInt(json['index'] ?? json['chapter_index']),
    sourceId: (json['source_id'] ?? json['sourceId'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'level': level,
    'index': index,
    'source_id': sourceId,
  };
}

/// A link supplied by a catalogue. The label keeps the destination clear
/// instead of implying that XiaoQi hosts the linked material.
class BookExternalLink {
  const BookExternalLink({
    required this.label,
    required this.url,
    this.provider = '',
  });

  final String label;
  final String url;
  final String provider;

  factory BookExternalLink.fromJson(Map<String, dynamic> json) =>
      BookExternalLink(
        label: (json['label'] ?? '').toString().trim(),
        url: (json['url'] ?? '').toString().trim(),
        provider: (json['provider'] ?? '').toString().trim(),
      );

  Map<String, dynamic> toJson() => {
    'label': label,
    'url': url,
    'provider': provider,
  };
}

/// Minimal source lineage retained with merged catalogue metadata. Full
/// provider responses are intentionally not stored in the user's database.
class BookMetadataSource {
  const BookMetadataSource({
    required this.provider,
    this.sourceId = '',
    this.sourceUrls = const [],
    this.fields = const [],
    this.fetchedAt = '',
    this.exactIsbnMatch = false,
  });

  final String provider;
  final String sourceId;
  final List<String> sourceUrls;
  final List<String> fields;
  final String fetchedAt;
  final bool exactIsbnMatch;

  factory BookMetadataSource.fromJson(Map<String, dynamic> json) =>
      BookMetadataSource(
        provider: (json['provider'] ?? '').toString(),
        sourceId: (json['source_id'] ?? json['sourceId'] ?? '').toString(),
        sourceUrls: _stringList(json['source_urls'] ?? json['sourceUrls']),
        fields: _stringList(json['fields']),
        fetchedAt: (json['fetched_at'] ?? json['fetchedAt'] ?? '').toString(),
        exactIsbnMatch:
            json['exact_isbn_match'] == true || json['exactIsbnMatch'] == true,
      );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'source_id': sourceId,
    'source_urls': sourceUrls,
    'fields': fields,
    'fetched_at': fetchedAt,
    'exact_isbn_match': exactIsbnMatch,
  };
}

class BookMetadataConflict {
  const BookMetadataConflict({
    required this.field,
    required this.primaryValue,
    required this.alternateValue,
    required this.alternateProvider,
  });

  final String field;
  final String primaryValue;
  final String alternateValue;
  final String alternateProvider;
}

/// The direct ISBN plugin result. [book] is always non-null so the scanner can
/// safely continue to manual confirmation after a network miss.
class BookMetadataLookupResult {
  const BookMetadataLookupResult({
    required this.book,
    required this.exactIsbnMatch,
    this.conflicts = const [],
    this.missingFields = const [],
    this.retryableError,
    this.diagnostics = const {},
  });

  final BookRecord book;
  final bool exactIsbnMatch;
  final List<BookMetadataConflict> conflicts;
  final List<String> missingFields;
  final String? retryableError;
  final Map<String, Object?> diagnostics;

  bool get needsManualReview =>
      !exactIsbnMatch || conflicts.isNotEmpty || book.title == '待确认书籍';
}

int _asInt(Object? value, {int fallback = 0}) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<T> _jsonList<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) {
  if (raw is! String || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((item) => fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

class BookRecord {
  const BookRecord({
    this.id,
    required this.title,
    this.authors = const [],
    this.publisher = '',
    this.edition = '',
    this.publishedDate = '',
    this.description = '',
    this.tableOfContents = const [],
    this.externalLinks = const [],
    this.metadataSources = const [],
    this.metadataUpdatedAt = '',
    this.isbn10 = '',
    this.isbn13 = '',
    this.coverUrl = '',
    this.coverPath = '',
    this.coverType = 'auto',
    this.coverTemplate = 'mist',
    this.source = 'mock',
    this.sourceId = '',
    this.isCustom = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final int? id;
  final String title;
  final List<String> authors;
  final String publisher;
  final String edition;
  final String publishedDate;
  final String description;
  final List<BookTocEntry> tableOfContents;
  final List<BookExternalLink> externalLinks;
  final List<BookMetadataSource> metadataSources;
  final String metadataUpdatedAt;
  final String isbn10;
  final String isbn13;
  final String coverUrl;
  final String coverPath;

  /// auto resolves to the catalogue cover when available, then the local
  /// fallback. Other values are official, uploaded, template, or ai.
  final String coverType;
  final String coverTemplate;
  final String source;
  final String sourceId;
  final bool isCustom;
  final String createdAt;
  final String updatedAt;

  String get authorLabel => authors.join('、');

  String get metadataLabel => [
    authorLabel,
    publisher,
    edition.isNotEmpty ? edition : publishedDate,
  ].where((value) => value.trim().isNotEmpty).join(' · ');

  String get canonicalKey {
    final isbn = isbn13.isNotEmpty ? isbn13 : isbn10;
    if (isbn.isNotEmpty) return 'isbn:$isbn';
    return [
      title,
      authorLabel,
      publisher,
      edition,
    ].map((value) => value.trim().toLowerCase()).join('|');
  }

  factory BookRecord.fromMap(Map<String, dynamic> map) {
    final authors = (map['authors'] as String? ?? '')
        .split('\u001f')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return BookRecord(
      id: map['id'] as int?,
      title: map['title'] as String? ?? '',
      authors: authors,
      publisher: map['publisher'] as String? ?? '',
      edition: map['edition'] as String? ?? '',
      publishedDate: map['published_date'] as String? ?? '',
      description: map['description'] as String? ?? '',
      tableOfContents: _jsonList(map['toc_json'], BookTocEntry.fromJson),
      externalLinks: _jsonList(
        map['external_links_json'],
        BookExternalLink.fromJson,
      ),
      metadataSources: _jsonList(
        map['metadata_sources_json'],
        BookMetadataSource.fromJson,
      ),
      metadataUpdatedAt: map['metadata_updated_at'] as String? ?? '',
      isbn10: map['isbn_10'] as String? ?? '',
      isbn13: map['isbn_13'] as String? ?? '',
      coverUrl: map['cover_url'] as String? ?? '',
      coverPath: map['cover_path'] as String? ?? '',
      coverType: map['cover_type'] as String? ?? 'auto',
      coverTemplate: map['cover_template'] as String? ?? 'mist',
      source: map['source'] as String? ?? 'mock',
      sourceId: map['source_id'] as String? ?? '',
      isCustom: (map['is_custom'] as int? ?? 0) == 1,
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'canonical_key': canonicalKey,
    'title': title.trim(),
    'authors': authors.map((value) => value.trim()).join('\u001f'),
    'publisher': publisher.trim(),
    'edition': edition.trim(),
    'published_date': publishedDate.trim(),
    'description': description.trim(),
    'toc_json': jsonEncode(
      tableOfContents.map((item) => item.toJson()).toList(),
    ),
    'external_links_json': jsonEncode(
      externalLinks.map((item) => item.toJson()).toList(),
    ),
    'metadata_sources_json': jsonEncode(
      metadataSources.map((item) => item.toJson()).toList(),
    ),
    'metadata_updated_at': metadataUpdatedAt.trim(),
    'isbn_10': isbn10.trim(),
    'isbn_13': isbn13.trim(),
    'cover_url': coverUrl.trim(),
    'cover_path': coverPath.trim(),
    'cover_type': coverType.trim().isEmpty ? 'auto' : coverType.trim(),
    'cover_template': coverTemplate.trim().isEmpty
        ? 'mist'
        : coverTemplate.trim(),
    'source': source,
    'source_id': sourceId,
    'is_custom': isCustom ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  BookRecord copyWith({
    int? id,
    String? title,
    List<String>? authors,
    String? publisher,
    String? edition,
    String? publishedDate,
    String? description,
    List<BookTocEntry>? tableOfContents,
    List<BookExternalLink>? externalLinks,
    List<BookMetadataSource>? metadataSources,
    String? metadataUpdatedAt,
    String? isbn10,
    String? isbn13,
    String? coverUrl,
    String? coverPath,
    String? coverType,
    String? coverTemplate,
    String? source,
    String? sourceId,
    bool? isCustom,
    String? createdAt,
    String? updatedAt,
  }) {
    return BookRecord(
      id: id ?? this.id,
      title: title ?? this.title,
      authors: authors ?? this.authors,
      publisher: publisher ?? this.publisher,
      edition: edition ?? this.edition,
      publishedDate: publishedDate ?? this.publishedDate,
      description: description ?? this.description,
      tableOfContents: tableOfContents ?? this.tableOfContents,
      externalLinks: externalLinks ?? this.externalLinks,
      metadataSources: metadataSources ?? this.metadataSources,
      metadataUpdatedAt: metadataUpdatedAt ?? this.metadataUpdatedAt,
      isbn10: isbn10 ?? this.isbn10,
      isbn13: isbn13 ?? this.isbn13,
      coverUrl: coverUrl ?? this.coverUrl,
      coverPath: coverPath ?? this.coverPath,
      coverType: coverType ?? this.coverType,
      coverTemplate: coverTemplate ?? this.coverTemplate,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      isCustom: isCustom ?? this.isCustom,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class BookCandidate {
  const BookCandidate({
    required this.book,
    required this.confidence,
    required this.matchLabel,
    this.score = 0,
    this.fromHistory = false,
  });

  final BookRecord book;
  final BookMatchConfidence confidence;
  final String matchLabel;
  final double score;
  final bool fromHistory;

  /// Short, user-facing account of how this candidate was found.
  ///
  /// The backend usually provides a more specific [matchLabel]. Keeping the
  /// fallback here prevents the UI from exposing an empty status when an older
  /// or degraded endpoint omits it.
  String get verificationLabel {
    final explicitLabel = matchLabel.trim();
    if (explicitLabel.isNotEmpty) return explicitLabel;
    return switch (confidence) {
      BookMatchConfidence.high => '书目已核对',
      BookMatchConfidence.medium => '可能是这一版',
      BookMatchConfidence.low => '根据内容推测',
      BookMatchConfidence.unknown => '资料待核对',
    };
  }

  /// Explains what the confidence means without presenting the model score as
  /// a probability or asking the user to understand a technical source name.
  String get verificationGuidance {
    if (book.title.trim().isEmpty || book.title.trim() == '待确认书籍') {
      return '当前只确认了书码，请补充书名并核对版本';
    }
    if (fromHistory) return '来自你以前确认过的书库记录';
    return switch (confidence) {
      BookMatchConfidence.high =>
        book.isbn13.trim().isNotEmpty || book.isbn10.trim().isNotEmpty
            ? 'ISBN 与这版书目一致，保存前仍可核对作者和出版社'
            : '书名与作者等资料高度一致，保存前请核对版本',
      BookMatchConfidence.medium => '书名或作者相似，请核对出版社和版本',
      BookMatchConfidence.low => '仅根据正文或相似资料推测，请逐项核对',
      BookMatchConfidence.unknown => '当前资料不足，请补充书名并核对版本',
    };
  }

  bool get requiresManualReview =>
      confidence != BookMatchConfidence.high ||
      book.title.trim().isEmpty ||
      book.title.trim() == '待确认书籍';
}

class BookRecognitionResult {
  const BookRecognitionResult({
    required this.batchId,
    required this.candidates,
    this.selectedIndex = 0,
  });

  final String batchId;
  final List<BookCandidate> candidates;
  final int selectedIndex;

  BookCandidate? get selected {
    if (candidates.isEmpty) return null;
    return candidates[selectedIndex.clamp(0, candidates.length - 1)];
  }
}

class BookConfirmation {
  const BookConfirmation({
    required this.book,
    required this.pageNumbers,
    this.wasChanged = false,
  });

  final BookRecord book;
  final List<String> pageNumbers;
  final bool wasChanged;
}
