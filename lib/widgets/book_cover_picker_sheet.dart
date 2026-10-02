import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/book_flow_theme.dart';
import '../models/book_cover_design.dart';
import '../models/book_recognition.dart';
import 'book_cover.dart';
import 'app_toast.dart';

Future<BookRecord?> showBookCoverPicker(
  BuildContext context, {
  required BookRecord initial,
}) {
  return showModalBottomSheet<BookRecord>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x990C1712),
    builder: (_) => BookCoverPickerSheet(initial: initial),
  );
}

class BookCoverPickerSheet extends StatefulWidget {
  const BookCoverPickerSheet({super.key, required this.initial});

  final BookRecord initial;

  @override
  State<BookCoverPickerSheet> createState() => _BookCoverPickerSheetState();
}

class _BookCoverPickerSheetState extends State<BookCoverPickerSheet> {
  final _picker = ImagePicker();
  late BookRecord _selected;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1200,
        maxHeight: 1800,
      );
      if (file == null || !mounted) return;
      final storedPath = await _persistImage(file);
      setState(() {
        _selected = _selected.copyWith(
          coverType: 'uploaded',
          coverPath: storedPath,
          coverUrl: '',
        );
      });
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '图片读取失败，请检查相册权限后重试：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<String> _persistImage(XFile file) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'book_covers'));
    await directory.create(recursive: true);
    final extension = p.extension(file.path).toLowerCase();
    const allowedExtensions = {
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.heic',
      '.heif',
    };
    final safeExtension = allowedExtensions.contains(extension)
        ? extension
        : '.jpg';
    final target = p.join(
      directory.path,
      'cover_${DateTime.now().microsecondsSinceEpoch}$safeExtension',
    );
    return (await File(file.path).copy(target)).path;
  }

  void _showAiEmptyState() {
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x88000000),
      builder: (dialogContext) => AlertDialog(
        title: const Text('专属 AI 封面'),
        content: const Text('AI 封面正在准备中。当前可以先使用模板，或上传原书封面与自己的照片，之后仍然可以随时更换。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCatalogueCover =
        _selected.coverUrl.trim().isNotEmpty ||
        _selected.isbn10.trim().isNotEmpty ||
        _selected.isbn13.trim().isNotEmpty;
    final selectedTemplate = _selected.coverType == 'template'
        ? _selected.coverTemplate
        : '';

    return Material(
      color: BookFlowTheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            14 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: BookFlowTheme.ink.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选择封面',
                        style: TextStyle(
                          color: BookFlowTheme.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  '封面文字会由应用排版，保证中文清晰可改。',
                  style: TextStyle(
                    color: BookFlowTheme.inkSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                _CurrentPreview(book: _selected),
                const SizedBox(height: 20),
                _SectionLabel(title: '原书封面'),
                const SizedBox(height: 8),
                _SourceOption(
                  key: const Key('book_cover_official_option'),
                  icon: Icons.menu_book_rounded,
                  title: '使用原书封面',
                  subtitle: hasCatalogueCover
                      ? '优先使用 ISBN 或书籍资料中的正版封面来源'
                      : '暂未找到目录封面，可以上传照片作为原书封面',
                  selected: _selected.coverType == 'official',
                  onTap: hasCatalogueCover
                      ? () => setState(
                          () => _selected = _selected.copyWith(
                            coverType: 'official',
                            coverPath: '',
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('book_cover_gallery_button'),
                        onPressed: _picking
                            ? null
                            : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('上传原书封面'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('book_cover_camera_button'),
                        onPressed: _picking
                            ? null
                            : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('拍摄封面'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _SectionLabel(title: '模板封面'),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: BookCoverTemplateDefinition.values.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                    childAspectRatio: .72,
                  ),
                  itemBuilder: (context, index) {
                    final template = BookCoverTemplateDefinition.values[index];
                    final preview = _selected.copyWith(
                      coverType: 'template',
                      coverTemplate: template.id,
                      coverPath: '',
                      coverUrl: '',
                    );
                    return _TemplateOption(
                      key: Key('book_cover_template_${template.id}'),
                      template: template,
                      book: preview,
                      selected: selectedTemplate == template.id,
                      onTap: () => setState(() => _selected = preview),
                    );
                  },
                ),
                const SizedBox(height: 20),
                _SourceOption(
                  key: const Key('book_cover_photo_option'),
                  icon: Icons.image_outlined,
                  title: '使用自己的照片',
                  subtitle: '从相册选择一张照片，应用会按书籍比例裁切并加上哑光书面效果',
                  selected: _selected.coverType == 'uploaded',
                  onTap: _picking
                      ? null
                      : () => _pickImage(ImageSource.gallery),
                ),
                const SizedBox(height: 8),
                _SourceOption(
                  key: const Key('book_cover_ai_option'),
                  icon: Icons.auto_awesome_rounded,
                  title: '专属 AI 封面',
                  subtitle: '即将开放：只生成无文字背景，标题由应用准确排版',
                  selected: false,
                  onTap: _showAiEmptyState,
                  trailing: const Chip(
                    label: Text('即将开放'),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  key: const Key('book_cover_apply_button'),
                  onPressed: _picking
                      ? null
                      : () => Navigator.pop(context, _selected),
                  style: BookFlowTheme.primaryButtonStyle(),
                  child: Text(_picking ? '正在读取图片…' : '应用此封面'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrentPreview extends StatelessWidget {
  const _CurrentPreview({required this.book});

  final BookRecord book;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BookFlowTheme.canvas,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: BookFlowTheme.line),
    ),
    child: Row(
      children: [
        RepaintBoundary(
          child: SizedBox(width: 72, height: 102, child: BookCover(book: book)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '当前预览',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 5),
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 5),
              Text(
                book.coverType == 'uploaded'
                    ? '自选照片'
                    : book.coverType == 'template'
                    ? '模板 · ${BookCoverTemplateDefinition.forId(book.coverTemplate).name}'
                    : '原书封面 / 自动推荐',
                style: TextStyle(
                  color: BookFlowTheme.inkSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      color: BookFlowTheme.ink,
      fontWeight: FontWeight.w800,
      fontSize: 16,
    ),
  );
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? BookFlowTheme.primary.withValues(alpha: .10)
        : BookFlowTheme.canvas,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              color: onTap == null
                  ? BookFlowTheme.inkSecondary.withValues(alpha: .45)
                  : BookFlowTheme.primary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: BookFlowTheme.inkSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected
                    ? BookFlowTheme.primary
                    : BookFlowTheme.inkSecondary,
              ),
          ],
        ),
      ),
    ),
  );
}

class _TemplateOption extends StatelessWidget {
  const _TemplateOption({
    super.key,
    required this.template,
    required this.book,
    required this.selected,
    required this.onTap,
  });

  final BookCoverTemplateDefinition template;
  final BookRecord book;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '模板：${template.name}',
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Column(
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: selected
                          ? BookFlowTheme.primary
                          : Colors.transparent,
                      width: selected ? 2.5 : 0,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: RepaintBoundary(
                      child: BookCover(book: book, borderRadius: 8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                template.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? BookFlowTheme.primary : BookFlowTheme.ink,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
