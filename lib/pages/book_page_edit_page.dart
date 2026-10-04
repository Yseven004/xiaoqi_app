import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import '../config/note_page_theme.dart';
import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../models/page_annotation.dart';
import '../models/page_image_editor_controller.dart';
import '../models/page_annotation_tool_controller.dart';
import '../models/reader_pagination.dart';
import '../plugins/document_recognition/markdown_blocks_codec.dart';
import '../services/database_service.dart';
import '../services/low_latency_ink_input.dart';
import '../services/page_image_asset_store.dart';
import '../widgets/app_toast.dart';
import '../features/ai_study_annotation/presentation/ai_conversation_panel.dart';
import '../features/ai_study_annotation/data/ai_annotation_screenshot_capture.dart';
import '../features/ai_study_annotation/domain/ai_annotation_source_attachment.dart';
import '../features/ai_study_annotation/domain/ai_web_source.dart';
import '../widgets/book_page_annotation_view.dart';
import '../widgets/book_page_document_content.dart';
import '../widgets/book_page_document_view.dart';
import '../widgets/editor_toolbar_asset_button.dart';
import '../widgets/book_text_selection_controls.dart';
import '../widgets/pdf_page_canvas.dart';

/// Structured book-page editor used after OCR has produced a readable page.
///
/// The editor changes the visible copy of a page and keeps the original OCR
/// blocks in [BookPageDocument.blocks]. This makes correction safe to undo or
/// compare with the source image later.
class BookPageEditPage extends StatefulWidget {
  const BookPageEditPage({
    super.key,
    required this.initialNote,
    this.initialNotes = const [],
    this.initialIndex = 0,
    this.isDraft = false,
    this.bookId,
    this.bookName,
    this.imageStore,
    this.onOriginalPage,
    this.onDraftSaved,
    this.catalogDrawerBuilder,
    this.catalogDrawerVersionListenable,
    this.pdfDocumentRef,
    this.pdfPageNumber,
    this.onPdfPageChanged,
    this.pdfPageLoader,
    this.pdfPaginationModeListenable,
  });

  final Note initialNote;
  final List<Note> initialNotes;
  final int initialIndex;
  final bool isDraft;
  final int? bookId;
  final String? bookName;
  final PageImageAssetStore? imageStore;
  final Future<void> Function(int pageIndex)? onOriginalPage;
  /// Called after a draft save queue completes. Structured source editors use
  /// this to persist the document revision while the route is still open.
  final Future<void> Function(List<Note> notes)? onDraftSaved;
  final Widget Function(
    VoidCallback onClose,
    ValueChanged<int> onSelectPage,
    VoidCallback onFinishEditor,
  )? catalogDrawerBuilder;
  final ValueListenable<int>? catalogDrawerVersionListenable;
  final PdfDocumentRef? pdfDocumentRef;
  final int? pdfPageNumber;
  final ValueChanged<int>? onPdfPageChanged;
  final Future<Note?> Function(int pageNumber)? pdfPageLoader;
  final ValueListenable<ReaderPaginationMode>? pdfPaginationModeListenable;

  @override
  State<BookPageEditPage> createState() => _BookPageEditPageState();
}

enum _EditorSaveState { saved, saving, failed }

enum _AiMenuChoice { conversation, independentNote, annotationNote }

enum _EditorChangeKind { insert, delete, replace, mixed }

class _EditorSnapshot {
  const _EditorSnapshot(
    this.title,
    this.body,
    this.annotations,
    this.blockTexts,
  );

  final String title;
  final String body;
  final PageAnnotationDocument annotations;
  final Map<int, String> blockTexts;

  bool sameAs(_EditorSnapshot other) =>
      title == other.title &&
      body == other.body &&
      _sameBlockTexts(blockTexts, other.blockTexts) &&
      (identical(annotations, other.annotations) ||
          annotations == other.annotations);
}

bool _sameBlockTexts(Map<int, String> a, Map<int, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

class _BookPageDraft {
  _BookPageDraft(this.note)
    : document = BookPageDocumentContent.documentFor(note),
      annotations = _annotationsFor(note),
      titleController = TextEditingController(),
      bodyController = TextEditingController(),
      scrollController = ScrollController() {
    final visibleBlocks = document.renderBlocks;
    OcrBlock? titleBlock;
    for (final block in visibleBlocks) {
      if (block.isTitle) {
        titleBlock = block;
        break;
      }
    }
    titleController.text = titleBlock?.text.trim() ?? note.title.trim();
    bodyController.text = visibleBlocks
        .where(
          (block) =>
              !block.isFurniture &&
              !block.isTitle &&
              !block.isTable &&
              !block.isFigure,
        )
        .map((block) {
          final text = block.readableText.trim();
          if (text.isEmpty) return '';
          return block.firstLineIndent > 0 ? '　　$text' : text;
        })
        .where((text) => text.trim().isNotEmpty)
        .join('\n\n');
    for (final block in visibleBlocks) {
      if (block.isTitle ||
          block.isFurniture ||
          block.isTable ||
          block.isFigure) {
        continue;
      }
      blockControllers[block.id] = TextEditingController(text: block.text);
    }
  }

  Note note;
  BookPageDocument document;
  PageAnnotationDocument annotations;
  final TextEditingController titleController;
  final TextEditingController bodyController;
  final ScrollController scrollController;
  final Map<int, TextEditingController> blockControllers = {};
  int revision = 0;
  int persistedRevision = 0;

  bool get hasUnsupportedLayout =>
      document.renderBlocks.any((block) => block.isTable || block.isFigure);

  /// 一页里允许立即创建真实输入框的可编辑块上限。
  ///
  /// 2026-09-14 的卡顿事故里，一份被写坏的 DOCX 派生文档把 6,013 个块塞进一章，
  /// 编辑页会在同一帧创建 6,013 个 TextField 并让 Android 主线程超时（ANR）。
  /// 正常资料远低于这个上限，因此行为完全不变；超出的块先渲染成同样的文本，
  /// 点一下再变成输入框。
  static const int liveTextFieldBudget = 160;

  /// 需要立即创建输入框的块 id。
  late final Set<int> liveEditableBlockIds = _computeLiveEditableBlockIds();

  /// 本页可编辑（非标题、非图表、非表格）的块总数。
  late final int editableBlockCount = _countEditableBlocks();

  int _countEditableBlocks() {
    var count = 0;
    for (final block in document.renderBlocks) {
      if (block.isTitle ||
          block.isFurniture ||
          block.isTable ||
          block.isFigure) {
        continue;
      }
      count++;
    }
    return count;
  }

  Set<int> _computeLiveEditableBlockIds() {
    final ids = <int>{};
    for (final block in document.renderBlocks) {
      if (block.isTitle ||
          block.isFurniture ||
          block.isTable ||
          block.isFigure) {
        continue;
      }
      ids.add(block.id);
      if (ids.length >= liveTextFieldBudget) break;
    }
    return ids;
  }

  BookPageDocument draftDocument() {
    if (!hasUnsupportedLayout) return document;
    final editedBlocks = [
      for (final block in document.renderBlocks)
        block.isTitle
            ? block.copyWith(text: titleController.text)
            : blockControllers[block.id] == null
            ? block
            : block.copyWith(text: blockControllers[block.id]!.text),
    ];
    return document.copyWith(
      editedBlocks: List.unmodifiable(editedBlocks),
      compatibilityMarkdown: editedBlocks
          .map((block) => block.readableText.trim())
          .where((text) => text.isNotEmpty)
          .join('\n\n'),
    );
  }

  String draftBodyText() => document.renderBlocks
      .where(
        (block) =>
            !block.isFurniture &&
            !block.isTitle &&
            !block.isTable &&
            !block.isFigure,
      )
      .map((block) => blockControllers[block.id]?.text ?? block.text)
      .where((text) => text.trim().isNotEmpty)
      .join('\n\n');

  void dispose() {
    titleController.dispose();
    bodyController.dispose();
    scrollController.dispose();
    for (final controller in blockControllers.values) {
      controller.dispose();
    }
  }

  void replaceNote(Note next) {
    note = next;
    document = BookPageDocumentContent.documentFor(next);
    annotations = _annotationsFor(next);
    titleController.text =
        document.renderBlocks
            .where((block) => block.isTitle)
            .firstOrNull
            ?.text
            .trim() ??
        next.title.trim();
    bodyController.text = document.renderBlocks
        .where(
          (block) =>
              !block.isFurniture &&
              !block.isTitle &&
              !block.isTable &&
              !block.isFigure,
        )
        .map((block) => block.readableText.trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    for (final controller in blockControllers.values) {
      controller.dispose();
    }
    blockControllers.clear();
    for (final block in document.renderBlocks) {
      if (block.isTitle ||
          block.isFurniture ||
          block.isTable ||
          block.isFigure) {
        continue;
      }
      blockControllers[block.id] = TextEditingController(text: block.text);
    }
    revision = 0;
    persistedRevision = 0;
  }
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

/// PDF pages are identified by their physical position in the source file.
///
/// OCR may also find a printed page number, but that number is not a stable
/// identity for a PDF page. Keeping it in BookPageDocument.pageNumber made the
/// viewer reuse one page's overlay when the physical viewer page changed.
Note _normalizePdfNoteForPage(Note note, int physicalPageNumber) {
  if (note.pdfPath.trim().isEmpty || physicalPageNumber < 1) return note;
  final document = BookPageDocumentContent.documentFor(note);
  final normalized = document.copyWith(
    pageNumber: physicalPageNumber.toString(),
  );
  final documentJson = <String, dynamic>{...normalized.toJson()};
  final raw = note.annotationsJson;
  if (raw != null && raw.trim().isNotEmpty) {
    try {
      final rawJson = jsonDecode(raw);
      if (rawJson is Map) {
        for (final key in const [
          'annotations',
          'annotation_schema_version',
          'annotation_coordinate_space',
        ]) {
          if (rawJson.containsKey(key)) documentJson[key] = rawJson[key];
        }
      }
    } catch (_) {
      // The normalized document remains a readable fallback for legacy data.
    }
  }
  return note.copyWith(
    bookPage: physicalPageNumber.toString(),
    annotationsJson: jsonEncode(documentJson),
  );
}

/// OCR loading may replace a pending page note with a fresh text-layer note.
/// Keep the annotations that were already created for that physical PDF page
/// when that replacement happens.
Note _mergePdfPageAnnotations(Note loaded, Note cached) {
  final raw = cached.annotationsJson;
  if (raw == null || raw.trim().isEmpty) return loaded;
  try {
    final rawJson = jsonDecode(raw);
    if (rawJson is! Map) return loaded;
    final documentJson = <String, dynamic>{
      ...BookPageDocumentContent.documentFor(loaded).toJson(),
    };
    for (final key in const [
      'annotations',
      'annotation_schema_version',
      'annotation_coordinate_space',
    ]) {
      if (rawJson.containsKey(key)) documentJson[key] = rawJson[key];
    }
    return loaded.copyWith(annotationsJson: jsonEncode(documentJson));
  } catch (_) {
    return loaded;
  }
}

class _BookPageEditPageState extends State<BookPageEditPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _caretKeyboardGap = 24.0;
  static const _historyGroupWindow = Duration(milliseconds: 400);
  static const _maxUndoSnapshots = 200;

  final _db = DatabaseService();
  late final List<_BookPageDraft> _pages;
  late final List<GlobalKey> _canvasKeys;
  late final List<GlobalKey> _pageContentKeys;
  late final List<GlobalKey> _bodyFieldKeys;
  late final List<GlobalKey> _annotationLayerKeys;
  late final PageController _pageController;
  PdfViewerController? _pdfViewerController;
  late final AnimationController _consoleController;
  late final CurvedAnimation _consoleAnimation;
  late final Animation<Offset> _consolePosition;

  int _current = 0;
  int _pdfPageNumber = 1;
  int? _pdfAnnotationPageNumber;
  int _pdfPageCount = 1;
  int? _focusedPdfPageNumber;
  PdfRect? _focusedPdfPageRect;
  bool _consoleOpen = false;
  bool _allowPop = false;
  bool _finishInProgress = false;
  bool _saveAgain = false;
  bool _restoring = false;
  bool _hasUnsavedChanges = false;
  bool _saveError = false;
  bool _selectionHandlePrecached = false;
  bool _keyboardScrollScheduled = false;
  bool _allowKeyboardScrollDecrease = false;
  ui.FlutterView? _view;
  double _keyboardInset = 0;
  double? _keyboardBaseScrollOffset;
  ScrollController? _keyboardScrollController;
  final ValueNotifier<double> _keyboardInsetListenable = ValueNotifier(0);
  final ValueNotifier<bool> _drawingToolbarVisibleListenable = ValueNotifier(
    false,
  );
  final ValueNotifier<bool> _catalogOpenListenable = ValueNotifier(false);
  final ValueNotifier<int?> _activePdfTextBlockIdListenable = ValueNotifier(
    null,
  );
  Timer? _pdfTextFocusTimeout;
  final ValueNotifier<({int current, int? total})> _pdfPageStateListenable =
      ValueNotifier((current: 1, total: null));
  Offset? _pdfInteractionStart;
  int? _pdfInteractionStartPage;
  bool _pdfSnapScheduled = false;
  int _pdfPageLoadToken = 0;
  final _pdfPageNoteCache = <int, Note>{};
  final _pdfPageLoadFutures = <int, Future<Note?>>{};
  final _annotationTools = PageAnnotationToolController();
  late final PageImageAssetStore _imageStore;
  late final AiAnnotationScreenshotCapture _laserScreenshotCapture;
  AiAnnotationAttachmentTrayState _laserTrayState =
      AiAnnotationAttachmentTrayState();
  bool _catalogOpen = false;
  bool _laserPanelOpen = false;
  final _imageEditor = PageImageEditorController();
  bool _imageImportInProgress = false;
  final _managedImageAssets = <String>{};
  bool _drawingEditorActive = false;
  bool _drawingToolbarVisible = false;
  bool? _pointerResamplingBeforeDrawing;
  _EditorSaveState _saveState = _EditorSaveState.saved;
  Future<void>? _saveFuture;
  Timer? _saveTimer;
  final _undoStack = <_EditorSnapshot>[];
  final _redoStack = <_EditorSnapshot>[];
  late _EditorSnapshot _lastObserved;
  DateTime? _lastHistoryEditAt;
  int? _lastHistoryField;
  _EditorChangeKind? _lastHistoryKind;
  DateTime? _lastAnnotationHistoryAt;

  _BookPageDraft get _page => _pages[_current];

  /// 被用户点开的只读块：页序号 → 块 id。它只影响渲染方式，不参与保存。
  final Map<int, Set<int>> _promotedEditableBlocks = <int, Set<int>>{};
  int? _pendingEditableFocusBlockId;

  Set<int> _liveEditableBlockIds(int index) {
    final budget = _pages[index].liveEditableBlockIds;
    final promoted = _promotedEditableBlocks[index];
    if (promoted == null || promoted.isEmpty) return budget;
    return {...budget, ...promoted};
  }

  void _promoteEditableBlock(int index, int blockId) {
    final promoted = _promotedEditableBlocks.putIfAbsent(index, () => <int>{});
    if (promoted.contains(blockId)) return;
    setState(() {
      promoted.add(blockId);
      _pendingEditableFocusBlockId = blockId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingEditableFocusBlockId != blockId) return;
      setState(() => _pendingEditableFocusBlockId = null);
    });
  }

  @override
  void initState() {
    super.initState();
    _imageStore = widget.imageStore ?? PageImageAssetStore();
    _laserScreenshotCapture = AiAnnotationScreenshotCapture(_imageStore);
    // Flutter's baseline debug paint is process-global. If it was enabled by
    // the inspector while this editable route is open, it draws yellow lines
    // below every text render object, including page thumbnails. The editor
    // must never present that diagnostic layer as product UI.
    assert(() {
      debugPaintBaselinesEnabled = false;
      return true;
    }());
    final rawNotes = widget.initialNotes.isEmpty
        ? [widget.initialNote]
        : widget.initialNotes;
    _pdfPageNumber =
        (widget.pdfPageNumber ?? int.tryParse(widget.initialNote.bookPage) ?? 1)
            .clamp(1, 999999)
            .toInt();
    final notes = widget.pdfDocumentRef == null
        ? rawNotes
        : [
            for (final note in rawNotes)
              _normalizePdfNoteForPage(note, _pdfPageNumber),
          ];
    _pages = [for (final note in notes) _BookPageDraft(note)];
    _pdfAnnotationPageNumber =
        widget.pdfDocumentRef == null ? null : _pdfPageNumber;
    _pdfPageStateListenable.value = (current: _pdfPageNumber, total: null);
    if (widget.pdfDocumentRef != null) {
      _pdfViewerController = PdfViewerController();
      _pdfPageNoteCache[_pdfPageNumber] = _pages.first.note;
    }
    _canvasKeys = List<GlobalKey>.generate(_pages.length, (_) => GlobalKey());
    _pageContentKeys = List<GlobalKey>.generate(
      _pages.length,
      (_) => GlobalKey(),
    );
    _bodyFieldKeys = List<GlobalKey>.generate(
      _pages.length,
      (_) => GlobalKey(),
    );
    _annotationLayerKeys = List<GlobalKey>.generate(
      _pages.length,
      (_) => GlobalKey(),
    );
    _current = widget.initialIndex.clamp(0, _pages.length - 1);
    _pageController = PageController(initialPage: _current);
    _consoleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _consoleAnimation = CurvedAnimation(
      parent: _consoleController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _consolePosition = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(_consoleAnimation);
    for (final page in _pages) {
      page.titleController.addListener(_onDraftChanged);
      page.bodyController.addListener(_onDraftChanged);
      for (final controller in page.blockControllers.values) {
        controller.addListener(_onDraftChanged);
      }
    }
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onPrimaryFocusChanged);
    _annotationTools.addListener(_onAnnotationToolChanged);
    _imageEditor.addListener(_onImageEditorChanged);
    _activePdfTextBlockIdListenable.addListener(_onActivePdfTextBlockChanged);
    widget.pdfPaginationModeListenable?.addListener(
      _onPdfPaginationModeChanged,
    );
    _resetHistory();
  }

  @override
  void dispose() {
    _setDrawingPointerResampling(false);
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_onPrimaryFocusChanged);
    _annotationTools.removeListener(_onAnnotationToolChanged);
    widget.pdfPaginationModeListenable?.removeListener(
      _onPdfPaginationModeChanged,
    );
    _annotationTools.dispose();
    _imageEditor.removeListener(_onImageEditorChanged);
    _activePdfTextBlockIdListenable.removeListener(
      _onActivePdfTextBlockChanged,
    );
    _imageEditor.dispose();
    _saveTimer?.cancel();
    _pdfTextFocusTimeout?.cancel();
    _keyboardInsetListenable.dispose();
    _drawingToolbarVisibleListenable.dispose();
    _catalogOpenListenable.dispose();
    _activePdfTextBlockIdListenable.dispose();
    _pdfPageStateListenable.dispose();
    _consoleAnimation.dispose();
    _consoleController.dispose();
    _pageController.dispose();
    for (final page in _pages) {
      page.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    if (_selectionHandlePrecached) return;
    _selectionHandlePrecached = true;
    unawaited(
      precacheImage(
        const AssetImage(BookPencilTextSelectionControls.assetPath),
        context,
      ),
    );
  }

  void _resetHistory() {
    _undoStack.clear();
    _redoStack.clear();
    _lastObserved = _snapshotFor(_page);
    _lastHistoryEditAt = null;
    _lastHistoryField = null;
    _lastHistoryKind = null;
    _lastAnnotationHistoryAt = null;
  }

  void _resetHistoryGrouping() {
    _lastHistoryEditAt = null;
    _lastHistoryField = null;
    _lastHistoryKind = null;
  }

  ({int field, _EditorChangeKind kind, int magnitude}) _classifyChange(
    _EditorSnapshot before,
    _EditorSnapshot after,
  ) {
    final titleChanged = before.title != after.title;
    final bodyChanged = before.body != after.body;
    if (titleChanged == bodyChanged) {
      return (field: 2, kind: _EditorChangeKind.mixed, magnitude: 0);
    }
    final beforeText = titleChanged ? before.title : before.body;
    final afterText = titleChanged ? after.title : after.body;
    final delta = afterText.length - beforeText.length;
    final kind = delta > 0
        ? _EditorChangeKind.insert
        : delta < 0
        ? _EditorChangeKind.delete
        : _EditorChangeKind.replace;
    return (field: titleChanged ? 0 : 1, kind: kind, magnitude: delta.abs());
  }

  void _recordUndoBoundary(
    _EditorSnapshot before,
    ({int field, _EditorChangeKind kind, int magnitude}) change,
  ) {
    final now = DateTime.now();
    final previousAt = _lastHistoryEditAt;
    final continuesGroup =
        previousAt != null &&
        now.difference(previousAt) <= _historyGroupWindow &&
        _lastHistoryField == change.field &&
        _lastHistoryKind == change.kind &&
        change.magnitude <= 1;
    if (!continuesGroup) {
      _undoStack.add(before);
      if (_undoStack.length > _maxUndoSnapshots) {
        _undoStack.removeAt(0);
      }
    }
    _lastHistoryEditAt = now;
    _lastHistoryField = change.field;
    _lastHistoryKind = change.kind;
  }

  _EditorSnapshot _snapshotFor(_BookPageDraft page) {
    return _EditorSnapshot(
      page.titleController.text,
      page.hasUnsupportedLayout
          ? page.draftBodyText()
          : page.bodyController.text,
      page.annotations,
      Map.unmodifiable({
        for (final entry in page.blockControllers.entries)
          entry.key: entry.value.text,
      }),
    );
  }

  void _onAnnotationToolChanged() {
    if (!_annotationTools.isBrowseMode) _imageEditor.lockSelection();
    if (_annotationTools.activeTool == DrawingTool.laser) {
      _setNativeInkInput(false);
    }
    if (mounted) setState(() {});
  }

  void _onImageEditorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    final view = _view;
    if (!mounted || view == null) return;
    _updateKeyboardInset(view.viewInsets.bottom / view.devicePixelRatio);
  }

  void _onPrimaryFocusChanged() {
    if (mounted) setState(() {});
    if (_isPdfEditor &&
        _activePdfTextBlockIdListenable.value != null &&
        _keyboardInset <= 0 &&
        _focusedEditor() == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _keyboardInset > 0 ||
            _activePdfTextBlockIdListenable.value == null ||
            _focusedEditor() != null) {
          return;
        }
        _activePdfTextBlockIdListenable.value = null;
      });
    }
    if (_keyboardInset <= 0) return;
    if (_pageInputLocked) return;
    if (_isPdfEditor) {
      _schedulePdfKeyboardReveal();
      return;
    }
    _scheduleKeyboardScroll();
  }

  bool get _pageInputLocked =>
      _imageEditor.isEditing ||
      (_drawingEditorActive && !_annotationTools.isBrowseMode);

  bool get _isPdfEditor =>
      widget.pdfDocumentRef != null && _pdfViewerController != null;

  bool get _horizontalPdfPaging =>
      widget.pdfPaginationModeListenable?.value ==
          ReaderPaginationMode.horizontal ||
      widget.pdfPaginationModeListenable == null;

  void _onPdfPaginationModeChanged() {
    if (!mounted || !_isPdfEditor) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _pdfViewerController;
      if (!mounted || controller == null || !controller.isReady) return;
      controller.invalidate();
      unawaited(_goToPdfPage(_pdfPageNumber, duration: Duration.zero));
    });
  }

  void _onActivePdfTextBlockChanged() {
    if (!mounted) return;
    _pdfTextFocusTimeout?.cancel();
    if (_activePdfTextBlockIdListenable.value != null) {
      _pdfTextFocusTimeout = Timer(const Duration(milliseconds: 900), () {
        if (!mounted || _activePdfTextBlockIdListenable.value == null) return;
        if (_focusedEditor() == null || _keyboardInset <= 0) {
          _activePdfTextBlockIdListenable.value = null;
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pdfViewerController?.invalidate();
    });
  }

  EditableTextState? _focusedEditor() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editableState = focusContext
        ?.findAncestorStateOfType<EditableTextState>();
    if (editableState == null) return null;
    final controller = editableState.widget.controller;
    for (final page in _pages) {
      if (identical(controller, page.titleController) ||
          identical(controller, page.bodyController) ||
          page.blockControllers.values.any(
            (item) => identical(item, controller),
          )) {
        return editableState;
      }
    }
    return null;
  }

  void _updateKeyboardInset(double nextInset) {
    final normalizedInset = nextInset <= 0.5 ? 0.0 : nextInset;
    final previousInset = _keyboardInset;
    if ((normalizedInset - previousInset).abs() < 0.25) return;

    if (_isPdfEditor) {
      _keyboardInset = normalizedInset;
      _keyboardInsetListenable.value = normalizedInset;
      if (normalizedInset > 0) _schedulePdfKeyboardReveal();
      if (normalizedInset == 0 &&
          previousInset > 0 &&
          _activePdfTextBlockIdListenable.value != null) {
        _activePdfTextBlockIdListenable.value = null;
      }
      return;
    }

    if (normalizedInset > 0 && _keyboardBaseScrollOffset == null) {
      final controller = _page.scrollController;
      if (controller.hasClients) {
        _keyboardScrollController = controller;
        _keyboardBaseScrollOffset = controller.offset;
      }
    }

    _keyboardInset = normalizedInset;
    _keyboardInsetListenable.value = normalizedInset;

    if (normalizedInset == 0) {
      final controller = _keyboardScrollController;
      final baseOffset = _keyboardBaseScrollOffset;
      if (controller != null && baseOffset != null && controller.hasClients) {
        controller.jumpTo(
          baseOffset
              .clamp(
                controller.position.minScrollExtent,
                controller.position.maxScrollExtent,
              )
              .toDouble(),
        );
      }
      _keyboardScrollController = null;
      _keyboardBaseScrollOffset = null;
      return;
    }

    // The notifier moves the accessory bar and reserves the matching editor
    // space immediately. Scroll correction is coalesced to one post-frame
    // pass so the IME never waits on an arbitrary debounce timer.
    _scheduleKeyboardScroll(allowDecrease: normalizedInset < previousInset);
  }

  void _onPdfTextFocus(int pageNumber, PdfRect pageRect) {
    _focusedPdfPageNumber = pageNumber;
    _focusedPdfPageRect = pageRect;
    if (_keyboardInset > 0) _schedulePdfKeyboardReveal();
  }

  void _onPdfInteractionStart(ScaleStartDetails details) {
    if (!_horizontalPdfPaging || _pageInputLocked) {
      return;
    }
    final controller = _pdfViewerController;
    if (controller == null || !controller.isReady) return;
    _pdfInteractionStart = controller.centerPosition;
    _pdfInteractionStartPage = controller.pageNumber ?? _pdfPageNumber;
  }

  void _onPdfInteractionEnd(ScaleEndDetails details) {
    if (!_horizontalPdfPaging || _pageInputLocked || _pdfSnapScheduled) {
      return;
    }
    _pdfSnapScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pdfSnapScheduled = false;
      await _snapPdfPage(details);
    });
  }

  Future<void> _snapPdfPage(ScaleEndDetails details) async {
    final controller = _pdfViewerController;
    final start = _pdfInteractionStart;
    final startPage = _pdfInteractionStartPage;
    if (controller == null ||
        !controller.isReady ||
        start == null ||
        startPage == null ||
        controller.currentZoom >
            _pdfPageWidthZoom(controller, startPage) * 1.05) {
      return;
    }
    final delta = controller.centerPosition.dx - start.dx;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final threshold = math.max(48.0, controller.viewSize.width * .16);
    var target = startPage;
    if (velocity.abs() >= 650 || delta.abs() >= threshold) {
      final forward = velocity < -650 || delta > 0;
      target = startPage + (forward ? 1 : -1);
    }
    target = target.clamp(1, controller.layout.pageLayouts.length).toInt();
    await _goToPdfPage(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
    );
    if (target != _activePdfDocumentPage) {
      _dismissKeyboard();
      await _activatePdfPage(target);
    }
  }

  double _pdfPageWidthZoom(PdfViewerController controller, int pageNumber) {
    final layouts = controller.layout.pageLayouts;
    final index = pageNumber.clamp(1, layouts.length).toInt() - 1;
    final width = layouts[index].width;
    return width <= 0
        ? controller.currentZoom
        : controller.viewSize.width / width;
  }

  Future<void> _goToPdfPage(
    int pageNumber, {
    Duration duration = const Duration(milliseconds: 220),
  }) async {
    final controller = _pdfViewerController;
    if (controller == null || !controller.isReady) return;
    final safePage = pageNumber
        .clamp(1, controller.layout.pageLayouts.length)
        .toInt();
    final pageRect = controller.layout.pageLayouts[safePage - 1];
    final zoom = _horizontalPdfPaging
        ? _pdfPageWidthZoom(controller, safePage)
        : controller.alternativeFitScale ?? controller.currentZoom;
    final matrix = controller.calcMatrixFor(
      pageRect.center,
      zoom: zoom,
      viewSize: controller.viewSize,
    );
    await controller.goTo(
      matrix,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : duration,
    );
  }

  void _schedulePdfOverlayRefresh(PdfViewerController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(_pdfViewerController, controller) ||
          !controller.isReady) {
        return;
      }
      controller.invalidate();
    });
  }

  void _schedulePdfKeyboardReveal() {
    if (_keyboardScrollScheduled) return;
    _keyboardScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardScrollScheduled = false;
      if (!mounted || !_isPdfEditor || _keyboardInset <= 0) return;
      final pageNumber = _focusedPdfPageNumber;
      final pageRect = _focusedPdfPageRect;
      final controller = _pdfViewerController;
      if (pageNumber == null || pageRect == null || controller == null) return;
      if (!controller.isReady || pageNumber > controller.pageCount) return;
      try {
        final documentRect = controller.calcRectForRectInsidePage(
          pageNumber: pageNumber,
          rect: pageRect.inflate(6, 6),
        );
        final safeHeight = math
            .max(
              1,
              controller.viewSize.height - _keyboardInset - _caretKeyboardGap,
            )
            .toDouble();
        final matrix = controller.calcMatrixFor(
          documentRect.center,
          zoom: controller.currentZoom,
          viewSize: Size(controller.viewSize.width, safeHeight),
        );
        unawaited(
          // Keep caret reveals out of the scroll animation queue; text input
          // can emit several changes per frame while the IME is open.
          controller.goTo(matrix, duration: Duration.zero),
        );
      } catch (_) {
        // The first IME frame can arrive before pdfrx has published its layout.
      }
    });
  }

  void _scheduleKeyboardScroll({bool allowDecrease = false}) {
    _allowKeyboardScrollDecrease |= allowDecrease;
    _queueKeyboardScroll();
  }

  void _queueKeyboardScroll() {
    if (_keyboardScrollScheduled) return;
    _keyboardScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardScrollScheduled = false;
      if (!mounted || _keyboardInset <= 0) return;
      final canDecrease = _allowKeyboardScrollDecrease;
      _allowKeyboardScrollDecrease = false;
      _syncKeyboardScroll(_keyboardInset, allowDecrease: canDecrease);
    });
  }

  void _syncKeyboardScroll(double inset, {required bool allowDecrease}) {
    if (_pageInputLocked) return;
    final controller = _keyboardScrollController;
    final baseOffset = _keyboardBaseScrollOffset;
    if (controller == null ||
        baseOffset == null ||
        !controller.hasClients ||
        inset <= 0) {
      return;
    }

    final editableState = _focusedEditor();
    if (editableState == null) return;
    final selection = editableState.widget.controller.selection;
    if (!selection.isValid) return;

    final renderEditable = editableState.renderEditable;
    if (!renderEditable.attached || !renderEditable.hasSize) return;
    final caretRect = renderEditable.getLocalRectForCaret(selection.extent);
    final caretBottom = renderEditable.localToGlobal(caretRect.bottomLeft).dy;
    final view = _view;
    if (view == null) return;
    final logicalHeight = view.physicalSize.height / view.devicePixelRatio;
    final keyboardTop = logicalHeight - inset;

    // Reconstruct the caret position at the pre-keyboard scroll offset. The
    // target is absolute, so repeated platform inset frames cannot accumulate
    // rounding error or make the text wobble.
    final baselineCaretBottom = caretBottom + (controller.offset - baseOffset);
    final requiredLift = (baselineCaretBottom + _caretKeyboardGap - keyboardTop)
        .clamp(0.0, double.infinity)
        .toDouble();
    var target = (baseOffset + requiredLift)
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    if (!allowDecrease && target < controller.offset) {
      target = controller.offset;
    }
    if ((target - controller.offset).abs() >= 0.25) {
      controller.jumpTo(target);
    }
  }

  void _onDraftChanged() {
    if (_restoring || _pages.isEmpty) return;
    final current = _snapshotFor(_page);
    // TextEditingController also notifies when only its selection changes.
    // Returning here keeps handle dragging out of the page-wide autosave,
    // history and setState path; only the field and isolated selection layer
    // repaint while the finger moves.
    if (_lastObserved.sameAs(current)) {
      if (_keyboardInset > 0) {
        if (_isPdfEditor) {
          _schedulePdfKeyboardReveal();
        } else {
          _scheduleKeyboardScroll();
        }
      }
      return;
    }
    final change = _classifyChange(_lastObserved, current);
    // Deletion moves the caret upward, so the existing keyboard lift remains
    // safe. Skipping caret geometry here keeps Backspace repeat off the
    // post-frame scroll path; insertion/replacement can move the caret down.
    if (_keyboardInset > 0 && change.kind != _EditorChangeKind.delete) {
      if (_isPdfEditor) {
        _schedulePdfKeyboardReveal();
      } else {
        _scheduleKeyboardScroll();
      }
    }
    _recordUndoBoundary(_lastObserved, change);
    _lastAnnotationHistoryAt = null;
    _redoStack.clear();
    _lastObserved = current;
    _page.revision++;
    final shouldRefreshSaveState =
        !_hasUnsavedChanges ||
        _saveError ||
        _saveState != _EditorSaveState.saving;
    _hasUnsavedChanges = true;
    _saveError = false;
    if (mounted && shouldRefreshSaveState) {
      setState(() => _saveState = _EditorSaveState.saving);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 650), () {
      unawaited(_saveDirty());
    });
  }

  void _applySnapshot(_EditorSnapshot snapshot) {
    _resetHistoryGrouping();
    _restoring = true;
    _page.titleController.value = TextEditingValue(
      text: snapshot.title,
      selection: TextSelection.collapsed(offset: snapshot.title.length),
    );
    _page.bodyController.value = TextEditingValue(
      text: snapshot.body,
      selection: TextSelection.collapsed(offset: snapshot.body.length),
    );
    for (final entry in snapshot.blockTexts.entries) {
      final controller = _page.blockControllers[entry.key];
      if (controller == null || controller.text == entry.value) continue;
      controller.value = TextEditingValue(
        text: entry.value,
        selection: TextSelection.collapsed(offset: entry.value.length),
      );
    }
    _page.annotations = snapshot.annotations;
    _restoring = false;
    _lastAnnotationHistoryAt = null;
    _lastObserved = snapshot;
    _page.revision++;
    _hasUnsavedChanges = true;
    if (mounted) setState(() => _saveState = _EditorSaveState.saving);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 650), () {
      unawaited(_saveDirty());
    });
  }

  void _recordAnnotationChange(PageAnnotationDocument before) {
    final previous = _EditorSnapshot(
      _page.titleController.text,
      _page.hasUnsupportedLayout
          ? _page.draftBodyText()
          : _page.bodyController.text,
      before,
      Map.unmodifiable({
        for (final entry in _page.blockControllers.entries)
          entry.key: entry.value.text,
      }),
    );
    final current = _snapshotFor(_page);
    if (previous.sameAs(current)) return;
    _lastHistoryEditAt = null;
    _lastHistoryField = null;
    _lastHistoryKind = null;
    final now = DateTime.now();
    final continuesGroup =
        _lastAnnotationHistoryAt != null &&
        now.difference(_lastAnnotationHistoryAt!) <= _historyGroupWindow;
    if (!continuesGroup) {
      _undoStack.add(previous);
      if (_undoStack.length > _maxUndoSnapshots) _undoStack.removeAt(0);
    }
    _lastAnnotationHistoryAt = now;
    _redoStack.clear();
    _lastObserved = current;
    _page.revision++;
    final shouldRefreshSaveState =
        !_hasUnsavedChanges ||
        _saveError ||
        _saveState != _EditorSaveState.saving;
    _hasUnsavedChanges = true;
    _saveError = false;
    if (mounted) {
      // Annotation changes must rebuild the canvas immediately. Waiting for
      // the debounce save lets a PDF overlay rebuild with the previous
      // document and makes a just-committed permanent stroke vanish.
      setState(() {
        if (shouldRefreshSaveState) {
          _saveState = _EditorSaveState.saving;
        }
      });
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 650), () {
      unawaited(_saveDirty());
    });
  }

  void _undo() {
    _dismissKeyboard();
    if (_undoStack.isEmpty) return;
    _resetHistoryGrouping();
    final current = _snapshotFor(_page);
    _redoStack.add(current);
    _applySnapshot(_undoStack.removeLast());
  }

  void _redo() {
    _dismissKeyboard();
    if (_redoStack.isEmpty) return;
    _resetHistoryGrouping();
    final current = _snapshotFor(_page);
    _undoStack.add(current);
    _applySnapshot(_redoStack.removeLast());
  }

  Future<void> _selectPage(int index) async {
    if (_pageInputLocked) return;
    _imageEditor.clearSelection();
    _dismissKeyboard();
    if (_isPdfEditor) {
      await _activatePdfPage(index, moveViewer: true, showUnavailable: true);
      return;
    }
    if (index < 0 || index >= _pages.length || index == _current) return;
    await _saveDirty();
    final distance = (index - _current).abs();
    if (distance == 1) {
      await _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(index);
    }
    if (!mounted) return;
    setState(() {
      _current = index;
      _resetHistory();
      _laserTrayState = AiAnnotationAttachmentTrayState();
      _laserPanelOpen = false;
    });
  }

  int? get _activePdfDocumentPage =>
      int.tryParse(_page.document.pageNumber ?? _page.note.bookPage);

  Future<void> _activatePdfPage(
    int pageNumber, {
    bool moveViewer = false,
    bool showUnavailable = false,
  }) async {
    final controller = _pdfViewerController;
    if (!_isPdfEditor || controller == null || pageNumber < 1) return;
    final pageCount = controller.isReady ? controller.pageCount : pageNumber;
    if (pageNumber > pageCount) return;
    _imageEditor.clearSelection();
    final request = ++_pdfPageLoadToken;
    _activePdfTextBlockIdListenable.value = null;
    final previousPage = _activePdfDocumentPage;
    if (!moveViewer && _activePdfDocumentPage == pageNumber) {
      void restoreActivePage() {
        _pdfPageNumber = pageNumber;
        _pdfAnnotationPageNumber = pageNumber;
      }
      if (mounted) {
        setState(restoreActivePage);
      } else {
        restoreActivePage();
      }
      _schedulePdfOverlayRefresh(controller);
      _pdfPageStateListenable.value = (
        current: pageNumber,
        total: _pdfPageCount,
      );
      widget.onPdfPageChanged?.call(pageNumber);
      return;
    }

    void clearActiveOverlay() {
      _pdfPageNumber = pageNumber;
      _pdfAnnotationPageNumber = null;
    }
    if (mounted) {
      setState(clearActiveOverlay);
    } else {
      clearActiveOverlay();
    }
    await _saveDirty();
    if (!mounted || request != _pdfPageLoadToken) return;
    if (_saveError || _hasUnsavedChanges) {
      if (previousPage != null) {
        await _goToPdfPage(previousPage, duration: Duration.zero);
      }
      if (mounted && request == _pdfPageLoadToken) {
        setState(() {
          _pdfPageNumber = previousPage ?? pageNumber;
          _pdfAnnotationPageNumber = previousPage;
        });
        _schedulePdfOverlayRefresh(controller);
      }
      AppToast.show(context, '当前页保存失败，暂不切换 PDF 页');
      return;
    }
    if (previousPage != null) {
      // The persisted note can lag behind the in-memory annotation document
      // while the debounce save is running. Cache the materialized snapshot
      // so leaving and returning to a PDF page cannot drop a fresh stroke.
      _cachePdfPageNote(previousPage, _materialize(_page));
    }

    // Commit navigation only after the previous page is safe. Text-layer
    // loading below is best effort and must never decide whether this page is
    // a valid PDF page.
    final moveFuture = moveViewer && controller.isReady
        ? controller.goToPage(
            pageNumber: pageNumber,
            duration: const Duration(milliseconds: 180),
          )
        : null;
    if (mounted && request == _pdfPageLoadToken) {
      setState(() {
        _pdfPageNumber = pageNumber;
        _pdfAnnotationPageNumber = null;
      });
      _pdfPageStateListenable.value = (
        current: pageNumber,
        total: _pdfPageCount,
      );
      widget.onPdfPageChanged?.call(pageNumber);
    }

    final next = await _loadPdfPageNote(pageNumber);
    if (!mounted || request != _pdfPageLoadToken) return;
    final resolved = next ?? _pendingPdfPageNote(pageNumber);
    _cachePdfPageNote(pageNumber, resolved);
    _restoring = true;
    _pages[_current].replaceNote(resolved);
    for (final blockController in _pages[_current].blockControllers.values) {
      blockController.addListener(_onDraftChanged);
    }
    _restoring = false;
    _resetHistory();
    if (moveFuture != null) await moveFuture;
    if (!mounted || request != _pdfPageLoadToken) return;
    setState(() {
      _pdfPageNumber = pageNumber;
      _pdfAnnotationPageNumber = pageNumber;
    });
    _schedulePdfOverlayRefresh(controller);
    _pdfPageStateListenable.value = (current: pageNumber, total: _pdfPageCount);
    widget.onPdfPageChanged?.call(pageNumber);
    if (showUnavailable && next == null) {
      AppToast.show(context, '该 PDF 页文字层暂不可用，仍可阅读和画笔批注');
    }
  }

  Note _pendingPdfPageNote(int pageNumber) {
    final now = DateTime.now().toIso8601String();
    final document = BookPageDocument(
      schemaVersion: 2,
      blocks: const [],
      pageNumber: pageNumber.toString(),
    );
    return _page.note.copyWith(
      clearId: true,
      type: 'text',
      title: 'PDF 第 $pageNumber 页',
      content: '',
      contentDelta: '',
      sourceType: 'pdf_ocr_pending',
      bookPage: pageNumber.toString(),
      annotationsJson: jsonEncode(document.toJson()),
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<Note?> _loadPdfPageNote(int pageNumber) {
    final cached = _pdfPageNoteCache[pageNumber];
    if (cached != null) return Future.value(cached);
    final futures = _pdfPageLoadFutures;
    final existing = futures[pageNumber];
    if (existing != null) {
      return existing.then((loaded) {
        if (loaded == null) return null;
        final latestCached = _pdfPageNoteCache[pageNumber];
        return _mergePdfPageAnnotations(loaded, latestCached ?? loaded);
      });
    }
    final loader = widget.pdfPageLoader;
    if (loader == null) return Future.value();
    final loadFuture = () async {
      try {
        final loaded = await loader(pageNumber);
        final latestCached = _pdfPageNoteCache[pageNumber] ?? cached;
        return loaded == null
            ? null
            : _mergePdfPageAnnotations(
                _normalizePdfNoteForPage(loaded, pageNumber),
                latestCached ?? loaded,
              );
      } catch (_) {
        return null;
      }
    }();
    late final Future<Note?> future;
    future = loadFuture.whenComplete(() {
      if (identical(futures[pageNumber], future)) {
        futures.remove(pageNumber);
      }
    });
    futures[pageNumber] = future;
    return future;
  }

  void _cachePdfPageNote(int pageNumber, Note note) {
    final normalized = _normalizePdfNoteForPage(note, pageNumber);
    _pdfPageNoteCache
      ..remove(pageNumber)
      ..[pageNumber] = normalized;
    if (_pdfPageNoteCache.length > 8) {
      _pdfPageNoteCache.remove(_pdfPageNoteCache.keys.first);
    }
  }

  void _onPageChanged(int index) {
    _imageEditor.clearSelection();
    _dismissKeyboard();
    if (!mounted || index == _current) return;
    setState(() {
      _current = index;
      _resetHistory();
    });
  }

  void _onPdfPageChanged(int? pageNumber) {
    if (!_isPdfEditor || pageNumber == null || pageNumber < 1) return;
    final nextCount = _pdfViewerController?.isReady == true
        ? _pdfViewerController!.pageCount
        : _pdfPageCount;
    final pageChanged = _pdfPageNumber != pageNumber;
    final countChanged = _pdfPageCount != nextCount;
    if (!pageChanged && !countChanged) return;
    void updatePageState() {
      _pdfPageNumber = pageNumber;
      _pdfPageCount = nextCount;
      if (pageChanged && pageNumber != _activePdfDocumentPage) {
        // The viewer moved before the page-specific note finished loading.
        // Clear the old page's overlay immediately; it must never migrate with
        // the viewport during the asynchronous switch.
        _pdfAnnotationPageNumber = null;
      }
    }
    if (mounted) {
      setState(updatePageState);
      _schedulePdfOverlayRefresh(_pdfViewerController!);
    } else {
      updatePageState();
    }
    _pdfPageStateListenable.value = (current: pageNumber, total: nextCount);
    widget.onPdfPageChanged?.call(pageNumber);
    if (!_horizontalPdfPaging && pageNumber != _activePdfDocumentPage) {
      unawaited(_activatePdfPage(pageNumber));
    }
  }

  void _toggleConsole() {
    if (_pageInputLocked) return;
    _imageEditor.lockSelection();
    _dismissKeyboard();
    if (_consoleOpen) {
      setState(() => _consoleOpen = false);
      _consoleController.reverse();
    } else {
      setState(() => _consoleOpen = true);
      _consoleController.forward();
    }
  }

  void _toggleCatalog() {
    if (_pageInputLocked) return;
    _imageEditor.lockSelection();
    _dismissKeyboard();
    _catalogOpen = !_catalogOpen;
    _catalogOpenListenable.value = _catalogOpen;
  }

  void _closeCatalog() {
    if (!_catalogOpen) return;
    _catalogOpen = false;
    _catalogOpenListenable.value = false;
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    _pdfTextFocusTimeout?.cancel();
    if (_activePdfTextBlockIdListenable.value != null) {
      _activePdfTextBlockIdListenable.value = null;
    }
  }

  BookPageDocument _editedDocument(_BookPageDraft page) {
    if (page.hasUnsupportedLayout) return page.draftDocument();
    final visible = page.document.renderBlocks;
    final paragraphs = page.bodyController.text
        .split(RegExp(r'\n\s*\n'))
        .map(_cleanEditorParagraph)
        .where((text) => text.isNotEmpty)
        .toList();
    final editedBlocks = <OcrBlock>[];
    var bodyIndex = 0;
    var foundTitle = false;
    var maxId = 0;

    for (final block in visible) {
      if (block.id > maxId) maxId = block.id;
      if (block.isFurniture || block.isTable || block.isFigure) {
        editedBlocks.add(block);
        continue;
      }
      if (block.isTitle && !foundTitle) {
        foundTitle = true;
        editedBlocks.add(
          block.copyWith(text: page.titleController.text.trim()),
        );
        continue;
      }
      final text = bodyIndex < paragraphs.length ? paragraphs[bodyIndex++] : '';
      editedBlocks.add(block.copyWith(text: text));
    }

    if (!foundTitle && page.titleController.text.trim().isNotEmpty) {
      editedBlocks.insert(
        0,
        OcrBlock(
          id: maxId + 1,
          text: page.titleController.text.trim(),
          type: 'title',
          x: .08,
          y: .08,
          width: .84,
          height: .08,
          fontWeightRole: 'bold',
        ),
      );
    }
    while (bodyIndex < paragraphs.length) {
      editedBlocks.add(
        OcrBlock(
          id: ++maxId,
          text: paragraphs[bodyIndex++],
          type: 'paragraph',
          x: .08,
          y: .08,
          width: .84,
          height: .06,
          firstLineIndent: 2,
        ),
      );
    }

    return BookPageDocument(
      schemaVersion: 2,
      blocks: page.document.blocks,
      editedBlocks: editedBlocks,
      pageNumber: page.document.pageNumber,
      compatibilityMarkdown: MarkdownBlocksCodec.toMarkdown(editedBlocks),
    );
  }

  Note _materialize(_BookPageDraft page) {
    final document = _editedDocument(page);
    final now = DateTime.now().toIso8601String();
    final bookId = widget.bookId ?? page.note.bookId;
    final bookName = widget.bookName ?? page.note.bookName;
    final documentJson = document.toJson();
    final annotationJson = page.annotations.toJson();
    documentJson['annotations'] = annotationJson['annotations'];
    documentJson['annotation_schema_version'] =
        annotationJson['schema_version'];
    documentJson['annotation_coordinate_space'] =
        annotationJson['annotation_coordinate_space'];
    return page.note.copyWith(
      bookId: bookId,
      bookName: bookName,
      title: page.titleController.text.trim(),
      content: document.plainText,
      contentDelta: '',
      annotationsJson: jsonEncode(documentJson),
      bookPage: document.pageNumber ?? page.note.bookPage,
      updatedAt: now,
    );
  }

  Future<Note> _persistPage(Note note) async {
    if (widget.isDraft) return note;
    if (note.id == null) {
      final id = await _db.insertNote(note);
      return note.copyWith(id: id);
    }
    final changed = await _db.update(note);
    if (changed == 0) throw StateError('书页不存在或已被删除');
    return note;
  }

  Future<void> _saveDirty() async {
    _saveAgain = true;
    final active = _saveFuture;
    if (active != null) {
      await active;
      return;
    }
    if (!_pages.any((page) => page.revision != page.persistedRevision)) {
      _saveAgain = false;
      return;
    }
    final future = _runSaveQueue();
    _saveFuture = future;
    try {
      await future;
    } finally {
      if (identical(_saveFuture, future)) _saveFuture = null;
    }
  }

  Future<void> _runSaveQueue() async {
    _saveError = false;
    while (_saveAgain) {
      _saveAgain = false;
      final dirty = [
        for (final page in _pages)
          if (page.revision != page.persistedRevision) page,
      ];
      if (dirty.isEmpty) break;
      if (mounted && _saveState != _EditorSaveState.saving) {
        setState(() => _saveState = _EditorSaveState.saving);
      }
      for (final page in dirty) {
        try {
          final revisionAtStart = page.revision;
          final saved = await _persistPage(_materialize(page));
          // A new stroke or text edit may arrive while persistence is
          // awaiting the database. Never let that older result replace the
          // newer in-memory page state.
          if (page.revision != revisionAtStart) {
            _saveAgain = true;
            continue;
          }
          page.note = saved;
          page.document = BookPageDocumentContent.documentFor(saved);
          page.annotations = _annotationsFor(saved);
          page.persistedRevision = revisionAtStart;
          if (identical(page, _page)) {
            _lastObserved = _snapshotFor(page);
          }
        } catch (error) {
          debugPrint('[BookPageEdit] 保存书页失败: $error');
          _saveError = true;
        }
      }
      if (!_saveError && dirty.isNotEmpty && widget.onDraftSaved != null) {
        try {
          await widget.onDraftSaved!(
            [for (final page in _pages) _materialize(page)],
          );
        } catch (error) {
          debugPrint('[BookPageEdit] 草稿资料保存失败: $error');
          // The page notes were only materialized in memory. Keep the changed
          // pages dirty so Finish/retry can run the source-revision save again
          // instead of falsely treating a failed source save as complete.
          for (final page in dirty) {
            if (page.persistedRevision == page.revision) {
              page.persistedRevision = page.revision - 1;
            }
          }
          _saveError = true;
        }
      }
    }
    _hasUnsavedChanges = _pages.any(
      (page) => page.revision != page.persistedRevision,
    );
    if (mounted) {
      setState(() {
        _saveState = _saveError
            ? _EditorSaveState.failed
            : _EditorSaveState.saved;
      });
    }
  }

  Future<void> _finish() async {
    _imageEditor.lockSelection();
    _dismissKeyboard();
    if (_finishInProgress) return;
    _finishInProgress = true;
    _saveTimer?.cancel();
    await _saveDirty();
    if (!mounted) return;
    if (_saveError || _hasUnsavedChanges) {
      _finishInProgress = false;
      AppToast.show(context, '保存失败，请重试');
      return;
    }
    await _cleanupRemovedImageAssets();
    _allowPop = true;
    Navigator.of(context).pop(<Note>[for (final page in _pages) page.note]);
  }

  Future<void> _cleanupRemovedImageAssets() async {
    final referenced = {
      for (final page in _pages)
        for (final image in page.annotations.images) image.assetPath,
    };
    final candidates = _managedImageAssets
        .where((path) => !referenced.contains(path))
        .toList(growable: false);
    for (final path in candidates) {
      try {
        await _imageStore.delete(path);
      } catch (_) {
        // Cleanup is best-effort. A failed delete must never block a saved page.
      }
    }
    _managedImageAssets.removeAll(candidates);
  }

  Future<void> _showOriginal() async {
    _imageEditor.lockSelection();
    _dismissKeyboard();
    final note = _page.note;
    final path = note.originalPhotoPath.isNotEmpty
        ? note.originalPhotoPath
        : note.photoPath;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      requestFocus: false,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.file(
                  File(path),
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
                onPressed: () {
                  _dismissKeyboard();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUnavailable(String feature) {
    _dismissKeyboard();
    AppToast.show(context, '$feature功能暂未开放');
  }

  void _showRealtimeVoiceUnavailable() {
    _showUnavailable('实时语音');
  }

  void _closeConversationPanel() {
    setState(() => _laserPanelOpen = false);
  }

  Future<void> _showAiMenu(BuildContext anchorContext) async {
    _dismissKeyboard();
    const menuWidth = 156.0;
    final choice = await showMenu<_AiMenuChoice>(
      context: anchorContext,
      positionBuilder: (menuContext, _) {
        final box = anchorContext.findRenderObject() as RenderBox;
        final topLeft = box.localToGlobal(Offset.zero);
        final bottomRight = box.localToGlobal(
          box.size.bottomRight(Offset.zero),
        );
        final screenWidth = MediaQuery.sizeOf(menuContext).width;
        final screenHeight = MediaQuery.sizeOf(menuContext).height;
        final left = (topLeft.dx + box.size.width / 2 - menuWidth / 2)
            .clamp(8.0, screenWidth - menuWidth - 8.0)
            .toDouble();
        final top = (bottomRight.dy + 6)
            .clamp(8.0, screenHeight - 170)
            .toDouble();
        return RelativeRect.fromLTRB(
          left,
          top,
          screenWidth - left - menuWidth,
          screenHeight - top - 170,
        );
      },
      items: [
        _CompactPopupMenuEntry<_AiMenuChoice>(
          key: const Key('book_page_editor_open_ai_conversation'),
          value: _AiMenuChoice.conversation,
          label: 'AI 对话',
        ),
        _CompactPopupMenuEntry<_AiMenuChoice>(
          key: const Key('book_page_editor_generate_independent_note'),
          value: _AiMenuChoice.independentNote,
          label: '生成独立笔记',
        ),
        _CompactPopupMenuEntry<_AiMenuChoice>(
          key: const Key('book_page_editor_generate_annotation_note'),
          value: _AiMenuChoice.annotationNote,
          label: '生成批注笔记',
        ),
      ],
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFD8D3CC)),
      ),
      menuPadding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: menuWidth),
      semanticLabel: 'AI 功能选项',
      requestFocus: false,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AiMenuChoice.conversation:
        setState(() => _laserPanelOpen = true);
      case _AiMenuChoice.independentNote:
        _showUnavailable('独立笔记');
      case _AiMenuChoice.annotationNote:
        _showUnavailable('批注笔记');
    }
  }

  Future<void> _insertImage(BuildContext anchorContext) async {
    if (_imageImportInProgress) return;
    _dismissKeyboard();
    _imageEditor.lockSelection();
    if (_drawingEditorActive) _toggleDrawingPalette();
    if (!_annotationTools.isBrowseMode) {
      _annotationTools.selectTool(DrawingTool.browse);
    }
    const menuWidth = 128.0;
    final source = await showMenu<ImageSource>(
      context: anchorContext,
      positionBuilder: (menuContext, _) {
        final box = anchorContext.findRenderObject() as RenderBox;
        final topLeft = box.localToGlobal(Offset.zero);
        final bottomRight = box.localToGlobal(
          box.size.bottomRight(Offset.zero),
        );
        final screenWidth = MediaQuery.sizeOf(menuContext).width;
        final screenHeight = MediaQuery.sizeOf(menuContext).height;
        final left = (topLeft.dx + box.size.width / 2 - menuWidth / 2)
            .clamp(8.0, screenWidth - menuWidth - 8.0)
            .toDouble();
        final top = (bottomRight.dy + 6)
            .clamp(8.0, screenHeight - 120)
            .toDouble();
        return RelativeRect.fromLTRB(
          left,
          top,
          screenWidth - left - menuWidth,
          screenHeight - top - 120,
        );
      },
      items: [
        _CompactPopupMenuEntry<ImageSource>(
          key: const Key('book_page_editor_image_camera'),
          value: ImageSource.camera,
          label: '拍照',
          icon: const Icon(Icons.photo_camera_outlined, size: 22),
          horizontalPadding: 12,
          iconGap: 8,
        ),
        _CompactPopupMenuEntry<ImageSource>(
          key: const Key('book_page_editor_image_gallery'),
          value: ImageSource.gallery,
          label: '选择图片',
          icon: const Icon(Icons.photo_library_outlined, size: 22),
          horizontalPadding: 12,
          iconGap: 8,
        ),
      ],
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFD8D3CC)),
      ),
      menuPadding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: menuWidth),
      semanticLabel: '图片操作',
      requestFocus: false,
    );
    if (source == null || !mounted) return;

    setState(() => _imageImportInProgress = true);
    try {
      final asset = await _imageStore.pickAndStore(source);
      if (asset == null || !mounted) return;
      _managedImageAssets.add(asset.relativePath);
      final before = _page.annotations;
      final id = 'image-${DateTime.now().microsecondsSinceEpoch}';
      final image = PageImageObject(
        id: id,
        assetPath: asset.relativePath,
        originalName: asset.originalName,
        pixelWidth: asset.pixelWidth,
        pixelHeight: asset.pixelHeight,
        center: const Offset(.5, .5),
        width: .5,
        createdAt: DateTime.now().toIso8601String(),
      );
      _page.annotations = before.copyWith(images: [...before.images, image]);
      _recordAnnotationChange(before);
      _imageEditor.selectForEditing(id);
      AppToast.show(context, '图片已添加');
    } on FormatException catch (error) {
      if (mounted) AppToast.show(context, error.message.toString());
    } on PlatformException catch (error) {
      if (mounted) {
        final message =
            error.code == 'camera_access_denied' ||
                error.code == 'photo_access_denied'
            ? '未获得图片权限，请在系统设置中开启后重试'
            : '图片添加失败，请重试';
        AppToast.show(context, message);
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '图片添加失败，请检查存储空间后重试');
    } finally {
      if (mounted) setState(() => _imageImportInProgress = false);
    }
  }

  void _toggleDrawingPalette() {
    _dismissKeyboard();
    if (!_drawingEditorActive) {
      _setDrawingPointerResampling(true);
      setState(() {
        _drawingEditorActive = true;
        _drawingToolbarVisible = true;
      });
      _drawingToolbarVisibleListenable.value = true;
      _setNativeInkInput(false);
      _annotationTools.selectTool(DrawingTool.browse);
      return;
    }

    if (!_drawingToolbarVisible) {
      setState(() => _drawingToolbarVisible = true);
      _drawingToolbarVisibleListenable.value = true;
      _setNativeInkInput(false);
      return;
    }

    setState(() {
      _drawingEditorActive = false;
      _drawingToolbarVisible = false;
    });
    _setDrawingPointerResampling(false);
    _drawingToolbarVisibleListenable.value = false;
    _annotationTools.clearSelection();
  }

  void _hideDrawingToolbarForCanvasInteraction() {
    if (!_drawingEditorActive || !_drawingToolbarVisible) return;
    // Hiding the floating toolbar must not rebuild the page and annotation
    // canvas in the same frame as the first pointer sample. The notifier
    // updates only the overlay subtree, leaving the page viewport untouched.
    _drawingToolbarVisible = false;
    _drawingToolbarVisibleListenable.value = false;
    _setNativeInkInput(true);
  }

  void _selectDrawingTool(DrawingTool tool) {
    _dismissKeyboard();
    if (!_drawingEditorActive || !_drawingToolbarVisible) {
      _setDrawingPointerResampling(true);
      setState(() {
        _drawingEditorActive = true;
        _drawingToolbarVisible = true;
      });
      _drawingToolbarVisibleListenable.value = true;
      _setNativeInkInput(false);
    }
    if (tool == DrawingTool.browse && _annotationTools.isBrowseMode) {
      _annotationTools.toggleBrowse();
      return;
    }
    if (_annotationTools.activeTool == tool && tool != DrawingTool.browse) {
      if (tool == DrawingTool.text) {
        _annotationTools.selectTool(DrawingTool.text);
        return;
      }
      _annotationTools.toggleToolOptions();
      return;
    }
    if (tool == DrawingTool.browse && !_annotationTools.isBrowseMode) {
      _annotationTools.selectTool(DrawingTool.browse);
      return;
    }
    _annotationTools.selectTool(tool);
    if (tool == DrawingTool.laser) _setNativeInkInput(false);
  }

  void _setDrawingPointerResampling(bool drawing) {
    final binding = GestureBinding.instance;
    _setNativeInkInput(drawing && !_drawingToolbarVisible);
    if (drawing) {
      _pointerResamplingBeforeDrawing ??= binding.resamplingEnabled;
      binding.resamplingEnabled = false;
      return;
    }
    final previous = _pointerResamplingBeforeDrawing;
    if (previous == null) return;
    binding.resamplingEnabled = previous;
    _pointerResamplingBeforeDrawing = null;
  }

  void _setNativeInkInput(bool enabled) {
    // The laser gesture is short-lived and must appear from the very first
    // Flutter pointer sample. Switching the platform ink channel on at the
    // same moment as pointer-down can replay a buffered batch after lift-off.
    final shouldEnable =
        enabled && _annotationTools.activeTool != DrawingTool.laser;
    unawaited(LowLatencyInkInput.instance.setEnabled(shouldEnable));
  }

  void _clearPageAnnotations() {
    if (_page.annotations.isEmpty) return;
    final before = _page.annotations;
    _page.annotations = PageAnnotationDocument();
    _annotationTools.clearSelection();
    _recordAnnotationChange(before);
  }

  void _removeLaserAttachment(String id) {
    final attachment = _laserTrayState.attachments
        .where((item) => item.id == id)
        .firstOrNull;
    if (attachment == null) return;
    setState(() {
      _laserTrayState = _laserTrayState.removeAttachment(id);
    });
    final path = attachment.screenshotPath;
    if (path.isEmpty) return;
    unawaited(() async {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Removing the preview from the active tray is still successful even
        // if the temporary file has already disappeared.
      }
    }());
  }

  String _saveLabel() {
    if (_saveState == _EditorSaveState.saving || _hasUnsavedChanges) {
      return '正在保存…';
    }
    if (_saveState == _EditorSaveState.failed) return '保存失败';
    return widget.isDraft && widget.onDraftSaved == null ? '已暂存' : '已自动保存';
  }

  Future<void> _captureLaserSelection(
    int pageIndex,
    List<Offset> globalPoints,
  ) async {
    if (!mounted ||
        pageIndex < 0 ||
        pageIndex >= _pages.length ||
        pageIndex != _current) {
      return;
    }
    final selection = _globalPointsBounds(globalPoints);
    if (selection == null) return;
    final page = _pages[pageIndex];
    final matchingBlocks = _laserBlocksForSelection(pageIndex, page, selection);
    final boundary = _canvasKeys[pageIndex].currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    final bounds = _globalToNormalizedRect(selection, boundary);
    if (bounds == null) return;
    final pageBounds = _isPdfEditor
        ? _pdfGlobalToNormalizedRect(selection)
        : bounds;
    if (pageBounds == null) {
      AppToast.show(context, '圈选区域不在当前 PDF 页内，请在页内重试');
      return;
    }
    try {
      final capture = await _laserScreenshotCapture.captureAnalyzed(
        boundary: boundary,
        normalizedBounds: bounds,
      );
      if (!capture.hasReadableContent) {
        await _imageStore.delete(capture.asset.relativePath);
        if (mounted) AppToast.show(context, '圈选区域没有可识别内容');
        return;
      }
      final asset = capture.asset;
      final screenshot = await _imageStore.resolve(asset.relativePath);
      if (screenshot == null || !mounted) {
        await _imageStore.delete(asset.relativePath);
        return;
      }
      if (pageIndex != _current) {
        await _imageStore.delete(asset.relativePath);
        return;
      }
      final block =
          matchingBlocks
              .where((candidate) => candidate.readableText.trim().isNotEmpty)
              .firstOrNull ??
          matchingBlocks.firstOrNull;
      final quote = block?.readableText.trim() ?? '';
      final sourceType = quote.isEmpty
          ? AiAnnotationSourceType.pageRegion
          : AiAnnotationSourceType.pageText;
      final attachment = AiAnnotationSourceAttachment(
        id: 'laser-source-${DateTime.now().microsecondsSinceEpoch}',
        sequence: _laserTrayState.attachments.length + 1,
        sourceType: sourceType,
        pageLabel: '书页 ${_pageLabel(page)}',
        quote: quote,
        screenshotPath: screenshot.path,
        screenshotRect: [bounds.left, bounds.top, bounds.right, bounds.bottom],
        anchor: AiAnnotationSourceAnchor(
          pageNoteId: page.note.id,
          documentHash: _documentFingerprint(page.document),
          blockId: block?.id.toString() ?? 'page-region',
          startOffset: 0,
          endOffset: quote.length,
          exactQuote: quote,
          normalizedRect: [
            pageBounds.left,
            pageBounds.top,
            pageBounds.right,
            pageBounds.bottom,
          ],
          sourceType: sourceType,
        ),
      );
      setState(() {
        _laserTrayState = _laserTrayState.copyWith(
          attachments: [..._laserTrayState.attachments, attachment],
          activeAttachmentId: attachment.id,
          isReviewOpen: false,
        );
      });
      AppToast.show(context, quote.isEmpty ? '已圈选区域' : '已圈选文字');
    } catch (_) {
      if (mounted) AppToast.show(context, '圈选截图暂存失败，请重试');
    }
  }

  String _pageLabel(_BookPageDraft page) {
    final pageNumber = page.document.pageNumber?.trim();
    if (pageNumber != null && pageNumber.isNotEmpty) return pageNumber;
    return page.note.bookPage.trim().isEmpty ? '未标页码' : page.note.bookPage;
  }

  Rect? _globalPointsBounds(List<Offset> points) {
    if (points.length < 3) return null;
    final left = points.map((point) => point.dx).reduce(math.min);
    final top = points.map((point) => point.dy).reduce(math.min);
    final right = points.map((point) => point.dx).reduce(math.max);
    final bottom = points.map((point) => point.dy).reduce(math.max);
    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? _globalToNormalizedRect(Rect globalRect, RenderBox canvas) {
    if (!canvas.hasSize || canvas.size.width <= 0 || canvas.size.height <= 0) {
      return null;
    }
    final topLeft = canvas.globalToLocal(globalRect.topLeft);
    final bottomRight = canvas.globalToLocal(globalRect.bottomRight);
    final left = (math.min(topLeft.dx, bottomRight.dx) / canvas.size.width)
        .clamp(0.0, 1.0)
        .toDouble();
    final top = (math.min(topLeft.dy, bottomRight.dy) / canvas.size.height)
        .clamp(0.0, 1.0)
        .toDouble();
    final right = (math.max(topLeft.dx, bottomRight.dx) / canvas.size.width)
        .clamp(0.0, 1.0)
        .toDouble();
    final bottom = (math.max(topLeft.dy, bottomRight.dy) / canvas.size.height)
        .clamp(0.0, 1.0)
        .toDouble();
    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? _pdfGlobalToNormalizedRect(Rect globalRect) {
    final controller = _pdfViewerController;
    if (controller == null || !controller.isReady) return null;
    final pageNumber = _pdfPageNumber;
    final layouts = controller.layout.pageLayouts;
    if (pageNumber < 1 || pageNumber > layouts.length) return null;
    final pageRect = layouts[pageNumber - 1];
    final points = <Offset>[
      globalRect.topLeft,
      globalRect.topRight,
      globalRect.bottomLeft,
      globalRect.bottomRight,
    ].map(controller.globalToDocument).whereType<Offset>().toList();
    if (points.length != 4 || pageRect.width <= 0 || pageRect.height <= 0) {
      return null;
    }
    final left = points.map((point) => point.dx).reduce(math.min);
    final top = points.map((point) => point.dy).reduce(math.min);
    final right = points.map((point) => point.dx).reduce(math.max);
    final bottom = points.map((point) => point.dy).reduce(math.max);
    final normalized = Rect.fromLTRB(
      ((left - pageRect.left) / pageRect.width).clamp(0.0, 1.0).toDouble(),
      ((top - pageRect.top) / pageRect.height).clamp(0.0, 1.0).toDouble(),
      ((right - pageRect.left) / pageRect.width).clamp(0.0, 1.0).toDouble(),
      ((bottom - pageRect.top) / pageRect.height).clamp(0.0, 1.0).toDouble(),
    );
    return normalized.width > 0 && normalized.height > 0 ? normalized : null;
  }

  List<OcrBlock> _laserBlocksForSelection(
    int pageIndex,
    _BookPageDraft page,
    Rect globalSelection,
  ) {
    if (_isPdfEditor) {
      final normalized = _pdfGlobalToNormalizedRect(globalSelection);
      if (normalized == null) return const [];
      return page.document.renderBlocks
          .where(
            (block) =>
                !block.isFurniture &&
                _laserSelectionHitsBlock(normalized, block),
          )
          .toList(growable: false);
    }
    final editable = _findRenderEditable(_bodyFieldKeys[pageIndex]);
    if (editable != null) {
      final ranges = _bodyBlockRanges(page);
      final matches = <OcrBlock>[];
      for (final (block, start, end) in ranges) {
        final boxes = editable.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: end),
        );
        final hit = boxes.any((box) {
          final local = box.toRect();
          final topLeft = editable.localToGlobal(local.topLeft);
          final bottomRight = editable.localToGlobal(local.bottomRight);
          final boxRect = Rect.fromPoints(topLeft, bottomRight);
          return !boxRect.intersect(globalSelection).isEmpty;
        });
        if (hit) matches.add(block);
      }
      return matches;
    }

    final canvas = _canvasRenderBox(pageIndex);
    if (canvas == null) return const [];
    final normalized = _globalToNormalizedRect(globalSelection, canvas);
    if (normalized == null) return const [];
    return page.document.renderBlocks
        .where(
          (block) =>
              !block.isFurniture && _laserSelectionHitsBlock(normalized, block),
        )
        .toList(growable: false);
  }

  List<(OcrBlock, int, int)> _bodyBlockRanges(_BookPageDraft page) {
    final blocks = page.document.renderBlocks
        .where(
          (block) =>
              !block.isFurniture &&
              !block.isTitle &&
              block.readableText.trim().isNotEmpty,
        )
        .toList(growable: false);
    final text = page.bodyController.text;
    final ranges = <(OcrBlock, int, int)>[];
    var cursor = 0;
    var blockIndex = 0;
    for (final paragraph in text.split(RegExp(r'\n\s*\n'))) {
      if (paragraph.isEmpty || blockIndex >= blocks.length) continue;
      final start = text.indexOf(paragraph, cursor);
      if (start < 0) continue;
      final end = start + paragraph.length;
      ranges.add((blocks[blockIndex++], start, end));
      cursor = end;
    }
    return ranges;
  }

  RenderEditable? _findRenderEditable(GlobalKey key) {
    return _findRenderEditableIn(_renderObjectFor(key));
  }

  RenderObject? _renderObjectFor(GlobalKey key) =>
      key.currentContext?.findRenderObject();

  RenderEditable? _findRenderEditableIn(RenderObject? object) {
    if (object is RenderEditable) return object;
    RenderEditable? result;
    object?.visitChildren((child) {
      result ??= _findRenderEditableIn(child);
    });
    return result;
  }

  RenderBox? _canvasRenderBox(int pageIndex) {
    final renderObject = _canvasKeys[pageIndex].currentContext
        ?.findRenderObject();
    return renderObject is RenderBox ? renderObject : null;
  }

  String _documentFingerprint(BookPageDocument document) {
    final bytes = utf8.encode(jsonEncode(document.toJson()));
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return 'fnv1a64:${hash.toRadixString(16).padLeft(16, '0')}';
  }

  bool _laserSelectionHitsBlock(Rect selection, OcrBlock block) {
    final blockBounds = Rect.fromLTWH(
      block.x,
      block.y,
      block.width,
      block.height,
    );
    final intersection = blockBounds.intersect(selection);
    if (intersection.isEmpty) return false;
    final centerMatches =
        blockBounds.contains(selection.center) ||
        selection.contains(blockBounds.center);
    if (!centerMatches) return false;
    final blockArea = math.max(blockBounds.width * blockBounds.height, .000001);
    final overlapArea = intersection.width * intersection.height;
    return centerMatches || overlapArea / blockArea >= .18;
  }

  void _submitConversation(String text) {
    _laserTrayState = _laserTrayState.copyWith(inputText: text);
    AppToast.show(context, '问题已暂存，AI 回答服务将在下一阶段接入');
  }

  void _submitConversationWithWebSources(
    String text,
    List<AiWebSource> sources,
  ) {
    _laserTrayState = _laserTrayState.copyWith(inputText: text);
    AppToast.show(
      context,
      sources.isEmpty
          ? '问题已暂存，AI 回答服务将在下一阶段接入'
          : '问题已暂存，附带 ${sources.length} 条网页来源；AI 回答服务将在下一阶段接入',
    );
  }

  Widget _buildEditorCanvas(int index) {
    return RepaintBoundary(
      key: _canvasKeys[index],
      child: _EditorCanvas(
        key: Key('book_page_editor_canvas_$index'),
        page: _pages[index],
        pageIndex: index,
        bodyFieldKey: _bodyFieldKeys[index],
        pageContentKey: _pageContentKeys[index],
        annotationLayerKey: _annotationLayerKeys[index],
        saveLabel: _saveLabel(),
        keyboardInsetListenable: _keyboardInsetListenable,
        // During a physical-page switch the PDF viewer can already be on the
        // target page while its OCR/note payload is still loading. Do not let
        // the previous page's annotation document follow that viewport.
        annotationDocument:
            _isPdfEditor && _pdfAnnotationPageNumber != _pdfPageNumber
                ? PageAnnotationDocument()
                : _pages[index].annotations,
        imageStore: _imageStore,
        imageEditor: _imageEditor,
        // The annotation layer must remain interactive while a PDF page
        // payload is settling. Page identity is guarded by the overlay
        // document/key below; disabling this flag would make the gesture
        // complete without producing any ink at all.
        drawingEnabled: _drawingEditorActive,
        pageLocked: _pageInputLocked,
        isActivePage: index == _current,
        liveEditableBlockIds: _liveEditableBlockIds(index),
        pendingFocusBlockId: _pendingEditableFocusBlockId,
        onPromoteBlock: (blockId) => _promoteEditableBlock(index, blockId),
        annotationTools: _annotationTools,
        onLaserSelection: (points) {
          final selection = List<Offset>.unmodifiable(points);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(_captureLaserSelection(index, selection));
          });
        },
        onAnnotationChanged: (next) {
          final before = _pages[index].annotations;
          _pages[index].annotations = next;
          if (_isPdfEditor) {
            // Keep the page cache aligned with the live editor state. A quick
            // page switch may happen before the database debounce completes.
            final activePage = _activePdfDocumentPage;
            if (activePage != null) {
              _cachePdfPageNote(activePage, _materialize(_pages[index]));
            }
          }
          _managedImageAssets.addAll({
            for (final image in before.images)
              if (!next.images.any((item) => item.id == image.id))
                image.assetPath,
          });
          _recordAnnotationChange(before);
        },
        onAnnotationAction: (action) {
          switch (action) {
            case _AnnotationAction.edit:
              _annotationTools.enterTransformMode();
            case _AnnotationAction.copy:
            case _AnnotationAction.color:
            case _AnnotationAction.delete:
              break;
          }
        },
        onOriginal: () {
          _current = index;
          final callback = widget.onOriginalPage;
          if (callback != null) {
            unawaited(callback(index));
          } else {
            unawaited(_showOriginal());
          }
        },
        pdfDocumentRef: widget.pdfDocumentRef,
        pdfController: _pdfViewerController,
        pdfPageNumber: _pdfPageNumber,
        pdfPaginationModeListenable: widget.pdfPaginationModeListenable,
        activePdfTextBlockIdListenable: _activePdfTextBlockIdListenable,
        onPdfInteractionStart: _onPdfInteractionStart,
        onPdfInteractionEnd: _onPdfInteractionEnd,
        onPdfPageChanged: _onPdfPageChanged,
        onPdfTextFocus: _onPdfTextFocus,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_catalogOpen) {
          _closeCatalog();
          return;
        }
        if (!_finishInProgress) unawaited(_finish());
      },
      child: DefaultTextStyle(
        style: DefaultTextStyle.of(context).style.copyWith(
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent,
        ),
        child: Stack(
          children: [
            Scaffold(
              backgroundColor: NotePageTheme.card,
              // Keep the expensive multi-line editor at a stable size while
              // the IME animates. The active caret is revealed by synchronizing
              // only its ScrollPosition with the platform inset below.
              resizeToAvoidBottomInset: false,
              body: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    RepaintBoundary(
                      child: _EditorToolbar(
                        onBack: _finish,
                        onPageControl: widget.catalogDrawerBuilder == null
                            ? _toggleConsole
                            : _toggleCatalog,
                        pageButtonTooltip: widget.catalogDrawerBuilder == null
                            ? '查看书页'
                            : '查看目录与识别文本',
                        onUndo: _undoStack.isEmpty ? null : _undo,
                        onRedo: _redoStack.isEmpty ? null : _redo,
                        onAi: (anchorContext) => _showAiMenu(anchorContext),
                        onImage: (anchorContext) => _insertImage(anchorContext),
                        imageBusy: _imageImportInProgress,
                        onVoice: _showRealtimeVoiceUnavailable,
                        onPen: _toggleDrawingPalette,
                        onFinish: _finish,
                      ),
                    ),
                    Expanded(
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) =>
                            _hideDrawingToolbarForCanvasInteraction(),
                        child: _isPdfEditor
                            ? _buildEditorCanvas(0)
                            : PageView.builder(
                                key: const Key('book_page_editor_view'),
                                controller: _pageController,
                                itemCount: _pages.length,
                                allowImplicitScrolling: true,
                                physics: _pageInputLocked
                                    ? const NeverScrollableScrollPhysics()
                                    : null,
                                onPageChanged: _onPageChanged,
                                itemBuilder: (context, index) =>
                                    _buildEditorCanvas(index),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top:
                  MediaQuery.viewPaddingOf(context).top +
                  _EditorToolbar.height +
                  10,
              left: 12,
              right: 12,
              child: ValueListenableBuilder<bool>(
                valueListenable: _drawingToolbarVisibleListenable,
                builder: (context, visible, _) => visible
                    ? Material(
                        type: MaterialType.transparency,
                        child: _DrawingToolOverlay(
                          controller: _annotationTools,
                          onToolSelected: _selectDrawingTool,
                          onToolPressedAgain: _selectDrawingTool,
                          onClearPage: _clearPageAnnotations,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            if (!_laserPanelOpen)
              Positioned(
                top:
                    MediaQuery.viewPaddingOf(context).top +
                    _EditorToolbar.height +
                    14,
                right: 20,
                child: AiConversationEntryButton(
                  key: const Key('book_page_editor_ai_conversation_entry'),
                  annotationCount: _laserTrayState.count,
                  onPressed: () => setState(() => _laserPanelOpen = true),
                ),
              ),
            // Page navigation chrome stays anchored to the full window and is
            // naturally covered by the keyboard instead of moving with text.
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: AnimatedBuilder(
                  animation: _consoleAnimation,
                  builder: (context, _) {
                    final visible =
                        widget.catalogDrawerBuilder == null &&
                        (_consoleOpen || _consoleAnimation.value > 0);
                    return Stack(
                      children: [
                        if (visible)
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                setState(() => _consoleOpen = false);
                                _consoleController.reverse();
                              },
                              child: const SizedBox.expand(),
                            ),
                          ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            ignoring: !visible,
                            child: SlideTransition(
                              position: _consolePosition,
                              child: _EditorPageConsole(
                                pages: _pages,
                                current: _current,
                                onSelect: _selectPage,
                              ),
                            ),
                          ),
                        ),
                        if (!visible &&
                            !_laserPanelOpen &&
                            (!_isPdfEditor ||
                                _pdfViewerController?.isReady == true))
                          _isPdfEditor
                              ? Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 24,
                                  child:
                                      ValueListenableBuilder<
                                        ({int current, int? total})
                                      >(
                                        valueListenable:
                                            _pdfPageStateListenable,
                                        builder: (_, pageState, _) => Center(
                                          child: _EditorPageCounter(
                                            key: const Key(
                                              'book_page_editor_counter',
                                            ),
                                            current: pageState.current,
                                            total:
                                                pageState.total ??
                                                _pdfPageCount,
                                            pdf: true,
                                          ),
                                        ),
                                      ),
                                )
                              : Positioned(
                                  left: 20,
                                  bottom: bottomInset + 14,
                                  child: _EditorPageCounter(
                                    key: const Key('book_page_editor_counter'),
                                    current: _current + 1,
                                    total: _pages.length,
                                  ),
                                ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (widget.catalogDrawerBuilder != null)
              ValueListenableBuilder<bool>(
                valueListenable: _catalogOpenListenable,
                builder: (context, open, _) {
                  if (!open) return const SizedBox.shrink();
                  final drawerBuilder = widget.catalogDrawerBuilder!;
                  Widget drawer(BuildContext context) => drawerBuilder(
                    _closeCatalog,
                    (index) => unawaited(_selectPage(index)),
                    () => unawaited(_finish()),
                  );
                  final versionListenable =
                      widget.catalogDrawerVersionListenable;
                  final child = versionListenable == null
                      ? drawer(context)
                      : ValueListenableBuilder<int>(
                          valueListenable: versionListenable,
                          builder: (_, _, _) => drawer(context),
                        );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _closeCatalog,
                          child: const ColoredBox(color: Color(0x66000000)),
                        ),
                      ),
                      child,
                    ],
                  );
                },
              ),
            if (_laserPanelOpen)
              Positioned.fill(
                child: Offstage(
                  offstage: !_laserPanelOpen,
                  child: AiConversationPanel(
                    key: const Key('book_page_editor_ai_conversation_panel'),
                    annotationCount: _laserTrayState.count,
                    bookId: widget.bookId ?? _page.note.bookId,
                    bookName: widget.bookName ?? _page.note.bookName,
                    pageLabel: _pageLabel(_page),
                    attachments: _laserTrayState.attachments,
                    onRemoveAttachment: _removeLaserAttachment,
                    onClose: _closeConversationPanel,
                    onSubmit: _submitConversation,
                    onVoice: _showRealtimeVoiceUnavailable,
                    onSubmitWithWebSources: _submitConversationWithWebSources,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _cleanEditorParagraph(String text) =>
    text.trim().replaceFirst(RegExp(r'^[\u3000 ]{1,2}'), '');

class _EditorToolbar extends StatelessWidget {
  static const height = 66.0;
  static const _toolbarButtonExtent = 52.0;
  static const _toolbarLeading = 10.0;
  static const _pageToHistoryGap = 126.0;
  static const _toolGap = 8.0;
  static const _finishGap = 127.0;
  static const _finishWidth = 72.0;
  static const _toolbarIconColor = NotePageTheme.ink;

  const _EditorToolbar({
    required this.onBack,
    required this.onPageControl,
    this.pageButtonTooltip = '查看书页',
    required this.onUndo,
    required this.onRedo,
    required this.onAi,
    required this.onImage,
    this.imageBusy = false,
    required this.onVoice,
    required this.onPen,
    required this.onFinish,
  });

  final VoidCallback onBack;
  final VoidCallback onPageControl;
  final String pageButtonTooltip;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final ValueChanged<BuildContext> onAi;
  final ValueChanged<BuildContext> onImage;
  final bool imageBusy;
  final VoidCallback onVoice;
  final VoidCallback onPen;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final backButton = _EditorToolbarButton(
      key: const Key('book_page_editor_back'),
      icon: Icons.arrow_back,
      tooltip: '返回',
      onPressed: onBack,
      iconSize: 28,
      buttonExtent: _toolbarButtonExtent,
    );
    final pageButton = EditorToolbarAssetButton(
      key: const Key('book_page_editor_page_control'),
      tooltip: pageButtonTooltip,
      onPressed: onPageControl,
      assetPath: EditorToolbarAssets.bookPageA,
      color: _toolbarIconColor,
      iconSize: 32,
      buttonExtent: _toolbarButtonExtent,
    );
    final undoButton = _UndoRedoToolbarButton(
      key: const Key('book_page_editor_undo'),
      tooltip: '撤销',
      onPressed: onUndo,
      redo: false,
    );
    final redoButton = _UndoRedoToolbarButton(
      key: const Key('book_page_editor_redo'),
      tooltip: '重做',
      onPressed: onRedo,
      redo: true,
    );
    final aiButton = Builder(
      builder: (buttonContext) => _AiToolbarButton(
        key: const Key('book_page_editor_ai'),
        onPressed: () => onAi(buttonContext),
      ),
    );
    final imageButton = Builder(
      builder: (buttonContext) => EditorToolbarAssetButton(
        key: const Key('book_page_editor_image'),
        tooltip: imageBusy ? '正在添加图片' : '图片',
        onPressed: imageBusy ? null : () => onImage(buttonContext),
        assetPath: EditorToolbarAssets.imageA,
        color: imageBusy
            ? _toolbarIconColor.withValues(alpha: .54)
            : _toolbarIconColor,
        iconSize: 32,
        buttonExtent: _toolbarButtonExtent,
      ),
    );
    final voiceButton = EditorToolbarAssetButton(
      key: const Key('book_page_editor_voice'),
      tooltip: '语音',
      onPressed: onVoice,
      assetPath: EditorToolbarAssets.voiceA,
      color: _toolbarIconColor,
      iconSize: 32,
      buttonExtent: _toolbarButtonExtent,
    );
    final noteButton = EditorToolbarAssetButton(
      key: const Key('book_page_editor_pen'),
      tooltip: '画笔',
      onPressed: onPen,
      assetPath: EditorToolbarAssets.noteA,
      color: _toolbarIconColor,
      iconSize: 32,
      buttonExtent: _toolbarButtonExtent,
    );
    final compactActions = <Widget>[
      backButton,
      pageButton,
      const SizedBox(width: _pageToHistoryGap),
      undoButton,
      const SizedBox(width: 4),
      redoButton,
      const SizedBox(width: _toolGap),
      aiButton,
      const SizedBox(width: _toolGap),
      imageButton,
      const SizedBox(width: _toolGap),
      voiceButton,
      const SizedBox(width: _toolGap),
      noteButton,
    ];
    Widget finishButton() => SizedBox(
      width: _finishWidth,
      height: _toolbarButtonExtent,
      child: TextButton(
        key: const Key('book_page_editor_finish'),
        onPressed: onFinish,
        child: const Text(
          '完成',
          style: TextStyle(
            color: NotePageTheme.ink,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: NotePageTheme.card,
        border: Border(bottom: BorderSide(color: NotePageTheme.line)),
      ),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 800) {
              return Row(
                children: [
                  const SizedBox(width: _toolbarLeading),
                  backButton,
                  pageButton,
                  const SizedBox(width: _pageToHistoryGap),
                  undoButton,
                  const SizedBox(width: 4),
                  redoButton,
                  const SizedBox(width: _toolGap),
                  aiButton,
                  const SizedBox(width: _toolGap),
                  imageButton,
                  const SizedBox(width: _toolGap),
                  voiceButton,
                  const SizedBox(width: _toolGap),
                  noteButton,
                  const SizedBox(width: _finishGap),
                  finishButton(),
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: compactActions),
                  ),
                ),
                finishButton(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AiToolbarButton extends StatelessWidget {
  const _AiToolbarButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => EditorToolbarAssetButton(
    tooltip: 'AI功能',
    onPressed: onPressed,
    assetPath: EditorToolbarAssets.aiC,
    color: _EditorToolbar._toolbarIconColor,
    iconSize: 34,
    buttonExtent: _EditorToolbar._toolbarButtonExtent,
  );
}

class _EditorToolbarButton extends StatelessWidget {
  const _EditorToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 24,
    this.buttonExtent = 52,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double iconSize;
  final double buttonExtent;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: iconSize,
        color: onPressed == null
            ? NotePageTheme.muted.withValues(alpha: .5)
            : NotePageTheme.ink,
      ),
      padding: const EdgeInsets.all(10),
      constraints: BoxConstraints(
        minWidth: buttonExtent,
        minHeight: buttonExtent,
      ),
    );
  }
}

class _UndoRedoToolbarButton extends StatelessWidget {
  const _UndoRedoToolbarButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.redo,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final bool redo;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return EditorToolbarAssetButton(
      tooltip: tooltip,
      onPressed: onPressed,
      assetPath: redo
          ? (enabled
                ? EditorToolbarAssets.redoBFilled
                : EditorToolbarAssets.redoA)
          : (enabled
                ? EditorToolbarAssets.undoBFilled
                : EditorToolbarAssets.undoA),
      color: enabled
          ? _EditorToolbar._toolbarIconColor
          : _EditorToolbar._toolbarIconColor.withValues(alpha: .54),
      iconSize: 32,
      buttonExtent: _EditorToolbar._toolbarButtonExtent,
    );
  }
}

class _CompactPopupMenuEntry<T> extends PopupMenuEntry<T> {
  const _CompactPopupMenuEntry({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.horizontalPadding = 16,
    this.iconGap = 12,
  });

  final T value;
  final String label;
  final Widget? icon;
  final double horizontalPadding;
  final double iconGap;

  @override
  double get height => 52;

  @override
  bool represents(T? value) => value == this.value;

  @override
  State<_CompactPopupMenuEntry<T>> createState() =>
      _CompactPopupMenuEntryState<T>();
}

class _CompactPopupMenuEntryState<T> extends State<_CompactPopupMenuEntry<T>> {
  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: radius,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(widget.value),
        borderRadius: radius,
        splashColor: NotePageTheme.ink.withValues(alpha: .08),
        highlightColor: NotePageTheme.ink.withValues(alpha: .04),
        child: Semantics(
          button: true,
          label: widget.label,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.horizontalPadding,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    widget.icon!,
                    SizedBox(width: widget.iconGap),
                  ],
                  Text(widget.label, style: const TextStyle(fontSize: 16)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AnnotationAction { copy, color, edit, delete }

enum _TextCategory { font, color, style, layout }

const _textFontChoices = [
  (id: 'serif', label: '宋体', family: PageTextFontFamily.song),
  (id: 'KaiTi', label: '楷体', family: PageTextFontFamily.kai),
  (id: 'sans-serif', label: '黑体', family: PageTextFontFamily.black),
  (id: 'MaShanZheng', label: '手写', family: PageTextFontFamily.handwriting),
  (id: 'sans-serif-rounded', label: '圆体', family: PageTextFontFamily.rounded),
  (id: 'FangSong', label: '仿宋', family: PageTextFontFamily.fangSong),
];

class _TextTransformSession {
  const _TextTransformSession({
    required this.initialText,
    required this.initialBounds,
    required this.initialHandleVector,
    required this.canvasSize,
  });

  final PageTextObject initialText;
  final Rect initialBounds;
  final Offset initialHandleVector;
  final Size canvasSize;

  Offset get center => initialBounds.center;
}

class _DrawingToolOverlay extends StatefulWidget {
  const _DrawingToolOverlay({
    required this.controller,
    required this.onToolSelected,
    required this.onToolPressedAgain,
    required this.onClearPage,
  });

  final PageAnnotationToolController controller;
  final ValueChanged<DrawingTool> onToolSelected;
  final ValueChanged<DrawingTool> onToolPressedAgain;
  final VoidCallback onClearPage;

  @override
  State<_DrawingToolOverlay> createState() => _DrawingToolOverlayState();
}

class _DrawingToolOverlayState extends State<_DrawingToolOverlay> {
  final Map<DrawingTool, GlobalKey> _toolKeys = {
    for (final tool in DrawingTool.values) tool: GlobalKey(),
  };
  final GlobalKey _optionsSurfaceKey = GlobalKey();
  double? _measuredPointerFraction;
  DrawingTool? _measuredTool;

  PageAnnotationToolController get controller => widget.controller;
  ValueChanged<DrawingTool> get onToolSelected => widget.onToolSelected;
  ValueChanged<DrawingTool> get onToolPressedAgain => widget.onToolPressedAgain;
  VoidCallback get onClearPage => widget.onClearPage;

  void _schedulePointerMeasurement(DrawingTool active) {
    if (!controller.isToolOptionsOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.isToolOptionsOpen) return;
      final toolRenderObject = _toolKeys[active]?.currentContext
          ?.findRenderObject();
      final optionsRenderObject = _optionsSurfaceKey.currentContext
          ?.findRenderObject();
      if (toolRenderObject is! RenderBox ||
          optionsRenderObject is! RenderBox ||
          optionsRenderObject.size.width <= 0) {
        return;
      }
      final toolCenter = toolRenderObject.localToGlobal(
        Offset(
          toolRenderObject.size.width / 2,
          toolRenderObject.size.height / 2,
        ),
      );
      final optionsLeft = optionsRenderObject.localToGlobal(Offset.zero).dx;
      final nextFraction =
          ((toolCenter.dx - optionsLeft) / optionsRenderObject.size.width)
              .clamp(.08, .92)
              .toDouble();
      if (_measuredTool == active &&
          _measuredPointerFraction != null &&
          (_measuredPointerFraction! - nextFraction).abs() < .001) {
        return;
      }
      setState(() {
        _measuredTool = active;
        _measuredPointerFraction = nextFraction;
      });
    });
  }

  Future<void> _showColorPicker(BuildContext context) async {
    final selected = await showDialog<int>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .12),
      builder: (_) => _InkColorPickerDialog(
        initialColor: controller.colorFor(controller.activeTool),
      ),
    );
    if (selected != null) controller.setPenColor(selected);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final active = controller.activeTool;
        final tools = const [
          DrawingTool.ballpoint,
          DrawingTool.pencil,
          DrawingTool.highlighter,
          DrawingTool.laser,
          DrawingTool.eraser,
          DrawingTool.lasso,
          DrawingTool.text,
          DrawingTool.browse,
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            // Eight 48dp touch slots plus seven 2dp gaps and capsule padding
            // need a wider surface now that laser sits after highlighter.
            final maxWidth = math.min(432.0, constraints.maxWidth);
            final main = _DrawingCapsuleSurface(
              key: const Key('book_page_editor_draw_palette'),
              maxWidth: maxWidth,
              height: 58,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < tools.length; index++) ...[
                      _DrawingToolButton(
                        key: Key(
                          'book_page_editor_draw_tool_${tools[index].name}',
                        ),
                        measurementKey: _toolKeys[tools[index]],
                        tool: tools[index],
                        selected: active == tools[index],
                        slashed:
                            tools[index] == DrawingTool.browse &&
                            active != DrawingTool.browse,
                        muted:
                            active != DrawingTool.browse &&
                            active != tools[index] &&
                            controller.isToolOptionsOpen,
                        onPressed: () {
                          if (active == tools[index]) {
                            if (tools[index] == DrawingTool.browse) {
                              onToolSelected(DrawingTool.browse);
                            } else {
                              onToolPressedAgain(tools[index]);
                            }
                          } else {
                            onToolSelected(tools[index]);
                          }
                        },
                      ),
                      if (index != tools.length - 1) const SizedBox(width: 2),
                    ],
                  ],
                ),
              ),
            );
            final optionsMaxWidth = math.min(
              560.0,
              math.max(0.0, constraints.maxWidth - 32),
            );
            final activeToolIndex = tools.indexOf(active);
            final activeToolCenter = 8.0 + 24.0 + activeToolIndex * 50.0;
            final pointerFraction = optionsMaxWidth <= 0
                ? .5
                : (((optionsMaxWidth - maxWidth) / 2) + activeToolCenter) /
                      optionsMaxWidth;
            _schedulePointerMeasurement(active);
            final options = controller.isToolOptionsOpen
                ? _ToolOptionsCapsule(
                    tool: active,
                    eraserMode: controller.eraserMode,
                    lassoMode: controller.lassoMode,
                    pointerFraction:
                        (_measuredTool == active
                            ? _measuredPointerFraction
                            : null) ??
                        pointerFraction.clamp(0.08, 0.92).toDouble(),
                    surfaceKey: _optionsSurfaceKey,
                    controller: controller,
                    onEraserMode: controller.setEraserMode,
                    onEraserRadius: controller.setEraserRadius,
                    onClearPage: () => _confirmClearPage(context),
                    onLassoMode: controller.setLassoMode,
                    onMoreColors: () => _showColorPicker(context),
                  )
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                main,
                if (options != null) ...[const SizedBox(height: 4), options],
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmClearPage(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空本页批注？'),
        content: const Text('只会删除本页的画笔和文字批注，书页原文不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空本页'),
          ),
        ],
      ),
    );
    if (confirmed == true) onClearPage();
  }
}

class _DrawingToolButton extends StatelessWidget {
  const _DrawingToolButton({
    super.key,
    this.measurementKey,
    required this.tool,
    required this.selected,
    required this.slashed,
    required this.muted,
    required this.onPressed,
  });

  final DrawingTool tool;
  final Key? measurementKey;
  final bool selected;
  final bool slashed;
  final bool muted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = switch (tool) {
      DrawingTool.ballpoint => '圆珠笔',
      DrawingTool.pencil => '铅笔',
      DrawingTool.highlighter => '荧光笔',
      DrawingTool.laser => '激光笔',
      DrawingTool.eraser => '橡皮',
      DrawingTool.lasso => '套索',
      DrawingTool.text => '文字',
      DrawingTool.browse => '浏览模式已开启',
    };
    return SizedBox(
      key: measurementKey,
      width: 48,
      height: 48,
      child: Semantics(
        button: true,
        label: label,
        selected: selected,
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          style: const ButtonStyle(
            splashFactory: NoSplash.splashFactory,
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: AnimatedOpacity(
            opacity: muted ? .38 : 1,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              width: selected ? 40 : 48,
              height: selected ? 40 : 48,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              decoration: selected
                  ? BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE1DED9)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                        BoxShadow(
                          color: Color(0xCCFFFFFF),
                          blurRadius: 2,
                          offset: Offset(0, -1),
                        ),
                      ],
                    )
                  : null,
              child: Center(
                child: _DrawingToolGlyph(
                  tool: tool,
                  selected: selected,
                  slashed: slashed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawingToolGlyph extends StatelessWidget {
  const _DrawingToolGlyph({
    required this.tool,
    this.selected = false,
    this.slashed = false,
  });

  final DrawingTool tool;
  final bool selected;
  final bool slashed;

  @override
  Widget build(BuildContext context) {
    final frozenAsset = switch (tool) {
      DrawingTool.ballpoint =>
        selected
            ? 'assets/icons/editor/draw_ballpoint_v5_selected.png'
            : 'assets/icons/editor/draw_ballpoint_v5_regular.png',
      DrawingTool.lasso =>
        selected
            ? 'assets/icons/editor/draw_lasso_v5_selected.png'
            : 'assets/icons/editor/draw_lasso_v5_regular.png',
      DrawingTool.pencil =>
        selected
            ? 'assets/icons/editor/draw_pencil_v6_selected.png'
            : 'assets/icons/editor/draw_pencil_v6_regular.png',
      DrawingTool.highlighter =>
        selected
            ? 'assets/icons/editor/draw_highlighter_v6_selected.png'
            : 'assets/icons/editor/draw_highlighter_v6_regular.png',
      DrawingTool.laser =>
        selected
            ? 'assets/icons/editor/laser_pointer_v1_selected.png'
            : 'assets/icons/editor/laser_pointer_v1_regular.png',
      DrawingTool.eraser =>
        selected
            ? 'assets/icons/editor/draw_eraser_v6_selected.png'
            : 'assets/icons/editor/draw_eraser_v6_regular.png',
      DrawingTool.text =>
        selected
            ? 'assets/icons/editor/draw_text_v6_selected.png'
            : 'assets/icons/editor/draw_text_v6_regular.png',
      // The user-selected browse source intentionally has no filled variant;
      // both states use the exact same outline asset.
      DrawingTool.browse => 'assets/icons/editor/draw_browse_v5_outline.png',
    };
    final image = Image.asset(
      frozenAsset,
      key: Key(
        'book_page_editor_draw_${tool.name}_${selected ? 'selected' : 'regular'}_asset',
      ),
      width: 32,
      height: 32,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    );
    if (!slashed) return image;
    return Stack(
      key: const Key('book_page_editor_draw_hand_slash'),
      alignment: Alignment.center,
      children: [
        image,
        Transform.rotate(
          angle: .68,
          child: Container(width: 28, height: 1.8, color: NotePageTheme.ink),
        ),
      ],
    );
  }
}

class _ToolOptionsCapsule extends StatelessWidget {
  const _ToolOptionsCapsule({
    this.surfaceKey,
    required this.tool,
    required this.eraserMode,
    required this.lassoMode,
    required this.pointerFraction,
    required this.controller,
    required this.onEraserMode,
    required this.onEraserRadius,
    required this.onClearPage,
    required this.onLassoMode,
    required this.onMoreColors,
  });

  final Key? surfaceKey;
  final DrawingTool tool;
  final EraserMode eraserMode;
  final LassoMode lassoMode;
  final double pointerFraction;
  final PageAnnotationToolController controller;
  final ValueChanged<EraserMode> onEraserMode;
  final ValueChanged<double> onEraserRadius;
  final VoidCallback onClearPage;
  final ValueChanged<LassoMode> onLassoMode;
  final VoidCallback onMoreColors;

  @override
  Widget build(BuildContext context) {
    final body = switch (tool) {
      DrawingTool.ballpoint ||
      DrawingTool.pencil ||
      DrawingTool.highlighter => _PenOptionsContent(
        tool: tool,
        selectedColor: controller.colorFor(tool),
        selectedWidth: controller.widthFor(tool),
        onColor: controller.setPenColor,
        onWidth: controller.setPenWidth,
        onMoreColors: onMoreColors,
      ),
      DrawingTool.laser => _PenOptionsContent(
        tool: tool,
        selectedColor: controller.colorFor(tool),
        selectedWidth: controller.widthFor(tool),
        onColor: controller.setPenColor,
        onWidth: controller.setPenWidth,
        onMoreColors: onMoreColors,
        showWidth: false,
      ),
      DrawingTool.eraser => _EraserOptionsContent(
        mode: eraserMode,
        onMode: onEraserMode,
        radius: controller.eraserRadius,
        onRadius: onEraserRadius,
        onClearPage: onClearPage,
      ),
      DrawingTool.lasso => _LassoOptionsContent(
        mode: lassoMode,
        onMode: onLassoMode,
      ),
      _ => const SizedBox.shrink(),
    };
    return _DrawingCapsuleSurface(
      key: surfaceKey,
      maxWidth: math.min(
        560.0,
        math.max(0.0, MediaQuery.sizeOf(context).width - 32),
      ),
      height: tool == DrawingTool.eraser ? 58 : 54,
      pointerFraction: pointerFraction,
      compact: true,
      child: body,
    );
  }
}

class _PenOptionsContent extends StatelessWidget {
  const _PenOptionsContent({
    required this.tool,
    required this.selectedColor,
    required this.selectedWidth,
    required this.onColor,
    required this.onWidth,
    required this.onMoreColors,
    this.showWidth = true,
  });

  final DrawingTool tool;
  final int selectedColor;
  final double selectedWidth;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onWidth;
  final VoidCallback onMoreColors;
  final bool showWidth;

  @override
  Widget build(BuildContext context) {
    final ink = Color(selectedColor);
    return SingleChildScrollView(
      key: ValueKey('book_page_editor_pen_options_content_${tool.name}'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          if (showWidth) ...[
            for (var index = 0; index < 4; index++) ...[
              _PenWidthButton(
                key: ValueKey('book_page_editor_pen_width_${tool.name}_$index'),
                width: tool == DrawingTool.highlighter
                    ? 8 + index * 4.0
                    : 1.1 + index * 1.2,
                color: ink,
                highlighter: tool == DrawingTool.highlighter,
                selected:
                    (selectedWidth -
                            (tool == DrawingTool.highlighter
                                ? 8 + index * 4.0
                                : 1.1 + index * 1.2))
                        .abs() <
                    .01,
                onPressed: () => onWidth(
                  tool == DrawingTool.highlighter
                      ? 8 + index * 4.0
                      : 1.1 + index * 1.2,
                ),
              ),
              if (index != 3) const SizedBox(width: 1),
            ],
            const SizedBox(width: 8),
            Container(width: 1, height: 24, color: NotePageTheme.line),
            const SizedBox(width: 8),
          ],
          for (final color in const [
            Color(0xFF1A1A1A),
            Color(0xFF3559A6),
            Color(0xFFC54237),
            Color(0xFF2E6B4E),
            Color(0xFFF6C945),
            Color(0xFFA6741E),
            Color(0xFF6E43A3),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _ColorDot(
                color: color,
                selected: selectedColor == color.toARGB32(),
                onPressed: () => onColor(color.toARGB32()),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: _ColorDot(color: null, onPressed: onMoreColors),
          ),
        ],
      ),
    );
  }
}

class _StrokeSamplePainter extends CustomPainter {
  const _StrokeSamplePainter({
    required this.color,
    required this.width,
    required this.highlighter,
  });

  final Color color;
  final double width;
  final bool highlighter;

  @override
  void paint(Canvas canvas, Size size) {
    final horizontalInset = math.min(size.width / 3, width / 2 + 1).toDouble();
    final startX = horizontalInset;
    final endX = size.width - horizontalInset;
    final centerY = size.height / 2;
    final availableVertical = math.max(0.0, size.height - width - 2).toDouble();
    final amplitude = math
        .min(size.height * .42, availableVertical * .45)
        .toDouble();
    final path = Path()
      ..moveTo(startX, centerY + amplitude * .2)
      ..cubicTo(
        startX + (endX - startX) * .18,
        centerY - amplitude,
        startX + (endX - startX) * .36,
        centerY - amplitude,
        startX + (endX - startX) * .46,
        centerY,
      )
      ..cubicTo(
        startX + (endX - startX) * .56,
        centerY + amplitude,
        startX + (endX - startX) * .75,
        centerY + amplitude,
        endX,
        centerY - amplitude * .2,
      );
    final paint = Paint()
      ..color = color.withValues(alpha: highlighter ? .42 : 1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokeSamplePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.highlighter != highlighter;
}

class _PenWidthButton extends StatelessWidget {
  const _PenWidthButton({
    super.key,
    required this.width,
    required this.color,
    required this.highlighter,
    required this.selected,
    required this.onPressed,
  });

  final double width;
  final Color color;
  final bool highlighter;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '线宽',
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size(highlighter ? 52 : 44, 44),
          padding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: selected
                ? BorderSide(
                    color: NotePageTheme.lineStrong.withValues(alpha: .8),
                  )
                : BorderSide.none,
          ),
        ),
        child: CustomPaint(
          size: Size(highlighter ? 44 : 36, highlighter ? 28 : 25),
          painter: _StrokeSamplePainter(
            color: color,
            width: width,
            highlighter: highlighter,
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.color,
    this.selected = false,
    this.onPressed,
  });

  final Color? color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: color == null ? '更多颜色' : '颜色',
      button: true,
      selected: selected,
      child: InkResponse(
        onTap: onPressed,
        radius: 27,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: selected ? 32 : 24,
              height: selected ? 32 : 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Colors.white : color,
                border: Border.all(
                  color: selected
                      ? NotePageTheme.ink
                      : NotePageTheme.lineStrong,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: color == null
                  ? Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          colors: [
                            Color(0xFFE53935),
                            Color(0xFFFFC107),
                            Color(0xFF43A047),
                            Color(0xFF1E88E5),
                            Color(0xFF8E24AA),
                            Color(0xFFE53935),
                          ],
                        ),
                      ),
                    )
                  : selected
                  ? Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineTextColorPicker extends StatefulWidget {
  const _InlineTextColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<int> onChanged;

  @override
  State<_InlineTextColorPicker> createState() => _InlineTextColorPickerState();
}

class _InlineTextColorPickerState extends State<_InlineTextColorPicker> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
  }

  @override
  void didUpdateWidget(covariant _InlineTextColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _hsv = HSVColor.fromColor(widget.color);
    }
  }

  void _setColor(HSVColor color) {
    setState(() => _hsv = color);
    widget.onChanged(color.toColor().toARGB32());
  }

  void _setSaturationAndValue(Offset localPosition, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final saturation = (localPosition.dx / size.width)
        .clamp(0.0, 1.0)
        .toDouble();
    final value = (1 - localPosition.dy / size.height)
        .clamp(0.0, 1.0)
        .toDouble();
    _setColor(HSVColor.fromAHSV(1, _hsv.hue, saturation, value));
  }

  void _setHue(Offset localPosition, Size size) {
    if (size.height <= 0) return;
    final hue = (localPosition.dy / size.height * 360)
        .clamp(0.0, 359.9)
        .toDouble();
    _setColor(HSVColor.fromAHSV(1, hue, _hsv.saturation, _hsv.value));
  }

  String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final preview = _hsv.toColor();
    return _TextEditorGlassSurface(
      key: const Key('book_page_editor_text_custom_color_surface'),
      borderRadius: 22,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: preview,
                    shape: BoxShape.circle,
                    border: Border.all(color: NotePageTheme.lineStrong),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '自定义颜色',
                        style: TextStyle(
                          color: NotePageTheme.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '点按或拖动，文字会同步更新',
                        style: TextStyle(
                          color: NotePageTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _hex(preview),
                  style: const TextStyle(
                    color: NotePageTheme.inkSecondary,
                    fontSize: 12,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (_, _) {
                const hueWidth = 24.0;
                const gap = 10.0;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildSaturationValuePicker()),
                    const SizedBox(width: gap),
                    SizedBox(width: hueWidth, child: _buildHuePicker()),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaturationValuePicker() {
    return LayoutBuilder(
      builder: (_, constraints) {
        const height = 148.0;
        final size = Size(constraints.maxWidth, height);
        final hueColor = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
        final markerLeft = (_hsv.saturation * size.width - 14)
            .clamp(0.0, math.max(0.0, size.width - 28))
            .toDouble();
        final markerTop = ((1 - _hsv.value) * size.height - 14)
            .clamp(0.0, size.height - 28)
            .toDouble();
        return SizedBox(
          height: height,
          child: GestureDetector(
            key: const Key('book_page_editor_text_color_field'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) =>
                _setSaturationAndValue(details.localPosition, size),
            onPanUpdate: (details) =>
                _setSaturationAndValue(details.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.white, hueColor],
                        ),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: markerLeft,
                    top: markerTop,
                    child: IgnorePointer(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Color(0x66000000), blurRadius: 3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHuePicker() {
    return LayoutBuilder(
      builder: (_, constraints) {
        const height = 148.0;
        final size = Size(constraints.maxWidth, height);
        final hueColors = [
          for (final hue in const [
            0.0,
            60.0,
            120.0,
            180.0,
            240.0,
            300.0,
            360.0,
          ])
            HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
        ];
        final markerTop = (_hsv.hue / 360 * size.height - 3)
            .clamp(0.0, size.height - 6)
            .toDouble();
        return SizedBox(
          height: height,
          child: GestureDetector(
            key: const Key('book_page_editor_text_hue_field'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _setHue(details.localPosition, size),
            onPanUpdate: (details) => _setHue(details.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: hueColors,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: -2,
                    right: -2,
                    top: markerTop,
                    height: 6,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: const [
                            BoxShadow(color: Color(0x66000000), blurRadius: 2),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EraserOptionsContent extends StatelessWidget {
  const _EraserOptionsContent({
    required this.mode,
    required this.onMode,
    required this.radius,
    required this.onRadius,
    required this.onClearPage,
  });

  final EraserMode mode;
  final ValueChanged<EraserMode> onMode;
  final double radius;
  final ValueChanged<double> onRadius;
  final VoidCallback onClearPage;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('book_page_editor_eraser_options_content'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 12),
        _OptionTextButton(
          key: const Key('book_page_editor_eraser_free'),
          label: '自由擦除',
          icon: Icons.auto_fix_normal_outlined,
          selected: mode == EraserMode.free,
          onPressed: () => onMode(EraserMode.free),
        ),
        _OptionTextButton(
          key: const Key('book_page_editor_eraser_stroke'),
          label: '整笔擦除',
          icon: Icons.cleaning_services_outlined,
          selected: mode == EraserMode.stroke,
          onPressed: () => onMode(EraserMode.stroke),
        ),
        const SizedBox(width: 4),
        Container(width: 1, height: 30, color: NotePageTheme.line),
        for (final size in const [14.0, 22.0, 30.0])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: _EraserSizeButton(
              size: size,
              selected: (radius - size).abs() < .01,
              onPressed: () => onRadius(size),
            ),
          ),
        Container(width: 1, height: 30, color: NotePageTheme.line),
        _OptionTextButton(
          label: '清空本页',
          icon: Icons.delete_outline,
          selected: false,
          onPressed: onClearPage,
        ),
        const SizedBox(width: 12),
      ],
    );
  }
}

class _EraserSizeButton extends StatelessWidget {
  const _EraserSizeButton({
    required this.size,
    required this.selected,
    required this.onPressed,
  });

  final double size;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '擦除范围',
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: selected
                ? BorderSide(
                    color: NotePageTheme.lineStrong.withValues(alpha: .8),
                  )
                : BorderSide.none,
          ),
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: NotePageTheme.ink, width: 1.4),
          ),
        ),
      ),
    );
  }
}

class _InkColorPickerDialog extends StatefulWidget {
  const _InkColorPickerDialog({required this.initialColor});

  final int initialColor;

  @override
  State<_InkColorPickerDialog> createState() => _InkColorPickerDialogState();
}

class _InkColorPickerDialogState extends State<_InkColorPickerDialog> {
  late int _color;
  late final TextEditingController _hexController;
  late double _hue;
  late double _saturation;
  late double _value;

  static const _palette = [
    [
      0xFF1A1A1A,
      0xFF333333,
      0xFF666666,
      0xFF999999,
      0xFFCCCCCC,
      0xFFEFEFEF,
      0xFFFFFFFF,
    ],
    [
      0xFF8E1B13,
      0xFFC54237,
      0xFFE05A4F,
      0xFFED8C83,
      0xFFF4B4AE,
      0xFFF8D5D1,
      0xFFFFEFED,
    ],
    [
      0xFF8A4F16,
      0xFFC3771E,
      0xFFE4A04B,
      0xFFF0BE77,
      0xFFF5D09D,
      0xFFF9E4C7,
      0xFFFFF3E4,
    ],
    [
      0xFFB58C00,
      0xFFE2BD16,
      0xFFF6D54A,
      0xFFF7E77E,
      0xFFFAF2B0,
      0xFFFFF9D4,
      0xFFFFFDEB,
    ],
    [
      0xFF176C3C,
      0xFF2E9A5B,
      0xFF53BD78,
      0xFF80D09B,
      0xFFAADFB9,
      0xFFD2F0DA,
      0xFFEFFAF1,
    ],
    [
      0xFF1E4C8E,
      0xFF3559A6,
      0xFF5D82C3,
      0xFF88A9D7,
      0xFFB4C9E8,
      0xFFDCE6F5,
      0xFFF3F7FD,
    ],
    [
      0xFF4C258C,
      0xFF6E43A3,
      0xFF956DC3,
      0xFFB79ADA,
      0xFFD1BCEA,
      0xFFE8DFF6,
      0xFFF8F3FE,
    ],
    [
      0xFF8B1D52,
      0xFFB52F6D,
      0xFFD35687,
      0xFFE183A6,
      0xFFEDA9C1,
      0xFFF6D0DD,
      0xFFFFEEF4,
    ],
  ];

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
    final hsv = HSVColor.fromColor(Color(_color));
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
    _hexController = TextEditingController(text: _hex(_color));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _hex(int value) =>
      '#${value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _setColor(int value) {
    final hsv = HSVColor.fromColor(Color(value | 0xFF000000));
    setState(() {
      _color = value | 0xFF000000;
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _value = hsv.value;
      _hexController.text = _hex(_color);
    });
  }

  void _setFromHsv({double? hue, double? saturation, double? value}) {
    final nextHue = hue ?? _hue;
    final nextSaturation = saturation ?? _saturation;
    final nextValue = value ?? _value;
    final color = HSVColor.fromAHSV(
      1,
      nextHue,
      nextSaturation,
      nextValue,
    ).toColor();
    setState(() {
      _hue = nextHue;
      _saturation = nextSaturation;
      _value = nextValue;
      _color = color.value | 0xFF000000;
      _hexController.text = _hex(_color);
    });
  }

  void _updateColorField(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _setFromHsv(
      saturation: (local.dx / size.width).clamp(0, 1).toDouble(),
      value: (1 - local.dy / size.height).clamp(0, 1).toDouble(),
    );
  }

  void _updateHue(Offset local, Size size) {
    if (size.width <= 0) return;
    _setFromHsv(hue: (local.dx / size.width * 360).clamp(0, 359.99));
  }

  int? _parseHex(String value) {
    final normalized = value.trim().replaceFirst('#', '');
    if (normalized.length != 6 && normalized.length != 8) return null;
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return null;
    return normalized.length == 6 ? parsed | 0xFF000000 : parsed;
  }

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    final dialogWidth = (mediaSize.width * .73).clamp(280.0, 520.0).toDouble();
    final maxHeight = mediaSize.height * .86;
    return Dialog(
      key: const Key('book_page_editor_color_picker'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 34,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        '选择颜色',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF222222),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 34,
                            height: 34,
                          ),
                          icon: const Icon(Icons.close, size: 26),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Semantics(
                          label: '取色器（暂未开放）',
                          child: Icon(
                            Icons.colorize_outlined,
                            size: 25,
                            color: const Color(0xFF222222),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '预设颜色',
                  style: TextStyle(fontSize: 14, color: Color(0xFF333333)),
                ),
                const SizedBox(height: 8),
                for (final row in _palette) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final value in row)
                        _PaletteColorButton(
                          color: Color(value),
                          selected: _color == (value | 0xFF000000),
                          onPressed: () => _setColor(value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                ],
                const Padding(
                  padding: EdgeInsets.only(top: 7, bottom: 14),
                  child: Divider(height: 1, color: Color(0xFFE0E0E0)),
                ),
                const Text(
                  '自定义颜色',
                  style: TextStyle(fontSize: 14, color: Color(0xFF333333)),
                ),
                const SizedBox(height: 9),
                GestureDetector(
                  onPanDown: (details) => _updateColorField(
                    details.localPosition,
                    Size(dialogWidth - 44, 84),
                  ),
                  onPanUpdate: (details) => _updateColorField(
                    details.localPosition,
                    Size(dialogWidth - 44, 84),
                  ),
                  child: SizedBox(
                    height: 84,
                    child: CustomPaint(
                      painter: _ColorFieldPainter(
                        hue: _hue,
                        saturation: _saturation,
                        value: _value,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onPanDown: (details) => _updateHue(
                    details.localPosition,
                    Size(dialogWidth - 44, 14),
                  ),
                  onPanUpdate: (details) => _updateHue(
                    details.localPosition,
                    Size(dialogWidth - 44, 14),
                  ),
                  child: SizedBox(
                    height: 18,
                    child: CustomPaint(painter: _HueSliderPainter(hue: _hue)),
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(_color),
                        border: Border.all(color: const Color(0xFF222222)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _hexController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(
                              color: Color(0xFFB8B8B8),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          final parsed = _parseHex(value);
                          if (parsed != null) _setColor(parsed);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF222222),
                        minimumSize: const Size(70, 44),
                      ),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, _color),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3D3D3D),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(126, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('使用此颜色'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton({
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '预设颜色',
      child: GestureDetector(
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: Container(
              width: selected ? 28 : 22,
              height: selected ? 28 : 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF5E5E5E)
                      : color.computeLuminance() > .86
                      ? const Color(0xFFD2D2D2)
                      : Colors.transparent,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorFieldPainter extends CustomPainter {
  const _ColorFieldPainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  final double hue;
  final double saturation;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final baseColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, baseColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final point = Offset(
      saturation.clamp(0, 1) * size.width,
      (1 - value.clamp(0, 1)) * size.height,
    );
    canvas.drawCircle(
      point,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      point,
      9.5,
      Paint()
        ..color = const Color(0xAA555555)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorFieldPainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value;
}

class _HueSliderPainter extends CustomPainter {
  const _HueSliderPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    final colors = [
      for (var index = 0; index <= 6; index++)
        HSVColor.fromAHSV(1, index * 60.0, 1, 1).toColor(),
    ];
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: colors,
        ).createShader(Offset.zero & size),
    );
    final x = (hue.clamp(0, 360) / 360) * size.width;
    canvas.drawCircle(
      Offset(x, size.height / 2),
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(x, size.height / 2),
      8,
      Paint()
        ..color = const Color(0xFF777777)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _HueSliderPainter oldDelegate) =>
      oldDelegate.hue != hue;
}

class _LassoOptionsContent extends StatelessWidget {
  const _LassoOptionsContent({required this.mode, required this.onMode});

  final LassoMode mode;
  final ValueChanged<LassoMode> onMode;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 12),
        _OptionTextButton(
          key: const Key('book_page_editor_lasso_free'),
          label: '自由套索',
          icon: Icons.gesture_outlined,
          selected: mode == LassoMode.free,
          onPressed: () => onMode(LassoMode.free),
        ),
        _OptionTextButton(
          key: const Key('book_page_editor_lasso_rectangle'),
          label: '矩形框选',
          icon: Icons.crop_free,
          selected: mode == LassoMode.rectangle,
          onPressed: () => onMode(LassoMode.rectangle),
        ),
        _OptionTextButton(
          key: const Key('book_page_editor_lasso_all'),
          label: '全选本页',
          icon: Icons.select_all,
          selected: mode == LassoMode.all,
          onPressed: () => onMode(LassoMode.all),
        ),
        const SizedBox(width: 12),
      ],
    );
  }
}

class _TextChoiceButton extends StatelessWidget {
  const _TextChoiceButton({
    super.key,
    required this.label,
    required this.style,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final TextStyle style;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: NotePageTheme.ink,
          minimumSize: const Size(0, 44),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: selected
              ? Colors.white.withValues(alpha: .62)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: selected
                ? BorderSide(
                    color: NotePageTheme.lineStrong.withValues(alpha: .7),
                  )
                : BorderSide.none,
          ),
        ),
        child: Text(label, style: style),
      ),
    );
  }
}

class _OptionTextButton extends StatelessWidget {
  const _OptionTextButton({
    super.key,
    required this.label,
    required this.icon,
    this.selected = false,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 22),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: NotePageTheme.ink,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          backgroundColor: selected
              ? const Color(0xFFF8F6F2)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: selected
                ? BorderSide(
                    color: NotePageTheme.lineStrong.withValues(alpha: .8),
                  )
                : BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _TextContextAction extends StatelessWidget {
  const _TextContextAction({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(NotePageTheme.ink),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: selected ? 18 : 0,
              height: 2,
              decoration: BoxDecoration(
                color: NotePageTheme.ink,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextEditorGlassSurface extends StatelessWidget {
  const _TextEditorGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.height,
  });

  final Widget child;
  final double borderRadius;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .94),
        border: Border.all(color: const Color(0xFFD9DEE3)),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 9,
            offset: Offset(0, 4),
          ),
          BoxShadow(
            color: Color(0xD9FFFFFF),
            blurRadius: 2,
            offset: Offset(0, -1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius - 1),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: child,
        ),
      ),
    );
    return height == null ? surface : SizedBox(height: height, child: surface);
  }
}

class _TextTransformActionButton extends StatelessWidget {
  const _TextTransformActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Material(
            color: Colors.white.withValues(alpha: .96),
            elevation: 1.5,
            shadowColor: const Color(0x24000000),
            shape: const CircleBorder(
              side: BorderSide(color: Color(0xFFD9DEE3)),
            ),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(icon, size: 16, color: NotePageTheme.ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TextTransformHandleIndicator extends StatelessWidget {
  const _TextTransformHandleIndicator({super.key, required this.rotation});

  final double rotation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Transform.rotate(
          angle: rotation,
          child: Material(
            color: Colors.white.withValues(alpha: .96),
            elevation: 1.5,
            shadowColor: const Color(0x24000000),
            shape: const CircleBorder(
              side: BorderSide(color: Color(0xFFD9DEE3)),
            ),
            child: const SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                Icons.open_in_full,
                size: 16,
                color: NotePageTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawingCapsuleSurface extends StatelessWidget {
  const _DrawingCapsuleSurface({
    super.key,
    required this.child,
    required this.maxWidth,
    required this.height,
    this.pointerFraction,
    this.compact = false,
  });

  final Widget child;
  final double maxWidth;
  final double height;
  final double? pointerFraction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: compact ? const Color(0xFFFCFBF8) : Colors.white,
        border: Border.all(color: const Color(0xFFE6E3DF)),
        borderRadius: BorderRadius.circular(compact ? 18 : 29),
        boxShadow: compact
            ? const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x18000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
                BoxShadow(
                  color: Color(0xBFFFFFFF),
                  blurRadius: 2,
                  offset: Offset(0, -1),
                ),
              ],
      ),
      child: SizedBox(height: height, child: child),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 0),
        child: pointerFraction == null
            ? surface
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  surface,
                  Positioned(
                    top: -5,
                    left: 0,
                    right: 0,
                    child: Align(
                      alignment: Alignment(
                        (pointerFraction!.clamp(0, 1).toDouble() * 2) - 1,
                        0,
                      ),
                      child: CustomPaint(
                        size: const Size(14, 6),
                        painter: _CapsulePointerPainter(
                          color: compact
                              ? const Color(0xFFFCFBF8)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CapsulePointerPainter extends CustomPainter {
  const _CapsulePointerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..quadraticBezierTo(size.width * .35, size.height * .5, 0, size.height)
      ..lineTo(size.width, size.height)
      ..quadraticBezierTo(size.width * .65, size.height * .5, size.width / 2, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    final edgePath = Path()
      ..moveTo(size.width / 2, 0)
      ..quadraticBezierTo(size.width * .35, size.height * .5, 0, size.height)
      ..moveTo(size.width / 2, 0)
      ..quadraticBezierTo(
        size.width * .65,
        size.height * .5,
        size.width,
        size.height,
      );
    canvas.drawPath(
      edgePath,
      Paint()
        ..color = const Color(0xFFE6E3DF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _CapsulePointerPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _EditorCanvas extends StatelessWidget {
  const _EditorCanvas({
    super.key,
    required this.page,
    required this.pageIndex,
    required this.bodyFieldKey,
    required this.pageContentKey,
    required this.annotationLayerKey,
    required this.saveLabel,
    required this.keyboardInsetListenable,
    required this.annotationDocument,
    required this.imageStore,
    required this.imageEditor,
    required this.drawingEnabled,
    required this.pageLocked,
    required this.isActivePage,
    required this.liveEditableBlockIds,
    required this.pendingFocusBlockId,
    required this.onPromoteBlock,
    required this.annotationTools,
    required this.onLaserSelection,
    required this.onAnnotationChanged,
    required this.onAnnotationAction,
    required this.onOriginal,
    this.pdfDocumentRef,
    this.pdfController,
    this.pdfPageNumber,
    this.pdfPaginationModeListenable,
    this.activePdfTextBlockIdListenable,
    this.onPdfInteractionStart,
    this.onPdfInteractionEnd,
    this.onPdfPageChanged,
    this.onPdfTextFocus,
  });

  final _BookPageDraft page;
  final int pageIndex;
  final GlobalKey bodyFieldKey;
  final GlobalKey pageContentKey;
  final GlobalKey annotationLayerKey;
  final String saveLabel;
  final ValueListenable<double> keyboardInsetListenable;
  final PageAnnotationDocument annotationDocument;
  final PageImageAssetStore imageStore;
  final PageImageEditorController imageEditor;
  final bool drawingEnabled;
  final bool pageLocked;
  final bool isActivePage;

  /// 本页允许立即创建真实输入框的块 id（见 `_BookPageDraft.liveTextFieldBudget`）。
  final Set<int> liveEditableBlockIds;

  /// 刚刚被点开、需要在下一帧获得焦点的块 id。
  final int? pendingFocusBlockId;

  /// 用户点开一个只读块时把它切换成输入框。
  final ValueChanged<int> onPromoteBlock;
  final PageAnnotationToolController annotationTools;
  final ValueChanged<List<Offset>> onLaserSelection;
  final ValueChanged<PageAnnotationDocument> onAnnotationChanged;
  final ValueChanged<_AnnotationAction> onAnnotationAction;
  final VoidCallback onOriginal;
  final PdfDocumentRef? pdfDocumentRef;
  final PdfViewerController? pdfController;
  final int? pdfPageNumber;
  final ValueListenable<ReaderPaginationMode>? pdfPaginationModeListenable;
  final ValueNotifier<int?>? activePdfTextBlockIdListenable;
  final GestureScaleStartCallback? onPdfInteractionStart;
  final GestureScaleEndCallback? onPdfInteractionEnd;
  final ValueChanged<int?>? onPdfPageChanged;
  final PdfPageTextFocusCallback? onPdfTextFocus;

  Widget _editableBlock(
    BuildContext context,
    OcrBlock block,
    TextStyle style,
    FocusNode? focusNode,
  ) {
    final pdfMode = pdfDocumentRef != null;
    if (!pdfMode && block.isTitle) {
      style = style.copyWith(
        color: NotePageTheme.ink,
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w700,
      );
    }
    if (!pdfMode && block.type == 'code') {
      style = style.copyWith(fontFamily: 'monospace', fontSize: 14);
    }
    final controller = block.isTitle
        ? page.titleController
        : page.blockControllers[block.id];
    if (controller == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(block.text, style: style),
      );
    }
    final readOnly =
        !isActivePage || (drawingEnabled && !annotationTools.isBrowseMode);
    final liveEditable =
        pdfMode || block.isTitle || liveEditableBlockIds.contains(block.id);
    final field = liveEditable
        ? BookTextSelectionBackdrop(
            controller: controller,
            child: TextSelectionTheme(
              data: const TextSelectionThemeData(
                selectionColor:
                    BookPencilTextSelectionControls.editableSelectionColor,
              ),
              child: TextField(
                key: Key(
                  block.isTitle
                      ? 'book_page_editor_title_$pageIndex'
                      : 'book_page_editor_block_${block.id}',
                ),
                controller: controller,
                focusNode: pdfMode ? focusNode : null,
                autofocus:
                    !readOnly &&
                    (pdfMode
                        ? focusNode != null
                        : pendingFocusBlockId == block.id),
                onTap: pdfMode && focusNode != null
                    ? focusNode.requestFocus
                    : null,
                readOnly: readOnly,
                maxLines: null,
                minLines: block.isTitle ? 1 : 1,
                style: style,
                showCursor: !readOnly,
                cursorColor: BookPencilTextSelectionControls.cursorColor,
                cursorWidth: 1.5,
                cursorRadius: Radius.zero,
                selectionControls: bookPencilTextSelectionControls,
                selectionHeightStyle: ui.BoxHeightStyle.tight,
                selectionWidthStyle: ui.BoxWidthStyle.tight,
                scrollPadding: EdgeInsets.zero,
                scrollPhysics: pdfMode
                    ? const NeverScrollableScrollPhysics()
                    : null,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: block.isTitle ? '书页标题' : '正文',
                  hintStyle: const TextStyle(color: NotePageTheme.muted),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          )
        : _pendingEditableBlock(block, style, controller);
    if (pdfMode) return field;
    if (block.type == 'quote') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          color: NotePageTheme.ochreSoft,
          border: Border.fromBorderSide(
            BorderSide(color: NotePageTheme.ochre, width: 1.2),
          ),
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        child: field,
      );
    }
    if (block.type == 'list_item') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ', style: style),
            Expanded(child: field),
          ],
        ),
      );
    }
    if (block.type == 'code') {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F1F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: field,
      );
    }
    return Padding(
      key: Key('book_page_editor_block_surface_${block.id}'),
      padding: EdgeInsets.only(
        top: block.isTitle ? 10 : 5,
        bottom: block.isTitle ? 7 : 5,
      ),
      child: field,
    );
  }

  /// 超出输入框预算的块先按同样的排版渲染成文本，用户点一下再切换成真实输入框。
  /// 一页的构建成本因此只跟预算内的内容有关，而不是整章块数。
  Widget _pendingEditableBlock(
    OcrBlock block,
    TextStyle style,
    TextEditingController controller,
  ) {
    final text = controller.text;
    final isEmpty = text.trim().isEmpty;
    return GestureDetector(
      key: Key('book_page_editor_block_pending_${block.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onPromoteBlock(block.id),
      child: Text(
        isEmpty ? (block.isTitle ? '书页标题' : '正文') : text,
        style: isEmpty ? style.copyWith(color: NotePageTheme.muted) : style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (page.note.pdfPath.trim().isNotEmpty &&
        pdfDocumentRef != null &&
        pdfController != null) {
      return _PdfEditorCanvas(
        page: page,
        bodyFieldKey: bodyFieldKey,
        annotationLayerKey: annotationLayerKey,
        annotationDocument: annotationDocument,
        imageStore: imageStore,
        imageEditor: imageEditor,
        drawingEnabled: drawingEnabled,
        pageLocked: pageLocked,
        isActivePage: isActivePage,
        annotationTools: annotationTools,
        onLaserSelection: onLaserSelection,
        onAnnotationChanged: onAnnotationChanged,
        onAnnotationAction: onAnnotationAction,
        pdfDocumentRef: pdfDocumentRef!,
        pdfController: pdfController!,
        pdfPageNumber: pdfPageNumber ?? int.tryParse(page.note.bookPage) ?? 1,
        pdfPaginationModeListenable: pdfPaginationModeListenable,
        activePdfTextBlockIdListenable: activePdfTextBlockIdListenable,
        onPdfInteractionStart: onPdfInteractionStart,
        onPdfInteractionEnd: onPdfInteractionEnd,
        onPdfPageChanged: onPdfPageChanged,
        onPdfTextFocus: onPdfTextFocus,
      );
    }
    const titleStyle = TextStyle(
      color: NotePageTheme.ink,
      fontFamily: NotePageTheme.bookFont,
      fontSize: 28,
      height: 1.25,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.none,
      decorationColor: Colors.transparent,
    );
    const bodyStyle = TextStyle(
      color: NotePageTheme.bookText,
      fontFamily: NotePageTheme.bookFont,
      fontSize: 17,
      height: 1.8,
      decoration: TextDecoration.none,
      decorationColor: Colors.transparent,
    );
    final pageNumber = page.document.pageNumber?.trim().isNotEmpty == true
        ? page.document.pageNumber!.trim()
        : page.note.bookPage.trim();
    final mediaSize = MediaQuery.sizeOf(context);
    final topViewPadding = MediaQuery.viewPaddingOf(context).top;
    final stableViewportHeight =
        mediaSize.height - topViewPadding - _EditorToolbar.height;
    final stableContentMinHeight = (stableViewportHeight - 50)
        .clamp(0.0, double.infinity)
        .toDouble();
    const contentTopPadding = 18.0;
    return ColoredBox(
      color: NotePageTheme.card,
      child: Scrollbar(
        controller: page.scrollController,
        thumbVisibility: mediaSize.width >= 600,
        child: SingleChildScrollView(
          key: Key('book_page_editor_scroll_$pageIndex'),
          controller: page.scrollController,
          physics: pageLocked ? const NeverScrollableScrollPhysics() : null,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          // This viewport and its text layout stay fixed during IME motion.
          // Only the leaf spacer below changes scroll extent.
          // Keep the scroll viewport full width so the annotation layer can
          // receive and paint strokes in the page margins. The text column
          // applies its own horizontal inset below.
          padding: EdgeInsets.only(top: contentTopPadding, bottom: 32),
          child: RepaintBoundary(
            key: pageContentKey,
            child: Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: stableContentMinHeight,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${_formatDate(page.note.updatedAt)} · $saveLabel',
                                key: Key(
                                  'book_page_editor_save_state_$pageIndex',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.left,
                                style: const TextStyle(
                                  color: NotePageTheme.muted,
                                  fontSize: 13,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                key: Key('book_page_editor_source_$pageIndex'),
                                onPressed: onOriginal,
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  minimumSize: const Size(0, 36),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text:
                                            '来源：书页 ${pageNumber.isNotEmpty ? pageNumber : '未标页码'}  ',
                                      ),
                                      const TextSpan(
                                        text: '查看原文',
                                        style: TextStyle(
                                          color: NotePageTheme.gold,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: NotePageTheme.inkSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (page.hasUnsupportedLayout) ...[
                        SizedBox(
                          key: bodyFieldKey,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: BookPageDocumentView(
                              document: page.document,
                              editableTextBuilder: isActivePage
                                  ? _editableBlock
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          page.editableBlockCount >
                                  page.liveEditableBlockIds.length
                              ? '图表、图片、表格和公式保持原位。这一章内容很长，为保持流畅正文按需进入编辑状态：点一下要修改的段落即可编辑。'
                              : '图表、图片、表格和公式保持原位，前后文字可直接修改。',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: NotePageTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ] else ...[
                        if (isActivePage)
                          BookTextSelectionBackdrop(
                            controller: page.titleController,
                            child: TextSelectionTheme(
                              data: const TextSelectionThemeData(
                                selectionColor: BookPencilTextSelectionControls
                                    .editableSelectionColor,
                              ),
                              child: TextField(
                                key: Key('book_page_editor_title_$pageIndex'),
                                controller: page.titleController,
                                readOnly:
                                    drawingEnabled &&
                                    !annotationTools.isBrowseMode,
                                maxLines: null,
                                style: titleStyle,
                                showCursor: true,
                                cursorColor:
                                    BookPencilTextSelectionControls.cursorColor,
                                cursorWidth: 1.5,
                                cursorRadius: Radius.zero,
                                selectionControls:
                                    bookPencilTextSelectionControls,
                                selectionHeightStyle: ui.BoxHeightStyle.tight,
                                selectionWidthStyle: ui.BoxWidthStyle.tight,
                                scrollPadding: EdgeInsets.zero,
                                decoration: const InputDecoration.collapsed(
                                  hintText: '书页标题',
                                  hintStyle: TextStyle(
                                    color: NotePageTheme.muted,
                                    fontFamily: NotePageTheme.bookFont,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Text(
                            page.titleController.text,
                            key: Key('book_page_editor_title_$pageIndex'),
                            style: titleStyle,
                          ),
                        const SizedBox(height: 22),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: isActivePage
                              ? SizedBox(
                                  key: bodyFieldKey,
                                  child: BookTextSelectionBackdrop(
                                    controller: page.bodyController,
                                    child: TextSelectionTheme(
                                      data: const TextSelectionThemeData(
                                        selectionColor:
                                            BookPencilTextSelectionControls
                                                .editableSelectionColor,
                                      ),
                                      child: TextField(
                                        key: Key(
                                          'book_page_editor_body_$pageIndex',
                                        ),
                                        controller: page.bodyController,
                                        readOnly:
                                            drawingEnabled &&
                                            !annotationTools.isBrowseMode,
                                        maxLines: null,
                                        minLines: 13,
                                        style: bodyStyle,
                                        showCursor: true,
                                        cursorColor:
                                            BookPencilTextSelectionControls
                                                .cursorColor,
                                        cursorWidth: 1.5,
                                        cursorRadius: Radius.zero,
                                        selectionControls:
                                            bookPencilTextSelectionControls,
                                        selectionHeightStyle:
                                            ui.BoxHeightStyle.tight,
                                        selectionWidthStyle:
                                            ui.BoxWidthStyle.tight,
                                        scrollPadding: EdgeInsets.zero,
                                        textAlignVertical:
                                            TextAlignVertical.top,
                                        decoration: const InputDecoration(
                                          hintText: '正文',
                                          hintStyle: TextStyle(
                                            color: NotePageTheme.muted,
                                            fontFamily: NotePageTheme.bookFont,
                                          ),
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 13 * 17 * 1.8,
                                  ),
                                  child: Text(
                                    page.bodyController.text,
                                    key: Key(
                                      'book_page_editor_body_$pageIndex',
                                    ),
                                    style: bodyStyle,
                                  ),
                                ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      if (pageNumber.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Center(
                          child: Text(
                            '— $pageNumber —',
                            style: const TextStyle(
                              color: NotePageTheme.muted,
                              fontFamily: NotePageTheme.bookFont,
                              fontSize: 13,
                              letterSpacing: 1.4,
                            ),
                          ),
                        ),
                      ],
                      ValueListenableBuilder<double>(
                        valueListenable: keyboardInsetListenable,
                        builder: (context, inset, _) => SizedBox(
                          key: Key(
                            'book_page_editor_keyboard_space_$pageIndex',
                          ),
                          height: pageLocked ? 0 : inset,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: _PageAnnotationLayer(
                  layerKey: annotationLayerKey,
                  document: annotationDocument,
                  controller: annotationTools,
                  imageStore: imageStore,
                  imageEditor: imageEditor,
                  enabled: drawingEnabled,
                  isActivePage: isActivePage,
                  onChanged: onAnnotationChanged,
                  onAction: onAnnotationAction,
                  onLaserSelection: onLaserSelection,
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

class _PdfEditorCanvas extends StatelessWidget {
  const _PdfEditorCanvas({
    required this.page,
    required this.bodyFieldKey,
    required this.annotationLayerKey,
    required this.annotationDocument,
    required this.imageStore,
    required this.imageEditor,
    required this.drawingEnabled,
    required this.pageLocked,
    required this.isActivePage,
    required this.annotationTools,
    required this.onLaserSelection,
    required this.onAnnotationChanged,
    required this.onAnnotationAction,
    required this.pdfDocumentRef,
    required this.pdfController,
    required this.pdfPageNumber,
    this.pdfPaginationModeListenable,
    this.activePdfTextBlockIdListenable,
    this.onPdfInteractionStart,
    this.onPdfInteractionEnd,
    this.onPdfPageChanged,
    this.onPdfTextFocus,
  });

  final _BookPageDraft page;
  final GlobalKey bodyFieldKey;
  final GlobalKey annotationLayerKey;
  final PageAnnotationDocument annotationDocument;
  final PageImageAssetStore imageStore;
  final PageImageEditorController imageEditor;
  final bool drawingEnabled;
  final bool pageLocked;
  final bool isActivePage;
  final PageAnnotationToolController annotationTools;
  final ValueChanged<List<Offset>> onLaserSelection;
  final ValueChanged<PageAnnotationDocument> onAnnotationChanged;
  final ValueChanged<_AnnotationAction> onAnnotationAction;
  final PdfDocumentRef pdfDocumentRef;
  final PdfViewerController pdfController;
  final int pdfPageNumber;
  final ValueListenable<ReaderPaginationMode>? pdfPaginationModeListenable;
  final ValueNotifier<int?>? activePdfTextBlockIdListenable;
  final GestureScaleStartCallback? onPdfInteractionStart;
  final GestureScaleEndCallback? onPdfInteractionEnd;
  final ValueChanged<int?>? onPdfPageChanged;
  final PdfPageTextFocusCallback? onPdfTextFocus;

  @override
  Widget build(BuildContext context) {
    final modeListenable = pdfPaginationModeListenable;
    if (modeListenable == null) return _buildCanvas(true);
    return ValueListenableBuilder<ReaderPaginationMode>(
      valueListenable: modeListenable,
      builder: (_, mode, _) =>
          _buildCanvas(mode == ReaderPaginationMode.horizontal),
    );
  }

  Widget _buildCanvas(bool horizontal) {
    return ColoredBox(
      color: NotePageTheme.card,
      child: Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: bodyFieldKey,
            child: PdfPageCanvas(
              documentRef: pdfDocumentRef,
              controller: pdfController,
              document: page.document,
              initialPageNumber: pdfPageNumber,
              pageLocked: pageLocked,
              margin: 0,
              horizontal: horizontal,
              layoutPages: horizontal ? horizontalPdfPageLayout : null,
              // PDF pages remain readable in the note editor, but their OCR
              // text layer is intentionally not an editable input surface.
              editable: false,
              editableTextBuilder: null,
              annotationLayerBuilder: (_, _, pdfPage) {
                if (pdfPage.pageNumber != pdfPageNumber) return null;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    _PageAnnotationLayer(
                      key: ValueKey(
                        'pdf-annotation-page-${pdfPage.pageNumber}',
                      ),
                      layerKey: annotationLayerKey,
                      document: annotationDocument,
                      controller: annotationTools,
                      imageStore: imageStore,
                      imageEditor: imageEditor,
                      enabled: drawingEnabled,
                      isActivePage: isActivePage,
                      onChanged: onAnnotationChanged,
                      onAction: onAnnotationAction,
                      onLaserSelection: onLaserSelection,
                    ),
                  ],
                );
              },
              activeTextBlockIdListenable: activePdfTextBlockIdListenable,
              verticalCacheExtent: .35,
              onInteractionStart: horizontal ? onPdfInteractionStart : null,
              onInteractionEnd: horizontal ? onPdfInteractionEnd : null,
              onPageChanged: onPdfPageChanged,
              onTextFocus: null,
              onViewerReady: (_, controller) {
                onPdfPageChanged?.call(controller.pageNumber ?? pdfPageNumber);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (controller.isReady) controller.invalidate();
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The old editor normalized x coordinates against the content column, which
/// started 32 logical pixels from either edge. Keeping this conversion in one
/// place prevents strokes, text objects, and future image objects from drifting
/// when an old page is opened on the wider canvas.
abstract final class _PageAnnotationCoordinateMapper {
  static const horizontalInset = 32.0;

  static PageAnnotationDocument toViewport(
    PageAnnotationDocument document,
    Size viewportSize,
  ) {
    if (document.coordinateSpace == PageAnnotationCoordinateSpace.viewport ||
        viewportSize.width <= 0) {
      return document;
    }

    final width = viewportSize.width;
    final contentWidth = math.max(width - horizontalInset * 2, 1.0);
    final xScale = contentWidth / width;
    final xOffset = horizontalInset / width;

    Offset mapPoint(Offset point) => Offset(
      (xOffset + point.dx * xScale).clamp(0.0, 1.0).toDouble(),
      point.dy.clamp(0.0, 1.0).toDouble(),
    );

    return document.copyWith(
      coordinateSpace: PageAnnotationCoordinateSpace.viewport,
      strokes: [
        for (final stroke in document.strokes)
          stroke.copyWith(points: stroke.points.map(mapPoint).toList()),
      ],
      texts: [
        for (final text in document.texts)
          text.copyWith(
            center: mapPoint(text.center),
            width: (text.width * xScale).clamp(.001, 1.0).toDouble(),
          ),
      ],
      images: [
        for (final image in document.images)
          image.copyWith(
            center: mapPoint(image.center),
            width: (image.width * xScale).clamp(.001, 1.0).toDouble(),
          ),
      ],
    );
  }
}

class _PageAnnotationLayer extends StatefulWidget {
  const _PageAnnotationLayer({
    super.key,
    required this.layerKey,
    required this.document,
    required this.controller,
    required this.imageStore,
    required this.imageEditor,
    required this.enabled,
    required this.isActivePage,
    required this.onChanged,
    required this.onAction,
    required this.onLaserSelection,
  });

  final GlobalKey layerKey;
  final PageAnnotationDocument document;
  final PageAnnotationToolController controller;
  final PageImageAssetStore imageStore;
  final PageImageEditorController imageEditor;
  final bool enabled;
  final bool isActivePage;
  final ValueChanged<PageAnnotationDocument> onChanged;
  final ValueChanged<_AnnotationAction> onAction;
  final ValueChanged<List<Offset>> onLaserSelection;

  @override
  State<_PageAnnotationLayer> createState() => _PageAnnotationLayerState();
}

class _PageAnnotationLayerState extends State<_PageAnnotationLayer> {
  // Predicted points are retained in the platform packet for diagnostics, but
  // are not painted into the user-visible stroke. A prediction that is later
  // corrected must never flash black pixels and then retract from the canvas.
  static const _showPredictedInk = false;

  late PageAnnotationDocument _workingDocument;
  final _draftPoints = <Offset>[];
  final ChangeNotifier _draftRepaint = ChangeNotifier();
  final ChangeNotifier _historyRepaint = ChangeNotifier();
  late final StreamSubscription<InkPointerPacket> _inkSubscription;
  final _nativePointers = <int>{};
  final _nativeLastSampleTimes = <int, int>{};
  int _predictedPointCount = 0;
  int _draftGeometryGeneration = 0;
  int _draftCommitGeneration = 0;
  Timer? _laserFadeDelayTimer;
  Timer? _laserFadeTimer;
  double _laserDraftOpacity = 1;

  void _requestDraftRepaint() {
    // RenderCustomPaint already coalesces markNeedsPaint calls until the next
    // frame. Waiting for a scheduled frame here would add an avoidable frame
    // of ink latency, especially when platform prediction is active.
    _draftRepaint.notifyListeners();
  }

  PageAnnotationDocument? _gestureBeforeDocument;
  int? _activeDrawingPointer;
  Offset? _currentEraserPosition;
  bool _isErasing = false;
  bool _legacyEraserMaterializationScheduled = false;
  final _textControllers = <String, TextEditingController>{};
  final _textFocusNodes = <String, FocusNode>{};
  String? _textKeyboardReadyId;
  DrawingTool? _lastObservedTool;
  int _lastTextActivationVersion = 0;
  Offset? _lastPoint;
  Offset? _transformStartPoint;
  Rect? _transformStartBounds;
  _TextTransformSession? _textTransformSession;
  bool _movingSelection = false;
  bool _transforming = false;
  bool _rotating = false;
  String? _editingTextId;
  List<Offset>? _selectionContour;
  _TextCategory? _textCategory;
  bool _customTextColorOpen = false;
  // A PDF overlay may send an empty/older document more than one frame after
  // a stroke is committed. Keep every locally committed id until the parent
  // actually echoes it back; a single-frame guard is not enough here.
  final _pendingCommittedStrokeIds = <String>{};
  PageImageObject? _imageGestureStart;
  Offset? _imageGestureStartPoint;
  bool _imageScaling = false;

  @override
  void initState() {
    super.initState();
    _workingDocument = widget.document;
    _lastObservedTool = widget.controller.activeTool;
    _lastTextActivationVersion = widget.controller.textActivationVersion;
    _syncTextControllers();
    widget.controller.addListener(_onToolControllerChanged);
    widget.imageEditor.addListener(_onImageEditorChanged);
    _inkSubscription = LowLatencyInkInput.instance.packets.listen(
      _onNativeInkPacket,
      onError: (_, _) {},
    );
    if (widget.isActivePage &&
        widget.controller.activeTool == DrawingTool.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editingTextId == null) _beginNewTextObject();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _PageAnnotationLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onToolControllerChanged);
      widget.controller.addListener(_onToolControllerChanged);
      _lastObservedTool = widget.controller.activeTool;
      _lastTextActivationVersion = widget.controller.textActivationVersion;
    }
    if (oldWidget.imageEditor != widget.imageEditor) {
      oldWidget.imageEditor.removeListener(_onImageEditorChanged);
      widget.imageEditor.addListener(_onImageEditorChanged);
    }
    if (oldWidget.enabled && !widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.enabled) _finishTextEditing();
      });
    }
    if (!oldWidget.isActivePage && widget.isActivePage) {
      _lastObservedTool = widget.controller.activeTool;
      _lastTextActivationVersion = widget.controller.textActivationVersion;
      if (widget.controller.activeTool == DrawingTool.text &&
          _editingTextId == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _editingTextId == null) _beginNewTextObject();
        });
      }
    }
    if (!identical(oldWidget.document, widget.document)) {
      final hasActiveInteraction =
          _activeDrawingPointer != null ||
          _draftPoints.isNotEmpty ||
          _isErasing ||
          _movingSelection ||
          _transforming ||
          _rotating ||
          _imageGestureStart != null;
      if (hasActiveInteraction) return;

      // A PDF page/overlay refresh can briefly deliver an empty or older
      // document. The permanent drawing tools have already committed the
      // stroke locally, so accepting that stale payload would retract the
      // stroke immediately after it was painted. Keep the local commit until
      // the parent acknowledges its id.
      if (_pendingCommittedStrokeIds.isNotEmpty) {
        final acknowledged = _pendingCommittedStrokeIds.every(
          (pendingId) => widget.document.strokes.any(
            (stroke) => stroke.id == pendingId,
          ),
        );
        if (!acknowledged) return;
        _pendingCommittedStrokeIds.clear();
      }

      // Text creation follows the same parent/overlay handshake. In a PDF
      // page transition the parent may briefly pass an empty document; if it
      // replaces the local document while the text field is being created,
      // the newly created object and its input controller disappear together.
      final editingTextId = _editingTextId;
      if (editingTextId != null &&
          !widget.document.texts.any((text) => text.id == editingTextId)) {
        return;
      }
      _workingDocument = widget.document;
      _syncTextControllers();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onToolControllerChanged);
    widget.imageEditor.removeListener(_onImageEditorChanged);
    _inkSubscription.cancel();
    _laserFadeDelayTimer?.cancel();
    _laserFadeTimer?.cancel();
    _draftRepaint.dispose();
    _historyRepaint.dispose();
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    for (final node in _textFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _onToolControllerChanged() {
    final previous = _lastObservedTool;
    final current = widget.controller.activeTool;
    final textActivated =
        widget.controller.textActivationVersion != _lastTextActivationVersion;
    _lastObservedTool = current;
    _lastTextActivationVersion = widget.controller.textActivationVersion;
    if (!mounted) return;
    if (previous == current && !textActivated) return;
    _discardDraftPreview();
    if (current == DrawingTool.text && widget.isActivePage && textActivated) {
      if (_editingTextId != null) _finishTextEditing();
      _beginNewTextObject();
    } else if (previous == DrawingTool.text) {
      _finishTextEditing();
    }
  }

  void _discardDraftPreview() {
    _laserFadeDelayTimer?.cancel();
    _laserFadeTimer?.cancel();
    _laserDraftOpacity = 1;
    final hadPreview = _draftPoints.isNotEmpty || _predictedPointCount > 0;
    _draftPoints.clear();
    _predictedPointCount = 0;
    if (_movingSelection) widget.controller.endAnnotationDrag();
    _movingSelection = false;
    _transforming = false;
    _rotating = false;
    _textTransformSession = null;
    _transformStartPoint = null;
    _transformStartBounds = null;
    _draftGeometryGeneration++;
    if (!hadPreview) return;
    _historyRepaint.notifyListeners();
    _requestDraftRepaint();
  }

  void _syncTextControllers() {
    final activeIds = _workingDocument.texts.map((text) => text.id).toSet();
    for (final id in _textControllers.keys.toList()) {
      if (activeIds.contains(id)) continue;
      _textControllers.remove(id)?.dispose();
      _textFocusNodes.remove(id)?.dispose();
    }
    for (final text in _workingDocument.texts) {
      final controller = _textControllers.putIfAbsent(
        text.id,
        () => TextEditingController(text: text.text),
      );
      if (_editingTextId != text.id && controller.text != text.text) {
        controller.value = TextEditingValue(
          text: text.text,
          selection: TextSelection.collapsed(offset: text.text.length),
        );
      }
      _textFocusNodes.putIfAbsent(text.id, () => FocusNode());
    }
  }

  void _beginNewTextObject() {
    if (!mounted || !widget.enabled || !widget.isActivePage) return;
    final next = PageTextObject(
      id: 'text-${DateTime.now().microsecondsSinceEpoch}',
      text: '',
      center: const Offset(.5, .5),
      width: .28,
      height: .1,
      alignment: 'center',
    );
    final before = _workingDocument;
    _workingDocument = before.copyWith(texts: [...before.texts, next]);
    _editingTextId = next.id;
    _textKeyboardReadyId = null;
    _selectionContour = null;
    _syncTextControllers();
    widget.controller.selectAnnotations({next.id});
    widget.onChanged(_workingDocument);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingTextId != next.id) return;
      final node = _textFocusNodes[next.id];
      node?.requestFocus();
    });
  }

  void _finishTextEditing({bool clearSelection = false}) {
    final editingId = _editingTextId;
    _editingTextId = null;
    _textKeyboardReadyId = null;
    if (editingId == null) return;

    _textFocusNodes[editingId]?.unfocus();
    final text = _workingDocument.texts
        .where((item) => item.id == editingId)
        .firstOrNull;
    if (text == null || text.text.trim().isNotEmpty) {
      if (clearSelection) {
        _selectionContour = null;
        widget.controller.clearSelection();
      }
      if (mounted) setState(() {});
      return;
    }

    final before = _workingDocument;
    _workingDocument = before.copyWith(
      texts: before.texts.where((item) => item.id != editingId).toList(),
    );
    widget.controller.clearSelection();
    widget.onChanged(_workingDocument);
    if (mounted) setState(() {});
  }

  void _selectTextObject(String id) {
    if (widget.controller.activeTool != DrawingTool.text ||
        _editingTextId != null) {
      return;
    }
    final alreadySelected =
        widget.controller.selectedAnnotationIds.length == 1 &&
        widget.controller.selectedAnnotationIds.contains(id) &&
        widget.controller.isTransformMode;
    if (!alreadySelected) {
      widget.controller.selectAnnotations({id});
      widget.controller.enterTransformMode();
    }
  }

  void _beginEditingText(String id) {
    if (widget.controller.activeTool != DrawingTool.text) return;
    final text = _workingDocument.texts
        .where((item) => item.id == id)
        .firstOrNull;
    if (text == null) return;
    _selectionContour = null;
    _textCategory = null;
    _customTextColorOpen = false;
    _editingTextId = id;
    _textKeyboardReadyId = null;
    widget.controller.selectAnnotations({id});
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingTextId != id) return;
      _textFocusNodes[id]?.requestFocus();
    });
  }

  bool get _canDraw =>
      widget.enabled && !widget.controller.isBrowseMode && !_movingSelection;

  bool get _usesRawDrawingInput => switch (widget.controller.activeTool) {
    DrawingTool.ballpoint ||
    DrawingTool.pencil ||
    DrawingTool.highlighter ||
    DrawingTool.eraser => true,
    // Laser is handled by the immediate Flutter pointer stream below, but it
    // must stay out of the platform ink packet channel because it is transient.
    _ => false,
  };

  void _onRawPointerDown(PointerDownEvent event, Size size) {
    if (_nativePointers.contains(event.pointer)) return;
    _startRawPointer(event.pointer, event.localPosition, size);
  }

  void _startRawPointer(int pointer, Offset localPosition, Size size) {
    final laser = widget.controller.activeTool == DrawingTool.laser;
    if ((!_usesRawDrawingInput && !laser) ||
        !_canDraw ||
        _activeDrawingPointer != null) {
      return;
    }
    _draftCommitGeneration++;
    _activeDrawingPointer = pointer;
    _lastPoint = _normalize(localPosition, size);
    _clearPredictedPoints();
    if (widget.controller.activeTool == DrawingTool.laser) {
      _laserFadeDelayTimer?.cancel();
      _laserFadeTimer?.cancel();
      _laserDraftOpacity = 1;
      // The live painter is intentionally repaint-only during the stroke.
      // Rebuild once when a new stroke starts so a previous fade at opacity 0
      // cannot be reused for the new laser trace.
      if (mounted) setState(() {});
    }
    if (widget.controller.activeTool == DrawingTool.eraser) {
      _beginEraser(localPosition, size);
      return;
    }
    _draftPoints
      ..clear()
      ..add(_lastPoint!);
    _requestDraftRepaint();
  }

  void _onRawPointerMove(PointerMoveEvent event, Size size) {
    if (_nativePointers.contains(event.pointer)) return;
    if (event.pointer != _activeDrawingPointer || !_canDraw) return;
    _moveRawPoint(event.pointer, event.localPosition, size);
  }

  void _moveRawPoint(
    int pointer,
    Offset localPosition,
    Size size, {
    bool repaint = true,
  }) {
    if (pointer != _activeDrawingPointer || !_canDraw) return;
    _clearPredictedPoints();
    if (widget.controller.activeTool == DrawingTool.eraser) {
      _onPanUpdate(localPosition, size);
      return;
    }
    final next = _normalize(localPosition, size);
    _appendInterpolatedDraftPoint(next, size);
    _lastPoint = next;
    if (repaint) _requestDraftRepaint();
  }

  void _onRawPointerUp(PointerUpEvent event, Size size) {
    if (_nativePointers.remove(event.pointer)) return;
    if (event.pointer != _activeDrawingPointer) return;
    _finishRawPointer(event.pointer, size);
  }

  void _onRawPointerCancel(PointerCancelEvent event, Size size) {
    if (_nativePointers.remove(event.pointer)) return;
    if (event.pointer != _activeDrawingPointer) return;
    _cancelRawPointer(event.pointer, size);
  }

  void _finishRawPointer(int pointer, Size size) {
    if (pointer != _activeDrawingPointer) return;
    _activeDrawingPointer = null;
    _clearPredictedPoints();
    _onPanEnd(size);
  }

  void _cancelRawPointer(int pointer, Size size) {
    if (pointer != _activeDrawingPointer) return;
    _activeDrawingPointer = null;
    _clearPredictedPoints();
    _onPanCancel(size);
  }

  void _onNativeInkPacket(InkPointerPacket packet) {
    if (widget.controller.activeTool == DrawingTool.laser) {
      _nativePointers.remove(packet.pointer);
      _nativeLastSampleTimes.remove(packet.pointer);
      return;
    }
    if (!_usesRawDrawingInput &&
        packet.phase != InkPointerPhase.up &&
        packet.phase != InkPointerPhase.cancel) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final size = renderObject.size;
    final localPoints = <(InkPointerSample, Offset)>[];
    for (final sample in packet.samples) {
      final local = renderObject.globalToLocal(Offset(sample.x, sample.y));
      if (local.dx < 0 ||
          local.dy < 0 ||
          local.dx > size.width ||
          local.dy > size.height) {
        continue;
      }
      localPoints.add((sample, local));
    }

    if (packet.phase == InkPointerPhase.down) {
      if (!_canDraw || _nativePointers.contains(packet.pointer)) return;
      _nativePointers.add(packet.pointer);
      if (_activeDrawingPointer != null &&
          _activeDrawingPointer != packet.pointer) {
        // UIKit may deliver the Flutter pointer-down before the gesture
        // recognizer callback. Adopt the native id for the same locked touch
        // instead of starting a second stroke or dropping native samples.
        _activeDrawingPointer = packet.pointer;
      }
      final firstActual = localPoints
          .where((item) => !item.$1.predicted)
          .map((item) => item.$2)
          .firstOrNull;
      if (firstActual == null) {
        _nativePointers.remove(packet.pointer);
        return;
      }
      _nativeLastSampleTimes[packet.pointer] = localPoints
          .where((item) => !item.$1.predicted)
          .map((item) => item.$1.timeMicros)
          .fold<int>(0, (maxTime, time) => math.max(maxTime, time).toInt());
      _startRawPointer(packet.pointer, firstActual, size);
      return;
    }

    if (!_nativePointers.contains(packet.pointer) ||
        packet.pointer != _activeDrawingPointer) {
      return;
    }
    if (packet.phase == InkPointerPhase.move) {
      final actual = localPoints
          .where((item) => !item.$1.predicted)
          .where(
            (item) =>
                item.$1.timeMicros >
                (_nativeLastSampleTimes[packet.pointer] ?? -1),
          )
          .map((item) => item.$2)
          .toList(growable: false);
      if (actual.isNotEmpty) {
        for (final point in actual) {
          _moveRawPoint(packet.pointer, point, size, repaint: false);
        }
        _nativeLastSampleTimes[packet.pointer] = localPoints
            .where((item) => !item.$1.predicted)
            .map((item) => item.$1.timeMicros)
            .fold<int>(
              _nativeLastSampleTimes[packet.pointer] ?? -1,
              (maxTime, time) => math.max(maxTime, time).toInt(),
            );
      }
      if (_showPredictedInk &&
          widget.controller.activeTool != DrawingTool.eraser) {
        final predicted = localPoints
            .where((item) => item.$1.predicted)
            .map((item) => item.$2)
            .toList(growable: false);
        _replacePredictedPoints(predicted, size);
        if (predicted.isNotEmpty) _requestDraftRepaint();
      } else {
        _clearPredictedPoints();
        if (actual.isNotEmpty) _requestDraftRepaint();
      }
      return;
    }

    final actual = localPoints
        .where((item) => !item.$1.predicted)
        .where(
          (item) =>
              item.$1.timeMicros >
              (_nativeLastSampleTimes[packet.pointer] ?? -1),
        )
        .map((item) => item.$2)
        .toList(growable: false);
    for (final point in actual) {
      _moveRawPoint(packet.pointer, point, size, repaint: false);
    }
    final wasActive = _nativePointers.remove(packet.pointer);
    _nativeLastSampleTimes.remove(packet.pointer);
    _clearPredictedPoints();
    if (!wasActive) return;
    if (packet.phase == InkPointerPhase.up) {
      _finishRawPointer(packet.pointer, size);
    } else {
      _cancelRawPointer(packet.pointer, size);
    }
  }

  void _replacePredictedPoints(List<Offset> points, Size size) {
    _clearPredictedPoints();
    if (points.isEmpty) return;
    for (final point in points) {
      final normalized = _normalize(point, size);
      if (_lastPoint == normalized) continue;
      _draftPoints.add(normalized);
      _predictedPointCount++;
    }
  }

  void _clearPredictedPoints() {
    if (_predictedPointCount <= 0) return;
    final keepCount = _draftPoints.length - _predictedPointCount;
    if (keepCount >= 0 && keepCount <= _draftPoints.length) {
      _draftPoints.removeRange(keepCount, _draftPoints.length);
    }
    _predictedPointCount = 0;
    _draftGeometryGeneration++;
  }

  void _deferDraftClearAfterCommit(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _draftCommitGeneration) return;
      if (_activeDrawingPointer != null || _draftPoints.isEmpty) return;
      _draftPoints.clear();
      _draftGeometryGeneration++;
      if (mounted) setState(() {});
      _requestDraftRepaint();
    });
  }

  void _scheduleLaserFade() {
    _laserFadeDelayTimer?.cancel();
    _laserFadeTimer?.cancel();
    _laserDraftOpacity = 1;
    _laserFadeDelayTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _activeDrawingPointer != null) return;
      var step = 0;
      _laserFadeTimer = Timer.periodic(const Duration(milliseconds: 50), (
        timer,
      ) {
        if (!mounted || _activeDrawingPointer != null) {
          timer.cancel();
          return;
        }
        step++;
        _laserDraftOpacity = (1 - step / 14).clamp(0.0, 1.0).toDouble();
        _requestDraftRepaint();
        if (step >= 14) {
          timer.cancel();
          _draftPoints.clear();
          _draftGeometryGeneration++;
        }
        if (mounted) setState(() {});
      });
    });
  }

  void _appendInterpolatedDraftPoint(Offset next, Size size) {
    if (_draftPoints.isEmpty) {
      _draftPoints.add(next);
      return;
    }
    final previous = _draftPoints.last;
    final dx = (next.dx - previous.dx) * size.width;
    final dy = (next.dy - previous.dy) * size.height;
    final distance = math.sqrt(dx * dx + dy * dy);
    // Pointer events already preserve the curve. Extra collinear samples do
    // not improve the path, but they multiply live paint, replay and save
    // costs for every long stroke.
    final minimumDistance = widget.controller.activeTool == DrawingTool.laser
        ? 1.5
        : .75;
    if (distance >= minimumDistance) _draftPoints.add(next);
  }

  void _materializeLegacyErasers(Size size) {
    if (_legacyEraserMaterializationScheduled ||
        !_workingDocument.strokes.any(
          (stroke) => stroke.tool == StrokeTool.eraser,
        )) {
      return;
    }
    _legacyEraserMaterializationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _legacyEraserMaterializationScheduled = false;
      if (!mounted || size.width <= 0 || size.height <= 0) return;
      final erasers = _workingDocument.strokes
          .where((stroke) => stroke.tool == StrokeTool.eraser)
          .toList();
      if (erasers.isEmpty) return;

      for (final eraser in erasers) {
        if (eraser.points.isEmpty) continue;
        final radius = eraser.width;
        _eraseLocallyAt(
          _denormalize(eraser.points.first, size),
          size,
          radiusOverride: radius,
        );
        for (var index = 1; index < eraser.points.length; index++) {
          final from = eraser.points[index - 1];
          final to = eraser.points[index];
          final segmentLength =
              (_denormalize(to, size) - _denormalize(from, size)).distance;
          final steps = math.max(
            1,
            (segmentLength / math.max(radius / 2, 1)).ceil(),
          );
          for (var step = 1; step <= steps; step++) {
            final progress = step / steps;
            _eraseLocallyAt(
              _denormalize(
                Offset(
                  from.dx + (to.dx - from.dx) * progress,
                  from.dy + (to.dy - from.dy) * progress,
                ),
                size,
              ),
              size,
              radiusOverride: radius,
            );
          }
        }
      }
      _workingDocument = _workingDocument.copyWith(
        strokes: _workingDocument.strokes
            .where((stroke) => stroke.tool != StrokeTool.eraser)
            .toList(),
      );
      widget.onChanged(_workingDocument);
      setState(() {});
    });
  }

  void _onImageEditorChanged() {
    if (!widget.isActivePage) return;
    if (mounted) setState(() {});
  }

  Offset _pagePoint(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(globalPosition) ?? globalPosition;
  }

  Rect _imageRect(PageImageObject image, Size size) {
    final width = image.width * size.width;
    final height = width / image.aspectRatio;
    return Rect.fromCenter(
      center: Offset(
        image.center.dx * size.width,
        image.center.dy * size.height,
      ),
      width: width,
      height: height,
    );
  }

  double _imageHeightNormalized(
    PageImageObject image,
    double width,
    Size size,
  ) => width * size.width / image.aspectRatio / size.height;

  double _maxImageWidth(PageImageObject image, Size size) {
    final horizontal = 2 * math.min(image.center.dx, 1 - image.center.dx);
    final vertical =
        2 *
        math.min(image.center.dy, 1 - image.center.dy) *
        size.height *
        image.aspectRatio /
        size.width;
    return math
        .max(.01, math.min(1, math.min(horizontal, vertical)))
        .toDouble();
  }

  PageImageObject _clampImage(PageImageObject image, Size size) {
    final maxWidth = _maxImageWidth(image, size);
    final minWidth = math.min(
      maxWidth,
      math.min(.99, 96 / math.max(size.width, 1)),
    );
    final width = image.width.clamp(minWidth, maxWidth).toDouble();
    final height = _imageHeightNormalized(image, width, size);
    final halfWidth = width / 2;
    final halfHeight = height / 2;
    return image.copyWith(
      width: width,
      center: Offset(
        image.center.dx.clamp(halfWidth, 1 - halfWidth).toDouble(),
        image.center.dy.clamp(halfHeight, 1 - halfHeight).toDouble(),
      ),
    );
  }

  void _replaceImage(PageImageObject next) {
    _workingDocument = _workingDocument.copyWith(
      images: [
        for (final image in _workingDocument.images)
          image.id == next.id ? next : image,
      ],
    );
    widget.onChanged(_workingDocument);
    if (mounted) setState(() {});
  }

  void _beginImageMove(PageImageObject image, Offset globalPosition) {
    if (!widget.imageEditor.isEditing ||
        widget.imageEditor.selectedImageId != image.id) {
      return;
    }
    _imageGestureStart = image;
    _imageGestureStartPoint = _pagePoint(globalPosition);
    _imageScaling = false;
  }

  void _updateImageMove(Offset globalPosition, Size size) {
    final initial = _imageGestureStart;
    final startPoint = _imageGestureStartPoint;
    if (initial == null || startPoint == null || _imageScaling) return;
    final delta = _pagePoint(globalPosition) - startPoint;
    final next = _clampImage(
      initial.copyWith(
        center: Offset(
          initial.center.dx + delta.dx / size.width,
          initial.center.dy + delta.dy / size.height,
        ),
      ),
      size,
    );
    _replaceImage(next);
  }

  void _beginImageScale(PageImageObject image, Offset globalPosition) {
    if (!widget.imageEditor.isEditing ||
        widget.imageEditor.selectedImageId != image.id) {
      return;
    }
    _imageGestureStart = image;
    _imageGestureStartPoint = _pagePoint(globalPosition);
    _imageScaling = true;
  }

  void _updateImageScale(Offset globalPosition, Size size) {
    final initial = _imageGestureStart;
    final startPoint = _imageGestureStartPoint;
    if (initial == null || startPoint == null || !_imageScaling) return;
    final startRect = _imageRect(initial, size);
    final current = _pagePoint(globalPosition);
    final initialDistance = (startRect.bottomRight - startRect.center).distance;
    final currentDistance = (current - startRect.center).distance;
    if (initialDistance <= 1 || currentDistance <= 1) return;
    final requested = initial.width * currentDistance / initialDistance;
    _replaceImage(_clampImage(initial.copyWith(width: requested), size));
  }

  void _finishImageGesture() {
    _imageGestureStart = null;
    _imageGestureStartPoint = null;
    _imageScaling = false;
  }

  void _removeImage(String id) {
    final before = _workingDocument;
    final next = before.copyWith(
      images: before.images.where((image) => image.id != id).toList(),
    );
    if (identical(before, next)) return;
    _workingDocument = next;
    widget.onChanged(next);
    widget.imageEditor.clearSelection();
  }

  Widget _buildImageOverlay(Size size) {
    final canEdit =
        widget.isActivePage &&
        (!widget.enabled || widget.controller.isBrowseMode);
    final selectedId = widget.imageEditor.selectedImageId;
    final editing = canEdit && widget.imageEditor.isEditing;
    final children = <Widget>[];
    if (editing) {
      children.add(
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => widget.imageEditor.lockSelection(),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    for (final image in _workingDocument.images) {
      final imageForLayout = _clampImage(image, size);
      final rect = _imageRect(imageForLayout, size);
      final isSelected = editing && selectedId == image.id;
      if (isSelected) {
        final deleteLeft = math.max(0.0, 24 - rect.left).toDouble();
        final deleteTop = math.max(0.0, 24 - rect.top).toDouble();
        final resizeRight = math
            .max(0.0, rect.right + 24 - size.width)
            .toDouble();
        final resizeBottom = math
            .max(0.0, rect.bottom + 24 - size.height)
            .toDouble();
        children.add(
          Positioned(
            key: Key('book_page_editor_image_selected_${image.id}'),
            left: rect.left - 24,
            top: rect.top - 24,
            width: rect.width + 48,
            height: rect.height + 48,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 24,
                  top: 24,
                  width: rect.width,
                  height: rect.height,
                  child: GestureDetector(
                    key: Key('book_page_editor_image_move_${image.id}'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) =>
                        _beginImageMove(imageForLayout, details.globalPosition),
                    onPanUpdate: (details) =>
                        _updateImageMove(details.globalPosition, size),
                    onPanEnd: (_) => _finishImageGesture(),
                    onPanCancel: _finishImageGesture,
                    child: PageImageDisplay(
                      image: imageForLayout,
                      imageStore: widget.imageStore,
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  top: 24,
                  width: rect.width,
                  height: rect.height,
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ImageSelectionFramePainter()),
                  ),
                ),
                Positioned(
                  left: deleteLeft,
                  top: deleteTop,
                  width: 48,
                  height: 48,
                  child: IconButton(
                    key: Key('book_page_editor_image_delete_${image.id}'),
                    tooltip: '删除图片',
                    padding: EdgeInsets.zero,
                    icon: const _ImageEditHandle(
                      icon: Icons.delete_outline,
                      destructive: true,
                    ),
                    onPressed: () => _removeImage(image.id),
                  ),
                ),
                Positioned(
                  right: resizeRight,
                  bottom: resizeBottom,
                  width: 48,
                  height: 48,
                  child: GestureDetector(
                    key: Key('book_page_editor_image_resize_${image.id}'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) => _beginImageScale(
                      imageForLayout,
                      details.globalPosition,
                    ),
                    onPanUpdate: (details) =>
                        _updateImageScale(details.globalPosition, size),
                    onPanEnd: (_) => _finishImageGesture(),
                    onPanCancel: _finishImageGesture,
                    child: Semantics(
                      button: true,
                      label: '缩放图片',
                      child: Center(
                        child: _ImageEditHandle(icon: Icons.open_in_full),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Positioned(
            key: Key('book_page_editor_image_${image.id}'),
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: canEdit
                  ? () => widget.imageEditor.selectForEditing(image.id)
                  : null,
              child: AbsorbPointer(
                key: Key('book_page_editor_image_input_${image.id}'),
                absorbing: !canEdit,
                child: PageImageDisplay(
                  image: imageForLayout,
                  imageStore: widget.imageStore,
                ),
              ),
            ),
          ),
        );
      }
    }
    return Stack(
      key: const Key('book_page_editor_media_interaction_layer'),
      clipBehavior: Clip.none,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: widget.layerKey,
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Promote legacy content-column coordinates once the full-width layer
        // has a real size. All subsequent painting, hit testing, erasing and
        // persistence then share the viewport coordinate contract.
        if (_workingDocument.coordinateSpace ==
            PageAnnotationCoordinateSpace.content) {
          _workingDocument = _PageAnnotationCoordinateMapper.toViewport(
            _workingDocument,
            size,
          );
        }
        _materializeLegacyErasers(size);
        final bounds = _selectionBounds(size);
        final selectedText =
            widget.controller.activeTool == DrawingTool.text &&
                widget.controller.selectedAnnotationIds.length == 1
            ? _workingDocument.texts
                  .where(
                    (text) => widget.controller.selectedAnnotationIds.contains(
                      text.id,
                    ),
                  )
                  .firstOrNull
            : null;
        final isEditingSelectedText =
            selectedText != null && _editingTextId == selectedText.id;
        final usesRawDrawingInput = _usesRawDrawingInput;
        final usesImmediatePointerInput =
            usesRawDrawingInput ||
            widget.controller.activeTool == DrawingTool.laser;
        final usesLiveDraftPainter = usesImmediatePointerInput;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IgnorePointer(
              ignoring: !widget.enabled || widget.controller.isBrowseMode,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: usesImmediatePointerInput
                    ? (event) => _onRawPointerDown(event, size)
                    : null,
                onPointerMove: usesImmediatePointerInput
                    ? (event) => _onRawPointerMove(event, size)
                    : null,
                onPointerUp: usesImmediatePointerInput
                    ? (event) => _onRawPointerUp(event, size)
                    : null,
                onPointerCancel: usesImmediatePointerInput
                    ? (event) => _onRawPointerCancel(event, size)
                    : null,
                child: GestureDetector(
                  behavior: usesImmediatePointerInput
                      ? HitTestBehavior.opaque
                      : HitTestBehavior.translucent,
                  onTapDown: usesImmediatePointerInput
                      ? null
                      : (details) {
                          // Non-drawing tools keep GestureDetector semantics.
                          if (widget.controller.activeTool ==
                                  DrawingTool.eraser &&
                              _canDraw &&
                              !_isErasing) {
                            _beginEraser(details.localPosition, size);
                          }
                        },
                  onTapUp: usesImmediatePointerInput
                      ? null
                      : (details) {
                          if (_isErasing) {
                            _onPanEnd(size);
                          } else {
                            _onTap(details.localPosition, size);
                          }
                        },
                  onPanStart: usesImmediatePointerInput
                      ? null
                      : (details) => _onPanStart(details.localPosition, size),
                  onPanUpdate: usesImmediatePointerInput
                      ? null
                      : (details) => _onPanUpdate(details.localPosition, size),
                  onPanEnd: usesImmediatePointerInput
                      ? null
                      : (_) => _onPanEnd(size),
                  onPanCancel: usesImmediatePointerInput
                      ? null
                      : () => _onPanCancel(size),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _AnnotationPainter(
                              document: _workingDocument,
                              documentProvider: () => _workingDocument,
                              // Skip only while the matching live draft is
                              // still painted. Once the draft is cleared, a
                              // pending parent acknowledgement must not make
                              // the permanent stroke invisible.
                              skipStrokeId: _draftPoints.isNotEmpty &&
                                      _pendingCommittedStrokeIds.isNotEmpty
                                  ? _pendingCommittedStrokeIds.last
                                  : null,
                              draftPoints: usesLiveDraftPainter
                                  ? const <Offset>[]
                                  : _draftPoints,
                              repaint: _historyRepaint,
                              draftTool: widget.controller.activeTool,
                              draftColor: Color(
                                widget.controller.colorFor(
                                  widget.controller.activeTool,
                                ),
                              ),
                              draftWidth:
                                  widget.controller.activeTool ==
                                      DrawingTool.eraser
                                  ? widget.controller.eraserRadius * 2
                                  : widget.controller.widthFor(
                                      widget.controller.activeTool,
                                    ),
                              draftOpacity:
                                  widget.controller.activeTool ==
                                      DrawingTool.laser
                                  ? _laserDraftOpacity
                                  : widget.controller.activeTool ==
                                        DrawingTool.highlighter
                                  ? .42
                                  : 1,
                              currentEraserPosition: null,
                              eraserRadius: widget.controller.eraserRadius,
                              isErasing: false,
                              selectedIds:
                                  widget.controller.selectedAnnotationIds,
                              selectionContour: _selectionContour,
                              selectionBounds: isEditingSelectedText
                                  ? null
                                  : bounds,
                              transformMode: widget.controller.isTransformMode,
                            ),
                          ),
                        ),
                      ),
                      if (usesLiveDraftPainter)
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _LiveAnnotationPainter(
                                points: _draftPoints,
                                repaint: _draftRepaint,
                                tool: widget.controller.activeTool,
                                color: Color(
                                  widget.controller.colorFor(
                                    widget.controller.activeTool,
                                  ),
                                ),
                                width:
                                    widget.controller.activeTool ==
                                        DrawingTool.eraser
                                    ? widget.controller.eraserRadius * 2
                                    : widget.controller.widthFor(
                                        widget.controller.activeTool,
                                      ),
                                opacity:
                                    widget.controller.activeTool ==
                                        DrawingTool.laser
                                    ? _laserDraftOpacity
                                    : widget.controller.activeTool ==
                                          DrawingTool.highlighter
                                    ? .42
                                    : 1,
                                geometryGeneration: _draftGeometryGeneration,
                                eraserPosition: () => _currentEraserPosition,
                                eraserRadius: widget.controller.eraserRadius,
                                isErasing: () => _isErasing,
                              ),
                            ),
                          ),
                        ),
                      for (final text in _workingDocument.texts)
                        _buildTextObject(text, size),
                      if (selectedText != null &&
                          bounds != null &&
                          widget.controller.isTransformMode)
                        ..._buildTextTransformActions(
                          selectedText,
                          bounds,
                          size,
                        ),
                      if (bounds != null &&
                          widget.controller.isAnnotationActionBarVisible &&
                          widget.controller.activeTool == DrawingTool.lasso)
                        _buildAnnotationActionBar(bounds, size),
                      if (selectedText != null &&
                          !widget.controller.isTransformMode)
                        _buildTextContextBar(selectedText, bounds, size),
                      if (selectedText != null &&
                          bounds != null &&
                          !widget.controller.isTransformMode &&
                          _textCategory != null)
                        _buildTextPropertyPanel(selectedText, bounds, size),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(child: _buildImageOverlay(size)),
          ],
        );
      },
    );
  }

  void _onTap(Offset point, Size size) {
    final hitText = _textAt(point, size);
    if (hitText != null) {
      if (widget.controller.activeTool == DrawingTool.text) {
        _selectTextObject(hitText.id);
      }
      return;
    }
    if (widget.controller.activeTool == DrawingTool.text) {
      if (_editingTextId != null) {
        _finishTextEditing(clearSelection: true);
      } else {
        _selectionContour = null;
        _textCategory = null;
        widget.controller.clearSelection();
      }
      return;
    }
    if (widget.controller.activeTool == DrawingTool.lasso) {
      if (widget.controller.lassoMode == LassoMode.all) {
        widget.controller.selectAnnotations({
          for (
            var strokeIndex = 0;
            strokeIndex < _workingDocument.strokes.length;
            strokeIndex++
          )
            if (_workingDocument.strokes[strokeIndex].tool !=
                    StrokeTool.eraser &&
                _visibleStrokePoints(strokeIndex, size).isNotEmpty)
              _workingDocument.strokes[strokeIndex].id,
          ..._workingDocument.texts.map((text) => text.id),
        });
      } else {
        _selectionContour = null;
        widget.controller.clearSelection();
      }
    }
  }

  void _beginEraser(Offset point, Size size) {
    _draftPoints.clear();
    _gestureBeforeDocument = _workingDocument;
    _currentEraserPosition = point;
    _isErasing = true;
    final changed = widget.controller.eraserMode == EraserMode.free
        ? _eraseLocallyAt(point, size)
        : _removeIntersectedStrokes(point, size);
    if (changed) _historyRepaint.notifyListeners();
    _requestDraftRepaint();
  }

  bool _removeIntersectedStrokes(Offset point, Size size) {
    final hit = _strokeIdsNear(point, size, widget.controller.eraserRadius);
    if (hit.isEmpty) return false;
    _workingDocument = _workingDocument.copyWith(
      strokes: _workingDocument.strokes
          .where((stroke) => !hit.contains(stroke.id))
          .toList(),
    );
    return true;
  }

  bool _eraseLocallyAt(Offset point, Size size, {double? radiusOverride}) {
    if (size.width <= 0 || size.height <= 0) return false;
    final radius = radiusOverride ?? widget.controller.eraserRadius;
    final nextStrokes = <PageStroke>[];
    var changed = false;
    for (final stroke in _workingDocument.strokes) {
      if (stroke.tool == StrokeTool.eraser) {
        nextStrokes.add(stroke);
        continue;
      }
      final segments = <List<Offset>>[];
      var current = <Offset>[];
      var strokeChanged = false;
      void visit(Offset sample) {
        final samplePoint = _denormalize(sample, size);
        final inside = (samplePoint - point).distance <= radius;
        if (inside) {
          if (current.isNotEmpty) segments.add(current);
          current = <Offset>[];
          strokeChanged = true;
          changed = true;
        } else {
          if (current.isEmpty || current.last != sample) current.add(sample);
        }
      }

      if (stroke.points.isNotEmpty) {
        visit(stroke.points.first);
        for (var index = 1; index < stroke.points.length; index++) {
          final from = stroke.points[index - 1];
          final to = stroke.points[index];
          final segmentLength =
              (_denormalize(to, size) - _denormalize(from, size)).distance;
          final steps = math.max(
            1,
            (segmentLength / math.max(radius / 2, 1)).ceil(),
          );
          for (var step = 1; step <= steps; step++) {
            final progress = step / steps;
            visit(
              Offset(
                from.dx + (to.dx - from.dx) * progress,
                from.dy + (to.dy - from.dy) * progress,
              ),
            );
          }
        }
      }
      if (current.isNotEmpty) segments.add(current);
      if (!strokeChanged) {
        nextStrokes.add(stroke);
        continue;
      }
      for (var index = 0; index < segments.length; index++) {
        nextStrokes.add(
          stroke.copyWith(
            id: index == 0
                ? stroke.id
                : '${stroke.id}-segment-${DateTime.now().microsecondsSinceEpoch}-$index',
            points: segments[index],
          ),
        );
      }
    }
    if (changed) {
      _workingDocument = _workingDocument.copyWith(strokes: nextStrokes);
    }
    return changed;
  }

  void _finishEraserGesture() {
    _draftPoints.clear();
    _gestureBeforeDocument = null;
    _currentEraserPosition = null;
    _isErasing = false;
    _lastPoint = null;
  }

  double _signedAngleBetween(Offset from, Offset to) => math.atan2(
    from.dx * to.dy - from.dy * to.dx,
    from.dx * to.dx + from.dy * to.dy,
  );

  void _updateTextTransform(Offset point) {
    final session = _textTransformSession;
    if (session == null) {
      return;
    }
    final initialVector = session.initialHandleVector;
    final currentVector = point - session.center;
    final initialDistance = initialVector.distance;
    final currentDistance = currentVector.distance;
    if (initialDistance <= 1 || currentDistance <= 1) return;

    final factor = (currentDistance / initialDistance)
        .clamp(.25, 4.0)
        .toDouble();
    final angle = _signedAngleBetween(initialVector, currentVector);
    if (!angle.isFinite) return;
    final initialText = session.initialText;
    final nextScale = (initialText.scale * factor).clamp(.05, 20).toDouble();
    final nextRotation = initialText.rotation + angle;
    _workingDocument = _workingDocument.copyWith(
      texts: [
        for (final item in _workingDocument.texts)
          item.id == initialText.id
              ? item.copyWith(
                  center: Offset(
                    session.center.dx / session.canvasSize.width,
                    session.center.dy / session.canvasSize.height,
                  ),
                  scale: nextScale,
                  rotation: nextRotation,
                )
              : item,
      ],
    );
  }

  void _onPanStart(Offset point, Size size) {
    final tool = widget.controller.activeTool;
    final normalized = _normalize(point, size);
    _lastPoint = normalized;
    if (tool == DrawingTool.text) {
      if (_editingTextId != null) {
        _discardDraftPreview();
        return;
      }
      final selectedText = widget.controller.selectedAnnotationIds.length == 1
          ? _workingDocument.texts
                .where(
                  (text) =>
                      widget.controller.selectedAnnotationIds.contains(text.id),
                )
                .firstOrNull
          : null;
      final bounds = selectedText == null ? null : _selectionBounds(size);
      if (selectedText != null &&
          bounds != null &&
          widget.controller.isTransformMode) {
        final handlePoint = _rotatePixelPoint(
          bounds.bottomRight,
          bounds.center,
          selectedText.rotation,
        );
        if ((point - handlePoint).distance <= 36) {
          _textTransformSession = _TextTransformSession(
            initialText: selectedText,
            initialBounds: bounds,
            initialHandleVector: handlePoint - bounds.center,
            canvasSize: size,
          );
          _transformStartBounds = bounds;
          _transformStartPoint = normalized;
          _transforming = true;
          return;
        }
        if (_containsRotatedRect(point, bounds, selectedText.rotation)) {
          _movingSelection = true;
          widget.controller.beginAnnotationDrag();
          return;
        }
      }
      _discardDraftPreview();
      return;
    }
    if (tool == DrawingTool.lasso &&
        widget.controller.selectedAnnotationIds.isNotEmpty) {
      final bounds = _selectionBounds(size);
      if (widget.controller.isTransformMode && bounds != null) {
        _textTransformSession = null;
        _transformStartBounds = bounds;
        _transformStartPoint = normalized;
        final rotatePoint = Offset(bounds.center.dx, bounds.top - 28);
        _rotating = (point - rotatePoint).distance <= 28;
        _transforming =
            !_rotating && (point - bounds.bottomRight).distance <= 32;
        if (_transforming || _rotating) return;
      }
      if (bounds != null && bounds.contains(point)) {
        _movingSelection = true;
        widget.controller.beginAnnotationDrag();
        return;
      }
    }
    if (tool == DrawingTool.eraser && _canDraw) {
      if (!_isErasing) _beginEraser(point, size);
      return;
    }
    if (!_canDraw) return;
    _draftPoints
      ..clear()
      ..add(normalized);
    setState(() {});
  }

  void _onPanUpdate(Offset point, Size size) {
    final normalized = _normalize(point, size);
    final last = _lastPoint;
    final tool = widget.controller.activeTool;
    if (_isErasing) {
      _currentEraserPosition = point;
      final minimumStep = math.max(1.5, widget.controller.eraserRadius * .18);
      if (last != null &&
          (_denormalize(last, size) - point).distance < minimumStep) {
        _requestDraftRepaint();
        return;
      }
      _lastPoint = normalized;
      final changed = widget.controller.eraserMode == EraserMode.free
          ? _eraseLocallyAt(point, size)
          : _removeIntersectedStrokes(point, size);
      if (changed) _historyRepaint.notifyListeners();
      _requestDraftRepaint();
      return;
    }
    _lastPoint = normalized;
    if (_movingSelection && last != null) {
      _translateSelection(normalized - last);
      setState(() {});
      return;
    }
    if (_transforming &&
        _transformStartPoint != null &&
        _transformStartBounds != null) {
      if (tool == DrawingTool.text) {
        _updateTextTransform(point);
      } else {
        final delta = normalized - _transformStartPoint!;
        final ratio = (1 + delta.dx * 1.4).clamp(.25, 4.0).toDouble();
        _scaleSelection(ratio, size);
        _transformStartPoint = normalized;
      }
      setState(() {});
      return;
    }
    if (_rotating && _transformStartBounds != null) {
      final center = _transformStartBounds!.center;
      final previous = last ?? normalized;
      final currentAngle = math.atan2(
        point.dy - center.dy,
        point.dx - center.dx,
      );
      final previousAngle = math.atan2(
        (previous.dy * size.height) - center.dy,
        (previous.dx * size.width) - center.dx,
      );
      _rotateSelection(currentAngle - previousAngle, size);
      setState(() {});
      return;
    }
    if (tool == DrawingTool.text) {
      _discardDraftPreview();
      return;
    }
    if (_draftPoints.isEmpty || !_canDraw) return;
    _draftPoints.add(normalized);
    setState(() {});
  }

  void _onPanEnd(Size size) {
    if (_isErasing) {
      final before = _gestureBeforeDocument;
      final changed = before != null && before != _workingDocument;
      _finishEraserGesture();
      if (changed) widget.onChanged(_workingDocument);
      setState(() {});
      return;
    }
    if (_movingSelection) {
      _movingSelection = false;
      _lastPoint = null;
      widget.controller.endAnnotationDrag();
      widget.onChanged(_workingDocument);
      setState(() {});
      return;
    }
    if (_transforming || _rotating) {
      _transforming = false;
      _rotating = false;
      _textTransformSession = null;
      _transformStartPoint = null;
      _transformStartBounds = null;
      _lastPoint = null;
      widget.onChanged(_workingDocument);
      setState(() {});
      return;
    }
    final points = List<Offset>.from(_draftPoints);
    final tool = widget.controller.activeTool;
    if (tool == DrawingTool.text) {
      _discardDraftPreview();
      setState(() {});
      return;
    }
    if (points.isEmpty || (tool == DrawingTool.lasso && points.length < 2)) {
      _draftPoints.clear();
      _draftGeometryGeneration++;
      _requestDraftRepaint();
      setState(() {});
      return;
    }
    if (tool == DrawingTool.laser) {
      // Laser is a temporary discussion gesture. It must never be
      // materialized into PageAnnotationDocument or annotationsJson.
      if (points.length >= 3) {
        final layer = widget.layerKey.currentContext?.findRenderObject();
        if (layer is RenderBox && layer.hasSize) {
          widget.onLaserSelection([
            for (final point in points)
              layer.localToGlobal(_denormalize(point, size)),
          ]);
        }
      }
      _scheduleLaserFade();
      setState(() {});
      return;
    }
    if (tool == DrawingTool.lasso) {
      _draftPoints.clear();
      _draftGeometryGeneration++;
      _requestDraftRepaint();
      final selected = <String>{};
      final bounds = _pointsBounds(points, size);
      if (bounds != null) {
        for (
          var strokeIndex = 0;
          strokeIndex < _workingDocument.strokes.length;
          strokeIndex++
        ) {
          final stroke = _workingDocument.strokes[strokeIndex];
          if (stroke.tool == StrokeTool.eraser) continue;
          final visiblePoints = _visibleStrokePoints(strokeIndex, size);
          final matches = widget.controller.lassoMode == LassoMode.free
              ? visiblePoints.any((p) => _polygonContains(p, points))
              : visiblePoints.any(
                  (p) => bounds.contains(_denormalize(p, size)),
                );
          if (matches) {
            selected.add(stroke.id);
          }
        }
        for (final text in _workingDocument.texts) {
          final matches = widget.controller.lassoMode == LassoMode.free
              ? _polygonContains(text.center, points)
              : bounds.contains(_textRect(text, size).center);
          if (matches) {
            selected.add(text.id);
          }
        }
      }
      _selectionContour = widget.controller.lassoMode == LassoMode.free
          ? points
          : null;
      widget.controller.selectAnnotations(selected);
    } else if (tool == DrawingTool.ballpoint ||
        tool == DrawingTool.pencil ||
        tool == DrawingTool.highlighter) {
      final before = _workingDocument;
      final stroke = PageStroke(
        id: 'stroke-${DateTime.now().microsecondsSinceEpoch}',
        tool: switch (tool) {
          DrawingTool.ballpoint => StrokeTool.ballpoint,
          DrawingTool.pencil => StrokeTool.pencil,
          _ => StrokeTool.highlighter,
        },
        colorValue: widget.controller.colorFor(tool),
        width: widget.controller.widthFor(tool),
        opacity: tool == DrawingTool.highlighter ? .42 : 1,
        points: points,
      );
      _workingDocument = before.copyWith(strokes: [...before.strokes, stroke]);
      _pendingCommittedStrokeIds.add(stroke.id);
      widget.onChanged(_workingDocument);
      _deferDraftClearAfterCommit(++_draftCommitGeneration);
    } else if (tool == DrawingTool.eraser) {
      widget.onChanged(_workingDocument);
    }
    setState(() {});
  }

  void _onPanCancel(Size size) {
    if (_isErasing) {
      _workingDocument = _gestureBeforeDocument ?? _workingDocument;
      _finishEraserGesture();
    }
    if (_movingSelection) widget.controller.endAnnotationDrag();
    _movingSelection = false;
    _transforming = false;
    _rotating = false;
    _textTransformSession = null;
    _transformStartPoint = null;
    _transformStartBounds = null;
    _draftPoints.clear();
    _requestDraftRepaint();
    _lastPoint = null;
    if (mounted) setState(() {});
  }

  Offset _normalize(Offset point, Size size) => Offset(
    size.width <= 0 ? 0 : (point.dx / size.width).clamp(0, 1),
    size.height <= 0 ? 0 : (point.dy / size.height).clamp(0, 1),
  );

  Offset _denormalize(Offset point, Size size) =>
      Offset(point.dx * size.width, point.dy * size.height);

  bool _polygonContains(Offset point, List<Offset> polygon) {
    if (polygon.length < 3) return false;
    var inside = false;
    for (
      var index = 0, previous = polygon.length - 1;
      index < polygon.length;
      previous = index++
    ) {
      final current = polygon[index];
      final prior = polygon[previous];
      final crosses =
          ((current.dy > point.dy) != (prior.dy > point.dy)) &&
          (point.dx <
              (prior.dx - current.dx) *
                      (point.dy - current.dy) /
                      (prior.dy - current.dy == 0
                          ? 1e-9
                          : prior.dy - current.dy) +
                  current.dx);
      if (crosses) inside = !inside;
    }
    return inside;
  }

  List<Offset> _visibleStrokePoints(int strokeIndex, Size size) {
    final stroke = _workingDocument.strokes[strokeIndex];
    return [
      for (final point in stroke.points)
        if (!_isPointErasedByLaterPath(strokeIndex, point, size)) point,
    ];
  }

  bool _isPointErasedByLaterPath(int strokeIndex, Offset point, Size size) {
    final target = _denormalize(point, size);
    for (
      var index = strokeIndex + 1;
      index < _workingDocument.strokes.length;
      index++
    ) {
      final eraser = _workingDocument.strokes[index];
      if (eraser.tool != StrokeTool.eraser || eraser.points.isEmpty) continue;
      final radius = eraser.width;
      final eraserPoints = eraser.points
          .map((value) => _denormalize(value, size))
          .toList();
      if (eraserPoints.length == 1 &&
          (target - eraserPoints.first).distance <= radius) {
        return true;
      }
      for (var pointIndex = 1; pointIndex < eraserPoints.length; pointIndex++) {
        if (_distanceToSegment(
              target,
              eraserPoints[pointIndex - 1],
              eraserPoints[pointIndex],
            ) <=
            radius) {
          return true;
        }
      }
    }
    return false;
  }

  double _distanceToSegment(Offset point, Offset start, Offset end) {
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared == 0) return (point - start).distance;
    final projection =
        ((point.dx - start.dx) * delta.dx + (point.dy - start.dy) * delta.dy) /
        lengthSquared;
    final t = projection.clamp(0.0, 1.0).toDouble();
    final closest = Offset(start.dx + delta.dx * t, start.dy + delta.dy * t);
    return (point - closest).distance;
  }

  List<String> _strokeIdsNear(Offset point, Size size, double radius) => [
    for (
      var strokeIndex = 0;
      strokeIndex < _workingDocument.strokes.length;
      strokeIndex++
    )
      if (_workingDocument.strokes[strokeIndex].tool != StrokeTool.eraser &&
          _visibleStrokePoints(
            strokeIndex,
            size,
          ).any((p) => (_denormalize(p, size) - point).distance <= radius))
        _workingDocument.strokes[strokeIndex].id,
  ];

  PageTextObject? _textAt(Offset point, Size size) {
    for (final text in _workingDocument.texts.reversed) {
      final bounds = _textRect(text, size);
      if (_containsRotatedRect(point, bounds, text.rotation)) return text;
    }
    return null;
  }

  Rect _textRect(PageTextObject text, Size size) {
    final width = text.width * size.width * text.scale;
    final height = text.height * size.height * text.scale;
    return Rect.fromCenter(
      center: _denormalize(text.center, size),
      width: width,
      height: height,
    );
  }

  Rect? _pointsBounds(List<Offset> points, Size size) {
    if (points.isEmpty) return null;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final point in points) {
      final value = _denormalize(point, size);
      left = math.min(left, value.dx);
      top = math.min(top, value.dy);
      right = math.max(right, value.dx);
      bottom = math.max(bottom, value.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? _selectionBounds(Size size) {
    final ids = widget.controller.selectedAnnotationIds;
    if (ids.isEmpty) return null;
    final rects = <Rect>[];
    for (
      var strokeIndex = 0;
      strokeIndex < _workingDocument.strokes.length;
      strokeIndex++
    ) {
      final stroke = _workingDocument.strokes[strokeIndex];
      if (stroke.tool == StrokeTool.eraser || !ids.contains(stroke.id)) {
        continue;
      }
      final bounds = _pointsBounds(
        _visibleStrokePoints(strokeIndex, size),
        size,
      );
      if (bounds != null) rects.add(bounds.inflate(stroke.width));
    }
    for (final text in _workingDocument.texts) {
      if (ids.contains(text.id)) rects.add(_textRect(text, size));
    }
    if (rects.isEmpty) return null;
    var result = rects.first;
    for (final rect in rects.skip(1)) {
      result = result.expandToInclude(rect);
    }
    return result;
  }

  void _translateSelection(Offset delta) {
    if (_selectionContour != null) {
      _selectionContour = [
        for (final point in _selectionContour!)
          Offset(point.dx + delta.dx, point.dy + delta.dy),
      ];
    }
    final ids = widget.controller.selectedAnnotationIds;
    _workingDocument = _workingDocument.copyWith(
      strokes: [
        for (final stroke in _workingDocument.strokes)
          ids.contains(stroke.id)
              ? stroke.copyWith(
                  points: [
                    for (final point in stroke.points)
                      Offset(
                        (point.dx + delta.dx).clamp(-.9, 1.9),
                        (point.dy + delta.dy).clamp(-.9, 1.9),
                      ),
                  ],
                )
              : stroke,
      ],
      texts: [
        for (final text in _workingDocument.texts)
          ids.contains(text.id)
              ? text.copyWith(
                  center: Offset(
                    (text.center.dx + delta.dx).clamp(-.9, 1.9),
                    (text.center.dy + delta.dy).clamp(-.9, 1.9),
                  ),
                )
              : text,
      ],
    );
  }

  void _scaleSelection(double factor, Size size) {
    final bounds = _transformStartBounds;
    if (bounds == null) return;
    final center = Offset(
      bounds.center.dx / size.width,
      bounds.center.dy / size.height,
    );
    final ids = widget.controller.selectedAnnotationIds;
    _workingDocument = _workingDocument.copyWith(
      texts: [
        for (final text in _workingDocument.texts)
          ids.contains(text.id)
              ? text.copyWith(
                  center: Offset(
                    center.dx + (text.center.dx - center.dx) * factor,
                    center.dy + (text.center.dy - center.dy) * factor,
                  ),
                  scale: (text.scale * factor).clamp(.05, 20),
                )
              : text,
      ],
      strokes: [
        for (final stroke in _workingDocument.strokes)
          if (ids.contains(stroke.id))
            stroke.copyWith(
              points: [
                for (final point in stroke.points)
                  Offset(
                    center.dx + (point.dx - center.dx) * factor,
                    center.dy + (point.dy - center.dy) * factor,
                  ),
              ],
            )
          else
            stroke,
      ],
    );
  }

  void _rotateSelection(double angle, Size size) {
    final bounds = _transformStartBounds;
    if (bounds == null) return;
    final center = Offset(
      bounds.center.dx / size.width,
      bounds.center.dy / size.height,
    );
    final ids = widget.controller.selectedAnnotationIds;
    _workingDocument = _workingDocument.copyWith(
      texts: [
        for (final text in _workingDocument.texts)
          ids.contains(text.id)
              ? text.copyWith(
                  center: _rotatePoint(text.center, center, angle),
                  rotation: text.rotation + angle,
                )
              : text,
      ],
      strokes: [
        for (final stroke in _workingDocument.strokes)
          ids.contains(stroke.id)
              ? stroke.copyWith(
                  points: [
                    for (final point in stroke.points)
                      _rotatePoint(point, center, angle),
                  ],
                )
              : stroke,
      ],
    );
  }

  Offset _rotatePoint(Offset point, Offset center, double angle) {
    final dx = point.dx - center.dx;
    final dy = point.dy - center.dy;
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    return Offset(
      center.dx + dx * cosine - dy * sine,
      center.dy + dx * sine + dy * cosine,
    );
  }

  Widget _buildTextObject(PageTextObject text, Size size) {
    final rect = _textRect(text, size);
    final editing = _editingTextId == text.id;
    final keyboardReady = _textKeyboardReadyId == text.id;
    final controller = _textControllers[text.id];
    final node = _textFocusNodes[text.id];
    final textAlign = switch (text.alignment) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      _ => TextAlign.left,
    };
    final style = TextStyle(
      color: Color(text.colorValue),
      fontFamily: text.fontFamily,
      fontSize: text.fontSize * text.scale,
      height: text.lineSpacing,
      letterSpacing: text.letterSpacing * text.scale,
      fontWeight: text.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
      decoration: text.underline
          ? TextDecoration.underline
          : TextDecoration.none,
      shadows: text.shadow
          ? const [
              Shadow(
                color: Color(0x40000000),
                blurRadius: 2,
                offset: Offset(1, 1),
              ),
            ]
          : null,
    );
    final textInset = EdgeInsets.symmetric(
      horizontal: 8 * text.scale,
      vertical: 6 * text.scale,
    );
    final child = editing && controller != null && node != null
        ? TextField(
            key: const Key('book_page_editor_annotation_text_input'),
            controller: controller,
            focusNode: node,
            expands: true,
            maxLines: null,
            readOnly: !keyboardReady,
            showCursor: true,
            autofocus: false,
            style: style,
            textAlign: textAlign,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration.collapsed(hintText: '点此输入文字'),
            onTap: () {
              if (!keyboardReady) {
                setState(() => _textKeyboardReadyId = text.id);
              }
            },
            onChanged: (value) {
              final before = _workingDocument;
              _workingDocument = before.copyWith(
                texts: [
                  for (final item in before.texts)
                    item.id == text.id ? item.copyWith(text: value) : item,
                ],
              );
              widget.onChanged(_workingDocument);
            },
          )
        : Align(
            alignment: switch (text.alignment) {
              'right' => Alignment.centerRight,
              'center' => Alignment.center,
              _ => Alignment.centerLeft,
            },
            child: Text(
              text.text.isEmpty ? '点此输入文字' : text.text,
              textAlign: textAlign,
              style: style.copyWith(
                color: text.text.isEmpty
                    ? NotePageTheme.muted
                    : Color(text.colorValue),
              ),
            ),
          );
    final interaction = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectTextObject(text.id),
      onDoubleTap: () => _beginEditingText(text.id),
      child: editing
          ? _TextEditorGlassSurface(
              borderRadius: 16,
              child: Padding(padding: textInset, child: child),
            )
          : Padding(padding: textInset, child: child),
    );
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: editing
          ? interaction
          : Transform.rotate(angle: text.rotation, child: interaction),
    );
  }

  Widget _buildAnnotationActionBar(Rect bounds, Size size) {
    final width = math.min(460.0, size.width - 24);
    final left = (bounds.center.dx - width / 2)
        .clamp(12.0, math.max(12.0, size.width - width - 12))
        .toDouble();
    final top = (bounds.bottom + 10)
        .clamp(0.0, math.max(0.0, size.height - 64))
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: _DrawingCapsuleSurface(
        maxWidth: width,
        height: 56,
        pointerFraction: .5,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _OptionTextButton(
              label: '复制',
              icon: Icons.copy_outlined,
              onPressed: () {
                _copySelection();
                widget.onAction(_AnnotationAction.copy);
              },
            ),
            _OptionTextButton(
              label: '颜色',
              icon: Icons.circle,
              onPressed: () => widget.onAction(_AnnotationAction.color),
            ),
            _OptionTextButton(
              label: '编辑',
              icon: Icons.crop_free,
              onPressed: () => widget.onAction(_AnnotationAction.edit),
            ),
            _OptionTextButton(
              label: '删除',
              icon: Icons.delete_outline,
              onPressed: () {
                _deleteSelection();
                widget.onAction(_AnnotationAction.delete);
              },
            ),
          ],
        ),
      ),
    );
  }

  Offset _rotatePixelPoint(Offset point, Offset center, double angle) {
    final delta = point - center;
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    return Offset(
      center.dx + delta.dx * cosine - delta.dy * sine,
      center.dy + delta.dx * sine + delta.dy * cosine,
    );
  }

  bool _containsRotatedRect(Offset point, Rect bounds, double rotation) {
    final unrotatedPoint = _rotatePixelPoint(point, bounds.center, -rotation);
    return bounds.contains(unrotatedPoint);
  }

  List<Widget> _buildTextTransformActions(
    PageTextObject text,
    Rect bounds,
    Size size,
  ) {
    const touchSize = 44.0;
    final center = bounds.center;
    final topLeft = _rotatePixelPoint(bounds.topLeft, center, text.rotation);
    final topRight = _rotatePixelPoint(bounds.topRight, center, text.rotation);
    final bottomRight = _rotatePixelPoint(
      bounds.bottomRight,
      center,
      text.rotation,
    );

    double clampLeft(double value) =>
        value.clamp(8.0, math.max(8.0, size.width - touchSize - 8)).toDouble();
    double clampTop(double value) =>
        value.clamp(8.0, math.max(8.0, size.height - touchSize - 8)).toDouble();
    return [
      Positioned(
        left: clampLeft(topLeft.dx - touchSize / 2),
        top: clampTop(topLeft.dy - touchSize / 2),
        width: touchSize,
        height: touchSize,
        child: _TextTransformActionButton(
          key: const Key('book_page_editor_text_delete'),
          label: '删除文字',
          icon: Icons.delete_outline,
          onPressed: _deleteSelection,
        ),
      ),
      Positioned(
        left: clampLeft(topRight.dx - touchSize / 2),
        top: clampTop(topRight.dy - touchSize / 2),
        width: touchSize,
        height: touchSize,
        child: _TextTransformActionButton(
          key: const Key('book_page_editor_text_edit'),
          label: '编辑文字',
          icon: Icons.edit_outlined,
          onPressed: () {
            final id = widget.controller.selectedAnnotationIds.length == 1
                ? widget.controller.selectedAnnotationIds.first
                : null;
            if (id != null) _beginEditingText(id);
          },
        ),
      ),
      Positioned(
        left: clampLeft(bottomRight.dx - touchSize / 2),
        top: clampTop(bottomRight.dy - touchSize / 2),
        width: touchSize,
        height: touchSize,
        child: IgnorePointer(
          child: _TextTransformHandleIndicator(
            key: const Key('book_page_editor_text_transform_handle'),
            rotation: text.rotation,
          ),
        ),
      ),
    ];
  }

  Widget _buildTextContextBar(PageTextObject text, Rect? bounds, Size size) {
    if (bounds == null || widget.controller.activeTool != DrawingTool.text) {
      return const SizedBox.shrink();
    }
    final width = math.min(420.0, size.width - 48);
    final left = (bounds.center.dx - width / 2)
        .clamp(24.0, math.max(24.0, size.width - width - 24))
        .toDouble();
    final top = (bounds.top - 52)
        .clamp(0.0, math.max(0.0, size.height - 48))
        .toDouble();
    final itemWidth = (width - 3) / 4;
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: _TextEditorGlassSurface(
        borderRadius: 14,
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: itemWidth,
              child: _TextContextAction(
                label: '字体',
                icon: Icons.text_fields,
                selected: _textCategory == _TextCategory.font,
                onPressed: () => _selectTextCategory(_TextCategory.font),
              ),
            ),
            const SizedBox(
              width: 1,
              height: 22,
              child: ColoredBox(color: NotePageTheme.line),
            ),
            SizedBox(
              width: itemWidth,
              child: _TextContextAction(
                label: '颜色',
                icon: Icons.circle,
                selected: _textCategory == _TextCategory.color,
                onPressed: () => _selectTextCategory(_TextCategory.color),
              ),
            ),
            const SizedBox(
              width: 1,
              height: 22,
              child: ColoredBox(color: NotePageTheme.line),
            ),
            SizedBox(
              width: itemWidth,
              child: _TextContextAction(
                label: '样式',
                icon: Icons.format_bold,
                selected: _textCategory == _TextCategory.style,
                onPressed: () => _selectTextCategory(_TextCategory.style),
              ),
            ),
            const SizedBox(
              width: 1,
              height: 22,
              child: ColoredBox(color: NotePageTheme.line),
            ),
            SizedBox(
              width: itemWidth,
              child: _TextContextAction(
                label: '排版',
                icon: Icons.format_align_left,
                selected: _textCategory == _TextCategory.layout,
                onPressed: () => _selectTextCategory(_TextCategory.layout),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTextCategory(_TextCategory category) {
    setState(() {
      _textCategory = category;
      if (category != _TextCategory.color) {
        _customTextColorOpen = false;
      }
    });
  }

  Widget _buildTextPropertyPanel(PageTextObject text, Rect bounds, Size size) {
    final category = _textCategory!;
    final basePanelHeight = category == _TextCategory.font
        ? 120.0
        : category == _TextCategory.layout
        ? 96.0
        : 78.0;
    final isFontPanel = category == _TextCategory.font;
    final panelWidth = isFontPanel
        ? math.min(420.0, size.width - 48)
        : math.min(680.0, size.width - 24);
    final horizontalInset = isFontPanel ? 24.0 : 12.0;
    final left = (bounds.center.dx - panelWidth / 2)
        .clamp(
          horizontalInset,
          math.max(horizontalInset, size.width - panelWidth - horizontalInset),
        )
        .toDouble();
    final customColorOpen =
        category == _TextCategory.color && _customTextColorOpen;
    var top = bounds.bottom + 10;
    if (!customColorOpen && top + basePanelHeight > size.height - 8) {
      top = math.max(8, bounds.top - basePanelHeight - 10);
    }
    final content = switch (category) {
      _TextCategory.font => _buildFontChoices(text),
      _TextCategory.color => _buildColorChoices(text),
      _TextCategory.style => _buildStyleChoices(text),
      _TextCategory.layout => _buildLayoutChoices(text),
    };
    return Positioned(
      left: left,
      top: top,
      width: panelWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DrawingCapsuleSurface(
            key: category == _TextCategory.color
                ? const Key('book_page_editor_text_color_choices_surface')
                : null,
            maxWidth: panelWidth,
            height: basePanelHeight,
            pointerFraction: .5,
            child: content,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            child: customColorOpen
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math
                            .max(0.0, size.height - top - basePanelHeight - 16)
                            .toDouble(),
                      ),
                      child: SingleChildScrollView(
                        child: _InlineTextColorPicker(
                          key: const Key('book_page_editor_text_custom_color'),
                          color: Color(text.colorValue),
                          onChanged: (value) => _updateText(
                            text.id,
                            (item) => item.copyWith(colorValue: value),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildFontChoices(PageTextObject text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: GridView.builder(
        key: const Key('book_page_editor_font_grid'),
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 46,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _textFontChoices.length,
        itemBuilder: (context, index) {
          final choice = _textFontChoices[index];
          return _TextChoiceButton(
            key: ValueKey('book_page_editor_font_${choice.id}'),
            label: choice.label,
            style: TextStyle(fontFamily: choice.family, fontSize: 17),
            selected: text.fontFamily == choice.family,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(fontFamily: choice.family),
            ),
          );
        },
      ),
    );
  }

  Widget _buildColorChoices(PageTextObject text) {
    const colors = [
      0xFF1A1A1A,
      0xFF3559A6,
      0xFFC54237,
      0xFF2E6B4E,
      0xFFF6C945,
      0xFFA6741E,
      0xFF6E43A3,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          for (final value in colors)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _ColorDot(
                color: Color(value),
                selected: text.colorValue == value,
                onPressed: () => _updateText(
                  text.id,
                  (item) => item.copyWith(colorValue: value),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _ColorDot(
              key: const Key('book_page_editor_text_custom_color_button'),
              color: null,
              selected:
                  _customTextColorOpen || !colors.contains(text.colorValue),
              onPressed: () =>
                  setState(() => _customTextColorOpen = !_customTextColorOpen),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleChoices(PageTextObject text) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _OptionTextButton(
            label: '粗体',
            icon: Icons.format_bold,
            selected: text.bold,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(bold: !value.bold),
            ),
          ),
          _OptionTextButton(
            label: '斜体',
            icon: Icons.format_italic,
            selected: text.italic,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(italic: !value.italic),
            ),
          ),
          _OptionTextButton(
            label: '下划线',
            icon: Icons.format_underline,
            selected: text.underline,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(underline: !value.underline),
            ),
          ),
          _OptionTextButton(
            label: '描边',
            icon: Icons.border_color_outlined,
            selected: text.outline,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(outline: !value.outline),
            ),
          ),
          _OptionTextButton(
            label: '阴影',
            icon: Icons.text_fields,
            selected: text.shadow,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(shadow: !value.shadow),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayoutChoices(PageTextObject text) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _OptionTextButton(
            label: '左对齐',
            icon: Icons.format_align_left,
            selected: text.alignment == 'left',
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(alignment: 'left'),
            ),
          ),
          _OptionTextButton(
            label: '居中',
            icon: Icons.format_align_center,
            selected: text.alignment == 'center',
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(alignment: 'center'),
            ),
          ),
          _OptionTextButton(
            label: '右对齐',
            icon: Icons.format_align_right,
            selected: text.alignment == 'right',
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(alignment: 'right'),
            ),
          ),
          _OptionTextButton(
            label: '字距',
            icon: Icons.space_bar,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(
                letterSpacing: (value.letterSpacing + .5).clamp(0, 8),
              ),
            ),
          ),
          _OptionTextButton(
            label: '行距',
            icon: Icons.format_line_spacing,
            onPressed: () => _updateText(
              text.id,
              (value) => value.copyWith(
                lineSpacing: (value.lineSpacing + .1).clamp(.8, 3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _updateText(String id, PageTextObject Function(PageTextObject) update) {
    final before = _workingDocument;
    _workingDocument = before.copyWith(
      texts: [
        for (final item in before.texts) item.id == id ? update(item) : item,
      ],
    );
    widget.onChanged(_workingDocument);
    setState(() {});
  }

  void _deleteSelection() {
    final ids = widget.controller.selectedAnnotationIds;
    if (ids.isEmpty) return;
    _workingDocument = _workingDocument.copyWith(
      strokes: _workingDocument.strokes
          .where((stroke) => !ids.contains(stroke.id))
          .toList(),
      texts: _workingDocument.texts
          .where((text) => !ids.contains(text.id))
          .toList(),
    );
    widget.controller.clearSelection();
    widget.onChanged(_workingDocument);
    setState(() {});
  }

  void _copySelection() {
    final ids = widget.controller.selectedAnnotationIds;
    if (ids.isEmpty) return;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copiedStrokes = [
      for (final stroke in _workingDocument.strokes)
        if (ids.contains(stroke.id))
          stroke.copyWith(
            id: '${stroke.id}-copy-$stamp',
            points: [
              for (final point in stroke.points)
                Offset(
                  (point.dx + .03).clamp(0, 1),
                  (point.dy + .03).clamp(0, 1),
                ),
            ],
          ),
    ];
    final copiedTexts = [
      for (final text in _workingDocument.texts)
        if (ids.contains(text.id))
          text.copyWith(
            id: '${text.id}-copy-$stamp',
            center: Offset(
              (text.center.dx + .03).clamp(0, 1),
              (text.center.dy + .03).clamp(0, 1),
            ),
          ),
    ];
    _workingDocument = _workingDocument.copyWith(
      strokes: [..._workingDocument.strokes, ...copiedStrokes],
      texts: [..._workingDocument.texts, ...copiedTexts],
    );
    widget.onChanged(_workingDocument);
    setState(() {});
  }
}

class _ImageEditHandle extends StatelessWidget {
  const _ImageEditHandle({required this.icon, this.destructive = false});

  final IconData icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFCFBF8),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD8D3CC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
          BoxShadow(
            color: Color(0xBFFFFFFF),
            blurRadius: 1,
            offset: Offset(0, -1),
          ),
        ],
      ),
      child: SizedBox.square(
        dimension: 32,
        child: Icon(
          icon,
          size: 16,
          color: destructive
              ? const Color(0xFF8A3E34)
              : const Color(0xFF403C37),
        ),
      ),
    );
  }
}

class _ImageSelectionFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Rect.fromLTWH(
      .75,
      .75,
      math.max(0.0, size.width - 1.5).toDouble(),
      math.max(0.0, size.height - 1.5).toDouble(),
    );
    final border = Paint()
      ..color = const Color(0xB35F5B56)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      border,
    );

    const corner = 12.0;
    final corners = Path()
      ..moveTo(rect.left, rect.top + corner)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + corner, rect.top)
      ..moveTo(rect.right - corner, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + corner)
      ..moveTo(rect.right, rect.bottom - corner)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - corner, rect.bottom)
      ..moveTo(rect.left + corner, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - corner);
    canvas.drawPath(
      corners,
      Paint()
        ..color = const Color(0xFF403C37)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ImageSelectionFramePainter oldDelegate) =>
      false;
}

class _LiveAnnotationPainter extends CustomPainter {
  _LiveAnnotationPainter({
    required this.points,
    required Listenable repaint,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.geometryGeneration,
    required this.eraserPosition,
    required this.eraserRadius,
    required this.isErasing,
  }) : super(repaint: repaint);

  final List<Offset> points;
  final DrawingTool tool;
  final Color color;
  final double width;
  final double opacity;
  final int geometryGeneration;
  final Offset? Function() eraserPosition;
  final double eraserRadius;
  final bool Function() isErasing;

  final _pixelPoints = <Offset>[];
  int _processedPointCount = 0;
  Size? _pathSize;
  Offset? _firstPoint;
  int _seenGeometryGeneration = -1;

  @override
  void paint(Canvas canvas, Size size) {
    if (tool == DrawingTool.eraser) {
      _paintEraserCursor(canvas);
      return;
    }
    _syncPixelPoints(size);
    if (points.isEmpty) return;
    // A lone contact is intentionally kept in the model for tap strokes, but
    // showing its round cap before the finger moves reads as a lagging dot.
    // Start every live drawing tool on the second real sample; committed
    // single-point strokes still render normally after pointer-up.
    if (_pixelPoints.length < 2 && tool != DrawingTool.laser) return;
    if (tool == DrawingTool.laser) {
      _AnnotationPainter._drawLaserDraftStroke(
        canvas,
        _pixelPoints,
        color,
        width,
        opacity,
      );
    } else {
      _AnnotationPainter._drawAnnotationStroke(
        canvas,
        _pixelPoints,
        tool: switch (tool) {
          DrawingTool.ballpoint => StrokeTool.ballpoint,
          DrawingTool.pencil => StrokeTool.pencil,
          _ => StrokeTool.highlighter,
        },
        color: color,
        width: width,
        opacity: opacity,
      );
    }
  }

  void _syncPixelPoints(Size size) {
    final needsReset =
        _seenGeometryGeneration != geometryGeneration ||
        _pathSize != size ||
        points.length < _processedPointCount ||
        (points.isNotEmpty && _firstPoint != points.first);
    if (needsReset) {
      _pixelPoints.clear();
      _processedPointCount = 0;
      _firstPoint = null;
      _seenGeometryGeneration = geometryGeneration;
    }
    _pathSize = size;
    if (points.isEmpty) {
      _processedPointCount = 0;
      _firstPoint = null;
      return;
    }

    if (_processedPointCount == 0) {
      final first = Offset(
        points.first.dx * size.width,
        points.first.dy * size.height,
      );
      _pixelPoints.add(first);
      _processedPointCount = 1;
      _firstPoint = points.first;
    }
    for (var index = _processedPointCount; index < points.length; index++) {
      final point = Offset(
        points[index].dx * size.width,
        points[index].dy * size.height,
      );
      _pixelPoints.add(point);
    }
    _processedPointCount = points.length;
  }

  void _paintEraserCursor(Canvas canvas) {
    if (!isErasing()) return;
    final center = eraserPosition();
    if (center == null) return;
    canvas.drawCircle(
      center,
      eraserRadius,
      Paint()
        ..color = const Color(0x263A4650)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      eraserRadius,
      Paint()
        ..color = const Color(0x99636E76)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _LiveAnnotationPainter oldDelegate) => true;
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter({
    required this.document,
    this.documentProvider,
    this.skipStrokeId,
    required List<Offset> draftPoints,
    super.repaint,
    required this.draftTool,
    required this.draftColor,
    required this.draftWidth,
    required this.draftOpacity,
    required this.currentEraserPosition,
    required this.eraserRadius,
    required this.isErasing,
    required this.selectedIds,
    required this.selectionContour,
    required this.selectionBounds,
    required this.transformMode,
  }) : draftPoints = List.unmodifiable(draftPoints);

  final PageAnnotationDocument document;
  final PageAnnotationDocument Function()? documentProvider;
  final String? skipStrokeId;
  final List<Offset> draftPoints;
  final DrawingTool draftTool;
  final Color draftColor;
  final double draftWidth;
  final double draftOpacity;
  final Offset? currentEraserPosition;
  final double eraserRadius;
  final bool isErasing;
  final Set<String> selectedIds;
  final List<Offset>? selectionContour;
  final Rect? selectionBounds;
  final bool transformMode;

  @override
  void paint(Canvas canvas, Size size) {
    final paintDocument = documentProvider?.call() ?? document;
    final hasEraser = paintDocument.strokes.any(
      (stroke) => stroke.tool == StrokeTool.eraser,
    );
    if (hasEraser) {
      // Clear must be replayed in a layer containing only annotations. This
      // keeps the book text underneath intact while preserving stroke order.
      canvas.saveLayer(Offset.zero & size, Paint());
    }
    for (final stroke in paintDocument.strokes) {
      if (stroke.id == skipStrokeId) continue;
      if (stroke.points.isEmpty) continue;
      final points = [
        for (final point in stroke.points)
          Offset(point.dx * size.width, point.dy * size.height),
      ];
      _drawAnnotationStroke(
        canvas,
        points,
        tool: stroke.tool,
        color: stroke.tool == StrokeTool.eraser
            ? Colors.white
            : Color(stroke.colorValue),
        width: stroke.tool == StrokeTool.eraser
            ? stroke.width * 2
            : stroke.width,
        opacity: stroke.opacity,
      );
    }
    if (draftPoints.length >= 2 && draftTool != DrawingTool.eraser) {
      final points = [
        for (final point in draftPoints)
          Offset(point.dx * size.width, point.dy * size.height),
      ];
      if (draftTool == DrawingTool.laser) {
        _drawLaserDraftStroke(
          canvas,
          points,
          draftColor,
          draftWidth,
          draftOpacity,
        );
      } else if (draftTool == DrawingTool.lasso) {
        final path = _pathForPoints(points);
        final previewPaint = Paint()
          ..color = const Color(0xFF1687C8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = draftWidth
          ..strokeCap = StrokeCap.round;
        _drawDashedPath(canvas, path, previewPaint);
      } else {
        _drawAnnotationStroke(
          canvas,
          points,
          tool: switch (draftTool) {
            DrawingTool.ballpoint => StrokeTool.ballpoint,
            DrawingTool.pencil => StrokeTool.pencil,
            _ => StrokeTool.highlighter,
          },
          color: draftColor,
          width: draftWidth,
          opacity: draftOpacity,
        );
      }
    }
    if (hasEraser) canvas.restore();

    if (isErasing && currentEraserPosition != null) {
      final center = currentEraserPosition!;
      canvas.drawCircle(
        center,
        eraserRadius,
        Paint()
          ..color = const Color(0x263A4650)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        eraserRadius,
        Paint()
          ..color = const Color(0x99636E76)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final bounds = selectionBounds;
    if (bounds == null || selectedIds.isEmpty) return;
    final selectedPaint = Paint()
      ..color = draftTool == DrawingTool.lasso
          ? const Color(0xFF1687C8)
          : NotePageTheme.lineStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    if (transformMode) {
      final selectedText =
          draftTool == DrawingTool.text && selectedIds.length == 1
          ? paintDocument.texts
                .where((text) => selectedIds.contains(text.id))
                .firstOrNull
          : null;
      final frameRotation = selectedText?.rotation ?? 0;
      final shouldRotateFrame = frameRotation.abs() > 0.0001;
      if (shouldRotateFrame) {
        canvas.save();
        canvas.translate(bounds.center.dx, bounds.center.dy);
        canvas.rotate(frameRotation);
        canvas.translate(-bounds.center.dx, -bounds.center.dy);
      }
      canvas.drawRect(bounds, selectedPaint);
      if (draftTool != DrawingTool.text) {
        for (final point in [
          bounds.topLeft,
          bounds.topRight,
          bounds.bottomLeft,
          bounds.bottomRight,
        ]) {
          canvas.drawCircle(
            point,
            7,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(point, 7, selectedPaint);
        }
      }
      if (draftTool == DrawingTool.lasso) {
        canvas.drawLine(
          Offset(bounds.center.dx, bounds.top),
          Offset(bounds.center.dx, bounds.top - 24),
          selectedPaint,
        );
        canvas.drawCircle(
          Offset(bounds.center.dx, bounds.top - 28),
          6,
          selectedPaint,
        );
      }
      if (shouldRotateFrame) canvas.restore();
    } else {
      if (selectionContour != null && selectionContour!.length >= 3) {
        final contour = Path()
          ..moveTo(
            selectionContour!.first.dx * size.width,
            selectionContour!.first.dy * size.height,
          );
        for (final point in selectionContour!.skip(1)) {
          contour.lineTo(point.dx * size.width, point.dy * size.height);
        }
        contour.close();
        _drawDashedPath(canvas, contour, selectedPaint);
        return;
      }
      final path = Path()
        ..addRRect(
          RRect.fromRectAndRadius(bounds.inflate(8), const Radius.circular(18)),
        );
      final dotted = Paint()
        ..color = NotePageTheme.lineStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      _drawDashedPath(canvas, path, dotted);
    }
  }

  static Path _pathForPoints(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    return path;
  }

  static Path _smoothPathForPoints(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length == 1) return path;
    if (points.length == 2) {
      path.lineTo(points.last.dx, points.last.dy);
      return path;
    }

    // Pointer samples can be sparse when the UI thread is busy. Connecting
    // those samples with lineTo makes the renderer invent visibly straight
    // chords through a curved hand movement. Catmull-Rom controls preserve
    // every sample while keeping the tangent continuous through the curve.
    for (var index = 0; index < points.length - 1; index++) {
      final before = index == 0 ? points[index] : points[index - 1];
      final start = points[index];
      final end = points[index + 1];
      final after = index + 2 < points.length ? points[index + 2] : end;
      final firstControl = Offset(
        start.dx + (end.dx - before.dx) / 6,
        start.dy + (end.dy - before.dy) / 6,
      );
      final secondControl = Offset(
        end.dx - (after.dx - start.dx) / 6,
        end.dy - (after.dy - start.dy) / 6,
      );
      path.cubicTo(
        firstControl.dx,
        firstControl.dy,
        secondControl.dx,
        secondControl.dy,
        end.dx,
        end.dy,
      );
    }
    return path;
  }

  static void _drawAnnotationStroke(
    Canvas canvas,
    List<Offset> points, {
    required StrokeTool tool,
    required Color color,
    required double width,
    required double opacity,
  }) {
    if (points.isEmpty) return;
    if (tool == StrokeTool.pencil) {
      _drawPencilStroke(canvas, points, color, width, opacity);
      return;
    }
    final paint = Paint()
      ..color = tool == StrokeTool.eraser
          ? Colors.white
          : color.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = tool == StrokeTool.eraser
          ? BlendMode.clear
          : BlendMode.srcOver;
    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        tool == StrokeTool.eraser ? width / 2 : math.max(width / 2, 1),
        paint,
      );
      return;
    }
    canvas.drawPath(_smoothPathForPoints(points), paint);
  }

  static void _drawLaserDraftStroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
    double opacity,
  ) {
    final path = _smoothPathForPoints(points);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .28 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .96 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(
      points.last,
      math.max(width * 1.25, 2.5),
      Paint()..color = color.withValues(alpha: .96 * opacity),
    );
  }

  static void _drawPencilStroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
    double opacity,
  ) {
    final baseWidth = math.max(width, .8);
    // Use a dense, fine-grained pigment bed. Sparse large circles become a
    // visible bead chain on a real screen, which is unlike graphite on paper.
    // Keep enough granularity for a paper-like texture without turning every
    // predicted frame into a second, synthetic sample stream.
    final fiberWidth = math.max(baseWidth * .18, .35);
    final particleRadius = math.max(baseWidth * .16, .3);
    final jitter = (baseWidth * .16).clamp(.35, 2.2).toDouble();
    final samples = _pencilSamplePoints(points);

    // Keep the stroke connected, but let the fine pigment marks break the
    // edge and expose small areas of paper.
    if (samples.length > 1) {
      final underlay = Paint()
        ..color = color.withValues(
          alpha: (opacity * .13).clamp(0, 1).toDouble(),
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = baseWidth * .78
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(_smoothPathForPoints(samples), underlay);
    }

    // Batch the tiny pigment marks into a handful of drawPoints calls. The
    // previous implementation issued up to three Canvas commands per sample;
    // long strokes therefore made every history repaint increasingly costly.
    const bucketCount = 6;
    final pigmentBuckets = List.generate(bucketCount, (_) => <Offset>[]);
    final fleckBuckets = List.generate(bucketCount, (_) => <Offset>[]);
    final fiberBuckets = List.generate(bucketCount, (_) => <Offset>[]);
    for (var index = 0; index < samples.length; index++) {
      final point = samples[index];
      final density = .45 + .55 * _pencilNoise(point, index, phase: .3);
      final center = point + _pencilJitter(point, index, jitter);
      // Keep each sample's appearance local to that sample. Using the total
      // stroke length here makes every old particle change whenever a new
      // point arrives, which is the visible "self-adjusting" edge in the
      // recording.
      final taper = .86 + .14 * _pencilNoise(point, index, phase: 1.7);
      final bucket = (density * taper * bucketCount)
          .floor()
          .clamp(0, bucketCount - 1)
          .toInt();
      pigmentBuckets[bucket].add(center);

      // Tiny detached pigment flecks interrupt the bed without producing
      // obvious circular beads.
      if (density > .58 || index % 3 == 0) {
        final fleckOffset = _pencilJitter(
          point,
          index + 17,
          jitter * 1.8,
          phase: 1.4,
        );
        fleckBuckets[bucket].add(center + fleckOffset);
      }

      // Directional fibers add dry-brush breakup rather than a repeated-dot
      // pattern. Their geometry is deterministic for replay.
      if (index % 2 == 0 && samples.length > 1) {
        final previous = samples[index == 0 ? index : index - 1];
        final next = samples[index == samples.length - 1 ? index : index + 1];
        final tangent = next - previous;
        final length = tangent.distance;
        if (length > .01) {
          final direction = tangent / length;
          final fiberLength = baseWidth * (.5 + density * 1.25);
          final fiberCenter =
              center +
              _pencilJitter(point, index + 31, jitter * .75, phase: 2.2);
          fiberBuckets[bucket]
            ..add(fiberCenter - direction * (fiberLength / 2))
            ..add(fiberCenter + direction * (fiberLength / 2));
        }
      }
    }
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      final factor = (bucket + .5) / bucketCount;
      if (pigmentBuckets[bucket].isNotEmpty) {
        canvas.drawPoints(
          ui.PointMode.points,
          pigmentBuckets[bucket],
          Paint()
            ..color = color.withValues(
              alpha: (opacity * (.026 + factor * .07) * (.55 + factor * .45))
                  .clamp(0, 1)
                  .toDouble(),
            )
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(
              particleRadius * (.65 + factor * .65) * 2,
              .6,
            )
            ..strokeCap = StrokeCap.round,
        );
      }
      if (fleckBuckets[bucket].isNotEmpty) {
        canvas.drawPoints(
          ui.PointMode.points,
          fleckBuckets[bucket],
          Paint()
            ..color = color.withValues(
              alpha: (opacity * (.018 + factor * .038) * (.55 + factor * .45))
                  .clamp(0, 1)
                  .toDouble(),
            )
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(
              particleRadius * (.65 + factor * .65) * .84,
              .44,
            )
            ..strokeCap = StrokeCap.round,
        );
      }
      if (fiberBuckets[bucket].isNotEmpty) {
        canvas.drawPoints(
          ui.PointMode.lines,
          fiberBuckets[bucket],
          Paint()
            ..color = color.withValues(
              alpha: (opacity * (.028 + factor * .048) * (.55 + factor * .45))
                  .clamp(0, 1)
                  .toDouble(),
            )
            ..style = PaintingStyle.stroke
            ..strokeWidth = fiberWidth * (.65 + factor * .7)
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  static List<Offset> _pencilSamplePoints(List<Offset> points) {
    // Pointer input is already filtered to sub-pixel duplicates. Reusing the
    // real samples avoids a full PathMetric walk on every live frame; the
    // underlay still uses the shared smooth path and the batched pigment pass
    // keeps the same output for live and persisted strokes.
    return points;
  }

  static double _pencilNoise(
    Offset point,
    int index, {
    required double phase,
  }) =>
      (math.sin(point.dx * .13 + point.dy * .21 + index * 1.37 + phase) + 1) /
      2;

  static Offset _pencilJitter(
    Offset point,
    int index,
    double amplitude, {
    double phase = 0,
  }) => Offset(
    math.sin(point.dx * .19 + point.dy * .07 + index * 1.71 + phase) *
        amplitude,
    math.cos(point.dx * .11 - point.dy * .17 + index * 1.37 + phase) *
        amplitude *
        .72,
  );

  static void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final segment = metric.extractPath(
          distance,
          math.min(distance + 5, metric.length),
        );
        canvas.drawPath(segment, paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) =>
      !identical(oldDelegate.document, document) ||
      !listEquals(oldDelegate.draftPoints, draftPoints) ||
      oldDelegate.draftTool != draftTool ||
      oldDelegate.draftColor != draftColor ||
      oldDelegate.draftWidth != draftWidth ||
      oldDelegate.draftOpacity != draftOpacity ||
      oldDelegate.currentEraserPosition != currentEraserPosition ||
      oldDelegate.eraserRadius != eraserRadius ||
      oldDelegate.isErasing != isErasing ||
      !setEquals(oldDelegate.selectedIds, selectedIds) ||
      !listEquals(oldDelegate.selectionContour, selectionContour) ||
      oldDelegate.skipStrokeId != skipStrokeId ||
      oldDelegate.selectionBounds != selectionBounds ||
      oldDelegate.transformMode != transformMode;
}

class _EditorPageConsole extends StatelessWidget {
  const _EditorPageConsole({
    required this.pages,
    required this.current,
    required this.onSelect,
  });

  final List<_BookPageDraft> pages;
  final int current;
  final Future<void> Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return DefaultTextStyle(
      style: DefaultTextStyle.of(context).style.copyWith(
        decoration: TextDecoration.none,
        decorationColor: Colors.transparent,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: ColoredBox(
          color: NotePageTheme.soft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                const Row(
                  children: [
                    Expanded(
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
                            '编辑中 · 点击页面切换',
                            style: TextStyle(
                              color: NotePageTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 176,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: pages.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) => _EditorThumbnail(
                      page: pages[index],
                      index: index,
                      selected: index == current,
                      onTap: () => unawaited(onSelect(index)),
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

class _EditorThumbnail extends StatelessWidget {
  const _EditorThumbnail({
    required this.page,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final _BookPageDraft page;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '书页${index + 1}${selected ? '，当前页面' : ''}',
      child: GestureDetector(
        key: Key('book_page_editor_thumbnail_$index'),
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
                          child: BookPageDocumentView(
                            compact: true,
                            document: _thumbnailDocument(page.document),
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

/// 缩略图只需要表现出这一页的样子：几百个块以上的页面不再整页渲染，
/// 否则打开书页浮层会为每个缩略图排版上千个文本块。
const int _thumbnailBlockLimit = 200;

BookPageDocument _thumbnailDocument(BookPageDocument document) {
  final blocks = document.renderBlocks;
  if (blocks.length <= _thumbnailBlockLimit) return document;
  // copyWith 无法清空 editedBlocks，而 renderBlocks 优先取它，所以这里直接构造
  // 一个只用于渲染的截断副本。
  return BookPageDocument(
    schemaVersion: document.schemaVersion,
    blocks: List<OcrBlock>.unmodifiable(blocks.take(_thumbnailBlockLimit)),
    pageNumber: document.pageNumber,
    compatibilityMarkdown: document.compatibilityMarkdown,
  );
}

class _EditorPageCounter extends StatelessWidget {
  const _EditorPageCounter({
    super.key,
    required this.current,
    required this.total,
    this.pdf = false,
  });

  final int current;
  final int total;
  final bool pdf;

  @override
  Widget build(BuildContext context) {
    final label = pdf ? '第 $current / $total 页' : '$current/$total';
    return Semantics(
      label: pdf ? '原书第$current页，共$total页' : '第$current页，共$total页',
      container: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: pdf
              ? NotePageTheme.card.withValues(alpha: .94)
              : const Color(0xFFEDEDED),
          borderRadius: BorderRadius.circular(pdf ? 18 : 17),
          border: pdf ? Border.all(color: NotePageTheme.lineStrong) : null,
          boxShadow: pdf
              ? const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: pdf ? 12 : 20,
            vertical: pdf ? 7 : 12,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: NotePageTheme.inkSecondary,
              fontSize: pdf ? 12 : 16,
              fontWeight: pdf ? FontWeight.w600 : FontWeight.w700,
              decoration: TextDecoration.none,
              decorationColor: Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '编辑书页';
  return '${date.year}年${date.month}月${date.day}日 '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
