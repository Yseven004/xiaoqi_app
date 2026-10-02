import 'package:flutter/material.dart';

// 情绪值 — 轻量单例服务
//
// 持有全局 moodScore (0-100)，供 BreathingBackgroundService 监听
// 实现情绪联动（Task 2）。

class EmotionService {
  EmotionService._();

  /// 当前情绪值 0-100，默认 50（标准档）
  static final ValueNotifier<int> moodScore = ValueNotifier<int>(50);

  /// 更新情绪值（情绪机器人表情变化时调用）
  static void updateMoodScore(int score) {
    final clamped = score.clamp(0, 100);
    if (clamped == moodScore.value) return;
    final tierLabel = clamped >= 80 ? '☀️明亮' : clamped >= 50 ? '🌤标准' : '🌧柔和';
    debugPrint('[XiaoQi] EmotionService: 情绪值 ${moodScore.value} → $clamped ($tierLabel)');
    moodScore.value = clamped;
  }

  /// 当前情绪档位
  /// 2 = 明亮 (≥80), 1 = 标准 (50-79), 0 = 柔和 (<50)
  static int get currentTier {
    final s = moodScore.value;
    if (s >= 80) return 2;
    if (s >= 50) return 1;
    return 0;
  }
}
