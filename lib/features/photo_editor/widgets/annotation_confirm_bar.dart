import 'package:flutter/material.dart';

/// 标注确认栏 — 画笔/马赛克模式下显示 × 和 √ 按钮
/// 样式与 CropConfirmBar 一致
class AnnotationConfirmBar extends StatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const AnnotationConfirmBar({
    super.key,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  State<AnnotationConfirmBar> createState() => _AnnotationConfirmBarState();
}

class _AnnotationConfirmBarState extends State<AnnotationConfirmBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _cancelSlide;
  late Animation<Offset> _confirmSlide;
  late Animation<double> _fadeIn;

  bool _isCancelPressed = false;
  bool _isConfirmPressed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _cancelSlide = Tween<Offset>(
      begin: const Offset(-2.0, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Curves.elasticOut,
    ));

    _confirmSlide = Tween<Offset>(
      begin: const Offset(2.0, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Curves.elasticOut,
    ));

    _fadeIn = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.3)),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeIn.value,
          child: Container(
            padding: EdgeInsets.only(
              left: 36,
              right: 36,
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 取消 × — 从左边滑入
                SlideTransition(
                  position: _cancelSlide,
                  child: GestureDetector(
                    onTap: widget.onCancel,
                    onTapDown: (_) => setState(() => _isCancelPressed = true),
                    onTapUp: (_) => setState(() => _isCancelPressed = false),
                    onTapCancel: () => setState(() => _isCancelPressed = false),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Colors.white.withValues(
                          alpha: _isCancelPressed ? 0.25 : 0.1,
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),

                // 确认 √ — 从右边滑入
                SlideTransition(
                  position: _confirmSlide,
                  child: GestureDetector(
                    onTap: widget.onConfirm,
                    onTapDown: (_) => setState(() => _isConfirmPressed = true),
                    onTapUp: (_) => setState(() => _isConfirmPressed = false),
                    onTapCancel: () => setState(() => _isConfirmPressed = false),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Colors.white.withValues(
                          alpha: _isConfirmPressed ? 0.25 : 0.1,
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
