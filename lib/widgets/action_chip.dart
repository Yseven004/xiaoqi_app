import 'package:flutter/material.dart';
import '../config/colors.dart';

// 小型操作标签，用于 AppBar 标题旁

class InlineActionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isDelete;

  const InlineActionChip({
    super.key,
    required this.label,
    required this.onTap,
    this.isDelete = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDelete ? AppColors.error : AppColors.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: color)),
      ),
    );
  }
}
