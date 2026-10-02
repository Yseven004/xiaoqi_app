import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/note.dart';
import '../utils/date_formatter.dart';

class AiNoteCard extends StatefulWidget {
  final Note note;
  final VoidCallback? onTap;

  const AiNoteCard({super.key, required this.note, this.onTap});

  @override
  State<AiNoteCard> createState() => _AiNoteCardState();
}

class _AiNoteCardState extends State<AiNoteCard>
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
  }

  void _onTapUp(TapUpDetails details) {
    _pressController.reverse();
    widget.onTap?.call();
  }

  void _onTapCancel() {
    _pressController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
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
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左侧 accent 色条
                Container(
                  width: 4,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                    ),
                  ),
                ),
                // 内容区
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          note.title.isNotEmpty ? note.title : '✨ 小七的分析',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (note.content.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            note.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          '🕐 ${createdAt != null ? DateFormatter.formatRelativeTime(createdAt) : note.createdAt}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.hint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
