import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/chat_note_capture.dart';
import '../models/note_attachment.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/user.dart';

class DatabaseService {
  DatabaseService._internal();

  static final DatabaseService _instance = DatabaseService._internal();

  factory DatabaseService() => _instance;

  static Database? _database;
  static const String _dbName = 'xiaoqi.db';
  static const int _dbVersion = 33;
  static const int homeNotebookLimit = 7;
  static const int pinnedNotebookLimit = 10;
  static const Duration deletedNotebookRetention = Duration(days: 30);

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    try {
      final dbDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dbDir.path, _dbName);
      debugPrint('[XiaoQi] DB: 数据库路径: $dbPath');

      return await openDatabase(
        dbPath,
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } catch (e) {
      debugPrint('[XiaoQi] DB: 数据库初始化失败: $e');
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    debugPrint('[XiaoQi] DB: 创建数据库 v$version');
    await db.execute('''
      CREATE TABLE notebooks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT '默认分类',
        description TEXT NOT NULL DEFAULT '',
        cover_index INTEGER NOT NULL DEFAULT 0,
        cover_path TEXT NOT NULL DEFAULT '',
        home_slot INTEGER,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        pinned_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        deleted_home_slot INTEGER,
        deleted_was_pinned INTEGER NOT NULL DEFAULT 0,
        deleted_pinned_at TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final now = DateTime.now().toIso8601String();
    await db.insert('notebooks', {
      'name': '默认笔记本',
      'category': '随手记录',
      'description': '',
      'cover_index': 0,
      'cover_path': '',
      'home_slot': 0,
      'is_pinned': 0,
      'pinned_at': null,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'deleted_home_slot': null,
      'deleted_was_pinned': 0,
      'deleted_pinned_at': null,
      'is_archived': 0,
      'is_deleted': 0,
    });
    await db.execute('''
      CREATE TABLE notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        notebook_id INTEGER NOT NULL DEFAULT 1,
        type TEXT NOT NULL DEFAULT 'text',
        title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        content_delta TEXT NOT NULL DEFAULT '',
        source_type TEXT NOT NULL DEFAULT 'text_note',
        photo_path TEXT NOT NULL DEFAULT '',
        original_photo_path TEXT NOT NULL DEFAULT '',
        pdf_path TEXT NOT NULL DEFAULT '',
        book_name TEXT NOT NULL DEFAULT '',
        book_page TEXT NOT NULL DEFAULT '',
        book_id INTEGER,
        capture_page_id INTEGER,
        parent_note_id INTEGER,
        annotations_json TEXT,
        page_group_id TEXT,
        page_group_index INTEGER,
        is_double_page INTEGER NOT NULL DEFAULT 0,
        source_photo_path TEXT NOT NULL DEFAULT '',
        capture_batch_id TEXT,
        group_id TEXT,
        group_index INTEGER,
        captured_at TEXT,
        capture_sequence INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        pinned_at TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_notes_type_deleted_created
      ON notes(type, is_deleted, created_at)
    ''');
    await db.execute('''
      CREATE INDEX idx_notes_notebook_updated
      ON notes(notebook_id, is_deleted, updated_at)
    ''');
    await db.execute('''
      CREATE INDEX idx_notes_page_group
      ON notes(page_group_id, page_group_index)
    ''');
    await db.execute(
      '''CREATE INDEX idx_notes_capture_order
      ON notes(capture_batch_id, capture_sequence, captured_at, group_index, id)''',
    );
    await db.execute('''
      CREATE INDEX idx_notes_book_pinned_updated
      ON notes(book_id, is_deleted, is_pinned, pinned_at, updated_at)
    ''');
    await _createChatNoteSourceTable(db);
    await _createNoteAttachmentTable(db);
    await _createNoteRelationTables(db);

    await _createBookRecognitionTables(db);
    await _createBookSourceTables(db);
    await _createBookSourceRevisionTables(db);
    await _createBookLearningTables(db);
    await _createCaptureSourceLinkTables(db);

    await db.execute('''
      CREATE TABLE ai_usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        used_at TEXT NOT NULL,
        FOREIGN KEY (note_id) REFERENCES notes(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nickname TEXT NOT NULL DEFAULT '同学',
        created_at TEXT NOT NULL
      )
    ''');
    debugPrint('[XiaoQi] DB: 创建数据库完成，已建立复合索引、ai_usage表和user表');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('[XiaoQi] DB: 升级数据库 v$oldVersion → v$newVersion');

    if (oldVersion < 2) {
      try {
        await db.execute(
          "ALTER TABLE notes ADD COLUMN photo_path TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          "ALTER TABLE notes ADD COLUMN book_name TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          "ALTER TABLE notes ADD COLUMN book_page TEXT NOT NULL DEFAULT ''",
        );
        await db.execute('ALTER TABLE notes ADD COLUMN parent_note_id INTEGER');
        debugPrint('[XiaoQi] DB: v1→v2 迁移完成');
      } catch (e) {
        debugPrint('[XiaoQi] DB: 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 3) {
      try {
        await db.execute('''
          CREATE TABLE ai_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL,
            used_at TEXT NOT NULL,
            FOREIGN KEY (note_id) REFERENCES notes(id)
          )
        ''');
        debugPrint('[XiaoQi] DB: v2→v3 迁移完成（新增ai_usage表）');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v2→v3 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 4) {
      try {
        await db.execute("ALTER TABLE notes ADD COLUMN annotations_json TEXT");
        debugPrint('[XiaoQi] DB: v3→v4 迁移完成（新增annotations_json列）');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v3→v4 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 5) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS user (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nickname TEXT NOT NULL DEFAULT '同学',
            created_at TEXT NOT NULL
          )
        ''');
        debugPrint('[XiaoQi] DB: v4→v5 迁移完成（新增user表）');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v4→v5 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 6) {
      try {
        try {
          await db.execute(
            "ALTER TABLE notes ADD COLUMN annotations_json TEXT",
          );
          debugPrint('[XiaoQi] DB: v5→v6 防御性添加 annotations_json 列成功');
        } catch (_) {
          // 列已存在，忽略
        }
        debugPrint('[XiaoQi] DB: v5→v6 迁移完成');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v5→v6 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 7) {
      try {
        await db.execute(
          "ALTER TABLE notes ADD COLUMN pdf_path TEXT NOT NULL DEFAULT ''",
        );
        debugPrint('[XiaoQi] DB: v6→v7 迁移完成（新增 pdf_path 列）');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v6→v7 迁移失败: $e');
        rethrow;
      }
    }

    if (oldVersion < 8) {
      try {
        await db.execute(
          "ALTER TABLE notes ADD COLUMN original_photo_path TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          "UPDATE notes SET original_photo_path = photo_path WHERE original_photo_path = ''",
        );
        debugPrint('[XiaoQi] DB: v7->v8 migration complete');
      } catch (e) {
        debugPrint('[XiaoQi] DB: v7->v8 migration failed: $e');
        rethrow;
      }
    }

    if (oldVersion < 9) {
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN page_group_id TEXT');
        await db.execute(
          'ALTER TABLE notes ADD COLUMN page_group_index INTEGER',
        );
        await db.execute(
          'ALTER TABLE notes ADD COLUMN is_double_page INTEGER NOT NULL DEFAULT 0',
        );
        await db.execute(
          "ALTER TABLE notes ADD COLUMN source_photo_path TEXT NOT NULL DEFAULT ''",
        );
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_notes_page_group
          ON notes(page_group_id, page_group_index)
        ''');
        debugPrint(
          '[XiaoQi] DB: v8->v9 double-page metadata migration complete',
        );
      } catch (e) {
        debugPrint('[XiaoQi] DB: v8->v9 migration failed: $e');
        rethrow;
      }
    }

    if (oldVersion < 10) {
      for (final sql in const [
        'ALTER TABLE notes ADD COLUMN capture_batch_id TEXT',
        'ALTER TABLE notes ADD COLUMN group_id TEXT',
        'ALTER TABLE notes ADD COLUMN group_index INTEGER',
        'ALTER TABLE notes ADD COLUMN captured_at TEXT',
        'ALTER TABLE notes ADD COLUMN capture_sequence INTEGER',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      await db.execute(
        'UPDATE notes SET group_id = page_group_id WHERE group_id IS NULL',
      );
      await db.execute(
        'UPDATE notes SET group_index = page_group_index WHERE group_index IS NULL',
      );
      await db.execute(
        'UPDATE notes SET captured_at = created_at WHERE captured_at IS NULL',
      );
      await db.execute(
        'UPDATE notes SET capture_sequence = id WHERE capture_sequence IS NULL',
      );
      await db.execute(
        '''CREATE INDEX IF NOT EXISTS idx_notes_capture_order
        ON notes(capture_batch_id, capture_sequence, captured_at, group_index, id)''',
      );
    }

    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS notebooks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          category TEXT NOT NULL DEFAULT '默认分类',
          description TEXT NOT NULL DEFAULT '',
          cover_index INTEGER NOT NULL DEFAULT 0,
          cover_path TEXT NOT NULL DEFAULT '',
          home_slot INTEGER,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          pinned_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT,
          deleted_home_slot INTEGER,
          deleted_was_pinned INTEGER NOT NULL DEFAULT 0,
          deleted_pinned_at TEXT,
          is_archived INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final rows = await db.query(
        'notebooks',
        columns: ['id'],
        where: 'is_deleted = 0',
        orderBy: 'id ASC',
        limit: 1,
      );
      final now = DateTime.now().toIso8601String();
      final defaultNotebookId = rows.isNotEmpty
          ? rows.first['id'] as int
          : await db.insert('notebooks', {
              'name': '默认笔记本',
              'category': '随手记录',
              'description': '',
              'cover_index': 0,
              'cover_path': '',
              'home_slot': 0,
              'is_pinned': 0,
              'pinned_at': null,
              'created_at': now,
              'updated_at': now,
              'deleted_at': null,
              'deleted_home_slot': null,
              'deleted_was_pinned': 0,
              'deleted_pinned_at': null,
              'is_archived': 0,
              'is_deleted': 0,
            });
      for (final sql in const [
        'ALTER TABLE notes ADD COLUMN notebook_id INTEGER',
        "ALTER TABLE notes ADD COLUMN content_delta TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE notes ADD COLUMN source_type TEXT NOT NULL DEFAULT 'text_note'",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      await db.update('notes', {
        'notebook_id': defaultNotebookId,
      }, where: 'notebook_id IS NULL');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_notes_notebook_updated
        ON notes(notebook_id, is_deleted, updated_at)
      ''');
    }

    if (oldVersion < 12) {
      for (final sql in const [
        "ALTER TABLE notebooks ADD COLUMN description TEXT NOT NULL DEFAULT ''",
        'ALTER TABLE notebooks ADD COLUMN home_slot INTEGER',
        'ALTER TABLE notebooks ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE notebooks ADD COLUMN pinned_at TEXT',
        'ALTER TABLE notebooks ADD COLUMN deleted_at TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      final activeRows = await db.query(
        'notebooks',
        columns: ['id'],
        where: 'is_deleted = 0 AND is_archived = 0',
        orderBy: 'updated_at DESC, id ASC',
        limit: 7,
      );
      for (var index = 0; index < activeRows.length; index++) {
        await db.update(
          'notebooks',
          {'home_slot': index},
          where: 'id = ? AND home_slot IS NULL',
          whereArgs: [activeRows[index]['id']],
        );
      }
    }

    if (oldVersion < 13) {
      for (final sql in const [
        "ALTER TABLE notebooks ADD COLUMN cover_path TEXT NOT NULL DEFAULT ''",
        'ALTER TABLE notebooks ADD COLUMN deleted_home_slot INTEGER',
        'ALTER TABLE notebooks ADD COLUMN deleted_was_pinned INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE notebooks ADD COLUMN deleted_pinned_at TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Defensive for databases created from intermediate development builds.
        }
      }
      await _compactHomeSlots(db);
    }

    if (oldVersion < 14) {
      for (final sql in const [
        'ALTER TABLE notes ADD COLUMN book_id INTEGER',
        'ALTER TABLE notes ADD COLUMN capture_page_id INTEGER',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Defensive for intermediate development databases.
        }
      }
      await _createBookRecognitionTables(db);
    }

    if (oldVersion < 15) {
      await _createBookLearningTables(db);
    }

    if (oldVersion < 16) {
      for (final sql in const [
        'ALTER TABLE notes ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE notes ADD COLUMN pinned_at TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Defensive for intermediate development databases.
        }
      }
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_notes_book_pinned_updated
        ON notes(book_id, is_deleted, is_pinned, pinned_at, updated_at)
      ''');
    }

    if (oldVersion < 17) {
      for (final sql in const [
        "ALTER TABLE books ADD COLUMN cover_type TEXT NOT NULL DEFAULT 'auto'",
        "ALTER TABLE books ADD COLUMN cover_template TEXT NOT NULL DEFAULT 'mist'",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Defensive for development databases that already contain a field.
        }
      }
    }

    if (oldVersion < 18) {
      for (final sql in const [
        "ALTER TABLE books ADD COLUMN description TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE books ADD COLUMN toc_json TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE books ADD COLUMN external_links_json TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE books ADD COLUMN metadata_sources_json TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE books ADD COLUMN metadata_updated_at TEXT NOT NULL DEFAULT ''",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Defensive for development databases built from an intermediate
          // metadata-plugin branch.
        }
      }
    }

    if (oldVersion < 19) {
      try {
        await db.execute(
          "ALTER TABLE capture_batches ADD COLUMN reader_collection_id TEXT NOT NULL DEFAULT ''",
        );
      } catch (_) {
        // Development databases may already contain the column.
      }
      await db.execute('''
        UPDATE capture_batches
        SET reader_collection_id = id
        WHERE reader_collection_id IS NULL OR reader_collection_id = ''
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_capture_batches_reader_collection
        ON capture_batches(reader_collection_id, updated_at)
      ''');
      debugPrint('[XiaoQi] DB: v18→v19 书页阅读集合迁移完成');
    }

    if (oldVersion < 21 && newVersion >= 21) {
      await _createBookSourceTables(db);
      debugPrint('[XiaoQi] DB: v20→v21 电子书来源表迁移完成');
    }

    if (oldVersion < 22 && newVersion >= 22) {
      for (final sql in const [
        "ALTER TABLE book_sources ADD COLUMN catalog_status TEXT NOT NULL DEFAULT 'not_started'",
        "ALTER TABLE book_sources ADD COLUMN catalog_source_kind TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN catalog_json TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE book_sources ADD COLUMN catalog_updated_at TEXT NOT NULL DEFAULT ''",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Development databases may already contain the catalog columns.
        }
      }
      await _createBookSourceTables(db);
      debugPrint('[XiaoQi] DB: v21→v22 PDF 目录字段迁移完成');
    }

    if (oldVersion < 23 && newVersion >= 23) {
      try {
        await db.execute(
          'ALTER TABLE book_sources ADD COLUMN catalog_parser_version INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {
        // Development databases may already contain the parser version.
      }
      debugPrint('[XiaoQi] DB: v22→v23 PDF 目录解析器版本迁移完成');
    }

    if (oldVersion < 24 && newVersion >= 24) {
      for (final sql in const [
        "ALTER TABLE book_sources ADD COLUMN catalog_run_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_source_catalog_revisions ADD COLUMN run_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_source_catalog_revisions ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_source_catalog_revisions ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Existing development databases may already contain these fields.
        }
      }
      debugPrint('[XiaoQi] DB: v23→v24 PDF 目录任务版本与来源字段迁移完成');
    }

    if (oldVersion < 25 && newVersion >= 25) {
      try {
        await db.execute(
          "ALTER TABLE book_sources ADD COLUMN format TEXT NOT NULL DEFAULT 'pdf'",
        );
      } catch (_) {
        // Development databases may already contain the format column.
      }
      debugPrint('[XiaoQi] DB: v24→v25 书籍来源格式字段迁移完成');
    }

    if (oldVersion < 26 && newVersion >= 26) {
      try {
        await db.execute(
          "ALTER TABLE book_sources ADD COLUMN is_primary INTEGER NOT NULL DEFAULT 0",
        );
      } catch (_) {
        // Development databases may already contain the primary-source flag.
      }
      debugPrint('[XiaoQi] DB: v25→v26 当前正文来源字段迁移完成');
    }

    if (oldVersion < 27 && newVersion >= 27) {
      for (final sql in const [
        "ALTER TABLE book_sources ADD COLUMN origin_uri TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN canonical_uri TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN captured_at TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN package_manifest_path TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN source_version_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE book_sources ADD COLUMN document_parser_version INTEGER NOT NULL DEFAULT 0",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Development databases may already contain these optional fields.
        }
      }
      debugPrint('[XiaoQi] DB: v26→v27 网页资料来源字段迁移完成');
    }

    if (oldVersion < 28 && newVersion >= 28) {
      for (final sql in const [
        "ALTER TABLE capture_pages ADD COLUMN input_kind TEXT NOT NULL DEFAULT 'legacy_unknown'",
        "ALTER TABLE capture_pages ADD COLUMN placement_json TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE capture_source_links ADD COLUMN replaces_link_id INTEGER",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {
          // Existing development databases may already contain the field.
        }
      }
      await _createCaptureSourceLinkTables(db);
      debugPrint('[XiaoQi] DB: v27→v28 图片识别文本来源关联字段迁移完成');
    }

    if (oldVersion < 29 && newVersion >= 29) {
      await _createBookSourceRevisionTables(db);
      debugPrint('[XiaoQi] DB: v28→v29 电子资料编辑版本迁移完成');
    }

    if (oldVersion < 30 && newVersion >= 30) {
      try {
        await db.execute(
          'ALTER TABLE books ADD COLUMN is_in_reading_space INTEGER NOT NULL DEFAULT 1',
        );
      } catch (_) {
        // Some development databases may already contain the field.
      }
      debugPrint('[XiaoQi] DB: v29→v30 书籍在读空间归属迁移完成');
    }

    if (oldVersion < 31 && newVersion >= 31) {
      await _createChatNoteSourceTable(db);
      debugPrint('[XiaoQi] DB: v30→v31 聊天笔记来源快照迁移完成');
    }

    if (oldVersion < 32 && newVersion >= 32) {
      await _createNoteAttachmentTable(db);
      debugPrint('[XiaoQi] DB: v31→v32 笔记附件迁移完成');
    }

    if (oldVersion < 33 && newVersion >= 33) {
      for (final sql in const [
        "ALTER TABLE books ADD COLUMN deleted_at TEXT",
        "ALTER TABLE books ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0",
      ]) {
        try {
          await db.execute(sql);
        } catch (_) {}
      }
      await _createNoteRelationTables(db);
      await db.execute('''
        INSERT OR IGNORE INTO note_book_references
          (note_id, book_id, book_name, book_page, is_primary, created_at)
        SELECT id, book_id, book_name, book_page, 1, COALESCE(created_at, '')
        FROM notes
        WHERE book_id IS NOT NULL
      ''');
      debugPrint('[XiaoQi] DB: v32→v33 笔记引用与回收批次迁移完成');
    }
  }

  static Future<void> _createNoteAttachmentTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'file',
        mime_type TEXT,
        position INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_note_attachments_note_order
      ON note_attachments(note_id, position, id)
    ''');
  }

  static Future<void> _createChatNoteSourceTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_chat_sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        conversation_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        capture_kind TEXT NOT NULL,
        source_text TEXT NOT NULL,
        captured_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_note_chat_sources_note
      ON note_chat_sources(note_id, captured_at)
    ''');
  }

  static Future<void> _createNoteRelationTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_relations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        related_note_id INTEGER NOT NULL,
        relation_type TEXT NOT NULL DEFAULT 'body_link',
        created_at TEXT NOT NULL,
        UNIQUE(note_id, related_note_id, relation_type)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_note_relations_target
      ON note_relations(related_note_id, created_at)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_book_references (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        book_id INTEGER NOT NULL,
        book_name TEXT NOT NULL DEFAULT '',
        book_page TEXT NOT NULL DEFAULT '',
        is_primary INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        UNIQUE(note_id, book_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_note_book_references_book
      ON note_book_references(book_id, note_id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_source_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        book_id INTEGER,
        book_name TEXT NOT NULL DEFAULT '',
        book_page TEXT NOT NULL DEFAULT '',
        capture_page_id INTEGER,
        created_at TEXT NOT NULL,
        is_primary INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_note_source_snapshots_note
      ON note_source_snapshots(note_id, is_primary, created_at)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_recycle_batches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deleted_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS note_recycle_items (
        batch_id INTEGER NOT NULL,
        note_id INTEGER NOT NULL,
        book_id INTEGER,
        reason TEXT NOT NULL DEFAULT 'manual',
        PRIMARY KEY(batch_id, note_id)
      )
    ''');
  }

  static Future<void> _createBookSourceRevisionTables(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_source_document_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL,
        base_content_hash TEXT NOT NULL,
        document_hash TEXT NOT NULL,
        document_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        UNIQUE(source_id, document_hash)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_source_revisions_active
      ON book_source_document_revisions(source_id, is_active, updated_at)
    ''');
  }

  static Future<void> _createCaptureSourceLinkTables(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_source_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        capture_page_id INTEGER NOT NULL,
        target_source_id INTEGER NOT NULL,
        target_source_version_id TEXT NOT NULL DEFAULT '',
        anchor_kind TEXT NOT NULL,
        anchor_json TEXT NOT NULL DEFAULT '{}',
        anchor_key TEXT NOT NULL,
        mode TEXT NOT NULL,
        created_by TEXT NOT NULL DEFAULT 'user_confirmed',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        detached_at TEXT,
        detach_reason TEXT NOT NULL DEFAULT '',
        replaces_link_id INTEGER,
        FOREIGN KEY (capture_page_id) REFERENCES capture_pages(id),
        FOREIGN KEY (target_source_id) REFERENCES book_sources(id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_source_links_page_active
      ON capture_source_links(capture_page_id)
      WHERE detached_at IS NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_source_links_target_active
      ON capture_source_links(target_source_id, anchor_key)
      WHERE detached_at IS NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_capture_source_links_source_active
      ON capture_source_links(target_source_id, detached_at, updated_at)
    ''');
  }

  static Future<void> _createBookSourceTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        kind TEXT NOT NULL DEFAULT 'book_file',
        format TEXT NOT NULL DEFAULT 'pdf',
        is_primary INTEGER NOT NULL DEFAULT 0,
        display_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size INTEGER NOT NULL DEFAULT 0,
        content_hash TEXT NOT NULL,
        origin_uri TEXT NOT NULL DEFAULT '',
        canonical_uri TEXT NOT NULL DEFAULT '',
        captured_at TEXT NOT NULL DEFAULT '',
        package_manifest_path TEXT NOT NULL DEFAULT '',
        source_version_id TEXT NOT NULL DEFAULT '',
        document_parser_version INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'ready',
        catalog_status TEXT NOT NULL DEFAULT 'not_started',
        catalog_source_kind TEXT NOT NULL DEFAULT '',
        catalog_json TEXT NOT NULL DEFAULT '[]',
        catalog_updated_at TEXT NOT NULL DEFAULT '',
        catalog_parser_version INTEGER NOT NULL DEFAULT 0,
        catalog_run_id TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(book_id, content_hash),
        FOREIGN KEY (book_id) REFERENCES books(id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_sources_book_updated
      ON book_sources(book_id, updated_at)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_source_catalog_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL,
        revision_kind TEXT NOT NULL,
        entries_json TEXT NOT NULL DEFAULT '[]',
        run_id TEXT NOT NULL DEFAULT '',
        content_hash TEXT NOT NULL DEFAULT '',
        parser_version INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (source_id) REFERENCES book_sources(id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_source_catalog_revisions_source
      ON book_source_catalog_revisions(source_id, created_at)
    ''');
  }

  static Future<void> _createBookRecognitionTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        canonical_key TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        authors TEXT NOT NULL DEFAULT '',
        publisher TEXT NOT NULL DEFAULT '',
        edition TEXT NOT NULL DEFAULT '',
        published_date TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        toc_json TEXT NOT NULL DEFAULT '[]',
        external_links_json TEXT NOT NULL DEFAULT '[]',
        metadata_sources_json TEXT NOT NULL DEFAULT '[]',
        metadata_updated_at TEXT NOT NULL DEFAULT '',
        isbn_10 TEXT NOT NULL DEFAULT '',
        isbn_13 TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        cover_path TEXT NOT NULL DEFAULT '',
        cover_type TEXT NOT NULL DEFAULT 'auto',
        cover_template TEXT NOT NULL DEFAULT 'mist',
        source TEXT NOT NULL DEFAULT 'mock',
        source_id TEXT NOT NULL DEFAULT '',
        is_custom INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        is_in_reading_space INTEGER NOT NULL DEFAULT 1,
        pinned_at TEXT,
        last_studied_at TEXT,
        deleted_at TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_batches (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'captured',
        selected_book_id INTEGER,
        recognition_confidence TEXT NOT NULL DEFAULT 'unknown',
        reader_collection_id TEXT NOT NULL DEFAULT '',
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_pages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        batch_id TEXT NOT NULL,
        page_order INTEGER NOT NULL,
        original_path TEXT NOT NULL,
        processed_path TEXT NOT NULL DEFAULT '',
        ocr_json TEXT,
        edited_text TEXT NOT NULL DEFAULT '',
        printed_page TEXT NOT NULL DEFAULT '',
        page_number_source TEXT NOT NULL DEFAULT 'unknown',
        status TEXT NOT NULL DEFAULT 'captured',
        input_kind TEXT NOT NULL DEFAULT 'legacy_unknown',
        placement_json TEXT NOT NULL DEFAULT '',
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(batch_id, page_order)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_recognition_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL UNIQUE,
        confirmed_count INTEGER NOT NULL DEFAULT 0,
        corrected_count INTEGER NOT NULL DEFAULT 0,
        last_confirmed_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_capture_pages_batch_order
      ON capture_pages(batch_id, page_order)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_capture_batches_reader_collection
      ON capture_batches(reader_collection_id, updated_at)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_history_recent
      ON book_recognition_history(last_confirmed_at DESC)
    ''');
  }

  static Future<void> _createBookLearningTables(DatabaseExecutor db) async {
    for (final sql in const [
      'ALTER TABLE books ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE books ADD COLUMN pinned_at TEXT',
      'ALTER TABLE books ADD COLUMN last_studied_at TEXT',
    ]) {
      try {
        await db.execute(sql);
      } catch (_) {
        // A newly-created database already has the column and development
        // builds can contain a partial v15 migration.
      }
    }

    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_study_activity (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        activity_date TEXT NOT NULL,
        last_active_at TEXT NOT NULL,
        action_count INTEGER NOT NULL DEFAULT 1,
        UNIQUE(book_id, activity_date)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE,
        is_system INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_category_links (
        book_id INTEGER NOT NULL,
        category_id INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(book_id, category_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_notes_book_updated
      ON notes(book_id, is_deleted, updated_at)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_books_pinned_studied
      ON books(is_pinned, last_studied_at, created_at)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_activity_date
      ON book_study_activity(book_id, activity_date)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_book_category_category
      ON book_category_links(category_id, book_id)
    ''');

    final now = DateTime.now().toIso8601String();
    for (final category in const [
      '文学',
      '哲学',
      '心灵成长',
      '历史',
      '社会科学',
      '经济管理',
      '语文',
      '数学',
      '英语',
      '物理',
      '化学',
      '生物',
      '计算机',
      '其他',
    ]) {
      await db.insert('book_categories', {
        'name': category,
        'normalized_name': category.toLowerCase(),
        'is_system': 1,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  @visibleForTesting
  Future<void> migrateForTesting(Database db, int oldVersion, int newVersion) {
    return _onUpgrade(db, oldVersion, newVersion);
  }

  @visibleForTesting
  void useDatabaseForTesting(Database? db) {
    _database = db;
  }

  // ========================
  // 通用插入
  // ========================

  Future<int> _defaultNotebookId(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'notebooks',
      columns: ['id'],
      where: 'is_deleted = 0 AND is_archived = 0',
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['id'] as int;
    final now = DateTime.now().toIso8601String();
    return executor.insert('notebooks', {
      'name': '默认笔记本',
      'category': '随手记录',
      'description': '',
      'cover_index': 0,
      'cover_path': '',
      'home_slot': 0,
      'is_pinned': 0,
      'pinned_at': null,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'deleted_home_slot': null,
      'deleted_was_pinned': 0,
      'deleted_pinned_at': null,
      'is_archived': 0,
      'is_deleted': 0,
    });
  }

  Future<Map<String, dynamic>> _noteMap(
    DatabaseExecutor executor,
    Note note,
  ) async {
    final map = note.toMap();
    map['notebook_id'] ??= await _defaultNotebookId(executor);
    return map;
  }

  Future<void> _touchNotebook(
    DatabaseExecutor executor,
    int? notebookId,
    String updatedAt,
  ) async {
    if (notebookId == null) return;
    await executor.update(
      'notebooks',
      {'updated_at': updatedAt},
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [notebookId],
    );
  }

  List<int> _noteIdsFromDelta(String encodedDelta) {
    if (encodedDelta.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(encodedDelta);
      if (decoded is! List) return const [];
      final ids = <int>{};
      for (final operation in decoded) {
        if (operation is! Map) continue;
        final attributes = operation['attributes'];
        if (attributes is! Map) continue;
        final link = attributes['link']?.toString() ?? '';
        final match = RegExp(r'^note://(\d+)$').firstMatch(link.trim());
        final id = int.tryParse(match?.group(1) ?? '');
        if (id != null && id > 0) ids.add(id);
      }
      return ids.toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _syncNoteRelations(
    DatabaseExecutor txn,
    int noteId,
    Map<String, dynamic> map,
  ) async {
    await txn.delete(
      'note_relations',
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
    final now = DateTime.now().toIso8601String();
    final linkedIds = _noteIdsFromDelta(
      map['content_delta'] as String? ?? '',
    ).where((id) => id != noteId).toSet();
    for (final relatedId in linkedIds) {
      await txn.insert('note_relations', {
        'note_id': noteId,
        'related_note_id': relatedId,
        'relation_type': 'body_link',
        'created_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final bookId = map['book_id'] as int?;
    if (bookId == null) return;
    await txn.update(
      'note_book_references',
      {'is_primary': 0},
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
    await txn.insert('note_book_references', {
      'note_id': noteId,
      'book_id': bookId,
      'book_name': map['book_name'] as String? ?? '',
      'book_page': map['book_page'] as String? ?? '',
      'is_primary': 1,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update(
      'note_book_references',
      {
        'book_name': map['book_name'] as String? ?? '',
        'book_page': map['book_page'] as String? ?? '',
        'is_primary': 1,
      },
      where: 'note_id = ? AND book_id = ?',
      whereArgs: [noteId, bookId],
    );
    await txn.delete(
      'note_source_snapshots',
      where: 'note_id = ? AND is_primary = 1',
      whereArgs: [noteId],
    );
    await txn.insert('note_source_snapshots', {
      'note_id': noteId,
      'book_id': bookId,
      'book_name': map['book_name'] as String? ?? '',
      'book_page': map['book_page'] as String? ?? '',
      'capture_page_id': map['capture_page_id'],
      'created_at': now,
      'is_primary': 1,
    });
  }

  Future<int> insertNote(Note note) async {
    try {
      final db = await database;
      final id = await db.transaction((txn) async {
        final map = await _noteMap(txn, note);
        final insertedId = await txn.insert(
          'notes',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await _syncNoteRelations(txn, insertedId, map);
        await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
        return insertedId;
      });
      debugPrint('[XiaoQi] DB: 插入笔记 id=$id, type=${note.type}');
      return id;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 插入笔记失败: $e');
      rethrow;
    }
  }

  Future<int> saveNoteWithChatSource(
    Note note,
    ChatNoteSourceRecord source,
  ) async {
    if (note.type != 'text') {
      throw ArgumentError('聊天摘录只能保存到文字笔记');
    }
    final db = await database;
    return db.transaction((txn) async {
      final map = await _noteMap(txn, note);
      final int noteId;
      if (note.id == null) {
        noteId = await txn.insert('notes', map);
      } else {
        final updateMap = Map<String, dynamic>.from(map)..remove('id');
        final changed = await txn.update(
          'notes',
          updateMap,
          where: 'id = ? AND is_deleted = 0',
          whereArgs: [note.id],
        );
        if (changed != 1) throw StateError('目标笔记不存在或已删除');
        noteId = note.id!;
      }
      await txn.insert('note_chat_sources', source.toMap(noteId));
      await _syncNoteRelations(txn, noteId, map);
      await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
      return noteId;
    });
  }

  Future<(int, List<NoteAttachment>)> saveNoteEditorSnapshot(
    Note note, {
    ChatNoteSourceRecord? source,
    List<NoteAttachment> newAttachments = const [],
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final map = await _noteMap(txn, note);
      final int noteId;
      if (note.id == null) {
        noteId = await txn.insert('notes', map);
      } else {
        final updateMap = Map<String, dynamic>.from(map)..remove('id');
        final changed = await txn.update(
          'notes',
          updateMap,
          where: 'id = ? AND is_deleted = 0',
          whereArgs: [note.id],
        );
        if (changed != 1) throw StateError('目标笔记不存在或已删除');
        noteId = note.id!;
      }
      if (source != null) {
        await txn.insert('note_chat_sources', source.toMap(noteId));
      }
      final savedAttachments = <NoteAttachment>[];
      for (final attachment in newAttachments) {
        final attachmentId = await txn.insert(
          'note_attachments',
          attachment.toMap(forNoteId: noteId),
        );
        savedAttachments.add(
          attachment.copyWith(id: attachmentId, noteId: noteId),
        );
      }
      await _syncNoteRelations(txn, noteId, map);
      await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
      return (noteId, savedAttachments);
    });
  }

  Future<List<NoteAttachment>> queryNoteAttachments(int noteId) async {
    final db = await database;
    final rows = await db.query(
      'note_attachments',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'position, id',
    );
    return rows.map(NoteAttachment.fromMap).toList(growable: false);
  }

  Future<bool> deleteNoteAttachment(int attachmentId) async {
    final db = await database;
    return await db.delete(
          'note_attachments',
          where: 'id = ?',
          whereArgs: [attachmentId],
        ) ==
        1;
  }

  Future<int> insertNoteWithCopiedChatSources(
    Note note, {
    required int sourceNoteId,
    List<NoteAttachment> copiedAttachments = const [],
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final map = await _noteMap(txn, note);
      final noteId = await txn.insert('notes', map);
      final sources = await txn.query(
        'note_chat_sources',
        where: 'note_id = ?',
        whereArgs: [sourceNoteId],
      );
      for (final source in sources) {
        final copy = Map<String, Object?>.from(source)
          ..remove('id')
          ..['note_id'] = noteId;
        await txn.insert('note_chat_sources', copy);
      }
      for (final attachment in copiedAttachments) {
        await txn.insert(
          'note_attachments',
          attachment.toMap(forNoteId: noteId),
        );
      }
      await _syncNoteRelations(txn, noteId, map);
      await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
      return noteId;
    });
  }

  Future<List<ChatNoteSourceRecord>> queryChatNoteSources(int noteId) async {
    final db = await database;
    final rows = await db.query(
      'note_chat_sources',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'captured_at ASC, id ASC',
    );
    return rows
        .map((row) => ChatNoteSourceRecord.fromMap(row))
        .toList(growable: false);
  }

  // ========================
  // 照片笔记专用插入
  // ========================

  Future<int> insertPhotoNote(Note note) async {
    if (note.type != 'photo') {
      throw ArgumentError('insertPhotoNote 只接受 type=photo 的笔记');
    }
    if (note.photoPath.isEmpty) {
      throw ArgumentError('photo_path 不能为空，请提供图片路径');
    }

    try {
      final db = await database;
      final id = await db.transaction((txn) async {
        final map = await _noteMap(txn, note);
        final insertedId = await txn.insert(
          'notes',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await _syncNoteRelations(txn, insertedId, map);
        await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
        return insertedId;
      });
      debugPrint('[XiaoQi] DB: 插入照片笔记 id=$id, photoPath=${note.photoPath}');
      return id;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 插入照片笔记失败: $e');
      rethrow;
    }
  }

  // ========================
  // 查询照片笔记列表
  // ========================

  Future<List<Note>> queryPhotoNotes() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'notes',
        where: 'type = ? AND is_deleted = ?',
        whereArgs: ['photo', 0],
        orderBy:
            'COALESCE(capture_sequence, 2147483647) ASC, COALESCE(captured_at, created_at) ASC, COALESCE(group_index, page_group_index, 2147483647) ASC, id ASC',
      );
      debugPrint('[XiaoQi] DB: 查询照片笔记 ${maps.length} 条');
      return maps.map((map) => Note.fromMap(map)).toList();
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询照片笔记失败: $e');
      rethrow;
    }
  }

  // ========================
  // 查询所有未删除笔记
  // ========================

  Future<List<Note>> queryAllNotes({
    String search = '',
    int? notebookId,
    int? bookId,
  }) async {
    try {
      final db = await database;
      final where = <String>['is_deleted = 0'];
      final args = <Object?>[];
      if (notebookId != null) {
        where.add('notebook_id = ?');
        args.add(notebookId);
      }
      if (bookId != null) {
        where.add('''(
          book_id = ? OR id IN (
            SELECT note_id FROM note_book_references WHERE book_id = ?
          )
        )''');
        args.addAll([bookId, bookId]);
      }
      final normalizedSearch = search.trim();
      if (normalizedSearch.isNotEmpty) {
        where.add('(title LIKE ? OR content LIKE ? OR book_name LIKE ?)');
        final like = '%$normalizedSearch%';
        args.addAll([like, like, like]);
      }
      final List<Map<String, dynamic>> maps = await db.query(
        'notes',
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'is_pinned DESC, pinned_at DESC, updated_at DESC, id DESC',
      );
      debugPrint('[XiaoQi] DB: 查询全部笔记 ${maps.length} 条');
      return maps.map((map) => Note.fromMap(map)).toList();
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询全部笔记失败: $e');
      rethrow;
    }
  }

  Future<List<Note>> queryDeletedNotes() async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'is_deleted = 1',
      orderBy: 'updated_at DESC, id DESC',
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<List<Note>> queryLinkedNotes(int noteId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT notes.*
      FROM notes
      INNER JOIN note_relations
        ON note_relations.related_note_id = notes.id
      WHERE note_relations.note_id = ?
      ORDER BY notes.is_deleted ASC, notes.updated_at DESC, notes.id DESC
    ''',
      [noteId],
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<List<Note>> queryBacklinks(int noteId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT notes.*
      FROM notes
      INNER JOIN note_relations
        ON note_relations.note_id = notes.id
      WHERE note_relations.related_note_id = ?
      ORDER BY notes.is_deleted ASC, notes.updated_at DESC, notes.id DESC
    ''',
      [noteId],
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<void> addNoteRelation({
    required int noteId,
    required int relatedNoteId,
  }) async {
    if (noteId == relatedNoteId) return;
    final db = await database;
    await db.insert('note_relations', {
      'note_id': noteId,
      'related_note_id': relatedNoteId,
      'relation_type': 'body_link',
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeNoteRelation({
    required int noteId,
    required int relatedNoteId,
  }) async {
    final db = await database;
    await db.delete(
      'note_relations',
      where: 'note_id = ? AND related_note_id = ?',
      whereArgs: [noteId, relatedNoteId],
    );
  }

  Future<List<Map<String, Object?>>> queryNoteBookReferences(int noteId) async {
    final db = await database;
    return db.query(
      'note_book_references',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'is_primary DESC, created_at ASC, id ASC',
    );
  }

  Future<void> addNoteBookReference({
    required int noteId,
    required int bookId,
    required String bookName,
    String bookPage = '',
  }) async {
    final db = await database;
    await db.insert('note_book_references', {
      'note_id': noteId,
      'book_id': bookId,
      'book_name': bookName,
      'book_page': bookPage,
      'is_primary': 0,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setNotePinned(int noteId, bool pinned) async {
    final db = await database;
    await db.update(
      'notes',
      {
        'is_pinned': pinned ? 1 : 0,
        'pinned_at': pinned ? DateTime.now().toIso8601String() : null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [noteId],
    );
  }

  Future<void> restoreNotes(Iterable<int> noteIds) async {
    final ids = noteIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'notes',
      {'is_deleted': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<void> permanentlyDeleteNotes(Iterable<int> noteIds) async {
    final ids = noteIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      for (final table in const [
        'note_relations',
        'note_book_references',
        'note_source_snapshots',
        'note_attachments',
        'note_chat_sources',
        'ai_usage',
      ]) {
        await txn.delete(
          table,
          where: 'note_id IN ($placeholders)',
          whereArgs: ids,
        );
      }
      await txn.delete('notes', where: 'id IN ($placeholders)', whereArgs: ids);
    });
  }

  /// 首页使用的最近笔记，按最后更新时间倒序返回。
  Future<List<Note>> queryRecentNotes({int limit = 3}) async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'is_deleted = ?',
      whereArgs: [0],
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<List<Note>> queryNotesForChatCapture({
    int? preferredBookId,
    int? notebookId,
  }) async {
    final db = await database;
    final where = <String>[
      'is_deleted = 0',
      "type = 'text'",
      "pdf_path = ''",
      "photo_path = ''",
      "source_photo_path = ''",
    ];
    final args = <Object?>[];
    if (notebookId != null) {
      where.add('notebook_id = ?');
      args.add(notebookId);
    }
    final orderBy = preferredBookId == null
        ? 'updated_at DESC, id DESC'
        : 'CASE WHEN book_id = ? THEN 0 ELSE 1 END, updated_at DESC, id DESC';
    if (preferredBookId != null) args.add(preferredBookId);
    final rows = await db.rawQuery(
      'SELECT * FROM notes WHERE ${where.join(' AND ')} '
      'ORDER BY $orderBy',
      args,
    );
    return rows.map(Note.fromMap).toList(growable: false);
  }

  // ========================
  // 笔记本与目录
  // ========================

  Future<List<Notebook>> queryNotebooks({
    String status = 'active',
    String query = '',
    String category = 'all',
    String sort = 'updated',
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];

    switch (status) {
      case 'home':
        where.add('b.is_deleted = 0 AND b.is_archived = 0');
        where.add('b.home_slot IS NOT NULL');
        break;
      case 'archived':
        where.add('b.is_deleted = 0 AND b.is_archived = 1');
        break;
      case 'deleted':
        where.add('b.is_deleted = 1');
        break;
      case 'active':
      default:
        where.add('b.is_deleted = 0 AND b.is_archived = 0');
        break;
    }

    if (category != 'all') {
      where.add('b.category = ?');
      args.add(category);
    }
    final normalizedQuery = query.trim();
    if (normalizedQuery.isNotEmpty) {
      where.add('(b.name LIKE ? OR b.category LIKE ? OR b.description LIKE ?)');
      final like = '%$normalizedQuery%';
      args.addAll([like, like, like]);
    }

    final orderBy = switch (sort) {
      'created' => 'b.created_at DESC, b.id DESC',
      'name' => 'b.name COLLATE NOCASE ASC, b.id ASC',
      _ when status == 'home' =>
        'b.home_slot ASC, b.is_pinned DESC, b.updated_at DESC',
      _ => 'b.is_pinned DESC, b.pinned_at DESC, b.updated_at DESC, b.id DESC',
    };

    final maps = await db.rawQuery('''
      SELECT b.*, COUNT(n.id) AS note_count
      FROM notebooks b
      LEFT JOIN notes n
        ON n.notebook_id = b.id AND n.is_deleted = 0
      WHERE ${where.join(' AND ')}
      GROUP BY b.id
      ORDER BY $orderBy
    ''', args);
    return maps.map(Notebook.fromMap).toList(growable: false);
  }

  Future<List<Notebook>> queryHomeNotebooks() {
    return queryNotebooks(status: 'home', sort: 'updated');
  }

  Future<Notebook?> getNotebookById(int id) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT b.*, COUNT(n.id) AS note_count
      FROM notebooks b
      LEFT JOIN notes n
        ON n.notebook_id = b.id AND n.is_deleted = 0
      WHERE b.id = ? AND b.is_deleted = 0
      GROUP BY b.id
      LIMIT 1
      ''',
      [id],
    );
    return maps.isEmpty ? null : Notebook.fromMap(maps.first);
  }

  Future<int> createNotebook({
    required String name,
    String category = '默认分类',
    String description = '',
    int coverIndex = 0,
    String coverPath = '',
    int? homeSlot,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', '笔记本名称不能为空');
    }
    final now = DateTime.now().toIso8601String();
    final db = await database;
    return db.transaction((txn) async {
      final resolvedHomeSlot = homeSlot == null
          ? null
          : await _firstFreeHomeSlot(txn);
      if (homeSlot != null && resolvedHomeSlot == null) {
        throw StateError('首页最多展示 $homeNotebookLimit 本笔记本');
      }
      return txn.insert('notebooks', {
        'name': trimmedName,
        'category': category.trim().isEmpty ? '默认分类' : category.trim(),
        'description': description.trim(),
        'cover_index': coverIndex,
        'cover_path': coverPath,
        'home_slot': resolvedHomeSlot,
        'is_pinned': 0,
        'pinned_at': null,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'deleted_home_slot': null,
        'deleted_was_pinned': 0,
        'deleted_pinned_at': null,
        'is_archived': 0,
        'is_deleted': 0,
      });
    });
  }

  Future<int> updateNotebook(Notebook notebook) async {
    if (notebook.id == null) {
      throw ArgumentError('更新笔记本时 id 不能为 null');
    }
    if (notebook.name.trim().isEmpty) {
      throw ArgumentError('笔记本名称不能为空');
    }
    final db = await database;
    return db.update(
      'notebooks',
      notebook
          .copyWith(
            name: notebook.name.trim(),
            updatedAt: DateTime.now().toIso8601String(),
          )
          .toMap(),
      where: 'id = ?',
      whereArgs: [notebook.id],
    );
  }

  Future<int?> firstFreeHomeSlot({int? excludingNotebookId}) async {
    final db = await database;
    final rows = await db.query(
      'notebooks',
      columns: ['home_slot'],
      where:
          'is_deleted = 0 AND is_archived = 0 AND home_slot IS NOT NULL'
          '${excludingNotebookId == null ? '' : ' AND id != ?'}',
      whereArgs: excludingNotebookId == null ? null : [excludingNotebookId],
    );
    final used = rows.map((row) => row['home_slot']).whereType<int>().toSet();
    for (var slot = 0; slot < homeNotebookLimit; slot++) {
      if (!used.contains(slot)) return slot;
    }
    return null;
  }

  Future<void> setNotebookHomeSlot(int notebookId, int? slot) async {
    final db = await database;
    await db.transaction((txn) async {
      final current = await txn.query(
        'notebooks',
        columns: ['home_slot'],
        where: 'id = ? AND is_deleted = 0 AND is_archived = 0',
        whereArgs: [notebookId],
        limit: 1,
      );
      if (current.isEmpty) throw StateError('笔记本不可用');
      final oldSlot = current.first['home_slot'] as int?;
      if (slot != null && oldSlot == null) {
        final count =
            Sqflite.firstIntValue(
              await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                WHERE is_deleted = 0 AND is_archived = 0
                  AND home_slot IS NOT NULL'''),
            ) ??
            0;
        if (count >= homeNotebookLimit) throw StateError('首页书架已满');
      }
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {
          'home_slot': slot == null
              ? null
              : oldSlot ?? await _firstFreeHomeSlot(txn),
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [notebookId],
      );
      await _compactHomeSlots(txn);
    });
  }

  Future<void> setNotebookPinned(int notebookId, bool pinned) async {
    final db = await database;
    await db.transaction((txn) async {
      if (pinned) {
        final rows = await txn.query(
          'notebooks',
          columns: ['is_pinned'],
          where: 'id = ? AND is_deleted = 0 AND is_archived = 0',
          whereArgs: [notebookId],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('笔记本不可用');
        if ((rows.first['is_pinned'] as int? ?? 0) == 0) {
          final count =
              Sqflite.firstIntValue(
                await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                  WHERE is_deleted = 0 AND is_archived = 0
                    AND is_pinned = 1'''),
              ) ??
              0;
          if (count >= pinnedNotebookLimit) throw StateError('书房置顶已达上限');
        }
      }
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {
          'is_pinned': pinned ? 1 : 0,
          'pinned_at': pinned ? now : null,
          'updated_at': now,
        },
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [notebookId],
      );
    });
  }

  Future<void> setNotebookArchived(int notebookId, bool archived) async {
    final db = await database;
    await db.transaction((txn) async {
      if (!archived) {
        final target = await txn.query(
          'notebooks',
          columns: ['is_pinned'],
          where: 'id = ? AND is_deleted = 0 AND is_archived = 1',
          whereArgs: [notebookId],
          limit: 1,
        );
        if (target.isNotEmpty &&
            (target.first['is_pinned'] as int? ?? 0) == 1) {
          final pinnedCount =
              Sqflite.firstIntValue(
                await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                  WHERE is_deleted = 0 AND is_archived = 0
                    AND is_pinned = 1'''),
              ) ??
              0;
          if (pinnedCount >= pinnedNotebookLimit) {
            throw StateError('书房置顶已达上限');
          }
        }
      }
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {'is_archived': archived ? 1 : 0, 'home_slot': null, 'updated_at': now},
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [notebookId],
      );
      await _compactHomeSlots(txn);
    });
  }

  Future<void> restoreNotebook(int notebookId) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'notebooks',
      {
        'is_deleted': 0,
        'deleted_at': null,
        'deleted_home_slot': null,
        'deleted_was_pinned': 0,
        'deleted_pinned_at': null,
        'home_slot': null,
        'is_pinned': 0,
        'pinned_at': null,
        'is_archived': 0,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [notebookId],
    );
  }

  Future<List<Note>> queryNotesByNotebook(int notebookId) async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'notebook_id = ? AND is_deleted = 0',
      whereArgs: [notebookId],
      orderBy: 'updated_at DESC, id DESC',
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<void> moveNoteToNotebook(int noteId, int notebookId) async {
    final db = await database;
    await db.transaction((txn) async {
      final notebook = await txn.query(
        'notebooks',
        columns: ['id'],
        where: 'id = ? AND is_deleted = 0 AND is_archived = 0',
        whereArgs: [notebookId],
        limit: 1,
      );
      if (notebook.isEmpty) {
        throw StateError('目标笔记本不可用');
      }
      final existing = await txn.query(
        'notes',
        columns: ['notebook_id'],
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [noteId],
        limit: 1,
      );
      final now = DateTime.now().toIso8601String();
      final changed = await txn.update(
        'notes',
        {'notebook_id': notebookId, 'updated_at': now},
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [noteId],
      );
      if (changed != 1) throw StateError('笔记不存在或已删除');
      await _touchNotebook(txn, notebookId, now);
      if (existing.isNotEmpty) {
        await _touchNotebook(txn, existing.first['notebook_id'] as int?, now);
      }
    });
  }

  Future<void> deleteNotebook(int notebookId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'notebooks',
        columns: ['home_slot', 'is_pinned', 'pinned_at'],
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [notebookId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {
          'is_deleted': 1,
          'deleted_at': now,
          'deleted_home_slot': row['home_slot'],
          'deleted_was_pinned': row['is_pinned'],
          'deleted_pinned_at': row['pinned_at'],
          'home_slot': null,
          'is_pinned': 0,
          'pinned_at': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [notebookId],
      );
      await _compactHomeSlots(txn);
    });
  }

  Future<void> replaceHomeNotebook({
    required int incomingNotebookId,
    required int displacedNotebookId,
  }) async {
    if (incomingNotebookId == displacedNotebookId) return;
    final db = await database;
    await db.transaction((txn) async {
      final displaced = await txn.query(
        'notebooks',
        columns: ['home_slot'],
        where:
            'id = ? AND is_deleted = 0 AND is_archived = 0 '
            'AND home_slot IS NOT NULL',
        whereArgs: [displacedNotebookId],
        limit: 1,
      );
      final incoming = await txn.query(
        'notebooks',
        columns: ['id'],
        where: 'id = ? AND is_deleted = 0 AND is_archived = 0',
        whereArgs: [incomingNotebookId],
        limit: 1,
      );
      if (displaced.isEmpty || incoming.isEmpty) {
        throw StateError('替换的笔记本不可用');
      }
      final slot = displaced.first['home_slot'] as int;
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {'home_slot': null, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [displacedNotebookId],
      );
      await txn.update(
        'notebooks',
        {'home_slot': slot, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [incomingNotebookId],
      );
      await _compactHomeSlots(txn);
    });
  }

  Future<bool> undoDeleteNotebook(int notebookId) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'notebooks',
        where: 'id = ? AND is_deleted = 1',
        whereArgs: [notebookId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final homeRows = await txn.query(
        'notebooks',
        columns: ['id', 'home_slot'],
        where: 'is_deleted = 0 AND is_archived = 0 AND home_slot IS NOT NULL',
        orderBy: 'home_slot ASC, id ASC',
      );
      final preferred = row['deleted_home_slot'] as int?;
      int? restoredSlot;
      if (preferred != null && homeRows.length < homeNotebookLimit) {
        restoredSlot = preferred.clamp(0, homeRows.length);
        for (final homeRow in homeRows.reversed) {
          final slot = homeRow['home_slot'] as int;
          if (slot < restoredSlot) continue;
          await txn.update(
            'notebooks',
            {'home_slot': slot + 1},
            where: 'id = ?',
            whereArgs: [homeRow['id']],
          );
        }
      }
      final pinnedCount =
          Sqflite.firstIntValue(
            await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
              WHERE is_deleted = 0 AND is_archived = 0 AND is_pinned = 1'''),
          ) ??
          0;
      final restorePin =
          (row['deleted_was_pinned'] as int? ?? 0) == 1 &&
          pinnedCount < pinnedNotebookLimit;
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {
          'is_deleted': 0,
          'deleted_at': null,
          'deleted_home_slot': null,
          'deleted_was_pinned': 0,
          'deleted_pinned_at': null,
          'home_slot': restoredSlot,
          'is_pinned': restorePin ? 1 : 0,
          'pinned_at': restorePin
              ? (row['deleted_pinned_at'] as String? ?? now)
              : null,
          'is_archived': 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [notebookId],
      );
      await _compactHomeSlots(txn);
      return true;
    });
  }

  Future<void> permanentlyDeleteNotebook(int notebookId) async {
    final db = await database;
    String coverPath = '';
    await db.transaction((txn) async {
      final rows = await txn.query(
        'notebooks',
        columns: ['cover_path'],
        where: 'id = ?',
        whereArgs: [notebookId],
        limit: 1,
      );
      coverPath = rows.isEmpty ? '' : rows.first['cover_path'] as String? ?? '';
      await txn.delete(
        'ai_usage',
        where: 'note_id IN (SELECT id FROM notes WHERE notebook_id = ?)',
        whereArgs: [notebookId],
      );
      await txn.delete(
        'notes',
        where: 'notebook_id = ?',
        whereArgs: [notebookId],
      );
      await txn.delete('notebooks', where: 'id = ?', whereArgs: [notebookId]);
      await _compactHomeSlots(txn);
    });
    await _deleteCoverFile(coverPath);
  }

  Future<int> purgeExpiredDeletedNotebooks({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now())
        .subtract(deletedNotebookRetention)
        .toIso8601String();
    final db = await database;
    final rows = await db.query(
      'notebooks',
      columns: ['id'],
      where: 'is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at <= ?',
      whereArgs: [cutoff],
    );
    for (final row in rows) {
      await permanentlyDeleteNotebook(row['id'] as int);
    }
    return rows.length;
  }

  Future<void> setNotebooksPinned(List<int> notebookIds, bool pinned) async {
    if (notebookIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final placeholders = List.filled(notebookIds.length, '?').join(',');
      final targets = await txn.query(
        'notebooks',
        columns: ['id', 'is_pinned'],
        where: 'id IN ($placeholders) AND is_deleted = 0 AND is_archived = 0',
        whereArgs: notebookIds,
      );
      if (pinned) {
        final incoming = targets
            .where((row) => (row['is_pinned'] as int? ?? 0) == 0)
            .length;
        final current =
            Sqflite.firstIntValue(
              await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                WHERE is_deleted = 0 AND is_archived = 0 AND is_pinned = 1'''),
            ) ??
            0;
        if (current + incoming > pinnedNotebookLimit) {
          throw StateError('书房置顶已达上限');
        }
      }
      final now = DateTime.now().toIso8601String();
      await txn.update(
        'notebooks',
        {
          'is_pinned': pinned ? 1 : 0,
          'pinned_at': pinned ? now : null,
          'updated_at': now,
        },
        where: 'id IN ($placeholders)',
        whereArgs: notebookIds,
      );
    });
  }

  Future<void> setNotebooksHome(List<int> notebookIds, bool show) async {
    if (notebookIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final placeholders = List.filled(notebookIds.length, '?').join(',');
      if (!show) {
        await txn.update(
          'notebooks',
          {'home_slot': null, 'updated_at': DateTime.now().toIso8601String()},
          where: 'id IN ($placeholders)',
          whereArgs: notebookIds,
        );
        await _compactHomeSlots(txn);
        return;
      }
      final targets = await txn.query(
        'notebooks',
        columns: ['id', 'home_slot'],
        where: 'id IN ($placeholders) AND is_deleted = 0 AND is_archived = 0',
        whereArgs: notebookIds,
        orderBy: 'id ASC',
      );
      final incoming = targets
          .where((row) => row['home_slot'] == null)
          .toList(growable: false);
      final currentCount =
          Sqflite.firstIntValue(
            await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
              WHERE is_deleted = 0 AND is_archived = 0
                AND home_slot IS NOT NULL'''),
          ) ??
          0;
      if (currentCount + incoming.length > homeNotebookLimit) {
        throw StateError('首页剩余位置不足');
      }
      final now = DateTime.now().toIso8601String();
      for (var index = 0; index < incoming.length; index++) {
        await txn.update(
          'notebooks',
          {'home_slot': currentCount + index, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [incoming[index]['id']],
        );
      }
      await _compactHomeSlots(txn);
    });
  }

  Future<void> setNotebooksArchived(
    List<int> notebookIds,
    bool archived,
  ) async {
    if (notebookIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final placeholders = List.filled(notebookIds.length, '?').join(',');
      if (!archived) {
        final returningPinned =
            Sqflite.firstIntValue(
              await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                  WHERE id IN ($placeholders) AND is_deleted = 0
                    AND is_archived = 1 AND is_pinned = 1''', notebookIds),
            ) ??
            0;
        final pinnedCount =
            Sqflite.firstIntValue(
              await txn.rawQuery('''SELECT COUNT(*) FROM notebooks
                WHERE is_deleted = 0 AND is_archived = 0
                  AND is_pinned = 1'''),
            ) ??
            0;
        if (pinnedCount + returningPinned > pinnedNotebookLimit) {
          throw StateError('书房置顶已达上限');
        }
      }
      await txn.update(
        'notebooks',
        {
          'is_archived': archived ? 1 : 0,
          'home_slot': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id IN ($placeholders) AND is_deleted = 0',
        whereArgs: notebookIds,
      );
      await _compactHomeSlots(txn);
    });
  }

  Future<void> deleteNotebooks(List<int> notebookIds) async {
    if (notebookIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      for (final notebookId in notebookIds) {
        final rows = await txn.query(
          'notebooks',
          columns: ['home_slot', 'is_pinned', 'pinned_at'],
          where: 'id = ? AND is_deleted = 0',
          whereArgs: [notebookId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final row = rows.first;
        await txn.update(
          'notebooks',
          {
            'is_deleted': 1,
            'deleted_at': now,
            'deleted_home_slot': row['home_slot'],
            'deleted_was_pinned': row['is_pinned'],
            'deleted_pinned_at': row['pinned_at'],
            'home_slot': null,
            'is_pinned': 0,
            'pinned_at': null,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [notebookId],
        );
      }
      await _compactHomeSlots(txn);
    });
  }

  Future<void> restoreNotebooks(List<int> notebookIds) async {
    if (notebookIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(notebookIds.length, '?').join(',');
    await db.update(
      'notebooks',
      {
        'is_deleted': 0,
        'deleted_at': null,
        'deleted_home_slot': null,
        'deleted_was_pinned': 0,
        'deleted_pinned_at': null,
        'home_slot': null,
        'is_pinned': 0,
        'pinned_at': null,
        'is_archived': 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id IN ($placeholders)',
      whereArgs: notebookIds,
    );
  }

  Future<void> permanentlyDeleteNotebooks(List<int> notebookIds) async {
    for (final id in notebookIds) {
      await permanentlyDeleteNotebook(id);
    }
  }

  Future<int?> _firstFreeHomeSlot(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'notebooks',
      columns: ['home_slot'],
      where: 'is_deleted = 0 AND is_archived = 0 AND home_slot IS NOT NULL',
    );
    final used = rows.map((row) => row['home_slot']).whereType<int>().toSet();
    for (var slot = 0; slot < homeNotebookLimit; slot++) {
      if (!used.contains(slot)) return slot;
    }
    return null;
  }

  Future<void> _compactHomeSlots(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'notebooks',
      columns: ['id', 'home_slot'],
      where: 'is_deleted = 0 AND is_archived = 0 AND home_slot IS NOT NULL',
      orderBy: 'home_slot ASC, id ASC',
    );
    for (var index = 0; index < rows.length; index++) {
      if (rows[index]['home_slot'] == index) continue;
      await executor.update(
        'notebooks',
        {'home_slot': index},
        where: 'id = ?',
        whereArgs: [rows[index]['id']],
      );
    }
  }

  Future<void> _deleteCoverFile(String path) async {
    if (path.trim().isEmpty) return;
    try {
      final documents = await getApplicationDocumentsDirectory();
      final coverRoot = p.normalize(p.join(documents.path, 'book_covers'));
      final target = p.normalize(File(path).absolute.path);
      final rootPrefix = coverRoot.endsWith(p.separator)
          ? coverRoot
          : '$coverRoot${p.separator}';
      // Cover paths are app-owned files. Never allow a malformed DB value to
      // make notebook cleanup delete an arbitrary path outside that folder.
      if (!target.startsWith(rootPrefix)) return;
      final file = File(target);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('[XiaoQi] DB: 删除封面文件失败: $error');
    }
  }

  // ========================
  // 按 ID 查询单条
  // ========================

  Future<Note?> getNoteById(int id) async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'notes',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (maps.isEmpty) {
        debugPrint('[XiaoQi] DB: 笔记 id=$id 不存在');
        return null;
      }
      debugPrint('[XiaoQi] DB: 查询笔记 id=$id');
      return Note.fromMap(maps.first);
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询笔记失败: $e');
      rethrow;
    }
  }

  Future<List<int>> insertNotesBatch(List<Note> notes) async {
    if (notes.isEmpty) return const [];
    final db = await database;
    final ids = <int>[];
    await db.transaction((txn) async {
      final touchedNotebooks = <int>{};
      var latestUpdatedAt = '';
      for (final note in notes) {
        final map = await _noteMap(txn, note);
        ids.add(
          await txn.insert(
            'notes',
            map,
            conflictAlgorithm: ConflictAlgorithm.replace,
          ),
        );
        final notebookId = map['notebook_id'] as int?;
        if (notebookId != null) touchedNotebooks.add(notebookId);
        if (note.updatedAt.compareTo(latestUpdatedAt) > 0) {
          latestUpdatedAt = note.updatedAt;
        }
      }
      for (final notebookId in touchedNotebooks) {
        await _touchNotebook(txn, notebookId, latestUpdatedAt);
      }
    });
    return ids;
  }

  /// Persists OCR pages without creating duplicates when a save was completed
  /// in the database but the app closed before the batch status was updated.
  /// The capture page is the stable source identity for this operation.
  Future<List<Note>> upsertNotesByCapturePage(List<Note> notes) async {
    if (notes.isEmpty) return const [];
    final db = await database;
    final persisted = <Note>[];
    await db.transaction((txn) async {
      final touchedNotebooks = <int>{};
      var latestUpdatedAt = '';
      for (final note in notes) {
        int? existingId;
        if (note.capturePageId != null) {
          final rows = await txn.query(
            'notes',
            columns: ['id'],
            where: 'capture_page_id = ? AND is_deleted = 0',
            whereArgs: [note.capturePageId],
            limit: 1,
          );
          existingId = rows.isEmpty ? null : rows.first['id'] as int?;
        }
        if (existingId == null &&
            note.captureBatchId?.isNotEmpty == true &&
            note.captureSequence != null) {
          final rows = await txn.query(
            'notes',
            columns: ['id'],
            where:
                'capture_batch_id = ? AND capture_sequence = ? AND is_deleted = 0',
            whereArgs: [note.captureBatchId, note.captureSequence],
            limit: 1,
          );
          existingId = rows.isEmpty ? null : rows.first['id'] as int?;
        }
        final value = existingId == null ? note : note.copyWith(id: existingId);
        final map = await _noteMap(txn, value);
        map.remove('id');
        late final int id;
        if (existingId == null) {
          id = await txn.insert('notes', map);
        } else {
          await txn.update(
            'notes',
            map,
            where: 'id = ?',
            whereArgs: [existingId],
          );
          id = existingId;
        }
        persisted.add(value.copyWith(id: id));
        final notebookId = map['notebook_id'] as int?;
        if (notebookId != null) touchedNotebooks.add(notebookId);
        if (value.updatedAt.compareTo(latestUpdatedAt) > 0) {
          latestUpdatedAt = value.updatedAt;
        }
      }
      for (final notebookId in touchedNotebooks) {
        await _touchNotebook(txn, notebookId, latestUpdatedAt);
      }
    });
    return persisted;
  }

  Future<List<Note>> queryDoublePageGroup(String pageGroupId) async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where:
          '(group_id = ? OR page_group_id = ?) AND is_double_page = 1 AND is_deleted = 0',
      whereArgs: [pageGroupId, pageGroupId],
      orderBy: 'COALESCE(group_index, page_group_index) ASC, id ASC',
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<List<Note>> queryCaptureBatch(String batchId) async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'capture_batch_id = ? AND is_deleted = 0',
      whereArgs: [batchId],
      orderBy:
          'capture_sequence ASC, COALESCE(captured_at, created_at) ASC, COALESCE(group_index, page_group_index, 2147483647) ASC, id ASC',
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  /// Reads all saved pages belonging to one logical reader collection. Each
  /// scan remains a separate capture batch/source fragment in the database.
  Future<List<Note>> queryReaderCollection(String collectionId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''SELECT notes.*
         FROM notes
         INNER JOIN capture_batches
           ON capture_batches.id = notes.capture_batch_id
         WHERE capture_batches.reader_collection_id = ?
           AND notes.is_deleted = 0
         ORDER BY notes.capture_sequence ASC,
           COALESCE(notes.captured_at, notes.created_at) ASC,
           notes.id ASC''',
      [collectionId],
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  Future<List<Note>> queryReaderCollectionForBatch(String batchId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''SELECT notes.*
         FROM notes
         INNER JOIN capture_batches
           ON capture_batches.id = notes.capture_batch_id
         WHERE capture_batches.reader_collection_id = (
             SELECT reader_collection_id FROM capture_batches
             WHERE id = ? LIMIT 1
           )
           AND notes.is_deleted = 0
         ORDER BY notes.capture_sequence ASC,
           COALESCE(notes.captured_at, notes.created_at) ASC,
           notes.id ASC''',
      [batchId],
    );
    return maps.map(Note.fromMap).toList(growable: false);
  }

  // ========================
  // 当天 AI 生成计数
  // ========================

  Future<int> getTodayAiCount() async {
    try {
      final db = await database;
      final now = DateTime.now();
      final today =
          '${now.year}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final List<Map<String, dynamic>> result = await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM notes '
        'WHERE type = ? AND created_at LIKE ? AND is_deleted = ?',
        ['ai_generated', '$today%', 0],
      );
      final count = Sqflite.firstIntValue(result) ?? 0;
      debugPrint('[XiaoQi] DB: 今日AI生成笔记数 = $count');
      return count;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询AI计数失败: $e');
      rethrow;
    }
  }

  // ========================
  // 更新笔记
  // ========================

  Future<int> update(Note note) async {
    if (note.id == null) {
      throw ArgumentError('更新笔记时 id 不能为 null');
    }

    try {
      final db = await database;
      final count = await db.transaction((txn) async {
        final before = await txn.query(
          'notes',
          columns: ['notebook_id'],
          where: 'id = ?',
          whereArgs: [note.id],
          limit: 1,
        );
        final map = await _noteMap(txn, note);
        final changed = await txn.update(
          'notes',
          map,
          where: 'id = ?',
          whereArgs: [note.id],
        );
        await _syncNoteRelations(txn, note.id!, map);
        await _touchNotebook(txn, map['notebook_id'] as int?, note.updatedAt);
        if (before.isNotEmpty) {
          await _touchNotebook(
            txn,
            before.first['notebook_id'] as int?,
            note.updatedAt,
          );
        }
        return changed;
      });
      debugPrint('[XiaoQi] DB: 更新笔记 id=${note.id}, 影响行数=$count');
      return count;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 更新笔记失败: $e');
      rethrow;
    }
  }

  // ========================
  // 软删除
  // ========================

  Future<int> softDelete(int id) async {
    try {
      final db = await database;
      final now = DateTime.now().toIso8601String();
      final count = await db.transaction((txn) async {
        final rows = await txn.query(
          'notes',
          columns: ['notebook_id', 'book_id'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        final batchId = await txn.insert('note_recycle_batches', {
          'deleted_at': now,
          'expires_at': DateTime.parse(
            now,
          ).add(deletedNotebookRetention).toIso8601String(),
        });
        final changed = await txn.update(
          'notes',
          {'is_deleted': 1, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [id],
        );
        if (changed == 1) {
          await txn.insert('note_recycle_items', {
            'batch_id': batchId,
            'note_id': id,
            'book_id': rows.isEmpty ? null : rows.first['book_id'],
            'reason': 'manual',
          });
        }
        if (rows.isNotEmpty) {
          await _touchNotebook(txn, rows.first['notebook_id'] as int?, now);
        }
        return changed;
      });
      debugPrint('[XiaoQi] DB: 软删除笔记 id=$id, 影响行数=$count');
      return count;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 软删除失败: $e');
      rethrow;
    }
  }

  // ========================
  // AI 使用次数追踪
  // ========================

  Future<void> insertAiUsage(int noteId) async {
    try {
      final db = await database;
      final now = DateTime.now().toIso8601String();
      await db.insert('ai_usage', {'note_id': noteId, 'used_at': now});
      debugPrint('[XiaoQi] DB: 记录AI使用 note_id=$noteId');
    } catch (e) {
      debugPrint('[XiaoQi] DB: 记录AI使用失败: $e');
      rethrow;
    }
  }

  Future<int> getTodayAiUsageCount() async {
    try {
      final db = await database;
      final now = DateTime.now();
      final today =
          '${now.year}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final List<Map<String, dynamic>> result = await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM ai_usage WHERE used_at LIKE ?',
        ['$today%'],
      );
      final count = Sqflite.firstIntValue(result) ?? 0;
      debugPrint('[XiaoQi] DB: 今日AI使用次数 = $count');
      return count;
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询AI使用次数失败: $e');
      rethrow;
    }
  }

  // ========================
  // User CRUD
  // ========================

  Future<User?> getUser() async {
    try {
      final db = await database;
      final results = await db.query('user', limit: 1);
      if (results.isEmpty) {
        debugPrint('[XiaoQi] DB: 用户不存在');
        return null;
      }
      return User.fromMap(results.first);
    } catch (e) {
      debugPrint('[XiaoQi] DB: 查询用户失败: $e');
      rethrow;
    }
  }

  Future<void> upsertUser(String nickname) async {
    try {
      final db = await database;
      final existing = await getUser();
      if (existing != null) {
        await db.update(
          'user',
          {
            'nickname': nickname,
            'created_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [existing.id],
        );
        debugPrint('[XiaoQi] DB: 更新用户 id=${existing.id}, nickname=$nickname');
      } else {
        await db.insert('user', User(nickname: nickname).toMap());
        debugPrint('[XiaoQi] DB: 插入用户 nickname=$nickname');
      }
    } catch (e) {
      debugPrint('[XiaoQi] DB: 保存用户失败: $e');
      rethrow;
    }
  }
}
