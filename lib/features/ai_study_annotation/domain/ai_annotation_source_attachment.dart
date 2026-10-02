import 'dart:collection';

/// The semantic object a temporary laser selection points at.
///
/// This is deliberately separate from [PageAnnotationDocument]: a laser
/// selection is a discussion source, not a persisted pen stroke.
enum AiAnnotationSourceType { pageText, pageRegion, aiAnnotation }

class AiAnnotationSourceAnchor {
  const AiAnnotationSourceAnchor({
    required this.pageNoteId,
    required this.documentHash,
    required this.blockId,
    required this.startOffset,
    required this.endOffset,
    required this.exactQuote,
    this.prefix = '',
    this.suffix = '',
    this.normalizedRect,
    this.sourceType,
  });

  final int? pageNoteId;
  final String documentHash;
  final String blockId;
  final int startOffset;
  final int endOffset;
  final String exactQuote;
  final String prefix;
  final String suffix;
  final List<double>? normalizedRect;
  final AiAnnotationSourceType? sourceType;

  bool get isValid =>
      documentHash.isNotEmpty &&
      blockId.isNotEmpty &&
      startOffset >= 0 &&
      endOffset >= startOffset &&
      (sourceType == AiAnnotationSourceType.pageRegion
          ? normalizedRect?.length == 4
          : exactQuote.trim().isNotEmpty);

  Map<String, Object?> toJson() => {
    if (pageNoteId != null) 'page_note_id': pageNoteId,
    'document_hash': documentHash,
    'block_id': blockId,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'exact_quote': exactQuote,
    if (prefix.isNotEmpty) 'prefix': prefix,
    if (suffix.isNotEmpty) 'suffix': suffix,
    if (normalizedRect != null) 'normalized_rect': normalizedRect,
    if (sourceType != null) 'source_type': sourceType!.name,
  };

  factory AiAnnotationSourceAnchor.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Invalid AI annotation source anchor');
    }
    final rect = raw['normalized_rect'];
    return AiAnnotationSourceAnchor(
      pageNoteId: (raw['page_note_id'] as num?)?.toInt(),
      documentHash: raw['document_hash']?.toString() ?? '',
      blockId: raw['block_id']?.toString() ?? '',
      startOffset: (raw['start_offset'] as num?)?.toInt() ?? -1,
      endOffset: (raw['end_offset'] as num?)?.toInt() ?? -1,
      exactQuote: raw['exact_quote']?.toString() ?? '',
      prefix: raw['prefix']?.toString() ?? '',
      suffix: raw['suffix']?.toString() ?? '',
      normalizedRect: rect is List
          ? rect.whereType<num>().map((value) => value.toDouble()).toList()
          : null,
      sourceType: AiAnnotationSourceType.values
          .where((value) => value.name == raw['source_type']?.toString())
          .firstOrNull,
    );
  }
}

class AiAnnotationSourceAttachment {
  const AiAnnotationSourceAttachment({
    required this.id,
    required this.sequence,
    required this.sourceType,
    required this.pageLabel,
    required this.quote,
    required this.anchor,
    required this.screenshotPath,
    this.screenshotRect,
  });

  final String id;
  final int sequence;
  final AiAnnotationSourceType sourceType;
  final String pageLabel;
  final String quote;
  final AiAnnotationSourceAnchor anchor;
  final String screenshotPath;
  final List<double>? screenshotRect;

  AiAnnotationSourceAttachment copyWith({int? sequence}) =>
      AiAnnotationSourceAttachment(
        id: id,
        sequence: sequence ?? this.sequence,
        sourceType: sourceType,
        pageLabel: pageLabel,
        quote: quote,
        anchor: anchor,
        screenshotPath: screenshotPath,
        screenshotRect: screenshotRect,
      );

  bool get isValid =>
      id.isNotEmpty &&
      sequence > 0 &&
      pageLabel.trim().isNotEmpty &&
      (sourceType == AiAnnotationSourceType.pageRegion ||
          quote.trim().isNotEmpty) &&
      screenshotPath.trim().isNotEmpty &&
      anchor.isValid;

  Map<String, Object?> toJson() => {
    'id': id,
    'sequence': sequence,
    'source_type': sourceType.name,
    'page_label': pageLabel,
    'quote': quote,
    'anchor': anchor.toJson(),
    'screenshot_path': screenshotPath,
    if (screenshotRect != null) 'screenshot_rect': screenshotRect,
  };

  factory AiAnnotationSourceAttachment.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Invalid AI annotation source attachment');
    }
    final rawType = raw['source_type']?.toString();
    final sourceType = AiAnnotationSourceType.values.firstWhere(
      (value) => value.name == rawType,
      orElse: () => AiAnnotationSourceType.pageText,
    );
    final rect = raw['screenshot_rect'];
    final parsedAnchor = AiAnnotationSourceAnchor.fromJson(raw['anchor']);
    final anchor =
        parsedAnchor.sourceType == null &&
            sourceType == AiAnnotationSourceType.pageRegion
        ? AiAnnotationSourceAnchor(
            pageNoteId: parsedAnchor.pageNoteId,
            documentHash: parsedAnchor.documentHash,
            blockId: parsedAnchor.blockId,
            startOffset: parsedAnchor.startOffset,
            endOffset: parsedAnchor.endOffset,
            exactQuote: parsedAnchor.exactQuote,
            prefix: parsedAnchor.prefix,
            suffix: parsedAnchor.suffix,
            normalizedRect: parsedAnchor.normalizedRect,
            sourceType: sourceType,
          )
        : parsedAnchor;
    return AiAnnotationSourceAttachment(
      id: raw['id']?.toString() ?? '',
      sequence: (raw['sequence'] as num?)?.toInt() ?? 0,
      sourceType: sourceType,
      pageLabel: raw['page_label']?.toString() ?? '',
      quote: raw['quote']?.toString() ?? '',
      anchor: anchor,
      screenshotPath: raw['screenshot_path']?.toString() ?? '',
      screenshotRect: rect is List
          ? rect.whereType<num>().map((value) => value.toDouble()).toList()
          : null,
    );
  }
}

class AiAnnotationAttachmentTrayState {
  AiAnnotationAttachmentTrayState({
    Iterable<AiAnnotationSourceAttachment> attachments = const [],
    this.inputText = '',
    this.activeAttachmentId,
    this.isReviewOpen = false,
  }) : attachments = UnmodifiableListView(attachments.toList(growable: false));

  final List<AiAnnotationSourceAttachment> attachments;
  final String inputText;
  final String? activeAttachmentId;
  final bool isReviewOpen;

  bool get canSend => attachments.isNotEmpty || inputText.trim().isNotEmpty;
  int get count => attachments.length;

  AiAnnotationAttachmentTrayState copyWith({
    Iterable<AiAnnotationSourceAttachment>? attachments,
    String? inputText,
    String? activeAttachmentId,
    bool clearActiveAttachment = false,
    bool? isReviewOpen,
  }) => AiAnnotationAttachmentTrayState(
    attachments: attachments ?? this.attachments,
    inputText: inputText ?? this.inputText,
    activeAttachmentId: clearActiveAttachment
        ? null
        : activeAttachmentId ?? this.activeAttachmentId,
    isReviewOpen: isReviewOpen ?? this.isReviewOpen,
  );

  AiAnnotationAttachmentTrayState removeAttachment(String id) {
    final remaining = attachments.where((item) => item.id != id).toList();
    final next = [
      for (var index = 0; index < remaining.length; index++)
        remaining[index].copyWith(sequence: index + 1),
    ];
    final nextActive = activeAttachmentId == id ? null : activeAttachmentId;
    return AiAnnotationAttachmentTrayState(
      attachments: next,
      inputText: inputText,
      activeAttachmentId: nextActive,
      isReviewOpen: isReviewOpen,
    );
  }

  Map<String, Object?> toJson() => {
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'input_text': inputText,
    if (activeAttachmentId != null) 'active_attachment_id': activeAttachmentId,
    'is_review_open': isReviewOpen,
  };

  factory AiAnnotationAttachmentTrayState.fromJson(Object? raw) {
    if (raw is! Map) return AiAnnotationAttachmentTrayState();
    final rawAttachments = raw['attachments'];
    final parsed = <AiAnnotationSourceAttachment>[];
    if (rawAttachments is List) {
      for (final item in rawAttachments) {
        try {
          final attachment = AiAnnotationSourceAttachment.fromJson(item);
          if (attachment.isValid) parsed.add(attachment);
        } on FormatException {
          // Ignore one malformed draft item without losing the rest.
        }
      }
    }
    return AiAnnotationAttachmentTrayState(
      attachments: parsed,
      inputText: raw['input_text']?.toString() ?? '',
      activeAttachmentId: raw['active_attachment_id']?.toString(),
      isReviewOpen: raw['is_review_open'] == true,
    );
  }
}
