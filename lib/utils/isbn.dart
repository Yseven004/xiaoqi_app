/// Helpers for validating the numbers printed below a book barcode.
///
/// The scanner only treats valid ISBN-10/ISBN-13 values as books. Ordinary
/// EAN-13 product barcodes are deliberately rejected so a price sticker or
/// stationery barcode cannot silently link the wrong book.
abstract final class Isbn {
  static String compact(String value) =>
      value.replaceAll(RegExp(r'[^0-9Xx]'), '').toUpperCase();

  static bool isValid10(String value) {
    final isbn = compact(value);
    if (!RegExp(r'^\d{9}[\dX]$').hasMatch(isbn)) return false;
    var sum = 0;
    for (var index = 0; index < 10; index++) {
      final digit = isbn[index] == 'X' ? 10 : int.parse(isbn[index]);
      sum += (10 - index) * digit;
    }
    return sum % 11 == 0;
  }

  static bool isValid13(String value) {
    final isbn = compact(value);
    if (!RegExp(r'^\d{13}$').hasMatch(isbn)) return false;
    if (!isbn.startsWith('978') && !isbn.startsWith('979')) return false;
    var sum = 0;
    for (var index = 0; index < 12; index++) {
      sum += int.parse(isbn[index]) * (index.isEven ? 1 : 3);
    }
    final checkDigit = (10 - (sum % 10)) % 10;
    return checkDigit == int.parse(isbn[12]);
  }

  /// Returns one canonical ISBN-13, or `null` for a non-book/invalid barcode.
  static String? normalize(String value) {
    final isbn = compact(value);
    if (isValid13(isbn)) return isbn;
    if (!isValid10(isbn)) return null;

    final firstTwelve = '978${isbn.substring(0, 9)}';
    var sum = 0;
    for (var index = 0; index < firstTwelve.length; index++) {
      sum += int.parse(firstTwelve[index]) * (index.isEven ? 1 : 3);
    }
    return '$firstTwelve${(10 - (sum % 10)) % 10}';
  }

  /// Gives an actionable correction for manual entry instead of treating a
  /// checksum typo as an unexplained incomplete ISBN.
  static String explainInvalid(String value) {
    final isbn = compact(value);
    if (RegExp(r'^97[89]\d{10}$').hasMatch(isbn)) {
      var sum = 0;
      for (var index = 0; index < 12; index++) {
        sum += int.parse(isbn[index]) * (index.isEven ? 1 : 3);
      }
      final expected = (10 - (sum % 10)) % 10;
      return 'ISBN 校验位不正确：最后一位可能应为 $expected';
    }
    if (RegExp(r'^\d{9}[\dX]$').hasMatch(isbn)) {
      return 'ISBN-10 校验不正确，请检查最后一位';
    }
    return '请输入完整的 ISBN-10 或 ISBN-13';
  }
}
