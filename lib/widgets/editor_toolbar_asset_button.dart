import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Frozen toolbar assets shared by the book-page reader and editor.
abstract final class EditorToolbarAssets {
  static const _root = 'assets/icons/editor';

  static const bookPageA = '$_root/book_page_a.png';
  static const undoA = '$_root/undo_a.png';
  static const redoA = '$_root/redo_a.png';
  static const undoBFilled = '$_root/undo_b_filled.png';
  static const redoBFilled = '$_root/redo_b_filled.png';
  static const aiC = '$_root/ai_c.png';
  static const imageA = '$_root/image_a.png';
  static const voiceA = '$_root/voice_a.png';
  static const noteA = '$_root/note_a.png';
}

/// Toolbar button that renders one of the frozen editor icon assets.
class EditorToolbarAssetButton extends StatelessWidget {
  const EditorToolbarAssetButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.assetPath,
    required this.color,
    this.iconSize = 27,
    this.buttonExtent = 52,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final String assetPath;
  final Color color;
  final double iconSize;
  final double buttonExtent;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: SizedBox.square(
        dimension: iconSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: .7,
              top: 1,
              child: Opacity(
                opacity: .2,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: .7, sigmaY: .7),
                  child: SizedBox.square(
                    dimension: iconSize,
                    child: _assetImage(Colors.black),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: _assetImage(color)),
          ],
        ),
      ),
      padding: const EdgeInsets.all(10),
      constraints: BoxConstraints(
        minWidth: buttonExtent,
        minHeight: buttonExtent,
      ),
    );
  }

  Widget _assetImage(Color tint) {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      ),
    );
  }
}
