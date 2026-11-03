import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:schemantic/schemantic.dart';
import 'store.dart';

final learningNotesSchema = SchemanticType.from<Map<String, dynamic>>(
  jsonSchema: const {
    'type': 'object',
    'additionalProperties': false,
    'required': ['notes'],
    'properties': {
      'notes': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 3,
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['title', 'summary', 'sections'],
          'properties': {
            'topic_id': {'type': 'string', 'maxLength': 96},
            'title': {'type': 'string', 'minLength': 1, 'maxLength': 160},
            'summary': {'type': 'string', 'minLength': 1, 'maxLength': 1200},
            'sections': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 5,
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['heading', 'items'],
                'properties': {
                  'ordered': {'type': 'boolean'},
                  'heading': {
                    'type': 'string',
                    'minLength': 1,
                    'maxLength': 80,
                  },
                  'items': {
                    'type': 'array',
                    'minItems': 1,
                    'maxItems': 8,
                    'items': {
                      'type': 'string',
                      'minLength': 1,
                      'maxLength': 800,
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  },
  parse: (value) => Map<String, dynamic>.from(value as Map),
);

/// Only an explicitly selected deployment-owned plugin may submit native notes.
class LearningNotes {
  static List<Map<String, dynamic>> topics(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 100)
      throw const FormatException('学习主题目录无效');
    final result = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is! Map ||
          item['id'] is! String ||
          item['title'] is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(item['id']) ||
          (item['title'] as String).length > 160)
        throw const FormatException('学习主题无效');
      result.add({'id': item['id'], 'title': item['title']});
    }
    return result;
  }

  static List<Map<String, dynamic>> submit(
    CloudStore store, {
    required String tenant,
    required String taskId,
    required String identity,
    required String conversationId,
    required String messageId,
    required String sourceText,
    required List<Map<String, dynamic>> catalog,
    required Map<String, dynamic> input,
    required bool explicitlyEnabled,
  }) {
    if (!explicitlyEnabled) throw StateError('仅本聊天明确启用的官方笔记管家可整理笔记');
    if (conversationId.isEmpty || messageId.isEmpty)
      throw const FormatException('笔记来源缺失');
    final key = 'task/$tenant/$taskId';
    final task = store.get(key);
    if (task == null) throw StateError('笔记任务不存在');
    final previous = task.value['learning_notes'];
    if (task.value['learning_notes_identity'] == identity && previous is List) {
      return previous
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    String text(Object? raw, int max) {
      if (raw is! String ||
          raw.trim().isEmpty ||
          raw.length > max ||
          raw.contains('\u0000')) {
        throw const FormatException('笔记补充格式无效');
      }
      return raw.trim();
    }

    final notes = input['notes'];
    if (notes is! List || notes.isEmpty || notes.length > 3)
      throw const FormatException('每轮最多整理 3 个主题');
    final ids = catalog.map((e) => e['id']).toSet();
    final result = <Map<String, dynamic>>[];
    final used = <String>{};
    for (final raw in notes) {
      if (raw is! Map) throw const FormatException('笔记格式无效');
      final title = text(raw['title'], 160);
      final requested = raw['topic_id']?.toString() ?? '';
      if (requested.isNotEmpty && !ids.contains(requested))
        throw const FormatException('只能合并到本轮已有主题');
      final topic = requested.isNotEmpty
          ? requested
          : 'topic-${sha256.convert(utf8.encode('$identity/$title')).toString().substring(0, 32)}';
      if (!used.add(topic)) throw const FormatException('同一主题请合并为一份补充');
      final sections = raw['sections'];
      if (sections is! List || sections.isEmpty || sections.length > 5)
        throw const FormatException('笔记小节无效');
      final parsed = <Map<String, dynamic>>[];
      for (final section in sections) {
        if (section is! Map || section['items'] is! List)
          throw const FormatException('笔记条目无效');
        final items = section['items'] as List;
        if (items.isEmpty || items.length > 8)
          throw const FormatException('笔记条目数量无效');
        parsed.add({
          'ordered': section['ordered'] == true,
          'heading': text(section['heading'], 80),
          'items': items.map((e) => text(e, 800)).toList(),
        });
      }
      result.add({
        'receipt_id': sha256
            .convert(utf8.encode('$taskId/$identity/$topic'))
            .toString(),
        'topic_id': topic,
        'title': title,
        'summary': text(raw['summary'], 1200),
        'sections': parsed,
        'conversation_id': conversationId,
        'message_id': messageId,
        'source_text': sourceText,
      });
    }
    store.put(key, {
      ...task.value,
      'learning_notes': result,
      'learning_notes_identity': identity,
    }, task.revision);
    return result;
  }
}
