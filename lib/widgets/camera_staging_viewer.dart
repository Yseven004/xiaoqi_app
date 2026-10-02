import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Shared glass fill for capsules + page indicator (visual consistency).
const Color _kGlassFill = Color(0x66FFFFFF);
const Color _kGlassBorder = Color(0x55FFFFFF);

/// 全屏查看暂存照片：顶部独立删除，底部编辑 + 完成。
class CameraStagingViewer extends StatefulWidget {
  const CameraStagingViewer({
    super.key,
    required this.paths,
    required this.initialIndex,
    required this.onDelete,
    required this.onEdit,
    required this.onComplete,
    required this.onClose,
  });

  final List<String> paths;
  final int initialIndex;
  final ValueChanged<int> onDelete;
  final ValueChanged<int> onEdit;
  final VoidCallback onComplete;
  final VoidCallback onClose;

  @override
  State<CameraStagingViewer> createState() => _CameraStagingViewerState();
}

class _CameraStagingViewerState extends State<CameraStagingViewer> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.paths.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void didUpdateWidget(covariant CameraStagingViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paths.isEmpty) return;
    if (_index >= widget.paths.length) {
      _index = widget.paths.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(_index);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.paths.isEmpty) {
      return const SizedBox.shrink();
    }

    final photoHeight = MediaQuery.sizeOf(context).height * 2 / 3;

    return Material(
      color: const Color(0xE6000000),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: SizedBox(
              height: photoHeight,
              width: double.infinity,
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.paths.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final file = File(widget.paths[i]);
                  final exists = file.existsSync();
                  return exists
                      ? Image.file(
                          file,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 48,
                          ),
                        )
                      : const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                          size: 48,
                        );
                },
              ),
            ),
          ),
          Positioned(
            top: 4,
            left: 4,
            child: SafeArea(
              child: IconButton(
                key: const Key('staging_viewer_close'),
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: SafeArea(
              child: IconButton(
                key: const Key('staging_viewer_delete'),
                tooltip: '删除当前照片',
                onPressed: () => widget.onDelete(_index),
                icon: const Icon(
                  Icons.delete_outline,
                  color: AppColors.error,
                  size: 24,
                ),
              ),
            ),
          ),
          if (widget.paths.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 88,
              child: SafeArea(
                top: false,
                child: _GlassPageIndicator(
                  key: const Key('staging_viewer_page_indicator'),
                  count: widget.paths.length,
                  index: _index,
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 16,
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _GlassCapsule(
                    key: const Key('staging_viewer_edit'),
                    label: '编辑',
                    onTap: () => widget.onEdit(_index),
                  ),
                  _GlassCapsule(
                    key: const Key('staging_viewer_complete'),
                    label: '完成',
                    fillColor: AppColors.accent,
                    borderColor: AppColors.accent,
                    onTap: widget.onComplete,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill + dots under the photo — same glass tint as the secondary action.
class _GlassPageIndicator extends StatelessWidget {
  const _GlassPageIndicator({
    super.key,
    required this.count,
    required this.index,
  });

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 20 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: _kGlassFill,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _kGlassBorder),
          ),
        );
      }),
    );
  }
}

class _GlassCapsule extends StatelessWidget {
  const _GlassCapsule({
    super.key,
    required this.label,
    required this.onTap,
    this.fillColor = _kGlassFill,
    this.borderColor = _kGlassBorder,
  });

  final String label;
  final VoidCallback onTap;
  final Color fillColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: fillColor,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
