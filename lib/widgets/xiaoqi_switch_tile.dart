import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class XiaoqiSwitchTile extends StatelessWidget {
  const XiaoqiSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.iconAsset,
    this.onRetry,
    this.iconPadding = 3,
  });

  final String title;
  final String? subtitle;
  final String? iconAsset;
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onRetry;
  final double iconPadding;

  @override
  Widget build(BuildContext context) {
    final currentValue = value;
    final toggle = onChanged;
    final description = subtitle;
    final asset = iconAsset;
    return MergeSemantics(
      child: Semantics(
        toggled: currentValue,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          minTileHeight: 64,
          internalAddSemanticForOnTap: onRetry != null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: asset == null
              ? null
              : Container(
                  width: 40,
                  height: 40,
                  padding: EdgeInsets.all(iconPadding),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFE8E8E8)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SvgPicture.asset(asset, excludeFromSemantics: true),
                ),
          title: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          subtitle: description == null
              ? null
              : Text(
                  description,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B6B6B),
                  ),
                ),
          trailing: _SwitchIndicator(value: currentValue),
          onTap:
              onRetry ??
              (toggle != null && currentValue != null
                  ? () => toggle(!currentValue)
                  : null),
        ),
      ),
    );
  }
}

class _SwitchIndicator extends StatelessWidget {
  const _SwitchIndicator({required this.value});

  final bool? value;

  @override
  Widget build(BuildContext context) {
    const width = 44.0;
    const height = 24.0;
    const inset = 2.0;
    const thumbSize = height - 2 * inset;
    const travel = width - 2 * inset - thumbSize;
    final direction = Directionality.of(context) == TextDirection.ltr ? 1 : -1;

    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value == true ? 1.0 : 0.0),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(dimension: thumbSize),
          ),
          builder: (context, progress, thumb) => DecoratedBox(
            decoration: BoxDecoration(
              color: value == null
                  ? const Color(0xFFD5D8DE)
                  : Color.lerp(
                      const Color(0xFF858784),
                      const Color(0xFF247344),
                      progress,
                    ),
              borderRadius: const BorderRadius.all(Radius.circular(height / 2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(inset),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Transform.translate(
                  offset: Offset(travel * progress * direction, 0),
                  child: thumb,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
