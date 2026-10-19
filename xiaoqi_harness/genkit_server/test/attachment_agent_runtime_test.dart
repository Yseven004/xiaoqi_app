import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/attachment_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

import 'support/attachment_runtime_fixture.dart' show RecordingAttachments;

void main() {
  test(
    'overview is bounded and explicit full reading is a separate intent',
    () {
      expect(agentAttachmentReadMode(''), 'overview');
      expect(agentAttachmentReadMode('帮我总结一下这份课件'), 'overview');
      expect(agentAttachmentReadMode('这个附件主要讲了什么？'), 'overview');
      expect(agentAttachmentReadMode('第二章的主要观点是什么？'), 'query');
      expect(agentAttachmentReadMode('如何理解文中光合作用的过程？'), 'query');
      expect(agentAttachmentReadMode('请逐页分析全文'), 'full');
      expect(agentAttachmentReadMode('Summarize the whole document'), 'full');
      expect(
        agentToolNamesForRequest(
          attachmentOverview: true,
          materialsAvailable: true,
          codeExecutionAvailable: true,
          webSearchAvailable: true,
          imageGenerationAvailable: true,
          skillsAvailable: true,
        ),
        isEmpty,
      );
    },
  );

  test('coverage never labels truncated or sampled text as full reading', () {
    expect(
      agentAttachmentCoverage({
        'name': '课件',
        'read_pages': [1, 8],
        'total_pages': 18,
      }),
      contains('尚未覆盖全文'),
    );
    expect(
      agentAttachmentCoverage({
        'name': '课件',
        'read_pages': [1],
        'total_pages': 1,
        'text_truncated': true,
      }),
      contains('部分文字'),
    );
    expect(
      agentAttachmentCoverage({
        'name': '课件',
        'read_pages': [1, 2],
        'total_pages': 2,
      }),
      contains('全部 2 页'),
    );
  });

  test(
    'reference reads bind tenant, request allowlist, query and page batches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'attachment-agent-test-',
      );
      final store = CloudStore(root: directory.path);
      final attachments = RecordingAttachments(store);
      final runtime = GenkitXiaoqiAgentRuntime(
        store,
        ImageService(store),
        attachments: attachments,
      );
      const materials = [
        {
          'id': 'local',
          'name': '课件',
          'attachment_id': 'resource',
          'tenant': 'forged',
        },
      ];
      try {
        final result = await runtime.readTaskMaterial(
          tenantId: 'personal',
          materials: materials,
          materialId: 'local',
          mode: 'query',
          query: '光合作用',
        );
        expect(result['text'], contains('光合作用'));
        expect(result['material_id'], 'local');
        expect(
          (result['segments'] as List).every(
            (part) => !(part as Map).containsKey('text'),
          ),
          isTrue,
        );
        expect(attachments.calls.single, containsPair('tenant', 'personal'));
        expect(attachments.calls.single, containsPair('id', 'resource'));
        expect(attachments.calls.single, containsPair('query', '光合作用'));
        await expectLater(
          runtime.readTaskMaterial(
            tenantId: 'personal',
            materials: materials,
            materialId: 'resource-from-another-turn',
          ),
          throwsFormatException,
        );
        expect(attachments.calls, hasLength(1));
        await expectLater(
          runtime.readTaskMaterial(
            tenantId: 'another-account',
            materials: materials,
            materialId: 'local',
          ),
          throwsA(isA<AttachmentFailure>()),
        );
        final fullBatch = await runtime.readTaskMaterial(
          tenantId: 'personal',
          materials: materials,
          materialId: 'local',
          mode: 'full',
        );
        expect(attachments.calls.last['mode'], 'pages');
        expect(attachments.calls.last['pages'], [1, 2, 3, 4, 5, 6, 7, 8]);
        expect(fullBatch['next_pages'], [9, 10, 11, 12, 13, 14, 15, 16]);
        await expectLater(
          runtime.readTaskMaterial(
            tenantId: 'personal',
            materials: materials,
            materialId: 'local',
            pages: List.generate(9, (index) => index + 1),
          ),
          throwsFormatException,
        );
      } finally {
        await attachments.close();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'legacy extracted text supports bounded reads without starting attachment service',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'attachment-agent-legacy-test-',
      );
      final store = CloudStore(root: directory.path);
      final runtime = GenkitXiaoqiAgentRuntime(store, ImageService(store));
      try {
        final content = List.filled(3000, '中').join();
        final result = await runtime.readTaskMaterial(
          tenantId: 'personal',
          materials: [
            {'id': 'local', 'text': content},
          ],
          materialId: 'local',
          maxChars: 1000,
        );
        expect((result['text'] as String).length, 1000);
        expect(result['next_offset'], 1000);
        expect(result['text_truncated'], isTrue);
        final next = await runtime.readTaskMaterial(
          tenantId: 'personal',
          materials: [
            {'id': 'local', 'text': content},
          ],
          materialId: 'local',
          offset: 1000,
          maxChars: 2000,
        );
        expect(next['next_offset'], isNull);
        expect(next['source_text_truncated'], isFalse);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final scenario in ['overview', 'image', 'full']) {
    test(
      '$scenario streams real attachment content without unrelated tools',
      () async {
        final requests = <Map<String, dynamic>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          requests.add(body);
          if (body['stream'] == true) {
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            request.response.write(
              'data: ${jsonEncode({
                'id': 'test',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': '这份资料介绍光合作用。'},
                    'finish_reason': null,
                  },
                ],
              })}\n\n',
            );
            request.response.write(
              'data: ${jsonEncode({
                'id': 'test',
                'choices': [
                  {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
                ],
              })}\n\ndata: [DONE]\n\n',
            );
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'id': 'test',
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'content': '光合作用的结构及证据（已读页码）。',
                    },
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
          }
          await request.response.close();
        });
        try {
          final result = await Process.run(
            Platform.resolvedExecutable,
            [
              '--disable-dart-dev',
              '--packages=.dart_tool/package_config.json',
              'test/support/attachment_runtime_fixture.dart',
              scenario,
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
            environment: {
              'MIMO_API_KEY': 'test-local-key',
              'MIMO_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
              'XIAOQI_CAPTURE_TRACES': '0',
            },
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final line = result.stdout
              .toString()
              .split('\n')
              .firstWhere((line) => line.startsWith('RUNTIME_RESULT:'));
          final output =
              jsonDecode(line.substring('RUNTIME_RESULT:'.length)) as Map;
          expect(requests, hasLength(scenario == 'full' ? 4 : 1));
          for (final request in requests) {
            expect(request['tools'] ?? const [], isEmpty);
          }
          expect(output['text'], contains('光合作用'));
          expect(
            output['text'],
            contains(
              scenario == 'full'
                  ? '全部 18 页'
                  : scenario == 'image'
                  ? '已查看图片'
                  : '尚未覆盖全文',
            ),
          );
          expect(
            (output['events'] as List).first,
            containsPair('type', 'reading_material'),
          );
          expect(
            (output['events'] as List).last,
            containsPair('type', 'answer_started'),
          );
          if (scenario == 'overview') {
            expect(
              (output['events'] as List).last['model_first_token_ms'],
              isA<num>(),
            );
          }
          if (scenario == 'image') {
            expect(
              jsonEncode(requests.single['messages']),
              contains('data:image/png;base64,'),
            );
          }
          if (scenario == 'full') {
            final calls = (output['calls'] as List).cast<Map>();
            expect(calls.map((call) => call['mode']), [
              'overview',
              'pages',
              'pages',
              'pages',
            ]);
            expect(calls.last['pages'], [17, 18]);
          }
        } finally {
          await server.close(force: true);
          await serving.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
