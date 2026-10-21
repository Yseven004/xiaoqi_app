import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class MessageSelectionActionCard extends StatelessWidget {
  const MessageSelectionActionCard({
    super.key,
    required this.primaryLabel,
    required this.primaryAsset,
    required this.onPrimaryAction,
    this.onCopy,
    this.onAnnotate,
    this.primaryEnabled = true,
  });

  final String primaryLabel;
  final String primaryAsset;
  final bool primaryEnabled;
  final VoidCallback onPrimaryAction;
  final VoidCallback? onCopy;
  final VoidCallback? onAnnotate;

  Widget _actionButton({
    required String label,
    required String asset,
    required VoidCallback onPressed,
    bool enabled = true,
  }) => TextButton(
    onPressed: enabled ? onPressed : null,
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFF2B2F36),
      disabledForegroundColor: const Color(0xFFB8BBC0),
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset(
          asset,
          width: 18,
          height: 18,
          excludeFromSemantics: true,
          colorFilter: ColorFilter.mode(
            enabled ? const Color(0xFF2B2F36) : const Color(0xFFB8BBC0),
            BlendMode.srcIn,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 5,
    shadowColor: const Color(0x26000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFFE8E9EB)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionButton(
            label: primaryLabel,
            asset: primaryAsset,
            onPressed: onPrimaryAction,
            enabled: primaryEnabled,
          ),
          if (onCopy != null) ...[
            if (onAnnotate != null) ...[
              const SizedBox(width: 8),
              _actionButton(
                label: '注释',
                asset: 'assets/icons/chat_annotations/comment.svg',
                onPressed: onAnnotate!,
              ),
            ],
            const SizedBox(width: 8),
            _actionButton(
              label: '复制',
              asset: 'assets/images/home_reply_copy.svg',
              onPressed: onCopy!,
            ),
          ],
        ],
      ),
    ),
  );
}
