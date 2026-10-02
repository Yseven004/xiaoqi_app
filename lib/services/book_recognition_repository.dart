import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/book_recognition.dart';
import '../models/captured_page.dart';

abstract interface class BookRecognitionRepository {
  Future<BookRecognitionResult> recognize({
    required String batchId,
    required List<CapturedPage> pages,
    String? recognizedText,
  });

  Future<List<BookCandidate>> search(String query);

  Future<List<BookCandidate>> lookupIsbn(String isbn);

  Future<BookRecord> saveCustom(BookRecord book);
}

enum MockBookRecognitionScenario {
  highConfidence,
  history,
  lowConfidence,
  missing,
  failure,
  timeout,
}

class MockBookRecognitionRepository implements BookRecognitionRepository {
  MockBookRecognitionRepository({
    this.scenario = MockBookRecognitionScenario.highConfidence,
    this.delay = const Duration(milliseconds: 420),
  });

  final MockBookRecognitionScenario scenario;
  final Duration delay;

  static const _candidates = <BookCandidate>[
    BookCandidate(
      book: BookRecord(
        title: '思考，快与慢',
        authors: ['丹尼尔·卡尼曼'],
        publisher: '中信出版社',
        edition: '2012年版',
        publishedDate: '2012',
        isbn13: '9787508633558',
        source: 'mock_google_books',
        sourceId: 'thinking-fast-slow-2012',
      ),
      confidence: BookMatchConfidence.high,
      matchLabel: '最可能',
      score: .93,
    ),
    BookCandidate(
      book: BookRecord(
        title: '思考，快与慢',
        authors: ['丹尼尔·卡尼曼'],
        publisher: '中信出版集团',
        edition: '2018年版',
        publishedDate: '2018',
        isbn13: '9787508694672',
        source: 'mock_google_books',
        sourceId: 'thinking-fast-slow-2018',
      ),
      confidence: BookMatchConfidence.medium,
      matchLabel: '相似版本',
      score: .72,
    ),
    BookCandidate(
      book: BookRecord(
        title: 'Thinking, Fast and Slow',
        authors: ['Daniel Kahneman'],
        publisher: 'Farrar, Straus and Giroux',
        edition: '2011 English edition',
        publishedDate: '2011',
        isbn13: '9780374275631',
        source: 'mock_open_library',
        sourceId: 'thinking-fast-slow-en',
      ),
      confidence: BookMatchConfidence.low,
      matchLabel: '英文原版',
      score: .45,
    ),
  ];

  @override
  Future<BookRecognitionResult> recognize({
    required String batchId,
    required List<CapturedPage> pages,
    String? recognizedText,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    switch (scenario) {
      case MockBookRecognitionScenario.failure:
        throw const BookRecognitionException('书籍资料识别失败，可稍后重试或自定义书籍');
      case MockBookRecognitionScenario.timeout:
        throw const BookRecognitionException('书籍资料识别超时，可直接继续或手动选择');
      case MockBookRecognitionScenario.missing:
        return BookRecognitionResult(
          batchId: batchId,
          candidates: const [
            BookCandidate(
              book: BookRecord(
                title: '待确认书籍',
                source: 'generated',
                sourceId: 'generated-pending',
              ),
              confidence: BookMatchConfidence.unknown,
              matchLabel: '系统生成 · 请核对',
            ),
          ],
        );
      case MockBookRecognitionScenario.lowConfidence:
        return BookRecognitionResult(
          batchId: batchId,
          candidates: [_candidates[1], _candidates[0], _candidates[2]],
        );
      case MockBookRecognitionScenario.history:
        final first = _candidates.first;
        return BookRecognitionResult(
          batchId: batchId,
          candidates: [
            BookCandidate(
              book: first.book,
              confidence: BookMatchConfidence.high,
              matchLabel: '来自历史书籍',
              score: .98,
              fromHistory: true,
            ),
            ..._candidates.skip(1),
          ],
        );
      case MockBookRecognitionScenario.highConfidence:
        return BookRecognitionResult(batchId: batchId, candidates: _candidates);
    }
  }

  @override
  Future<List<BookCandidate>> search(String query) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(
        Duration(milliseconds: delay.inMilliseconds ~/ 2),
      );
    }
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return _candidates;
    return _candidates
        .where((candidate) {
          final book = candidate.book;
          return book.title.toLowerCase().contains(normalized) ||
              book.authorLabel.toLowerCase().contains(normalized) ||
              book.isbn10.contains(normalized) ||
              book.isbn13.contains(normalized);
        })
        .toList(growable: false);
  }

  @override
  Future<List<BookCandidate>> lookupIsbn(String isbn) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(
        Duration(milliseconds: delay.inMilliseconds ~/ 2),
      );
    }
    final exact = _candidates
        .where((candidate) => candidate.book.isbn13 == isbn)
        .toList(growable: false);
    if (exact.isNotEmpty) {
      return [
        for (final candidate in exact)
          BookCandidate(
            book: candidate.book,
            confidence: BookMatchConfidence.high,
            matchLabel: '书码精确匹配',
            score: 1,
          ),
      ];
    }
    return [
      BookCandidate(
        book: BookRecord(
          title: '待确认书籍',
          isbn13: isbn,
          source: 'isbn_unresolved',
          sourceId: 'isbn-$isbn',
        ),
        confidence: BookMatchConfidence.unknown,
        matchLabel: '已扫到书码 · 请补充书名',
      ),
    ];
  }

  @override
  Future<BookRecord> saveCustom(BookRecord book) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(
        Duration(milliseconds: delay.inMilliseconds ~/ 2),
      );
    }
    return book.copyWith(isCustom: true, source: 'custom');
  }
}

class CloudBookRecognitionRepository implements BookRecognitionRepository {
  CloudBookRecognitionRepository({
    String? recognitionEndpoint,
    String? searchEndpoint,
    String? isbnEndpoint,
    String? customEndpoint,
    String? appSecret,
    http.Client? httpClient,
    Duration? timeout,
  }) : recognitionEndpoint =
           recognitionEndpoint ?? ApiConfig.bookRecognitionEndpoint,
       searchEndpoint = searchEndpoint ?? ApiConfig.bookSearchEndpoint,
       isbnEndpoint = isbnEndpoint ?? ApiConfig.bookIsbnEndpoint,
       customEndpoint = customEndpoint ?? ApiConfig.bookCustomEndpoint,
       appSecret = appSecret ?? ApiConfig.appSecret,
       httpClient = httpClient ?? http.Client(),
       timeout = timeout ?? const Duration(seconds: 45);

  final String recognitionEndpoint;
  final String searchEndpoint;
  final String isbnEndpoint;
  final String customEndpoint;
  final String appSecret;
  final http.Client httpClient;
  final Duration timeout;

  @override
  Future<BookRecognitionResult> recognize({
    required String batchId,
    required List<CapturedPage> pages,
    String? recognizedText,
  }) async {
    final uri = Uri.parse(recognitionEndpoint);
    final request = http.MultipartRequest('POST', uri)
      ..headers['X-App-Secret'] = appSecret
      ..fields['batch_id'] = batchId
      ..fields['page_count'] = pages.length.toString();

    final text = recognizedText?.trim() ?? '';
    if (text.isNotEmpty) {
      request.fields['text'] = text;
    }

    // Reuse the OCR output already produced by the note pipeline. Uploading the
    // same images here would make the server run OCR twice and frequently exceed
    // the mobile request timeout.
    for (var index = 0; text.isEmpty && index < pages.length; index++) {
      final page = pages[index];
      request.fields['pages[$index][order]'] = (page.captureSequence ?? index)
          .toString();
      request.fields['pages[$index][is_double_page]'] = page.isDoublePage
          ? '1'
          : '0';
      request.fields['pages[$index][group_index]'] =
          (page.pageGroupIndex ?? index).toString();
      final file = File(page.path);
      if (await file.exists() && await file.length() > 0) {
        request.files.add(
          await http.MultipartFile.fromPath('images', file.path),
        );
      }
    }

    final streamed = await httpClient.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    final decoded = _decodeResponse(response);
    return _resultFromJson(decoded, fallbackBatchId: batchId);
  }

  @override
  Future<List<BookCandidate>> search(String query) async {
    final uri = Uri.parse(
      searchEndpoint,
    ).replace(queryParameters: {'q': query.trim()});
    final response = await httpClient
        .get(uri, headers: {'X-App-Secret': appSecret})
        .timeout(timeout);
    final decoded = _decodeResponse(response);
    final rawCandidates = decoded['candidates'];
    if (rawCandidates is List) {
      return rawCandidates
          .whereType<Map>()
          .map((item) => _candidateFromJson(item.cast<String, dynamic>()))
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<List<BookCandidate>> lookupIsbn(String isbn) async {
    final uri = Uri.parse(
      isbnEndpoint,
    ).replace(queryParameters: {'isbn': isbn.trim()});
    final response = await httpClient
        .get(uri, headers: {'X-App-Secret': appSecret})
        .timeout(timeout);
    final decoded = _decodeResponse(response);
    final rawCandidates = decoded['candidates'];
    if (rawCandidates is! List) return const [];
    return rawCandidates
        .whereType<Map>()
        .map((item) => _candidateFromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  Future<BookRecord> saveCustom(BookRecord book) async {
    final response = await httpClient
        .post(
          Uri.parse(customEndpoint),
          headers: {
            'Content-Type': 'application/json',
            'X-App-Secret': appSecret,
          },
          body: jsonEncode({'book': _bookToJson(book)}),
        )
        .timeout(timeout);
    final decoded = _decodeResponse(response);
    final rawBook = decoded['book'];
    if (rawBook is Map) {
      return _bookFromJson(
        rawBook.cast<String, dynamic>(),
      ).copyWith(isCustom: true, source: 'custom');
    }
    return book.copyWith(isCustom: true, source: 'custom');
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final body = response.bodyBytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = '书籍识别服务暂时不可用';
      if (body is Map) {
        message = (body['error'] ?? body['message'] ?? message).toString();
      }
      throw BookRecognitionException(message);
    }
    if (body is! Map<String, dynamic>) {
      throw const BookRecognitionException('书籍识别返回格式异常');
    }
    if (body['success'] == false) {
      throw BookRecognitionException(
        (body['error'] ?? body['message'] ?? '书籍识别失败').toString(),
      );
    }
    final data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  BookRecognitionResult _resultFromJson(
    Map<String, dynamic> json, {
    required String fallbackBatchId,
  }) {
    final rawCandidates = json['candidates'];
    final candidates = rawCandidates is List
        ? rawCandidates
              .whereType<Map>()
              .map((item) => _candidateFromJson(item.cast<String, dynamic>()))
              .toList(growable: false)
        : <BookCandidate>[];
    return BookRecognitionResult(
      batchId: (json['batch_id'] ?? json['batchId'] ?? fallbackBatchId)
          .toString(),
      candidates: candidates,
      selectedIndex: _intValue(json['selected_index'] ?? json['selectedIndex']),
    );
  }

  BookCandidate _candidateFromJson(Map<String, dynamic> json) {
    final rawBook = json['book'];
    final book = rawBook is Map
        ? _bookFromJson(rawBook.cast<String, dynamic>())
        : _bookFromJson(json);
    return BookCandidate(
      book: book,
      confidence: _confidenceFromJson(json['confidence']),
      matchLabel: (json['match_label'] ?? json['matchLabel'] ?? '').toString(),
      score: _doubleValue(json['score']),
      fromHistory: json['from_history'] == true || json['fromHistory'] == true,
    );
  }

  BookRecord _bookFromJson(Map<String, dynamic> json) {
    final rawAuthors = json['authors'];
    final authors = rawAuthors is List
        ? rawAuthors.map((value) => value.toString()).toList(growable: false)
        : (json['author'] ?? json['author_label'] ?? json['authorLabel'] ?? '')
              .toString()
              .split(RegExp(r'[,，、]'))
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: false);
    return BookRecord(
      title: (json['title'] ?? '').toString(),
      authors: authors,
      publisher: (json['publisher'] ?? '').toString(),
      edition: (json['edition'] ?? '').toString(),
      publishedDate: (json['published_date'] ?? json['publishedDate'] ?? '')
          .toString(),
      isbn10: (json['isbn_10'] ?? json['isbn10'] ?? '').toString(),
      isbn13: (json['isbn_13'] ?? json['isbn13'] ?? '').toString(),
      coverUrl: (json['cover_url'] ?? json['coverUrl'] ?? '').toString(),
      source: (json['source'] ?? 'cloud').toString(),
      sourceId: (json['source_id'] ?? json['sourceId'] ?? '').toString(),
      isCustom: json['is_custom'] == true || json['isCustom'] == true,
    );
  }

  Map<String, dynamic> _bookToJson(BookRecord book) => {
    'title': book.title,
    'authors': book.authors,
    'publisher': book.publisher,
    'edition': book.edition,
    'published_date': book.publishedDate,
    'isbn_10': book.isbn10,
    'isbn_13': book.isbn13,
    'cover_url': book.coverUrl,
    'source': book.source,
    'source_id': book.sourceId,
    'is_custom': book.isCustom,
  };

  BookMatchConfidence _confidenceFromJson(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'high':
        return BookMatchConfidence.high;
      case 'medium':
        return BookMatchConfidence.medium;
      case 'low':
        return BookMatchConfidence.low;
      default:
        return BookMatchConfidence.unknown;
    }
  }

  int _intValue(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;

  double _doubleValue(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;
}

class BookRecognitionException implements Exception {
  const BookRecognitionException(this.message);

  final String message;

  @override
  String toString() => message;
}
