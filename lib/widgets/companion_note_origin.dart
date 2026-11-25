import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/companion_source_range.dart';
import '../models/reader_pagination.dart';
import '../services/book_library_service.dart';
import '../services/companion_annotation_store.dart';
import '../services/database_service.dart';
import '../services/source_document_loader.dart';
import 'annotation_sheet.dart';
import 'app_toast.dart';
import 'companion_annotation_sheet.dart';
import 'companion_pdf_annotation_overlay.dart';
import 'reading_companion.dart';

typedef _NoteOrigin = ({
  CompanionAnnotationSelection selection,
  ReadingCompanionTarget? target,
  String? status,
});

const _sourceUnavailable = '原文资料已删除或暂不可用';
const _unalignedTranslation = '这段译文暂时无法定位到原文';
const _unverifiedLocator = '暂时无法定位引文';

bool _isUnalignedTranslation(CompanionAnnotationSelection selection) =>
    selection.canonicalRange == null &&
    (selection.translationVersion != null ||
        selection.view == 'translation' ||
        selection.view == 'flow-translation');

class CompanionNoteOrigin extends StatefulWidget {
  const CompanionNoteOrigin({required this.noteId, super.key});

  final int noteId;

  @override
  State<CompanionNoteOrigin> createState() => _CompanionNoteOriginState();
}

class _CompanionNoteOriginState extends State<CompanionNoteOrigin> {
  final _library = BookLibraryService();
  late final _originRevision =
      CapabilityCloudSync.instance.emailSessionRevision.value;
  late final _origin = _readOrigin();

  Future<_NoteOrigin?> _readOrigin() async {
    final row = await DatabaseService().queryCompanionAnnotationSnapshot(
      widget.noteId,
    );
    if (row == null) return null;
    final locator =
        jsonDecode(row['selection'] as String) as Map<String, dynamic>;
    final selection = CompanionAnnotationSelection.fromJson(
      locator,
      bookId: row['book_id'] as int,
      sourceId: row['source_id'] as int,
    );
    if (_isUnalignedTranslation(selection)) {
      return (
        selection: selection,
        target: null,
        status: _unalignedTranslation,
      );
    }
    final book = await _library.getBook(selection.bookId);
    if (book == null) {
      return (selection: selection, target: null, status: _sourceUnavailable);
    }
    final sources = <BookSourceRecord>[];
    for (final candidate in await _library.listSourcesForBook(
      selection.bookId,
    )) {
      if (candidate.bookId == selection.bookId &&
          SourceDocumentLoader.isReadableSource(candidate) &&
          await File(candidate.filePath).exists()) {
        sources.add(candidate);
      }
    }
    final bound = resolveCompanionOriginSource(selection, locator, sources);
    if (bound == null) {
      return (selection: selection, target: null, status: _sourceUnavailable);
    }
    if (!_canJumpToSource(bound.selection, bound.source)) {
      return (selection: selection, target: null, status: _unverifiedLocator);
    }
    return (
      selection: bound.selection,
      target: ReadingCompanionTarget(
        title: book.title,
        source: bound.source,
        sources: sources,
      ),
      status: null,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _origin,
    builder: (context, snapshot) {
      final origin = snapshot.data;
      final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
      if (origin == null || revision != _originRevision) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AnnotationQuoteLine(
                  origin.selection.quote,
                  guardContent: (child) =>
                      guardPrivateAnnotationContent(revision, child),
                ),
              ),
              if (origin.target != null)
                TextButton(onPressed: _openSource, child: const Text('跳转原文')),
            ],
          ),
          if (origin.status case final status?)
            Text(status, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
        ],
      );
    },
  );

  Future<void> _openSource() async {
    final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
    final origin = await _readOrigin();
    if (!mounted ||
        revision != _originRevision ||
        revision != CapabilityCloudSync.instance.emailSessionRevision.value) {
      return;
    }
    final target = origin?.target;
    if (origin == null ||
        target == null ||
        !await File(target.source.filePath).exists()) {
      if (mounted &&
          revision == CapabilityCloudSync.instance.emailSessionRevision.value) {
        AppToast.show(context, origin?.status ?? _sourceUnavailable);
      }
      return;
    }
    if (!mounted ||
        revision != CapabilityCloudSync.instance.emailSessionRevision.value) {
      return;
    }
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (context) => guardPrivateAnnotationContent(
          revision,
          Scaffold(
            appBar: AppBar(title: Text(target.title)),
            body: ReadingCompanion(
              target: target,
              bookId: target.source.bookId,
              library: _library,
              initialAnnotationSelection: origin.selection,
              messages: const [],
              streamingReply: const AlwaysStoppedAnimation(''),
              composerBuilder: (history) => history,
              onPassageOpened: (_) {},
            ),
          ),
        ),
      ),
    );
  }
}

/// A deleted source ID can be rebound within the original book when the file
/// import verified identical bytes. The reader still validates text ranges.
({CompanionAnnotationSelection selection, BookSourceRecord source})?
resolveCompanionOriginSource(
  CompanionAnnotationSelection selection,
  Map<String, dynamic> locator,
  List<BookSourceRecord> sources,
) {
  if (_isUnalignedTranslation(selection)) return null;
  String version(BookSourceRecord source) => source.sourceVersionId.isEmpty
      ? source.contentHash
      : source.sourceVersionId;
  final scope = sources.where((source) => source.bookId == selection.bookId);
  final stored = locator['source_content_hash'];
  final digest = stored is String && stored.isNotEmpty
      ? stored
      : selection.sourceVersion;
  final current = scope
      .where(
        (source) =>
            source.id == selection.sourceId &&
            version(source) == selection.sourceVersion &&
            (stored is! String ||
                stored.isEmpty ||
                source.contentHash == stored),
      )
      .firstOrNull;
  if (current != null) return (selection: selection, source: current);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) return null;
  final target = scope
      .where((source) => source.contentHash == digest)
      .singleOrNull;
  if (target == null) return null;
  String? rebind(ReaderAnchor? anchor) {
    if (anchor == null) return null;
    final data = jsonDecode(readerAnchorJson(anchor)) as Map<String, dynamic>;
    data['source_id'] = '${target.id}';
    return jsonEncode(data);
  }

  return (
    selection: CompanionAnnotationSelection.fromJson(
      {
        ...selection.toJson(),
        'source_version': version(target),
        'anchor': rebind(selection.anchor),
        'end_anchor': rebind(selection.endAnchor),
      },
      bookId: selection.bookId,
      sourceId: target.id,
    ),
    source: target,
  );
}

bool _canJumpToSource(
  CompanionAnnotationSelection selection,
  BookSourceRecord source,
) {
  final range = selection.canonicalRange;
  if (normalizeBookSourceFormat(source.format) == 'pdf') {
    if (range is CompanionPdfSourceRange) return range.pages.isNotEmpty;
    final legacy = legacyCompanionPdfRange(selection);
    return legacy != null &&
        selection.pdfPageTextHashes.containsKey(legacy.firstPage) &&
        selection.pdfPageTextHashes.containsKey(legacy.lastPage);
  }
  if (range is CompanionFlowSourceRange) return true;
  final anchor = selection.anchor;
  final start = selection.startOffset;
  final end = selection.endOffset;
  return range == null &&
      anchor is FlowReaderAnchor &&
      anchor.blockId != null &&
      start != null &&
      end != null &&
      start >= 0 &&
      end > start;
}
