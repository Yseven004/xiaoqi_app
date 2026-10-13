import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Skills and MCP capsule styled to match the untouched reading capsule.
class ComposerActionCapsule extends StatelessWidget {
  const ComposerActionCapsule({
    required this.label,
    required this.iconAsset,
    required this.expanded,
    this.onTap,
    super.key,
  });

  final String label;
  final String iconAsset;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      button: true,
      enabled: onTap != null,
      expanded: expanded,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          radius: 16,
          splashColor: const Color(0x12252932),
          highlightColor: Colors.transparent,
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1B17212B),
                      blurRadius: 22,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xEFFFFFFF),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: const Color(0xDFFFFFFF)),
                      ),
                      child: AnimatedOpacity(
                        opacity: expanded ? .55 : 1,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeInOut,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvgPicture.asset(iconAsset, width: 18, height: 18),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF252932),
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            AnimatedRotation(
                              turns: expanded ? .5 : 0,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeInOut,
                              child: Icon(
                                PhosphorIconsRegular.caretDown,
                                size: 14,
                                color: const Color(0xFF737A84),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
