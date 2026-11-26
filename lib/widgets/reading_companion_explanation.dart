import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/reading_companion_evidence.dart';

enum _CloudSide { above, left, right, below }

class ReadingCompanionExplanationCloud extends StatelessWidget {
  const ReadingCompanionExplanationCloud({
    super.key,
    required this.viewport,
    required this.selection,
    required this.dark,
    required this.text,
    required this.pending,
    required this.failed,
    required this.onDismiss,
    required this.onRegenerate,
    required this.onContinue,
    this.onSwitchAnswer,
    this.showingPrevious = false,
    this.evidence = const [],
    this.onOpenEvidence,
  });

  final Rect viewport;
  final Rect selection;
  final bool dark;
  final String text;
  final bool pending;
  final bool failed;
  final VoidCallback onDismiss;
  final VoidCallback onRegenerate;
  final VoidCallback? onContinue;
  final VoidCallback? onSwitchAnswer;
  final bool showingPrevious;
  final List<ReadingCompanionEvidence> evidence;
  final ValueChanged<ReadingCompanionEvidence>? onOpenEvidence;

  @override
  Widget build(BuildContext context) {
    const gap = 16.0;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final width = math.min(420.0, viewport.width);
    final height = math.min(
      230.0,
      162.0 + (textScale - 1).clamp(0.0, 2.0).toDouble() * 44.0,
    );
    final centerX = (selection.center.dx - width / 2)
        .clamp(viewport.left, viewport.right - width)
        .toDouble();
    final centerY = (selection.center.dy - height / 2)
        .clamp(viewport.top, math.max(viewport.top, viewport.bottom - height))
        .toDouble();
    final right = viewport.right - selection.right - gap;
    final left = selection.left - viewport.left - gap;
    final sideWidth = math.min(width, math.max(left, right));
    final (side, rect) = switch ((
      selection.top - viewport.top >= height + gap,
      sideWidth >= 222 && viewport.height >= height,
      selection.bottom + height + gap <= viewport.bottom,
    )) {
      (true, _, _) => (
        _CloudSide.above,
        Rect.fromLTWH(centerX, selection.top - gap - height, width, height),
      ),
      (false, true, _) when right >= left => (
        _CloudSide.right,
        Rect.fromLTWH(selection.right + gap, centerY, sideWidth, height),
      ),
      (false, true, _) => (
        _CloudSide.left,
        Rect.fromLTWH(
          selection.left - gap - sideWidth,
          centerY,
          sideWidth,
          height,
        ),
      ),
      (false, false, true) => (
        _CloudSide.below,
        Rect.fromLTWH(centerX, selection.bottom + gap, width, height),
      ),
      _ => (_CloudSide.above, null),
    };

    final scheme = dark ? const ColorScheme.dark() : const ColorScheme.light();
    if (rect == null || width < 210) {
      return Positioned(
        left: viewport.left,
        right: 12,
        top: viewport.top,
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(22),
            elevation: 3,
            clipBehavior: Clip.antiAlias,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: failed ? onRegenerate : onContinue,
                  child: Text(
                    failed
                        ? '重试解释'
                        : pending
                        ? '正在解释'
                        : '查看解释',
                  ),
                ),
                IconButton(
                  tooltip: '关闭解释',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final horizontal = side == _CloudSide.above || side == _CloudSide.below;
    final tailX = (selection.center.dx - rect.left - 14)
        .clamp(28.0, rect.width - 56)
        .toDouble();
    final tailY = (selection.center.dy - rect.top - 14)
        .clamp(25.0, rect.height - 53)
        .toDouble();
    final assetTint = dark
        ? const ColorFilter.mode(Color(0xFF373737), BlendMode.modulate)
        : null;
    Widget content(bool settled) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        SvgPicture.asset(
          'assets/images/reading_companion_explanation_cloud.svg',
          fit: BoxFit.fill,
          colorFilter: assetTint,
          excludeFromSemantics: true,
        ),
        Positioned(
          left: horizontal
              ? tailX
              : side == _CloudSide.right
              ? -17
              : rect.width - 11,
          top: horizontal
              ? side == _CloudSide.below
                    ? -10
                    : rect.height - 11
              : tailY,
          width: 28,
          height: 18,
          child: RotatedBox(
            quarterTurns: switch (side) {
              _CloudSide.above => 0,
              _CloudSide.left => 3,
              _CloudSide.right => 1,
              _CloudSide.below => 2,
            },
            child: SvgPicture.asset(
              'assets/images/reading_companion_explanation_tail.svg',
              fit: BoxFit.fill,
              colorFilter: assetTint,
              excludeFromSemantics: true,
            ),
          ),
        ),
        if (settled)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 17),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  liveRegion: !pending,
                                  child: Text(
                                    text.isNotEmpty
                                        ? text
                                        : failed
                                        ? '暂时无法解释这段'
                                        : '正在解释…',
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 15,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                                if (!pending && onOpenEvidence != null)
                                  ReadingCompanionEvidenceLinks(
                                    evidence: evidence,
                                    onOpen: onOpenEvidence!,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭解释',
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
                if (pending)
                  const SizedBox(
                    height: 44,
                    child: Center(child: LinearProgressIndicator()),
                  )
                else
                  SizedBox(
                    height: 44,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: onRegenerate,
                            child: Text(failed ? '重试' : '重新生成'),
                          ),
                          if (onSwitchAnswer != null)
                            TextButton(
                              onPressed: onSwitchAnswer,
                              child: Text(showingPrevious ? '下一条' : '上一条'),
                            ),
                          if (onContinue != null)
                            TextButton(
                              onPressed: onContinue,
                              child: const Text('继续聊 ›'),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    return Positioned.fromRect(
      rect: rect,
      child: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: scheme,
          iconTheme: IconThemeData(color: scheme.onSurface),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: TweenAnimationBuilder<double>(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 480),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: 1),
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(math.sin(value * math.pi) * 9, 19 * (1 - value)),
                child: content(value == 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReadingCompanionEvidenceLinks extends StatelessWidget {
  const ReadingCompanionEvidenceLinks({
    super.key,
    required this.evidence,
    required this.onOpen,
  });

  final List<ReadingCompanionEvidence> evidence;
  final ValueChanged<ReadingCompanionEvidence> onOpen;

  @override
  Widget build(BuildContext context) {
    if (evidence.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      children: [
        for (final entry in evidence)
          TextButton(
            key: ValueKey(entry.identity),
            onPressed: () => onOpen(entry),
            child: Text('查看原文 · ${entry.label}'),
          ),
      ],
    );
  }
}
