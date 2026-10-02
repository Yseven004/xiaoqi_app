import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Compact staging cluster for the black bottom bar (Quark-style).
///
/// Vertical thumb + 「完成」, widths matched, vertically centered in the bar
/// so the cluster reads as one unit beside the shutter.
class CameraStagingTray extends StatelessWidget {
  const CameraStagingTray({
    super.key,
    required this.paths,
    required this.onExpand,
    required this.onComplete,
    required this.thumbInteractive,
    required this.completeInteractive,
    this.thumbKey,
  });

  final List<String> paths;
  final VoidCallback onExpand;
  final VoidCallback onComplete;
  final bool thumbInteractive;
  final bool completeInteractive;
  final GlobalKey? thumbKey;

  static const double _thumbW = 52;
  static const double _thumbH = 52;

  /// Glass complete pill on black bar — translucent white reads as a capsule
  /// (black-on-black rgba(0,0,0,0.35) was invisible).
  static const Color _completeFill = Color(0x66FFFFFF);
  static const Color _completeBorder = Color(0x55FFFFFF);

  /// Badge: translucent white + black type
  static const Color _badgeFill = Color(0xCCFFFFFF);

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();

    final latest = paths.first;
    final file = File(latest);
    final exists = file.existsSync();

    return Column(
      key: const Key('staging_tray'),
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Opacity(
          opacity: thumbInteractive ? 1 : 0.45,
          child: GestureDetector(
            key: const Key('staging_thumb'),
            onTap: thumbInteractive ? onExpand : null,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                KeyedSubtree(
                  key: thumbKey,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: _thumbW,
                      height: _thumbH,
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
                Positioned(
                  top: -5,
                  left: -5,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: _badgeFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${paths.length}',
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: completeInteractive ? 1 : 0.45,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                decoration: BoxDecoration(
                  color: _completeFill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _completeBorder, width: 0.5),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const Key('staging_complete'),
                    onTap: completeInteractive ? onComplete : null,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      child: Text(
                        '完成',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
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
