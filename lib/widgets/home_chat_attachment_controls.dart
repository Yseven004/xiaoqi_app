import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/home_chat_attachment.dart';

class HomeChatAttachmentTray extends StatelessWidget {
  const HomeChatAttachmentTray({
    required this.attachments,
    required this.onRemove,
    this.onEditDrawing,
    super.key,
  });

  final List<HomeChatAttachment> attachments;
  final ValueChanged<HomeChatAttachment> onRemove;
  final ValueChanged<HomeChatAttachment>? onEditDrawing;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
      child: SizedBox(
        height: 78,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: attachments.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final item = attachments[index];
            final canEditDrawing =
                item.source == 'drawing' &&
                item.drawingDraftPath != null &&
                onEditDrawing != null;
            final preview = GestureDetector(
              onTap: canEditDrawing
                  ? () => onEditDrawing!(item)
                  : item.isImage
                  ? () => _showImage(context, item)
                  : null,
              child: Container(
                width: item.isImage ? 64 : 150,
                height: 68,
                padding: item.isImage
                    ? EdgeInsets.zero
                    : const EdgeInsets.fromLTRB(10, 7, 23, 7),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F4),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: item.isImage
                    ? Image.file(File(item.path), fit: BoxFit.cover)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF303134),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${item.name.split('.').last.toUpperCase()} · ${_size(item.byteLength)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF777777),
                            ),
                          ),
                        ],
                      ),
              ),
            );
            final editBadge = Positioned(
              right: 5,
              bottom: 5,
              child: IgnorePointer(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Color(0xCCFFFFFF),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: SvgPicture.asset(
                    'assets/icons/capabilities/edit.svg',
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            );
            Widget removeButton(Alignment alignment) => Semantics(
              button: true,
              label: '移除${item.name}',
              child: Tooltip(
                message: '移除${item.name}',
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onRemove(item),
                      child: Align(
                        alignment: alignment,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: const Color(0xCC555555),
                            child: const Icon(
                              Icons.close,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );

            if (canEditDrawing) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(children: [preview, editBadge]),
                  removeButton(Alignment.topLeft),
                ],
              );
            }
            return Stack(
              children: [
                preview,
                Positioned(
                  top: 0,
                  right: 0,
                  child: removeButton(Alignment.topRight),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showImage(BuildContext context, HomeChatAttachment item) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: Image.file(File(item.path), fit: BoxFit.contain),
        ),
      ),
    );
  }

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).ceil()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class HomeChatMessageAttachments extends StatelessWidget {
  const HomeChatMessageAttachments({required this.attachments, super.key});

  final List<HomeChatAttachment> attachments;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    children: attachments
        .map((item) {
          if (item.isImage) {
            return Semantics(
              image: true,
              label: item.name,
              child: GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => Dialog(
                    backgroundColor: Colors.transparent,
                    insetPadding: const EdgeInsets.all(16),
                    child: InteractiveViewer(
                      child: Image.file(
                        File(item.path),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(item.path),
                    width: 124,
                    height: 104,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(
                      width: 124,
                      height: 104,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/images/home_attachment_file.svg',
                  width: 24,
                  height: 24,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF303134),
                          fontSize: 13,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${item.name.split('.').last.toUpperCase()} · ${_size(item.byteLength)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF777777),
                          fontSize: 11,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        })
        .toList(growable: false),
  );

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).ceil()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class HomeChatAttachmentActionPanel extends StatelessWidget {
  const HomeChatAttachmentActionPanel({
    required this.onSelected,
    required this.onRecentPhotoSelected,
    required this.recentPhotos,
    required this.selectedRecentPhotoIds,
    required this.loadingRecentPhotos,
    required this.visible,
    super.key,
  });

  final ValueChanged<int> onSelected;
  final ValueChanged<AssetEntity> onRecentPhotoSelected;
  final List<AssetEntity> recentPhotos;
  final Set<String> selectedRecentPhotoIds;
  final bool loadingRecentPhotos;
  final bool visible;
  static const _options = [
    ('图片', 'assets/images/home_attachment_image.svg'),
    ('拍照', 'assets/images/home_attachment_camera.svg'),
    ('本地文件', 'assets/images/home_attachment_file.svg'),
    ('微信文件', 'assets/images/home_attachment_wechat.svg'),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loadingRecentPhotos || recentPhotos.isNotEmpty) ...[
          _buildRecentPhotos(),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            for (var i = 0; i < _options.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  label: _options[i].$1,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => onSelected(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F3F3),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.all(11),
                            child: SvgPicture.asset(_options[i].$2),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _options[i].$1,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF303134),
                              height: 1.1,
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
      ],
    ),
  );

  Widget _buildRecentPhotos() => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final size = (constraints.maxWidth - gap * 4) / 5;
      if (loadingRecentPhotos && recentPhotos.isEmpty) {
        return SizedBox(
          height: size,
          child: Row(
            children: [
              for (var index = 0; index < 5; index++) ...[
                if (index > 0) const SizedBox(width: gap),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F1F1),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      }
      return SizedBox(
        height: size,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: recentPhotos.length,
            separatorBuilder: (_, __) => const SizedBox(width: gap),
            itemBuilder: (context, index) {
              final photo = recentPhotos[index];
              return _RecentPhotoThumbnail(
                key: ValueKey(photo.id),
                photo: photo,
                size: size,
                selected: selectedRecentPhotoIds.contains(photo.id),
                visible: visible,
                onTap: () => onRecentPhotoSelected(photo),
              );
            },
          ),
        ),
      );
    },
  );
}

class _RecentPhotoThumbnail extends StatefulWidget {
  const _RecentPhotoThumbnail({
    required this.photo,
    required this.size,
    required this.selected,
    required this.visible,
    required this.onTap,
    super.key,
  });

  final AssetEntity photo;
  final double size;
  final bool selected;
  final bool visible;
  final VoidCallback onTap;

  @override
  State<_RecentPhotoThumbnail> createState() => _RecentPhotoThumbnailState();
}

class _RecentPhotoThumbnailState extends State<_RecentPhotoThumbnail> {
  late Future<Uint8List?> _thumbnail;
  bool _thumbnailFailed = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(_RecentPhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.id != widget.photo.id ||
        oldWidget.photo.modifiedDateTime != widget.photo.modifiedDateTime) {
      _loadThumbnail();
    } else if (!oldWidget.visible && widget.visible && _thumbnailFailed) {
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    _thumbnailFailed = false;
    _thumbnail = widget.photo
        .thumbnailDataWithSize(const ThumbnailSize.square(160), quality: 80)
        .then<Uint8List?>(
          (bytes) {
            _thumbnailFailed = bytes == null;
            return bytes;
          },
          onError: (Object _, StackTrace __) {
            _thumbnailFailed = true;
            return null;
          },
        );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    image: true,
    selected: widget.selected,
    label: widget.selected ? '取消选择图片' : '选择图片',
    child: InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: _thumbnail,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const ColoredBox(color: Color(0xFFF1F1F1));
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 160,
                    cacheHeight: 160,
                    errorBuilder: (_, __, ___) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _thumbnailFailed = true;
                      });
                      return const ColoredBox(color: Color(0xFFF1F1F1));
                    },
                  );
                },
              ),
              if (widget.selected) const ColoredBox(color: Color(0x38000000)),
              Positioned(
                top: 4,
                right: 4,
                child: SvgPicture.asset(
                  widget.selected
                      ? 'assets/images/home_attachment_photo_selected.svg'
                      : 'assets/images/home_attachment_photo_unselected.svg',
                  width: 22,
                  height: 22,
                  excludeFromSemantics: true,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
