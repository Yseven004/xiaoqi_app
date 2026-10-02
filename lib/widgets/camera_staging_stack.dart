import 'dart:io';

import 'package:flutter/material.dart';

/// Right-edge staging cards: rise from the tray, settle as a bottom-up column
/// on the preview's right edge (does not change the bottom-bar tray).
///
/// Dismiss via tray re-tap or system back — blank barrier does not collapse
/// (avoids missing the × delete control).
class CameraStagingStack extends StatefulWidget {
  const CameraStagingStack({
    super.key,
    required this.paths,
    required this.onOpen,
    required this.onDelete,
  });

  final List<String> paths;
  final ValueChanged<int> onOpen;
  final ValueChanged<int> onDelete;

  @override
  State<CameraStagingStack> createState() => _CameraStagingStackState();
}

class _CameraStagingStackState extends State<CameraStagingStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const double _cardW = 76;
  static const double _cardH = 100;
  static const double _gap = 10;

  static const Duration _animDuration = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _animDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          if (mounted) setState(() {});
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Reverse-animate the cards out, then return so the caller can remove the
  /// widget from the tree.
  Future<void> dismiss() async {
    if (_controller.isDismissed) return;
    await _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Leave the black bar + tray alone; cards live only in the preview.
    // Match taller 88px bottom bar (thumb 52 + 完成).
    final barClearance = media.padding.bottom + 140;
    final topClearance = media.padding.top + 52;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: barClearance,
          child: const ColoredBox(
            // Dim preview only — do not dismiss on tap (easy to miss ×).
            key: Key('staging_stack_barrier'),
            color: Color(0x66000000),
          ),
        ),
        // Bottom-up column on the right edge of the viewfinder.
        Positioned(
          top: topClearance,
          bottom: barClearance + 8,
          right: 10,
          width: _cardW,
          child: IgnorePointer(
            ignoring: !_controller.isCompleted,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ListView.separated(
                reverse: true, // newest (index 0) nearest the tray
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
                itemCount: widget.paths.length,
                separatorBuilder: (_, _) => const SizedBox(height: _gap),
                itemBuilder: (context, index) {
                  final start = (index * 0.07).clamp(0.0, 0.65);
                  // Expand: easeOutCubic (decelerate in).
                  // Collapse: easeInCubic (accelerate out — feels controlled).
                  final isDismissing =
                      _controller.isDismissed ||
                      _controller.status == AnimationStatus.reverse;
                  final curve = isDismissing
                      ? Curves.easeInOutCubic
                      : Curves.easeOutCubic;
                  final animation = CurvedAnimation(
                    parent: _controller,
                    curve: Interval(start, 1.0, curve: curve),
                  );
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.55),
                        end: Offset.zero,
                      ).animate(animation),
                      child: _StackCard(
                        index: index,
                        path: widget.paths[index],
                        width: _cardW,
                        height: _cardH,
                        onOpen: () => widget.onOpen(index),
                        onDelete: () => widget.onDelete(index),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StackCard extends StatelessWidget {
  const _StackCard({
    required this.index,
    required this.path,
    required this.width,
    required this.height,
    required this.onOpen,
    required this.onDelete,
  });

  final int index;
  final String path;
  final double width;
  final double height;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final exists = file.existsSync();
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: Key('staging_stack_item_$index'),
              onTap: onOpen,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: exists
                      ? Image.file(
                          file,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              const ColoredBox(color: Color(0xFF333333)),
                        )
                      : const ColoredBox(color: Color(0xFF333333)),
                ),
              ),
            ),
          ),
          Positioned(
            top: -8,
            right: -8,
            child: Material(
              color: const Color(0xCC000000),
              shape: const CircleBorder(),
              child: InkWell(
                key: Key('staging_stack_delete_$index'),
                customBorder: const CircleBorder(),
                onTap: onDelete,
                child: const SizedBox(
                  width: 28,
                  height: 28,
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
