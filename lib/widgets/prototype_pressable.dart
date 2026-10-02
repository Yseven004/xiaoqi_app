import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原型统一按压手势：800ms 长按，移动超过 10px 取消，并带轻微按压反馈。
class PrototypePressable extends StatefulWidget {
  const PrototypePressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  State<PrototypePressable> createState() => _PrototypePressableState();
}

class _PrototypePressableState extends State<PrototypePressable> {
  static const _longPressDelay = Duration(milliseconds: 800);
  static const _cancelDistance = 10.0;

  Timer? _timer;
  Offset? _origin;
  bool _pressed = false;
  bool _longPressTriggered = false;

  void _handleDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    _origin = event.position;
    _longPressTriggered = false;
    setState(() => _pressed = true);
    if (widget.onLongPress != null) {
      _timer = Timer(_longPressDelay, () {
        if (!_pressed || !mounted) return;
        _longPressTriggered = true;
        HapticFeedback.selectionClick();
        widget.onLongPress?.call();
      });
    }
  }

  void _handleMove(PointerMoveEvent event) {
    final origin = _origin;
    if (origin == null) return;
    if ((event.position - origin).distance > _cancelDistance) {
      _cancelPress();
    }
  }

  void _handleUp(PointerUpEvent event) {
    if (!_pressed) return;
    final fireTap = !_longPressTriggered;
    _finishPress();
    if (fireTap) widget.onTap?.call();
  }

  void _cancelPress() {
    _timer?.cancel();
    _timer = null;
    _origin = null;
    if (_pressed && mounted) setState(() => _pressed = false);
  }

  void _finishPress() {
    _timer?.cancel();
    _timer = null;
    _origin = null;
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void didUpdateWidget(covariant PrototypePressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) _cancelPress();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handleDown,
        onPointerMove: _handleMove,
        onPointerUp: _handleUp,
        onPointerCancel: (_) => _cancelPress(),
        child: AnimatedScale(
          scale: _pressed ? 0.975 : 1,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
