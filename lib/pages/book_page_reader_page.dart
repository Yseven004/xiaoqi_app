import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../config/note_page_theme.dart';
import '../models/captured_page.dart';
import '../models/note.dart';
import '../models/page_annotation.dart';
import '../models/ocr_layout.dart';
import '../services/book_library_service.dart';
import '../services/database_service.dart';
import '../services/note_generation_service.dart';
import '../services/page_image_asset_store.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_page_annotation_view.dart';
import '../widgets/book_page_document_view.dart';
import '../widgets/editor_toolbar_asset_button.dart';
import 'book_page_edit_page.dart';
import 'viewfinder_camera_page.dart';

/// OCR 书页的统一阅读器。
///
/// 书页本身是结构化文本页面，不是原图浏览器。草稿和已保存书页共用同一
/// 阅读外壳；差异只在返回时，草稿需要先保存/放弃确认。
class BookPageReaderPage extends StatefulWidget {
  const BookPageReaderPage({
    super.key,
    required this.initialNote,
    this.initialNotes = const [],
    this.draftBatchId,
    this.bookId,
    this.bookName,
    this.bookLibraryService,
    this.persistNotes,
    this.hasUnresolvedPages = false,
    this.imageStore,
  });

  final Note initialNote;
  final List<Note> initialNotes;

  /// 非空表示当前阅读内容仍是未保存草稿。
  final String? draftBatchId;
  final int? bookId;
  final String? bookName;
  final BookLibraryService? bookLibraryService;
  final Future<List<Note>> Function(List<Note> notes)? persistNotes;
  final bool hasUnresolvedPages;
  final PageImageAssetStore? imageStore;

  bool get isDraft => draftBatchId?.trim().isNotEmpty == true;

  @override
  State<BookPageReaderPage> createState() => _BookPageReaderPageState();
}

class _BookPageReaderPageState extends State<BookPageReaderPage>
    with SingleTickerProviderStateMixin {
  final _library = BookLibraryService();
  PageController? _pageController;
  List<Note> _notes = const [];
  int _current = 0;
  bool _pageConsoleOpen = false;
  late final AnimationController _pageDrawerController;
  late final CurvedAnimation _pageDrawerAnimation;
  late final Animation<Offset> _pageDrawerPosition;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  bool _addingPage = false;
  bool _hasUnresolvedPages = false;
  late final PageImageAssetStore _imageStore;

  BookLibraryService get _bookLibrary => widget.bookLibraryService ?? _library;

  @override
  void initState() {
    super.initState();
    _pageDrawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _pageDrawerAnimation = CurvedAnimation(
      parent: _pageDrawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _pageDrawerPosition = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(_pageDrawerAnimation);
    _hasUnresolvedPages = widget.hasUnresolvedPages;
    _imageStore = widget.imageStore ?? PageImageAssetStore();
    unawaited(_load());
  }

  Future<void> _load() async {
    late final List<Note> notes;
    try {
      notes = await _fetchNotes();
    } catch (error) {
      debugPrint('[BookReader] loading pages failed: $error');
      notes = widget.initialNotes.isNotEmpty
          ? _ordered(widget.initialNotes)
          : [widget.initialNote];
    }
    if (!mounted) return;
    final initialIndex = notes.indexWhere(
      (note) => note.id != null && note.id == widget.initialNote.id,
    );
    _current = initialIndex < 0 ? 0 : initialIndex;
    _pageController?.dispose();
    _pageController = PageController(initialPage: _current);
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  Future<List<Note>> _fetchNotes() async {
    if (widget.initialNotes.isNotEmpty) {
      if (!widget.isDraft) return _ordered(widget.initialNotes);
      try {
        final savedCollection = await DatabaseService()
            .queryReaderCollectionForBatch(widget.draftBatchId!);
        if (savedCollection.isNotEmpty) {
          final byId = <String, Note>{
            for (final note in savedCollection) _noteIdentity(note): note,
          };
          for (final note in widget.initialNotes) {
            byId[_noteIdentity(note)] = note;
          }
          return _ordered(byId.values);
        }
      } catch (error) {
        debugPrint('[BookReader] draft collection query unavailable: $error');
      }
      return _ordered(widget.initialNotes);
    }
    final batchId = widget.draftBatchId ?? widget.initialNote.captureBatchId;
    if (batchId != null && batchId.isNotEmpty) {
      if (widget.isDraft) {
        final notes = await DatabaseService().queryCaptureBatch(batchId);
        if (notes.isNotEmpty) return _ordered(notes);
      } else {
        try {
          final notes = await DatabaseService().queryReaderCollectionForBatch(
            batchId,
          );
          if (notes.isNotEmpty) return _ordered(notes);
        } catch (error) {
          debugPrint('[BookReader] collection query unavailable: $error');
        }
        // Old local data may not have been backfilled yet. Keep the current
        // batch readable while the v19 migration is applied.
        final batchNotes = await DatabaseService().queryCaptureBatch(batchId);
        if (batchNotes.isNotEmpty) return _ordered(batchNotes);
      }
    }
    final groupId = widget.initialNote.pageGroupId;
    if (groupId != null && groupId.isNotEmpty) {
      final notes = await DatabaseService().queryDoublePageGroup(groupId);
      if (notes.isNotEmpty) return _ordered(notes);
    }
    return [widget.initialNote];
  }

  List<Note> _ordered(Iterable<Note> notes) {
    final result = notes.toList(growable: false);
    return [...result]..sort((a, b) {
      final sequence = (a.captureSequence ?? 1 << 30).compareTo(
        b.captureSequence ?? 1 << 30,
      );
      if (sequence != 0) return sequence;
      final group = (a.pageGroupIndex ?? a.groupIndex ?? 1 << 30).compareTo(
        b.pageGroupIndex ?? b.groupIndex ?? 1 << 30,
      );
      if (group != 0) return group;
      return (a.id ?? 1 << 30).compareTo(b.id ?? 1 << 30);
    });
  }

  @override
  void dispose() {
    _pageDrawerAnimation.dispose();
    _pageDrawerController.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _notes.length || index == _current) return;
    final controller = _pageController;
    if (controller == null) return;
    final distance = (index - _current).abs();
    if (distance == 1) {
      await controller.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      controller.jumpToPage(index);
    }
    if (!mounted) return;
    setState(() => _current = index);
  }

  void _togglePageConsole() {
    if (_pageConsoleOpen) {
      _closePageConsole();
    } else {
      _openPageConsole();
    }
  }

  void _closePageConsole() {
    if (!_pageConsoleOpen && _pageDrawerController.value == 0) return;
    setState(() => _pageConsoleOpen = false);
    _pageDrawerController.reverse();
  }

  void _openPageConsole() {
    if (_pageConsoleOpen && _pageDrawerController.value == 1) return;
    setState(() => _pageConsoleOpen = true);
    _pageDrawerController.forward();
  }

  Future<void> _handleBack() async {
    if (_pageConsoleOpen || _pageDrawerController.value > 0) {
      _closePageConsole();
      return;
    }
    if (!widget.isDraft || _saved) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final action = await showDialog<_DraftExitAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('是否保存书页？'),
        content: const Text('识别后的文本书页可以保存为独立书页，之后随时继续阅读。'),
        actions: [
          TextButton(
            key: const Key('discard_book_pages'),
            onPressed: () => Navigator.pop(context, _DraftExitAction.discard),
            child: const Text('放弃草稿'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _DraftExitAction.keep),
            child: const Text('继续查看'),
          ),
          FilledButton(
            key: const Key('save_book_pages_and_exit'),
            onPressed: () => Navigator.pop(context, _DraftExitAction.save),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == _DraftExitAction.keep) return;
    if (action == _DraftExitAction.discard) {
      await _discardDraft();
      return;
    }
    await _saveDraft(exitAfterSave: true);
  }

  Future<void> _discardDraft() async {
    final batchId = widget.draftBatchId;
    if (batchId != null && batchId.isNotEmpty) {
      try {
        await _bookLibrary.discardCaptureBatch(batchId);
      } catch (error) {
        if (mounted) AppToast.show(context, '草稿放弃失败：$error');
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveDraft({bool exitAfterSave = false}) async {
    if (_saving || _saved || _notes.isEmpty) return;
    setState(() => _saving = true);
    try {
      final notes = [
        for (final note in _notes)
          note.copyWith(
            bookId: widget.bookId,
            bookName: widget.bookName ?? note.bookName,
            bookPage: note.bookPage.isNotEmpty
                ? note.bookPage
                : _documentFor(note).pageNumber ?? '',
            updatedAt: DateTime.now().toIso8601String(),
          ),
      ];
      final persisted = widget.persistNotes != null
          ? await widget.persistNotes!(notes)
          : await _insertNotes(notes);
      if (persisted.length != notes.length) {
        throw StateError('保存结果与书页数量不一致');
      }
      final batchId = widget.draftBatchId;
      if (batchId != null && batchId.isNotEmpty) {
        if (widget.bookId != null) {
          await _bookLibrary.commitDraftPlacements(batchId, widget.bookId!);
        }
        if (_hasUnresolvedPages) {
          await _bookLibrary.completeCaptureBatchAfterSaving(
            batchId,
            preserveBookAssociation: widget.bookId != null,
          );
        } else {
          await _bookLibrary.completeCaptureBatch(
            batchId,
            preserveBookAssociation: widget.bookId != null,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _notes = persisted;
        _saving = false;
        _saved = true;
      });
      AppToast.show(
        context,
        _hasUnresolvedPages ? '已保存成功书页，失败书页已保留草稿' : '已保存书页',
      );
      if (exitAfterSave && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, '保存失败，草稿仍在：$error');
    }
  }

  Future<List<Note>> _insertNotes(List<Note> notes) async {
    return DatabaseService().upsertNotesByCapturePage(notes);
  }

  Future<void> _openAddPage() async {
    if (_addingPage) return;
    final result = await Navigator.of(context).push<CameraCaptureBatch>(
      MaterialPageRoute(builder: (_) => const ViewfinderCameraPage()),
    );
    if (!mounted || result == null || result.pages.isEmpty) return;
    setState(() => _addingPage = true);
    try {
      if (widget.isDraft) {
        await _appendToDraft(result.pages);
      } else {
        await _appendToSavedReader(result.pages);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _addingPage = false);
      AppToast.show(context, '添加书页失败：$error');
    }
  }

  Future<void> _appendToDraft(List<CapturedPage> pages) async {
    final batchId = widget.draftBatchId;
    if (batchId == null || batchId.isEmpty) {
      throw StateError('找不到当前书页草稿');
    }
    final orders = await _bookLibrary.appendDraftPages(batchId, pages);
    final newNotes = <Note>[];
    var failed = 0;
    var sequenceOffset = _notes.length;
    for (final note in _notes) {
      final sequence = note.captureSequence;
      if (sequence != null && sequence >= sequenceOffset) {
        sequenceOffset = sequence + 1;
      }
    }
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final order = orders[index];
      final pageWithBatch = _pageWithBatch(
        page,
        batchId,
        sequenceOffset + index,
      );
      try {
        var note = await NoteGenerationService.prepareAnnotationNote(
          pageWithBatch,
        );
        final capturePageId = await _bookLibrary.capturePageId(batchId, order);
        note = note.copyWith(
          captureBatchId: batchId,
          captureSequence: sequenceOffset + index,
          capturePageId: capturePageId,
        );
        await _bookLibrary.updateDraftPage(
          batchId: batchId,
          pageOrder: order,
          status: 'processed',
          processedPath: note.photoPath,
          originalPath: note.originalPhotoPath,
          ocrJson: note.annotationsJson,
          editedText: note.content,
        );
        newNotes.add(note);
      } catch (error) {
        failed++;
        await _bookLibrary.updateDraftPage(
          batchId: batchId,
          pageOrder: order,
          status: 'failed',
          errorMessage: error.toString(),
        );
      }
    }
    if (!mounted) return;
    _hasUnresolvedPages = _hasUnresolvedPages || failed > 0;
    if (newNotes.isNotEmpty) {
      _replaceReaderNotes(newNotes);
    } else {
      setState(() => _addingPage = false);
    }
    AppToast.show(
      context,
      failed == 0
          ? '已添加 ${newNotes.length} 页书页'
          : newNotes.isEmpty
          ? '新增书页识别失败，已保留草稿'
          : '已添加 ${newNotes.length} 页，$failed 页已保留草稿',
    );
  }

  Future<void> _appendToSavedReader(List<CapturedPage> pages) async {
    final batchId = await _bookLibrary.createLinkedDraftBatch(
      parentNote: _notes.first,
      pages: pages,
      selectedBookId: widget.bookId,
    );
    final newNotes = <Note>[];
    var sequenceOffset = _notes.length;
    for (final note in _notes) {
      final sequence = note.captureSequence;
      if (sequence != null && sequence >= sequenceOffset) {
        sequenceOffset = sequence + 1;
      }
    }
    var failed = 0;
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final pageWithBatch = _pageWithBatch(
        page,
        batchId,
        sequenceOffset + index,
      );
      try {
        var note = await NoteGenerationService.prepareAnnotationNote(
          pageWithBatch,
        );
        final capturePageId = await _bookLibrary.capturePageId(batchId, index);
        note = note.copyWith(capturePageId: capturePageId);
        await _bookLibrary.updateDraftPage(
          batchId: batchId,
          pageOrder: index,
          status: 'processed',
          processedPath: note.photoPath,
          originalPath: note.originalPhotoPath,
          ocrJson: note.annotationsJson,
          editedText: note.content,
        );
        newNotes.add(note);
      } catch (error) {
        failed++;
        await _bookLibrary.updateDraftPage(
          batchId: batchId,
          pageOrder: index,
          status: 'failed',
          errorMessage: error.toString(),
        );
      }
    }
    if (newNotes.isEmpty) {
      await _bookLibrary.completeCaptureBatchAfterSaving(
        batchId,
        preserveBookAssociation: widget.bookId != null,
      );
      if (!mounted) return;
      setState(() => _addingPage = false);
      AppToast.show(context, '新增书页识别失败，已保留草稿');
      return;
    }
    final persisted = await _insertNotes(newNotes);
    if (failed > 0) {
      await _bookLibrary.completeCaptureBatchAfterSaving(
        batchId,
        preserveBookAssociation: widget.bookId != null,
      );
    } else {
      await _bookLibrary.completeCaptureBatch(
        batchId,
        preserveBookAssociation: widget.bookId != null,
      );
    }
    if (!mounted) return;
    _replaceReaderNotes(persisted);
    AppToast.show(
      context,
      failed == 0
          ? '已添加 ${persisted.length} 页书页'
          : '已添加 ${persisted.length} 页，$failed 页已保留草稿',
    );
  }

  CapturedPage _pageWithBatch(CapturedPage page, String batchId, int sequence) {
    return CapturedPage(
      path: page.path,
      inputKind: page.inputKind,
      isDoublePage: page.isDoublePage,
      pageGroupId: page.pageGroupId,
      pageGroupIndex: page.pageGroupIndex,
      sourcePhotoPath: page.sourcePhotoPath,
      capturedAt: page.capturedAt,
      captureBatchId: batchId,
      captureSequence: sequence,
    );
  }

  void _replaceReaderNotes(List<Note> additions) {
    final merged = _ordered([..._notes, ...additions]);
    final target = merged.indexWhere(
      (note) => _noteIdentity(note) == _noteIdentity(additions.first),
    );
    final controller = _pageController;
    final safeTarget = target < 0 ? 0 : target;
    setState(() {
      _notes = merged;
      _current = safeTarget;
      _addingPage = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller == null || controller != _pageController) {
        return;
      }
      if (controller.hasClients) controller.jumpToPage(safeTarget);
    });
  }

  Future<void> _showOriginal(int index) async {
    if (index < 0 || index >= _notes.length) return;
    final note = _notes[index];
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.file(
                  File(
                    note.originalPhotoPath.isNotEmpty
                        ? note.originalPhotoPath
                        : note.photoPath,
                  ),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.image_not_supported_outlined,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                tooltip: '关闭原图',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
    if (_notes.isEmpty) return;
    final currentIdentity = _noteIdentity(_notes[_current]);
    final edited = await Navigator.of(context).push<List<Note>>(
      MaterialPageRoute(
        builder: (_) => BookPageEditPage(
          initialNote: _notes[_current],
          initialNotes: _notes,
          initialIndex: _current,
          isDraft: widget.isDraft,
          bookId: widget.bookId,
          bookName: widget.bookName,
        ),
      ),
    );
    if (!mounted || edited == null || edited.isEmpty) return;
    final byIdentity = <String, Note>{
      for (final note in _notes) _noteIdentity(note): note,
    };
    for (final note in edited) {
      byIdentity[_noteIdentity(note)] = note;
    }
    final merged = _ordered(byIdentity.values);
    final selectedIndex = merged.indexWhere(
      (note) => _noteIdentity(note) == currentIdentity,
    );
    setState(() {
      _notes = merged;
      _current = selectedIndex < 0 ? 0 : selectedIndex;
    });
    if (_pageController?.hasClients == true && selectedIndex >= 0) {
      _pageController!.jumpToPage(selectedIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: NotePageTheme.card,
        body: SizedBox.shrink(),
      );
    }
    if (_notes.isEmpty) {
      return const Scaffold(
        backgroundColor: NotePageTheme.card,
        body: Center(child: Text('暂无书页')),
      );
    }
    _pageController ??= PageController(initialPage: _current);
    final safeCurrent = _current.clamp(0, _notes.length - 1);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: NotePageTheme.card,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 96),
                Expanded(
                  child: PageView.builder(
                    key: const Key('book_page_reader_view'),
                    controller: _pageController,
                    itemCount: _notes.length,
                    // Pre-layout the adjacent structured page. Otherwise its
                    // document tree is first built while the user's finger is
                    // already dragging, which produces a visible hitch.
                    allowImplicitScrolling: true,
                    onPageChanged: (index) {
                      if (!mounted) return;
                      setState(() => _current = index);
                    },
                    itemBuilder: (context, index) => RepaintBoundary(
                      child: _ReaderCanvas(
                        key: Key('book_page_reader_canvas_$index'),
                        note: _notes[index],
                        pageIndex: index,
                        imageStore: _imageStore,
                        onOriginal: () => _showOriginal(index),
                      ),
                    ),
                  ),
                ),
                const SizedBox(
                  height: 82,
                  child: ColoredBox(color: NotePageTheme.card),
                ),
              ],
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _pageDrawerAnimation,
                child: RepaintBoundary(
                  child: IgnorePointer(
                    ignoring: !_pageConsoleOpen,
                    child: _PageConsole(
                      notes: _notes,
                      current: safeCurrent,
                      addingPage: _addingPage,
                      imageStore: _imageStore,
                      onSelect: _goTo,
                      onAddPage: _openAddPage,
                    ),
                  ),
                ),
                builder: (context, panel) {
                  final drawerVisible =
                      _pageConsoleOpen || _pageDrawerAnimation.value > 0;
                  return Stack(
                    children: [
                      if (drawerVisible)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _closePageConsole,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ClipRect(
                          child: SlideTransition(
                            position: _pageDrawerPosition,
                            child: panel,
                          ),
                        ),
                      ),
                      if (!drawerVisible)
                        Positioned(
                          left: 20,
                          bottom: bottomInset + 18,
                          child: _PageCounter(
                            key: const Key('page_count_indicator'),
                            current: safeCurrent + 1,
                            total: _notes.length,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Positioned(
              top: 12,
              left: 16,
              child: _ReaderActionCapsule(
                children: [
                  _ReaderIconButton(
                    key: const Key('reader_back_button'),
                    icon: Icons.arrow_back,
                    tooltip: '返回',
                    onPressed: _handleBack,
                    elevated: false,
                  ),
                  EditorToolbarAssetButton(
                    key: const Key('page_control_button'),
                    tooltip: '查看书页',
                    onPressed: _togglePageConsole,
                    assetPath: EditorToolbarAssets.bookPageA,
                    color: NotePageTheme.ink,
                    iconSize: 32,
                    buttonExtent: 52,
                  ),
                ],
              ),
            ),
            Positioned(
              top: 12,
              right: 16,
              child: _ReaderIconButton(
                key: const Key('reader_edit_button'),
                icon: Icons.edit_outlined,
                tooltip: '编辑书页',
                onPressed: _openEditor,
              ),
            ),
            if (_saving)
              Positioned(
                left: 0,
                right: 0,
                bottom: bottomInset,
                child: const _ReaderSaveNotice(),
              ),
          ],
        ),
      ),
    );
  }
}

String _noteIdentity(Note note) {
  if (note.id != null) return 'id:${note.id}';
  if (note.capturePageId != null) return 'page:${note.capturePageId}';
  if (note.captureBatchId?.isNotEmpty == true || note.captureSequence != null) {
    return 'batch:${note.captureBatchId}:${note.captureSequence}';
  }
  if (note.pageGroupId?.isNotEmpty == true || note.pageGroupIndex != null) {
    return 'group:${note.pageGroupId}:${note.pageGroupIndex}';
  }
  return 'fallback:${note.title}';
}

enum _DraftExitAction { keep, discard, save }

class _ReaderCanvas extends StatefulWidget {
  const _ReaderCanvas({
    super.key,
    required this.note,
    required this.pageIndex,
    required this.imageStore,
    required this.onOriginal,
  });

  final Note note;
  final int pageIndex;
  final PageImageAssetStore imageStore;
  final VoidCallback onOriginal;

  @override
  State<_ReaderCanvas> createState() => _ReaderCanvasState();
}

class _ReaderCanvasState extends State<_ReaderCanvas> {
  late BookPageDocument _document;
  late PageAnnotationDocument _annotations;

  @override
  void initState() {
    super.initState();
    _document = _documentFor(widget.note);
    _annotations = _annotationsFor(widget.note);
  }

  @override
  void didUpdateWidget(covariant _ReaderCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.note, widget.note)) {
      _document = _documentFor(widget.note);
      _annotations = _annotationsFor(widget.note);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ColoredBox(
        color: Colors.white,
        child: SingleChildScrollView(
          key: Key('reader_page_scroll_${widget.pageIndex}'),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '结构化书页',
                          style: TextStyle(
                            color: NotePageTheme.green.withValues(alpha: .55),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            '《${widget.note.title.isEmpty ? '未命名书页' : widget.note.title}》',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: NotePageTheme.green.withValues(alpha: .55),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(color: NotePageTheme.line),
                    const SizedBox(height: 18),
                    BookPageDocumentView(document: _document),
                    const SizedBox(height: 22),
                    const Divider(color: NotePageTheme.line),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final source = Text(
                          '来源：本次扫描${widget.note.bookPage.isEmpty ? '' : ' · 书页 ${widget.note.bookPage}'}',
                          style: const TextStyle(
                            color: NotePageTheme.muted,
                            fontSize: 12,
                          ),
                        );
                        final action = TextButton(
                          onPressed: widget.onOriginal,
                          child: const Text('原图对照｜修正识别'),
                        );
                        if (constraints.maxWidth < 520) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              source,
                              Align(
                                alignment: Alignment.centerRight,
                                child: action,
                              ),
                            ],
                          );
                        }
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [source, action],
                        );
                      },
                    ),
                  ],
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: BookPageAnnotationView(
                      document: _annotations,
                      imageStore: widget.imageStore,
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

class _PageConsole extends StatelessWidget {
  const _PageConsole({
    required this.notes,
    required this.current,
    required this.addingPage,
    required this.imageStore,
    required this.onSelect,
    required this.onAddPage,
  });

  final List<Note> notes;
  final int current;
  final bool addingPage;
  final PageImageAssetStore imageStore;
  final Future<void> Function(int index) onSelect;
  final VoidCallback onAddPage;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: ColoredBox(
        color: NotePageTheme.soft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: NotePageTheme.lineStrong,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '页面',
                          style: TextStyle(
                            color: NotePageTheme.ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '本次扫描 · 可视化控制台',
                          style: TextStyle(
                            color: NotePageTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '点击页面切换查看',
                    style: TextStyle(
                      color: NotePageTheme.inkSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 176,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  itemCount: notes.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    if (index == notes.length) {
                      return _AddPageTile(
                        loading: addingPage,
                        onPressed: onAddPage,
                      );
                    }
                    return _PageThumbnail(
                      note: notes[index],
                      index: index,
                      selected: index == current,
                      imageStore: imageStore,
                      onTap: () => onSelect(index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.note,
    required this.index,
    required this.selected,
    required this.imageStore,
    required this.onTap,
  });

  final Note note;
  final int index;
  final bool selected;
  final PageImageAssetStore imageStore;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '书页${index + 1}${selected ? '，当前页面' : ''}',
      child: GestureDetector(
        key: Key('page_thumbnail_$index'),
        onTap: onTap,
        child: SizedBox(
          width: 128,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 150,
                width: 112,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: NotePageTheme.canvas,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF1687C8)
                        : Colors.transparent,
                    width: selected ? 3 : 1,
                  ),
                  boxShadow: NotePageTheme.cardShadow,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ColoredBox(
                    color: Colors.white,
                    child: FittedBox(
                      alignment: Alignment.topCenter,
                      fit: BoxFit.fitWidth,
                      child: SizedBox(
                        width: 210,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Stack(
                            children: [
                              BookPageDocumentView(
                                compact: true,
                                document: _documentFor(note),
                              ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: BookPageAnnotationView(
                                    document: _annotationsFor(note),
                                    imageStore: imageStore,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(
                height: 19,
                child: Text(
                  '书页${index + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF1687C8)
                        : NotePageTheme.inkSecondary,
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddPageTile extends StatelessWidget {
  const _AddPageTile({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '添加书页',
      child: GestureDetector(
        key: const Key('add_book_page_tile'),
        onTap: loading ? null : onPressed,
        child: SizedBox(
          width: 128,
          child: Column(
            children: [
              Container(
                height: 150,
                width: 112,
                decoration: BoxDecoration(
                  color: NotePageTheme.canvas,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: NotePageTheme.lineStrong),
                ),
                child: Center(
                  child: loading
                      ? const Icon(
                          Icons.hourglass_top,
                          color: NotePageTheme.muted,
                        )
                      : const Icon(
                          Icons.add_a_photo_outlined,
                          color: NotePageTheme.green,
                          size: 32,
                        ),
                ),
              ),
              const SizedBox(height: 7),
              const SizedBox(
                height: 19,
                child: Text(
                  '添加书页',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: NotePageTheme.green,
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderIconButton extends StatelessWidget {
  const _ReaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.elevated = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: NotePageTheme.ink, size: 25),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minWidth: 58, minHeight: 58),
    );
    final content = elevated
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: NotePageTheme.card,
              borderRadius: BorderRadius.circular(18),
              boxShadow: BookFlowTheme.buttonShadow,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: button,
            ),
          )
        : button;
    return Semantics(button: true, label: tooltip, child: content);
  }
}

class _ReaderActionCapsule extends StatelessWidget {
  const _ReaderActionCapsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: NotePageTheme.card,
        borderRadius: BorderRadius.circular(22),
        boxShadow: BookFlowTheme.buttonShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _PageCounter extends StatelessWidget {
  const _PageCounter({super.key, required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEDEDED),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Text(
          '$current/$total',
          style: const TextStyle(
            color: NotePageTheme.inkSecondary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ReaderSaveNotice extends StatelessWidget {
  const _ReaderSaveNotice();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xF2FFFFFF),
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Center(
          child: Text(
            '正在保存书页…',
            style: TextStyle(color: NotePageTheme.inkSecondary),
          ),
        ),
      ),
    );
  }
}

BookPageDocument _documentFor(Note note) {
  final raw = note.annotationsJson;
  if (raw != null && raw.isNotEmpty) {
    try {
      final document = BookPageDocument.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (document.blocks.any(
        (block) =>
            block.text.trim().isNotEmpty || block.isTable || block.isFigure,
      )) {
        return document;
      }
    } catch (_) {
      // Fall back to the plain text block below for legacy notes.
    }
  }
  return BookPageDocument(
    blocks: [
      if (note.content.trim().isNotEmpty)
        OcrBlock(
          id: 1,
          text: note.content,
          type: 'paragraph',
          x: .08,
          y: .08,
          width: .84,
          height: .8,
        ),
    ],
    compatibilityMarkdown: note.content,
  );
}

PageAnnotationDocument _annotationsFor(Note note) {
  final raw = note.annotationsJson;
  if (raw == null || raw.trim().isEmpty) return PageAnnotationDocument();
  try {
    return PageAnnotationDocument.fromJson(jsonDecode(raw));
  } catch (_) {
    return PageAnnotationDocument();
  }
}

/// Shared conversion used by book workspaces that preview a saved structured
/// page without taking ownership of the reader's editing lifecycle.
BookPageDocument documentForBookNote(Note note) => _documentFor(note);

PageAnnotationDocument annotationsForBookNote(Note note) =>
    _annotationsFor(note);
