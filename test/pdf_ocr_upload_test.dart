import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File pdf;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
    });
    directory = await Directory.systemTemp.createTemp(
      'attachment-upload-test-',
    );
    pdf = await File('${directory.path}/任意文件.pdf').writeAsString('%PDF-1.4');
  });
  tearDown(() => directory.delete(recursive: true));
  http.Response health() => http.Response(
    jsonEncode({
      'release_id': releaseId,
      'api_contract_version': apiContractVersion,
    }),
    200,
  );
  Map<String, Object?> ready() => {
    'id': 'resource-1',
    'status': 'ready',
    'phase': 'ready',
    'ready': true,
    'page_count': 3,
    'coverage': 'full',
    'completed_pages': [1, 2, 3],
    'segments': [
      {'index': 0, 'page': 1, 'text': 'page 1'},
      {'index': 2, 'page': 3, 'text': 'page 3'},
    ],
  };
  test('PDF uses resource contract and retains results on success', () async {
    final requests = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path == '/health') return health();
        expect(request.headers['authorization'], 'Bearer test-token');
        expect(request.headers['X-Xiaoqi-Contract'], apiContractVersion);
        if (request.url.path == '/v1/attachments') {
          expect(request.body, '%PDF-1.4');
          expect(request.headers['content-type'], 'application/pdf');
          expect(
            Uri.decodeComponent(request.headers['X-Xiaoqi-Filename']!),
            '任意文件.pdf',
          );
          return http.Response('{"id":"resource-1","status":"uploaded"}', 202);
        }
        expect(jsonDecode(request.body)['mode'], 'full');
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
    expect(await cloud.recognizePdf(pdf.path), ['page 1', '', 'page 3']);
    expect(requests, [
      'GET /health',
      'POST /v1/attachments',
      'POST /v1/attachments/resource-1/read',
    ]);
  });
  test('one timed out poll retries without deleting pages', () async {
    var polls = 0;
    final requests = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        requests.add(request.method);
        if (request.url.path == '/health') return health();
        if (++polls == 1) throw TimeoutException('temporary connection stall');
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
    final result = await cloud.waitForAttachment(
      'resource-1',
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
    );
    expect(result['ready'], true);
    expect(polls, 2);
    expect(requests, everyElement('GET'));
  });
  test('parse failure retains resource and actionable error', () async {
    final requests = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        requests.add(request.method);
        if (request.url.path == '/health') return health();
        return http.Response(
          '{"id":"resource-1","status":"failed","error_code":"encrypted_pdf","message":"PDF 已加密","retryable":false}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await expectLater(
      cloud.waitForAttachment('resource-1'),
      throwsA(
        isA<AttachmentCloudException>()
            .having((error) => error.code, 'code', 'encrypted_pdf')
            .having((error) => error.retryable, 'retryable', false),
      ),
    );
    expect(requests, everyElement('GET'));
  });
  test('plain HTTP error preserves status', () async {
    final cloud = CapabilityCloudSync.forTesting(
      MockClient(
        (request) async => request.url.path == '/health'
            ? health()
            : http.Response('Not Found', 404),
      ),
    );
    await expectLater(
      cloud.createAttachment(
        path: pdf.path,
        name: 'a.pdf',
        mimeType: 'application/pdf',
      ),
      throwsA(
        isA<AttachmentCloudException>()
            .having((error) => error.message, 'message', contains('HTTP 404'))
            .having((error) => error.retryable, 'retryable', false),
      ),
    );
  });
  test('contract mismatch blocks upload and reports both versions', () async {
    final requests = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(
          '{"release_id":"old","api_contract_version":"old"}',
          200,
        );
      }),
    );
    await expectLater(
      cloud.createAttachment(
        path: pdf.path,
        name: 'a.pdf',
        mimeType: 'application/pdf',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('不匹配'), contains(apiContractVersion), contains('old')),
        ),
      ),
    );
    expect(requests, ['/health']);
  });
  test('explicit stop issues cancellation once', () async {
    var cancelled = false;
    final requests = <String>[];
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((request) async {
        requests.add(request.method);
        if (request.url.path == '/health') return health();
        if (request.method == 'POST') {
          cancelled = true;
          return http.Response('{"id":"resource-1","status":"uploaded"}', 202);
        }
        expect(request.method, 'DELETE');
        return http.Response('{"id":"resource-1","status":"cancelled"}', 200);
      }),
    );
    await expectLater(
      cloud.recognizePdf(pdf.path, isCancelled: () => cancelled),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('已停止'),
        ),
      ),
    );
    expect(requests, ['GET', 'POST', 'DELETE']);
  });
}
