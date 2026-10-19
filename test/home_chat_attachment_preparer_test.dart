import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/services/home_chat_attachment_preparer.dart';
import 'package:xiaoqi_app/services/home_chat_attachment_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': 'reader@example.com',
    });
    directory = await Directory.systemTemp.createTemp('attachment-preparer-');
  });
  tearDown(() => directory.delete(recursive: true));
  HomeChatAttachment attachment(
    File file, {
    String? name,
    String mimeType = 'text/plain',
    String id = 'local-1',
  }) => HomeChatAttachment(
    id: id,
    name: name ?? file.uri.pathSegments.last,
    path: file.path,
    mimeType: mimeType,
    byteLength: file.lengthSync(),
    source: 'file',
  );
  http.Response health() => http.Response(
    jsonEncode({
      'release_id': releaseId,
      'api_contract_version': apiContractVersion,
    }),
    200,
  );
  Map<String, Object?> ready() => {
    'id': 'remote-1',
    'status': 'ready',
    'phase': 'ready',
    'ready': true,
    'coverage': 'full',
    'page_count': 1,
    'completed_pages': [1],
    'selected_pages': [1],
  };
  test('eager preparation shares send and survives restart', () async {
    final file = await File('${directory.path}/中文.txt').writeAsString('通用附件内容');
    final source = attachment(file);
    var uploads = 0;
    final phases = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') return health();
        if (request.url.path == '/v1/attachments') {
          uploads++;
          expect(request.headers['X-Xiaoqi-Sha256']?.length, 64);
          return http.Response(
            '{"id":"remote-1","status":"uploaded","ready":false}',
            202,
          );
        }
        if (request.method == 'PUT') {
          final segments = jsonDecode(request.body)['segments'] as List;
          expect(segments.first['index'], 0);
          expect(segments.first['text'], contains('通用附件内容'));
        }
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
    final preparer = HomeChatAttachmentPreparer(cloud: cloud);
    preparer.states.addListener(() {
      phases.add(preparer.states.value[source.id]!.phase);
    });
    preparer.start(source);
    final results = await Future.wait([
      preparer.prepare(source),
      preparer.prepare(source),
    ]);
    expect(uploads, 1);
    expect(results.first.remoteAttachmentId, 'remote-1');
    expect(results.first.preparationCoverage, 'full');
    expect(results.first.contentHash?.length, 64);
    expect(
      phases,
      containsAll([
        'validating',
        'uploading',
        'extracting',
        'reading',
        'ready',
      ]),
    );
    preparer.cancel(source.id);
    expect((await preparer.prepare(source)).remoteAttachmentId, 'remote-1');
    preparer.dispose();
    final restored = HomeChatAttachmentPreparer(cloud: cloud);
    expect((await restored.prepare(source)).remoteAttachmentId, 'remote-1');
    expect(uploads, 1);
    restored.dispose();
  });
  test(
    'temporary HEIC upload image is removed after success or failure',
    () async {
      for (final failUpload in [false, true]) {
        final name = 'photo-$failUpload.heic';
        final file = await File(
          '${directory.path}/$name',
        ).writeAsBytes(image.encodePng(image.Image(width: 2, height: 2)));
        final source = attachment(file, name: name, mimeType: 'image/heic');
        final cloud = CapabilityCloudSync.forTesting(
          MockClient((request) async {
            if (request.url.path == '/health') return health();
            if (request.url.path == '/v1/attachments') {
              return failUpload
                  ? http.Response('upload failed', 500)
                  : http.Response(jsonEncode(ready()), 200);
            }
            return http.Response(jsonEncode(ready()), 200);
          }),
        );
        final preparer = HomeChatAttachmentPreparer(cloud: cloud);
        final preparation = preparer.prepare(source);
        if (failUpload) {
          await expectLater(preparation, throwsA(anything));
        } else {
          await preparation;
        }
        expect(await File('${file.path}.upload.jpg').exists(), isFalse);
        expect(await file.exists(), isTrue);
        preparer.dispose();
      }
    },
  );
  test('binary Office fails early with conversion message', () async {
    final file = await File(
      '${directory.path}/old.doc',
    ).writeAsString('legacy');
    var calls = 0;
    final preparer = HomeChatAttachmentPreparer(
      cloud: CapabilityCloudSync.forTesting(
        MockClient((request) async {
          calls++;
          return health();
        }),
      ),
    );
    await expectLater(
      preparer.prepare(attachment(file)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('.docx'),
        ),
      ),
    );
    expect(calls, 0);
    expect(preparer.states.value['local-1']!.retryable, false);
    preparer.dispose();
  });
  test('overview progress counts selected pages only', () async {
    final file = await File(
      '${directory.path}/sample.pdf',
    ).writeAsString('%PDF-1.4');
    final progress = <double?>[];
    final labels = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') return health();
        if (request.url.path == '/v1/attachments') {
          return http.Response(
            '{"id":"remote-1","status":"uploaded","ready":false}',
            202,
          );
        }
        if (request.method == 'POST') {
          expect(jsonDecode(request.body)['mode'], 'overview');
          return http.Response(
            jsonEncode({
              'id': 'remote-1',
              'status': 'processing',
              'phase': 'ocr',
              'ready': false,
              'completed_pages': [1, 2, 3, 4, 5],
              'selected_pages': [1, 5],
              'page_count': 5,
            }),
            200,
          );
        }
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
    final preparer = HomeChatAttachmentPreparer(cloud: cloud);
    preparer.states.addListener(() {
      final state = preparer.states.value['local-1'];
      if (state?.phase == 'ocr') {
        progress.add(state?.progress);
        labels.add(state!.label);
      }
    });
    await preparer.prepare(attachment(file));
    expect(progress, [1.0]);
    expect(labels, ['正在识别 2/2 页']);
    preparer.dispose();
  });
  test('retry resumes uploaded resource after parse failure', () async {
    final file = await File('${directory.path}/empty.txt').writeAsString('   ');
    var uploads = 0;
    var gets = 0;
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') return health();
        if (request.url.path == '/v1/attachments') uploads++;
        if (request.method == 'GET') gets++;
        return http.Response(
          '{"id":"remote-1","status":"uploaded","ready":false}',
          200,
        );
      }),
    );
    final source = attachment(file);
    final preparer = HomeChatAttachmentPreparer(cloud: cloud);
    await expectLater(preparer.prepare(source), throwsFormatException);
    expect(
      preparer.states.value[source.id]!.attachment!.remoteAttachmentId,
      'remote-1',
    );
    await expectLater(preparer.prepare(source), throwsFormatException);
    expect(uploads, 1);
    expect(gets, 1);
    preparer.dispose();
  });
  test('same ID different path invalidates prepared content', () async {
    final first = await File(
      '${directory.path}/first.txt',
    ).writeAsString('第一份');
    final second = await File(
      '${directory.path}/second.txt',
    ).writeAsString('第二份');
    var uploads = 0;
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') return health();
        if (request.url.path == '/v1/attachments') uploads++;
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
    final preparer = HomeChatAttachmentPreparer(cloud: cloud);
    final one = await preparer.prepare(attachment(first));
    final two = await preparer.prepare(attachment(second));
    expect(uploads, 2);
    expect(one.contentHash, isNot(two.contentHash));
    preparer.dispose();
  });
  test('PPTX XLSX preserve Chinese text on worker isolate', () async {
    for (final ext in ['pptx', 'xlsx']) {
      final archive = Archive();
      final parts = ext == 'pptx'
          ? {'ppt/slides/slide1.xml': '<slide><t>中文幻灯片</t></slide>'}
          : {
              'xl/sharedStrings.xml': '<sst><si><t>中文单元格</t></si></sst>',
              'xl/worksheets/sheet1.xml':
                  '<worksheet><row><c r="A1" t="s"><v>0</v></c></row></worksheet>',
            };
      for (final entry in parts.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final file = await File(
        '${directory.path}/中文.$ext',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final chunks = await HomeChatAttachmentReader().read(attachment(file));
      expect(chunks.join(), contains(ext == 'pptx' ? '中文幻灯片' : '中文单元格'));
    }
  });
  test('DOCX EPUB preserve Chinese body text on worker isolate', () async {
    final fixtures = <String, Map<String, String>>{
      'docx': {
        'word/document.xml':
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>中文 Word 正文</w:t></w:r></w:p></w:body></w:document>',
      },
      'epub': {
        'META-INF/container.xml':
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'OEBPS/content.opf':
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">synthetic-book</dc:identifier><dc:title>通用 EPUB 样本</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>',
        'OEBPS/chapter.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body><h1>第一章</h1><p>中文 EPUB 正文</p></body></html>',
      },
    };
    for (final fixture in fixtures.entries) {
      final archive = Archive();
      for (final entry in fixture.value.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final file = await File(
        '${directory.path}/通用样本.${fixture.key}',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final chunks = await HomeChatAttachmentReader().read(attachment(file));
      expect(
        chunks.join(),
        contains(fixture.key == 'docx' ? '中文 Word 正文' : '中文 EPUB 正文'),
      );
    }
  });
  test('old JSON loads and preparation metadata round trips', () {
    final old = HomeChatAttachment.fromJson({
      'id': 'old',
      'name': 'old.txt',
      'path': 'old.txt',
    });
    expect(old.remoteAttachmentId, isNull);
    final updated = old.copyWith(
      remoteAttachmentId: 'ref',
      contentHash: 'hash',
      preparationCoverage: 'partial',
      preparationPageCount: 20,
      preparationCompletedPages: 3,
      preparationExpiresAt: DateTime.utc(2026, 10, 19),
    );
    final restored = HomeChatAttachment.fromJson(updated.toJson());
    expect(restored.remoteAttachmentId, 'ref');
    expect(restored.preparationCompletedPages, 3);
    expect(restored.preparationCoverage, 'partial');
    expect(restored.preparationExpiresAt, DateTime.utc(2026, 10, 19));
  });
}
