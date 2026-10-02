import 'dart:io';

import 'package:flutter/material.dart';

import '../../../widgets/editor_toolbar_asset_button.dart';
import '../domain/ai_annotation_source_attachment.dart';

/// The pre-send source tray for laser-selected page fragments.
///
/// Each item remains an independent screenshot + structured anchor. The tray
/// only groups the presentation; it never merges the underlying sources.
class AiAnnotationAttachmentTray extends StatefulWidget {
  const AiAnnotationAttachmentTray({
    super.key,
    required this.state,
    required this.onInputChanged,
    required this.onRemove,
    required this.onSend,
    this.onViewAll,
    this.onTapAttachment,
    this.onVoice,
    this.floating = false,
    this.onClose,
  });

  final AiAnnotationAttachmentTrayState state;
  final ValueChanged<String> onInputChanged;
  final ValueChanged<String> onRemove;
  final VoidCallback onSend;
  final VoidCallback? onViewAll;
  final ValueChanged<String>? onTapAttachment;
  final VoidCallback? onVoice;
  final bool floating;
  final VoidCallback? onClose;

  @override
  State<AiAnnotationAttachmentTray> createState() =>
      _AiAnnotationAttachmentTrayState();
}

class _AiAnnotationAttachmentTrayState
    extends State<AiAnnotationAttachmentTray> {
  late final TextEditingController _inputController;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.state.inputText);
  }

  @override
  void didUpdateWidget(covariant AiAnnotationAttachmentTray oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.inputText != widget.state.inputText &&
        _inputController.text != widget.state.inputText) {
      _inputController.value = TextEditingValue(
        text: widget.state.inputText,
        selection: TextSelection.collapsed(
          offset: widget.state.inputText.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: .08),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFE4E2DE)),
        borderRadius: BorderRadius.all(
          Radius.circular(widget.floating ? 18 : 24),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrayHeader(
                count: state.count,
                onViewAll: state.count == 0 ? null : widget.onViewAll,
                floating: widget.floating,
                onClose: widget.onClose,
              ),
              if (state.attachments.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 118,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: state.attachments.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final attachment = state.attachments[index];
                      return AiAnnotationAttachmentThumbnail(
                        attachment: attachment,
                        selected: attachment.id == state.activeAttachmentId,
                        onTap: widget.onTapAttachment == null
                            ? null
                            : () => widget.onTapAttachment!(attachment.id),
                        onRemove: () => widget.onRemove(attachment.id),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 10),
              _ComposerRow(
                controller: _inputController,
                canSend: state.canSend,
                onChanged: widget.onInputChanged,
                onSend: widget.onSend,
                onVoice: widget.onVoice,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrayHeader extends StatelessWidget {
  const _TrayHeader({
    required this.count,
    this.onViewAll,
    this.floating = false,
    this.onClose,
  });

  final int count;
  final VoidCallback? onViewAll;
  final bool floating;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            floating ? '小七' : '已圈选 $count 条',
            style: const TextStyle(
              color: Color(0xFF202020),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (floating)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '已圈选 $count 条',
              style: const TextStyle(color: Color(0xFF8B8984), fontSize: 12),
            ),
          ),
        TextButton(
          onPressed: onViewAll,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF8D6B2E),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(44, 40),
          ),
          child: const Text('查看全部来源'),
        ),
        if (floating)
          IconButton(
            onPressed: onClose,
            tooltip: '收起对话面板',
            icon: const Icon(Icons.remove, size: 22),
          ),
      ],
    );
  }
}

/// Persistent bottom-right entry for the confirmed floating conversation
/// window. The badge is intentionally hidden when there are no pending
/// screenshots; the entry itself remains available for current-page chat.
class AiAnnotationFloatingButton extends StatelessWidget {
  const AiAnnotationFloatingButton({
    super.key,
    required this.pendingCount,
    required this.onPressed,
  });

  final int pendingCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: pendingCount > 0 ? '小七，对话中有$pendingCount条待发送来源' : '打开小七对话',
      child: Material(
        color: Colors.white,
        elevation: 7,
        shadowColor: Colors.black.withValues(alpha: .12),
        shape: const CircleBorder(side: BorderSide(color: Color(0xFFE1DED9))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Image.asset(
                    EditorToolbarAssets.aiC,
                    width: 32,
                    height: 32,
                    fit: BoxFit.contain,
                  ),
                ),
                if (pendingCount > 0)
                  Positioned(
                    right: -2,
                    top: -4,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0xFFC54237),
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Text(
                          '$pendingCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AiAnnotationAttachmentThumbnail extends StatelessWidget {
  const AiAnnotationAttachmentThumbnail({
    required this.attachment,
    required this.selected,
    required this.onRemove,
    this.onTap,
    this.showRemove = true,
  });

  final AiAnnotationSourceAttachment attachment;
  final bool selected;
  final VoidCallback onRemove;
  final VoidCallback? onTap;
  final bool showRemove;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '第${attachment.sequence}条来源，${attachment.pageLabel}',
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 118,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF8F8F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? const Color(0xFF202020)
                    : const Color(0xFFE5E3DF),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: _ScreenshotPreview(path: attachment.screenshotPath),
                  ),
                ),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0xCC202020),
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                        child: Text(
                          '${attachment.sequence}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showRemove)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton(
                      onPressed: onRemove,
                      tooltip: '删除第${attachment.sequence}条来源',
                      icon: const Icon(Icons.close, size: 18),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: .9),
                        foregroundColor: const Color(0xFF202020),
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScreenshotPreview extends StatelessWidget {
  const _ScreenshotPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return const ColoredBox(color: Color(0xFFF1F0ED));
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFFF1F0ED)),
    );
  }
}

class _ComposerRow extends StatelessWidget {
  const _ComposerRow({
    required this.controller,
    required this.canSend,
    required this.onChanged,
    required this.onSend,
    this.onVoice,
  });

  final TextEditingController controller;
  final bool canSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback? onVoice;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4E2DE)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 3,
                onChanged: onChanged,
                decoration: const InputDecoration(
                  hintText: '问问这些内容…',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              onPressed: onVoice,
              tooltip: '语音输入',
              icon: const Icon(Icons.mic_none, size: 24),
            ),
            IconButton(
              onPressed: canSend ? onSend : null,
              tooltip: '发送',
              icon: const Icon(Icons.arrow_upward, size: 24),
              style: IconButton.styleFrom(
                shape: const CircleBorder(),
                side: BorderSide(
                  color: canSend
                      ? const Color(0xFF202020)
                      : const Color(0xFFB8B6B2),
                ),
                foregroundColor: canSend
                    ? const Color(0xFF202020)
                    : const Color(0xFFB8B6B2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
