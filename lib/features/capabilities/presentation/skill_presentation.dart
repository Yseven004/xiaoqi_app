import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'market_ui.dart';
import '../../../widgets/app_toast.dart';

Widget skillDataImage(String data, {BoxFit fit = BoxFit.contain}) {
  try {
    final uri = UriData.parse(data);
    final bytes = uri.contentAsBytes();
    return uri.mimeType == 'image/svg+xml'
        ? SvgPicture.memory(bytes, fit: fit)
        : Image.memory(
            bytes,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (_, error, stack) =>
                const Center(child: Text('图片无法显示')),
          );
  } catch (_) {
    return const Center(child: Text('图片无法显示'));
  }
}

class SkillPresentationIcon extends StatelessWidget {
  const SkillPresentationIcon(
    this.presentation, {
    this.size = 82,
    this.defaultAsset = 'file-text',
    super.key,
  });
  final Map<String, dynamic> presentation;
  final double size;
  final String defaultAsset;
  @override
  Widget build(BuildContext context) {
    final data = presentation['icon_data']?.toString() ?? '';
    // The caller knows the content type; old selected glyphs do not define it.
    final asset = switch (defaultAsset) {
      'mcp' => 'assets/icons/capabilities/mcp_connector.svg',
      'extension' => 'assets/icons/capabilities/extension.svg',
      _ => '${marketAssets}detail/file-text.svg',
    };
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            SvgPicture.asset('${marketAssets}detail/presentation-icon-frame.svg'),
            if (data.isNotEmpty)
              skillDataImage(data, fit: BoxFit.cover)
            else
              Padding(
                padding: EdgeInsets.all(size * .22),
                child: SvgPicture.asset(asset),
              ),
          ],
        ),
      ),
    );
  }
}

Future<String?> pickSkillPresentationImage({bool icon = false}) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: icon
        ? ['svg', 'png', 'jpg', 'jpeg', 'webp']
        : ['png', 'jpg', 'jpeg', 'webp'],
  );
  if (file == null) return null;
  final length = await file.length();
  if (length == null || length <= 0 || length > 10 * 1024 * 1024) {
    throw const FormatException('请选择不超过 10 MB 的图片');
  }
  final bytes = await file.readAsBytes();
  if (icon && file.name.toLowerCase().endsWith('.svg')) {
    final svg = utf8.decode(bytes);
    if (bytes.length > 128 * 1024 ||
        RegExp(
          r'<!|<\?|\bon\w+\s*=|\bhref\s*=|\bstyle\s*=|url\s*\(',
          caseSensitive: false,
        ).hasMatch(svg) ||
        RegExp(r'<\s*/?\s*([\w:-]+)')
            .allMatches(svg)
            .any(
              (m) => !const {
                'svg',
                'g',
                'path',
                'rect',
                'circle',
                'ellipse',
                'line',
                'polyline',
                'polygon',
                'title',
                'desc',
              }.contains(m.group(1)),
            ) ||
        !RegExp(r'<svg\b').hasMatch(svg)) {
      throw const FormatException('请选择 128 KB 内、不含脚本、外链或嵌入图片的 SVG');
    }
    return 'data:image/svg+xml;base64,${base64Encode(bytes)}';
  }
  final limit = (icon ? 128 : 512) * 1024;
  for (final width in icon ? [256, 192, 128] : [1200, 900, 600]) {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: width,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data != null && data.lengthInBytes <= limit) {
          return 'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
  throw FormatException('图片处理后仍超过 ${icon ? "128" : "512"} KB，请选择较小的图片');
}

Future<Map<String, dynamic>?> chooseSkillIcon(
  BuildContext context,
  Map<String, dynamic> current, {
  String defaultAsset = 'file-text',
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  try {
    final data = await pickSkillPresentationImage(icon: true);
    return data == null
        ? null
        : {'icon_asset': defaultAsset, 'icon_data': data};
  } catch (error) {
    if (context.mounted) AppToast.show(context, '$error');
    return null;
  }
}

class SkillPresentationBody extends StatelessWidget {
  const SkillPresentationBody({
    required this.presentation,
    required this.name,
    required this.description,
    this.author = '我',
    this.kindLabel = '技能',
    super.key,
  });
  final Map<String, dynamic> presentation;
  final String name, description, author, kindLabel;
  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width <= 600;
    final title = presentation['title']?.toString().trim();
    final introduction = presentation['introduction']?.toString().trim() ?? '';
    final images = (presentation['images'] as List? ?? [])
        .whereType<Map>()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkillPresentationIcon(
              presentation,
              size: phone ? 70 : 92,
              defaultAsset: kindLabel == 'MCP'
                  ? 'mcp'
                  : kindLabel == '插件'
                  ? 'extension'
                  : 'file-text',
            ),
            SizedBox(width: phone ? 18 : 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title?.isNotEmpty == true ? title! : name,
                    style: TextStyle(
                      fontSize: phone ? 25 : 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    description,
                    style: const TextStyle(fontSize: 16, height: 1.7),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '$kindLabel · 作者：$author',
                    style: const TextStyle(color: marketMuted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (introduction.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Divider(height: 1, color: marketLine),
          ),
          const Text(
            '详细介绍',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          SelectableText(
            introduction,
            style: const TextStyle(fontSize: 16, height: 1.8),
          ),
        ],
        if (images.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Divider(height: 1, color: marketLine),
          ),
          const Text(
            '介绍图片',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 18),
          SkillPresentationGallery(
            images: images,
            layout: presentation['image_layout']?.toString() ?? 'horizontal',
          ),
        ],
      ],
    );
  }
}

class SkillPresentationGallery extends StatefulWidget {
  const SkillPresentationGallery({
    required this.images,
    required this.layout,
    super.key,
  });
  final List<Map> images;
  final String layout;
  @override
  State<SkillPresentationGallery> createState() =>
      _SkillPresentationGalleryState();
}

class _SkillPresentationGalleryState extends State<SkillPresentationGallery> {
  final Map<String, double> _ratios = {};
  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant SkillPresentationGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measure();
  }

  Future<void> _measure() async {
    for (final image in widget.images) {
      final data = image['data']?.toString() ?? '';
      if (_ratios.containsKey(data)) continue;
      _ratios[data] = .75;
      try {
        final codec = await ui.instantiateImageCodec(
          UriData.parse(data).contentAsBytes(),
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            _ratios[data] = frame.image.width / frame.image.height;
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } catch (_) {
        /* Display the existing unreadable-image placeholder. */
      }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final grid = widget.layout == 'grid';
      final columns = box.maxWidth < 320 ? 1 : 2;
      final height = box.maxWidth < 400 ? 200.0 : 280.0;
      Widget tile(Map image) {
        final data = image['data']?.toString() ?? '';
        final ratio = _ratios[data] ?? .75;
        final width = grid
            ? (box.maxWidth - (columns - 1) * 16) / columns
            : height * ratio;
        return SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: InteractiveViewer(child: skillDataImage(data)),
                  ),
                ),
                child: SizedBox(
                  height: grid ? width / ratio : height,
                  child: skillDataImage(data),
                ),
              ),
            ],
          ),
        );
      }

      if (grid)
        return Wrap(
          spacing: 16,
          runSpacing: 20,
          children: widget.images.map(tile).toList(),
        );
      return SizedBox(
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: widget.images.length,
          separatorBuilder: (_, index) => const SizedBox(width: 16),
          itemBuilder: (_, i) => tile(widget.images[i]),
        ),
      );
    },
  );
}

class SkillPublicationPreview extends StatefulWidget {
  const SkillPublicationPreview({
    required this.presentation,
    required this.name,
    required this.description,
    required this.onPublish,
    this.published = false,
    this.kindLabel = '技能',
    super.key,
  });
  final Map<String, dynamic> presentation;
  final String name, description, kindLabel;
  final bool published;
  final Future<void> Function() onPublish;
  @override
  State<SkillPublicationPreview> createState() =>
      _SkillPublicationPreviewState();
}

class _SkillPublicationPreviewState extends State<SkillPublicationPreview> {
  bool _busy = false;
  String? _error;
  Future<void> _publish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onPublish();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '发布未完成，草稿已保留：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: marketTheme(context),
    child: PopScope(
      canPop: !_busy,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        marketIconButton(
                          'back',
                          '返回编辑',
                          _busy ? null : () => Navigator.pop(context),
                        ),
                        const Expanded(
                          child: Center(
                            child: Text(
                              '预览',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                    Text(
                      widget.published ? '仅自己可见 · 修改尚未发布' : '仅自己可见 · 尚未发布',
                      style: const TextStyle(color: marketMuted, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: marketLine),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: SkillPresentationBody(
                    presentation: widget.presentation,
                    name: widget.name,
                    description: widget.description,
                    kindLabel: widget.kindLabel,
                  ),
                ),
              ),
              const Divider(height: 1, color: marketLine),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: Column(
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    const Text(
                      '发布后，其他用户可在市场查看并安装。',
                      style: TextStyle(color: marketMuted, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: marketButton(
                            '返回编辑',
                            _busy ? null : () => Navigator.pop(context),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: marketButton(
                            _busy
                                ? '正在发布…'
                                : widget.published
                                ? '确认发布更新'
                                : '确认发布',
                            _busy ? null : _publish,
                            primary: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
