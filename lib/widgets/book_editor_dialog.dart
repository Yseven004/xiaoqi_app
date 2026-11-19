import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/book_flow_theme.dart';
import 'book_keyboard_layout.dart';

const bookEditorLine = Color(0xFFD9D9D9);
const bookEditorChip = Color(0xFFEAEAEA);
const bookEditorBarrier = Color(0x99000000);
const _iconRoot = 'assets/icons/extension_market/detail';

Widget bookEditorIcon(String name, {double size = 16}) => SvgPicture.asset(
  '$_iconRoot/$name.svg',
  width: size,
  height: size,
  excludeFromSemantics: true,
);

Future<T?> showBookEditorDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required Color barrierColor,
  bool barrierDismissible = false,
  bool avoidKeyboard = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    _BookEditorDialogRoute<T>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (context) => BookKeyboardLayout(
        avoidKeyboard: avoidKeyboard,
        child: SafeArea(child: Builder(builder: builder)),
      ),
      barrierColor: barrierColor,
      barrierDismissible: barrierDismissible,
    ),
  );
}

class _BookEditorDialogRoute<T> extends DialogRoute<T> {
  _BookEditorDialogRoute({
    required super.context,
    required super.themes,
    required super.builder,
    required super.barrierColor,
    required super.barrierDismissible,
  }) : super(
         useSafeArea: false,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );

  @override
  Iterable<OverlayEntry> createOverlayEntries() => [
    // Flutter disables hit testing on the normal barrier as soon as the
    // closing animation starts. Keep an invisible blocker behind it until
    // the route removes all of its overlay entries.
    OverlayEntry(
      builder: (_) =>
          const Positioned.fill(child: AbsorbPointer(child: SizedBox.expand())),
    ),
    ...super.createOverlayEntries(),
  ];
}

class BookEditorDialog extends StatelessWidget {
  const BookEditorDialog({
    super.key,
    required this.width,
    required this.title,
    required this.child,
    this.footer,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(18, 12, 18, 14),
    this.alignment = const Alignment(0, .15),
    this.elevation = 0,
  }) : _matchDescriptionSize = false,
       onEdit = null,
       titleIcon = null,
       closeTooltip = '关闭';

  const BookEditorDialog.description({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.footer,
    this.onEdit,
    this.titleIcon,
    this.closeTooltip = '关闭',
  }) : width = 880,
       padding = const EdgeInsets.fromLTRB(22, 10, 22, 12),
       alignment = Alignment.center,
       elevation = 0,
       _matchDescriptionSize = true;

  final double width;
  final String title;
  final Widget? titleIcon;
  final Widget child;
  final Widget? footer;
  final VoidCallback? onEdit;
  final VoidCallback? onClose;
  final String closeTooltip;
  final EdgeInsets padding;
  final Alignment alignment;
  final double elevation;
  final bool _matchDescriptionSize;

  static const _titleSize = 20.0;

  @override
  Widget build(BuildContext context) {
    final preferredHeight = _matchDescriptionSize
        ? (MediaQuery.sizeOf(context).height * .31).clamp(244.0, 400.0)
        : null;
    final textScaler = MediaQuery.textScalerOf(context);
    final actionHeight = math.max(48.0, textScaler.scale(14) * 1.45);
    final headingHeight = math.max(48.0, textScaler.scale(_titleSize) * 1.35);
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      shadowColor: const Color(0x33000000),
      alignment: alignment,
      // Android already reports the animated IME insets. Easing them again
      // makes the card trail behind the system keyboard.
      insetAnimationDuration: Duration.zero,
      insetPadding: EdgeInsets.symmetric(
        horizontal: _matchDescriptionSize ? 24 : 16,
        vertical: 12,
      ),
      constraints: BoxConstraints(maxWidth: width),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: preferredHeight,
        child: Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final action = footer;
              // In a very short window, let the whole card scroll so the
              // action does not take up the input's only visible space.
              final pinFooter =
                  action != null && constraints.maxHeight >= actionHeight + 24;
              final inlineFooter = pinFooter ? null : action;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    fit: _matchDescriptionSize ? FlexFit.tight : FlexFit.loose,
                    child: LayoutBuilder(
                      builder: (context, viewport) => SingleChildScrollView(
                        primary: false,
                        child: SizedBox(
                          height: _matchDescriptionSize
                              ? math.max(
                                  viewport.maxHeight,
                                  headingHeight +
                                      76 +
                                      (inlineFooter == null ? 0 : actionHeight),
                                )
                              : null,
                          child: _buildContent(inlineFooter),
                        ),
                      ),
                    ),
                  ),
                  if (pinFooter) action,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Widget? inlineFooter) => TextSelectionTheme(
    data: const TextSelectionThemeData(
      cursorColor: BookFlowTheme.ink,
      selectionColor: Color(0xFFD9D9D9),
      selectionHandleColor: BookFlowTheme.ink,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: BookFlowTheme.heading.copyWith(
                          fontSize: _titleSize,
                        ),
                      ),
                    ),
                    if (titleIcon case final icon?) ...[
                      const SizedBox(width: 8),
                      icon,
                    ],
                  ],
                ),
              ),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: '编辑简介',
                onPressed: onEdit,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                style:
                    IconButton.styleFrom(
                      splashFactory: NoSplash.splashFactory,
                    ).copyWith(
                      overlayColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.pressed)
                            ? Colors.transparent
                            : null,
                      ),
                    ),
                icon: bookEditorIcon('pencil', size: 18),
              ),
            IconButton(
              tooltip: closeTooltip,
              onPressed: onClose,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              padding: EdgeInsets.zero,
              alignment: Alignment.centerRight,
              icon: bookEditorIcon('close', size: 18),
            ),
          ],
        ),
        if (_matchDescriptionSize) Expanded(child: child) else child,
        ?inlineFooter,
      ],
    ),
  );
}

ButtonStyle bookEditorActionStyle(
  BuildContext context, {
  double width = 92,
  double height = 40,
  Color background = BookFlowTheme.ink,
  Color foreground = Colors.white,
  BorderSide? border,
}) => FilledButton.styleFrom(
  backgroundColor: background,
  foregroundColor: foreground,
  disabledBackgroundColor: bookEditorChip,
  disabledForegroundColor: BookFlowTheme.inkSecondary,
  minimumSize: Size(width, height),
  padding: const EdgeInsets.symmetric(horizontal: 12),
  textStyle: Theme.of(
    context,
  ).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
  elevation: 0,
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.padded,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  side: border,
);

InputDecoration bookEditorInput({
  String? hint,
  String? error,
  double radius = 5,
  Color outline = const Color(0xFFCCCCCC),
  Color? focusedOutline,
  EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
}) {
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: const TextStyle(color: BookFlowTheme.inkSecondary),
    errorText: error,
    errorMaxLines: 2,
    contentPadding: padding,
    border: border(outline),
    enabledBorder: border(outline),
    focusedBorder: focusedOutline == null
        ? border(BookFlowTheme.ink, 1.4)
        : border(focusedOutline),
    errorBorder: border(BookFlowTheme.danger),
    focusedErrorBorder: border(BookFlowTheme.danger, 1.4),
  );
}

/// Applies the global keyboard dismissal rule to the dialog's own view.
mixin BookEditorInputFocus<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  bool _keyboardVisible = false;
  bool _watchingMetrics = false;

  Iterable<(FocusNode, TextEditingController)> get editorInputs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final view = View.of(context);
    _keyboardVisible = view.viewInsets.bottom > 0;
    if (!_watchingMetrics) {
      WidgetsBinding.instance.addObserver(this as WidgetsBindingObserver);
      _watchingMetrics = true;
    }
  }

  @override
  void didChangeMetrics() {
    final visible = View.of(context).viewInsets.bottom > 0;
    if (_keyboardVisible && !visible) {
      for (final (focus, controller) in editorInputs) {
        if (focus.hasFocus && controller.text.isEmpty) focus.unfocus();
      }
    }
    _keyboardVisible = visible;
  }

  @override
  void dispose() {
    if (_watchingMetrics) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

Future<String?> showBookCategoryNameDialog(
  BuildContext context, {
  String? initialValue,
  Future<void> Function(String)? onCreate,
  Color barrierColor = const Color(0x80000000),
}) => showBookEditorDialog<String>(
  context: context,
  barrierColor: barrierColor,
  builder: (_) =>
      _CategoryNameDialog(initialValue: initialValue, onCreate: onCreate),
);

class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({this.initialValue, this.onCreate});

  final String? initialValue;
  final Future<void> Function(String)? onCreate;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog>
    with WidgetsBindingObserver, BookEditorInputFocus {
  late final _controller = TextEditingController(text: widget.initialValue);
  final _focus = FocusNode();
  bool _saving = false;
  String? _error;

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs => [
    (_focus, _controller),
  ];

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    _focus.unfocus();
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入分类名称');
      return;
    }
    if (widget.onCreate != null) {
      setState(() => _saving = true);
      try {
        await widget.onCreate!(name);
      } catch (_) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = '创建失败，请重试';
          });
        }
        return;
      }
    }
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, name);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: BookEditorDialog(
      width: 344,
      title: widget.initialValue == null ? '新建分类' : '重新命名分类',
      alignment: const Alignment(0, .12),
      elevation: 7,
      padding: const EdgeInsets.fromLTRB(20, 9, 20, 10),
      onClose: _saving ? null : () => Navigator.pop(context),
      footer: Align(
        alignment: Alignment.centerRight,
        child: TextFieldTapRegion(
          child: FilledButton(
            style: bookEditorActionStyle(context, width: 80),
            onPressed: _saving ? null : _submit,
            child: Text(
              _saving ? '创建中' : (widget.initialValue == null ? '创建' : '保存'),
            ),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            focusNode: _focus,
            readOnly: _saving,
            maxLength: 20,
            buildCounter:
                (
                  _, {
                  required currentLength,
                  required isFocused,
                  required maxLength,
                }) => null,
            textInputAction: TextInputAction.done,
            style: const TextStyle(fontSize: 15, color: BookFlowTheme.ink),
            onTapOutside: (_) => _focus.unfocus(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: bookEditorInput(
              hint: '输入分类名称',
              error: _error,
              radius: 8,
              outline: BookFlowTheme.ink,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
