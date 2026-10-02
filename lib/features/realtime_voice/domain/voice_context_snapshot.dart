import 'dart:convert';

/// The smallest piece of reading context the voice agent is allowed to see.
///
/// A new snapshot is sent whenever the page or selection changes. The version
/// is echoed by the agent so a late answer can never be mistaken for the
/// current page.
class VoiceContextSnapshot {
  const VoiceContextSnapshot({
    required this.sourceId,
    required this.sourceType,
    required this.pageAnchor,
    required this.selectedText,
    required this.pageText,
    required this.sourceLineage,
    required this.version,
  });

  final String sourceId;
  final String sourceType;
  final String pageAnchor;
  final String selectedText;
  final String pageText;
  final Map<String, dynamic> sourceLineage;
  final int version;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceType': sourceType,
    'pageAnchor': pageAnchor,
    'selectedText': selectedText,
    'pageText': pageText,
    'sourceLineage': sourceLineage,
    'version': version,
  };

  String encode() => jsonEncode(toJson());

  VoiceContextSnapshot copyWith({
    String? selectedText,
    String? pageText,
    String? pageAnchor,
    Map<String, dynamic>? sourceLineage,
    int? version,
  }) => VoiceContextSnapshot(
    sourceId: sourceId,
    sourceType: sourceType,
    pageAnchor: pageAnchor ?? this.pageAnchor,
    selectedText: selectedText ?? this.selectedText,
    pageText: pageText ?? this.pageText,
    sourceLineage: sourceLineage ?? this.sourceLineage,
    version: version ?? this.version,
  );
}

