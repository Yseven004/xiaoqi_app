/// The user's search conditions. A linked print ISBN is a catalog hint, not a
/// required identifier of a digital edition.
class BookSearchQuery {
  const BookSearchQuery({
    this.title = '',
    this.author = '',
    this.translator = '',
    this.isbn = '',
    this.language = '',
    this.format = '',
    this.edition = '',
    this.topic = '',
    this.referenceIsbn = '',
  });

  final String title;
  final String author;
  final String translator;
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
  static final _language = RegExp(
    r'[简簡][体體](?:中文|版)?|繁[体體](?:中文|版)?|[简簡繁]中|中文|英文|英语',
  );
  static final _numberedEdition = RegExp(
    r'第\s*([一二三四五六七八九十\d]+)\s*版(?:次)?|\b(\d+)(?:st|nd|rd|th)\s+edition\b',
    caseSensitive: false,
  );
  static final _version = RegExp(r'(?<![\d.])\d+\.\d+(?:\.\d+)?(?![\d.])');
  static const _variants =
      r'python|java(?:script)?|c\+\+|c#|dart|typescript|go|kotlin|ruby|rust|swift|pytorch|mxnet|c';
  static final _variantEdition = RegExp(
    '(?<![a-z0-9])($_variants)(?![a-z0-9+#])'
    r'\s*(?:语言版|代码(?:示例)?|版|示例|edition\b|examples?\b)',
    caseSensitive: false,
  );
  static final _usedVariant = RegExp(
    r'(?:我(?:主要|平时)?(?:在)?(?:写|用)|(?:想|我要)用)\s*'
    '($_variants)(?![a-z0-9+#])'
    '|做\\s*($_variants)\\s*(?:练习|練習)',
    caseSensitive: false,
  );
  static final _notRequired = RegExp(
    r'(?:不要|不想|不需要|不接受|不用|并非|不是|排除|除了|而非|最好|优先|without|except|prefer)\s*(?:用|要|找|看|下载|是)?\s*$',
    caseSensitive: false,
  );
  static final _formatSuffix = RegExp(
    r'^\s*(?:版|格式|文件|电子书|下载|就行|或|和|都可|都行|均可|/|、|of\b|or\b|and\b|$)',
    caseSensitive: false,
  );
  static final _acceptedRelease = RegExp('只接受\\s*[vV]?(${_version.pattern})');
  static final _numberedRelease = RegExp(
    '[vV]?(${_version.pattern})'
    r'\s*(?:版本|版|release\b)',
    caseSensitive: false,
  );

  /// Extract explicit qualifiers the model may omit when reformulating a search.
  /// Keep ambiguous alternatives out of the mandatory filters.
  factory BookSearchQuery.constraintsFromUserText(String text) {
    final outsideTitles = text.replaceAll(
      RegExp(r'《[^》]*》|〈[^〉]*〉|「[^」]*」|『[^』]*』'),
      ' ',
    );
    final clauses = outsideTitles.split(RegExp(r'[，,。！？!?；;\n]'));
    final formats = <String>{};
    final languages = <String>{};
    final numbered = <String>{};
    final variants = <String>{};
    final usedVariants = <String>{};
    for (final clause in clauses) {
      for (final match in _positiveMatches(_fileFormat, clause)) {
        if (_formatSuffix.hasMatch(clause.substring(match.end))) {
          formats.add(match.group(1)!.toLowerCase());
        }
      }
      for (final match in _positiveMatches(_language, clause)) {
        languages.add(_preferredLanguage(_languageId(match.group(0)!)));
      }
      for (final match in _positiveMatches(_numberedEdition, clause)) {
        numbered.add('第${_editionNumber(match)}版');
      }
      for (final match in _positiveMatches(_variantEdition, clause)) {
        variants.add(match.group(1)!.toLowerCase());
      }
      for (final match in _positiveMatches(_usedVariant, clause)) {
        usedVariants.add((match.group(1) ?? match.group(2)!).toLowerCase());
      }
    }
    // A bare numeric version following a quoted title refers to the book.
    // A runtime version elsewhere (for example Python 3.11) does not.
    final versions = <String>{
      for (final match in RegExp(
        '[》〉」』]\\s*[vV]?(${_version.pattern})',
      ).allMatches(text))
        match.group(1)!,
      for (final clause in clauses) ...[
        for (final match in _positiveMatches(_numberedRelease, clause))
          match.group(1)!,
        for (final match in _acceptedRelease.allMatches(clause))
          match.group(1)!,
      ],
    };
    final isbn = <String>{
      for (final match in RegExp(
        r'\bISBN(?:-1[03])?\s*[:：]?\s*([\dXx-]{10,17})\b',
        caseSensitive: false,
      ).allMatches(outsideTitles))
        if (_isbnShape.hasMatch(_isbn(match.group(1)!))) _isbn(match.group(1)!),
    };
    final directIsbn = _isbn(outsideTitles);
    if (_isbnShape.hasMatch(directIsbn)) isbn.add(directIsbn);
    return BookSearchQuery(
      isbn: _only(isbn),
      language: _only(languages),
      format: _only(formats),
      edition: [
        _only(variants.isEmpty ? usedVariants : variants),
        _only(numbered),
        _only(versions),
      ].where((value) => value.isNotEmpty).join(' '),
    );
  }

  static Iterable<RegExpMatch> _positiveMatches(
    RegExp pattern,
    String clause,
  ) => pattern
      .allMatches(clause)
      .where(
        (match) => !_notRequired.hasMatch(clause.substring(0, match.start)),
      );

  static String _only(Set<String> values) =>
      values.length == 1 ? values.single : '';

  static String _editionNumber(RegExpMatch match) {
    final ordinal = match.group(1) ?? match.group(2)!;
    const chinese = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
    final index = chinese.indexOf(ordinal);
    return index < 0 ? ordinal : '${index + 1}';
  }

  static String _languageId(String language) =>
      switch (language.trim().toLowerCase()) {
        '简体中文' ||
        '簡體中文' ||
        '简中' ||
        '簡中' ||
        '简体' ||
        '簡體' ||
        '简体版' ||
        '簡體版' ||
        'zh-cn' ||
        'zh-hans' => 'zh-hans',
        '繁体中文' ||
        '繁體中文' ||
        '繁中' ||
        '繁体' ||
        '繁體' ||
        '繁体版' ||
        '繁體版' ||
        'zh-tw' ||
        'zh-hant' => 'zh-hant',
        '中文' || '中文版' || 'zh' || 'chi' || 'zho' || 'chinese' => 'zh',
        '英文' || '英语' || 'en' || 'eng' || 'english' => 'en',
        final language => language,
      };

  static String _preferredLanguage(String id) => switch (id) {
    'zh-hans' => '简体中文',
    'zh-hant' => '繁體中文',
    'zh' => '中文',
    'en' => '英文',
    _ => id,
  };

  factory BookSearchQuery.fromStoredConstraints(Map row) => BookSearchQuery(
    isbn: row['isbn'] as String? ?? '',
    language: row['language'] as String? ?? '',
    format: row['format'] as String? ?? '',
    edition: row['edition'] as String? ?? '',
    author: row['author'] as String? ?? '',
    translator: row['translator'] as String? ?? '',
  );

  BookSearchQuery withRequiredMatch(BookSearchQuery requiredMatch) =>
      BookSearchQuery(
        title: title,
        author: requiredMatch.author.isEmpty ? author : requiredMatch.author,
        translator: requiredMatch.translator.isEmpty
            ? translator
            : requiredMatch.translator,
        isbn: requiredMatch.isbn.isEmpty ? isbn : requiredMatch.isbn,
        language: requiredMatch.language.isEmpty
            ? language
            : requiredMatch.language,
        format: requiredMatch.format.isEmpty ? format : requiredMatch.format,
        edition: requiredMatch.edition.isEmpty
            ? edition
            : requiredMatch.edition,
        topic: topic,
        referenceIsbn: requiredMatch.isbn.isEmpty ? referenceIsbn : '',
      );

  bool acceptsFile({
    required String title,
    required String edition,
    required String format,
    required String language,
    String? isbn,
    String? translator,
    bool checkEdition = true,
  }) {
    if (this.isbn.isNotEmpty && this.isbn != _isbn(isbn ?? '')) return false;
    if (this.translator.isNotEmpty && !matchesTranslator(translator))
      return false;
    if (this.format.isNotEmpty &&
        this.format.toLowerCase() != format.toLowerCase())
      return false;
    final requestedLanguage = _languageId(this.language);
    final actualLanguage = _languageId(language);
    if (requestedLanguage.isNotEmpty &&
        requestedLanguage != actualLanguage &&
        (requestedLanguage != 'zh' || !actualLanguage.startsWith('zh-'))) {
      return false;
    }
    if (!checkEdition || this.edition.isEmpty) return true;

    final expected = this.edition.toLowerCase();
    final actual = '$title · $edition'.toLowerCase();
    final ordinal = _numberedEdition.firstMatch(expected);
    if (ordinal != null &&
        !_numberedEdition
            .allMatches(actual)
            .any((match) => _editionNumber(match) == _editionNumber(ordinal))) {
      return false;
    }
    final release = _version.firstMatch(expected)?.group(0);
    if (release != null &&
        !_version.allMatches(edition).any((match) {
          final value = match.group(0)!;
          return value == release ||
              (release.split('.').length == 2 && value.startsWith('$release.'));
        })) {
      return false;
    }
    final qualifier = expected
        .replaceAll(_numberedEdition, '')
        .replaceAll(_version, '')
        .trim();
    if (qualifier.isEmpty) return true;
    final variant = RegExp(
      '^($_variants)(?:[ ]*版)?\$',
    ).firstMatch(qualifier)?.group(1);
    if (variant != null) {
      return edition.trim().toLowerCase() == variant ||
          _variantEdition
              .allMatches(actual)
              .any((match) => match.group(1) == variant);
    }
    return actual.contains(qualifier);
  }

  bool matchesTranslator(String? name) {
    if (translator.isEmpty) return true;
    return _matchesContributor(translator, name);
  }

  bool matchesAuthor(String? name) =>
      author.isEmpty || _matchesContributor(author, name);

  static bool _matchesContributor(String expected, String? actual) {
    String key(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
    return (actual ?? '')
        .split('、')
        .any((candidate) => key(candidate) == key(expected));
  }

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
        .replaceAll(RegExp(r'(?:电子|電子)(?:版|书|書)'), ' ')
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
    final translator = field('translator');
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
      translator: userText.toLowerCase().contains(translator.toLowerCase())
          ? translator
          : '',
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
    translator,
    isbn,
    topic,
    language,
    edition,
    format,
  ].where((s) => s.isNotEmpty).join(' ');
  Map<String, String> toJson() => {
    if (title.isNotEmpty) 'title': title,
    if (author.isNotEmpty) 'author': author,
    if (translator.isNotEmpty) 'translator': translator,
    if (isbn.isNotEmpty) 'isbn': isbn,
    if (topic.isNotEmpty) 'topic': topic,
    if (language.isNotEmpty) 'language': language,
    if (edition.isNotEmpty) 'edition': edition,
    if (format.isNotEmpty) 'format': format,
    if (referenceIsbn.isNotEmpty) 'referenceIsbn': referenceIsbn,
  };
}
