import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/note_page_theme.dart';
import '../models/book_source.dart';
import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../models/page_annotation.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/book_page_document_projection.dart';
import '../services/book_source_block_merger.dart';
import '../services/source_document_loader.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_page_document_content.dart';
import 'book_page_edit_page.dart';

/// Opens the existing book-page editor for a structured electronic source.
///
/// The editor still works with its established page draft contract. This
/// adapter projects each electronic chapter into a temporary Note and merges
/// the edited text back into a versioned XiaoqiDocument when the editor exits.
class BookSourceEditPage extends StatefulWidget {
  const BookSourceEditPage({
    super.key,
    required this.source,
    required this.bookLibraryService,
    this.catalogDrawerBuilder,
  });

  final BookSourceRecord source;
  final BookLibraryService bookLibraryService;
  final Widget Function(
    VoidCallback onClose,
    ValueChanged<int> onSelectPage,
    VoidCallback onFinishEditor,
  )? catalogDrawerBuilder;

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage> {
  String? _error;
  bool _opening = true;
  XiaoqiDocument? _loadedDocument;
  XiaoqiDocument? _pendingDocument;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openEditor());
    });
  }

  Future<void> _openEditor() async {
    try {
      final document = await _loadDocument();
      _loadedDocument = document;
      if (!mounted) return;
      final notes = _toEditorNotes(document);
      final editedNotes = await Navigator.of(context).push<List<Note>>(
        MaterialPageRoute(
          builder: (_) => BookPageEditPage(
            initialNote: notes.first,
            initialNotes: notes,
            initialIndex: 0,
            isDraft: true,
            bookId: widget.source.bookId,
            bookName: widget.source.displayName,
            catalogDrawerBuilder: widget.catalogDrawerBuilder,
            onDraftSaved: (notes) async {
              // The page editor is intentionally kept in draft mode so its
              // temporary chapter notes never pollute the notes table. Persist
              // the real source revision after the editor's save queue has
              // materialized a coherent snapshot of all chapters.
              final next = _mergeDocument(document, notes);
              _pendingDocument = next;
              await widget.bookLibraryService.saveBookSourceRevision(
                source: widget.source,
                document: next,
              );
            },
            onOriginalPage: (_) async {
              if (!mounted) return;
              AppToast.show(context, '原始资料文件保持不变，当前编辑的是应用内版本');
            },
          ),
        ),
      );
      if (!mounted) return;
      if (editedNotes == null) {
        Navigator.of(context).pop(false);
        return;
      }
      _pendingDocument = _mergeDocument(document, editedNotes);
      await _savePendingDocument();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _savePendingDocument() async {
    final document = _pendingDocument;
    if (document == null) return;
    if (mounted) {
      setState(() {
        _opening = false;
        _error = null;
      });
    }
    try {
      await widget.bookLibraryService.saveBookSourceRevision(
        source: widget.source,
        document: document,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      // 保存被结构防护拒绝时（见 DerivedDocumentGuard），把原因直接给用户看，
      // 不要带 “Bad state:” 前缀。
      setState(
        () => _error = error is StateError
            ? error.message.toString()
            : error.toString(),
      );
    }
  }

  Future<XiaoqiDocument> _loadDocument() async {
    final revision = await widget.bookLibraryService.loadBookSourceRevision(
      widget.source,
    );
    if (revision != null) return revision;
    if (!await File(widget.source.filePath).exists()) {
      throw StateError('找不到这份资料文件，请重新导入');
    }
    final loader = const SourceDocumentLoader();
    return loader.parseFile(
      widget.source.filePath,
      format: widget.source.format,
    );
  }

  List<Note> _toEditorNotes(XiaoqiDocument document) {
    final chapters = document.chapters.isEmpty
        ? [
            XiaoqiDocumentChapter(
              id: 'document',
              title: document.title,
              href: '',
              html: '',
              plainText: '',
              order: 0,
            ),
          ]
        : document.chapters;
    final now = DateTime.now().toIso8601String();
    return [
      for (var index = 0; index < chapters.length; index++)
        _noteForChapter(
          chapter: chapters[index],
          assets: document.assets,
          bookName: widget.source.displayName,
          bookId: widget.source.bookId,
          index: index,
          now: now,
        ),
    ];
  }

  Note _noteForChapter({
    required XiaoqiDocumentChapter chapter,
    List<XiaoqiDocumentAsset> assets = const [],
    required String bookName,
    required int bookId,
    required int index,
    required String now,
  }) {
    final pageDocument = BookPageDocumentProjection.chapterToPageDocument(
      chapter,
      assets: assets,
    );
    final documentJson = pageDocument.toJson();
    final annotation = _annotationForChapter(chapter.id);
    if (annotation != null) {
      documentJson.addAll(annotation);
    }
    return Note(
      type: 'text',
      title: chapter.title,
      content: chapter.plainText,
      sourceType: 'book_source_editor',
      bookName: bookName,
      bookPage: '${index + 1}',
      bookId: bookId,
      capturePageId: index,
      annotationsJson: jsonEncode(documentJson),
      createdAt: now,
      updatedAt: now,
    );
  }

  XiaoqiDocument _mergeDocument(
    XiaoqiDocument original,
    List<Note> editedNotes,
  ) {
    if (original.chapters.isEmpty && editedNotes.isNotEmpty) {
      final note = editedNotes.first;
      final pageDocument = BookPageDocumentContent.documentFor(note);
      final blocks = pageDocument.renderBlocks;
      return XiaoqiDocument(
        format: original.format,
        title: original.title,
        author: original.author,
        language: original.language,
        chapters: [
          XiaoqiDocumentChapter(
            id: 'document',
            title: note.title.trim(),
            href: '',
            html: '',
            plainText: blocks
                .where((block) => !block.isFurniture)
                .map((block) => block.readableText.trim())
                .where((value) => value.isNotEmpty)
                .join('\n\n'),
            order: 0,
            blocks: _mergeBlocks(const [], blocks),
          ),
        ],
        assets: original.assets,
        originalPageCount: original.originalPageCount,
        annotations: {
          ...original.annotations,
          'document': _annotationForNote(note),
        },
      );
    }
    final chapters = <XiaoqiDocumentChapter>[];
    final annotations = <String, Object?>{...original.annotations};
    for (var index = 0; index < original.chapters.length; index++) {
      final chapter = original.chapters[index];
      final note = editedNotes.firstWhere(
        (item) => item.capturePageId == index,
        orElse: () => index < editedNotes.length
            ? editedNotes[index]
            : _noteForChapter(
                chapter: chapter,
                assets: original.assets,
                bookName: widget.source.displayName,
                bookId: widget.source.bookId,
                index: index,
                now: DateTime.now().toIso8601String(),
              ),
      );
      final pageDocument = BookPageDocumentContent.documentFor(note);
      final editedBlocks = pageDocument.renderBlocks;
      final nextBlocks = _mergeBlocks(chapter.blocks, editedBlocks);
      annotations[chapter.id] = _annotationForNote(note);
      final plainText = nextBlocks
          .where((block) => block.kind != 'page_break')
          .map((block) => block.text.trim())
          .where((value) => value.isNotEmpty)
          .join('\n\n');
      chapters.add(
        XiaoqiDocumentChapter(
          id: chapter.id,
          title: _chapterTitle(note, editedBlocks),
          href: chapter.href,
          html: chapter.html,
          plainText: plainText,
          order: chapter.order,
          blocks: nextBlocks,
          sourceLocator: chapter.sourceLocator,
        ),
      );
    }
    return XiaoqiDocument(
      format: original.format,
      title: original.title,
      author: original.author,
      language: original.language,
      chapters: chapters,
      assets: original.assets,
      originalPageCount: original.originalPageCount,
      annotations: annotations,
    );
  }

  Map<String, Object?>? _annotationForChapter(String chapterId) {
    final value = _loadedDocument?.annotations[chapterId];
    return value is Map
        ? value.map((key, item) => MapEntry(key.toString(), item))
        : null;
  }

  Map<String, Object?> _annotationForNote(Note note) {
    final raw = note.annotationsJson;
    if (raw == null || raw.trim().isEmpty) {
      return const {
        'schema_version': 2,
        'annotation_coordinate_space': 'viewport',
        'annotations': <Object?>[],
      };
    }
    try {
      final decoded = jsonDecode(raw);
      return PageAnnotationDocument.fromJson(decoded).toJson();
    } on Object catch (_) {
      return const {
        'schema_version': 2,
        'annotation_coordinate_space': 'viewport',
        'annotations': <Object?>[],
      };
    }
  }

  /// 合并逻辑在 [BookSourceBlockMerger] 里，必须是幂等的：正文块数不允许因为
  /// 反复保存而增长（历史事故：每次保存翻倍，最终 6025 块拖死 UI 线程）。
  List<XiaoqiDocumentBlock> _mergeBlocks(
    List<XiaoqiDocumentBlock> original,
    List<OcrBlock> editedBlocks,
  ) => BookSourceBlockMerger.merge(original, editedBlocks);

  String _chapterTitle(Note note, List<OcrBlock> blocks) {
    var title = '';
    for (final block in blocks) {
      if (block.isTitle) {
        title = block.text.trim();
        break;
      }
    }
    return title.isEmpty ? note.title.trim() : title;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: NotePageTheme.card,
        appBar: AppBar(
          title: const Text('编辑资料'),
          backgroundColor: NotePageTheme.card,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 42),
                const SizedBox(height: 12),
                Text(
                  _pendingDocument != null
                      ? '保存失败：$_error'
                      : '资料暂时无法打开：$_error',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    if (_pendingDocument != null) {
                      unawaited(_savePendingDocument());
                      return;
                    }
                    setState(() {
                      _error = null;
                      _opening = true;
                    });
                    unawaited(_openEditor());
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: NotePageTheme.card,
      body: Center(
        child: Text(
          _opening ? '正在打开资料编辑页' : '正在保存资料版本',
          style: const TextStyle(color: NotePageTheme.muted, fontSize: 15),
        ),
      ),
    );
  }
}
