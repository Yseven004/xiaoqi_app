import 'package:flutter/material.dart';
import '../pages/note_editor_page.dart';
import '../services/database_service.dart';
import '../services/learning_notes_service.dart';

class LearningNotesStatusBar extends StatelessWidget {
  const LearningNotesStatusBar({super.key, required this.conversationId});
  final String? conversationId;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<LearningNotesStatus?>(
        valueListenable: LearningNotesService.instance.status,
        builder: (context, status, _) {
          if (status == null ||
              (status.conversationId.isNotEmpty &&
                  status.conversationId != conversationId)) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: const Color(0xFFF5F7F4),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '学习笔记管家 · ${status.message}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (status.noteId != null)
                      TextButton(
                        onPressed: () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          final note = await DatabaseService().getNoteById(
                            status.noteId!,
                          );
                          if (!context.mounted ||
                              note == null ||
                              note.isDeleted != 0) {
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => NoteEditorPage(
                                notebookId: note.notebookId,
                                existingNote: note,
                              ),
                            ),
                          );
                        },
                        child: const Text('查看笔记'),
                      ),
                    if (status.retry)
                      TextButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          LearningNotesService.instance.retry();
                        },
                        child: const Text('重试'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
