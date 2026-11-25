import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';

import 'attachment_service.dart';

String annotationImageNamespace(String account, String messageId) =>
    'annotation-${sha256.convert(utf8.encode(jsonEncode([account, messageId])))}';

class AgentAnnotationGroup {
  AgentAnnotationGroup(this.id, this.number, this.text, this.imageIds);

  final String id;
  final int number;
  final String text;
  final List<String> imageIds;
}

List<AgentAnnotationGroup> parseAnnotationGroups(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List || raw.isEmpty || raw.length > 256) {
    throw const FormatException('注释批次无效');
  }
  final groups = <AgentAnnotationGroup>[];
  final groupIds = <String>{};
  var imageCount = 0;
  for (final value in raw) {
    if (value is! Map) throw const FormatException('注释格式无效');
    final id = value['id'];
    final number = value['number'];
    final text = value['text'];
    final imageIds = value['image_ids'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(id) ||
        !groupIds.add(id) ||
        number != groups.length + 1 ||
        text is! String ||
        text.length > 100000 ||
        imageIds is! List ||
        imageIds.length > 3 ||
        imageIds.any((id) => id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))) {
      throw FormatException('注释 ${groups.length + 1} 的内容或解释图无效');
    }
    imageCount += imageIds.length;
    groups.add(AgentAnnotationGroup(id, groups.length + 1, text, imageIds.cast<String>()));
  }
  if (imageCount < 1 || imageCount > 9) {
    throw const FormatException('本轮解释图数量无效');
  }
  return groups;
}

const groupedAnnotationMediaMarker = 'xiaoqi_annotation_image';

Future<List<Part>> buildAnnotationGroupParts(
  List<AgentAnnotationGroup> groups, {
  required AttachmentService attachments,
  required String namespace,
  required int byteBudget,
}) async {
  final parts = <Part>[];
  var remaining = byteBudget;
  for (final group in groups) {
    parts.add(TextPart(text: '[注释 ${group.number}] ${group.text}'));
    for (final id in group.imageIds) {
      late final Map<String, dynamic> raw;
      try {
        raw = await attachments.imagePart(namespace, id, maxBytes: remaining);
      } on AttachmentFailure catch (error) {
        throw FormatException('注释 ${group.number} 的解释图无法读取：${error.message}');
      }
      final url = (raw['image_url'] as Map)['url'] as String;
      remaining -= inlineAgentImageBytes(url);
      parts.add(MediaPart(
        media: Media(contentType: url.substring(5, url.indexOf(';')), url: url),
        metadata: {groupedAnnotationMediaMarker: true},
      ));
    }
  }
  return parts;
}

int inlineAgentImageBytes(String url) {
  final comma = url.indexOf(',');
  if (!url.startsWith('data:') || comma < 0) return 0;
  final encoded = url.substring(comma + 1);
  return (encoded.length ~/ 4) * 3 -
      (encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0);
}
