import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/home_chat_model_preferences.dart';

const _ink = Color(0xFF202124);
const _mutedInk = Color(0xFF686D73);
const _modelMenuMaxWidth = 320.0;
const _modelMenuGap = 11.0;
const _modelMenuHeight = 240.0;
const _modelMenuRadius = BorderRadius.all(Radius.circular(20));
const _modelMenuHeading = TextStyle(
  color: Color(0xFF626D79),
  fontSize: 17,
  fontWeight: FontWeight.w600,
);
const homeChatThinkingIconAsset =
    'assets/images/reading_companion_model_brain.svg';

class HomeChatModelSelector extends StatefulWidget {
  const HomeChatModelSelector({
    super.key,
    required this.selection,
    required this.onChanged,
    this.onOpen,
    this.enabled = true,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatModelSelection> onChanged;
  final VoidCallback? onOpen;
  final bool enabled;

  @override
  State<HomeChatModelSelector> createState() => _HomeChatModelSelectorState();
}

class _HomeChatModelSelectorState extends State<HomeChatModelSelector>
    with WidgetsBindingObserver {
  final _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  bool _overlayRefreshScheduled = false;
  bool _isPressed = false;

  bool get _isOpen => _entry != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => _scheduleOverlayRefresh();

  @override
  void didUpdateWidget(covariant HomeChatModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && _isOpen) {
      _closeMenu();
    }
    _scheduleOverlayRefresh();
  }

  void _scheduleOverlayRefresh() {
    final entry = _entry;
    if (entry == null || _overlayRefreshScheduled) return;
    _overlayRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRefreshScheduled = false;
      if (!mounted || !identical(entry, _entry)) return;
      entry.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeEntry();
    super.dispose();
  }

  void _toggleMenu() {
    if (_isOpen) {
      _closeMenu();
      return;
    }
    widget.onOpen?.call();
    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() {});
  }

  void _removeEntry() {
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    entry.remove();
    entry.dispose();
  }

  void _closeMenu() {
    _removeEntry();
    if (mounted) setState(() {});
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final anchorObject = _anchorKey.currentContext?.findRenderObject();
    if (anchorObject is! RenderBox || !anchorObject.hasSize) {
      return const SizedBox.shrink();
    }
    final overlayObject = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    final globalOrigin = anchorObject.localToGlobal(Offset.zero);
    final localOrigin = overlayObject is RenderBox
        ? overlayObject.globalToLocal(globalOrigin)
        : globalOrigin;
    final anchorRect = localOrigin & anchorObject.size;
    final media = MediaQuery.of(overlayContext);
    final viewport = media.size;
    final width = math.max(
      1.0,
      math.min(_modelMenuMaxWidth, viewport.width - 24),
    );
    final safeTop = media.padding.top + 8;
    final availableHeight = math.max(
      0.0,
      anchorRect.top - safeTop - _modelMenuGap,
    );
    final panelHeight = math.min(_modelMenuHeight, availableHeight);
    final left = (anchorRect.center.dx - width / 2)
        .clamp(12.0, viewport.width - width - 12)
        .toDouble();
    final top = anchorRect.top - panelHeight - _modelMenuGap;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeMenu,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: width,
            height: panelHeight,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 7 * (1 - value)),
                  child: child,
                ),
              ),
              child: HomeChatModelMenuSurface(
                child: SingleChildScrollView(
                  child: HomeChatModelPickerPanel(
                    selection: widget.selection,
                    onChanged: widget.onChanged,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isOpen) _closeMenu();
      },
      child: SizedBox.expand(
        child: Semantics(
          button: true,
          enabled: widget.enabled,
          expanded: _isOpen,
          label:
              '模型 ${widget.selection.model.name}，思考强度 ${widget.selection.reasoningLevel.label}',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onHighlightChanged: (pressed) {
                if (!widget.enabled) return;
                if (_isPressed != pressed) setState(() => _isPressed = pressed);
              },
              onTap: widget.enabled ? _toggleMenu : null,
              child: Center(
                child: AnimatedOpacity(
                  opacity: widget.enabled ? 1 : .45,
                  duration: const Duration(milliseconds: 120),
                  child: SizedBox(
                    key: _anchorKey,
                    width: double.infinity,
                    height: 40,
                    child: AnimatedScale(
                      scale: _isPressed ? .985 : 1,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      child: Center(
                        child: SvgPicture.asset(
                          homeChatThinkingIconAsset,
                          width: 19,
                          height: 19,
                          colorFilter: ColorFilter.mode(
                            Theme.of(context).colorScheme.onSurface,
                            BlendMode.srcIn,
                          ),
                          excludeFromSemantics: true,
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
}

class HomeChatModelMenuSurface extends StatelessWidget {
  const HomeChatModelMenuSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      borderRadius: _modelMenuRadius,
      boxShadow: [
        BoxShadow(
          color: Color(0x1A65717E),
          blurRadius: 16,
          offset: Offset(0, 4),
        ),
      ],
    ),
    foregroundDecoration: const BoxDecoration(
      borderRadius: _modelMenuRadius,
      border: Border.fromBorderSide(BorderSide(color: Color(0xFFDCE2E8))),
    ),
    child: ClipRRect(
      borderRadius: _modelMenuRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          // Preserve the source highlight and corner proportions in short menus.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _modelMenuHeight,
            child: SvgPicture.asset(
              'assets/images/home_model_picker_panel.svg',
              fit: BoxFit.fill,
              excludeFromSemantics: true,
            ),
          ),
          child,
        ],
      ),
    ),
  );
}

class HomeChatModelPickerPanel extends StatelessWidget {
  const HomeChatModelPickerPanel({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatModelSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('模型', style: _modelMenuHeading),
          const SizedBox(height: 4),
          for (
            var index = 0;
            index < HomeChatModelOption.options.length;
            index++
          ) ...[
            _ModelOptionRow(
              model: HomeChatModelOption.options[index],
              selected:
                  selection.model.id == HomeChatModelOption.options[index].id,
              onTap: () => onChanged(
                selection.withModel(HomeChatModelOption.options[index]),
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Divider(height: 1, color: Color(0xFFD6DDE5)),
          ),
          const SizedBox(height: 8),
          HomeChatReasoningPicker(
            selection: selection,
            onChanged: (level) => onChanged(selection.withReasoning(level)),
          ),
        ],
      ),
    );
  }
}

class HomeChatReasoningPicker extends StatelessWidget {
  const HomeChatReasoningPicker({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatReasoningLevel> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('思考强度', style: _modelMenuHeading),
      const SizedBox(height: 4),
      _ReasoningLevelControl(selection: selection, onChanged: onChanged),
    ],
  );
}

class _ReasoningLevelControl extends StatelessWidget {
  const _ReasoningLevelControl({
    required this.selection,
    required this.onChanged,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatReasoningLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    final levels = selection.model.reasoningLevels;
    final selectedIndex = levels.indexOf(
      selection.model.normalize(selection.reasoningLevel),
    );
    final hasThreeLevels = levels.length == 3;
    final trackAsset = hasThreeLevels
        ? 'assets/images/home_model_reasoning_track.svg'
        : 'assets/images/home_model_reasoning_track_mimo.svg';

    void selectAt(double x, double width) {
      final index = (x / (width / levels.length))
          .floor()
          .clamp(0, levels.length - 1)
          .toInt();
      final level = levels[index];
      if (level != selection.reasoningLevel) {
        onChanged(level);
      }
    }

    return SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = hasThreeLevels
              ? constraints.maxWidth
              : constraints.maxWidth * (2 / 3);
          final segmentWidth = width / levels.length;
          return Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: width,
              height: 48,
              child: Semantics(
                container: true,
                slider: true,
                label: '思考强度',
                value: levels[selectedIndex].label,
                decreasedValue: selectedIndex > 0
                    ? levels[selectedIndex - 1].label
                    : null,
                increasedValue: selectedIndex < levels.length - 1
                    ? levels[selectedIndex + 1].label
                    : null,
                onDecrease: selectedIndex > 0
                    ? () => onChanged(levels[selectedIndex - 1])
                    : null,
                onIncrease: selectedIndex < levels.length - 1
                    ? () => onChanged(levels[selectedIndex + 1])
                    : null,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        selectAt(details.localPosition.dx, width),
                    onHorizontalDragStart: (details) =>
                        selectAt(details.localPosition.dx, width),
                    onHorizontalDragUpdate: (details) =>
                        selectAt(details.localPosition.dx, width),
                    child: SizedBox.expand(
                      child: Center(
                        child: SizedBox(
                          height: 41,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: SvgPicture.asset(
                                  trackAsset,
                                  fit: BoxFit.fill,
                                  excludeFromSemantics: true,
                                ),
                              ),
                              AnimatedPositioned(
                                left: segmentWidth * selectedIndex + 2,
                                top: 2,
                                bottom: 2,
                                width: segmentWidth - 4,
                                duration: const Duration(milliseconds: 190),
                                curve: Curves.easeInOutCubic,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(24),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Color(0x1465717E),
                                          blurRadius: 4,
                                          offset: Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    child: SvgPicture.asset(
                                      'assets/images/home_model_reasoning_thumb.svg',
                                      fit: BoxFit.fill,
                                      excludeFromSemantics: true,
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (
                                    var index = 0;
                                    index < levels.length;
                                    index++
                                  )
                                    Expanded(
                                      child: Center(
                                        child: Text(
                                          levels[index].label,
                                          style: TextStyle(
                                            color: index == selectedIndex
                                                ? _ink
                                                : _mutedInk,
                                            fontSize: 15,
                                            fontWeight: index == selectedIndex
                                                ? FontWeight.w500
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
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
          );
        },
      ),
    );
  }
}

class _ModelOptionRow extends StatelessWidget {
  const _ModelOptionRow({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final HomeChatModelOption model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Semantics(
        button: true,
        selected: selected,
        label: model.name,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: SvgPicture.asset(
                        'assets/images/home_model_option_selected.svg',
                        fit: BoxFit.fill,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      model.iconAsset,
                      width: 27,
                      height: 27,
                      colorFilter: model.id == HomeChatModelOption.mimo.id
                          ? const ColorFilter.mode(
                              Color(0xFFFF6900),
                              BlendMode.srcIn,
                            )
                          : null,
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (selected)
                      SvgPicture.asset(
                        'assets/images/reading_task_check.svg',
                        width: 20,
                        height: 20,
                        colorFilter: const ColorFilter.mode(
                          _ink,
                          BlendMode.srcIn,
                        ),
                        excludeFromSemantics: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
