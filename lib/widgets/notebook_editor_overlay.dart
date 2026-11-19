import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/book_flow_theme.dart';
import '../config/notebook_theme.dart';
import '../models/notebook.dart';
import '../services/book_library_service.dart';
import '../services/database_service.dart';
import 'book_editor_dialog.dart';
import 'notebook_cover.dart';

const _deleteColor = Color(0xFFB3261E);

Future<Notebook?> showNotebookEditor({
  required BuildContext context,
  int? bookId,
  String bookName = '',
  bool requireBookAssociation = false,
  Notebook? notebook,
}) => showBookEditorDialog<Notebook>(
  context: context,
  barrierColor: const Color(0x4D000000),
  builder: (dialogContext) => Padding(
    padding: MediaQuery.viewInsetsOf(dialogContext),
    child: _NotebookEditorOverlay(
      notebook: notebook,
      bookId: bookId,
      bookName: bookName,
      requireBookAssociation: requireBookAssociation,
      onComplete: (result) {
        if (ModalRoute.of(dialogContext)?.isCurrent == true) {
          Navigator.of(dialogContext).pop(result);
        }
      },
    ),
  ),
);

class _NotebookEditorOverlay extends StatefulWidget {
  const _NotebookEditorOverlay({
    required this.onComplete,
    required this.notebook,
    required this.bookId,
    required this.bookName,
    required this.requireBookAssociation,
  });

  final ValueChanged<Notebook?> onComplete;
  final Notebook? notebook;
  final int? bookId;
  final String bookName;
  final bool requireBookAssociation;

  @override
  State<_NotebookEditorOverlay> createState() => _NotebookEditorOverlayState();
}

class _NotebookEditorOverlayState extends State<_NotebookEditorOverlay>
    with WidgetsBindingObserver, BookEditorInputFocus {
  late final _newNotebookController = TextEditingController(
    text: widget.notebook?.name,
  );
  final _newNotebookFocusNode = FocusNode();
  late int _coverIndex = widget.notebook?.coverIndex ?? 0;
  late bool _associateNewNotebook = widget.bookId != null;
  late final Future<String?>? _associatedBookName = _resolveAssociatedBook();
  bool _savingNotebook = false;
  bool _confirmingDelete = false;
  bool _closed = false;
  String? _newNotebookError;

  int? get _associatedBookId =>
      widget.notebook == null ? widget.bookId : widget.notebook!.bookId;

  bool get _canDelete =>
      widget.notebook?.id != null && !widget.notebook!.isDefault;

  Future<String?>? _resolveAssociatedBook() {
    final bookId = _associatedBookId;
    if (bookId == null ||
        (bookId == widget.bookId && widget.bookName.trim().isNotEmpty)) {
      return null;
    }
    return BookLibraryService().getBook(bookId).then((book) => book?.title);
  }

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs => [
    (_newNotebookFocusNode, _newNotebookController),
  ];

  @override
  void dispose() {
    _newNotebookController.dispose();
    _newNotebookFocusNode.dispose();
    super.dispose();
  }

  void _complete(Notebook? notebook) {
    if (_closed) return;
    _closed = true;
    _newNotebookFocusNode.unfocus();
    widget.onComplete(notebook);
  }

  void _cancel() {
    if (!_savingNotebook && !_confirmingDelete) _complete(null);
  }

  void _dismissFromBackdrop() {
    if (_newNotebookFocusNode.hasFocus) {
      _newNotebookFocusNode.unfocus();
    } else {
      _cancel();
    }
  }

  Future<void> _deleteNotebook() async {
    final notebook = widget.notebook;
    final id = notebook?.id;
    if (notebook == null ||
        id == null ||
        notebook.isDefault ||
        _savingNotebook ||
        _confirmingDelete ||
        _closed) {
      return;
    }
    _newNotebookFocusNode.unfocus();
    _confirmingDelete = true;
    try {
      final confirmed = await showBookEditorDialog<bool>(
        context: context,
        barrierColor: Colors.black38,
        builder: (dialogContext) {
          void close(bool confirmed) {
            if (ModalRoute.of(dialogContext)?.isCurrent == true) {
              Navigator.of(dialogContext).pop(confirmed);
            }
          }

          return BookEditorDialog(
            width: 380,
            title: '删除笔记本',
            onClose: () => close(false),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '将“${notebook.name}”移入回收站？里面的笔记会保留，可以在回收站恢复笔记本。',
                  style: BookFlowTheme.body,
                ),
                const SizedBox(height: 16),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 10,
                  overflowSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => close(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => close(true),
                      style: bookEditorActionStyle(
                        dialogContext,
                        background: _deleteColor,
                      ),
                      child: const Text('移入回收站'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
      if (!mounted || confirmed != true) return;
      setState(() {
        _savingNotebook = true;
        _newNotebookError = null;
      });
      await DatabaseService().deleteNotebook(id);
    } catch (_) {
      if (mounted) {
        setState(() {
          _savingNotebook = false;
          _newNotebookError = '删除失败，请重试';
        });
      }
      return;
    } finally {
      _confirmingDelete = false;
    }
    if (mounted) _complete(notebook.copyWith(isDeleted: true));
  }

  Future<void> _saveNewNotebook() async {
    if (_savingNotebook || _confirmingDelete || _closed) return;
    final name = _newNotebookController.text.trim();
    if (name.isEmpty) {
      setState(() => _newNotebookError = '请输入笔记本名称');
      _newNotebookFocusNode.requestFocus();
      return;
    }

    _newNotebookFocusNode.unfocus();
    setState(() {
      _savingNotebook = true;
      _newNotebookError = null;
    });
    final database = DatabaseService();
    final editing = widget.notebook;
    final now = DateTime.now().toIso8601String();
    final Notebook saved;
    try {
      if (editing != null && editing.id != null) {
        saved = editing.copyWith(
          name: name,
          coverIndex: _coverIndex,
          updatedAt: now,
        );
        if (await database.updateNotebook(saved) != 1) {
          throw StateError('笔记本不可用');
        }
      } else {
        final bookId = editing != null
            ? editing.bookId
            : (widget.requireBookAssociation || _associateNewNotebook
                  ? widget.bookId
                  : null);
        final id = await database.createNotebook(
          name: name,
          coverIndex: _coverIndex,
          bookId: bookId,
        );
        saved = Notebook(
          id: id,
          name: name,
          coverIndex: _coverIndex,
          bookId: bookId,
          createdAt: now,
          updatedAt: now,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingNotebook = false;
        _newNotebookError = '保存失败，请重试';
      });
      return;
    }

    if (mounted) _complete(saved);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_savingNotebook,
    child: LayoutBuilder(
      builder: (context, constraints) =>
          TextFieldTapRegion(child: _buildOverlay(constraints)),
    ),
  );

  Widget _buildOverlay(BoxConstraints constraints) {
    final availableWidth = constraints.maxWidth;
    final width = availableWidth >= 600
        ? math.min(availableWidth * 0.70, 560.0)
        : math.max(0.0, availableWidth - 32);

    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: _newNotebookFocusNode,
          builder: (context, _) => ModalBarrier(
            dismissible: !_savingNotebook,
            onDismiss: _dismissFromBackdrop,
            semanticsLabel: _newNotebookFocusNode.hasFocus ? '结束输入' : '关闭笔记本卡片',
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: width,
              maxHeight: math.max(0.0, constraints.maxHeight - 28),
            ),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: _newNotebookFocusNode.unfocus,
                child: _buildNewNotebookCard(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNewNotebookCard() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.notebook == null ? '新增笔记本' : '编辑笔记本',
                style: BookFlowTheme.heading.copyWith(fontSize: 22),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: _savingNotebook ? null : _cancel,
              icon: bookEditorIcon('close', size: 18),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildIdentity(),
        const SizedBox(height: 22),
        const Divider(height: 1, color: bookEditorLine),
        const SizedBox(height: 14),
        const Text('封面样式', style: _sectionLabel),
        const SizedBox(height: 12),
        _buildCoverChoices(),
        const SizedBox(height: 20),
        const Divider(height: 1, color: bookEditorLine),
        const SizedBox(height: 16),
        _buildActions(),
      ],
    ),
  );

  static const _sectionLabel = TextStyle(
    color: BookFlowTheme.ink,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  Widget _buildIdentity() => LayoutBuilder(
    builder: (context, constraints) {
      final previewWidth = (constraints.maxWidth * .23).clamp(64.0, 112.0);
      final preview = SizedBox(
        width: previewWidth,
        height: previewWidth * 1.5,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _newNotebookController,
          builder: (context, value, _) {
            final name = value.text.trim();
            return ExcludeSemantics(
              child: NotebookCover(
                notebook: Notebook(
                  name: name,
                  coverIndex: _coverIndex,
                  createdAt: '',
                  updatedAt: '',
                ),
                showTitle: name.isNotEmpty,
              ),
            );
          },
        ),
      );
      final fields = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ExcludeSemantics(child: Text('笔记本名称', style: _sectionLabel)),
          const SizedBox(height: 8),
          Semantics(
            label: '笔记本名称',
            child: TextField(
              controller: _newNotebookController,
              focusNode: _newNotebookFocusNode,
              enabled: !_savingNotebook,
              cursorColor: BookFlowTheme.ink,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _newNotebookFocusNode.unfocus(),
              onChanged: (_) {
                if (_newNotebookError != null) {
                  setState(() => _newNotebookError = null);
                }
              },
              decoration: bookEditorInput(
                hint: '输入笔记本名称',
                error: _newNotebookError,
                radius: 8,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildBookAssociation(),
        ],
      );
      if (constraints.maxWidth < 224) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [preview, const SizedBox(height: 12), fields],
        );
      }
      return Row(
        children: [
          preview,
          const SizedBox(width: 24),
          Expanded(child: fields),
        ],
      );
    },
  );

  Widget _buildBookAssociation() {
    final bookId = _associatedBookId;
    if (bookId == null) return const Text('未关联书籍', style: BookFlowTheme.body);

    return FutureBuilder<String?>(
      future: _associatedBookName,
      builder: (context, snapshot) {
        final bookName =
            (_associatedBookName == null
                    ? widget.bookName
                    : snapshot.data ?? '')
                .trim();
        final title = bookName.startsWith('《') && bookName.endsWith('》')
            ? bookName
            : '《$bookName》';
        final label = bookName.isEmpty ? '关联书籍' : '关联书籍：$title';
        if (widget.requireBookAssociation || widget.notebook != null) {
          return Text(label, style: BookFlowTheme.body);
        }
        return Row(
          children: [
            Expanded(child: Text(label, style: BookFlowTheme.body)),
            const SizedBox(width: 8),
            Semantics(
              label: '关联当前书籍',
              child: Switch.adaptive(
                value: _associateNewNotebook,
                activeTrackColor: BookFlowTheme.ink,
                activeThumbColor: Colors.white,
                onChanged: _savingNotebook
                    ? null
                    : (value) {
                        _newNotebookFocusNode.unfocus();
                        setState(() => _associateNewNotebook = value);
                      },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCoverChoices() => SizedBox(
    height: 88,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: NotebookTheme.covers.length,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (context, index) {
        final selected = _coverIndex == index;
        return Semantics(
          button: true,
          selected: selected,
          label: '封面样式 ${index + 1}',
          child: InkWell(
            borderRadius: NotebookCover.radius,
            onTap: _savingNotebook
                ? null
                : () {
                    _newNotebookFocusNode.unfocus();
                    setState(() => _coverIndex = index);
                  },
            child: SizedBox(
              width: 58,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeSemantics(
                    child: NotebookCover(
                      notebook: Notebook(
                        name: '',
                        coverIndex: index,
                        createdAt: '',
                        updatedAt: '',
                      ),
                      showTitle: false,
                    ),
                  ),
                  if (selected) ...[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: NotebookCover.radius,
                        border: Border.all(color: BookFlowTheme.ink, width: 2),
                      ),
                    ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: BookFlowTheme.ink,
                          shape: BoxShape.circle,
                        ),
                        child: SvgPicture.asset(
                          'assets/icons/drawing/check.svg',
                          width: 11,
                          height: 11,
                          excludeFromSemantics: true,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _buildActions() => Row(
    children: [
      Expanded(
        child: FilledButton(
          onPressed: _savingNotebook
              ? null
              : (_canDelete ? _deleteNotebook : _cancel),
          style: bookEditorActionStyle(
            context,
            width: 0,
            height: 46,
            background: _canDelete ? const Color(0xFFFBEDEC) : bookEditorChip,
            foreground: _canDelete ? _deleteColor : BookFlowTheme.ink,
            border: _canDelete ? const BorderSide(color: _deleteColor) : null,
          ),
          child: Text(_canDelete ? '删除' : '取消'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton(
          onPressed: _savingNotebook ? null : _saveNewNotebook,
          style: bookEditorActionStyle(context, width: 0, height: 46),
          child: Text(_savingNotebook ? '处理中…' : '保存'),
        ),
      ),
    ],
  );
}
