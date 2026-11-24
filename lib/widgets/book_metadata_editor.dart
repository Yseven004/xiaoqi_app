import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/book_flow_theme.dart';
import '../models/book_category.dart';
import '../models/book_recognition.dart';
import 'app_toast.dart';
import 'book_cover.dart';
import 'book_cover_picker_sheet.dart';
import 'book_editor_dialog.dart';
import 'book_metadata_form_sheet.dart';

const _editorWidth = 560.0;
const _categoryLimit = 3;
const _inputStyle = TextStyle(color: BookFlowTheme.ink, fontSize: 15);

Future<BookMetadataFormResult?> showBookMetadataEditor({
  required BuildContext context,
  required BookRecord initial,
  required List<BookCategory> categories,
  required List<int> initialCategoryIds,
  required Future<BookCategory> Function(String) onCreateCategory,
  Future<BookRecord?> Function()? onReadOriginal,
  String? saveError,
}) => showBookEditorDialog<BookMetadataFormResult>(
  context: context,
  barrierColor: bookEditorBarrier,
  builder: (_) => _MetadataEditor(
    initial: initial,
    categories: categories,
    initialCategoryIds: initialCategoryIds,
    onCreateCategory: onCreateCategory,
    onReadOriginal: onReadOriginal,
    saveError: saveError,
  ),
);

Future<void> showBookDescriptionDialog({
  required BuildContext context,
  required String description,
  required Future<void> Function(String) onSave,
}) => showBookEditorDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  barrierDismissible: true,
  builder: (_) =>
      _BookDescriptionCard(initialValue: description, onSave: onSave),
);

class _MetadataEditor extends StatefulWidget {
  const _MetadataEditor({
    required this.initial,
    required this.categories,
    required this.initialCategoryIds,
    required this.onCreateCategory,
    this.onReadOriginal,
    this.saveError,
  });

  final BookRecord initial;
  final List<BookCategory> categories;
  final List<int> initialCategoryIds;
  final Future<BookCategory> Function(String) onCreateCategory;
  final Future<BookRecord?> Function()? onReadOriginal;
  final String? saveError;

  @override
  State<_MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<_MetadataEditor>
    with WidgetsBindingObserver, BookEditorInputFocus {
  late final _fields = <String, (FocusNode, TextEditingController)>{
    '书名 *': (FocusNode(), TextEditingController(text: widget.initial.title)),
    '作者': (
      FocusNode(),
      TextEditingController(text: widget.initial.authorLabel),
    ),
    '出版社': (FocusNode(), TextEditingController(text: widget.initial.publisher)),
    '版本 / 出版年份': (
      FocusNode(),
      TextEditingController(text: widget.initial.editionLabel),
    ),
  };
  late final _categories = [...widget.categories];
  late var _categoryIds = widget.initialCategoryIds.toSet();
  late var _description = widget.initial.description;
  late var _cover = widget.initial;
  bool _showingChild = false;
  bool _readingOriginal = false;
  final _editedMetadataFields = <String>{};
  String? _titleError;
  String? _categoryError;

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs =>
      _fields.values;

  @override
  void dispose() {
    for (final (focus, controller) in editorInputs) {
      focus.dispose();
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    FocusScope.of(context).unfocus();
    String value(String label) => _fields[label]!.$2.text.trim();
    final title = value('书名 *');
    if (title.isEmpty) {
      setState(() => _titleError = '请填写书名');
      return;
    }
    if (_categoryIds.length > _categoryLimit) {
      setState(() => _categoryError = '一本书最多选择 $_categoryLimit 个分类');
      return;
    }
    final author = value('作者');
    final authors = author == _cover.authorLabel
        ? _cover.authors
        : author
              .split(RegExp(r'[、,，/]'))
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toList(growable: false);
    final edition = value('版本 / 出版年份');
    final editionChanged = edition != _cover.editionLabel;
    Navigator.pop(
      context,
      BookMetadataFormResult(
        book: _cover.copyWith(
          title: title,
          authors: authors,
          publisher: value('出版社'),
          edition: editionChanged ? edition : _cover.edition,
          publishedDate: editionChanged ? '' : _cover.publishedDate,
          description: _description,
        ),
        categoryIds: _categoryIds.toList(growable: false),
      ),
    );
  }

  Future<void> _chooseCover() async {
    FocusScope.of(context).unfocus();
    final cover = await showBookCoverPicker(
      context,
      initial: _cover,
      persistOnSelect: false,
      maxWidth: 520,
    );
    if (mounted && cover != null) setState(() => _cover = cover);
  }

  Future<void> _readOriginal() async {
    FocusScope.of(context).unfocus();
    setState(() => _readingOriginal = true);
    try {
      final original = await widget.onReadOriginal?.call();
      if (!mounted) return;
      if (original == null) {
        AppToast.show(context, '原文件没有可补全的书籍资料');
        return;
      }
      final title = _fields['书名 *']!.$2;
      final author = _fields['作者']!.$2;
      final publisher = _fields['出版社']!.$2;
      final edition = _fields['版本 / 出版年份']!.$2;
      bool canFill(String label, TextEditingController controller) =>
          !_editedMetadataFields.contains(label) &&
          controller.text.trim().isEmpty;
      setState(() {
        if (!_editedMetadataFields.contains('书名 *') &&
            title.text == widget.initial.title &&
            original.title.isNotEmpty) {
          title.text = original.title;
        }
        if (canFill('作者', author) && original.authors.isNotEmpty) {
          author.text = original.authorLabel;
          _cover = _cover.copyWith(authors: original.authors);
        }
        if (canFill('出版社', publisher)) publisher.text = original.publisher;
        if (canFill('版本 / 出版年份', edition) && original.editionLabel.isNotEmpty) {
          edition.text = original.editionLabel;
          _cover = _cover.copyWith(
            edition: original.edition,
            publishedDate: original.publishedDate,
          );
        }
        if (_cover.coverType == 'auto' &&
            _cover.coverUrl.isEmpty &&
            _cover.coverPath.isEmpty &&
            original.coverPath.isNotEmpty) {
          _cover = _cover.copyWith(
            coverPath: original.coverPath,
            coverType: original.coverType,
          );
        }
        _cover = _cover.copyWith(title: title.text);
      });
    } finally {
      if (mounted) setState(() => _readingOriginal = false);
    }
  }

  // The detail page is the backdrop for these two editors. Keep their parent
  // route mounted so backing out of a child restores the in-progress draft.
  Future<T?> _openChild<T>(
    Widget child, {
    Color barrierColor = Colors.transparent,
    bool avoidKeyboard = true,
  }) async {
    FocusScope.of(context).unfocus();
    setState(() => _showingChild = true);
    try {
      return await showBookEditorDialog<T>(
        context: context,
        barrierColor: barrierColor,
        avoidKeyboard: avoidKeyboard,
        builder: (_) => child,
      );
    } finally {
      if (mounted) setState(() => _showingChild = false);
    }
  }

  Future<void> _editDescription() async {
    final result = await _openChild<String>(
      _BookDescriptionCard(initialValue: _description),
    );
    if (mounted && result != null) setState(() => _description = result);
  }

  Future<void> _editCategories() async {
    final result = await _openChild<Set<int>>(
      _CategoryPicker(
        categories: _categories,
        selectedIds: _categoryIds,
        createCategory: (name) async {
          final created = await widget.onCreateCategory(name);
          if (mounted &&
              !_categories.any((category) => category.id == created.id)) {
            _categories.add(created);
          }
          return created;
        },
      ),
      avoidKeyboard: false,
      barrierColor: const Color(0x26000000),
    );
    if (mounted && result != null) {
      setState(() {
        _categoryIds = result;
        _categoryError = null;
      });
    }
  }

  Widget _buildCategoryChip(BookCategory category) => Chip(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: const StadiumBorder(),
    side: const BorderSide(color: Color(0xFFCCCCCC)),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    padding: EdgeInsets.zero,
    labelPadding: const EdgeInsetsDirectional.only(start: 12, end: 3),
    labelStyle: const TextStyle(color: BookFlowTheme.ink, fontSize: 14),
    label: Tooltip(
      message: category.name,
      excludeFromSemantics: true,
      child: Text(category.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    deleteIcon: Center(child: bookEditorIcon('close', size: 15)),
    deleteButtonTooltipMessage: '移除分类「${category.name}」',
    onDeleted: () {
      FocusScope.of(context).unfocus();
      setState(() {
        _categoryIds.remove(category.id);
        _categoryError = null;
      });
    },
  );

  Widget _buildField(String label) {
    final (focus, controller) = _fields[label]!;
    final isTitle = label == '书名 *';
    final isLast = label == _fields.keys.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: focus.requestFocus,
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, height: 1.2),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Semantics(
          label: label,
          child: TextField(
            controller: controller,
            focusNode: focus,
            textInputAction: isLast
                ? TextInputAction.done
                : TextInputAction.next,
            style: _inputStyle,
            onTapOutside: (_) => focus.unfocus(),
            onChanged: (value) {
              _editedMetadataFields.add(label);
              if (!isTitle) return;
              setState(() {
                _cover = _cover.copyWith(title: value);
                _titleError = null;
              });
            },
            decoration: bookEditorInput(
              error: isTitle ? _titleError : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetadata() => LayoutBuilder(
    builder: (context, constraints) {
      final coverWidth = (constraints.maxWidth * .255).clamp(54.0, 128.0);
      final gap = constraints.maxWidth < 300 ? 8.0 : 16.0;
      return Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: const Key('book_cover_entry'),
                width: coverWidth,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: BookCover(book: _cover, borderRadius: 5),
                    ),
                    TextButton(
                      key: const Key('book_cover_choose_button'),
                      onPressed: _chooseCover,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        padding: EdgeInsets.zero,
                        foregroundColor: const Color(0xFF444444),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 14),
                      ),
                      child: const Text('更换封面', textAlign: TextAlign.center),
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap * 2 + 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final label in _fields.keys) ...[
                      _buildField(label),
                      SizedBox(height: label == _fields.keys.last ? 4 : 12),
                    ],
                    if (widget.onReadOriginal != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _readingOriginal ? null : _readOriginal,
                          child: Text(_readingOriginal ? '正在读取原书…' : '从原书补全'),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final category in _categories)
                          if (_categoryIds.contains(category.id))
                            _buildCategoryChip(category),
                        FilledButton.icon(
                          onPressed: _editCategories,
                          style:
                              bookEditorActionStyle(
                                context,
                                width: 84,
                                height: 44,
                                background: bookEditorChip,
                                foreground: BookFlowTheme.ink,
                              ).copyWith(
                                visualDensity: const VisualDensity(
                                  vertical: -2.5,
                                ),
                              ),
                          icon: bookEditorIcon('plus', size: 13),
                          label: const Text('分类'),
                        ),
                      ],
                    ),
                    if (_categoryError != null)
                      Text(
                        _categoryError!,
                        style: const TextStyle(color: BookFlowTheme.danger),
                      ),
                  ],
                ),
              ),
            ],
          ),
          PositionedDirectional(
            start: coverWidth + gap,
            top: 0,
            bottom: 0,
            width: 1,
            child: const IgnorePointer(
              child: ColoredBox(color: bookEditorLine),
            ),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => Visibility(
    visible: !_showingChild,
    maintainState: true,
    child: BookEditorDialog(
      width: _editorWidth,
      title: '编辑书籍资料',
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 10),
      onClose: () => Navigator.pop(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1, thickness: 1, color: bookEditorLine),
          const SizedBox(height: 14),
          if (widget.saveError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '上次保存失败，修改仍保留，可继续调整或重试：${widget.saveError}',
                style: const TextStyle(
                  color: BookFlowTheme.danger,
                  fontSize: 13,
                ),
              ),
            ),
          _buildMetadata(),
          const SizedBox(height: 9),
          const Divider(height: 1, thickness: 1, color: bookEditorLine),
          Semantics(
            button: true,
            label: '编辑简介',
            child: InkWell(
              onTap: _editDescription,
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '简介',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        bookEditorIcon('pencil', size: 15),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _description.trim().isEmpty ? '添加简介' : _description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: _description.trim().isEmpty
                            ? BookFlowTheme.inkSecondary
                            : BookFlowTheme.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: bookEditorLine),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _save,
              style: bookEditorActionStyle(context),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _BookDescriptionCard extends StatefulWidget {
  const _BookDescriptionCard({required this.initialValue, this.onSave});

  final String initialValue;
  final Future<void> Function(String)? onSave;

  @override
  State<_BookDescriptionCard> createState() => _BookDescriptionCardState();
}

class _BookDescriptionCardState extends State<_BookDescriptionCard>
    with WidgetsBindingObserver, BookEditorInputFocus {
  late final _controller = TextEditingController(text: widget.initialValue);
  final _focus = FocusNode();
  late String _description = widget.initialValue;
  late bool _editing = widget.onSave == null;
  bool _saving = false;
  bool _saveFailed = false;

  static const _textStyle = TextStyle(
    fontSize: 15,
    height: 1.7,
    color: BookFlowTheme.ink,
  );

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs => [
    (_focus, _controller),
  ];

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _beginEditing() {
    _controller.text = _description;
    setState(() => _editing = true);
  }

  Future<void> _complete() async {
    if (_saving) return;
    _focus.unfocus();
    final description = _controller.text.trim();
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.pop(context, description);
      return;
    }

    if (description != _description) {
      setState(() {
        _saving = true;
        _saveFailed = false;
      });
      try {
        await onSave(description);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _description = description;
      _editing = false;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Stack(
      children: [
        if (_editing && widget.onSave != null)
          Positioned.fill(
            // A backdrop tap during editing only dismisses input focus.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focus.unfocus,
              excludeFromSemantics: true,
            ),
          ),
        BookEditorDialog.description(
          title: _editing ? '编辑简介' : '本书简介',
          titleIcon: _editing ? bookEditorIcon('pencil', size: 18) : null,
          closeTooltip: widget.onSave == null ? '关闭' : '关闭简介',
          onClose: _saving
              ? null
              : () {
                  if (!_saving) Navigator.pop(context);
                },
          onEdit: _editing ? null : _beginEditing,
          footer: _editing
              ? TextFieldTapRegion(
                  child: Row(
                    children: [
                      Expanded(
                        child: _saveFailed
                            ? Semantics(
                                liveRegion: true,
                                child: const Text(
                                  '保存失败，请重试',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: BookFlowTheme.danger,
                                    fontSize: 13,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _saving ? null : _complete,
                        style: bookEditorActionStyle(context),
                        child: Text(_saving ? '保存中' : '完成'),
                      ),
                    ],
                  ),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 8, bottom: 4),
            child: _editing
                ? TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    readOnly: _saving,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    style: _textStyle,
                    onTapOutside: (_) => _focus.unfocus(),
                    decoration: const InputDecoration.collapsed(
                      hintText: '输入简介',
                      hintStyle: TextStyle(color: BookFlowTheme.inkSecondary),
                    ),
                  )
                : Scrollbar(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _description.isEmpty ? '暂无简介' : _description,
                        style: _textStyle,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    ),
  );
}

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({
    required this.categories,
    required this.selectedIds,
    required this.createCategory,
  });

  final List<BookCategory> categories;
  final Set<int> selectedIds;
  final Future<BookCategory> Function(String) createCategory;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late final _selected = {...widget.selectedIds};
  bool _creatingCategory = false;
  String? _error;

  void _toggle(int id) {
    setState(() {
      _error = null;
      if (_selected.remove(id)) return;
      if (_selected.length < _categoryLimit) {
        _selected.add(id);
      } else {
        _error = '一本书最多选择 $_categoryLimit 个分类';
      }
    });
  }

  Future<void> _create() async {
    if (_creatingCategory) return;
    setState(() => _creatingCategory = true);
    BookCategory? created;
    String? result;
    try {
      result = await showBookCategoryNameDialog(
        context,
        barrierColor: Colors.transparent,
        onCreate: (name) async {
          created = await widget.createCategory(name);
        },
      );
    } finally {
      if (mounted) setState(() => _creatingCategory = false);
    }
    final id = created?.id;
    if (!mounted || result == null || id == null) return;
    setState(() {
      if (_selected.contains(id) || _selected.length < _categoryLimit) {
        _selected.add(id);
        _error = null;
      } else {
        _error = '已创建分类。取消一个已选分类后即可选用。';
      }
    });
  }

  Widget _chip(BookCategory category) {
    final id = category.id!;
    final selected = _selected.contains(id);
    return Semantics(
      selected: selected,
      child: FilledButton(
        onPressed: () => _toggle(id),
        style:
            bookEditorActionStyle(
              context,
              width: 86,
              height: 44,
              background: selected ? BookFlowTheme.ink : bookEditorChip,
              foreground: selected ? Colors.white : BookFlowTheme.ink,
            ).copyWith(
              visualDensity: const VisualDensity(vertical: -2.5),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 15, vertical: 3),
              ),
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 14),
              ),
            ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(category.name)),
            if (selected) ...[
              const SizedBox(width: 4),
              SvgPicture.asset(
                'assets/icons/drawing/check.svg',
                width: 15,
                height: 15,
                excludeFromSemantics: true,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ColorFiltered(
    colorFilter: ColorFilter.mode(
      _creatingCategory ? const Color(0x7A000000) : Colors.transparent,
      BlendMode.srcATop,
    ),
    child: _buildPicker(context),
  );

  Widget _buildPicker(BuildContext context) => BookEditorDialog(
    width: 500,
    title: '选择分类',
    elevation: 4,
    alignment: const Alignment(0, .17),
    padding: const EdgeInsets.fromLTRB(22, 10, 22, 12),
    onClose: () => Navigator.pop(context),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '最多选择 $_categoryLimit 个分类',
          style: const TextStyle(
            color: BookFlowTheme.inkSecondary,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            for (final category in widget.categories)
              if (category.id != null) _chip(category),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(color: BookFlowTheme.danger, fontSize: 12),
          ),
        const SizedBox(height: 16),
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          spacing: 8,
          overflowSpacing: 4,
          children: [
            FilledButton.icon(
              onPressed: _create,
              icon: bookEditorIcon('plus', size: 14),
              label: const Text('自定义'),
              style: bookEditorActionStyle(
                context,
                width: 104,
                background: const Color(0xFFFAFAFA),
                foreground: BookFlowTheme.ink,
                border: const BorderSide(color: Color(0xFFAAAAAA)),
              ),
            ),
            FilledButton(
              onPressed: _selected.length > _categoryLimit
                  ? null
                  : () => Navigator.pop(context, _selected),
              style: bookEditorActionStyle(context, width: 84),
              child: const Text('完成'),
            ),
          ],
        ),
      ],
    ),
  );
}
