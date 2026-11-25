import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

Future<T?> showAnnotationSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool editing = false,
  bool? barrierDismissible,
  bool matchReferenceProportions = false,
  AnimationStyle? sheetAnimationStyle,
  Color barrierColor = const Color(0x38000000),
  Rect? Function()? resolveAnchor,
  ScrollPosition? scrollPosition,
  ValueChanged<double>? onViewportChanged,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    isDismissible: barrierDismissible ?? !editing,
    enableDrag: !editing,
    showDragHandle: editing ? false : null,
    sheetAnimationStyle: sheetAnimationStyle,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: barrierColor,
    // Override the Material 3 width cap without capturing the opening size.
    constraints: const BoxConstraints(),
    builder: (context) => _AnnotationSheetSurface(
      resolveAnchor: resolveAnchor,
      scrollPosition: scrollPosition,
      onViewportChanged: onViewportChanged,
      matchReferenceProportions: matchReferenceProportions,
      builder: builder,
    ),
  ).whenComplete(() => onViewportChanged?.call(double.infinity));
}

/// Preserves the editor's keyboard while a native media window has focus.
Future<T> withAnnotationKeyboard<T>(
  GlobalKey editorKey,
  Future<T> Function() action,
) {
  final editor = editorKey.currentState;
  return editor is _AnnotationTextFieldState
      ? editor._withKeyboard(action)
      : action();
}

class _AnnotationSheetSurface extends StatefulWidget {
  const _AnnotationSheetSurface({
    required this.builder,
    required this.matchReferenceProportions,
    this.resolveAnchor,
    this.scrollPosition,
    this.onViewportChanged,
  });
  final WidgetBuilder builder;
  final bool matchReferenceProportions;
  final Rect? Function()? resolveAnchor;
  final ScrollPosition? scrollPosition;
  final ValueChanged<double>? onViewportChanged;
  @override
  State<_AnnotationSheetSurface> createState() =>
      _AnnotationSheetSurfaceState();
}

class _AnnotationSheetSurfaceState extends State<_AnnotationSheetSurface> {
  final _surfaceKey = GlobalKey();
  bool _scheduled = false;
  double? _lastTop;
  double _heldKeyboardInset = 0;
  Animation<double>? _routeAnimation;

  VoidCallback _holdKeyboard() {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset == 0) return () {};
    setState(() => _heldKeyboardInset = inset);
    return () {
      if (mounted) setState(() => _heldKeyboardInset = 0);
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _routeAnimation) return;
    _routeAnimation?.removeListener(_reportViewport);
    _routeAnimation = animation;
    _routeAnimation?.addListener(_reportViewport);
  }

  @override
  void dispose() {
    _routeAnimation?.removeListener(_reportViewport);
    super.dispose();
  }

  void _reportViewport() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = _surfaceKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final top = box.localToGlobal(Offset.zero).dy;
      if (_lastTop != top) {
        _lastTop = top;
        widget.onViewportChanged?.call(top);
      }
      final anchor = widget.resolveAnchor?.call();
      final scroll = widget.scrollPosition;
      if (anchor == null || scroll == null || !scroll.hasContentDimensions) {
        return;
      }
      final overlap = anchor.bottom + 12 - top;
      if (overlap <= 1) return;
      final delta = scroll.axisDirection == AxisDirection.up
          ? -overlap
          : overlap;
      final target = (scroll.pixels + delta).clamp(
        scroll.minScrollExtent,
        scroll.maxScrollExtent,
      );
      if ((target - scroll.pixels).abs() > 1) scroll.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = math.max(media.viewInsets.bottom, _heldKeyboardInset);
    final availableHeight = math.max(
      0.0,
      media.size.height - media.padding.top - keyboard - media.padding.bottom,
    );
    _reportViewport();
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _reportViewport();
                return false;
              },
              child: SizeChangedLayoutNotifier(
                child: SizedBox(
                  key: _surfaceKey,
                  width: width,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: availableHeight),
                    child: Material(
                      color: Colors.white,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(
                            widget.matchReferenceProportions ? 12 : 16,
                          ),
                        ),
                        side: const BorderSide(color: Color(0xFFE6E7E9)),
                      ),
                      child: Theme(
                        data: annotationPanelTheme(context),
                        child: Builder(builder: widget.builder),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

ThemeData annotationPanelTheme(BuildContext context) {
  final theme = Theme.of(context);
  final flatButtons = ButtonStyle(
    elevation: const WidgetStatePropertyAll(0.0),
    splashFactory: NoSplash.splashFactory,
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? theme.colorScheme.onSurface.withValues(alpha: .10)
          : Colors.transparent,
    ),
  );
  return theme.copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    iconButtonTheme: IconButtonThemeData(
      style: (theme.iconButtonTheme.style ?? const ButtonStyle()).merge(
        flatButtons,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (theme.textButtonTheme.style ?? const ButtonStyle()).merge(
        flatButtons,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: (theme.filledButtonTheme.style ?? const ButtonStyle()).merge(
        flatButtons,
      ),
    ),
  );
}

const annotationComposerInset = 12.0;
const annotationComposerActionSize = 44.0;
const annotationPlusSize = 30.0;
const annotationQuoteInset = 12.0;
const annotationComposerActionStyle = ButtonStyle(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);

class AnnotationQuoteLine extends StatelessWidget {
  const AnnotationQuoteLine(
    this.quote, {
    this.guardContent,
    this.showLabel = false,
    this.verticalPadding = 11,
    super.key,
  });

  final String quote;
  final Widget Function(Widget)? guardContent;
  final bool showLabel;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) {
            final page = Scaffold(
              backgroundColor: Colors.white,
              appBar: AppBar(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                foregroundColor: const Color(0xFF232427),
                automaticallyImplyLeading: false,
                title: const Text('引文', style: TextStyle(fontSize: 18)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF232427),
                    ),
                    child: const Text('关闭'),
                  ),
                ],
              ),
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText(
                        quote,
                        style: const TextStyle(
                          fontSize: 18,
                          height: 1.65,
                          color: Color(0xFF232427),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            return guardContent?.call(page) ?? page;
          },
        ),
      );
    },
    child: Semantics(
      button: true,
      label: '查看完整引文',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Text(
          '${showLabel ? '引文  ' : ''}${quote.replaceAll(RegExp(r'\s+'), ' ')}',
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: const TextStyle(fontSize: 13, color: Color(0xFF5D626A)),
        ),
      ),
    ),
  );
}

Widget annotationAsset(String path, {double size = 20, Color? color}) =>
    SvgPicture.asset(
      path,
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
      excludeFromSemantics: true,
    );

class AnnotationThumbnails extends StatelessWidget {
  const AnnotationThumbnails({
    required this.paths,
    this.onRemove,
    this.guardContent,
    this.mediaChanges,
    this.onMissing,
    super.key,
  });

  final List<String> paths;
  final ValueChanged<int>? onRemove;
  final Widget Function(Widget)? guardContent;
  final Listenable? mediaChanges;
  final ValueChanged<String>? onMissing;

  @override
  Widget build(BuildContext context) {
    final changes = mediaChanges;
    return changes == null
        ? _gallery(context)
        : ListenableBuilder(
            listenable: changes,
            builder: (context, _) => _gallery(context),
          );
  }

  Widget _gallery(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var index = 0; index < paths.length; index++)
        Stack(
          children: [
            Padding(
              padding: onRemove == null
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(top: 4, right: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  if (onMissing != null && !File(paths[index]).existsSync()) {
                    onMissing!(paths[index]);
                    return;
                  }
                  showDialog<void>(
                    context: context,
                    builder: (context) {
                      final dialog = Dialog(
                        clipBehavior: Clip.antiAlias,
                        child: InteractiveViewer(
                          child: Image.file(
                            File(paths[index]),
                            fit: BoxFit.contain,
                          ),
                        ),
                      );
                      return guardContent?.call(dialog) ?? dialog;
                    },
                  );
                },
                child: Semantics(
                  label: '查看图片 ${index + 1}',
                  button: true,
                  child: Container(
                    foregroundDecoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFD5D8DE)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child:
                          onMissing != null && !File(paths[index]).existsSync()
                          ? const ColoredBox(
                              color: Color(0xFFF1F2F4),
                              child: SizedBox(
                                width: 58,
                                height: 58,
                                child: Center(child: Text('待下载')),
                              ),
                            )
                          : Image.file(
                              File(paths[index]),
                              width: 58,
                              height: 58,
                              cacheWidth: 192,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFFF1F2F4),
                                child: SizedBox(
                                  width: 58,
                                  height: 58,
                                  child: Center(child: Text('图片失效')),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            if (onRemove != null)
              Positioned(
                top: 0,
                right: 0,
                child: SizedBox.square(
                  dimension: 44,
                  child: TextFieldTapRegion(
                    child: IconButton(
                      tooltip: '移除图片 ${index + 1}',
                      onPressed: () => onRemove!(index),
                      alignment: Alignment.topRight,
                      padding: EdgeInsets.zero,
                      icon: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xB3343740),
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: annotationAsset(
                            'assets/icons/chat_note_editor/x.svg',
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
    ],
  );
}

/// Releases an empty editor when Android hides the keyboard via system Back.
class AnnotationTextField extends StatefulWidget {
  const AnnotationTextField({
    required this.controller,
    this.style,
    this.autofocus = true,
    this.readOnly = false,
    this.onFocusChange,
    this.inputFormatters,
    super.key,
  });

  final TextEditingController controller;
  final TextStyle? style;
  final bool autofocus;
  final bool readOnly;
  final ValueChanged<bool>? onFocusChange;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<AnnotationTextField> createState() => _AnnotationTextFieldState();
}

class _AnnotationTextFieldState extends State<AnnotationTextField>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  double _lastInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_reportFocus);
  }

  void _reportFocus() => widget.onFocusChange?.call(_focus.hasFocus);

  Future<T> _withKeyboard<T>(Future<T> Function() action) async {
    final view = View.of(context);
    final originalInset = view.viewInsets.bottom;
    if (originalInset == 0 || !_focus.hasPrimaryFocus) return action();
    final release = context
        .findAncestorStateOfType<_AnnotationSheetSurfaceState>()
        ?._holdKeyboard();
    try {
      return await action();
    } finally {
      try {
        await _restoreKeyboard(() => view.viewInsets.bottom, originalInset);
      } finally {
        release?.call();
      }
    }
  }

  Future<void> _restoreKeyboard(
    double Function() keyboardInset,
    double originalInset,
  ) async {
    bool stillEditing() =>
        mounted &&
        _focus.hasPrimaryFocus &&
        ModalRoute.isCurrentOf(context) == true;
    if (!stillEditing() || keyboardInset() >= originalInset) return;

    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    final binding = WidgetsBinding.instance;
    const interval = Duration(milliseconds: 20);
    while (stillEditing() &&
        binding.lifecycleState != null &&
        binding.lifecycleState != AppLifecycleState.resumed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
    }
    if (!stillEditing()) return;
    if (keyboardInset() == 0) _findEditableText(context)?.requestKeyboard();

    while (stillEditing() &&
        keyboardInset() < originalInset &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
    }
    if (stillEditing() &&
        keyboardInset() == 0 &&
        widget.controller.text.isEmpty) {
      _focus.unfocus();
    }
  }

  EditableTextState? _findEditableText(BuildContext context) {
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    EditableTextState? editable;
    context.visitChildElements((child) {
      editable ??= _findEditableText(child);
    });
    return editable;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    if (_lastInset > 0 &&
        inset == 0 &&
        widget.controller.text.isEmpty &&
        (context
                    .findAncestorStateOfType<_AnnotationSheetSurfaceState>()
                    ?._heldKeyboardInset ??
                0) ==
            0) {
      _focus.unfocus();
    }
    _lastInset = inset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.removeListener(_reportFocus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: _focus,
    autofocus: widget.autofocus,
    readOnly: widget.readOnly,
    inputFormatters: widget.inputFormatters,
    minLines: 1,
    maxLines: 5,
    maxLength: 4000,
    // Keep the panel in place until the tapped control receives pointer up.
    onTapOutside: (_) {},
    onTapUpOutside: (_) => _focus.unfocus(),
    style:
        widget.style ??
        const TextStyle(color: Color(0xFF202124), fontSize: 16, height: 1.45),
    decoration: const InputDecoration(
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      counterText: '',
      hintText: '写下注释…',
      hintStyle: TextStyle(color: Color(0xFF60646A)),
      contentPadding: EdgeInsets.symmetric(vertical: 8),
      isDense: true,
    ),
  );
}
