import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/note.dart';
import '../utils/date_formatter.dart';

class TextNoteCard extends StatefulWidget {
  final Note note;
  final VoidCallback? onTap;

  const TextNoteCard({super.key, required this.note, this.onTap});

  @override
  State<TextNoteCard> createState() => _TextNoteCardState();
}

class _TextNoteCardState extends State<TextNoteCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _pressAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _pressAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _pressController.forward();
    setState(() {});
  }

  void _onTapUp(TapUpDetails details) {
    _pressController.reverse();
    setState(() {});
    widget.onTap?.call();
  }

  void _onTapCancel() {
    _pressController.reverse();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final hasTitle = note.title.isNotEmpty;
    final hasContent = note.content.isNotEmpty;
    final hasBook = note.bookName.isNotEmpty;
    final isEmpty = !hasTitle && !hasContent;

    DateTime? createdAt;
    try {
      createdAt = DateTime.parse(note.createdAt);
    } catch (_) {}

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: Transform.scale(
        scale: _pressAnimation.value,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isEmpty)
                const Text(
                  '未命名笔记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.hint,
                  ),
                )
              else if (!hasTitle && hasContent)
                Text(
                  note.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                )
              else ...[
                Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (hasContent) ...[
                  const SizedBox(height: 6),
                  Text(
                    note.content,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '🕐 ${createdAt != null ? DateFormatter.formatRelativeTime(createdAt) : note.createdAt}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.hint,
                    ),
                  ),
                  if (hasBook) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '📖 ${note.bookName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.hint,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
