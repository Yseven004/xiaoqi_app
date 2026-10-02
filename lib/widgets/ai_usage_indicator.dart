import 'package:flutter/material.dart';
import '../config/api_config.dart';
import '../config/colors.dart';

class AiUsageIndicator extends StatelessWidget {
  final int usedCount;

  const AiUsageIndicator({super.key, required this.usedCount});

  @override
  Widget build(BuildContext context) {
    final maxCount = ApiConfig.dailyAiLimit;
    final remaining = maxCount - usedCount;

    String text;
    Color color;

    if (usedCount >= maxCount) {
      text = '今日已用完';
      color = AppColors.hint;
    } else if (remaining == 1) {
      text = '还剩 1 次';
      color = AppColors.error;
    } else {
      text = '已用 $usedCount/$maxCount 次';
      color = AppColors.hint;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
