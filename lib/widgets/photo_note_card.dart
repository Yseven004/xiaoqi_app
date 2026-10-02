import 'dart:io';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/note.dart';
import 'placeholder_image.dart';

class PhotoNoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback? onTap;

  const PhotoNoteCard({super.key, required this.note, this.onTap});

  String _formatTime(String iso8601) {
    try {
      final dt = DateTime.parse(iso8601);
      final month = dt.month.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$month-$day $hour:$minute';
    } catch (_) {
      return iso8601;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = note.title.isEmpty ? '未命名笔记' : note.title;
    final hasDescription = note.content.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 80,
                height: 80,
                child: Image.file(
                  File(note.photoPath),
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                  cacheHeight: 160,
                  errorBuilder: (context, error, stackTrace) {
                    return const PlaceholderImage(iconSize: 28);
                  },
                ),
              ),
            ),

            const SizedBox(width: 12),

            // 文字区域
            Expanded(
              child: SizedBox(
                height: 80,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: note.title.isEmpty
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),

                    // 描述摘要
                    if (hasDescription) ...[
                      const SizedBox(height: 4),
                      Text(
                        note.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],

                    const Spacer(),

                    // 底部：时间 + 图标
                    Row(
                      children: [
                        Text(
                          _formatTime(note.createdAt),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.camera_alt,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
