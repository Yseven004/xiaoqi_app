import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/reading_companion_evidence.dart';

enum _CloudSide { above, left, right, below }

const _cloudLeftOutlineProfile = <(double, double)>[
  (0.0125, 0.50),
  (0.15, 0.192),
  (0.3375, 0.058),
  (0.50625, -0.008),
  (0.6125, 0.022),
  (0.84375, 0.086),
  (0.91875, 0.197),
  (0.9875, 0.30),
  (1.0, 0.50),
];

const _cloudRightOutlineProfile = <(double, double)>[
  (0.0125, 0.50),
  (0.15, 0.75),
  (0.3375, 0.914),
  (0.50625, 0.997),
  (0.6125, 0.978),
  (0.84375, 0.931),
  (0.91875, 0.747),
  (0.9875, 0.72),
  (1.0, 0.50),
];

double _outlineXAtY(List<(double, double)> profile, double y) {
  final yClamped = y.clamp(profile.first.$1, profile.last.$1).toDouble();
  for (var index = 1; index < profile.length; index++) {
    final previous = profile[index - 1];
    final current = profile[index];
    if (yClamped > current.$1) continue;
    final progress = (yClamped - previous.$1) / (current.$1 - previous.$1);
    return previous.$2 + (current.$2 - previous.$2) * progress;
  }
  return profile.last.$2;
}

class ReadingCompanionExplanationCloud extends StatelessWidget {
  const ReadingCompanionExplanationCloud({
    super.key,
    required this.viewport,
    required this.selection,
    this.selectionRects = const [],
    this.answerVersion,
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
  final List<Rect> selectionRects;
  final Object? answerVersion;
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
    final width = math.min(560.0, viewport.width * 0.88);
    final selectionLines = selectionRects.isEmpty
        ? [selection]
        : selectionRects;
    final topSelectionLine = selectionLines.reduce(
      (first, second) => first.top <= second.top ? first : second,
    );
    final bottomSelectionLine = selectionLines.reduce(
      (first, second) => first.bottom >= second.bottom ? first : second,
    );
    double heightFor(double cardWidth) => math.min(
      230.0,
      math.max(224.0, cardWidth * 0.43) +
          (textScale - 1).clamp(0.0, 2.0).toDouble() * 44.0,
    );

    final preferredHeight = heightFor(width);
    final canPlaceAbove =
        selection.top - viewport.top >= preferredHeight + gap - 12;
    final sideCandidates = <({_CloudSide side, Rect rect, Rect anchor})>[];
    if (!canPlaceAbove) {
      for (final line in selectionLines) {
        for (final candidateSide in [_CloudSide.left, _CloudSide.right]) {
          final availableWidth = candidateSide == _CloudSide.right
              ? viewport.right - line.right - gap
              : line.left - viewport.left - gap;
          if (availableWidth < 222) continue;

          final candidateWidth = math.min(width, availableWidth);
          final candidateHeight = heightFor(candidateWidth);
          if (viewport.height < candidateHeight) continue;
          final minimumTop = math.max(
            viewport.top,
            line.center.dy - candidateHeight + 39.0,
          );
          final maximumTop = math.min(
            viewport.bottom - candidateHeight,
            line.center.dy - 39.0,
          );
          if (minimumTop > maximumTop) continue;

          final candidateLeft = candidateSide == _CloudSide.right
              ? line.right + gap
              : line.left - gap - candidateWidth;
          final targetTop = (line.center.dy - candidateHeight / 2)
              .clamp(minimumTop, maximumTop)
              .toDouble();
          final blockingLines =
              selectionLines
                  .where(
                    (otherLine) =>
                        candidateLeft < otherLine.right &&
                        otherLine.left < candidateLeft + candidateWidth,
                  )
                  .toList()
                ..sort((first, second) => first.top.compareTo(second.top));

          // Convert each intersecting line into the forbidden range for the
          // cloud's top, then merge those ranges. This avoids testing every
          // candidate height against every selected line (cubic work).
          var freeStart = minimumTop;
          var bestTop = double.infinity;
          var bestDistance = double.infinity;
          void considerFreeRange(double rangeStart, double rangeEnd) {
            if (rangeStart > rangeEnd) return;
            final candidateTop = targetTop
                .clamp(rangeStart, rangeEnd)
                .toDouble();
            final distance = (candidateTop - targetTop).abs();
            if (distance < bestDistance) {
              bestTop = candidateTop;
              bestDistance = distance;
            }
          }

          for (final blockingLine in blockingLines) {
            final forbiddenStart = blockingLine.top - candidateHeight;
            final forbiddenEnd = blockingLine.bottom;
            if (forbiddenEnd < freeStart) continue;
            if (forbiddenStart >= freeStart) {
              considerFreeRange(
                freeStart,
                math.min(maximumTop, forbiddenStart),
              );
            }
            freeStart = math.max(freeStart, forbiddenEnd);
            if (freeStart > maximumTop) break;
          }
          considerFreeRange(freeStart, maximumTop);
          if (!bestTop.isFinite) continue;

          sideCandidates.add((
            side: candidateSide,
            rect: Rect.fromLTWH(
              candidateLeft,
              bestTop,
              candidateWidth,
              candidateHeight,
            ),
            anchor: line,
          ));
        }
      }
    }
    sideCandidates.sort((first, second) {
      final widthOrder = second.rect.width.compareTo(first.rect.width);
      if (widthOrder != 0) return widthOrder;
      final firstDistance = (first.anchor.center.dy - selection.center.dy)
          .abs();
      final secondDistance = (second.anchor.center.dy - selection.center.dy)
          .abs();
      return firstDistance.compareTo(secondDistance);
    });

    late final _CloudSide side;
    final Rect? rect;
    late final Rect tailSelection;
    if (canPlaceAbove) {
      side = _CloudSide.above;
      rect = Rect.fromLTWH(
        (topSelectionLine.center.dx - width / 2)
            .clamp(viewport.left, viewport.right - width)
            .toDouble(),
        math.max(viewport.top, selection.top - gap - preferredHeight),
        width,
        preferredHeight,
      );
      tailSelection = topSelectionLine;
    } else if (sideCandidates.isNotEmpty) {
      final placement = sideCandidates.first;
      side = placement.side;
      rect = placement.rect;
      tailSelection = placement.anchor;
    } else if (selection.bottom + preferredHeight + gap <= viewport.bottom) {
      side = _CloudSide.below;
      rect = Rect.fromLTWH(
        (bottomSelectionLine.center.dx - width / 2)
            .clamp(viewport.left, viewport.right - width)
            .toDouble(),
        selection.bottom + gap,
        width,
        preferredHeight,
      );
      tailSelection = bottomSelectionLine;
    } else {
      side = _CloudSide.above;
      rect = null;
      tailSelection = selection;
    }

    final cardWidth = rect?.width ?? width;
    final contentInset = math.min(54.0, cardWidth * 0.10);
    final baseScheme = Theme.of(context).colorScheme;
    final scheme = baseScheme.copyWith(
      surface: dark ? const Color(0xFF373737) : Colors.white,
      onSurface: dark ? Colors.white : const Color(0xFF24272C),
      primary: dark ? Colors.white : const Color(0xFF24272C),
    );
    final actionOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) return Colors.transparent;
      if (states.contains(WidgetState.focused)) {
        return scheme.primary.withValues(alpha: 0.12);
      }
      return Colors.transparent;
    });
    final actionStyle = ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
      overlayColor: actionOverlay,
      splashFactory: NoSplash.splashFactory,
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final closeStyle = actionStyle.copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
      maximumSize: const WidgetStatePropertyAll(Size(44, 44)),
    );

    if (rect == null || width < 210) {
      final compactActions = <Widget>[];
      if (pending) {
        compactActions.add(
          TextButton(
            key: const ValueKey('cloud-compact-progress-action'),
            onPressed: null,
            style: actionStyle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('生成中…'),
              ],
            ),
          ),
        );
        if (onContinue != null) {
          compactActions.add(
            TextButton(
              key: const ValueKey('cloud-compact-continue-action'),
              onPressed: onContinue,
              style: actionStyle,
              child: const Text('继续聊 ›'),
            ),
          );
        }
      } else if (failed) {
        compactActions.add(
          TextButton(
            key: const ValueKey('cloud-compact-retry-action'),
            onPressed: onRegenerate,
            style: actionStyle,
            child: const Text('重试解释'),
          ),
        );
        if (onContinue != null) {
          compactActions.add(
            TextButton(
              key: const ValueKey('cloud-compact-continue-action'),
              onPressed: onContinue,
              style: actionStyle,
              child: const Text('查看解释'),
            ),
          );
        }
      } else if (onContinue != null) {
        compactActions.add(
          TextButton(
            key: const ValueKey('cloud-compact-continue-action'),
            onPressed: onContinue,
            style: actionStyle,
            child: const Text('查看解释'),
          ),
        );
      }

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
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(88.0, viewport.width - 24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: compactActions,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭解释',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onDismiss,
                    style: closeStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final cloudRect = rect;
    final horizontal = side == _CloudSide.above || side == _CloudSide.below;
    final tailX = (tailSelection.center.dx - cloudRect.left - 14)
        .clamp(28.0, cloudRect.width - 56)
        .toDouble();
    const sideTailHeight = 18.0;
    late final double sideTailLeft;
    late final double sideTailWidth;
    late final double sideTailTop;
    if (horizontal) {
      sideTailLeft = 0;
      sideTailWidth = 0;
      sideTailTop = 0;
    } else {
      final anchorY = tailSelection.center.dy;
      final normalizedY = (anchorY - cloudRect.top) / cloudRect.height;
      final yRadius = sideTailHeight / 2 / cloudRect.height;
      final profile = side == _CloudSide.right
          ? _cloudLeftOutlineProfile
          : _cloudRightOutlineProfile;
      final edgeSamples = [
        _outlineXAtY(profile, normalizedY - yRadius),
        _outlineXAtY(profile, normalizedY),
        _outlineXAtY(profile, normalizedY + yRadius),
      ];
      final insetFraction = side == _CloudSide.right
          ? edgeSamples.reduce(math.max)
          : edgeSamples.reduce(math.min);
      final boundaryX = cloudRect.left + cloudRect.width * insetFraction;
      final tipX = side == _CloudSide.right
          ? tailSelection.right + 2
          : tailSelection.left - 2;
      final tailStartX = side == _CloudSide.right ? tipX : boundaryX;
      final tailEndX = side == _CloudSide.right ? boundaryX : tipX;
      sideTailLeft = tailStartX - cloudRect.left;
      sideTailWidth = math.max(1.0, tailEndX - tailStartX).toDouble();
      sideTailTop = anchorY - cloudRect.top - sideTailHeight / 2;
    }
    final assetTint = dark
        ? const ColorFilter.mode(Color(0xFF373737), BlendMode.modulate)
        : null;
    final actionWidgets = <Widget>[
      TextButton(
        key: const ValueKey('cloud-regenerate-action'),
        onPressed: pending ? null : onRegenerate,
        style: actionStyle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: scheme.onSurface,
                ),
              ),
            if (pending) const SizedBox(width: 6),
            Text(
              pending
                  ? '生成中…'
                  : failed
                  ? '重试'
                  : '重新生成',
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      if (onSwitchAnswer != null)
        TextButton(
          key: const ValueKey('cloud-switch-answer-action'),
          onPressed: onSwitchAnswer,
          style: actionStyle,
          child: Text(
            showingPrevious ? '下一条' : '上一条',
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      if (onContinue != null)
        TextButton(
          key: const ValueKey('cloud-continue-action'),
          onPressed: onContinue,
          style: actionStyle,
          child: const Text(
            '继续聊 ›',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(fontSize: 13),
          ),
        ),
    ];
    Widget footerActions() => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < actionWidgets.length * 96 * textScale) {
          return SingleChildScrollView(
            key: const ValueKey('cloud-footer-overflow-scroll'),
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: actionWidgets,
              ),
            ),
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: actionWidgets,
        );
      },
    );
    Widget content(bool settled) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          key: const ValueKey('cloud-selection-tail'),
          left: horizontal ? tailX : sideTailLeft,
          top: horizontal
              ? side == _CloudSide.below
                    ? -10
                    : cloudRect.height - 11
              : sideTailTop,
          width: horizontal ? 28 : sideTailWidth,
          height: horizontal ? 18 : sideTailHeight,
          child: horizontal
              ? RotatedBox(
                  quarterTurns: side == _CloudSide.below ? 2 : 0,
                  child: SvgPicture.asset(
                    'assets/images/reading_companion_explanation_tail.svg',
                    fit: BoxFit.fill,
                    colorFilter: assetTint,
                    excludeFromSemantics: true,
                  ),
                )
              : RotatedBox(
                  quarterTurns: side == _CloudSide.left ? 2 : 0,
                  child: SvgPicture.asset(
                    'assets/images/reading_companion_explanation_side_tail.svg',
                    fit: BoxFit.fill,
                    colorFilter: assetTint,
                    excludeFromSemantics: true,
                  ),
                ),
        ),
        SvgPicture.asset(
          'assets/images/reading_companion_explanation_cloud.svg',
          fit: BoxFit.fill,
          colorFilter: assetTint,
          excludeFromSemantics: true,
        ),
        if (settled)
          Padding(
            padding: EdgeInsets.fromLTRB(contentInset, 19, contentInset, 15),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned(
                        top: 18,
                        right: 16,
                        child: IconButton(
                          key: const ValueKey('cloud-close-action'),
                          tooltip: '关闭解释',
                          onPressed: onDismiss,
                          icon: const Icon(Icons.close, size: 18),
                          style: closeStyle,
                        ),
                      ),
                      Positioned(
                        top: 60,
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: KeyedSubtree(
                          key: ValueKey(answerVersion),
                          child: ClipRect(
                            child: SingleChildScrollView(
                              key: const ValueKey(
                                'cloud-explanation-body-viewport',
                              ),
                              clipBehavior: Clip.hardEdge,
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
                                        fontSize: 16,
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                  if (onOpenEvidence != null)
                                    ReadingCompanionEvidenceLinks(
                                      evidence: evidence,
                                      onOpen: onOpenEvidence!,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: dark
                      ? const Color(0x44FFFFFF)
                      : const Color(0x33000000),
                ),
                const SizedBox(height: 4),
                SizedBox(height: 44, child: footerActions()),
              ],
            ),
          ),
      ],
    );

    return Positioned.fromRect(
      rect: cloudRect,
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
            builder: (context, value, child) {
              final origin = switch (side) {
                _CloudSide.above => Alignment.bottomCenter,
                _CloudSide.left => Alignment.centerRight,
                _CloudSide.right => Alignment.centerLeft,
                _CloudSide.below => Alignment.topCenter,
              };
              return Opacity(
                opacity: value,
                child: Transform.scale(
                  key: const ValueKey('cloud-entry-scale'),
                  alignment: origin,
                  scale: 0.68 + value * 0.32,
                  child: content(value == 1),
                ),
              );
            },
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
            style: ButtonStyle(
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return Colors.transparent;
                }
                if (states.contains(WidgetState.focused)) {
                  return Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.12);
                }
                return Colors.transparent;
              }),
              splashFactory: NoSplash.splashFactory,
            ),
            child: Text('查看原文 · ${entry.label}'),
          ),
      ],
    );
  }
}
