import 'dart:async';

import 'package:flutter/material.dart';

class AppToast {
  AppToast._();

  /// 居中弹出 Toast，1秒后自动消失
  static void show(BuildContext context, String message) {
    // 先在调用方仍然有效的当前 frame 捕获 Overlay。这样“提示后立即
    // Navigator.pop”的调用仍能显示 Toast，同时不会在 teardown 期间再做
    // 祖先查找。
    final overlay = context.mounted ? Overlay.maybeOf(context) : null;
    if (overlay == null || !overlay.mounted) return;

    late OverlayEntry entry;
    var inserted = false;
    var dismissed = false;

    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      if (!inserted) {
        entry.dispose();
        return;
      }
      entry.remove();
      // OverlayEntry 的 Element 要到移除后的 frame 才完成 teardown。
      WidgetsBinding.instance.addPostFrameCallback((_) => entry.dispose());
    }

    entry = OverlayEntry(
      builder: (ctx) {
        return _ToastWidget(message: message, onDismiss: dismiss);
      },
    );

    // 延迟插入，避开当前 frame 的 route teardown；Overlay 已在上面安全捕获，
    // 因此即使调用方随后 pop，Toast 仍可挂到同一个 Overlay 上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dismissed || !context.mounted || !overlay.mounted) {
        dismiss();
        return;
      }
      overlay.insert(entry);
      inserted = true;
    });
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ToastWidget({required this.message, required this.onDismiss});

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // 淡入
    _controller.forward();

    // 1秒后淡出
    _dismissTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        _controller.reverse().then((_) {
          if (mounted) widget.onDismiss();
        });
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, child) {
        return Opacity(
          opacity: _opacity.value,
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE6000000), // 90% black
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
