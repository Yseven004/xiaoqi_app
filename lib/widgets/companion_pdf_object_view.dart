import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/companion_pdf_reflow.dart';
import '../services/image_gallery_save.dart';
import 'app_toast.dart';
import 'reader_paper_turn.dart';

class CompanionPdfObjectView extends StatelessWidget {
  const CompanionPdfObjectView({
    super.key,
    required this.picture,
    required this.pageObjects,
    required this.isOriginalPage,
    required this.onPreview,
    this.links = const [],
    this.onLinkTap,
  });

  final CompanionPagePicture picture;
  final List<CompanionPagePicture> pageObjects;
  final bool isOriginalPage;
  final ValueChanged<CompanionPagePicture>? onPreview;
  final List<CompanionPdfLink> links;
  final ValueChanged<String>? onLinkTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final width = math.max(
          viewportWidth,
          picture.minimumReadableWidth ?? 0.0,
        );
        final height = width / picture.aspectRatio;
        final base = _pictureImage(picture, isOriginalPage: isOriginalPage);
        Widget withLinks(Widget child) => Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (onLinkTap != null)
              for (final link in links)
                if (link.bounds.overlaps(picture.bounds))
                  Positioned.fromRect(
                    rect: _linkRect(
                      link.bounds.intersect(picture.bounds),
                      width,
                      height,
                    ),
                    child: Semantics(
                      link: true,
                      label: link.target,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onLinkTap!(link.target),
                      ),
                    ),
                  ),
          ],
        );
        if (isOriginalPage) {
          return SizedBox(
            height: height,
            child: withLinks(
              Stack(
                fit: StackFit.expand,
                children: [
                  base,
                  if (onPreview != null)
                    for (final object in pageObjects)
                      Positioned.fromRect(
                        rect: Rect.fromLTRB(
                          object.bounds.left * width,
                          object.bounds.top * height,
                          object.bounds.right * width,
                          object.bounds.bottom * height,
                        ),
                        child: _previewTarget(object, const SizedBox.expand()),
                      ),
                ],
              ),
            ),
          );
        }
        final content = SizedBox(
          width: width,
          height: height,
          child: withLinks(_previewTarget(picture, base)),
        );
        if (width <= viewportWidth) return content;
        final scroll = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: onPreview == null
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          child: content,
        );
        return onPreview == null
            ? scroll
            : ReaderPaperTurnLocalDrag(child: scroll);
      },
    ),
  );

  Rect _linkRect(Rect box, double width, double height) {
    final page = picture.bounds;
    return Rect.fromLTRB(
      (box.left - page.left) * width / page.width,
      (box.top - page.top) * height / page.height,
      (box.right - page.left) * width / page.width,
      (box.bottom - page.top) * height / page.height,
    );
  }

  Widget _previewTarget(CompanionPagePicture target, Widget child) {
    final preview = onPreview;
    if (preview == null) return child;
    return Semantics(
      button: true,
      label: target.isTable ? '预览表格' : '预览图片',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => preview(target),
        child: child,
      ),
    );
  }
}

class CompanionObjectPreviewContent {
  const CompanionObjectPreviewContent(
    this.aspectRatio,
    this.child, {
    this.naturalSize,
    this.release,
  });

  final double aspectRatio;
  final Widget child;
  final Size? naturalSize;
  final VoidCallback? release;
}

Future<void> showCompanionPdfObjectPreview({
  required BuildContext context,
  required CompanionPagePicture picture,
  required String filename,
  required Future<Uint8List?> Function() loadPreview,
  required Future<Uint8List?> Function() loadExport,
}) {
  CompanionObjectPreviewContent content(Uint8List? bytes) =>
      CompanionObjectPreviewContent(
        picture.aspectRatio,
        _pictureImage(picture, bytes: bytes, gaplessPlayback: true),
      );
  return showCompanionObjectPreview(
    context: context,
    filename: filename,
    placeholder: picture.cachePath != null || picture.asset.bytes.isNotEmpty
        ? content(null)
        : null,
    loadPreview: () async => content(await loadPreview()),
    loadExport: loadExport,
  );
}

Future<void> showCompanionObjectPreview({
  required BuildContext context,
  required String filename,
  required Future<CompanionObjectPreviewContent> Function() loadPreview,
  required Future<Uint8List?> Function() loadExport,
  CompanionObjectPreviewContent? placeholder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierColor: const Color.fromRGBO(0, 0, 0, .64),
  barrierLabel: '关闭预览',
  transitionDuration: MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 200),
  pageBuilder: (context, _, _) => _CompanionObjectPreview(
    filename: filename,
    loadPreview: loadPreview,
    loadExport: loadExport,
    placeholder: placeholder,
  ),
);

class _CompanionObjectPreview extends StatefulWidget {
  const _CompanionObjectPreview({
    required this.filename,
    required this.loadPreview,
    required this.loadExport,
    this.placeholder,
  });

  final String filename;
  final Future<CompanionObjectPreviewContent> Function() loadPreview;
  final Future<Uint8List?> Function() loadExport;
  final CompanionObjectPreviewContent? placeholder;

  @override
  State<_CompanionObjectPreview> createState() =>
      _CompanionObjectPreviewState();
}

class _CompanionObjectPreviewState extends State<_CompanionObjectPreview> {
  final _transform = TransformationController();
  late final _preview = _loadPreview();
  CompanionObjectPreviewContent? _loadedContent;
  bool _saving = false;

  Future<CompanionObjectPreviewContent> _loadPreview() async {
    final content = await widget.loadPreview();
    if (mounted) {
      _loadedContent = content;
    } else {
      content.release?.call();
    }
    return content;
  }

  @override
  void dispose() {
    _transform.dispose();
    _loadedContent?.release?.call();
    super.dispose();
  }

  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await saveImageToGallery(
        loadImage: () async {
          final bytes = await widget.loadExport();
          if (bytes == null || bytes.isEmpty) {
            throw StateError('Cannot render the complete reading object.');
          }
          return bytes;
        },
        filename: widget.filename,
      );
      if (!mounted) return;
      AppToast.show(context, saved ? '已保存到相册' : '请在系统设置中允许小栖保存图片到相册');
    } catch (_) {
      if (mounted) AppToast.show(context, '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      child: FutureBuilder<CompanionObjectPreviewContent>(
        future: _preview,
        initialData: widget.placeholder,
        builder: (context, snapshot) {
          final content = snapshot.data ?? widget.placeholder;
          return Stack(
            children: [
              Positioned.fill(
                top: 72,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewport = constraints.biggest;
                    final size = content == null
                        ? Size.zero
                        : applyBoxFit(
                            BoxFit.contain,
                            Size(content.aspectRatio, 1),
                            Size(viewport.width * .88, viewport.height * .8),
                          ).destination;
                    final rect = Alignment.center.inscribe(
                      size,
                      Offset.zero & viewport,
                    );
                    final naturalSize = content?.naturalSize;
                    final maxScale = naturalSize == null || size.isEmpty
                        ? 6.0
                        : (1.4 * naturalSize.width / size.width).clamp(
                            6.0,
                            256.0,
                          );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        if (!rect.contains(
                          _transform.toScene(details.localPosition),
                        )) {
                          Navigator.of(context).pop();
                        }
                      },
                      child: InteractiveViewer(
                        transformationController: _transform,
                        maxScale: maxScale,
                        child: SizedBox.expand(
                          child: Stack(
                            children: [
                              if (content != null)
                                Positioned.fromRect(
                                  rect: rect,
                                  child: content.child,
                                )
                              else if (snapshot.hasError)
                                const Center(
                                  child: Text(
                                    '预览暂时无法显示',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                right: 16,
                top: 16,
                child: TextButton.icon(
                  onPressed: _saving || content == null
                      ? null
                      : () => unawaited(_download()),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    shape: const StadiumBorder(),
                    foregroundColor: const Color(0xFF232323),
                    backgroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xFF747474),
                    disabledBackgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  icon: SvgPicture.asset(
                    'assets/icons/chat_annotations/download.svg',
                    width: 20,
                    height: 20,
                    colorFilter: ColorFilter.mode(
                      _saving
                          ? const Color(0xFF747474)
                          : const Color(0xFF232323),
                      BlendMode.srcIn,
                    ),
                  ),
                  label: const Text('下载', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

Widget _pictureImage(
  CompanionPagePicture picture, {
  Uint8List? bytes,
  bool gaplessPlayback = false,
  bool isOriginalPage = false,
}) {
  final source = picture.asset.bytes;
  final label = picture.asset.altText;
  final ImageProvider provider;
  if (bytes != null && bytes.isNotEmpty) {
    provider = MemoryImage(bytes);
  } else if (source.isNotEmpty) {
    provider = MemoryImage(
      source is Uint8List ? source : Uint8List.fromList(source),
    );
  } else if (picture.cachePath case final path?) {
    provider = FileImage(File(path));
  } else {
    return const Center(child: Text('预览暂时无法显示'));
  }
  return Image(
    image: provider,
    fit: BoxFit.contain,
    semanticLabel: label.isNotEmpty
        ? label
        : isOriginalPage
        ? 'PDF 原页'
        : picture.isTable
        ? '表格'
        : '图片',
    gaplessPlayback: gaplessPlayback,
    errorBuilder: (_, _, _) => const Center(child: Text('图片暂时无法显示')),
  );
}
