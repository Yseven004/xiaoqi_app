import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/public_agent_transport.dart';

void main() {
  final message = {
    'role': 'model',
    'metadata': {'debug': 'private-debug'},
    'custom': {'debug': 'private-custom'},
    'content': [
      {'reasoning': 'private-reasoning'},
      {
        'toolRequest': {
          'name': 'execute_python',
          'input': {'code': 'private-code'},
        },
      },
      {
        'toolRequest': {'name': 'tool', 'input': 'private-false-interrupt'},
        'metadata': {'interrupt': false},
      },
      {
        'toolResponse': {'name': 'execute_python', 'output': 'private-output'},
      },
      {'text': '公开回答。'},
      {
        'data': {
          'a2ui': {
            'content': ['保留交互数据'],
          },
        },
      },
    ],
  };

  test(
    'snapshot projection hides internal context and preserves explicit approvals',
    () {
      final payload = publicAgentPayload({
        'messages': [
          {
            'role': 'system',
            'content': [
              {'text': 'private-system'},
            ],
          },
          {
            'role': 'tool',
            'content': [
              {'text': 'private-tool'},
            ],
          },
          message,
          {
            'role': 'model',
            'content': [
              {
                'toolRequest': {
                  'name': 'permission',
                  'ref': 'approval',
                  'input': {
                    'domains': ['example.com'],
                  },
                },
                'metadata': {'interrupt': true},
              },
            ],
          },
        ],
      });
      final encoded = jsonEncode(payload);
      expect(encoded, isNot(contains('private-')));
      expect(encoded, contains('公开回答'));
      expect(encoded, contains('example.com'));
      expect(encoded, contains('保留交互数据'));
    },
  );

  test(
    'JSON and arbitrarily split UTF8 SSE share the snapshot policy',
    () async {
      final frame =
          'data: ${jsonEncode({
            'result': {'message': message},
          })}\n\n';
      final bytes = utf8.encode(frame);
      final streamed = await publicAgentResponse(
        Response.ok(
          Stream.fromIterable([
            for (final byte in bytes) [byte],
          ]),
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final text = await streamed.readAsString();
      expect(text, startsWith('data: '));
      expect(text, endsWith('\n\n'));
      expect(text, isNot(contains('private-')));
      final response = await publicAgentResponse(
        Response.ok(
          jsonEncode({
            'result': {'message': message},
          }),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(
        jsonDecode(text.substring(6).trim()),
        jsonDecode(await response.readAsString()),
      );
    },
  );
}
