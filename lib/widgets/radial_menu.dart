import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/colors.dart';

// 扇形弧形展开菜单 — 折扇展开动画
//
// 选项以 FAB（×）为圆心沿弧线分布。
// 遮罩在选项之下，FAB 在遮罩之上。

class RadialMenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const RadialMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class RadialMenu extends StatefulWidget {
  final List<RadialMenuItem> items;
  final bool isOpen;
  final VoidCallback onClose;
  final Widget fab; // FAB 组件，由外部控制层级

  const RadialMenu({
    super.key,
    required this.items,
    required this.isOpen,
    required this.onClose,
    required this.fab,
  });

  @override
  State<RadialMenu> createState() => _RadialMenuState();
}

class _RadialMenuState extends State<RadialMenu>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _expandAnim;
  late Animation<double> _collapseAnim;

  // 弧线参数
  static const double _radius = 100.0;
  static const double _startAngle = 3.49; // ~200° 合拢态
  static const double _fanStart = 1.66; // ~95° 扇面起始
  static const double _fanEnd = 2.88; // ~165° 扇面终止

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() => setState(() {}));
    _expandAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    _collapseAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInCubic);
  }

  @override
  void didUpdateWidget(covariant RadialMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen && !oldWidget.isOpen) {
      _ctrl.forward();
    } else if (!widget.isOpen && oldWidget.isOpen) {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _targetAngle(int i, int total) {
    if (total == 1) return (_fanStart + _fanEnd) / 2;
    return _fanStart + (_fanEnd - _fanStart) * i / (total - 1);
  }

  @override
  Widget build(BuildContext context) {
    // FAB 始终渲染
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final padding = MediaQuery.of(context).padding;
    final fabCx = screenWidth - 16 - 28;
    final fabCy = screenHeight - padding.bottom - 88 - 28;

    final fab = Positioned(
      left: fabCx - 28,
      top: fabCy - 28,
      child: widget.fab,
    );

    if (!widget.isOpen && !_ctrl.isAnimating) return fab;

    final progress = _ctrl.status == AnimationStatus.reverse
        ? _collapseAnim.value
        : _expandAnim.value;

    return Stack(
      children: [
        // 遮罩
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(
              color: Colors.black.withValues(alpha: 0.3 * progress),
            ),
          ),
        ),

        // 选项
        ...List.generate(widget.items.length, (i) {
          final targetAngle = _targetAngle(i, widget.items.length);
          final angle = _startAngle + (targetAngle - _startAngle) * progress;
          final itemDx = _radius * math.cos(angle);
          final itemDy = -_radius * math.sin(angle);
          final opacity = (progress / 0.5).clamp(0.0, 1.0);

          return Positioned(
            left: fabCx - 22 + itemDx,
            top: fabCy - 22 + itemDy,
            child: Opacity(
              opacity: opacity,
              child: GestureDetector(
                onTap: widget.items[i].onTap,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.shadow,
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(widget.items[i].icon, size: 22, color: AppColors.accent),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.items[i].label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),

        // FAB（最顶层）
        fab,
      ],
    );
  }
}
