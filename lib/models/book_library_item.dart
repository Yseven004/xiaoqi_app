import 'book_category.dart';
import 'book_recognition.dart';

class BookLibraryItem {
  const BookLibraryItem({
    required this.book,
    required this.noteCount,
    required this.recognizedPageCount,
    required this.activeDaysInLast30Days,
    required this.isPinned,
    required this.categories,
    this.isInReadingSpace = true,
    this.firstPage = '',
    this.lastPage = '',
    this.lastStudiedAt = '',
  });

  final BookRecord book;
  final int noteCount;
  final int recognizedPageCount;
  final int activeDaysInLast30Days;
  final bool isPinned;
  final bool isInReadingSpace;
  final List<BookCategory> categories;
  final String firstPage;
  final String lastPage;
  final String lastStudiedAt;
}
