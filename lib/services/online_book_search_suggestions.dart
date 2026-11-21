import '../models/book_library_query.dart';
import '../models/book_recognition.dart';
import 'book_library_service.dart';

const _generalSuggestions = [
  '帮我找《Hello 算法》中文版',
  '找一本适合零基础的 Python 入门书',
  '找《Pro Git》的中文 EPUB 版',
];

List<String> initialOnlineBookSearchSuggestions({String? bookTitle}) {
  final title = _normalizedTitle(bookTitle);
  return title.isEmpty ? _generalSuggestions : _forBook(title);
}

Future<List<String>> loadOnlineBookSearchSuggestions({
  BookRecord? linkedBook,
  String? bookTitle,
  BookLibraryService? library,
}) async {
  final linkedTitle = _normalizedTitle(linkedBook?.title ?? bookTitle);
  if (linkedTitle.isNotEmpty) {
    return _forBook(linkedTitle, author: linkedBook?.authors.firstOrNull ?? '');
  }

  final bookLibrary = library ?? BookLibraryService();
  try {
    final entries = await bookLibrary.listBooks(
      query: const BookLibraryQuery(sortMode: BookLibrarySortMode.recentStudy),
    );
    final now = DateTime.now();
    BookRecord? preferred;
    var highestScore = 0;
    for (final entry in entries) {
      if (_normalizedTitle(entry.book.title).isEmpty) continue;
      final lastRead = DateTime.tryParse(entry.lastStudiedAt);
      final recency = lastRead == null
          ? 0
          : (30 - now.difference(lastRead).inDays).clamp(0, 30).toInt();
      final score = recency + entry.activeDaysInLast30Days;
      if (score > highestScore) {
        highestScore = score;
        preferred = entry.book;
      }
    }

    if (preferred == null) return _generalSuggestions;
    final author = preferred.authors.isEmpty
        ? ''
        : preferred.authors.first.trim();
    return _forBook(_normalizedTitle(preferred.title), author: author);
  } on Exception {
    return _generalSuggestions;
  }
}

List<String> _forBook(String title, {String author = ''}) => [
  title.contains('中文版') ? '帮我找《$title》' : '帮我找《$title》中文版',
  '找《$title》的 EPUB 版',
  author.isEmpty ? '找和《$title》类似的书' : '找《$title》的作者写的其他书',
];

String _normalizedTitle(String? value) {
  final title = value?.trim() ?? '';
  if (title.startsWith('《') && title.endsWith('》')) {
    return title.substring(1, title.length - 1).trim();
  }
  return title;
}
