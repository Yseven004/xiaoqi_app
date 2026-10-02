import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/home_chat_model_preferences.dart';

const _ink = Color(0xFF202124);
const _mutedInk = Color(0xFF686D73);
const _modelMenuMaxWidth = 320.0;
const _modelMenuGap = 11.0;

class HomeChatModelSelector extends StatefulWidget {
  const HomeChatModelSelector({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatModelSelection> onChanged;

  @override
  State<HomeChatModelSelector> createState() =>
      _HomeChatModelSelectorState();
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
    final width = math.max(1.0, math.min(_modelMenuMaxWidth, viewport.width - 24));
    const preferredPanelHeight = 240.0;
    final safeTop = media.padding.top + 8;
    final availableHeight = math.max(
      0.0,
      anchorRect.top - safeTop - _modelMenuGap,
    );
    final panelHeight = math.min(preferredPanelHeight, availableHeight);
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
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A65717E),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SvgPicture.asset(
                        'assets/images/home_model_picker_panel.svg',
                        fit: BoxFit.fill,
                        excludeFromSemantics: true,
                      ),
                      SingleChildScrollView(
                        child: HomeChatModelPickerPanel(
                          selection: widget.selection,
                          onChanged: widget.onChanged,
                          isHomeOverlay: true,
                        ),
                      ),
                    ],
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
          expanded: _isOpen,
          label:
              '模型 ${widget.selection.model.name}，思考程度 ${widget.selection.reasoningLevel.label}',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onHighlightChanged: (pressed) {
                if (_isPressed != pressed) setState(() => _isPressed = pressed);
              },
              onTap: _toggleMenu,
              child: Center(
                child: Container(
                  key: _anchorKey,
                  width: double.infinity,
                  height: 40,
                  child: AnimatedScale(
                    scale: _isPressed ? .985 : 1,
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: SvgPicture.asset(
                            'assets/images/home_model_selector_button.svg',
                            fit: BoxFit.fill,
                            excludeFromSemantics: true,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              SvgPicture.asset(
                                widget.selection.model.iconAsset,
                                width: 22,
                                height: 22,
                                colorFilter:
                                    widget.selection.model.id ==
                                            HomeChatModelOption.mimo.id
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
                                  widget.selection.model.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              AnimatedRotation(
                                turns: _isOpen ? .5 : 0,
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeInOut,
                                child: Icon(
                                  PhosphorIcons.caretDown(
                                    PhosphorIconsStyle.regular,
                                  ),
                                  size: 15,
                                  color: _mutedInk,
                                ),
                              ),
                            ],
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
    );
  }
}

class HomeChatModelPickerPanel extends StatelessWidget {
  const HomeChatModelPickerPanel({
    super.key,
    required this.selection,
    required this.onChanged,
    this.isHomeOverlay = false,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatModelSelection> onChanged;
  final bool isHomeOverlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isHomeOverlay ? 16 : 18,
        isHomeOverlay ? 12 : 16,
        isHomeOverlay ? 16 : 18,
        isHomeOverlay ? 12 : 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '模型',
            style: TextStyle(
              color: isHomeOverlay ? const Color(0xFF626D79) : _mutedInk,
              fontSize: isHomeOverlay ? 17 : 14,
              fontWeight: isHomeOverlay ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          for (var index = 0;
              index < HomeChatModelOption.options.length;
              index++) ...[
            _ModelOptionRow(
              model: HomeChatModelOption.options[index],
              selected: selection.model.id ==
                  HomeChatModelOption.options[index].id,
              isHomeOverlay: isHomeOverlay,
              onTap: () => onChanged(
                selection.withModel(HomeChatModelOption.options[index]),
              ),
            ),
          ],
          Padding(
            padding: EdgeInsets.only(top: isHomeOverlay ? 8 : 6),
            child: Divider(
              height: 1,
              color: isHomeOverlay
                  ? const Color(0xFFD6DDE5)
                  : const Color(0xFFDADCE0),
            ),
          ),
          SizedBox(height: isHomeOverlay ? 8 : 10),
          Text(
            '思考程度',
            style: TextStyle(
              color: isHomeOverlay ? const Color(0xFF626D79) : _mutedInk,
              fontSize: isHomeOverlay ? 17 : 15,
              fontWeight: isHomeOverlay ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          if (isHomeOverlay) const SizedBox(height: 4),
          _ReasoningLevelControl(
            selection: selection,
            onChanged: onChanged,
            isHomeOverlay: isHomeOverlay,
          ),
        ],
      ),
    );
  }
}

class _ReasoningLevelControl extends StatelessWidget {
  const _ReasoningLevelControl({
    required this.selection,
    required this.onChanged,
    required this.isHomeOverlay,
  });

  final HomeChatModelSelection selection;
  final ValueChanged<HomeChatModelSelection> onChanged;
  final bool isHomeOverlay;

  @override
  Widget build(BuildContext context) {
    const low = HomeChatReasoningLevel.low;
    const medium = HomeChatReasoningLevel.medium;
    const high = HomeChatReasoningLevel.high;
    final levels = selection.model.supportsMedium
        ? const [low, medium, high]
        : const [low, high];
    final selectedLevelIndex = levels.indexOf(selection.reasoningLevel);
    final selectedIndex = selectedLevelIndex < 0 ? 0 : selectedLevelIndex;
    final trackAsset = isHomeOverlay
        ? (selection.model.supportsMedium
              ? 'assets/images/home_model_reasoning_track.svg'
              : 'assets/images/home_model_reasoning_track_mimo.svg')
        : 'assets/images/model_reasoning_track.svg';

    void selectAt(double x, double width) {
      final index = (x / (width / levels.length))
          .floor()
          .clamp(0, levels.length - 1)
          .toInt();
      final level = levels[index];
      if (level != selection.reasoningLevel) {
        onChanged(selection.withReasoning(level));
      }
    }

    return SizedBox(
      height: isHomeOverlay ? 48 : 44,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = selection.model.supportsMedium
              ? constraints.maxWidth
              : constraints.maxWidth * (2 / 3);
          final segmentWidth = width / levels.length;
          return Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: width,
              height: isHomeOverlay ? 48 : 44,
              child: Semantics(
                container: true,
                slider: true,
                label: '思考程度',
                value: selection.reasoningLevel.label,
                decreasedValue: selectedIndex > 0
                    ? levels[selectedIndex - 1].label
                    : null,
                increasedValue: selectedIndex < levels.length - 1
                    ? levels[selectedIndex + 1].label
                    : null,
                onDecrease: selectedIndex > 0
                    ? () => onChanged(
                        selection.withReasoning(levels[selectedIndex - 1]),
                      )
                    : null,
                onIncrease: selectedIndex < levels.length - 1
                    ? () => onChanged(
                        selection.withReasoning(levels[selectedIndex + 1]),
                      )
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
                          height: isHomeOverlay ? 41 : 44,
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
                              if (!isHomeOverlay)
                                AnimatedPositioned(
                                  left: 2,
                                  top: 2,
                                  bottom: 2,
                                  width: segmentWidth * selectedIndex,
                                  duration: const Duration(milliseconds: 190),
                                  curve: Curves.easeInOutCubic,
                                  child: IgnorePointer(
                                    child: SvgPicture.asset(
                                      'assets/images/model_reasoning_progress.svg',
                                      fit: BoxFit.fill,
                                      excludeFromSemantics: true,
                                    ),
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
                                    decoration: isHomeOverlay
                                        ? BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(24),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x1465717E),
                                                blurRadius: 4,
                                                offset: Offset(0, 1),
                                              ),
                                            ],
                                          )
                                        : const BoxDecoration(),
                                    child: SvgPicture.asset(
                                      isHomeOverlay
                                          ? 'assets/images/home_model_reasoning_thumb.svg'
                                          : 'assets/images/model_reasoning_thumb.svg',
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
                                            color: levels[index] ==
                                                    selection.reasoningLevel
                                                ? _ink
                                                : _mutedInk,
                                            fontSize: isHomeOverlay ? 15 : 13,
                                            fontWeight: levels[index] ==
                                                    selection.reasoningLevel
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
    required this.isHomeOverlay,
    required this.onTap,
  });

  final HomeChatModelOption model;
  final bool selected;
  final bool isHomeOverlay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isHomeOverlay ? 48 : 42,
      child: Semantics(
        button: true,
        selected: selected,
        label: model.name,
        child: InkWell(
          borderRadius: BorderRadius.circular(isHomeOverlay ? 13 : 11),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: onTap,
          child: Stack(
            fit: isHomeOverlay ? StackFit.expand : StackFit.loose,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: DecoratedBox(
                    decoration: selected && isHomeOverlay
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                          )
                        : const BoxDecoration(),
                    child: Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: double.infinity,
                        height: isHomeOverlay ? 46 : 42,
                        child: SvgPicture.asset(
                          isHomeOverlay
                              ? 'assets/images/home_model_option_selected.svg'
                              : 'assets/images/model_option_selected.svg',
                          fit: BoxFit.fill,
                          excludeFromSemantics: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  isHomeOverlay ? 12 : 9,
                  0,
                  isHomeOverlay ? 12 : 9,
                  0,
                ),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      model.iconAsset,
                      width: isHomeOverlay ? 27 : 19,
                      height: isHomeOverlay ? 27 : 19,
                      colorFilter: model.id == HomeChatModelOption.mimo.id
                          ? const ColorFilter.mode(
                              Color(0xFFFF6900),
                              BlendMode.srcIn,
                            )
                          : null,
                      excludeFromSemantics: true,
                    ),
                    SizedBox(width: isHomeOverlay ? 10 : 9),
                    Expanded(
                      child: Text(
                        model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _ink,
                          fontSize: isHomeOverlay ? 16 : 15,
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

class HomeChatModelSelectionSheet extends StatefulWidget {
  const HomeChatModelSelectionSheet({
    super.key,
    required this.initialSelection,
  });

  final HomeChatModelSelection initialSelection;

  @override
  State<HomeChatModelSelectionSheet> createState() =>
      _HomeChatModelSelectionSheetState();
}

class _HomeChatModelSelectionSheetState
    extends State<HomeChatModelSelectionSheet> {
  late HomeChatModelSelection _selection = widget.initialSelection;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Material(
          color: Colors.white.withOpacity(.96),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '新对话默认值',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  HomeChatModelPickerPanel(
                    selection: _selection,
                    onChanged: (value) => setState(() => _selection = value),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(_selection),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
