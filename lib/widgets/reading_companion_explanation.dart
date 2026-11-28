import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_parsing/path_parsing.dart';

import '../models/reading_companion_evidence.dart';
import 'app_toast.dart';

enum _CloudSide { above, left, right, below }

// Keep this clipping path byte-for-byte aligned with the visible cloud SVG.
const _cloudOutlineSvgPath =
    'M31 135C10 128 3 116 8 98C-3 81 3 63 21 54C22 34 43 22 69 24C87 8 111 4 134 13C155 2 183 2 206 16C228 7 252 10 270 23C298 20 321 32 329 49C349 56 359 71 352 91C363 107 352 126 335 133C319 153 289 153 269 147C250 159 224 160 205 150C182 159 157 159 137 150C114 161 87 157 71 147C53 151 39 145 31 135Z';

class _ScaledCloudPathProxy implements PathProxy {
  const _ScaledCloudPathProxy(this.path, this.scaleX, this.scaleY);

  final Path path;
  final double scaleX;
  final double scaleY;

  @override
  void moveTo(double x, double y) => path.moveTo(x * scaleX, y * scaleY);

  @override
  void lineTo(double x, double y) => path.lineTo(x * scaleX, y * scaleY);

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    path.cubicTo(
      x1 * scaleX,
      y1 * scaleY,
      x2 * scaleX,
      y2 * scaleY,
      x3 * scaleX,
      y3 * scaleY,
    );
  }

  @override
  void close() => path.close();
}

class _CloudOutlineClipper extends CustomClipper<Path> {
  const _CloudOutlineClipper(this.outline);

  final Path outline;

  @override
  Path getClip(Size size) => outline;

  @override
  bool shouldReclip(covariant _CloudOutlineClipper oldClipper) =>
      oldClipper.outline != outline;
}

class _CloudTailOutlineClipper extends CustomClipper<Path> {
  const _CloudTailOutlineClipper(this.cloud, this.tailOrigin);

  final Path cloud;
  final Offset tailOrigin;

  @override
  Path getClip(Size size) => Path.combine(
    PathOperation.difference,
    Path()..addRect(Offset.zero & size),
    cloud.shift(-tailOrigin),
  );

  @override
  bool shouldReclip(covariant _CloudTailOutlineClipper oldClipper) =>
      oldClipper.cloud != cloud || oldClipper.tailOrigin != tailOrigin;
}

Path _cloudOutline(Size size) {
  final path = Path();
  writeSvgPathDataToPath(
    _cloudOutlineSvgPath,
    _ScaledCloudPathProxy(path, size.width / 360, size.height / 160),
  );
  return path;
}

// Find the intersection between the SVG outline and a line across its body.
double _cloudEdge(Path outline, Offset inside, Offset outside, Axis axis) {
  var near = inside;
  var far = outside;
  for (var step = 0; step < 12; step++) {
    final middle = (near + far) / 2;
    if (outline.contains(middle)) {
      near = middle;
    } else {
      far = middle;
    }
  }
  return axis == Axis.horizontal ? near.dx : near.dy;
}

// Match the first panel of the approved placement GIF. The other two panels
// stagger the same reveal to demonstrate their directions.
const _cloudEntryDuration = Duration(milliseconds: 1480);
const _cloudEntryFade = Interval(180 / 1480, 220 / 1480);
const _cloudEntryGrowth = Interval(200 / 1480, 1200 / 1480);

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
    this.regenerating = false,
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
  final bool regenerating;
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
    const aboveGap = 27.0;
    const minimumAboveGap = 8.0;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final width = math.min(
      560.0,
      viewport.width * (viewport.width < 420 ? 0.88 : 0.87),
    );
    final selectionLines = selectionRects.isEmpty
        ? [selection]
        : selectionRects;
    final topSelectionLine = selectionLines.reduce(
      (first, second) => first.top <= second.top ? first : second,
    );
    final bottomSelectionLine = selectionLines.reduce(
      (first, second) => first.bottom >= second.bottom ? first : second,
    );
    double heightFor(double cardWidth) {
      final minimumHeight = viewport.width < 420 ? 224.0 : 184.0;
      return math.min(
        230.0,
        math.max(minimumHeight, cardWidth * 0.432) +
            (textScale - 1).clamp(0.0, 2.0).toDouble() * 44.0,
      );
    }

    final preferredHeight = heightFor(width);
    final canPlaceAbove =
        selection.top - viewport.top >= preferredHeight + minimumAboveGap;
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
    double horizontalAnchor(Rect line) => viewport.width <= 600
        ? viewport.center.dx.clamp(line.left, line.right).toDouble()
        : line.center.dx;
    if (canPlaceAbove) {
      side = _CloudSide.above;
      rect = Rect.fromLTWH(
        (horizontalAnchor(topSelectionLine) - width / 2)
            .clamp(viewport.left, viewport.right - width)
            .toDouble(),
        math.max(viewport.top, selection.top - aboveGap - preferredHeight),
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
        (horizontalAnchor(bottomSelectionLine) - width / 2)
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
    final contentInset = math.min(54.0, cardWidth * 0.095);
    final contentRightInset = math.min(72.0, cardWidth * 0.157);
    final closeRight = cardWidth * 0.165 - 22;
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
      elevation: const WidgetStatePropertyAll(0),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final closeStyle = actionStyle.copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
      maximumSize: const WidgetStatePropertyAll(Size(44, 44)),
    );
    final canCopy = !pending && text.trim().isNotEmpty;
    final bodyText = Text(
      text.isNotEmpty
          ? text
          : failed
          ? '暂时无法解释这段'
          : '正在解释…',
      textAlign: TextAlign.start,
      style: TextStyle(color: scheme.onSurface, fontSize: 16, height: 1.45),
    );
    final copy = IconButton(
      key: const ValueKey('cloud-copy-action'),
      tooltip: '复制',
      style: closeStyle,
      icon: SvgPicture.asset(
        'assets/images/home_reply_copy.svg',
        width: 22,
        height: 22,
        colorFilter: ColorFilter.mode(scheme.onSurface, BlendMode.srcIn),
      ),
      onPressed: !canCopy
          ? null
          : () async {
              try {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) AppToast.show(context, '已复制解释');
              } on PlatformException {
                if (context.mounted) AppToast.show(context, '复制失败');
              }
            },
    );

    if (rect == null || width < 210) {
      final compactActions = <Widget>[if (canCopy) copy];
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
    final outline = _cloudOutline(cloudRect.size);
    final bodyTop = math.max(44.0, cloudRect.height * .225);
    final bodyLeft = _cloudEdge(
      outline,
      Offset(cloudRect.width / 2, bodyTop),
      Offset(-2, bodyTop),
      Axis.horizontal,
    );
    final bodyInsets = EdgeInsets.only(
      left: math.max(0.0, bodyLeft + 12 - contentInset),
      top: bodyTop - 19,
      right: math.max(0.0, closeRight + 44 + 8 - contentRightInset),
    );
    final horizontal = side == _CloudSide.above || side == _CloudSide.below;
    final Rect tailRect;
    if (horizontal) {
      final above = side == _CloudSide.above;
      final left = (horizontalAnchor(tailSelection) - cloudRect.left - 14)
          .clamp(28.0, cloudRect.width - 56)
          .toDouble();
      final edge = [
        for (final x in [left + 1, left + 14, left + 27])
          _cloudEdge(
            outline,
            Offset(x, cloudRect.height / 2),
            Offset(x, above ? cloudRect.height : 0),
            Axis.vertical,
          ),
      ].reduce(above ? math.min : math.max);
      final tip = above
          ? math.min(
              cloudRect.height + 18,
              tailSelection.top - cloudRect.top - 6,
            )
          : math.max(-18.0, tailSelection.bottom - cloudRect.top + 6);
      tailRect = above
          ? Rect.fromLTRB(left, edge - 3, left + 28, tip)
          : Rect.fromLTRB(left, tip, left + 28, edge + 3);
    } else {
      final right = side == _CloudSide.right;
      final centerY = tailSelection.center.dy - cloudRect.top;
      final edge = [
        for (final y in [centerY - 8, centerY, centerY + 8])
          _cloudEdge(
            outline,
            Offset(cloudRect.width / 2, y),
            Offset(right ? -2 : cloudRect.width + 2, y),
            Axis.horizontal,
          ),
      ].reduce(right ? math.max : math.min);
      final tip =
          (right ? tailSelection.right + 2 : tailSelection.left - 2) -
          cloudRect.left;
      tailRect = right
          ? Rect.fromLTRB(tip, centerY - 9, edge + 3, centerY + 9)
          : Rect.fromLTRB(edge - 3, centerY - 9, tip, centerY + 9);
    }
    final assetTint = dark
        ? const ColorFilter.mode(Color(0xFF373737), BlendMode.modulate)
        : null;
    final tailAsset = horizontal
        ? 'assets/images/reading_companion_explanation_tail.svg'
        : 'assets/images/reading_companion_explanation_side_tail.svg';
    Widget tailArt(ColorFilter? tint) => RotatedBox(
      quarterTurns: side == _CloudSide.below || side == _CloudSide.left ? 2 : 0,
      child: SvgPicture.asset(
        tailAsset,
        fit: BoxFit.fill,
        colorFilter: tint,
        excludeFromSemantics: true,
      ),
    );
    final shell = Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        SvgPicture.asset(
          'assets/images/reading_companion_explanation_cloud.svg',
          fit: BoxFit.fill,
          colorFilter: assetTint,
          excludeFromSemantics: true,
        ),
        Positioned.fromRect(
          key: const ValueKey('cloud-selection-tail'),
          rect: tailRect,
          // Fill over the original outline, then keep the stroke outside the
          // body. This leaves a single visible contour through the join.
          child: Stack(
            fit: StackFit.expand,
            children: [
              tailArt(ColorFilter.mode(scheme.surface, BlendMode.srcIn)),
              ClipPath(
                clipper: _CloudTailOutlineClipper(outline, tailRect.topLeft),
                child: tailArt(assetTint),
              ),
            ],
          ),
        ),
      ],
    );
    Widget actionIcon(String asset) => SvgPicture.asset(
      asset,
      width: 16,
      height: 16,
      colorFilter: ColorFilter.mode(scheme.onSurface, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final (tailTip, initialScale) = switch (side) {
      _CloudSide.above => (tailRect.bottomCenter, const Size(.18, .33)),
      _CloudSide.below => (tailRect.topCenter, const Size(.19, .38)),
      _CloudSide.left => (tailRect.centerRight, const Size(.32, .22)),
      _CloudSide.right => (tailRect.centerLeft, const Size(.32, .22)),
    };
    final actionWidgets = <Widget>[
      TextButton(
        key: const ValueKey('cloud-regenerate-action'),
        onPressed: pending ? null : onRegenerate,
        style: actionStyle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 16,
              child: pending
                  ? reduceMotion
                        ? null
                        : Padding(
                            padding: const EdgeInsets.all(2),
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: scheme.onSurface,
                            ),
                          )
                  : actionIcon('assets/images/home_reply_regenerate.svg'),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 63 * textScale,
              child: Text(
                pending
                    ? '生成中…'
                    : failed
                    ? '重试'
                    : '重新生成',
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(fontSize: 14),
              ),
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
            style: const TextStyle(fontSize: 14),
          ),
        ),
      if (onContinue != null)
        TextButton(
          key: const ValueKey('cloud-continue-action'),
          onPressed: onContinue,
          style: actionStyle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '继续聊',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(width: 5),
              actionIcon(
                'assets/icons/extension_market/detail/caret-right.svg',
              ),
            ],
          ),
        )
      else
        const SizedBox.shrink(),
    ];
    Widget footerActions() => LayoutBuilder(
      builder: (context, constraints) {
        const copyWidth = 44.0;
        final minimumWidth =
            copyWidth +
            math.max(44.0, 22 + 63 * textScale) * actionWidgets.length;
        final actions = Row(
          children: [
            SizedBox(width: copyWidth, child: canCopy ? copy : null),
            for (final action in actionWidgets)
              Expanded(child: Center(child: action)),
          ],
        );
        if (constraints.maxWidth < minimumWidth) {
          return SingleChildScrollView(
            key: const ValueKey('cloud-footer-overflow-scroll'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minimumWidth, child: actions),
          );
        }
        return actions;
      },
    );
    final initialLoading = pending && text.isEmpty && !failed;
    Widget content(bool settled, Widget shell) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        shell,
        if (settled)
          Positioned.fill(
            child: ClipPath(
              key: const ValueKey('cloud-outline-content-clip'),
              clipper: _CloudOutlineClipper(outline),
              child: Stack(
                children: [
                  if (!initialLoading)
                    Visibility(
                      visible: !regenerating,
                      maintainState: true,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          contentInset,
                          19,
                          contentRightInset,
                          15,
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: bodyInsets,
                                child: KeyedSubtree(
                                  key: ValueKey(answerVersion),
                                  child: ClipRect(
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: SingleChildScrollView(
                                        key: const ValueKey(
                                          'cloud-explanation-body-viewport',
                                        ),
                                        clipBehavior: Clip.hardEdge,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Semantics(
                                              liveRegion: !pending,
                                              child: canCopy
                                                  ? SelectionArea(
                                                      child: bodyText,
                                                    )
                                                  : bodyText,
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
                            SizedBox(height: 44, child: footerActions()),
                          ],
                        ),
                      ),
                    )
                  else
                    Semantics(liveRegion: true, label: '正在解释这段'),
                  if (regenerating)
                    Positioned.fill(
                      child: _CloudRegenerationPlaceholder(dark: dark),
                    ),
                  Positioned(
                    top: 37,
                    right: closeRight,
                    child: IconButton(
                      key: const ValueKey('cloud-close-action'),
                      tooltip: '关闭解释',
                      onPressed: onDismiss,
                      icon: SvgPicture.asset(
                        'assets/icons/extension_market/detail/close.svg',
                        width: 16,
                        height: 16,
                        colorFilter: ColorFilter.mode(
                          scheme.onSurface,
                          BlendMode.srcIn,
                        ),
                        excludeFromSemantics: true,
                      ),
                      style: closeStyle,
                    ),
                  ),
                ],
              ),
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
          child: reduceMotion
              ? content(true, shell)
              : TweenAnimationBuilder<double>(
                  duration: _cloudEntryDuration,
                  tween: Tween(begin: 0, end: 1),
                  child: shell,
                  builder: (context, progress, shell) {
                    final t = _cloudEntryGrowth.transform(progress);
                    final growth = t * t * (3 - 2 * t);
                    final scale = Size.lerp(
                      initialScale,
                      const Size(1, 1),
                      growth,
                    )!;
                    return Opacity(
                      opacity: _cloudEntryFade.transform(progress),
                      child: Transform.scale(
                        key: const ValueKey('cloud-entry-growth'),
                        origin: tailTip,
                        alignment: Alignment.topLeft,
                        scaleX: scale.width,
                        scaleY: scale.height,
                        child: content(progress == 1, shell!),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _CloudRegenerationPlaceholder extends StatefulWidget {
  const _CloudRegenerationPlaceholder({required this.dark});

  final bool dark;

  @override
  State<_CloudRegenerationPlaceholder> createState() =>
      _CloudRegenerationPlaceholderState();
}

class _CloudRegenerationPlaceholderState
    extends State<_CloudRegenerationPlaceholder>
    with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.dark
        ? const Color(0xFF515151)
        : const Color(0xFFE5E5E5);
    final sheen = widget.dark
        ? const Color(0xFF686868)
        : const Color(0xFFF3F3F3);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      key: const ValueKey('cloud-regeneration-placeholder'),
      liveRegion: true,
      label: '正在重新生成解释',
      child: IgnorePointer(
        child: Center(
          child: FractionallySizedBox(
            widthFactor: .66,
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) {
                final center = -1.5 + 3 * _sweep.value;
                final decoration = BoxDecoration(
                  color: rail,
                  gradient: reducedMotion
                      ? null
                      : LinearGradient(
                          begin: Alignment(center - .5, 0),
                          end: Alignment(center + .5, 0),
                          colors: [rail, sheen, rail],
                        ),
                  borderRadius: BorderRadius.circular(6),
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DecoratedBox(
                      decoration: decoration,
                      child: const SizedBox(height: 5),
                    ),
                    const SizedBox(height: 12),
                    FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: .72,
                      child: DecoratedBox(
                        decoration: decoration,
                        child: const SizedBox(height: 5),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class ReadingCompanionEvidenceLinks extends StatefulWidget {
  const ReadingCompanionEvidenceLinks({
    super.key,
    required this.evidence,
    required this.onOpen,
  });

  final List<ReadingCompanionEvidence> evidence;
  final ValueChanged<ReadingCompanionEvidence> onOpen;

  @override
  State<ReadingCompanionEvidenceLinks> createState() =>
      _ReadingCompanionEvidenceLinksState();
}

class _ReadingCompanionEvidenceLinksState
    extends State<ReadingCompanionEvidenceLinks> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.evidence.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return Colors.transparent;
        if (states.contains(WidgetState.focused)) {
          return scheme.primary.withValues(alpha: 0.12);
        }
        return Colors.transparent;
      }),
      splashFactory: NoSplash.splashFactory,
    );
    final shownPages = <(String, int)>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          expanded: _expanded,
          child: TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: style,
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            label: const Text('原文出处'),
          ),
        ),
        if (_expanded)
          Wrap(
            spacing: 4,
            children: [
              for (final entry in widget.evidence)
                if (entry.page == null ||
                    shownPages.add((entry.sourceVersion, entry.page!)))
                  TextButton(
                    key: ValueKey(entry.identity),
                    onPressed: () => widget.onOpen(entry),
                    style: style,
                    child: Text('查看原文 · ${entry.label}'),
                  ),
            ],
          ),
      ],
    );
  }
}
