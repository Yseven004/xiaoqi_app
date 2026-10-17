import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_recognition.dart';
import 'book_cover.dart';
import 'book_cover_picker_sheet.dart';

class BookMetadataFormSheet extends StatefulWidget {
  const BookMetadataFormSheet({super.key, required this.initial});

  final BookRecord initial;

  @override
  State<BookMetadataFormSheet> createState() => _BookMetadataFormSheetState();
}

class _BookMetadataFormSheetState extends State<BookMetadataFormSheet> {
  late final TextEditingController _title;
  late final TextEditingController _author;
  late final TextEditingController _publisher;
  late final TextEditingController _edition;
  late BookRecord _cover;
  String? _titleError;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: widget.initial.title == '待确认书籍' ? '' : widget.initial.title,
    );
    _author = TextEditingController(text: widget.initial.authorLabel);
    _publisher = TextEditingController(text: widget.initial.publisher);
    _edition = TextEditingController(text: widget.initial.edition);
    _cover = widget.initial;
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _publisher.dispose();
    _edition.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请填写书名');
      return;
    }
    final authors = _author.text
        .split(RegExp(r'[、,，/]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    Navigator.of(context).pop(
      widget.initial.copyWith(
        title: title,
        authors: authors,
        publisher: _publisher.text.trim(),
        edition: _edition.text.trim(),
        coverUrl: _cover.coverUrl,
        coverPath: _cover.coverPath,
        coverType: _cover.coverType,
        coverTemplate: _cover.coverTemplate,
        isCustom: widget.initial.isCustom || widget.initial.title == '待确认书籍',
      ),
    );
  }

  Future<void> _chooseCover() async {
    final selected = await showBookCoverPicker(context, initial: _cover);
    if (!mounted || selected == null) return;
    setState(() => _cover = selected);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('确认书籍资料', style: BookFlowTheme.heading),
            const SizedBox(height: 4),
            const Text('书名为必填项，其余信息可稍后补充。', style: BookFlowTheme.caption),
            const SizedBox(height: 18),
            TextField(
              controller: _title,
              autofocus: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '书名 *',
                errorText: _titleError,
              ),
              onChanged: (_) {
                setState(() {
                  _cover = _cover.copyWith(title: _title.text);
                  _titleError = null;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _author,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '作者',
                hintText: '多个作者可用顿号分隔',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _publisher,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '出版社'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _edition,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '版本 / 出版年份'),
              onSubmitted: (_) => _save(),
            ),
            if (widget.initial.description.isNotEmpty) ...[
              const SizedBox(height: 18),
              _MetadataPreviewCard(
                icon: Icons.subject_rounded,
                title: '简介',
                child: Text(
                  widget.initial.description,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.55),
                ),
              ),
            ],
            if (widget.initial.tableOfContents.isNotEmpty) ...[
              const SizedBox(height: 10),
              _MetadataPreviewCard(
                icon: Icons.format_list_bulleted_rounded,
                title: '目录 · ${widget.initial.tableOfContents.length} 项',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in widget.initial.tableOfContents.take(4))
                      Padding(
                        padding: EdgeInsets.only(
                          left: ((entry.level - 1).clamp(0, 3) * 12).toDouble(),
                          bottom: 4,
                        ),
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, height: 1.35),
                        ),
                      ),
                    if (widget.initial.tableOfContents.length > 4)
                      const Text(
                        '其余目录会随书籍资料一同保存',
                        style: BookFlowTheme.caption,
                      ),
                  ],
                ),
              ),
            ],
            if (widget.initial.metadataSources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final source in widget.initial.metadataSources)
                    _SourceTag(label: _sourceLabel(source.provider)),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Container(
              key: const Key('book_cover_entry'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BookFlowTheme.canvas,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BookFlowTheme.line),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 54,
                    height: 76,
                    child: BookCover(book: _cover),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '封面',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '原书封面、模板、上传照片都可以在这里选择',
                          style: TextStyle(fontSize: 12, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('book_cover_choose_button'),
                    onPressed: _chooseCover,
                    child: const Text('更换'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _save,
              style: BookFlowTheme.primaryButtonStyle(),
              child: const Text('保存书籍'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MetadataPreviewCard extends StatelessWidget {
  const _MetadataPreviewCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BookFlowTheme.canvas,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BookFlowTheme.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: BookFlowTheme.primary),
            const SizedBox(width: 7),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 9),
        child,
      ],
    ),
  );
}

class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: BookFlowTheme.primarySoft,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12)),
  );
}

String _sourceLabel(String provider) => switch (provider) {
  'glm_web_search' => '联网书目核对',
  'deepseek_search_fetch' => 'DeepSeek 联网书目',
  'tanshu_isbn' => '探数 ISBN',
  'tanshu_proxy' => '探数代理',
  'jisu_isbn' => '极速数据',
  'open_library' => 'Open Library 补充',
  'weread' => '微信读书补充',
  _ => '书目来源',
};
