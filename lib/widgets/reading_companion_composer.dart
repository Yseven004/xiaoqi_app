import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../features/capabilities/data/capability_models.dart';
import '../features/capabilities/data/capability_store.dart';
import '../features/capabilities/presentation/capability_tag_text_controller.dart';
import '../features/capabilities/presentation/skill_presentation.dart';
import '../models/home_chat_attachment.dart';
import '../services/home_chat_attachment_preparer.dart';
import '../services/home_chat_model_preferences.dart';
import 'app_toast.dart';
import 'home_chat_attachment_controls.dart';
import 'home_chat_model_selector.dart';

part 'reading_companion_composer_menus.dart';

/// Composer and its menus within the bounds of the reading conversation card.
/// The surrounding page owns the draft, model and attachment actions.
class ReadingCompanionComposer extends StatefulWidget {
  const ReadingCompanionComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.modelSelection,
    required this.onModelSelectionChanged,
    required this.onSend,
    required this.onStop,
    required this.onAddAttachment,
    required this.onDrawingSelected,
    required this.onCapabilitySelected,
    required this.onInstallSkills,
    required this.onInstallPlugins,
    required this.onInstallMcp,
    required this.onManageMcp,
    required this.signedIn,
    this.requestLogin,
    this.content,
    this.generating = false,
    this.sendingEnabled = true,
    this.attachments = const [],
    this.attachmentPreparationStates,
    this.onRemoveAttachment,
    this.onRetryAttachment,
    this.onEditDrawing,
    this.onPreviewAttachment,
    this.onVoiceLongPressStart,
    this.onVoiceLongPressMove,
    this.onVoiceLongPressEnd,
    this.onVoiceLongPressCancel,
    this.voiceRecording = false,
    this.voiceCancelArmed = false,
    this.voiceStarting = false,
    this.voiceTranscribing = false,
    this.voiceSoundLevel,
    this.onMenuOpenChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final HomeChatModelSelection modelSelection;
  final ValueChanged<HomeChatModelSelection> onModelSelectionChanged;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final ValueChanged<int> onAddAttachment;
  final VoidCallback onDrawingSelected;
  final ValueChanged<Map<String, Object?>> onCapabilitySelected;
  final VoidCallback onInstallSkills;
  final VoidCallback onInstallPlugins;
  final VoidCallback onInstallMcp;
  final VoidCallback onManageMcp;
  final bool signedIn;
  final Future<bool> Function()? requestLogin;
  final Widget? content;
  final bool generating;
  final bool sendingEnabled;
  final List<HomeChatAttachment> attachments;
  final ValueListenable<Map<String, AttachmentPreparationState>>?
  attachmentPreparationStates;
  final ValueChanged<HomeChatAttachment>? onRemoveAttachment;
  final ValueChanged<HomeChatAttachment>? onRetryAttachment;
  final ValueChanged<HomeChatAttachment>? onEditDrawing;
  final ValueChanged<HomeChatAttachment>? onPreviewAttachment;
  final VoidCallback? onVoiceLongPressStart;
  final ValueChanged<double>? onVoiceLongPressMove;
  final VoidCallback? onVoiceLongPressEnd;
  final VoidCallback? onVoiceLongPressCancel;
  final bool voiceRecording;
  final bool voiceCancelArmed;
  final bool voiceStarting;
  final bool voiceTranscribing;
  final ValueListenable<double>? voiceSoundLevel;
  final ValueChanged<bool>? onMenuOpenChanged;

  @override
  State<ReadingCompanionComposer> createState() =>
      _ReadingCompanionComposerState();
}

const _bodyInk = Color(0xFF262626);
const _subtleInk = Color(0xFF686868);
const _controlHeight = 44.0;

enum _CompanionMenu { root, files, imageSource, skills, mcp, model }

class _ReadingCompanionComposerState extends State<ReadingCompanionComposer> {
  final _menuTapGroup = Object();
  _CompanionMenu? _menu;
  List<CapabilityRecord> _capabilities = const [];
  List<McpConnectionRecord> _connections = const [];
  bool _loadingCapabilities = false;
  bool _loadingConnections = false;
  bool _capabilityLoadFailed = false;
  bool _mcpLoadFailed = false;
  bool _loggingIn = false;
  int _connectionRequest = 0;
  double _keyboardInset = 0;

  String get _draftText => switch (widget.controller) {
    CapabilityTagTextController controller => controller.messageText,
    final controller => controller.text,
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (_keyboardInset > 0 && inset == 0 && _draftText.isEmpty) {
      // A keyboard dismissal can update inherited metrics during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _keyboardInset == 0 && _draftText.isEmpty) {
          widget.focusNode.unfocus();
        }
      });
    }
    _keyboardInset = inset;
  }

  @override
  void didUpdateWidget(covariant ReadingCompanionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.signedIn != widget.signedIn) {
      _connectionRequest++;
      _connections = const [];
      _loadingConnections = false;
      _mcpLoadFailed = false;
      if (widget.signedIn && _menu == _CompanionMenu.mcp) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _menu == _CompanionMenu.mcp) {
            unawaited(_loadConnections());
          }
        });
      }
    }
  }

  void _showMenu(_CompanionMenu? menu) {
    if (_menu == menu) return;
    final wasOpen = _menu != null;
    if (menu != null) widget.focusNode.unfocus();
    setState(() => _menu = menu);
    if (wasOpen != (menu != null)) widget.onMenuOpenChanged?.call(menu != null);
    if (menu == _CompanionMenu.skills) unawaited(_loadCapabilities());
    if (menu == _CompanionMenu.mcp && widget.signedIn) {
      unawaited(_loadConnections());
    }
  }

  void _activate(VoidCallback callback) {
    _showMenu(null);
    callback();
  }

  Future<void> _loadCapabilities() async {
    if (_loadingCapabilities) return;
    setState(() {
      _loadingCapabilities = true;
      _capabilityLoadFailed = false;
    });
    try {
      final records = await CapabilityStore.instance.list();
      if (!mounted) return;
      setState(() => _capabilities = records);
    } catch (_) {
      if (mounted) setState(() => _capabilityLoadFailed = true);
    } finally {
      if (mounted) setState(() => _loadingCapabilities = false);
    }
  }

  Future<void> _loadConnections() async {
    if (!widget.signedIn || _loadingConnections) return;
    final request = ++_connectionRequest;
    setState(() {
      _loadingConnections = true;
      _mcpLoadFailed = false;
    });
    try {
      final records = await CapabilityCloudSync.instance.listMcpConnections();
      if (!mounted || request != _connectionRequest) return;
      setState(() => _connections = records);
    } catch (_) {
      if (mounted && request == _connectionRequest) {
        setState(() => _mcpLoadFailed = true);
      }
    } finally {
      if (mounted && request == _connectionRequest) {
        setState(() => _loadingConnections = false);
      }
    }
  }

  Future<void> _signInForConnectors() async {
    final requestLogin = widget.requestLogin;
    if (requestLogin == null || _loggingIn) return;
    setState(() => _loggingIn = true);
    try {
      final signedIn = await requestLogin();
      if (mounted && signedIn && _menu == _CompanionMenu.mcp) {
        await _loadConnections();
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '无法打开登录，请重试');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    return PopScope<Object?>(
      canPop: menu == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _menu != null) _showMenu(null);
      },
      child: CustomMultiChildLayout(
        delegate: _CompanionComposerLayout(menu),
        children: [
          LayoutId(
            id: _ComposerSlot.conversation,
            child: widget.content ?? const SizedBox.shrink(),
          ),
          LayoutId(id: _ComposerSlot.composer, child: _composer()),
          if (menu != null)
            LayoutId(
              id: _ComposerSlot.menu,
              child: TapRegion(
                groupId: _menuTapGroup,
                onTapOutside: (_) => _showMenu(null),
                child: _buildMenu(menu),
              ),
            ),
        ],
      ),
    );
  }

  Widget _composer() {
    final recording = widget.voiceRecording;
    return ListenableBuilder(
      listenable: widget.focusNode,
      builder: (context, child) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: widget.focusNode.hasFocus
                ? const Color(0xFFA8A8A8)
                : const Color(0xFFDDDDDD),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trayHeight = widget.attachmentPreparationStates == null
              ? 80.0
              : 124.0;
          final showTray =
              widget.attachments.isNotEmpty &&
              constraints.maxHeight >= 84 + trayHeight;
          return SingleChildScrollView(
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(5, 7, 5, 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showTray)
                    HomeChatAttachmentTray(
                      attachments: widget.attachments,
                      onRemove: widget.onRemoveAttachment ?? (_) {},
                      onPreviewImage: widget.onPreviewAttachment,
                      onEditDrawing: widget.onEditDrawing,
                      preparationStates: widget.attachmentPreparationStates,
                      onRetry: widget.onRetryAttachment,
                    ),
                  if (recording ||
                      widget.voiceStarting ||
                      widget.voiceTranscribing)
                    _voiceFeedback()
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        minLines: 1,
                        maxLines: 2,
                        cursorColor: _bodyInk,
                        style: const TextStyle(
                          color: _bodyInk,
                          fontSize: 15,
                          height: 1.6,
                        ),
                        onTap: () => _showMenu(null),
                        onTapOutside: (_) => widget.focusNode.unfocus(),
                        decoration: const InputDecoration(
                          isCollapsed: true,
                          hintText: '发消息或按住说话',
                          hintStyle: TextStyle(color: _subtleInk),
                          contentPadding: EdgeInsets.only(top: 2, bottom: 5),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  SizedBox(
                    height: _controlHeight,
                    child: Row(
                      children: [
                        TapRegion(
                          groupId: _menuTapGroup,
                          child: _toolbarButton(
                            '添加内容',
                            'assets/images/home_composer_add.svg',
                            expanded:
                                _menu != null && _menu != _CompanionMenu.model,
                            onPressed: () => _showMenu(
                              _menu == _CompanionMenu.root
                                  ? null
                                  : _CompanionMenu.root,
                            ),
                          ),
                        ),
                        const Spacer(),
                        TapRegion(
                          groupId: _menuTapGroup,
                          child: _toolbarButton(
                            '模型 ${widget.modelSelection.model.name}',
                            'assets/images/reading_companion_model_brain.svg',
                            size: 19,
                            expanded: _menu == _CompanionMenu.model,
                            onPressed: () => _showMenu(
                              _menu == _CompanionMenu.model
                                  ? null
                                  : _CompanionMenu.model,
                            ),
                          ),
                        ),
                        _voiceButton(),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: widget.controller,
                          builder: (context, _, _) {
                            final controller = widget.controller;
                            final hasExplicitCapability =
                                controller is CapabilityTagTextController &&
                                controller.hasExplicitCapability;
                            final canSend =
                                widget.sendingEnabled &&
                                (_draftText.trim().isNotEmpty ||
                                    hasExplicitCapability ||
                                    widget.attachments.isNotEmpty);
                            return _toolbarButton(
                              widget.generating ? '停止生成' : '发送',
                              widget.generating
                                  ? 'assets/images/home_send_stop.svg'
                                  : canSend
                                  ? 'assets/images/home_send_active.svg'
                                  : 'assets/images/home_send_idle.svg',
                              onPressed: widget.generating
                                  ? widget.onStop
                                  : canSend
                                  ? widget.onSend
                                  : null,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbarButton(
    String label,
    String asset, {
    double size = 28,
    bool? expanded,
    VoidCallback? onPressed,
  }) => Semantics(
    expanded: expanded,
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(
        width: _controlHeight,
        height: _controlHeight,
      ),
      padding: EdgeInsets.zero,
      icon: _CompanionIcon(asset, size: size),
    ),
  );

  Widget _voiceButton() {
    final onStart = widget.onVoiceLongPressStart;
    final onEnd = widget.onVoiceLongPressEnd;
    if (onStart == null || onEnd == null) return const SizedBox.shrink();
    void start() {
      widget.focusNode.unfocus();
      _showMenu(null);
      onStart();
    }

    return Tooltip(
      message: '按住说话',
      child: Semantics(
        label: widget.voiceRecording ? '结束录音' : '语音输入，按住说话',
        button: true,
        onTap: widget.voiceRecording ? onEnd : null,
        onLongPress: start,
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (_) => start(),
          onLongPressMoveUpdate: (details) =>
              widget.onVoiceLongPressMove?.call(details.offsetFromOrigin.dy),
          onLongPressEnd: (_) => onEnd(),
          onLongPressCancel: widget.onVoiceLongPressCancel,
          child: const SizedBox.square(
            dimension: _controlHeight,
            child: Center(
              child: _CompanionIcon(
                'assets/images/home_composer_microphone.svg',
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _voiceFeedback() {
    final label = widget.voiceCancelArmed
        ? '松开取消'
        : widget.voiceRecording
        ? '松开发送，上滑取消'
        : widget.voiceTranscribing
        ? '正在转写…'
        : '正在启动录音…';
    final soundLevel = widget.voiceSoundLevel;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 31),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.voiceRecording &&
                !widget.voiceCancelArmed &&
                soundLevel != null) ...[
              ValueListenableBuilder<double>(
                valueListenable: soundLevel,
                builder: (context, level, child) => SizedBox(
                  width: 44,
                  child: LinearProgressIndicator(
                    value: level.clamp(0.0, 1.0).toDouble(),
                    color: _subtleInk,
                    backgroundColor: _line,
                    minHeight: 2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(label, style: const TextStyle(color: _subtleInk)),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ComposerSlot { conversation, composer, menu }

class _CompanionComposerLayout extends MultiChildLayoutDelegate {
  _CompanionComposerLayout(this.menu);

  final _CompanionMenu? menu;

  @override
  void performLayout(Size size) {
    final composerSize = layoutChild(
      _ComposerSlot.composer,
      BoxConstraints.tightFor(
        width: size.width,
      ).copyWith(maxHeight: size.height),
    );
    final composerTop = size.height - composerSize.height;
    positionChild(_ComposerSlot.composer, Offset(0, composerTop));
    layoutChild(
      _ComposerSlot.conversation,
      BoxConstraints.tightFor(
        width: size.width,
        height: math.max(0.0, composerTop - 12),
      ),
    );
    positionChild(_ComposerSlot.conversation, Offset.zero);
    if (menu == null) return;

    final toolMenu =
        menu == _CompanionMenu.root || menu == _CompanionMenu.model;
    final bottom = toolMenu
        ? size.height - _controlHeight - 6
        : composerTop - 8;
    final panelWidth = switch (menu) {
      _CompanionMenu.root => math.min(176.0, size.width),
      _CompanionMenu.model => math.min(320.0, size.width),
      _ => size.width,
    };
    final panelLimit = switch (menu) {
      _CompanionMenu.skills => 360.0,
      _CompanionMenu.mcp => 280.0,
      _CompanionMenu.model => 300.0,
      _ => 240.0,
    };
    final panelSize = layoutChild(
      _ComposerSlot.menu,
      BoxConstraints(
        minWidth: panelWidth,
        maxWidth: panelWidth,
        maxHeight: math.max(0.0, math.min(panelLimit, bottom)),
      ),
    );
    positionChild(
      _ComposerSlot.menu,
      Offset(
        menu == _CompanionMenu.model ? size.width - panelWidth : 0.0,
        math.max(0.0, bottom - panelSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(_CompanionComposerLayout oldDelegate) =>
      oldDelegate.menu != menu;
}

class _CompanionIcon extends StatelessWidget {
  const _CompanionIcon(this.asset, {this.size = 17});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    asset,
    width: size,
    height: size,
    excludeFromSemantics: true,
  );
}
