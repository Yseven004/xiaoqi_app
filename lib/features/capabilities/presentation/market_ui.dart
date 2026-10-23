import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const marketInk = Color(0xFF191919);
const marketMuted = Color(0xFF6B6B6B);
const marketLine = Color(0xFFE8E8E8);
const marketSoft = Color(0xFFF4F4F4);
const marketAssets = 'assets/icons/extension_market/';
const marketOfficialDeveloper = '第七世界';

Widget marketIcon(String name, {double size = 22, Color? color}) =>
    SvgPicture.asset(
      '${marketAssets}detail/$name.svg',
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );

Widget marketIconButton(
  String icon,
  String label,
  VoidCallback? onPressed, {
  bool edgeAligned = false,
}) => IconButton(
  tooltip: label,
  onPressed: onPressed,
  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
  padding: edgeAligned ? EdgeInsets.zero : null,
  alignment: edgeAligned ? Alignment.centerLeft : Alignment.center,
  icon: marketIcon(icon),
);

Widget marketButton(
  String label,
  VoidCallback? onPressed, {
  String? icon,
  bool primary = false,
  bool selected = false,
  bool outlined = true,
  double radius = 99,
  double height = 48,
  double fontSize = 15,
}) => TextButton(
  onPressed: onPressed,
  style: TextButton.styleFrom(
    minimumSize: Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    foregroundColor: primary ? Colors.white : marketInk,
    disabledForegroundColor: marketMuted,
    backgroundColor: primary
        ? const Color(0xFF1D1D1D)
        : selected
        ? const Color(0xFFF0F0F0)
        : Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: primary || selected || !outlined
          ? BorderSide.none
          : const BorderSide(color: Color(0xFFDEDEDE)),
    ),
    textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w400),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[
        marketIcon(icon, size: 20, color: primary ? Colors.white : null),
        const SizedBox(width: 8),
      ],
      Flexible(child: Text(label, textAlign: TextAlign.center)),
    ],
  ),
);

ThemeData marketTheme(BuildContext context) => Theme.of(context).copyWith(
  scaffoldBackgroundColor: Colors.white,
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: marketInk,
        brightness: Brightness.light,
      ).copyWith(
        primary: marketInk,
        surface: Colors.white,
        error: const Color(0xFFA52B25),
      ),
  textTheme: Theme.of(
    context,
  ).textTheme.apply(bodyColor: marketInk, displayColor: marketInk),
  popupMenuTheme: Theme.of(context).popupMenuTheme.copyWith(
    position: PopupMenuPosition.under,
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: false,
    contentPadding: const EdgeInsets.all(14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: marketLine),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFFDEDEDE)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFF888888), width: 2),
    ),
  ),
);

Widget marketLink(
  String label,
  VoidCallback? onPressed, {
  String icon = 'link',
}) => Align(
  alignment: Alignment.centerRight,
  child: TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: marketMuted,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        marketIcon(icon, size: 20, color: marketMuted),
        const SizedBox(width: 8),
        Flexible(child: Text(label, textAlign: TextAlign.right)),
        const SizedBox(width: 8),
        marketIcon('caret-right', size: 16, color: marketMuted),
      ],
    ),
  ),
);

class MarketBrand extends StatelessWidget {
  const MarketBrand(
    this.asset, {
    this.size = 40,
    this.glyphSize = 25,
    this.soft = false,
    super.key,
  });
  final String asset;
  final double size, glyphSize;
  final bool soft;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: soft ? marketSoft : Colors.white,
      border: soft ? null : Border.all(color: const Color(0xFFE6E6E6)),
      borderRadius: BorderRadius.circular(
        size >= 70
            ? 18
            : size >= 60
            ? 15
            : 9,
      ),
    ),
    alignment: Alignment.center,
    child: SvgPicture.asset(asset, width: glyphSize, height: glyphSize),
  );
}

class MarketFrame extends StatelessWidget {
  const MarketFrame({required this.children, this.footer, super.key});
  final List<Widget> children;
  final Widget? footer;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inset = constraints.maxWidth <= 600 ? 20.0 : 32.0;
              return Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        14,
                        inset,
                        footer == null ? 76 : 24,
                      ),
                      children: children,
                    ),
                  ),
                  if (footer != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(inset, 16, inset, 20),
                      child: footer!,
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

Widget marketHeading(String title, {String? subtitle}) => Padding(
  padding: const EdgeInsets.only(top: 30, bottom: 24),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 1.32,
          letterSpacing: -.6,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 17,
            color: marketMuted,
            height: 1.55,
          ),
        ),
      ],
    ],
  ),
);

Widget marketSection(String title, {VoidCallback? onTap, String? count}) =>
    Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text(
                  count,
                  style: const TextStyle(fontSize: 20, color: marketMuted),
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(width: 7),
                marketIcon('caret-right', size: 16),
              ],
            ],
          ),
        ),
      ),
    );

class MarketGrid extends StatelessWidget {
  const MarketGrid({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      final columns =
          constraints.maxWidth <= 540 ||
              MediaQuery.textScalerOf(context).scale(17) > 24
          ? 1
          : 2;
      final width = (constraints.maxWidth - (columns - 1) * 36) / columns;
      return Wrap(
        spacing: 36,
        children: children
            .map((child) => SizedBox(width: width, child: child))
            .toList(),
      );
    },
  );
}

Widget marketEmpty(
  String title,
  String message, {
  String? action,
  VoidCallback? onAction,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 38),
  child: Column(
    children: [
      marketIcon('search', size: 34),
      const SizedBox(height: 16),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 9),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: marketMuted, height: 1.65),
      ),
      if (action != null) ...[
        const SizedBox(height: 20),
        marketButton(action, onAction),
      ],
    ],
  ),
);

Widget marketError(String message, VoidCallback retry) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        message,
        style: const TextStyle(color: Color(0xFFA52B25), height: 1.6),
      ),
      marketButton('重试', retry),
    ],
  ),
);

Widget marketSkeleton() => Semantics(
  label: '正在加载扩展',
  liveRegion: true,
  child: MarketGrid(
    children: List.generate(
      6,
      (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: marketSoft,
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 14, width: 120, color: marketSoft),
                  const SizedBox(height: 10),
                  Container(height: 10, color: marketSoft),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

class MarketDialog extends StatefulWidget {
  const MarketDialog({
    required this.title,
    required this.children,
    this.actions = const [],
    this.canClose = true,
    super.key,
  });
  final String title;
  final List<Widget> children, actions;
  final bool canClose;
  @override
  State<MarketDialog> createState() => _MarketDialogState();
}

class _MarketDialogState extends State<MarketDialog> {
  final _cardKey = GlobalKey();
  final _layoutKey = GlobalKey();
  double? _restingTop;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    key: _layoutKey,
    builder: (context, constraints) {
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      if (keyboard == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
          final layout =
              _layoutKey.currentContext?.findRenderObject() as RenderBox?;
          if (box?.hasSize == true && layout != null) {
            _restingTop = box!.localToGlobal(Offset.zero, ancestor: layout).dy;
          }
        });
      }
      final pinned = keyboard > 0 && _restingTop != null;
      final visibleHeight = (constraints.maxHeight - keyboard)
          .clamp(0.0, constraints.maxHeight)
          .toDouble();
      // Keep the resting top edge. Only shorten the scroll area if the keyboard
      // actually covers the card; very short landscape windows can move it up.
      final top = pinned
          ? _restingTop!
                .clamp(
                  18.0,
                  (visibleHeight - 160).clamp(18.0, constraints.maxHeight),
                )
                .toDouble()
          : 18.0;
      return PopScope(
        canPop: widget.canClose,
        child: MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            alignment: pinned ? Alignment.topCenter : Alignment.center,
            insetAnimationDuration: Duration.zero,
            insetPadding: EdgeInsets.fromLTRB(18, top, 18, 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(25),
            ),
            child: ConstrainedBox(
              key: _cardKey,
              constraints: BoxConstraints(
                maxWidth: 600,
                maxHeight: pinned
                    ? (visibleHeight - top - 18)
                          .clamp(0.0, constraints.maxHeight)
                          .toDouble()
                    : constraints.maxHeight - 36,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: widget.canClose
                              ? () => Navigator.pop(context)
                              : null,
                          icon: marketIcon('close', size: 21),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ...widget.children,
                            if (widget.actions.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 10,
                                runSpacing: 10,
                                children: widget.actions,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
