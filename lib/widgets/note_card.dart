import 'package:flutter/material.dart';
import '../models/note.dart';
import 'photo_note_card.dart';
import 'text_note_card.dart';
import 'ai_note_card.dart';

class NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback? onTap;

  const NoteCard({super.key, required this.note, this.onTap});

  @override
  Widget build(BuildContext context) {
    switch (note.type) {
      case 'photo':
        return PhotoNoteCard(note: note, onTap: onTap);
      case 'ai_generated':
        return AiNoteCard(note: note, onTap: onTap);
      case 'text':
      default:
        return TextNoteCard(note: note, onTap: onTap);
    }
  }
}
