import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../config/breathing_config.dart';
import 'emotion_service.dart';

// 背景呼吸动效 — 轻量单例服务
//
// 暴露 currentColor / phase / enabled 三个 ValueNotifier，
// 供 BreathingBackgroundWidget 写入、其他组件（情绪联动、光晕等）读取。
// 设计模式与 RobotOverlay 一致。
//
// Task 2: 监听 EmotionService.moodScore，档位变化时更新目标色值对。

class BreathingBackgroundService {
  BreathingBackgroundService._();

  /// 当前插值后的背景色
  static final ValueNotifier<Color> currentColor =
      ValueNotifier<Color>(AppColors.background);

  /// 当前动画相位 0.0 → 1.0
  static final ValueNotifier<double> phase = ValueNotifier<double>(0.0);

  /// 呼吸动效是否启用（Task 4 氛围开关使用）
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  // ── 情绪联动（Task 2） ──

  /// 目标呼吸最暗色（Widget 监听此值启动 3s 过渡）
  static final ValueNotifier<Color> targetDarkest =
      ValueNotifier<Color>(AppColors.background);

  /// 目标呼吸最亮色（Widget 监听此值启动 3s 过渡）
  static final ValueNotifier<Color> targetBrightest =
      ValueNotifier<Color>(AppColors.backgroundBreathMax);

  static int _lastTier = 1; // 初始为标准档

  /// 初始化情绪联动监听
  static void init() {
    EmotionService.moodScore.addListener(_onMoodScoreChanged);
    debugPrint('[XiaoQi] BreathingBg: 情绪联动监听已注册，初始档位=$_lastTier');
  }

  static void _onMoodScoreChanged() {
    final score = EmotionService.moodScore.value;
    final newTier = EmotionService.currentTier;

    if (newTier == _lastTier) return; // 档位内波动不触发

    final oldTier = _lastTier;
    _lastTier = newTier;

    final newDarkest = BreathingConfig.darkestForScore(score);
    final newBrightest = BreathingConfig.brightestForScore(score);

    debugPrint('[XiaoQi] BreathingBg: 档位变化 $oldTier→$newTier (score=$score)');

    targetDarkest.value = newDarkest;
    targetBrightest.value = newBrightest;
  }

  // ── 阶段查询 ──

  /// 当前是否处于吸气阶段
  static bool get isInhaling => phase.value < BreathingConfig.inhaleEnd;

  /// 当前是否处于屏息阶段
  static bool get isHolding =>
      phase.value >= BreathingConfig.inhaleEnd &&
      phase.value < BreathingConfig.holdEnd;

  /// 当前是否处于呼气阶段
  static bool get isExhaling =>
      phase.value >= BreathingConfig.holdEnd;

  /// 复位到初始状态
  static void dispose() {
    currentColor.value = AppColors.background;
    phase.value = 0.0;
  }
}
