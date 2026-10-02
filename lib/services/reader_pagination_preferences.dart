import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/reader_pagination.dart';

/// Per-book, per-format reading preference. It is deliberately not global:
/// the same book may use different modes for its PDF and reflowable sources.
class ReaderPaginationPreferences {
  const ReaderPaginationPreferences();

  static const _prefix = 'book_reader.pagination_mode.v1';
  static const _anchorPrefix = 'book_reader.anchor.v1';

  Future<ReaderPaginationMode> load({
    required int bookId,
    required String format,
  }) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getString(_key(bookId, format));
      return ReaderPaginationMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => ReaderPaginationMode.horizontal,
      );
    } catch (_) {
      return ReaderPaginationMode.horizontal;
    }
  }

  Future<void> save({
    required int bookId,
    required String format,
    required ReaderPaginationMode mode,
  }) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_key(bookId, format), mode.name);
    } catch (_) {
      // A storage failure must never interrupt reading or page changes.
    }
  }

  Future<ReaderAnchor?> loadAnchor({
    required int bookId,
    required int sourceId,
  }) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return readerAnchorFromJson(
        preferences.getString(_anchorKey(bookId, sourceId)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAnchor({
    required int bookId,
    required ReaderAnchor anchor,
  }) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _anchorKey(bookId, int.tryParse(anchor.sourceId) ?? 0),
        readerAnchorJson(anchor),
      );
    } catch (_) {
      // Position persistence must never interrupt reading.
    }
  }

  String _key(int bookId, String format) =>
      '$_prefix.$bookId.${normalizeBookSourceFormat(format)}';

  String _anchorKey(int bookId, int sourceId) =>
      '$_anchorPrefix.$bookId.$sourceId';
}
