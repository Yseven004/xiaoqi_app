import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_library_query.dart';

class BookLearningPreferencesState {
  const BookLearningPreferencesState({
    this.viewMode = BookLibraryViewMode.grid,
    this.query = const BookLibraryQuery(),
  });

  final BookLibraryViewMode viewMode;
  final BookLibraryQuery query;
}

class BookLearningPreferences {
  static const _viewModeKey = 'book_learning.view_mode';
  static const _sortModeKey = 'book_learning.sort_mode';
  static const _sortDirectionKey = 'book_learning.sort_direction';
  static const _categoryIdKey = 'book_learning.category_id';
  static const _uncategorizedOnlyKey = 'book_learning.uncategorized_only';

  Future<BookLearningPreferencesState> load() async {
    final prefs = await SharedPreferences.getInstance();
    return BookLearningPreferencesState(
      viewMode: _parseViewMode(prefs.getString(_viewModeKey)),
      query: BookLibraryQuery(
        categoryId: prefs.getInt(_categoryIdKey),
        uncategorizedOnly: prefs.getBool(_uncategorizedOnlyKey) ?? false,
        sortMode: _parseSortMode(prefs.getString(_sortModeKey)),
        direction: _parseDirection(prefs.getString(_sortDirectionKey)),
      ),
    );
  }

  Future<void> saveViewMode(BookLibraryViewMode value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewModeKey, value.name);
  }

  Future<void> saveQuery(BookLibraryQuery query) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortModeKey, query.sortMode.name);
    await prefs.setString(_sortDirectionKey, query.direction.name);
    if (query.categoryId == null) {
      await prefs.remove(_categoryIdKey);
    } else {
      await prefs.setInt(_categoryIdKey, query.categoryId!);
    }
    await prefs.setBool(_uncategorizedOnlyKey, query.uncategorizedOnly);
  }

  BookLibraryViewMode _parseViewMode(String? value) =>
      BookLibraryViewMode.values
          .where((item) => item.name == value)
          .firstOrNull ??
      BookLibraryViewMode.grid;

  BookLibrarySortMode _parseSortMode(String? value) =>
      BookLibrarySortMode.values
          .where((item) => item.name == value)
          .firstOrNull ??
      BookLibrarySortMode.recentCreated;

  BookLibrarySortDirection _parseDirection(String? value) =>
      BookLibrarySortDirection.values
          .where((item) => item.name == value)
          .firstOrNull ??
      BookLibrarySortDirection.descending;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
