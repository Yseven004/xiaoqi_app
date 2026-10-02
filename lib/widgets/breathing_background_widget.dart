import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../config/breathing_config.dart';
import '../services/breathing_background_service.dart';

// 背景呼吸动效 — 根级 StatefulWidget
//
// 位于 MaterialApp.builder 层级，高于 Navigator，
// 确保呼吸动效跨页面连续、不重置。
//
// 使用 AnimationController(10s) + repeat() 驱动三段式呼吸曲线：
//   0.00–0.35  吸气（easeIn 渐亮）
//   0.35–0.40  屏息（保持最亮）
//   0.40–1.00  呼气（easeOut 渐暗）
//
// 情绪联动（Task 2）：监听 targetDarkest / targetBrightest，
// 档位变化时通过 _tierCtrl (3s easeInOutCubic) 平滑过渡。

class BreathingBackgroundWidget extends StatefulWidget {
  final Widget child;

  const BreathingBackgroundWidget({super.key, required this.child});

  @override
  State<BreathingBackgroundWidget> createState() =>
      _BreathingBackgroundWidgetState();
}

class _BreathingBackgroundWidgetState extends State<BreathingBackgroundWidget>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _breathCtrl;
  late AnimationController _tierCtrl;

  // ── 色值缓存 ──
  Color _currentColor = AppColors.background;

  // ── 档位过渡的起止色 ──
  Color _fromDarkest = AppColors.background;
  Color _fromBrightest = AppColors.backgroundBreathMax;
  Color _toDarkest = AppColors.background;
  Color _toBrightest = AppColors.backgroundBreathMax;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 呼吸动画
    _breathCtrl = AnimationController(
      vsync: this,
      duration: BreathingConfig.totalDuration,
    );
    _breathCtrl.addListener(_onBreathTick);
    _breathCtrl.repeat();

    // 档位过渡动画
    _tierCtrl = AnimationController(
      vsync: this,
      duration: BreathingConfig.tierTransitionDuration,
    );
    _tierCtrl.addListener(_onTierTick);
    _tierCtrl.addStatusListener(_onTierStatus);

    // 监听情绪档位变化
    BreathingBackgroundService.targetDarkest.addListener(_onTargetColorsChanged);
    BreathingBackgroundService.targetBrightest.addListener(_onTargetColorsChanged);

    // 初始化情绪联动
    BreathingBackgroundService.init();

    debugPrint('[XiaoQi] BreathingBg: 呼吸动效已启动，周期=${BreathingConfig.totalDuration.inSeconds}s');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _breathCtrl.removeListener(_onBreathTick);
    _breathCtrl.dispose();
    _tierCtrl.removeListener(_onTierTick);
    _tierCtrl.removeStatusListener(_onTierStatus);
    _tierCtrl.dispose();
    BreathingBackgroundService.targetDarkest.removeListener(_onTargetColorsChanged);
    BreathingBackgroundService.targetBrightest.removeListener(_onTargetColorsChanged);
    super.dispose();
  }

  // ── WidgetsBindingObserver ──

  @override
  void didChangeAccessibilityFeatures() {
    setState(() {});
  }

  // ── 档位过渡 ──

  void _onTargetColorsChanged() {
    final newDark = BreathingBackgroundService.targetDarkest.value;
    final newBright = BreathingBackgroundService.targetBrightest.value;

    // 快照当前有效色值作为过渡起点
    _fromDarkest = _effectiveDarkest;
    _fromBrightest = _effectiveBrightest;
    _toDarkest = newDark;
    _toBrightest = newBright;

    _tierCtrl.reset();
    _tierCtrl.forward();

    debugPrint('[XiaoQi] BreathingBg: 档位过渡开始 '
        'dark=#${_fromDarkest.toARGB32().toRadixString(16).padLeft(8, '0')}→'
        '#${_toDarkest.toARGB32().toRadixString(16).padLeft(8, '0')}');
  }

  void _onTierTick() {
    setState(() {});
  }

  void _onTierStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      debugPrint('[XiaoQi] BreathingBg: 档位过渡完成');
    }
  }

  // ── 有效色值（过渡期间为 lerp 结果，静止时为目标色值） ──

  Color get _effectiveDarkest {
    if (!_tierCtrl.isAnimating) return _toDarkest;
    return Color.lerp(_fromDarkest, _toDarkest, _tierCtrl.value)!;
  }

  Color get _effectiveBrightest {
    if (!_tierCtrl.isAnimating) return _toBrightest;
    return Color.lerp(_fromBrightest, _toBrightest, _tierCtrl.value)!;
  }

  // ── 呼吸动画回调 ──

  void _onBreathTick() {
    final t = _breathCtrl.value;
    final darkest = _effectiveDarkest;
    final brightest = _effectiveBrightest;
    final color = _interpolateColor(t, darkest, brightest);

    if (color == _currentColor) return;
    _currentColor = color;

    BreathingBackgroundService.phase.value = t;
    BreathingBackgroundService.currentColor.value = color;

    setState(() {});
  }

  // ── 三段式颜色插值 ──

  Color _interpolateColor(double t, Color darkest, Color brightest) {
    if (t < BreathingConfig.inhaleEnd) {
      final raw = t / BreathingConfig.inhaleEnd;
      final eased = raw * raw;
      return Color.lerp(darkest, brightest, eased)!;
    } else if (t < BreathingConfig.holdEnd) {
      return brightest;
    } else {
      final raw = (t - BreathingConfig.holdEnd) /
          (BreathingConfig.exhaleEnd - BreathingConfig.holdEnd);
      final eased = 1.0 - (1.0 - raw) * (1.0 - raw);
      return Color.lerp(brightest, darkest, eased)!;
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .disableAnimations;

    final enabled = BreathingBackgroundService.enabled.value;

    final shouldAnimate = enabled && !disableAnimations;

    return Container(
      color: shouldAnimate ? _currentColor : AppColors.background,
      child: widget.child,
    );
  }
}
