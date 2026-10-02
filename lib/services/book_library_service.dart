import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book_category.dart';
import '../models/book_library_item.dart';
import '../models/book_library_query.dart';
import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../models/capture_source_link.dart';
import '../models/captured_page.dart';
import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../utils/isbn.dart';
import 'book_cover_storage.dart';
import 'book_source_block_merger.dart';
import 'database_service.dart';
import 'epub_document_service.dart';
import 'pdf_catalog_service.dart';
import 'source_document_loader.dart';

class RecoveredCaptureBatch {
  const RecoveredCaptureBatch({
    required this.batchId,
    required this.pages,
    required this.preparedNotes,
    this.placements = const {},
    this.selectedBookId,
  });

  final String batchId;
  final List<CapturedPage> pages;
  final Map<int, Note> preparedNotes;
  final Map<int, CapturePagePlacement> placements;
  final int? selectedBookId;
}
class BookLibraryService {
  BookLibraryService({
    DatabaseService? databaseService,
    BookCoverStorage? coverStorage,
  }) : _databaseService = databaseService ?? DatabaseService(),
       _coverStorage = coverStorage ?? BookCoverStorage();

  final DatabaseService _databaseService;
  final BookCoverStorage _coverStorage;
  final PdfCatalogService _pdfCatalogService = const PdfCatalogService();

  Future<int> saveBook(BookRecord book) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    final normalized = book.copyWith(
      createdAt: book.createdAt.isEmpty ? now : book.createdAt,
      updatedAt: now,
    );
    await db.insert(
      'books',
      normalized.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final rows = await db.query(
      'books',
      columns: ['id'],
      where: 'canonical_key = ?',
      whereArgs: [normalized.canonicalKey],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('书籍资料保存失败');
    final id = rows.first['id'] as int;
    await db.update(
      'books',
      normalized.toMap()
        ..remove('id')
        ..remove('created_at'),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (normalized.coverPath.isEmpty && normalized.coverUrl.isNotEmpty) {
      // Keep confirmation fast; the local cover is an enhancement.
      unawaited(_persistCatalogueCover(id, normalized));
    }
    return id;
  }

  Future<bool> _isStoredSourceValid({
    required File file,
    required int expectedSize,
    required String expectedHash,
    required String format,
  }) async {
    if (!await file.exists() || await file.length() != expectedSize) {
      return false;
    }
    final actualHash = (await sha256.bind(file.openRead()).first).toString();
    if (actualHash != expectedHash) return false;
    if (format != 'pdf') return true;

    String? renderedPath;
    try {
      renderedPath = await _pdfCatalogService.renderPageForEditing(
        file.path,
        1,
      );
      return renderedPath.trim().isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      if (renderedPath != null && renderedPath.trim().isNotEmpty) {
        try {
          await File(renderedPath).delete();
        } catch (_) {
          // The temporary render is only a validation artifact.
        }
      }
    }
  }

  Future<void> _persistCatalogueCover(int id, BookRecord book) async {
    try {
      final stored = await _coverStorage.persistCatalogueCover(book);
      if (stored.coverPath.isEmpty) return;
      final db = await _databaseService.database;
      final updated = await db.update(
        'books',
        {
          'cover_path': stored.coverPath,
          'cover_type': stored.coverType,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated == 0) {
        await File(stored.coverPath).delete();
      }
    } catch (_) {
      // A cover enhancement must never turn a successful book save into an
      // unhandled asynchronous error.
    }
  }

  Future<BookRecord?> getBook(int id) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : BookRecord.fromMap(rows.first);
  }

  Future<List<BookLibraryItem>> listBooks({
    BookLibraryQuery query = const BookLibraryQuery(),
  }) async {
    final db = await _databaseService.database;
    final threshold = _dateOnly(
      DateTime.now().subtract(const Duration(days: 29)),
    );
    final where = <String>[];
    final whereArgs = <Object?>[threshold];
    final normalizedSearch = query.searchText.trim().toLowerCase();
    if (normalizedSearch.isNotEmpty) {
      final pattern = '%$normalizedSearch%';
      where.add('''(
        LOWER(b.title) LIKE ? OR LOWER(b.authors) LIKE ? OR
        LOWER(b.isbn_10) LIKE ? OR LOWER(b.isbn_13) LIKE ?
      )''');
      whereArgs.addAll([pattern, pattern, pattern, pattern]);
    }
    if (query.uncategorizedOnly) {
      where.add('''NOT EXISTS (
        SELECT 1 FROM book_category_links filter_link
        WHERE filter_link.book_id = b.id
      )''');
    } else if (query.categoryId != null) {
      where.add('''EXISTS (
        SELECT 1 FROM book_category_links filter_link
        WHERE filter_link.book_id = b.id
          AND filter_link.category_id = ?
      )''');
      whereArgs.add(query.categoryId);
    }

    final primaryField = switch (query.sortMode) {
      BookLibrarySortMode.recentStudy => 'b.last_studied_at',
      BookLibrarySortMode.recentCreated => 'b.created_at',
      BookLibrarySortMode.studyFrequency => 'active_days',
    };
    final direction = query.direction == BookLibrarySortDirection.descending
        ? 'DESC'
        : 'ASC';
    final sql =
        '''
      SELECT b.*,
        (SELECT COUNT(*) FROM notes n
         WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count,
        (SELECT COUNT(*) FROM capture_pages p
           INNER JOIN capture_batches batch ON batch.id = p.batch_id
         WHERE batch.selected_book_id = b.id AND p.status != 'removed')
          AS recognized_page_count,
        (SELECT COUNT(*) FROM book_study_activity a
         WHERE a.book_id = b.id AND a.activity_date >= ?) AS active_days
      FROM books b
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY b.is_pinned DESC,
        CASE WHEN $primaryField IS NULL THEN 1 ELSE 0 END ASC,
        $primaryField $direction,
        b.created_at DESC,
        b.id DESC
    ''';
    final rows = await db.rawQuery(sql, whereArgs);
    final categoryMap = await _categoriesForBookIds(
      db,
      rows.map((row) => row['id'] as int).toList(growable: false),
    );
    return rows
        .map(
          (row) => BookLibraryItem(
            book: BookRecord.fromMap(row),
            noteCount: (row['note_count'] as int? ?? 0),
            recognizedPageCount: (row['recognized_page_count'] as int? ?? 0),
            activeDaysInLast30Days: (row['active_days'] as int? ?? 0),
            isPinned: (row['is_pinned'] as int? ?? 0) == 1,
            isInReadingSpace: (row['is_in_reading_space'] as int? ?? 1) == 1,
            lastStudiedAt: row['last_studied_at'] as String? ?? '',
            categories: categoryMap[row['id'] as int] ?? const [],
          ),
        )
        .toList(growable: false);
  }

  Future<BookLibraryItem?> getBookLibraryItem(int bookId) async {
    final db = await _databaseService.database;
    final threshold = _dateOnly(
      DateTime.now().subtract(const Duration(days: 29)),
    );
    final rows = await db.rawQuery(
      '''SELECT b.*,
          (SELECT COUNT(*) FROM notes n
           WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count,
          (SELECT COUNT(*) FROM capture_pages p
             INNER JOIN capture_batches batch ON batch.id = p.batch_id
           WHERE batch.selected_book_id = b.id AND p.status != 'removed')
            AS recognized_page_count,
          (SELECT COUNT(*) FROM book_study_activity a
           WHERE a.book_id = b.id AND a.activity_date >= ?) AS active_days
        FROM books b WHERE b.id = ? LIMIT 1''',
      [threshold, bookId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final categories = await _categoriesForBookIds(db, [bookId]);
    return BookLibraryItem(
      book: BookRecord.fromMap(row),
      noteCount: row['note_count'] as int? ?? 0,
      recognizedPageCount: row['recognized_page_count'] as int? ?? 0,
      activeDaysInLast30Days: row['active_days'] as int? ?? 0,
      isPinned: (row['is_pinned'] as int? ?? 0) == 1,
      isInReadingSpace: (row['is_in_reading_space'] as int? ?? 1) == 1,
      lastStudiedAt: row['last_studied_at'] as String? ?? '',
      categories: categories[bookId] ?? const [],
    );
  }

  Future<List<Note>> getNotesForBook(int bookId) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'notes',
      where: 'book_id = ? AND is_deleted = 0',
      whereArgs: [bookId],
      orderBy: 'is_pinned DESC, pinned_at DESC, updated_at DESC, id DESC',
    );
    return rows.map(Note.fromMap).toList(growable: false);
  }

  /// 查同一份 PDF 同一页已有的文字层/图像识别层笔记。
  ///
  /// 不能只按 `book_id` 过滤：历史数据的 `book_id` 可能为空，而那正是同一页
  /// 反复新建笔记、越积越多的来源（设备上第 17 页曾有 4 条）。
  Future<Note?> findPdfTextLayerNote({
    required String pdfPath,
    required int pageNumber,
  }) async {
    if (pdfPath.trim().isEmpty || pageNumber < 1) return null;
    final db = await _databaseService.database;
    final rows = await db.query(
      'notes',
      where:
          'pdf_path = ? AND TRIM(book_page) = ? AND is_deleted = 0 '
          "AND source_type IN ('pdf_text_layer', 'pdf_ocr_layer', 'pdf_ocr_pending')",
      whereArgs: [pdfPath, pageNumber.toString()],
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Note.fromMap(rows.first);
  }

  Future<void> setNotePinned(int noteId, bool pinned) async {
    final db = await _databaseService.database;
    await db.update(
      'notes',
      {
        'is_pinned': pinned ? 1 : 0,
        'pinned_at': pinned ? DateTime.now().toIso8601String() : null,
      },
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [noteId],
    );
  }

  Future<void> setBookPinned(int bookId, bool pinned) async {
    await setBooksPinned([bookId], pinned);
  }

  Future<void> setBooksPinned(Iterable<int> bookIds, bool pinned) async {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.update(
        'books',
        {
          'is_pinned': pinned ? 1 : 0,
          'pinned_at': pinned ? now : null,
          'updated_at': now,
        },
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });
  }

  Future<void> setBookInReadingSpace(int bookId, bool inReadingSpace) async {
    await setBooksInReadingSpace([bookId], inReadingSpace);
  }

  Future<void> setBooksInReadingSpace(
    Iterable<int> bookIds,
    bool inReadingSpace,
  ) async {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _databaseService.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.update(
        'books',
        {
          'is_in_reading_space': inReadingSpace ? 1 : 0,
          if (!inReadingSpace) 'is_pinned': 0,
          if (!inReadingSpace) 'pinned_at': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });
  }

  Future<void> recordStudyActivity(int bookId, {String action = 'open'}) async {
    final db = await _databaseService.database;
    final now = DateTime.now();
    final timestamp = now.toIso8601String();
    final date = _dateOnly(now);
    await db.transaction((txn) async {
      final existing = await txn.query(
        'book_study_activity',
        columns: ['id', 'action_count'],
        where: 'book_id = ? AND activity_date = ?',
        whereArgs: [bookId, date],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('book_study_activity', {
          'book_id': bookId,
          'activity_date': date,
          'last_active_at': timestamp,
          'action_count': 1,
        });
      } else {
        await txn.update(
          'book_study_activity',
          {
            'last_active_at': timestamp,
            'action_count': (existing.first['action_count'] as int? ?? 0) + 1,
          },
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
      }
      await txn.update(
        'books',
        {'last_studied_at': timestamp, 'updated_at': timestamp},
        where: 'id = ?',
        whereArgs: [bookId],
      );
    });
  }

  Future<List<BookCategory>> listCategories() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'book_categories',
      orderBy: 'is_system DESC, name COLLATE NOCASE ASC',
    );
    return rows.map(BookCategory.fromMap).toList(growable: false);
  }

  Future<int> countBooksInCategory(int categoryId) async {
    final db = await _databaseService.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT book_id) AS book_count '
      'FROM book_category_links WHERE category_id = ?',
      [categoryId],
    );
    return (rows.single['book_count'] as int?) ?? 0;
  }

  Future<BookCategory> saveCustomCategory(String rawName) async {
    final name = rawName.trim();
    final normalized = _normalizeCategoryName(name);
    if (name.isEmpty) throw ArgumentError('分类名称不能为空');
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.insert('book_categories', {
      'name': name,
      'normalized_name': normalized,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows = await db.query(
      'book_categories',
      where: 'normalized_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('分类保存失败');
    return BookCategory.fromMap(rows.first);
  }

  Future<BookCategory> renameCustomCategory(
    int categoryId,
    String rawName,
  ) async {
    final name = rawName.trim();
    final normalized = _normalizeCategoryName(name);
    if (name.isEmpty) throw ArgumentError('分类名称不能为空');
    final db = await _databaseService.database;
    final current = await db.query(
      'book_categories',
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    if (current.isEmpty) throw StateError('分类不存在');
    if (current.first['normalized_name'] == _normalizeCategoryName('其他')) {
      throw StateError('“其他”分类不能重命名');
    }
    final duplicate = await db.query(
      'book_categories',
      columns: ['id'],
      where: 'normalized_name = ? AND id != ?',
      whereArgs: [normalized, categoryId],
      limit: 1,
    );
    if (duplicate.isNotEmpty) throw StateError('已有同名分类');
    final now = DateTime.now().toIso8601String();
    await db.update(
      'book_categories',
      {'name': name, 'normalized_name': normalized, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [categoryId],
    );
    final rows = await db.query(
      'book_categories',
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    return BookCategory.fromMap(rows.single);
  }

  Future<void> deleteCustomCategory(int categoryId) async {
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      final current = await txn.query(
        'book_categories',
        columns: ['normalized_name'],
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (current.isEmpty) throw StateError('分类不存在');
      if (current.single['normalized_name'] == _normalizeCategoryName('其他')) {
        throw StateError('“其他”分类不能删除');
      }
      await txn.delete(
        'book_category_links',
        where: 'category_id = ?',
        whereArgs: [categoryId],
      );
      await txn.delete(
        'book_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
      );
    });
  }

  Future<void> setBookCategories(int bookId, Iterable<int> categoryIds) async {
    final ids = categoryIds.toSet().toList(growable: false);
    if (ids.length > 3) throw ArgumentError('一本书最多选择 3 个分类');
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      if (ids.isNotEmpty) {
        final placeholders = List.filled(ids.length, '?').join(',');
        final valid = await txn.rawQuery(
          'SELECT id FROM book_categories WHERE id IN ($placeholders)',
          ids,
        );
        if (valid.length != ids.length) throw ArgumentError('存在无效分类');
      }
      await txn.delete(
        'book_category_links',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      final now = DateTime.now().toIso8601String();
      for (final categoryId in ids) {
        await txn.insert('book_category_links', {
          'book_id': bookId,
          'category_id': categoryId,
          'created_at': now,
        });
      }
      await txn.update(
        'books',
        {'updated_at': now},
        where: 'id = ?',
        whereArgs: [bookId],
      );
    });
  }

  Future<int> updateBookMetadata(BookRecord book) async {
    final id = book.id;
    if (id == null) return saveBook(book);
    final db = await _databaseService.database;
    final duplicate = await db.query(
      'books',
      columns: ['id'],
      where: 'canonical_key = ? AND id != ?',
      whereArgs: [book.canonicalKey, id],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      throw StateError('已有相同书籍，不能保存为重复记录');
    }
    final values =
        book.copyWith(updatedAt: DateTime.now().toIso8601String()).toMap()
          ..remove('id')
          ..remove('created_at');
    await db.update('books', values, where: 'id = ?', whereArgs: [id]);
    if (book.coverPath.isEmpty && book.coverUrl.isNotEmpty) {
      unawaited(_persistCatalogueCover(id, book));
    }
    return id;
  }

  Future<BookSourceImportResult> importPdfForBook({
    required int bookId,
    required String sourcePath,
    required String displayName,
  }) => importBookSourceForBook(
    bookId: bookId,
    sourcePath: sourcePath,
    displayName: displayName,
    format: 'pdf',
  );

  Future<BookSourceImportResult> importBookSourceForBook({
    required int bookId,
    required String sourcePath,
    required String displayName,
    required String format,
  }) async {
    final normalizedFormat = normalizeBookSourceFormat(format);
    if (!supportedBookSourceFormats.contains(normalizedFormat)) {
      throw UnsupportedError('暂不支持导入 .$normalizedFormat 文件');
    }
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('找不到要导入的文件');
    }
    final fileSize = await sourceFile.length();
    final maxBytes = normalizedFormat == 'epub'
        ? EpubDocumentService.maxInputBytes
        : PdfCatalogService.maxPdfBytes;
    if (fileSize > maxBytes) {
      throw FormatException('$normalizedFormat 文件过大，无法安全导入');
    }
    final contentHash = (await sha256.bind(sourceFile.openRead()).first)
        .toString();
    final db = await _databaseService.database;
    final existing = await db.query(
      'book_sources',
      where: 'book_id = ? AND content_hash = ?',
      whereArgs: [bookId, contentHash],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final existingRecord = BookSourceRecord.fromMap(existing.first);
      final existingFile = File(existingRecord.filePath);
      if (await _isStoredSourceValid(
        file: existingFile,
        expectedSize: fileSize,
        expectedHash: contentHash,
        format: normalizedFormat,
      )) {
        return BookSourceImportResult(
          source: existingRecord,
          reusedExisting: true,
        );
      }

      // A hash-matched row with a missing or damaged private copy can be
      // repaired from the user-selected source without changing its identity.
      await existingFile.parent.create(recursive: true);
      await sourceFile.copy(existingFile.path);
      final repaired = await _isStoredSourceValid(
        file: existingFile,
        expectedSize: fileSize,
        expectedHash: contentHash,
        format: normalizedFormat,
      );
      if (!repaired) {
        throw StateError('已有资料副本损坏，修复后仍无法打开');
      }
      final now = DateTime.now().toIso8601String();
      await db.update(
        'book_sources',
        {
          'file_size': fileSize,
          'status': 'ready',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [existingRecord.id],
      );
      final refreshed = await db.query(
        'book_sources',
        where: 'id = ?',
        whereArgs: [existingRecord.id],
        limit: 1,
      );
      return BookSourceImportResult(
        source: refreshed.isEmpty
            ? existingRecord
            : BookSourceRecord.fromMap(refreshed.first),
        reusedExisting: true,
      );
    }
    final existingSource = await db.query(
      'book_sources',
      columns: ['id'],
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    final makePrimary = existingSource.isEmpty;

    final documents = await getApplicationDocumentsDirectory();
    final sourceDirectory = Directory(p.join(documents.path, 'book_sources'));
    await sourceDirectory.create(recursive: true);
    final targetPath = p.join(
      sourceDirectory.path,
      '$contentHash.$normalizedFormat',
    );
    final targetFile = File(targetPath);
    final targetExisted = await targetFile.exists();
    if (!targetExisted) await sourceFile.copy(targetPath);
    var targetValid = await _isStoredSourceValid(
      file: targetFile,
      expectedSize: fileSize,
      expectedHash: contentHash,
      format: normalizedFormat,
    );
    if (!targetValid && targetExisted) {
      await sourceFile.copy(targetPath);
      targetValid = await _isStoredSourceValid(
        file: targetFile,
        expectedSize: fileSize,
        expectedHash: contentHash,
        format: normalizedFormat,
      );
    }
    if (!targetValid) {
      if (!targetExisted) {
        try {
          await targetFile.delete();
        } catch (_) {
          // Keep the original source; an orphaned private copy is harmless.
        }
      }
      throw StateError('PDF 副本无法打开或首页无法渲染');
    }
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('book_sources', {
      'book_id': bookId,
      'kind': 'book_file',
      'format': normalizedFormat,
      'is_primary': makePrimary ? 1 : 0,
      'display_name': displayName,
      'file_path': targetPath,
      'file_size': fileSize,
      'content_hash': contentHash,
      'status': 'ready',
      'created_at': now,
      'updated_at': now,
    });
    return BookSourceImportResult(
      source: BookSourceRecord(
        id: id,
        bookId: bookId,
        kind: 'book_file',
        format: normalizedFormat,
        isPrimary: makePrimary,
        displayName: displayName,
        filePath: targetPath,
        fileSize: fileSize,
        contentHash: contentHash,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
      reusedExisting: false,
    );
  }

  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async {
    final db = await _databaseService.database;
    try {
      final rows = await db.query(
        'book_sources',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'updated_at DESC',
      );
      final sources = rows.map(BookSourceRecord.fromMap).toList();
      sources.sort((a, b) {
        if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
      return List.unmodifiable(sources);
    } catch (_) {
      // Older in-memory databases may not include the optional source table.
      return const [];
    }
  }

  Future<XiaoqiDocument?> loadBookSourceRevision(
    BookSourceRecord source,
  ) async {
    final document = await _loadStoredRevision(source);
    if (document == null) return null;
    if (!DerivedDocumentGuard.needsBaselineCheck(document)) return document;
    final baseline = await _parseSourceDocumentFile(source);
    if (baseline == null) return document;
    if (!DerivedDocumentGuard.looksPoisoned(document, baseline: baseline)) {
      return document;
    }
    // 派生版本已经被写坏（每次保存翻倍，正文工作台和编辑页都会卡死）。
    // 不删除任何数据，也不假装无事发生：直接回退到重新解析的原始文件，并把
    // 派生版本里保存的标注带回，用户下一次保存就会覆盖掉这条坏版本。
    return _withStoredAnnotations(baseline, document.annotations);
  }

  Future<XiaoqiDocument?> _loadStoredRevision(BookSourceRecord source) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'book_source_document_revisions',
      columns: ['document_json'],
      where: 'source_id = ? AND is_active = 1',
      whereArgs: [source.id],
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['document_json']?.toString() ?? '';
    if (raw.isEmpty) return null;
    try {
      return XiaoqiDocument.fromJson(raw);
    } on Object catch (_) {
      return null;
    }
  }

  /// 重新解析原始资料文件。失败时返回 null，调用方继续使用已有派生版本。
  Future<XiaoqiDocument?> _parseSourceDocumentFile(
    BookSourceRecord source,
  ) async {
    final path = source.filePath.trim();
    if (path.isEmpty) return null;
    try {
      if (!await File(path).exists()) return null;
      return await const SourceDocumentLoader().parseFile(
        path,
        format: source.format,
      );
    } on Object catch (_) {
      return null;
    }
  }

  XiaoqiDocument _withStoredAnnotations(
    XiaoqiDocument document,
    Map<String, Object?> annotations,
  ) {
    if (annotations.isEmpty) return document;
    return XiaoqiDocument(
      format: document.format,
      title: document.title,
      author: document.author,
      language: document.language,
      chapters: document.chapters,
      assets: document.assets,
      originalPageCount: document.originalPageCount,
      annotations: annotations,
    );
  }

  Future<void> saveBookSourceRevision({
    required BookSourceRecord source,
    required XiaoqiDocument document,
  }) async {
    final db = await _databaseService.database;
    // 保存前只比较存下来的那条版本，不触发“重新解析原始文件”的修复路径。
    final previous = await _loadStoredRevision(source);
    final rejection = DerivedDocumentGuard.rejectionReason(
      document,
      previous: previous,
    );
    if (rejection != null) throw StateError(rejection);
    final json = document.toJson(includeAnnotations: true);
    final documentHash = sha256.convert(utf8.encode(json)).toString();
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final sourceRows = await txn.query(
        'book_sources',
        columns: ['content_hash'],
        where: 'id = ? AND book_id = ?',
        whereArgs: [source.id, source.bookId],
        limit: 1,
      );
      if (sourceRows.isEmpty) throw StateError('找不到这份资料');
      await txn.update(
        'book_source_document_revisions',
        {'is_active': 0, 'updated_at': now},
        where: 'source_id = ? AND is_active = 1',
        whereArgs: [source.id],
      );
      await txn.insert(
        'book_source_document_revisions',
        {
          'source_id': source.id,
          'base_content_hash': sourceRows.first['content_hash'],
          'document_hash': documentHash,
          'document_json': json,
          'created_at': now,
          'updated_at': now,
          'is_active': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'book_sources',
        {'updated_at': now},
        where: 'id = ? AND book_id = ?',
        whereArgs: [source.id, source.bookId],
      );
    });
  }

  Future<void> setPrimaryBookSource({
    required int sourceId,
    required int bookId,
  }) async {
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      final source = await txn.query(
        'book_sources',
        columns: ['id', 'file_path'],
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, bookId],
        limit: 1,
      );
      if (source.isEmpty) throw StateError('找不到这份资料');
      final filePath = source.first['file_path'] as String? ?? '';
      if (!await File(filePath).exists()) {
        throw StateError('找不到这份资料文件，请重新导入');
      }
      await txn.update(
        'book_sources',
        {'is_primary': 0},
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      await txn.update(
        'book_sources',
        {
          'is_primary': 1,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, bookId],
      );
    });
  }

  Future<PdfCatalogParseResult> parsePdfCatalogForSource(
    BookSourceRecord source, {
    List<int>? scannedPageNumbers,
    void Function(int completed, int total)? onProgress,
  }) async {
    final db = await _databaseService.database;
    final startedAt = DateTime.now().toIso8601String();
    final runId = 'catalog:${source.id}:${DateTime.now().microsecondsSinceEpoch}';
    final claimed = await db.update(
      'book_sources',
      {
        'catalog_status': 'processing',
        'catalog_updated_at': startedAt,
        'catalog_run_id': runId,
        'updated_at': startedAt,
      },
      where: 'id = ? AND content_hash = ? AND catalog_status != ?',
      whereArgs: [source.id, source.contentHash, 'confirmed'],
    );
    if (claimed == 0) {
      throw StateError('书籍来源已被替换或删除，取消目录解析');
    }
    try {
      final result = scannedPageNumbers == null
          ? await _pdfCatalogService.parse(source.filePath)
          : await _pdfCatalogService.parseScannedCatalog(
              source.filePath,
              pageNumbers: scannedPageNumbers,
              onProgress: onProgress,
            );
      final now = DateTime.now().toIso8601String();
      await db.transaction((txn) async {
        final current = await txn.query(
          'book_sources',
          columns: const [
            'content_hash',
            'catalog_run_id',
            'catalog_status',
          ],
          where: 'id = ?',
          whereArgs: [source.id],
          limit: 1,
        );
        if (current.isEmpty ||
            current.first['content_hash'] != source.contentHash ||
            current.first['catalog_run_id'] != runId ||
            current.first['catalog_status'] == 'confirmed') {
          return;
        }
        await txn.insert('book_source_catalog_revisions', {
          'source_id': source.id,
          'revision_kind': 'candidate',
          'entries_json': result.toJson(),
          'run_id': runId,
          'content_hash': source.contentHash,
          'parser_version': PdfCatalogService.parserVersion,
          'created_at': now,
        });
        await txn.update(
          'book_sources',
          {
            'catalog_status': result.status,
            'catalog_source_kind': result.sourceKind,
            'catalog_json': result.toJson(),
            'catalog_updated_at': now,
            'catalog_parser_version': PdfCatalogService.parserVersion,
            'catalog_run_id': runId,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [source.id],
        );
      });
      if (result.sourceKind != 'pdf_outline' &&
          result.entries.length >= 2 &&
          result.entries.any((entry) => entry.printedPage != null)) {
        unawaited(_refinePdfCatalogForSource(source, result, runId));
      }
      return result;
    } catch (error) {
      await db.update(
        'book_sources',
        {
          'catalog_status': 'failed',
          'catalog_updated_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND catalog_run_id = ? AND content_hash = ?',
        whereArgs: [source.id, runId, source.contentHash],
      );
      rethrow;
    }
  }

  Future<void> _refinePdfCatalogForSource(
    BookSourceRecord source,
    PdfCatalogParseResult initial,
    String runId,
  ) async {
    try {
      final refined = await _pdfCatalogService.refine(source.filePath, initial);
      if (refined.toJson() == initial.toJson()) return;
      final db = await _databaseService.database;
      final now = DateTime.now().toIso8601String();
      await db.transaction((txn) async {
        final current = await txn.query(
          'book_sources',
          columns: const [
            'catalog_status',
            'catalog_run_id',
            'content_hash',
          ],
          where: 'id = ?',
          whereArgs: [source.id],
          limit: 1,
        );
        if (current.isEmpty ||
            current.first['catalog_status'] == 'confirmed' ||
            current.first['catalog_run_id'] != runId ||
            current.first['content_hash'] != source.contentHash) {
          return;
        }
        await txn.insert('book_source_catalog_revisions', {
          'source_id': source.id,
          'revision_kind': 'refined',
          'entries_json': refined.toJson(),
          'run_id': runId,
          'content_hash': source.contentHash,
          'parser_version': PdfCatalogService.parserVersion,
          'created_at': now,
        });
        await txn.update(
          'book_sources',
          {
            'catalog_status': refined.status,
            'catalog_source_kind': refined.sourceKind,
            'catalog_json': refined.toJson(),
            'catalog_updated_at': now,
            'catalog_parser_version': PdfCatalogService.parserVersion,
            'catalog_run_id': runId,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [source.id],
        );
      });
    } catch (error) {
      // Refinement is an optimization. Keep the quick, navigable catalog when
      // a PDF page cannot be read or the source is removed during the job.
      debugPrint('[XiaoQi] PDF 目录后台校准跳过: $error');
    }
  }

  Future<void> confirmPdfCatalog({
    required int sourceId,
    required List<PdfCatalogEntry> entries,
  }) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    final json = jsonEncode(entries.map((entry) => entry.toJson()).toList());
    final source = await db.query(
      'book_sources',
      columns: const ['content_hash', 'catalog_run_id'],
      where: 'id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    if (source.isEmpty) throw StateError('书籍来源不存在，无法确认目录');
    await db.transaction((txn) async {
      await txn.insert('book_source_catalog_revisions', {
        'source_id': sourceId,
        'revision_kind': 'confirmed',
        'entries_json': json,
        'run_id': source.first['catalog_run_id'] ?? '',
        'content_hash': source.first['content_hash'] ?? '',
        'parser_version': PdfCatalogService.parserVersion,
        'created_at': now,
      });
      await txn.update(
        'book_sources',
        {
          'catalog_status': 'confirmed',
          'catalog_json': json,
          'catalog_parser_version': PdfCatalogService.parserVersion,
          'catalog_updated_at': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [sourceId],
      );
    });
  }

  Future<List<BookRecord>> listBooksForSource(BookSourceRecord source) async {
    final db = await _databaseService.database;
    final rows = await db.rawQuery(
      '''SELECT b.* FROM books b
         INNER JOIN book_sources s ON s.book_id = b.id
         WHERE s.content_hash = ?
         ORDER BY b.title COLLATE NOCASE ASC''',
      [source.contentHash],
    );
    return rows.map(BookRecord.fromMap).toList(growable: false);
  }

  Future<void> moveBookSource({
    required int sourceId,
    required int currentBookId,
    required int targetBookId,
  }) async {
    if (currentBookId == targetBookId) return;
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'book_sources',
        columns: ['content_hash'],
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, currentBookId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('找不到这份资料');
      final hash = rows.first['content_hash'] as String;
      final target = await txn.query(
        'book_sources',
        columns: ['id'],
        where: 'book_id = ? AND content_hash = ?',
        whereArgs: [targetBookId, hash],
        limit: 1,
      );
      if (target.isNotEmpty) {
        await txn.delete(
          'book_sources',
          where: 'id = ?',
          whereArgs: [sourceId],
        );
        return;
      }
      final targetPrimary = await txn.query(
        'book_sources',
        columns: ['id'],
        where: 'book_id = ? AND is_primary = 1',
        whereArgs: [targetBookId],
        limit: 1,
      );
      await txn.update(
        'book_sources',
        {
          'book_id': targetBookId,
          if (targetPrimary.isEmpty) 'is_primary': 1,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, currentBookId],
      );
    });
  }

  Future<void> shareBookSource({
    required int sourceId,
    required int currentBookId,
    required int targetBookId,
  }) async {
    if (currentBookId == targetBookId) return;
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'book_sources',
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, currentBookId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('找不到这份资料');
      final source = rows.first;
      final hash = source['content_hash'] as String;
      final existing = await txn.query(
        'book_sources',
        columns: ['id'],
        where: 'book_id = ? AND content_hash = ?',
        whereArgs: [targetBookId, hash],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      final targetPrimary = await txn.query(
        'book_sources',
        columns: ['id'],
        where: 'book_id = ? AND is_primary = 1',
        whereArgs: [targetBookId],
        limit: 1,
      );
      final now = DateTime.now().toIso8601String();
      await txn.insert('book_sources', {
        'book_id': targetBookId,
        'kind': source['kind'],
        'format':
            source['format'] ??
            inferBookSourceFormat(
              source['display_name'] as String? ?? '',
              source['file_path'] as String? ?? '',
            ),
        'is_primary': targetPrimary.isEmpty ? 1 : 0,
        'display_name': source['display_name'],
        'file_path': source['file_path'],
        'file_size': source['file_size'],
        'content_hash': hash,
        'origin_uri': source['origin_uri'] ?? '',
        'canonical_uri': source['canonical_uri'] ?? '',
        'captured_at': source['captured_at'] ?? '',
        'package_manifest_path': source['package_manifest_path'] ?? '',
        'source_version_id': source['source_version_id'] ?? '',
        'document_parser_version': source['document_parser_version'] ?? 0,
        'status': source['status'],
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  Future<void> removeBookSource({
    required int sourceId,
    required int bookId,
  }) async {
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'book_sources',
        columns: ['is_primary'],
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, bookId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final wasPrimary = (rows.first['is_primary'] as num?)?.toInt() == 1;
      try {
        await txn.delete(
          'capture_source_links',
          where: 'target_source_id = ?',
          whereArgs: [sourceId],
        );
      } catch (_) {
        // Older in-memory databases may not include source-link tables.
      }
      await txn.delete(
        'book_sources',
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, bookId],
      );
      if (!wasPrimary) return;
      final fallback = await txn.query(
        'book_sources',
        columns: ['id'],
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (fallback.isNotEmpty) {
        await txn.update(
          'book_sources',
          {'is_primary': 1},
          where: 'id = ? AND book_id = ?',
          whereArgs: [fallback.first['id'], bookId],
        );
      }
    });
  }

  Future<bool> deleteBookSourceFile({
    required int sourceId,
    required int bookId,
  }) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'book_sources',
      columns: ['content_hash', 'file_path', 'package_manifest_path'],
      where: 'id = ? AND book_id = ?',
      whereArgs: [sourceId, bookId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('找不到这份资料');
    final hash = rows.first['content_hash'] as String;
    final filePath = rows.first['file_path'] as String? ?? '';
    final manifestPath = rows.first['package_manifest_path'] as String? ?? '';
    final primaryRows = await db.query(
      'book_sources',
      columns: ['book_id'],
      where: 'content_hash = ? AND is_primary = 1',
      whereArgs: [hash],
    );
    final sourceIds = await db.query(
      'book_sources',
      columns: ['id'],
      where: 'content_hash = ?',
      whereArgs: [hash],
    );
    await db.transaction((txn) async {
      if (sourceIds.isNotEmpty) {
        final placeholders = List.filled(sourceIds.length, '?').join(',');
        try {
          await txn.delete(
            'capture_source_links',
            where: 'target_source_id IN ($placeholders)',
            whereArgs: sourceIds.map((row) => row['id']).toList(),
          );
        } catch (_) {
          // Older in-memory databases may not include source-link tables.
        }
      }
      await txn.delete(
        'book_sources',
        where: 'content_hash = ?',
        whereArgs: [hash],
      );
      for (final row in primaryRows) {
        final affectedBookId = row['book_id'] as int;
        final fallback = await txn.query(
          'book_sources',
          columns: ['id'],
          where: 'book_id = ?',
          whereArgs: [affectedBookId],
          orderBy: 'updated_at DESC',
          limit: 1,
        );
        if (fallback.isNotEmpty) {
          await txn.update(
            'book_sources',
            {'is_primary': 1},
            where: 'id = ? AND book_id = ?',
            whereArgs: [fallback.first['id'], affectedBookId],
          );
        }
      }
    });
    final deletedFiles = await _deleteBookFiles({
      filePath,
      if (manifestPath.trim().isNotEmpty) manifestPath,
    }, db);
    if (manifestPath.trim().isNotEmpty &&
        await _isManagedPackageManifest(manifestPath)) {
      final packageDirectory = Directory(p.dirname(manifestPath));
      if (await packageDirectory.exists()) {
        await packageDirectory.delete(recursive: true);
      }
    }
    return deletedFiles.contains(_normalPath(filePath));
  }

  Future<void> deleteBooks(Iterable<int> bookIds) async {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _databaseService.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final noteRows = await db.query(
      'notes',
      columns: [
        'photo_path',
        'original_photo_path',
        'pdf_path',
        'source_photo_path',
        'capture_page_id',
        'capture_batch_id',
      ],
      where: 'book_id IN ($placeholders)',
      whereArgs: ids,
    );
    final bookRows = await db.query(
      'books',
      columns: ['cover_path'],
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final sourceRows = <Map<String, Object?>>[];
    try {
      sourceRows.addAll(
        await db.query(
          'book_sources',
          columns: ['file_path', 'package_manifest_path'],
          where: 'book_id IN ($placeholders)',
          whereArgs: ids,
        ),
      );
    } catch (_) {
      // Older in-memory test databases may not include the optional source
      // table; deleting the book itself remains safe.
    }
    final batchIds = <String>{
      ...noteRows
          .map((row) => row['capture_batch_id'] as String? ?? '')
          .where((value) => value.isNotEmpty),
    };
    final selectedBatches = await db.query(
      'capture_batches',
      columns: ['id'],
      where: 'selected_book_id IN ($placeholders)',
      whereArgs: ids,
    );
    batchIds.addAll(selectedBatches.map((row) => row['id'] as String));
    final pageIds = noteRows
        .map((row) => row['capture_page_id'] as int?)
        .whereType<int>()
        .toSet();
    final pageRows = <Map<String, Object?>>[];
    if (batchIds.isNotEmpty) {
      final batchPlaceholders = List.filled(batchIds.length, '?').join(',');
      pageRows.addAll(
        await db.query(
          'capture_pages',
          columns: ['id', 'original_path', 'processed_path'],
          where: 'batch_id IN ($batchPlaceholders)',
          whereArgs: batchIds.toList(),
        ),
      );
    }
    if (pageIds.isNotEmpty) {
      final pagePlaceholders = List.filled(pageIds.length, '?').join(',');
      pageRows.addAll(
        await db.query(
          'capture_pages',
          columns: ['id', 'original_path', 'processed_path'],
          where: 'id IN ($pagePlaceholders)',
          whereArgs: pageIds.toList(),
        ),
      );
    }
    final filesToDelete = <String>{
      ...bookRows.map((row) => row['cover_path'] as String? ?? ''),
       ...sourceRows.expand(
         (row) => [
           row['file_path'] as String? ?? '',
           row['package_manifest_path'] as String? ?? '',
         ],
       ),
      ...noteRows.expand(
        (row) => [
          row['photo_path'] as String? ?? '',
          row['original_photo_path'] as String? ?? '',
          row['pdf_path'] as String? ?? '',
          row['source_photo_path'] as String? ?? '',
        ],
      ),
      ...pageRows.expand(
        (row) => [
          row['original_path'] as String? ?? '',
          row['processed_path'] as String? ?? '',
        ],
      ),
    }..removeWhere((path) => path.trim().isEmpty);

    await db.transaction((txn) async {
      try {
        await txn.delete(
          'capture_source_links',
          where:
              'target_source_id IN (SELECT id FROM book_sources '
              'WHERE book_id IN ($placeholders)) OR capture_page_id IN '
              '(SELECT cp.id FROM capture_pages cp INNER JOIN capture_batches cb '
              'ON cb.id = cp.batch_id WHERE cb.selected_book_id IN ($placeholders))',
          whereArgs: [...ids, ...ids],
        );
      } catch (_) {
        // Older in-memory databases may not include source-link tables.
      }
      await txn.delete(
        'ai_usage',
        where:
            'note_id IN (SELECT id FROM notes WHERE book_id IN ($placeholders))',
        whereArgs: ids,
      );
      await txn.delete(
        'notes',
        where: 'book_id IN ($placeholders)',
        whereArgs: ids,
      );
      final now = DateTime.now().toIso8601String();
      await txn.rawUpdate(
        'UPDATE capture_batches SET selected_book_id = NULL, updated_at = ? '
        'WHERE selected_book_id IN ($placeholders)',
        [now, ...ids],
      );
      if (batchIds.isNotEmpty) {
        final batchPlaceholders = List.filled(batchIds.length, '?').join(',');
        final remaining = await txn.query(
          'notes',
          columns: ['capture_batch_id'],
          where: 'capture_batch_id IN ($batchPlaceholders)',
          whereArgs: batchIds.toList(),
        );
        final sharedBatchIds = remaining
            .map((row) => row['capture_batch_id'] as String? ?? '')
            .where((value) => value.isNotEmpty)
            .toSet();
        final deletableBatchIds = batchIds.difference(sharedBatchIds);
        if (deletableBatchIds.isNotEmpty) {
          final deletablePlaceholders = List.filled(
            deletableBatchIds.length,
            '?',
          ).join(',');
          await txn.delete(
            'capture_pages',
            where: 'batch_id IN ($deletablePlaceholders)',
            whereArgs: deletableBatchIds.toList(),
          );
          await txn.delete(
            'capture_batches',
            where: 'id IN ($deletablePlaceholders)',
            whereArgs: deletableBatchIds.toList(),
          );
        }
      }
      if (pageIds.isNotEmpty) {
        final pagePlaceholders = List.filled(pageIds.length, '?').join(',');
        await txn.delete(
          'capture_pages',
          where:
              'id IN ($pagePlaceholders) AND NOT EXISTS ('
              'SELECT 1 FROM notes WHERE notes.capture_page_id = capture_pages.id)',
          whereArgs: pageIds.toList(),
        );
      }
      await txn.delete(
        'book_category_links',
        where: 'book_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'book_study_activity',
        where: 'book_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'book_recognition_history',
        where: 'book_id IN ($placeholders)',
        whereArgs: ids,
      );
      try {
        await txn.delete(
          'book_sources',
          where: 'book_id IN ($placeholders)',
          whereArgs: ids,
        );
      } catch (_) {
        // Keep compatibility with older in-memory databases.
      }
      await txn.delete('books', where: 'id IN ($placeholders)', whereArgs: ids);
    });
    await _deleteBookFiles(filesToDelete, db);
    for (final row in sourceRows) {
      final manifestPath = row['package_manifest_path'] as String? ?? '';
      if (manifestPath.trim().isEmpty) continue;
      final stillReferenced = await db.query(
        'book_sources',
        columns: ['id'],
        where: 'package_manifest_path = ?',
        whereArgs: [manifestPath],
        limit: 1,
      );
      if (stillReferenced.isEmpty) {
        if (await _isManagedPackageManifest(manifestPath)) {
          final packageDirectory = Directory(p.dirname(manifestPath));
          if (await packageDirectory.exists()) {
            await packageDirectory.delete(recursive: true);
          }
        }
      }
    }
  }

  Future<Set<String>> _deleteBookFiles(
    Set<String> candidates,
    Database db,
  ) async {
    if (candidates.isEmpty) return const <String>{};
    final referenced = <String>{};
    final deleted = <String>{};
    List<Map<String, Object?>> noteRefs;
    try {
      noteRefs = await db.rawQuery('''
        SELECT photo_path AS path FROM notes
        UNION ALL SELECT original_photo_path AS path FROM notes
        UNION ALL SELECT pdf_path AS path FROM notes
        UNION ALL SELECT source_photo_path AS path FROM notes
        UNION ALL SELECT original_path AS path FROM capture_pages
        UNION ALL SELECT processed_path AS path FROM capture_pages
        UNION ALL SELECT cover_path AS path FROM books
        UNION ALL SELECT file_path AS path FROM book_sources
      ''');
    } catch (_) {
      noteRefs = await db.rawQuery('''
        SELECT photo_path AS path FROM notes
        UNION ALL SELECT original_photo_path AS path FROM notes
        UNION ALL SELECT pdf_path AS path FROM notes
        UNION ALL SELECT source_photo_path AS path FROM notes
        UNION ALL SELECT original_path AS path FROM capture_pages
        UNION ALL SELECT processed_path AS path FROM capture_pages
        UNION ALL SELECT cover_path AS path FROM books
      ''');
    }
    referenced.addAll(
      noteRefs
          .map((row) => row['path'] as String? ?? '')
          .where((path) => path.trim().isNotEmpty)
          .map(_normalPath),
    );
    final documents = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final temporary = await getTemporaryDirectory();
    final roots = [
      documents.path,
      support.path,
      temporary.path,
    ].map(_normalPath).toList();
    for (final path in candidates) {
      final normalized = _normalPath(path);
      if (normalized.isEmpty || referenced.contains(normalized)) continue;
      if (!roots.any(
        (root) =>
            normalized == root || normalized.startsWith('$root${p.separator}'),
      )) {
        continue;
      }
      try {
        final file = File(normalized);
        if (await file.exists()) {
          await file.delete();
          deleted.add(normalized);
        }
      } catch (error) {
        // Database deletion is already complete; leave an inaccessible file
        // for a later cleanup pass rather than failing the user action.
        debugPrint('[XiaoQi] 删除书籍文件失败: $error');
      }
    }
    return deleted;
  }

  String _normalPath(String value) => p.normalize(File(value).absolute.path);

  Future<bool> _isManagedPackageManifest(String manifestPath) async {
    final documents = await getApplicationDocumentsDirectory();
    final packageRoot = _normalPath(p.join(documents.path, 'book_sources'));
    final packageDirectory = _normalPath(p.dirname(manifestPath));
    return packageDirectory != packageRoot &&
        p.isWithin(packageRoot, packageDirectory);
  }

  Future<void> unlinkNotesFromBook(Iterable<int> noteIds) async {
    final ids = noteIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _databaseService.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE notes SET book_id = NULL, book_name = \'\', updated_at = ? '
      'WHERE id IN ($placeholders)',
      [DateTime.now().toIso8601String(), ...ids],
    );
  }

  Future<Map<int, List<BookCategory>>> _categoriesForBookIds(
    DatabaseExecutor db,
    List<int> bookIds,
  ) async {
    if (bookIds.isEmpty) return const {};
    final placeholders = List.filled(bookIds.length, '?').join(',');
    final rows = await db.rawQuery(
      '''SELECT link.book_id, category.*
         FROM book_category_links link
         INNER JOIN book_categories category ON category.id = link.category_id
         WHERE link.book_id IN ($placeholders)
         ORDER BY category.is_system DESC, category.name COLLATE NOCASE ASC''',
      bookIds,
    );
    final result = <int, List<BookCategory>>{};
    for (final row in rows) {
      final bookId = row['book_id'] as int;
      result.putIfAbsent(bookId, () => []).add(BookCategory.fromMap(row));
    }
    return result;
  }

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  static String _normalizeCategoryName(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// Finds a book the user has already confirmed, without any network call.
  Future<BookRecord?> findByIsbn(String value) async {
    final isbn13 = Isbn.normalize(value);
    if (isbn13 == null) return null;
    final db = await _databaseService.database;
    final rows = await db.rawQuery(
      '''SELECT b.*
         FROM books b
         LEFT JOIN book_recognition_history h ON h.book_id = b.id
         WHERE b.isbn_13 = ? OR b.canonical_key = ?
         ORDER BY COALESCE(h.last_confirmed_at, b.updated_at) DESC
         LIMIT 1''',
      [isbn13, 'isbn:$isbn13'],
    );
    return rows.isEmpty ? null : BookRecord.fromMap(rows.first);
  }

  Future<void> createDraftBatch(
    String batchId,
    List<CapturedPage> pages, {
    int? selectedBookId,
  }) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'capture_batches',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [batchId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        if (selectedBookId != null) {
          await txn.update(
            'capture_batches',
            {'selected_book_id': selectedBookId, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [batchId],
          );
        }
        return;
      }
      await txn.insert('capture_batches', {
        'id': batchId,
        'status': 'processing',
        'selected_book_id': selectedBookId,
        'recognition_confidence': 'unknown',
        'reader_collection_id': batchId,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      for (var index = 0; index < pages.length; index++) {
        await txn.insert('capture_pages', {
          'batch_id': batchId,
          'page_order': index,
          'original_path': pages[index].path,
          'input_kind': pages[index].inputKind.storageValue,
          'status': 'captured',
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  /// Creates a new capture batch linked to the same reader collection.
  ///
  /// A completed batch is never appended to. This keeps the original scan
  /// immutable while allowing the reader's “添加书页” tile to extend the
  /// visible collection through a separate resumable draft.
  Future<String> createLinkedDraftBatch({
    required Note parentNote,
    required List<CapturedPage> pages,
    int? selectedBookId,
  }) async {
    if (pages.isEmpty) throw ArgumentError('至少需要一页书页');
    final db = await _databaseService.database;
    final batchId = 'batch_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    var collectionId = parentNote.captureBatchId?.trim() ?? '';
    await db.transaction((txn) async {
      if (collectionId.isNotEmpty) {
        final rows = await txn.query(
          'capture_batches',
          columns: ['reader_collection_id'],
          where: 'id = ?',
          whereArgs: [collectionId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          collectionId =
              (rows.first['reader_collection_id'] as String?)?.trim() ?? '';
        }
      }
      if (collectionId.isEmpty) {
        collectionId = parentNote.captureBatchId?.trim().isNotEmpty == true
            ? parentNote.captureBatchId!.trim()
            : batchId;
      }
      await txn.insert('capture_batches', {
        'id': batchId,
        'status': 'processing',
        'selected_book_id': selectedBookId ?? parentNote.bookId,
        'recognition_confidence': 'unknown',
        'reader_collection_id': collectionId,
        'created_at': now,
        'updated_at': now,
      });
      for (var index = 0; index < pages.length; index++) {
        await txn.insert('capture_pages', {
          'batch_id': batchId,
          'page_order': index,
          'original_path': pages[index].path,
          'input_kind': pages[index].inputKind.storageValue,
          'status': 'captured',
          'created_at': now,
          'updated_at': now,
        });
      }
    });
    return batchId;
  }

  Future<List<int>> appendDraftPages(
    String batchId,
    List<CapturedPage> pages,
  ) async {
    if (pages.isEmpty) return const [];
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    final orders = <int>[];
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(page_order), -1) AS max_order '
        'FROM capture_pages WHERE batch_id = ?',
        [batchId],
      );
      var nextOrder = ((rows.first['max_order'] as int?) ?? -1) + 1;
      for (final page in pages) {
        orders.add(nextOrder);
        await txn.insert('capture_pages', {
          'batch_id': batchId,
          'page_order': nextOrder,
          'original_path': page.path,
          'input_kind': page.inputKind.storageValue,
          'status': 'captured',
          'created_at': now,
          'updated_at': now,
        });
        nextOrder++;
      }
      await txn.update(
        'capture_batches',
        {'updated_at': now},
        where: 'id = ?',
        whereArgs: [batchId],
      );
    });
    return orders;
  }

  /// Drops only the capture draft rows. Source photos are intentionally left
  /// untouched because they may come from the camera roll or another flow.
  Future<void> discardCaptureBatch(String batchId) async {
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      await txn.delete(
        'capture_pages',
        where: 'batch_id = ?',
        whereArgs: [batchId],
      );
      await txn.delete(
        'capture_batches',
        where: 'id = ? AND status = ?',
        whereArgs: [batchId, 'processing'],
      );
    });
  }

  /// Completes the successful part of a draft and keeps failed pages
  /// resumable in a fresh processing batch. The successful capture batch is
  /// deliberately immutable after this operation.
  Future<void> completeCaptureBatchAfterSaving(
    String batchId, {
    bool preserveBookAssociation = false,
  }) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final batchRows = await txn.query(
        'capture_batches',
        where: 'id = ?',
        whereArgs: [batchId],
        limit: 1,
      );
      if (batchRows.isEmpty) return;
      final batch = batchRows.single;
      final failed = await txn.query(
        'capture_pages',
        where: 'batch_id = ? AND status = ?',
        whereArgs: [batchId, 'failed'],
        orderBy: 'page_order ASC',
      );
      String? retryBatchId;
      if (failed.isNotEmpty) {
        retryBatchId = 'batch_${DateTime.now().microsecondsSinceEpoch}';
        final collectionId =
            (batch['reader_collection_id'] as String?)?.trim().isNotEmpty ==
                true
            ? (batch['reader_collection_id'] as String).trim()
            : batchId;
        await txn.insert('capture_batches', {
          'id': retryBatchId,
          'status': 'processing',
          'selected_book_id': batch['selected_book_id'],
          'recognition_confidence': 'unknown',
          'reader_collection_id': collectionId,
          'error_message': '仍有书页待重试',
          'created_at': now,
          'updated_at': now,
        });
        for (var index = 0; index < failed.length; index++) {
          await txn.update(
            'capture_pages',
            {'batch_id': retryBatchId, 'page_order': index, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [failed[index]['id']],
          );
        }
      }
      final values = <String, Object?>{
        'status': 'completed',
        'updated_at': now,
      };
      if (!preserveBookAssociation) {
        values['selected_book_id'] = null;
        values['recognition_confidence'] = 'unknown';
      }
      await txn.update(
        'capture_batches',
        values,
        where: 'id = ?',
        whereArgs: [batchId],
      );
    });
  }

  Future<void> saveDraftEdits({
    required String batchId,
    required int pageOrder,
    required String editedText,
    required String printedPage,
    required String pageNumberSource,
  }) async {
    final db = await _databaseService.database;
    await db.update(
      'capture_pages',
      {
        'edited_text': editedText,
        'printed_page': printedPage,
        'page_number_source': pageNumberSource,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'batch_id = ? AND page_order = ?',
      whereArgs: [batchId, pageOrder],
    );
  }

  Future<void> saveDraftPlacement({
    required String batchId,
    required int pageOrder,
    required CapturePagePlacement placement,
  }) async {
    final db = await _databaseService.database;
    await db.update(
      'capture_pages',
      {
        'placement_json': capturePlacementJson(placement),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'batch_id = ? AND page_order = ?',
      whereArgs: [batchId, pageOrder],
    );
  }

  Future<bool> isCaptureBatchCancelled(String batchId) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'capture_batches',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['status'] == 'cancelled';
  }

  Future<bool> isCaptureBatchPaused(String batchId) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'capture_batches',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['status'] == 'paused';
  }

  Future<bool?> toggleCaptureBatchPause(String batchId) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'capture_batches',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final status = rows.first['status'];
    if (status != 'processing' && status != 'paused') return null;
    final paused = status == 'processing';
    await db.update(
      'capture_batches',
      {
        'status': paused ? 'paused' : 'processing',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
    return paused;
  }

  Future<void> cancelCaptureBatch(String batchId) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'capture_batches',
        {
          'status': 'cancelled',
          'error_message': '用户取消图片识别',
          'updated_at': now,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [batchId, 'processing'],
      );
      await txn.update(
        'capture_pages',
        {'status': 'cancelled', 'updated_at': now},
        where: 'batch_id = ? AND status IN (?, ?)',
        whereArgs: [batchId, 'captured', 'processing'],
      );
    });
  }

  Future<bool> isCapturePageRemoved(int capturePageId) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'capture_pages',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [capturePageId],
      limit: 1,
    );
    return rows.isEmpty || rows.first['status'] == 'removed';
  }

  Future<void> deleteImageRecognitionPage(int capturePageId) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'capture_source_links',
        {
          'detached_at': now,
          'updated_at': now,
          'detach_reason': 'image_recognition_deleted',
        },
        where: 'capture_page_id = ? AND detached_at IS NULL',
        whereArgs: [capturePageId],
      );
      await txn.update(
        'capture_pages',
        {'status': 'removed', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [capturePageId],
      );
      await txn.update(
        'notes',
        {'is_deleted': 1, 'updated_at': now},
        where: 'capture_page_id = ? AND is_deleted = 0',
        whereArgs: [capturePageId],
      );
    });
  }

  Future<void> removeDraftPage(String batchId, int pageOrder) async {
    final db = await _databaseService.database;
    await db.update(
      'capture_pages',
      {'status': 'removed', 'updated_at': DateTime.now().toIso8601String()},
      where: 'batch_id = ? AND page_order = ?',
      whereArgs: [batchId, pageOrder],
    );
  }

  Future<int?> capturePageId(String batchId, int pageOrder) async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'capture_pages',
      columns: ['id'],
      where: 'batch_id = ? AND page_order = ?',
      whereArgs: [batchId, pageOrder],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  Future<List<BookImageRecognitionEntry>> listImageRecognitionForBook(
    int bookId,
  ) async {
    final db = await _databaseService.database;
    try {
      final rows = await db.rawQuery(
        '''SELECT cp.id AS capture_page_id, cp.batch_id, cp.page_order,
                  cp.input_kind, cp.status, cp.error_message,
                  cb.status AS batch_status, n.*, l.id AS link_id,
                  l.target_source_id, l.target_source_version_id,
                  s.display_name AS target_source_name,
                  l.anchor_kind, l.anchor_json, l.anchor_key, l.mode,
                  l.created_at AS link_created_at,
                  l.updated_at AS link_updated_at,
                  l.detached_at AS link_detached_at,
                  l.detach_reason AS link_detach_reason,
                  l.replaces_link_id
           FROM capture_pages cp
           INNER JOIN capture_batches cb ON cb.id = cp.batch_id
           LEFT JOIN notes n ON n.capture_page_id = cp.id
             AND n.book_id = ? AND n.is_deleted = 0
           LEFT JOIN capture_source_links l ON l.capture_page_id = cp.id
             AND l.detached_at IS NULL
           LEFT JOIN book_sources s ON s.id = l.target_source_id
           WHERE cb.selected_book_id = ? AND cp.status != 'removed'
           ORDER BY cp.created_at ASC, cp.page_order ASC''',
        [bookId, bookId],
      );
      return rows.map((row) {
        final linkId = row['link_id'] as int?;
        final link = linkId == null
            ? null
            : CaptureSourceLinkRecord.fromMap({
                'id': linkId,
                'capture_page_id': row['capture_page_id'],
                'target_source_id': row['target_source_id'],
                'target_source_version_id': row['target_source_version_id'],
                'anchor_kind': row['anchor_kind'],
                'anchor_json': row['anchor_json'],
                'anchor_key': row['anchor_key'],
                'mode': row['mode'],
                'created_at': row['link_created_at'],
                'updated_at': row['link_updated_at'],
                'detached_at': row['link_detached_at'],
                'detach_reason': row['link_detach_reason'],
                'replaces_link_id': row['replaces_link_id'],
              });
        Note? note;
        try {
          if (row['id'] != null) note = Note.fromMap(row);
        } catch (_) {
          note = null;
        }
        return BookImageRecognitionEntry(
          capturePageId: row['capture_page_id'] as int,
          batchId: row['batch_id'] as String,
          pageOrder: row['page_order'] as int,
          inputKind: captureInputKindFromStorage(
            row['input_kind'] as String?,
          ),
          status: row['status'] as String? ?? 'captured',
          batchStatus: row['batch_status'] as String? ?? 'processing',
          errorMessage: row['error_message'] as String? ?? '',
          targetSourceName: row['target_source_name'] as String? ?? '',
          note: note,
          link: link,
        );
      }).toList(growable: false);
    } catch (_) {
      try {
        late final List<Map<String, Object?>> rows;
        try {
          rows = await db.rawQuery(
            '''SELECT cp.id AS capture_page_id, cp.batch_id, cp.page_order,
                      cp.input_kind, cp.status, cp.error_message,
                      cb.status AS batch_status
               FROM capture_pages cp
               INNER JOIN capture_batches cb ON cb.id = cp.batch_id
               WHERE cb.selected_book_id = ? AND cp.status != 'removed'
               ORDER BY cp.created_at ASC, cp.page_order ASC''',
            [bookId],
          );
        } catch (_) {
          rows = await db.rawQuery(
            '''SELECT cp.id AS capture_page_id, cp.batch_id, cp.page_order,
                      cp.status, cp.error_message,
                      cb.status AS batch_status
               FROM capture_pages cp
               INNER JOIN capture_batches cb ON cb.id = cp.batch_id
               WHERE cb.selected_book_id = ? AND cp.status != 'removed'
               ORDER BY cp.created_at ASC, cp.page_order ASC''',
            [bookId],
          );
        }
        final entries = <BookImageRecognitionEntry>[];
        for (final row in rows) {
          Note? note;
          try {
            final noteRows = await db.query(
              'notes',
              where: 'capture_page_id = ? AND book_id = ? AND is_deleted = 0',
              whereArgs: [row['capture_page_id'], bookId],
              limit: 1,
            );
            if (noteRows.isNotEmpty) note = Note.fromMap(noteRows.first);
          } catch (_) {
            // Keep the placeholder visible even when the note table is old.
          }
          entries.add(
            BookImageRecognitionEntry(
              capturePageId: row['capture_page_id'] as int,
              batchId: row['batch_id'] as String,
              pageOrder: row['page_order'] as int,
              inputKind: captureInputKindFromStorage(
                row['input_kind'] as String?,
              ),
              status: row['status'] as String? ?? 'captured',
              batchStatus: row['batch_status'] as String? ?? 'processing',
              errorMessage: row['error_message'] as String? ?? '',
              note: note,
            ),
          );
        }
        return entries;
      } catch (_) {
        return const [];
      }
    }
  }

  Future<int?> saveCapturePlacements({
    required int bookId,
    required int sourceId,
    required Map<int, CapturePagePlacement> placements,
  }) async {
    if (placements.isEmpty) return null;
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    int? replacementLinkId;
    await db.transaction((txn) async {
      final sourceRows = await txn.query(
        'book_sources',
        columns: ['id', 'book_id', 'content_hash', 'source_version_id'],
        where: 'id = ? AND book_id = ?',
        whereArgs: [sourceId, bookId],
        limit: 1,
      );
      if (sourceRows.isEmpty) throw StateError('找不到要关联的电子材料');
      final source = sourceRows.single;
      for (final entry in placements.entries) {
        final capturePageId = entry.key;
        final placement = entry.value;
        final pageRows = await txn.rawQuery(
          '''SELECT cp.id FROM capture_pages cp
             INNER JOIN capture_batches cb ON cb.id = cp.batch_id
             WHERE cp.id = ? AND cb.selected_book_id = ? LIMIT 1''',
          [capturePageId, bookId],
        );
        if (pageRows.isEmpty) throw StateError('图片识别文本不属于当前书籍');
        final currentRows = await txn.query(
          'capture_source_links',
          where: 'capture_page_id = ? AND detached_at IS NULL',
          whereArgs: [capturePageId],
          limit: 1,
        );
        final current = currentRows.isEmpty ? null : currentRows.single;
        if (!placement.isLinked) {
          if (current != null) {
            await txn.update(
              'capture_source_links',
              {
                'detached_at': now,
                'updated_at': now,
                'detach_reason': 'user_unlinked',
              },
              where: 'id = ?',
              whereArgs: [current['id']],
            );
          }
          continue;
        }
        final anchor = placement.anchor!;
        if (anchor.sourceId != sourceId.toString()) {
          throw StateError('关联位置属于另一份电子材料');
        }
        if (placement.kind == CapturePlacementKind.replacePdfPage &&
            anchor is! PdfReaderAnchor) {
          throw StateError('只有 PDF 固定页支持替换当前页');
        }
        if (placement.kind == CapturePlacementKind.relatedFlowPosition &&
            anchor is! FlowReaderAnchor) {
          throw StateError('可重排资料必须关联到章节位置');
        }
        final anchorKey = captureAnchorKey(anchor);
        final occupiedRows = await txn.query(
          'capture_source_links',
          where:
              'target_source_id = ? AND anchor_key = ? AND detached_at IS NULL',
          whereArgs: [sourceId, anchorKey],
          limit: 1,
        );
        final occupied = occupiedRows.isEmpty ? null : occupiedRows.single;
        int? replacesLinkId;
        if (occupied != null && occupied['capture_page_id'] != capturePageId) {
          replacesLinkId = occupied['id'] as int;
          await txn.update(
            'capture_source_links',
            {
              'detached_at': now,
              'updated_at': now,
              'detach_reason': 'replaced',
            },
            where: 'id = ?',
            whereArgs: [replacesLinkId],
          );
        }
        if (current != null) {
          await txn.update(
            'capture_source_links',
            {
              'detached_at': now,
              'updated_at': now,
              'detach_reason': 'relinked',
            },
            where: 'id = ?',
            whereArgs: [current['id']],
          );
        }
        final newLinkId = await txn.insert('capture_source_links', {
          'capture_page_id': capturePageId,
          'target_source_id': sourceId,
          'target_source_version_id':
              ((source['source_version_id'] as String?)?.trim().isNotEmpty ==
                      true
                  ? source['source_version_id'] as String
                  : source['content_hash'] as String? ?? ''),
          'anchor_kind': captureAnchorKind(anchor),
          'anchor_json': captureAnchorJson(anchor),
          'anchor_key': anchorKey,
          'mode': placement.kind == CapturePlacementKind.replacePdfPage
              ? 'replace'
              : 'related',
          'created_by': 'user_confirmed',
          'created_at': now,
          'updated_at': now,
          'replaces_link_id': replacesLinkId,
        });
        if (replacesLinkId != null) replacementLinkId = newLinkId;
      }
    });
    return replacementLinkId;
  }

  Future<void> undoCaptureSourceLinkReplacement(int linkId) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final rows = await txn.query(
        'capture_source_links',
        where: 'id = ? AND detached_at IS NULL',
        whereArgs: [linkId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final link = rows.single;
      final oldId = link['replaces_link_id'] as int?;
      if (oldId == null) return;
      final oldRows = await txn.query(
        'capture_source_links',
        where: 'id = ? AND detach_reason = ?',
        whereArgs: [oldId, 'replaced'],
        limit: 1,
      );
      if (oldRows.isEmpty) return;
      await txn.update(
        'capture_source_links',
        {
          'detached_at': now,
          'updated_at': now,
          'detach_reason': 'undo_replacement',
        },
        where: 'id = ?',
        whereArgs: [linkId],
      );
      await txn.update(
        'capture_source_links',
        {'detached_at': null, 'updated_at': now, 'detach_reason': ''},
        where: 'id = ?',
        whereArgs: [oldId],
      );
    });
  }

  Future<void> commitDraftPlacements(String batchId, int bookId) async {
    final db = await _databaseService.database;
    late final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        'capture_pages',
        columns: ['id', 'placement_json'],
        where: 'batch_id = ? AND status != ?',
        whereArgs: [batchId, 'removed'],
      );
    } catch (_) {
      return;
    }
    final grouped = <int, Map<int, CapturePagePlacement>>{};
    for (final row in rows) {
      final placement = capturePlacementFromJson(
        row['placement_json'] as String?,
      );
      final anchor = placement?.anchor;
      final sourceId = int.tryParse(anchor?.sourceId ?? '');
      if (placement == null || sourceId == null) continue;
      grouped.putIfAbsent(sourceId, () => {})[row['id'] as int] = placement;
    }
    for (final entry in grouped.entries) {
      await saveCapturePlacements(
        bookId: bookId,
        sourceId: entry.key,
        placements: entry.value,
      );
    }
  }

  Future<void> updateDraftPage({
    required String batchId,
    required int pageOrder,
    required String status,
    String processedPath = '',
    String originalPath = '',
    String? ocrJson,
    String editedText = '',
    String printedPage = '',
    String pageNumberSource = 'unknown',
    String? errorMessage,
  }) async {
    final db = await _databaseService.database;
    final values = <String, Object?>{
      'status': status,
      'processed_path': processedPath,
      'ocr_json': ocrJson,
      'edited_text': editedText,
      'printed_page': printedPage,
      'page_number_source': pageNumberSource,
      'error_message': errorMessage,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (originalPath.isNotEmpty) values['original_path'] = originalPath;
    await db.update(
      'capture_pages',
      values,
      where: 'batch_id = ? AND page_order = ?',
      whereArgs: [batchId, pageOrder],
    );
  }

  Future<RecoveredCaptureBatch?> loadLatestDraft() async {
    final db = await _databaseService.database;
    final batches = await db.query(
      'capture_batches',
      where: 'status = ?',
      whereArgs: ['processing'],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (batches.isEmpty) return null;
    final batchId = batches.first['id'] as String;
    final rows = await db.query(
      'capture_pages',
      where: 'batch_id = ? AND status != ?',
      whereArgs: [batchId, 'removed'],
      orderBy: 'page_order ASC',
    );
    final pages = <CapturedPage>[];
    final prepared = <int, Note>{};
    final placements = <int, CapturePagePlacement>{};
    for (final row in rows) {
      final order = row['page_order'] as int;
      final placement = capturePlacementFromJson(
        row['placement_json'] as String?,
      );
      if (placement != null) placements[order] = placement;
      final originalPath = row['original_path'] as String? ?? '';
      final processedPath = row['processed_path'] as String? ?? '';
      final availablePath = await File(originalPath).exists()
          ? originalPath
          : processedPath;
      if (availablePath.isEmpty || !await File(availablePath).exists()) {
        continue;
      }
      pages.add(
        CapturedPage(
          path: availablePath,
          inputKind: captureInputKindFromStorage(
            row['input_kind'] as String?,
          ),
          captureBatchId: batchId,
          captureSequence: order,
        ),
      );
      final ocrJson = row['ocr_json'] as String?;
      if (ocrJson == null || ocrJson.isEmpty || processedPath.isEmpty) continue;
      try {
        final data = AnnotatedNoteData.fromJson(
          jsonDecode(ocrJson) as Map<String, dynamic>,
        );
        final text = (row['edited_text'] as String? ?? '').trim();
        final now =
            row['updated_at'] as String? ?? DateTime.now().toIso8601String();
        prepared[pages.length - 1] = Note(
          type: 'annotated_note',
          title:
              data.ocrLayout
                  .where(
                    (block) => block.isTitle && block.text.trim().isNotEmpty,
                  )
                  .map((block) => block.text.trim())
                  .firstOrNull ??
              '我的笔记',
          content: text.isNotEmpty
              ? text
              : data.ocrLayout.map((block) => block.text).join('\n'),
          photoPath: processedPath,
          originalPhotoPath: originalPath,
          annotationsJson: ocrJson,
          capturePageId: row['id'] as int?,
          captureBatchId: batchId,
          captureSequence: order,
          createdAt: now,
          updatedAt: now,
        );
      } catch (_) {
        // A malformed draft is reprocessed instead of blocking recovery.
      }
    }
    if (pages.isEmpty) return null;
    return RecoveredCaptureBatch(
      batchId: batchId,
      pages: pages,
      preparedNotes: prepared,
      placements: placements,
      selectedBookId: batches.first['selected_book_id'] as int?,
    );
  }

  Future<void> confirmBook({
    required String batchId,
    required int bookId,
    required BookMatchConfidence confidence,
    required bool wasChanged,
  }) async {
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'capture_batches',
        {
          'status': 'confirmed',
          'selected_book_id': bookId,
          'recognition_confidence': confidence.name,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [batchId],
      );
      final existing = await txn.query(
        'book_recognition_history',
        where: 'book_id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('book_recognition_history', {
          'book_id': bookId,
          'confirmed_count': 1,
          'corrected_count': wasChanged ? 1 : 0,
          'last_confirmed_at': now,
          'created_at': now,
          'updated_at': now,
        });
      } else {
        await txn.rawUpdate(
          '''UPDATE book_recognition_history
             SET confirmed_count = confirmed_count + 1,
                 corrected_count = corrected_count + ?,
                 last_confirmed_at = ?, updated_at = ?
             WHERE book_id = ?''',
          [wasChanged ? 1 : 0, now, now, bookId],
        );
      }
    });
  }

  /// Marks an OCR batch as successfully converted into notes without forcing
  /// the user to identify a book first.
  Future<void> completeCaptureBatch(
    String batchId, {
    bool preserveBookAssociation = false,
  }) async {
    final db = await _databaseService.database;
    final values = <String, Object?>{
      'status': 'completed',
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (!preserveBookAssociation) {
      values['selected_book_id'] = null;
      values['recognition_confidence'] = 'unknown';
    }
    await db.update(
      'capture_batches',
      values,
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  /// Associates existing notes with one canonical book. [saveBook] reuses an
  /// existing row when the ISBN (or canonical metadata key) was seen before.
  Future<BookRecord> associateNotes({
    required Iterable<Note> notes,
    required BookCandidate candidate,
  }) async {
    final noteIds = notes.map((note) => note.id).whereType<int>().toSet();
    if (noteIds.isEmpty) throw ArgumentError('至少需要一条已保存的笔记');

    final bookId = await saveBook(candidate.book);
    final db = await _databaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final placeholders = List.filled(noteIds.length, '?').join(',');
      await txn.rawUpdate(
        'UPDATE notes SET book_id = ?, book_name = ?, updated_at = ? '
        'WHERE id IN ($placeholders)',
        [bookId, candidate.book.title.trim(), now, ...noteIds],
      );
      await _recordConfirmation(
        txn,
        bookId: bookId,
        now: now,
        wasChanged: false,
      );
    });
    return (await getBook(bookId)) ?? candidate.book.copyWith(id: bookId);
  }

  Future<void> _recordConfirmation(
    DatabaseExecutor executor, {
    required int bookId,
    required String now,
    required bool wasChanged,
  }) async {
    final existing = await executor.query(
      'book_recognition_history',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (existing.isEmpty) {
      await executor.insert('book_recognition_history', {
        'book_id': bookId,
        'confirmed_count': 1,
        'corrected_count': wasChanged ? 1 : 0,
        'last_confirmed_at': now,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }
    await executor.rawUpdate(
      '''UPDATE book_recognition_history
         SET confirmed_count = confirmed_count + 1,
             corrected_count = corrected_count + ?,
             last_confirmed_at = ?, updated_at = ?
         WHERE book_id = ?''',
      [wasChanged ? 1 : 0, now, now, bookId],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
