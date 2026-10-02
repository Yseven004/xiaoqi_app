class DateFormatter {
  DateFormatter._();

  static String formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) {
      return '刚刚';
    }
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}分钟前';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    }

    final sameYear = dateTime.year == now.year;
    if (sameYear) {
      return '${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    }
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
  }
}
