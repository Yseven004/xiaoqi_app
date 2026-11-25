import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/companion_source_range.dart';
import '../models/reader_pagination.dart';
import 'companion_annotation_sync.dart';
import 'database_service.dart';

class CompanionAnnotationSelection {
  const CompanionAnnotationSelection({
    required this.bookId,
    required this.sourceId,
    required this.sourceVersion,
    required this.anchor,
    required this.locator,
    required this.quote,
    this.endAnchor,
    this.startOffset,
    this.endOffset,
    this.translationVersion,
    this.view = 'original',
    this.pdfPageTextHashes = const {},
    this.canonicalRange,
  });

  final int bookId;
  final int sourceId;
  final String sourceVersion;
  final ReaderAnchor anchor;
  final ReaderAnchor? endAnchor;
  final String locator;
  final String quote;
  final int? startOffset;
  final int? endOffset;
  final String? translationVersion;
  final String view;
  final Map<int, String> pdfPageTextHashes;
  final CompanionSourceRange? canonicalRange;

  String get key => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            canonicalRange != null
                ? [sourceVersion, canonicalRange!.toJson()]
                : [
                    sourceVersion,
                    readerAnchorJson(anchor),
                    endAnchor == null ? null : readerAnchorJson(endAnchor!),
                    startOffset,
                    endOffset,
                    translationVersion,
                    view,
                    quote,
                  ],
          ),
        ),
      )
      .toString();

  Map<String, Object?> toJson() => {
    'source_version': sourceVersion,
    'anchor': readerAnchorJson(anchor),
    'end_anchor': endAnchor == null ? null : readerAnchorJson(endAnchor!),
    'locator': locator,
    'quote': quote,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'translation_version': translationVersion,
    'view': view,
    if (canonicalRange != null) 'canonical_range': canonicalRange!.toJson(),
    if (pdfPageTextHashes.isNotEmpty)
      'pdf_page_text_hashes': {
        for (final entry in pdfPageTextHashes.entries)
          '${entry.key}': entry.value,
      },
  };

  factory CompanionAnnotationSelection.fromJson(
    Map<String, dynamic> json, {
    required int bookId,
    required int sourceId,
  }) => CompanionAnnotationSelection(
    bookId: bookId,
    sourceId: sourceId,
    sourceVersion: json['source_version'] as String,
    anchor:
        readerAnchorFromJson(json['anchor'] as String?) ??
        (throw const FormatException('注释定位无效')),
    endAnchor: readerAnchorFromJson(json['end_anchor'] as String?),
    locator: json['locator'] as String,
    quote: json['quote'] as String,
    startOffset: json['start_offset'] as int?,
    endOffset: json['end_offset'] as int?,
    translationVersion: json['translation_version'] as String?,
    view: json['view'] as String? ?? 'original',
    canonicalRange: CompanionSourceRange.fromJson(json['canonical_range']),
    pdfPageTextHashes: {
      for (final entry
          in (json['pdf_page_text_hashes'] as Map? ?? const {}).entries)
        int.parse(entry.key as String): entry.value as String,
    },
  );
}

class CompanionAnnotation {
  const CompanionAnnotation({
    required this.id,
    required this.revision,
    required this.selection,
    required this.text,
    required this.images,
    required this.audio,
  });

  final String id;
  final String revision;
  final CompanionAnnotationSelection selection;
  final String text;
  final List<String> images;
  final List<String> audio;

  factory CompanionAnnotation.fromRow(Map<String, Object?> row) {
    final body = jsonDecode(row['body'] as String) as Map<String, dynamic>;
    return CompanionAnnotation(
      id: row['id'] as String,
      revision: row['revision'] as String,
      selection: CompanionAnnotationSelection.fromJson(
        body,
        bookId: row['book_id'] as int,
        sourceId: row['source_id'] as int,
      ),
      text: body['text'] as String,
      images: (body['images'] as List).cast<String>(),
      audio: (body['audio'] as List).cast<String>(),
    );
  }
}

class CompanionAnnotationStore {
  const CompanionAnnotationStore();

  static final _random = Random.secure();

  static String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<String> accountScope() async {
    final cloud = CapabilityCloudSync.instance;
    if (!await cloud.hasEmailSession) return 'local';
    final email = (await cloud.signedInEmail)?.trim().toLowerCase() ?? '';
    if (email.isEmpty) throw StateError('无法确认当前账号');
    return sha256.convert(utf8.encode(email)).toString();
  }

  Future<List<CompanionAnnotation>> list(String scope, int bookId) async {
    final sync = CompanionAnnotationSync.instance;
    if (scope != await accountScope()) throw StateError('账号已切换');
    await sync.prepareBook(scope, bookId);
    final db = await DatabaseService().database;
    final rows = await db.rawQuery(
      '''
      SELECT a.* FROM companion_annotations a JOIN books b ON b.id = a.book_id
      WHERE a.scope = ? AND a.book_id = ? AND a.is_deleted = 0 AND b.is_deleted = 0
      ORDER BY a.updated_at DESC, a.id
    ''',
      [scope, bookId],
    );
    return [
      for (final row in rows)
        if (!await sync.hidesBook(db, scope, row['id'] as String))
          CompanionAnnotation.fromRow(row),
    ];
  }

  Future<CompanionAnnotation> save({
    required String scope,
    required CompanionAnnotationSelection selection,
    required String text,
    required List<String> images,
    required List<String> audio,
    CompanionAnnotation? initial,
  }) async {
    if (text.trim().isEmpty && images.isEmpty && audio.isEmpty) {
      throw const FormatException('请先添加文字、图片或录音');
    }
    if (scope != await accountScope()) throw StateError('账号已切换');
    final sync = CompanionAnnotationSync.instance;
    final stagedMedia = await sync.stageMedia(scope, images, audio);
    if (scope != await accountScope()) throw StateError('账号已切换');
    final db = await DatabaseService().database;
    final saved = await db.transaction((txn) async {
      final book = await txn.query(
        'books',
        columns: ['id'],
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [selection.bookId],
      );
      if (book.isEmpty) throw StateError('书籍已删除');
      final key = selection.key;
      final existing = await txn.query(
        'companion_annotations',
        columns: ['id', 'revision', 'updated_at'],
        where:
            'scope = ? AND book_id = ? AND source_id = ? AND selection_key = ? AND is_deleted = 0',
        whereArgs: [scope, selection.bookId, selection.sourceId, key],
      );
      final current = existing.singleOrNull;
      if (initial != null &&
          (current?['id'] != initial.id ||
              current?['revision'] != initial.revision)) {
        throw StateError('注释已变更');
      }
      if (initial == null && current != null) throw StateError('注释已存在');
      final id = current?['id'] as String? ?? _newId();
      final revision = _newId();
      final row = <String, Object?>{
        'id': id,
        'scope': scope,
        'book_id': selection.bookId,
        'source_id': selection.sourceId,
        'selection_key': key,
        'revision': revision,
        'updated_at': DateTime.now().microsecondsSinceEpoch,
        'body': jsonEncode({
          ...selection.toJson(),
          'text': text.trim(),
          'images': images,
          'audio': audio,
        }),
      };
      final timestamp = await sync.enqueueAnnotation(
        txn,
        scope,
        CompanionAnnotation.fromRow(row),
        deleted: false,
        media: stagedMedia,
        lastEdit: current?['updated_at'] as int? ?? 0,
      );
      if (timestamp != null) row['updated_at'] = timestamp;
      if (existing.isEmpty) {
        await txn.insert('companion_annotations', row);
      } else {
        await txn.update(
          'companion_annotations',
          row,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      return CompanionAnnotation.fromRow(row);
    });
    sync.schedule();
    if (initial != null) {
      final keep = {...saved.images, ...saved.audio};
      await _removeMedia(
        scope,
        {...initial.images, ...initial.audio}.difference(keep),
      );
    }
    return saved;
  }

  Future<void> remove(String scope, CompanionAnnotation annotation) async {
    if (scope != await accountScope()) throw StateError('账号已切换');
    final db = await DatabaseService().database;
    final sync = CompanionAnnotationSync.instance;
    await db.transaction((txn) async {
      final previous = (await txn.query(
        'companion_annotations',
        columns: ['updated_at'],
        where: 'scope=? AND id=? AND revision=? AND is_deleted=0',
        whereArgs: [scope, annotation.id, annotation.revision],
      )).firstOrNull;
      if (previous == null) throw StateError('注释已变更');
      final timestamp = await sync.enqueueAnnotation(
        txn,
        scope,
        annotation,
        deleted: true,
        media: const [],
        lastEdit: previous['updated_at'] as int,
      );
      await txn.update(
        'companion_annotations',
        {
          'is_deleted': 1,
          'updated_at': timestamp ?? DateTime.now().microsecondsSinceEpoch,
        },
        where: 'scope=? AND id=?',
        whereArgs: [scope, annotation.id],
      );
    });
    sync.schedule();
    await _removeMedia(scope, {...annotation.images, ...annotation.audio});
  }

  Future<Directory> _mediaDirectory(String scope) async {
    final root = await getApplicationSupportDirectory();
    final scopeDirectory = sha256.convert(utf8.encode(scope)).toString();
    return Directory(
      p.join(root.path, 'companion_annotations', scopeDirectory),
    );
  }

  Future<void> _removeMedia(String scope, Set<String> paths) async {
    // A signed-in edit may still reference an earlier local file in its
    // durable outbox. Synced copies may also be shared by several notes.
    if (paths.isEmpty || scope != CompanionAnnotationSync.guestScope) return;
    try {
      final directory = await _mediaDirectory(scope);
      for (final path in paths) {
        if (!p.isWithin(directory.path, path)) continue;
        try {
          await File(path).delete();
        } on FileSystemException {
          // The annotation state is already committed.
        }
      }
    } on Exception {
      // Cleanup is best-effort after a successful transaction.
    }
  }

  Future<String> allocateMediaPath(String scope, String extension) async {
    final directory = await _mediaDirectory(scope);
    await directory.create(recursive: true);
    return p.join(directory.path, '${_newId()}.$extension');
  }
}
