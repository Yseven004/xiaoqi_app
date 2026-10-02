import 'note.dart';

enum NoteEditorOutcome { saved, deleted, unchanged }

class NoteEditorResult {
  const NoteEditorResult._({
    required this.outcome,
    this.note,
    this.previousNote,
  });

  const NoteEditorResult.saved(Note note)
    : this._(outcome: NoteEditorOutcome.saved, note: note);

  const NoteEditorResult.deleted(Note note)
    : this._(outcome: NoteEditorOutcome.deleted, previousNote: note);

  const NoteEditorResult.unchanged()
    : this._(outcome: NoteEditorOutcome.unchanged);

  final NoteEditorOutcome outcome;
  final Note? note;
  final Note? previousNote;

  bool get changed => outcome != NoteEditorOutcome.unchanged;
}
