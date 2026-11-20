import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/services/home_chat_attachment_preparer.dart';

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
  Map<String, Object?> ready([String? format]) => {
    'id': 'remote-1',
    'status': 'ready',
    'phase': 'ready',
    'ready': true,
    'coverage': 'full',
    'page_count': 1,
    'completed_pages': [1],
    'selected_pages': [1],
    if (format != null) ...{
      'parser_profile': documentMarkItDownAttachmentProfile,
      'source_format': format,
    },
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
          expect(
            request.headers['X-Xiaoqi-Attachment-Profile'],
            documentMarkItDownAttachmentProfile,
          );
          expect(request.bodyBytes, utf8.encode('通用附件内容'));
          return http.Response(
            jsonEncode({
              ...ready('txt'),
              'status': 'queued',
              'phase': 'queued',
              'ready': false,
            }),
            202,
          );
        }
        expect(request.method, 'GET');
        return http.Response(jsonEncode(ready('txt')), 200);
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
    expect(phases, containsAll(['validating', 'uploading', 'queued', 'ready']));
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
              expect(request.headers['X-Xiaoqi-Attachment-Profile'], isNull);
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
          expect(
            request.headers['X-Xiaoqi-Attachment-Profile'],
            documentMarkItDownAttachmentProfile,
          );
          return http.Response(
            jsonEncode({...ready('pdf'), 'status': 'uploaded', 'ready': false}),
            202,
          );
        }
        if (request.method == 'POST') {
          expect(jsonDecode(request.body)['mode'], 'overview');
          return http.Response(
            jsonEncode({
              ...ready('pdf'),
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
        return http.Response(
          jsonEncode({...ready('pdf'), 'coverage': 'partial'}),
          200,
        );
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
    final prepared = await preparer.prepare(attachment(file));
    expect(prepared.preparationCoverage, 'partial');
    expect(progress, [1.0]);
    expect(labels, ['正在识别 2/2 页']);
    preparer.dispose();
  });
  test('retry resumes uploaded resource after parse failure', () async {
    final file = await File('${directory.path}/retry.txt').writeAsString('正文');
    var uploads = 0;
    var retries = 0;
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path == '/health') return health();
        if (request.url.path == '/v1/attachments') {
          uploads++;
          return http.Response(
            jsonEncode({...ready('txt'), 'status': 'queued', 'ready': false}),
            202,
          );
        }
        if (request.method == 'POST') {
          expect(request.url.path, endsWith('/read'));
          retries++;
          return http.Response(jsonEncode(ready('txt')), 200);
        }
        expect(request.method, 'GET');
        return http.Response(
          jsonEncode({
            ...ready('txt'),
            'status': 'failed',
            'ready': false,
            'error_code': 'extract_failed',
            'retryable': true,
          }),
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
    expect((await preparer.prepare(source)).preparationCoverage, 'full');
    expect(uploads, 1);
    expect(retries, 1);
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
        return http.Response(jsonEncode(ready('txt')), 200);
      }),
    );
    final preparer = HomeChatAttachmentPreparer(cloud: cloud);
    final one = await preparer.prepare(attachment(first));
    final two = await preparer.prepare(attachment(second));
    expect(uploads, 2);
    expect(one.contentHash, isNot(two.contentHash));
    preparer.dispose();
  });
  test(
    'ordinary documents upload original bytes and accept normalized formats',
    () async {
      final text = utf8.encode('中文内容');
      const archiveHeader = [0x50, 0x4b, 3, 4, 0x2b, 0x5a];
      for (final (extension, format, bytes) in [
        ('pptx', 'pptx', archiveHeader),
        ('xlsx', 'xlsx', archiveHeader),
        ('docx', 'docx', archiveHeader),
        ('epub', 'epub', archiveHeader),
        ('markdown', 'md', text),
        ('htm', 'html', text),
      ]) {
        final file = await File(
          '${directory.path}/样本.$extension',
        ).writeAsBytes(bytes);
        final preparer = HomeChatAttachmentPreparer(
          cloud: CapabilityCloudSync.forTesting(
            MockClient((request) async {
              if (request.url.path == '/health') return health();
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/attachments');
              expect(request.bodyBytes, bytes);
              expect(
                request.headers['X-Xiaoqi-Attachment-Profile'],
                documentMarkItDownAttachmentProfile,
              );
              return http.Response(jsonEncode(ready(format)), 200);
            }),
          ),
        );
        addTearDown(preparer.dispose);
        final result = await preparer.prepare(
          attachment(file, mimeType: 'application/octet-stream'),
        );
        expect(result.preparationCoverage, 'full');
      }
    },
  );
  test('does not advertise a partial ordinary document', () async {
    final file = await File(
      '${directory.path}/partial.txt',
    ).writeAsString('正文');
    final preparer = HomeChatAttachmentPreparer(
      cloud: CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          return http.Response(
            jsonEncode({...ready('txt'), 'coverage': 'partial'}),
            200,
          );
        }),
      ),
    );
    addTearDown(preparer.dispose);
    await expectLater(
      preparer.prepare(attachment(file)),
      throwsA(
        isA<AttachmentCloudException>().having(
          (error) => error.code,
          'code',
          'attachment_not_ready',
        ),
      ),
    );
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
