import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _ImageClient extends http.BaseClient {
  _ImageClient(this.apiResponse);
  final http.Response apiResponse;
  final List<int> downloadBytes = const [137, 80, 78, 71];
  int postCount = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') {
      postCount++;
      return http.StreamedResponse(
        Stream.value(utf8.encode(apiResponse.body)),
        apiResponse.statusCode,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(downloadBytes),
      200,
      headers: {'content-type': 'image/png'},
    );
  }
}

class _HangingClient extends http.BaseClient {
  int postCount = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    postCount++;
    return Completer<http.StreamedResponse>().future;
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-image-test-');
    store = CloudStore(root: directory.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'downloads generated image into task-private artifact storage',
    () async {
      store.put('task/personal/task-image', {
        'task_id': 'task-image',
        'status': 'running',
        'events': [],
        'artifacts': [],
      }, null);
      final client = _ImageClient(
        http.Response(
          jsonEncode({
            'data': [
              {'url': 'https://ark.example/image.png'},
            ],
          }),
          200,
        ),
      );
      final service = ImageService(store, client: client, apiKey: 'test-key');
      final result = await service.generate(
        taskId: 'task-image',
        prompt: 'a quiet lake',
      );
      expect(result['count'], 1);
      expect(client.postCount, 1);
      final task = store.get('task/personal/task-image')!.value;
      final artifact = (task['artifacts'] as List).single as Map;
      expect(store.getObject(artifact['object_key'] as String), [
        137,
        80,
        78,
        71,
      ]);
      expect((task['events'] as List).single['type'], 'artifacts_ready');
    },
  );

  test('retries bounded transient Ark errors but not policy errors', () async {
    final failing = _ImageClient(http.Response('busy', 429));
    final service = ImageService(
      store,
      client: failing,
      apiKey: 'test-key',
      retryBaseDelay: const Duration(milliseconds: 1),
    );
    await expectLater(
      service.generate(taskId: 't', prompt: 'x'),
      throwsA(isA<HttpException>()),
    );
    expect(failing.postCount, 3);

    final policy = _ImageClient(
      http.Response(
        jsonEncode({
          'error': {
            'code': 'InputTextSensitiveContentDetected.PolicyViolation',
            'message': 'input text may be related to copyright restrictions',
            'request_id': 'policy-request',
          },
        }),
        400,
      ),
    );
    final policyService = ImageService(
      store,
      client: policy,
      apiKey: 'test-key',
      retryBaseDelay: const Duration(milliseconds: 1),
    );
    await expectLater(
      policyService.generate(taskId: 't', prompt: 'x'),
      throwsA(
        isA<ImageProviderException>()
            .having(
              (error) => error.category,
              'category',
              'image_policy_blocked',
            )
            .having(
              (error) => error.providerCode,
              'provider code',
              contains('PolicyViolation'),
            )
            .having((error) => error.requestId, 'request id', 'policy-request'),
      ),
    );
    expect(policy.postCount, 1);

    final hanging = _HangingClient();
    final timeoutService = ImageService(
      store,
      client: hanging,
      apiKey: 'test-key',
      apiTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      timeoutService.generate(taskId: 't', prompt: 'x'),
      throwsA(isA<TimeoutException>()),
    );
    expect(hanging.postCount, 1);
  });

  test(
    'reuses a completed image attempt for the same idempotency key',
    () async {
      store.put('task/personal/idempotent-image', {
        'task_id': 'idempotent-image',
        'status': 'running',
        'events': [],
        'artifacts': [],
      }, null);
      final client = _ImageClient(
        http.Response(
          jsonEncode({
            'data': [
              {'url': 'https://ark.example/image.png'},
            ],
          }),
          200,
        ),
      );
      final service = ImageService(store, client: client, apiKey: 'test-key');
      final first = await service.generate(
        taskId: 'idempotent-image',
        prompt: 'a quiet lake',
        idempotencyKey: 'brief-hash',
      );
      final second = await service.generate(
        taskId: 'idempotent-image',
        prompt: 'a quiet lake',
        idempotencyKey: 'brief-hash',
      );

      expect(client.postCount, 1);
      expect(second, first);
    },
  );
}
