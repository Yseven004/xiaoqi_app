enum BookLibraryViewMode { grid, learningList }

enum BookLibrarySortMode { recentCreated, recentStudy, studyFrequency }

enum BookLibrarySortDirection { descending, ascending }

class BookLibraryQuery {
  const BookLibraryQuery({
    this.searchText = '',
    this.categoryId,
    this.uncategorizedOnly = false,
    this.sortMode = BookLibrarySortMode.recentCreated,
    this.direction = BookLibrarySortDirection.descending,
  });

  final String searchText;
  final int? categoryId;
  final bool uncategorizedOnly;
  final BookLibrarySortMode sortMode;
  final BookLibrarySortDirection direction;

  BookLibraryQuery copyWith({
    String? searchText,
    int? categoryId,
    bool clearCategory = false,
    bool? uncategorizedOnly,
    BookLibrarySortMode? sortMode,
    BookLibrarySortDirection? direction,
  }) => BookLibraryQuery(
    searchText: searchText ?? this.searchText,
    categoryId: clearCategory ? null : categoryId ?? this.categoryId,
    uncategorizedOnly: clearCategory
        ? false
        : uncategorizedOnly ?? this.uncategorizedOnly,
    sortMode: sortMode ?? this.sortMode,
    direction: direction ?? this.direction,
  );
}
