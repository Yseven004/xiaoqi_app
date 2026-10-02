import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/colors.dart';
import '../models/emotion_type.dart';
import '../services/emotion_service.dart';
import 'chat_bubble.dart';
import 'emotion_robot_idle.dart';
import 'emotion_robot_painter.dart';

// 小七表情机器人 — 含手势交互、文字气泡、空闲行为

class EmotionRobotWidget extends StatefulWidget {
  final EmotionType initialEmotion;
  final VoidCallback? onSpecialExpired;

  const EmotionRobotWidget({
    super.key,
    this.initialEmotion = EmotionType.e2Calm,
    this.onSpecialExpired,
  });

  @override
  State<EmotionRobotWidget> createState() => EmotionRobotWidgetState();
}

class EmotionRobotWidgetState extends State<EmotionRobotWidget>
    with TickerProviderStateMixin, EmotionRobotIdleMixin {
  late AnimationController _baseController;
  late AnimationController _transitionController;
  late AnimationController _bubbleController;
  late Animation<double> _transitionCurve;

  EmotionType _currentEmotion = EmotionType.e2Calm;
  EmotionType? _pendingEmotion;
  double _displayOpacity = 1.0;
  bool _didSwap = false;

  Timer? _specialTimer;
  Timer? _temporaryTimer;
  EmotionType? _overrideEmotion;

  Offset _dragOffset = Offset.zero;
  double _dragOpacity = 1.0;
  bool _isDragging = false;
  bool _isLongPressing = false;
  Offset? _dragStartPos;
  AnimationController? _springBackCtrl;

  String? _bubbleText;
  bool _bubbleVisible = false;
  Timer? _bubbleTimer;
  DateTime _lastTapTime = DateTime(2000);
  int _consecutiveTapCount = 0;
  Timer? _consecutiveTapTimer;

  @override
  EmotionType get currentEmotion => _currentEmotion;
  @override
  EmotionType? get overrideEmotion => _overrideEmotion;

  @override
  void initState() {
    super.initState();
    _currentEmotion = widget.initialEmotion;
    _baseController = AnimationController(vsync: this, duration: _currentEmotion.animationConfig.period)
      ..addListener(() => setState(() {}))..repeat();
    _transitionController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _transitionCurve = CurvedAnimation(parent: _transitionController, curve: Curves.easeInOut);
    _transitionController.addListener(_onTransitionTick);
    _bubbleController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300))
      ..addListener(() => setState(() {}));
    initIdle(this);
  }

  @override
  void dispose() {
    _specialTimer?.cancel();
    _temporaryTimer?.cancel();
    _bubbleTimer?.cancel();
    _consecutiveTapTimer?.cancel();
    _springBackCtrl?.dispose();
    _baseController.dispose();
    _transitionController.removeListener(_onTransitionTick);
    _transitionController.dispose();
    _bubbleController.dispose();
    disposeIdle();
    super.dispose();
  }

  @override
  void switchTo(EmotionType newEmotion) {
    if (_currentEmotion == newEmotion && !_transitionController.isAnimating) return;
    _pendingEmotion = newEmotion;
    _didSwap = false;
    _transitionController.reset();
    _transitionController.forward();
  }

  bool requestSpecialExpression(EmotionType special) {
    if (!special.isSpecial) return false;
    if (_overrideEmotion != null && special.priority <= _overrideEmotion!.priority) {
      debugPrint('[XiaoQi] EmotionWidget: ${special.displayName} 被 ${_overrideEmotion!.displayName} 阻挡');
      return false;
    }
    switchTo(special);
    _startSpecialTimer(special);
    return true;
  }

  void showTemporary(EmotionType emotion, {Duration duration = const Duration(seconds: 2)}) {
    _temporaryTimer?.cancel();
    switchTo(emotion);
    _temporaryTimer = Timer(duration, () { if (mounted) switchTo(EmotionType.e2Calm); });
  }

  void _handleTap() {
    final now = DateTime.now();

    // 连续点击计数：2s 内无点击则重置
    _consecutiveTapCount++;
    _consecutiveTapTimer?.cancel();
    _consecutiveTapTimer = Timer(const Duration(seconds: 2), () => _consecutiveTapCount = 0);

    // 连点 ≥5 次 → 烦躁
    if (_consecutiveTapCount >= 5) {
      _consecutiveTapCount = 0;
      _consecutiveTapTimer?.cancel();
      HapticFeedback.heavyImpact();
      pauseIdle();
      requestSpecialExpression(EmotionType.e7Angry);
      _showBubble('别点了！烦死了~');
      return;
    }

    if (now.difference(_lastTapTime).inMilliseconds < 300) return;
    _lastTapTime = now;
    HapticFeedback.lightImpact();
    pauseIdle();
    switchTo(EmotionType.e1Happy);
    _showBubble(_randomTapText());
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && !_isDragging && !_isLongPressing) switchTo(EmotionType.e2Calm);
    });
  }

  void _handleLongPress() {
    _isLongPressing = true;
    HapticFeedback.mediumImpact();
    pauseIdle();
    requestSpecialExpression(EmotionType.e8Touched);
    _showBubble('好温暖~');
  }

  void _handleLongPressUp() {
    _isLongPressing = false;
    if (_isDragging) return;
    switchTo(EmotionType.e2Calm);
  }

  void _handleDragStart(DragStartDetails d) {
    // 取消正在进行的弹簧回弹
    _springBackCtrl?.stop();
    _springBackCtrl?.dispose();
    _springBackCtrl = null;
    _dragOffset = Offset.zero;
    _dragOpacity = 1.0;
    _dragStartPos = d.globalPosition;
    _isDragging = false;
  }

  void _handleDragUpdate(DragUpdateDetails d) {
    if (_dragStartPos != null) {
      final dist = (d.globalPosition - _dragStartPos!).distance;
      if (dist > 10 && !_isDragging) {
        _isDragging = true;
        pauseIdle();
        _hideBubble(immediate: true); // 立即清除旧气泡
        _dragOpacity = 0.7;
      }
    }
    if (_isDragging) {
      setState(() { _dragOffset += d.delta; });
    }
  }

  void _handleDragEnd(DragEndDetails d) {
    if (!_isDragging) return;
    _isDragging = false;

    final startOffset = _dragOffset;
    _springBackCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _springBackCtrl!.addListener(() {
      final decay = math.exp(-6.0 * _springBackCtrl!.value);
      setState(() { _dragOffset = startOffset * decay; _dragOpacity = 0.7 + 0.3 * (1.0 - decay); });
    });
    _springBackCtrl!.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        setState(() { _dragOffset = Offset.zero; _dragOpacity = 1.0; });
        _springBackCtrl?.dispose();
        _springBackCtrl = null;
        _showBubble('嘿嘿~');
      }
    });
    _springBackCtrl!.forward();
  }

  String _randomTapText() {
    const pool = ['嗨~', '嗯？', '在呢~', '嗨嗨！', '来啦~'];
    return pool[DateTime.now().millisecond % pool.length];
  }

  void _showBubble(String text) {
    _bubbleTimer?.cancel();
    setState(() {
      _bubbleText = text;
      _bubbleVisible = true;
    });
    if (_bubbleController.isAnimating) {
      _bubbleController.stop();
    }
    _bubbleController.forward();
    _bubbleTimer = Timer(const Duration(seconds: 3), _hideBubble);
  }

  void _hideBubble({bool immediate = false}) {
    _bubbleTimer?.cancel();
    if (!_bubbleVisible) return;
    if (immediate) {
      _bubbleController.stop();
      setState(() { _bubbleVisible = false; _bubbleText = null; });
      return;
    }
    _bubbleController.reverse().then((_) {
      if (mounted) setState(() { _bubbleVisible = false; _bubbleText = null; });
      resumeIdle();
    });
  }

  void _onTransitionTick() {
    final v = _transitionCurve.value;
    if (v < 0.5) {
      _displayOpacity = 1.0 - v * 2.0;
    } else {
      if (!_didSwap && _pendingEmotion != null) {
        _didSwap = true;
        final newEmotion = _pendingEmotion!;
        setState(() { _currentEmotion = newEmotion; });
        _configureBaseAnimation(newEmotion);
        // Task 2: 通知情绪联动系统
        EmotionService.updateMoodScore(newEmotion.representativeScore);
      }
      _displayOpacity = (v - 0.5) * 2.0;
    }
    setState(() {});
  }

  void _configureBaseAnimation(EmotionType e) {
    _baseController..stop()..duration = e.animationConfig.period..reset()..repeat();
  }

  void _startSpecialTimer(EmotionType special) {
    _specialTimer?.cancel();
    _overrideEmotion = special;
    final d = special.specialDuration;
    if (d == null) return;
    _specialTimer = Timer(d, () {
      if (!mounted) return;
      _specialTimer = null;
      _overrideEmotion = null;
      debugPrint('[XiaoQi] EmotionWidget: ${special.displayName} 过期');
      widget.onSpecialExpired?.call();
    });
  }

  double _responsiveSize(double w) => w < 360 ? 52.0 : (w > 420 ? 64.0 : 60.0);

  @override
  Widget build(BuildContext context) {
    final size = _responsiveSize(MediaQuery.of(context).size.width);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (_bubbleVisible && _bubbleText != null)
          Positioned(
            right: size + 12, top: -4,
            child: ChatBubble(
              text: _bubbleText!, animation: _bubbleController,
              appearing: _bubbleController.status != AnimationStatus.reverse,
            ),
          ),
        Transform.translate(
          offset: _dragOffset,
          child: GestureDetector(
            onTap: _handleTap, onLongPress: _handleLongPress, onLongPressUp: _handleLongPressUp,
            onPanStart: _handleDragStart, onPanUpdate: _handleDragUpdate, onPanEnd: _handleDragEnd,
            child: Opacity(
              opacity: _dragOpacity,
              child: Container(
                width: size, height: size,
                decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: [
                  BoxShadow(color: AppColors.robotShadow, blurRadius: 12, offset: Offset(0, 4)),
                ]),
                child: ClipOval(
                  child: CustomPaint(
                    size: Size(size, size),
                    painter: EmotionRobotPainter(
                      emotionType: _currentEmotion,
                      animationValue: _baseController.value,
                      opacity: _displayOpacity,
                      blinkProgress: blinkProgress, eyeOffsetX: eyeOffsetX,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
