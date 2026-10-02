import 'package:flutter/material.dart';
import '../config/colors.dart';

// 小七文字气泡 — 云朵造型，右侧小尾巴指向机器人

class ChatBubble extends StatelessWidget {
  final String text;
  final Animation<double> animation;
  final bool appearing;

  const ChatBubble({
    super.key,
    required this.text,
    required this.animation,
    required this.appearing,
  });

  @override
  Widget build(BuildContext context) {
    final v = animation.value;
    final opacity = appearing ? v.clamp(0.0, 1.0) : (1.0 - v).clamp(0.0, 1.0);
    // 出现：从下方滑入+放大 / 消失：原地淡出，微微上飘
    final offsetY = appearing ? (1.0 - v) * 8.0 : (1.0 - v) * (-2.0);
    final scale = appearing ? 0.9 + v * 0.1 : 1.0;

    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, offsetY),
        child: Transform.scale(
          scale: scale,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 180, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                height: 20.0 / 14.0,
                color: AppColors.textPrimary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
