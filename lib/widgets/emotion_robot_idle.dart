import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/emotion_type.dart';

// 小七空闲行为 mixin
//
// 提供眨眼、眼球转动、自发小表情等空闲行为。
// 需要 TickerProviderStateMixin + _blinkController + switchTo 等方法。

mixin EmotionRobotIdleMixin<T extends StatefulWidget> on State<T> {
  late AnimationController _blinkController;
  Timer? _blinkTimer;
  Timer? _lookTimer;
  Timer? _spontaneousTimer;
  double _eyeOffsetX = 0.0;
  double _blinkProgress = 0.0;
  bool _idlePaused = false;
  final math.Random _random = math.Random();

  // 子类必须提供
  EmotionType get currentEmotion;
  EmotionType? get overrideEmotion;
  void switchTo(EmotionType e);

  double get eyeOffsetX => _eyeOffsetX;
  double get blinkProgress => _blinkProgress;

  void initIdle(TickerProvider vsync) {
    _blinkController = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 250))
      ..addListener(_onBlinkTick)..addStatusListener(_onBlinkStatus);
    _startIdleBehavior();
  }

  void disposeIdle() {
    _blinkTimer?.cancel();
    _lookTimer?.cancel();
    _spontaneousTimer?.cancel();
    _blinkController.removeListener(_onBlinkTick);
    _blinkController.removeStatusListener(_onBlinkStatus);
    _blinkController.dispose();
  }

  void _startIdleBehavior() {
    _scheduleBlink();
    _scheduleLook();
    _scheduleSpontaneous();
  }

  void pauseIdle() => _idlePaused = true;
  void resumeIdle() => _idlePaused = false;

  void _scheduleBlink() {
    _blinkTimer?.cancel();
    final delay = Duration(milliseconds: 3000 + _random.nextInt(3000));
    _blinkTimer = Timer(delay, () {
      if (!mounted || _idlePaused) { _scheduleBlink(); return; }
      _triggerBlink();
      if (_random.nextDouble() < 0.2) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) { _blinkController.reset(); _blinkController.forward(); }
        });
      }
      _scheduleBlink();
    });
  }

  void _triggerBlink() => _blinkController..reset()..forward();

  void _onBlinkTick() {
    final v = _blinkController.value;
    if (v < 0.3) { _blinkProgress = v / 0.3; }
    else if (v < 0.4) { _blinkProgress = 1.0; }
    else { _blinkProgress = 1.0 - (v - 0.4) / 0.6; }
    setState(() {});
  }

  void _onBlinkStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) { _blinkProgress = 0.0; setState(() {}); }
  }

  void _scheduleLook() {
    _lookTimer?.cancel();
    final delay = Duration(milliseconds: 3000 + _random.nextInt(2000));
    _lookTimer = Timer(delay, () {
      if (!mounted || _idlePaused) { _scheduleLook(); return; }
      _changeLookDirection();
      _scheduleLook();
    });
  }

  void _changeLookDirection() {
    final choices = [-2.0, -1.5, -0.8, 0.0, 0.0, 0.8, 1.5, 2.0];
    final target = choices[_random.nextInt(choices.length)];
    const steps = 6;
    final delta = (target - _eyeOffsetX) / steps;
    for (int i = 1; i <= steps; i++) {
      Future.delayed(const Duration(milliseconds: 40) * i, () {
        if (mounted) setState(() => _eyeOffsetX += delta);
      });
    }
  }

  void _scheduleSpontaneous() {
    _spontaneousTimer?.cancel();
    final delay = Duration(milliseconds: 15000 + _random.nextInt(15000));
    _spontaneousTimer = Timer(delay, () {
      if (!mounted || _idlePaused) { _scheduleSpontaneous(); return; }
      if (currentEmotion == EmotionType.e2Calm && overrideEmotion == null) {
        final r = _random.nextDouble();
        final expr = r < 0.5 ? EmotionType.e1Happy : r < 0.8 ? EmotionType.e3Thinking : EmotionType.e6Excited;
        switchTo(expr);
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) switchTo(EmotionType.e2Calm);
        });
      }
      _scheduleSpontaneous();
    });
  }
}
