import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'market_ui.dart';

const skillPresentationIcons = [
  'research',
  'file-text',
  'book',
  'code',
  'database',
  'presentation',
  'table',
  'folder',
  'chat',
  'plugs',
  'gear',
  'search',
];

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
  const SkillPresentationIcon(this.presentation, {this.size = 82, super.key});
  final Map<String, dynamic> presentation;
  final double size;
  @override
  Widget build(BuildContext context) {
    final data = presentation['icon_data']?.toString() ?? '';
    final asset = presentation['icon_asset']?.toString() ?? 'research';
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .22),
      decoration: BoxDecoration(
        color: marketSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: data.isNotEmpty
          ? skillDataImage(data)
          : marketIcon(
              skillPresentationIcons.contains(asset) ? asset : 'research',
              size: size * .56,
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
  Map<String, dynamic> current,
) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (dialogContext) => MarketDialog(
    title: '更换图标',
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final icon in skillPresentationIcons)
            Semantics(
              label: '选择图标 $icon',
              button: true,
              child: InkWell(
                onTap: () => Navigator.pop(dialogContext, {
                  'icon_asset': icon,
                  'icon_data': '',
                }),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: SkillPresentationIcon({'icon_asset': icon}, size: 64),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      marketButton('上传自己的图标', () async {
        try {
          final data = await pickSkillPresentationImage(icon: true);
          if (data != null && dialogContext.mounted)
            Navigator.pop(dialogContext, {
              'icon_asset': 'research',
              'icon_data': data,
            });
        } catch (error) {
          if (dialogContext.mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }, icon: 'upload'),
      const SizedBox(height: 8),
      marketButton(
        '恢复默认',
        () => Navigator.pop(dialogContext, {
          'icon_asset': 'research',
          'icon_data': '',
        }),
      ),
      const SizedBox(height: 8),
      marketButton('取消', () => Navigator.pop(dialogContext)),
    ],
  ),
);

class SkillPresentationBody extends StatelessWidget {
  const SkillPresentationBody({
    required this.presentation,
    required this.name,
    required this.description,
    this.author = '我',
    super.key,
  });
  final Map<String, dynamic> presentation;
  final String name, description, author;
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
            SkillPresentationIcon(presentation, size: phone ? 70 : 92),
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
                    '技能 · 作者：$author',
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
          LayoutBuilder(
            builder: (_, box) {
              final width = phone ? box.maxWidth : (box.maxWidth - 18) / 2;
              return Wrap(
                spacing: 18,
                runSpacing: 22,
                children: [
                  for (final image in images)
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            onTap: () => showDialog<void>(
                              context: context,
                              builder: (_) => Dialog(
                                child: InteractiveViewer(
                                  child: skillDataImage(
                                    image['data']?.toString() ?? '',
                                  ),
                                ),
                              ),
                            ),
                            child: AspectRatio(
                              aspectRatio: .75,
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                color: marketSoft,
                                child: skillDataImage(
                                  image['data']?.toString() ?? '',
                                ),
                              ),
                            ),
                          ),
                          if ((image['caption']?.toString() ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                image['caption'].toString(),
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class SkillPublicationPreview extends StatefulWidget {
  const SkillPublicationPreview({
    required this.presentation,
    required this.name,
    required this.description,
    required this.onPublish,
    this.published = false,
    super.key,
  });
  final Map<String, dynamic> presentation;
  final String name, description;
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
