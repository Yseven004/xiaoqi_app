import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': 'owner@example.com',
    }),
  );
  http.Response health() => http.Response(
    jsonEncode({
      'release_id': releaseId,
      'api_contract_version': apiContractVersion,
    }),
    200,
  );

  test(
    'upload API sends one source and retains the existing job contract',
    () async {
      final bytes = utf8.encode('---\nname: example\n---\nRead input');
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          expect(request.headers['X-Xiaoqi-Contract'], apiContractVersion);
          if (request.url.path.endsWith('/capabilities/imports')) {
            final body = jsonDecode(request.body);
            expect(body, {
              'file_name': 'SKILL.md',
              'archive_base64': base64Encode(bytes),
            });
            return http.Response('{"id":"uploaded","status":"running"}', 202);
          }
          expect(
            request.url.path,
            endsWith('/capabilities/import-jobs/uploaded'),
          );
          return http.Response(
            '{"status":"completed","inspection":{"id":"checked","source_type":"upload"}}',
            200,
          );
        }),
      );
      String? job;
      final result = await cloud.inspectCapabilityUpload(
        fileName: 'SKILL.md',
        bytes: bytes,
        onJob: (id) => job = id,
      );
      expect(job, 'uploaded');
      expect(result['inspection']['source_type'], 'upload');
    },
  );

  test(
    'draft MCP test has its own non-saving endpoint and matching release',
    () async {
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          expect(request.url.path, endsWith('/mcp/connection-tests'));
          expect(request.headers['X-Xiaoqi-Release'], releaseId);
          expect(jsonDecode(request.body), {
            'name': 'Draft',
            'url': 'https://example.com/mcp',
            'bearer_token': 'temporary',
          });
          return http.Response(
            '{"saved":false,"tool_count":1,"tools":[]}',
            200,
          );
        }),
      );
      final result = await cloud.testMcpConnectionDraft(
        name: 'Draft',
        url: 'https://example.com/mcp',
        bearerToken: 'temporary',
      );
      expect(result['saved'], isFalse);
    },
  );

  test('uploaded installations retain their server management boundary', () {
    final record = CapabilityRecord.fromJson({
      'id': 'upload-a',
      'kind': 'plugin',
      'origin': 'upload',
      'name': 'Reader',
      'source': {'file_name': 'reader.zip', 'content_sha256': 'content'},
      'current_version_id': 'version',
      'cloud_revision': 3,
    });
    final restored = CapabilityRecord.fromJson(
      record.copyWith(showInMenu: false).toJson(),
    );
    expect(restored.isServerInstallation, isTrue);
    expect(restored.origin, 'upload');
    expect(restored.source, record.source);
    expect(restored.cloudRevision, 3);
  });
}
