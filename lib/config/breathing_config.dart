import 'package:flutter/material.dart';
import 'colors.dart';

// 背景呼吸动效 — 配置常量
//
// 定义呼吸周期各阶段的时长、情绪档位阈值和色值。

class BreathingConfig {
  BreathingConfig._();

  /// 总呼吸周期
  static const Duration totalDuration = Duration(seconds: 10);

  // ── 阶段边界（AnimationController.value 0.0 → 1.0） ──

  /// 吸气阶段结束点（3.5s / 10s）
  static const double inhaleEnd = 0.35;

  /// 屏息阶段结束点（4.0s / 10s）
  static const double holdEnd = 0.40;

  /// 呼气阶段结束点（周期终点）
  static const double exhaleEnd = 1.00;

  // ── 情绪档位阈值 ──

  /// 明亮档阈值
  static const int tierBright = 80;

  /// 柔和档阈值（以下）
  static const int tierCalm = 50;

  // ── 情绪档位过渡 ──

  /// 档位过渡时长
  static const Duration tierTransitionDuration = Duration(seconds: 3);

  /// 根据情绪值获取呼吸最暗色
  static Color darkestForScore(int score) {
    if (score >= tierBright) return AppColors.background;
    if (score >= tierCalm) return AppColors.background;
    return AppColors.backgroundCalm;
  }

  /// 根据情绪值获取呼吸最亮色
  static Color brightestForScore(int score) {
    if (score >= tierBright) return AppColors.backgroundBreathBright;
    if (score >= tierCalm) return AppColors.backgroundBreathNormal;
    return AppColors.background;
  }
}
