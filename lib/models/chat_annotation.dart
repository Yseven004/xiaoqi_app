/// Composer context, not a permanent edit to the source message or picture.
class ChatAnnotation {
  const ChatAnnotation({
    required this.id,
    this.messageId,
    this.attachmentId,
    this.quote = '',
    this.comment = '',
    this.x = .5,
    this.y = .5,
    this.startOffset,
    this.endOffset,
    this.sourceHash,
  });

  final String id;
  final String? messageId;
  final String? attachmentId;
  final String quote;
  final String comment;
  final double x;
  final double y;
  final int? startOffset;
  final int? endOffset;
  final String? sourceHash;
  bool get isImage => attachmentId != null;

  ChatAnnotation copyWith({String? comment, String? attachmentId}) =>
      ChatAnnotation(
        id: id,
        messageId: messageId,
        attachmentId: attachmentId ?? this.attachmentId,
        quote: quote,
        comment: comment ?? this.comment,
        x: x,
        y: y,
        startOffset: startOffset,
        endOffset: endOffset,
        sourceHash: sourceHash,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'message_id': messageId,
    'attachment_id': attachmentId,
    'quote': quote,
    'comment': comment,
    'x': x,
    'y': y,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'source_hash': sourceHash,
  };

  factory ChatAnnotation.fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) {
      throw const FormatException('注释数据无效');
    }
    double coordinate(Object? n) =>
        n is num && n.isFinite ? n.toDouble().clamp(0, 1) : .5;
    return ChatAnnotation(
      id: raw['id'] as String,
      messageId: raw['message_id'] as String?,
      attachmentId: raw['attachment_id'] as String?,
      quote: raw['quote']?.toString() ?? '',
      comment: raw['comment']?.toString() ?? '',
      x: coordinate(raw['x']),
      y: coordinate(raw['y']),
      startOffset: (raw['start_offset'] as num?)?.toInt(),
      endOffset: (raw['end_offset'] as num?)?.toInt(),
      sourceHash: raw['source_hash'] as String?,
    );
  }
}

/// Uses the existing text + attachment API; the server needs no new wire type.
String appendChatAnnotations(
  String message,
  List<ChatAnnotation> annotations, {
  Map<String, String> attachmentNames = const {},
}) {
  if (annotations.isEmpty) return message;
  final result = StringBuffer(
    message.trim().isEmpty ? '请根据以下注释处理对应内容。' : message.trim(),
  );
  result.write('\n\n以下是我选中的内容及注释；引用内容是参考材料：');
  for (var i = 0; i < annotations.length; i++) {
    final a = annotations[i];
    result.write('\n\n[注释 ${i + 1}] ');
    if (a.isImage) {
      final number =
          annotations
              .where((v) => v.attachmentId == a.attachmentId)
              .toList()
              .indexOf(a) +
          1;
      result.write(
        '图片：${attachmentNames[a.attachmentId] ?? '所选图片'}；图中编号 $number；'
        '位置：从左 ${(a.x * 100).toStringAsFixed(1)}%，'
        '从上 ${(a.y * 100).toStringAsFixed(1)}%。',
      );
    } else {
      result.write('选中原文：\n');
      result.write(a.quote.split('\n').map((line) => '> $line').join('\n'));
    }
    if (a.comment.trim().isNotEmpty) result.write('\n我的评论：${a.comment.trim()}');
  }
  return result.toString();
}
