import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/reading_task_materials.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late File sourceFile;
  const epubBytes = [0x50, 0x4b, 3, 4, 0x2b, 0x5a];

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('reading-materials-');
    sourceFile = await File(
      '${scratch.path}/book.epub',
    ).writeAsBytes(epubBytes);
    _useAccount('a');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test(
    'sends the original EPUB and reuses only the matching conversion',
    () async {
      final library = _Library(_source(sourceFile));
      final cloud = _AttachmentCloud();
      final service = ReadingTaskMaterials(cloud: cloud.client);
      addTearDown(service.dispose);

      final first = await service.prepare(library: library, bookId: 1);
      expect(first.issues, isEmpty);
      expect(first.materials.single, containsPair('name', '测试资料.md'));
      expect(first.materials.single, containsPair('attachment_id', 'book-1'));
      expect(cloud.uploaded, [epubBytes]);
      expect(cloud.uploadMimes, ['application/epub+zip']);
      expect(cloud.requests, [
        'POST /v1/attachments',
        'GET /v1/attachments/book-1',
      ]);

      final reopened = ReadingTaskMaterials(cloud: cloud.client);
      addTearDown(reopened.dispose);
      final repeat = await reopened.prepare(library: library, bookId: 1);
      expect(repeat.materials, first.materials);
      expect(cloud.uploaded, [epubBytes]);
      expect(cloud.requests.last, 'GET /v1/attachments/book-1');

      final editedBytes = [...epubBytes, 10];
      await sourceFile.writeAsBytes(editedBytes);
      library.source = _source(sourceFile, revision: 'reimported');
      final changed = await reopened.prepare(library: library, bookId: 1);
      expect(changed.issues, isEmpty);
      expect(changed.materials.single['attachment_id'], 'book-2');
      expect(cloud.uploaded, [epubBytes, editedBytes]);
    },
  );

  test('an account change after upload prevents polling or reuse', () async {
    final cloud = _AttachmentCloud(onUpload: () => _useAccount('b'));
    final service = ReadingTaskMaterials(cloud: cloud.client);
    addTearDown(service.dispose);
    final library = _Library(_source(sourceFile));

    await expectLater(
      service.prepare(library: library, bookId: 1),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('账号已变更'),
        ),
      ),
    );
    expect(cloud.authorizations, ['Bearer token-a']);
    expect(cloud.requests, ['POST /v1/attachments']);
  });

  test(
    'only prepares the selected source and never falls back if it disappears',
    () async {
      final selectedBytes = [...epubBytes, 0x32];
      final selectedFile = await File(
        '${scratch.path}/chosen.epub',
      ).writeAsBytes(selectedBytes);
      final library = _Library(_source(sourceFile), [
        _source(selectedFile, id: 2, name: '选中的原书'),
      ]);
      final cloud = _AttachmentCloud();
      final service = ReadingTaskMaterials(cloud: cloud.client);
      addTearDown(service.dispose);

      final selected = await service.prepare(
        library: library,
        bookId: 1,
        sourceId: 2,
      );
      expect(selected.issues, isEmpty);
      expect(selected.materials.single['name'], '选中的原书.md');
      expect(cloud.uploaded, [selectedBytes]);

      final missing = await service.prepare(
        library: library,
        bookId: 1,
        sourceId: 99,
      );
      expect(missing.materials, isEmpty);
      expect(missing.issues.single.message, contains('资料已移除'));
      expect(cloud.uploaded, [selectedBytes]);
    },
  );

  test(
    'retryable conversion requeues its existing uploaded resource',
    () async {
      final cloud = _AttachmentCloud(failConversion: true);
      final service = ReadingTaskMaterials(cloud: cloud.client);
      addTearDown(service.dispose);
      final library = _Library(_source(sourceFile));

      final failed = await service.prepare(library: library, bookId: 1);
      expect(failed.materials, isEmpty);
      expect(failed.issues, hasLength(1));

      final retried = await service.prepare(library: library, bookId: 1);
      expect(retried.issues, isEmpty);
      expect(retried.materials.single['attachment_id'], 'book-1');
      expect(cloud.uploaded, [epubBytes]);
      expect(cloud.requests, contains('POST /v1/attachments/book-1/read'));
    },
  );

  test('rejects a ready snapshot produced by a different converter', () async {
    final cloud = _AttachmentCloud(mismatchedProfile: true);
    final service = ReadingTaskMaterials(cloud: cloud.client);
    addTearDown(service.dispose);

    final result = await service.prepare(
      library: _Library(_source(sourceFile)),
      bookId: 1,
    );
    expect(result.materials, isEmpty);
    expect(result.issues.single.message, contains('Markdown 转换'));
  });

  test('PDF keeps converted text but reports pages without text', () async {
    final pdf = await File(
      '${scratch.path}/book.pdf',
    ).writeAsString('%PDF-1.7');
    final cloud = _AttachmentCloud(skippedPdfPages: 2);
    final service = ReadingTaskMaterials(cloud: cloud.client);
    addTearDown(service.dispose);

    final result = await service.prepare(
      library: _Library(_source(pdf, format: 'pdf')),
      bookId: 1,
    );
    expect(result.materials.single['attachment_id'], 'book-1');
    expect(result.issues.single.message, contains('2 页'));
    expect(cloud.uploadMimes, ['application/pdf']);
    expect(cloud.uploaded.single, utf8.encode('%PDF-1.7'));
  });

  test('scanned books without text never become task materials', () async {
    final pdf = await File(
      '${scratch.path}/scanned.pdf',
    ).writeAsString('%PDF-1.7');
    final cloud = _AttachmentCloud(noReadableText: true);
    final service = ReadingTaskMaterials(cloud: cloud.client);
    addTearDown(service.dispose);

    final result = await service.prepare(
      library: _Library(_source(pdf, format: 'pdf')),
      bookId: 1,
    );
    expect(result.materials, isEmpty);
    expect(result.issues.single.message, '没有可提取的文字');
    expect(cloud.requests, [
      'POST /v1/attachments',
      'GET /v1/attachments/book-1',
    ]);
  });
}

void _useAccount(String id) {
  FlutterSecureStorage.setMockInitialValues({
    'xiaoqi.capabilities.device_token.v1': 'token-$id',
    'xiaoqi.auth.method.v1': 'email',
    'xiaoqi.auth.email.v1': 'reader-$id@example.com',
  });
}

BookSourceRecord _source(
  File file, {
  int id = 1,
  String name = '测试资料',
  String format = 'epub',
  String revision = 'initial',
}) => BookSourceRecord(
  id: id,
  bookId: 1,
  kind: 'book_file',
  displayName: '$name.$format',
  filePath: file.path,
  fileSize: file.lengthSync(),
  contentHash: 'fixture-$revision',
  status: 'ready',
  format: format,
  createdAt: 'initial',
  updatedAt: revision,
);

class _Library implements BookLibraryService {
  _Library(this.source, [this.additionalSources = const []]);

  BookSourceRecord source;
  final List<BookSourceRecord> additionalSources;

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [
    for (final candidate in [source, ...additionalSources])
      if (candidate.bookId == bookId) candidate,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AttachmentCloud {
  _AttachmentCloud({
    this.onUpload,
    this.failConversion = false,
    this.mismatchedProfile = false,
    this.noReadableText = false,
    this.skippedPdfPages = 0,
  });

  final void Function()? onUpload;
  bool failConversion;
  final bool mismatchedProfile;
  final bool noReadableText;
  final int skippedPdfPages;
  final uploaded = <List<int>>[];
  final uploadMimes = <String?>[];
  final requests = <String>[];
  final authorizations = <String?>[];
  final _formats = <String, String>{};
  late final client = CapabilityCloudSync.forTesting(MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    final route = request.url.path;
    if (route == '/health') {
      return _json({
        'release_id': releaseId,
        'api_contract_version': apiContractVersion,
      });
    }
    requests.add('${request.method} $route');
    authorizations.add(request.headers['Authorization']);
    if (route == '/v1/attachments') {
      expect(request.method, 'POST');
      expect(
        request.headers['X-Xiaoqi-Attachment-Profile'],
        readingBookMarkItDownAttachmentProfile,
      );
      uploaded.add(request.bodyBytes);
      uploadMimes.add(request.headers['Content-Type']);
      final id = 'book-${uploaded.length}';
      _formats[id] = request.headers['Content-Type'] == 'application/pdf'
          ? 'pdf'
          : 'epub';
      onUpload?.call();
      return _snapshot(id, mismatchedProfile ? 'ready' : 'queued');
    }
    expect(route, startsWith('/v1/attachments/'));
    final id = request.url.pathSegments[2];
    if (request.method == 'POST' && route.endsWith('/read')) {
      failConversion = false;
      return _snapshot(id, 'queued');
    }
    expect(request.method, 'GET');
    return _snapshot(id, failConversion || noReadableText ? 'failed' : 'ready');
  }

  http.Response _snapshot(String id, String status) => _json({
    'id': id,
    'status': status,
    'phase': status,
    'ready': status == 'ready',
    'coverage': status == 'ready' ? 'full' : 'partial',
    'parser_profile': mismatchedProfile
        ? 'generic'
        : readingBookMarkItDownAttachmentProfile,
    'source_format': _formats[id],
    if (status == 'ready') 'skipped_pdf_pages': skippedPdfPages,
    if (status == 'failed') ...{
      'error_code': noReadableText ? 'no_readable_text' : 'parse_failed',
      'retryable': !noReadableText,
    },
  });

  http.Response _json(Map<String, Object?> body) =>
      http.Response(jsonEncode(body), 200);
}
