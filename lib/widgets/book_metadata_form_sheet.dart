import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_category.dart';
import '../models/book_recognition.dart';
import 'book_cover.dart';
import 'book_cover_picker_sheet.dart';

class BookMetadataFormResult {
  const BookMetadataFormResult({
    required this.book,
    required this.categoryIds,
    this.saveError,
  });

  final BookRecord book;
  final List<int> categoryIds;
  final String? saveError;
}

Future<BookMetadataFormResult?> showBookMetadataForm({
  required BuildContext context,
  required BookRecord initial,
  List<BookCategory> categories = const [],
  List<int> initialCategoryIds = const [],
  String? saveError,
}) => showModalBottomSheet<BookMetadataFormResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  requestFocus: false,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0x99000000),
  builder: (_) => Material(
    color: Colors.white,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    clipBehavior: Clip.antiAlias,
    child: BookMetadataFormSheet(
      initial: initial,
      categories: categories,
      initialCategoryIds: initialCategoryIds,
      saveError: saveError,
    ),
  ),
);

class BookMetadataFormSheet extends StatefulWidget {
  const BookMetadataFormSheet({
    super.key,
    required this.initial,
    this.categories = const [],
    this.initialCategoryIds = const [],
    this.saveError,
  });

  final BookRecord initial;
  final List<BookCategory> categories;
  final List<int> initialCategoryIds;
  final String? saveError;

  @override
  State<BookMetadataFormSheet> createState() => _BookMetadataFormSheetState();
}

class _BookMetadataFormSheetState extends State<BookMetadataFormSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _title;
  late final TextEditingController _author;
  late final TextEditingController _publisher;
  late final TextEditingController _edition;
  late final FocusNode _titleFocus;
  late final FocusNode _authorFocus;
  late final FocusNode _publisherFocus;
  late final FocusNode _editionFocus;
  late BookRecord _cover;
  late final Set<int> _selectedCategoryIds;
  String? _titleError;
  String? _categoryError;
  bool _keyboardVisible = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: widget.initial.title == '待确认书籍' ? '' : widget.initial.title,
    );
    _author = TextEditingController(text: widget.initial.authorLabel);
    _publisher = TextEditingController(text: widget.initial.publisher);
    _edition = TextEditingController(text: widget.initial.editionLabel);
    _titleFocus = FocusNode();
    _authorFocus = FocusNode();
    _publisherFocus = FocusNode();
    _editionFocus = FocusNode();
    _cover = widget.initial;
    _selectedCategoryIds = widget.initialCategoryIds.toSet();
    WidgetsBinding.instance.addObserver(this);
    final views = WidgetsBinding.instance.platformDispatcher.views;
    _keyboardVisible = views.isNotEmpty && views.first.viewInsets.bottom > 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _author.dispose();
    _publisher.dispose();
    _edition.dispose();
    _titleFocus.dispose();
    _authorFocus.dispose();
    _publisherFocus.dispose();
    _editionFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final keyboardVisible =
        views.isNotEmpty && views.first.viewInsets.bottom > 0;
    if (_keyboardVisible && !keyboardVisible) {
      _unfocusEmptyField(_titleFocus, _title);
      _unfocusEmptyField(_authorFocus, _author);
      _unfocusEmptyField(_publisherFocus, _publisher);
      _unfocusEmptyField(_editionFocus, _edition);
    }
    _keyboardVisible = keyboardVisible;
  }

  void _unfocusEmptyField(FocusNode focus, TextEditingController controller) {
    if (focus.hasFocus && controller.text.isEmpty) focus.unfocus();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请填写书名');
      return;
    }
    if (_selectedCategoryIds.length > 3) {
      setState(() => _categoryError = '一本书最多选择 3 个分类');
      return;
    }
    final author = _author.text.trim();
    final authors = author == widget.initial.authorLabel
        ? widget.initial.authors
        : author
              .split(RegExp(r'[、,，/]'))
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false);
    final edition = _edition.text.trim();
    final editionChanged = edition != widget.initial.editionLabel;
    Navigator.of(context).pop(
      BookMetadataFormResult(
        book: widget.initial.copyWith(
          title: title,
          authors: authors,
          publisher: _publisher.text.trim(),
          edition: editionChanged ? edition : widget.initial.edition,
          publishedDate: editionChanged ? '' : widget.initial.publishedDate,
          coverUrl: _cover.coverUrl,
          coverPath: _cover.coverPath,
          coverType: _cover.coverType,
          coverTemplate: _cover.coverTemplate,
          isCustom: widget.initial.isCustom || widget.initial.title == '待确认书籍',
        ),
        categoryIds: _selectedCategoryIds.toList(growable: false),
      ),
    );
  }

  Future<void> _chooseCover() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = await showBookCoverPicker(
      context,
      initial: _cover,
      persistOnSelect: false,
    );
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
            const Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFD5D8DE),
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                child: SizedBox(width: 42, height: 5),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text('确认书籍资料', style: BookFlowTheme.heading),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: BookFlowTheme.ink,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('书名为必填项，其余信息可稍后补充。', style: BookFlowTheme.caption),
            if (widget.saveError != null) ...[
              const SizedBox(height: 8),
              Text(
                '上次保存失败，修改仍保留，可继续调整或重试：${widget.saveError}',
                style: const TextStyle(
                  color: BookFlowTheme.danger,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 18),
            TextField(
              controller: _title,
              focusNode: _titleFocus,
              autofocus: false,
              textInputAction: TextInputAction.next,
              onTapOutside: (_) => _titleFocus.unfocus(),
              decoration: _metadataInputDecoration(
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
              focusNode: _authorFocus,
              textInputAction: TextInputAction.next,
              onTapOutside: (_) => _authorFocus.unfocus(),
              decoration: _metadataInputDecoration(
                labelText: '作者',
                hintText: '多个作者可用顿号分隔',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _publisher,
              focusNode: _publisherFocus,
              textInputAction: TextInputAction.next,
              onTapOutside: (_) => _publisherFocus.unfocus(),
              decoration: _metadataInputDecoration(labelText: '出版社'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _edition,
              focusNode: _editionFocus,
              textInputAction: TextInputAction.done,
              onTapOutside: (_) => _editionFocus.unfocus(),
              decoration: _metadataInputDecoration(labelText: '版本 / 出版年份'),
              onSubmitted: (_) => _save(),
            ),
            if (widget.categories.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('分类', style: BookFlowTheme.heading),
              const SizedBox(height: 4),
              const Text('最多选择 3 个分类', style: BookFlowTheme.caption),
              if (_categoryError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _categoryError!,
                  style: const TextStyle(color: BookFlowTheme.danger),
                ),
              ],
              const SizedBox(height: 6),
              for (final category in widget.categories)
                CheckboxListTile(
                  value: _selectedCategoryIds.contains(category.id),
                  title: Text(category.name),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: BookFlowTheme.ink,
                  onChanged: category.id == null
                      ? null
                      : (checked) {
                          FocusManager.instance.primaryFocus?.unfocus();
                          final id = category.id!;
                          if (checked == true &&
                              _selectedCategoryIds.length >= 3) {
                            setState(() => _categoryError = '一本书最多选择 3 个分类');
                            return;
                          }
                          setState(() {
                            if (checked == true) {
                              _selectedCategoryIds.add(id);
                            } else {
                              _selectedCategoryIds.remove(id);
                            }
                            _categoryError = null;
                          });
                        },
                ),
            ],
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
                border: Border.all(color: const Color(0xFFD5D8DE)),
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
                          '原书封面或上传照片',
                          style: TextStyle(fontSize: 12, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('book_cover_choose_button'),
                    onPressed: _chooseCover,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BookFlowTheme.ink,
                      minimumSize: const Size(48, 48),
                      side: const BorderSide(color: Color(0xFFD5D8DE)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('更换'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: BookFlowTheme.ink,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
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
      border: Border.all(color: const Color(0xFFD5D8DE)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: BookFlowTheme.inkSecondary),
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

InputDecoration _metadataInputDecoration({
  required String labelText,
  String? hintText,
  String? errorText,
}) {
  const borderColor = Color(0xFFD5D8DE);
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    errorText: errorText,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    border: border(borderColor),
    enabledBorder: border(borderColor),
    focusedBorder: border(BookFlowTheme.ink, 1.3),
    errorBorder: border(BookFlowTheme.danger),
    focusedErrorBorder: border(BookFlowTheme.danger, 1.3),
  );
}

class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFF2F2F2),
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
