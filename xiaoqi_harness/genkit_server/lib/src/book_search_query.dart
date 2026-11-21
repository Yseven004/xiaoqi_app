/// The user's search conditions. A linked print ISBN is a catalog hint, not a
/// required identifier of a digital edition.
class BookSearchQuery {
  const BookSearchQuery({
    this.title = '',
    this.author = '',
    this.isbn = '',
    this.language = '',
    this.format = '',
    this.edition = '',
    this.topic = '',
    this.referenceIsbn = '',
  });

  final String title;
  final String author;
  final String isbn;
  final String language;
  final String format;
  final String edition;
  final String topic;
  final String referenceIsbn;

  static String _cleanTitle(String value) =>
      value.trim().replaceAll(RegExp(r'^[《〈「『]|[》〉」』]$'), '').trim();

  static String _isbn(String value) =>
      value.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  static final _isbnShape = RegExp(r'^(?:97[89]\d{10}|\d{9}[\dX])$');
  static final _fileFormat = RegExp(
    r'(?<![a-zA-Z])(pdf|epub)(?![a-zA-Z])',
    caseSensitive: false,
  );

  factory BookSearchQuery.fromText(String text) {
    final raw = text.trim();
    final isbn = _isbn(
      raw.replaceFirst(RegExp(r'^ISBN\s*[:：]?\s*', caseSensitive: false), ''),
    );
    if (_isbnShape.hasMatch(isbn)) return BookSearchQuery(isbn: isbn);
    final by = RegExp(
      r'^(?:作者|author)\s*[:：]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (by != null) return BookSearchQuery(author: by.group(1)!.trim());

    // Only parse trailing edition qualifiers outside a quoted book title.
    final quoted = RegExp(r'^[《〈「『](.+?)[》〉」』](.*)$').firstMatch(raw);
    var title = quoted == null ? raw : quoted.group(1)!;
    var qualifiers = quoted?.group(2)?.trim() ?? '';
    if (quoted == null) {
      final suffix = RegExp(
        r'(?:\s+|(?<=[\u3400-\u9fff]))((?:简体中文|繁体中文|繁體中文|中文|英文)版?|pdf|epub|python|java|pytorch|mxnet|\d+\.\d+(?:\.\d+)?|第[一二三四五六七八九\d]+版|纸质书)(?=\s|$)',
        caseSensitive: false,
      ).firstMatch(title);
      if (suffix != null) {
        qualifiers = title.substring(suffix.start).trim();
        title = title.substring(0, suffix.start).trim();
      }
    }
    final language = RegExp(r'(简体中文|繁体中文|繁體中文|中文|英文)版?').firstMatch(qualifiers);
    final format = _fileFormat.firstMatch(qualifiers);
    final edition = qualifiers
        .replaceAll(_fileFormat, ' ')
        .replaceFirst(language?.group(0) ?? '', '')
        .trim();
    return BookSearchQuery(
      title: _cleanTitle(title),
      language: language?.group(1) ?? '',
      format: format?.group(1)?.toLowerCase() ?? '',
      edition: edition,
    );
  }

  factory BookSearchQuery.fromTool(
    Map<String, dynamic> input, {
    required String userText,
    Map<String, String> linkedBook = const {},
  }) {
    String field(String key) =>
        input[key] is String ? (input[key] as String).trim() : '';
    final title = _cleanTitle(field('title'));
    final topic = field('topic');
    final author = field('author');
    // A translated or abbreviated shelf attribution can differ from the
    // spelling used in the source. Only explicit author criteria filter a title.
    final authorRequested =
        title.isEmpty ||
        (author.isNotEmpty &&
            userText.toLowerCase().contains(author.toLowerCase()));
    final normalizedUserText = _isbn(userText);
    final isbn = _isbn(field('isbn'));
    final explicitIsbn =
        _isbnShape.hasMatch(isbn) && normalizedUserText.contains(isbn)
        ? isbn
        : '';
    final sameTitle =
        title.isNotEmpty &&
        topic.isEmpty &&
        title.toLowerCase() ==
            _cleanTitle(linkedBook['title'] ?? '').toLowerCase() &&
        (!authorRequested ||
            author.isEmpty ||
            linkedBook['author'] == null ||
            linkedBook['author'] == author);
    final linkedIsbn = sameTitle ? _isbn(linkedBook['isbn'] ?? '') : '';

    final requestedFormat = field('format').toLowerCase();
    // Some providers omit the explicitly requested PDF/EPUB. Don't infer a
    // preference from a book title, a comparison, or an exclusion.
    final outsideTitle = userText.replaceAll(RegExp(r'《[^》]*》'), ' ');
    final mentions = _fileFormat.allMatches(outsideTitle).toList();
    final formatMentions = mentions
        .map((match) => match.group(1)!.toLowerCase())
        .toSet();
    final singleFormat =
        formatMentions.length == 1 &&
        RegExp(
          r'^\s*(?:版|格式|文件|电子书|下载|[。！？?!，,;；]|$)',
        ).hasMatch(outsideTitle.substring(mentions.last.end)) &&
        !RegExp(
          r'不要|不想|除了|排除|不用|并非|不是|而非|without|except',
          caseSensitive: false,
        ).hasMatch(outsideTitle);
    final format = singleFormat ? formatMentions.single : requestedFormat;
    final requestedLanguage = field('language');
    final generalChinese =
        outsideTitle.contains('中文') &&
        (requestedLanguage.isEmpty ||
            RegExp(
              r'中文|[简簡繁][体體]|^zh',
              caseSensitive: false,
            ).hasMatch(requestedLanguage)) &&
        !RegExp(r'简[体體]|簡[体體]|繁[体體]').hasMatch(outsideTitle);
    return BookSearchQuery(
      title: title,
      topic: topic,
      isbn: explicitIsbn,
      author: authorRequested ? author : '',
      language: generalChinese ? '中文' : requestedLanguage,
      format: format,
      edition: field('edition'),
      referenceIsbn: _isbnShape.hasMatch(linkedIsbn) && explicitIsbn.isEmpty
          ? linkedIsbn
          : '',
    );
  }

  bool get hasIdentity => [title, author, isbn, topic].any((s) => s.isNotEmpty);
  String get displayText => [
    title,
    author,
    isbn,
    topic,
    language,
    edition,
    format,
  ].where((s) => s.isNotEmpty).join(' ');
  Map<String, String> toJson() => {
    if (title.isNotEmpty) 'title': title,
    if (author.isNotEmpty) 'author': author,
    if (isbn.isNotEmpty) 'isbn': isbn,
    if (topic.isNotEmpty) 'topic': topic,
    if (language.isNotEmpty) 'language': language,
    if (edition.isNotEmpty) 'edition': edition,
    if (format.isNotEmpty) 'format': format,
    if (referenceIsbn.isNotEmpty) 'referenceIsbn': referenceIsbn,
  };
}
