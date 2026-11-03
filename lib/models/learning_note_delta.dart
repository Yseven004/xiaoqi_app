import 'dart:convert';

/// A validated, append-only native note update. No model-provided editor ops.
class LearningNoteDelta {
  const LearningNoteDelta({
    required this.receiptId,
    required this.topicId,
    required this.title,
    required this.summary,
    required this.sections,
  });

  final String receiptId;
  final String topicId;
  final String title;
  final String summary;
  final List<({String heading, List<String> items, bool ordered})> sections;

  factory LearningNoteDelta.fromJson(Map<String, dynamic> value) {
    String text(Object? raw, int limit, {bool empty = false}) {
      if (raw is! String ||
          (!empty && raw.trim().isEmpty) ||
          raw.length > limit ||
          raw.contains('\u0000')) {
        throw const FormatException('笔记补充格式无效，原笔记已保留');
      }
      return raw.trim();
    }

    final receipt = text(value['receipt_id'], 96);
    final topic = text(value['topic_id'], 96);
    final idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$');
    if (!idPattern.hasMatch(receipt) || !idPattern.hasMatch(topic)) {
      throw const FormatException('笔记补充标识无效');
    }
    final rawSections = value['sections'];
    if (rawSections is! List || rawSections.isEmpty || rawSections.length > 5) {
      throw const FormatException('笔记小节数量无效');
    }
    final sections = <({String heading, List<String> items, bool ordered})>[];
    for (final raw in rawSections) {
      if (raw is! Map || raw['items'] is! List) {
        throw const FormatException('笔记小节无效');
      }
      final items = raw['items'] as List;
      if (items.isEmpty || items.length > 8) {
        throw const FormatException('笔记条目数量无效');
      }
      sections.add((
        heading: text(raw['heading'], 80),
        ordered: raw['ordered'] == true,
        items: items.map((item) => text(item, 800)).toList(growable: false),
      ));
    }
    return LearningNoteDelta(
      receiptId: receipt,
      topicId: topic,
      title: text(value['title'], 160),
      summary: text(value['summary'], 1200),
      sections: List.unmodifiable(sections),
    );
  }

  Map<String, Object?> toJson() => {
    'receipt_id': receiptId,
    'topic_id': topicId,
    'title': title,
    'summary': summary,
    'sections': [
      for (final section in sections)
        {
          'heading': section.heading,
          'items': section.items,
          'ordered': section.ordered,
        },
    ],
  };

  ({String content, String delta}) append({
    required String content,
    required String delta,
    required bool existing,
  }) {
    final operations = <Object?>[];
    if (delta.trim().isNotEmpty) {
      final decoded = jsonDecode(delta);
      if (decoded is! List ||
          decoded.isEmpty ||
          decoded.any(
            (op) =>
                op is! Map ||
                !op.containsKey('insert') ||
                op.containsKey('delete') ||
                op.containsKey('retain'),
          )) {
        throw const FormatException('现有富文本格式无法安全追加，原笔记已保留');
      }
      final last = decoded.last as Map;
      if (last['insert'] is! String ||
          !(last['insert'] as String).endsWith('\n')) {
        throw const FormatException('现有笔记结尾无效，原笔记已保留');
      }
      // Keep every original operation and attribute byte value unchanged.
      operations.addAll(decoded);
    } else if (content.isNotEmpty) {
      operations.add({
        'insert': content.endsWith('\n') ? content : '$content\n',
      });
    }
    final plain = StringBuffer();
    void paragraph(String value, {Map<String, Object?>? attributes}) {
      operations.add({'insert': value});
      operations.add({
        'insert': '\n',
        'attributes': ?attributes,
      });
      plain.writeln(value);
    }

    if (existing && operations.isNotEmpty) {
      paragraph('');
      paragraph('新补充', attributes: {'header': 2});
    }
    if (!existing) paragraph('核心概念', attributes: {'header': 2});
    paragraph(summary);
    for (final section in sections) {
      paragraph(section.heading, attributes: {'header': 2});
      for (final item in section.items) {
        paragraph(
          item,
          attributes: {'list': section.ordered ? 'ordered' : 'bullet'},
        );
      }
    }
    return (
      content: '${content.isEmpty ? '' : '$content\n'}$plain',
      delta: jsonEncode(operations),
    );
  }
}
