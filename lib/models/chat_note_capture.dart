import 'note.dart';
import 'notebook.dart';

enum ChatNoteCaptureKind { fullReply, selection }

class ChatNoteCaptureRequest {
  const ChatNoteCaptureRequest({
    required this.conversationId,
    required this.messageId,
    required this.kind,
    required this.text,
    required this.capturedAt,
    this.bookId,
    this.bookName = '',
  });

  final String conversationId;
  final String messageId;
  final ChatNoteCaptureKind kind;
  final String text;
  final DateTime capturedAt;
  final int? bookId;
  final String bookName;
}

class ChatNoteSourceRecord {
  const ChatNoteSourceRecord({
    this.id,
    this.noteId,
    required this.conversationId,
    required this.messageId,
    required this.captureKind,
    required this.sourceText,
    required this.capturedAt,
  });

  factory ChatNoteSourceRecord.fromMap(Map<String, Object?> map) {
    return ChatNoteSourceRecord(
      id: map['id'] as int?,
      noteId: map['note_id'] as int?,
      conversationId: map['conversation_id'] as String? ?? '',
      messageId: map['message_id'] as String? ?? '',
      captureKind: map['capture_kind'] as String? ?? '',
      sourceText: map['source_text'] as String? ?? '',
      capturedAt: map['captured_at'] as String? ?? '',
    );
  }

  factory ChatNoteSourceRecord.fromRequest(ChatNoteCaptureRequest request) {
    return ChatNoteSourceRecord(
      conversationId: request.conversationId,
      messageId: request.messageId,
      captureKind: request.kind.name,
      sourceText: request.text,
      capturedAt: request.capturedAt.toIso8601String(),
    );
  }

  final String conversationId;
  final String messageId;
  final String captureKind;
  final String sourceText;
  final String capturedAt;
  final int? id;
  final int? noteId;

  Map<String, Object?> toMap(int noteId) => {
    'note_id': noteId,
    'conversation_id': conversationId,
    'message_id': messageId,
    'capture_kind': captureKind,
    'source_text': sourceText,
    'captured_at': capturedAt,
  };
}

class ChatNoteCaptureSelection {
  const ChatNoteCaptureSelection({
    required this.notebook,
    required this.keepBookAssociation,
    this.existingNote,
  });

  final Notebook notebook;
  final bool keepBookAssociation;
  final Note? existingNote;
}
