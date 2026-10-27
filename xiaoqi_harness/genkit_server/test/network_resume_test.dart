import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/network_resume.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;
  const hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const scope =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final request = <String, dynamic>{
    'model_id': 'fixture',
    'messages': [
      {'role': 'user', 'content': 'Read this public page'},
    ],
  };
  final pending = ToolRequestPart(
    toolRequest: ToolRequest(
      name: 'execute_python',
      ref: 'original-call',
      input: {
        'code': 'original approved code',
        'domains': ['example.com'],
      },
    ),
    metadata: {
      'interrupt': {
        'type': 'network_permission',
        'approval_hash': hash,
        'scope_hash': scope,
        'domains': ['example.com'],
        'purpose': 'Read public page',
      },
    },
  );
  final messages = [
    Message(
      role: Role.user,
      content: [TextPart(text: 'Read this public page')],
    ),
    Message(role: Role.model, content: [pending]),
  ];
  setUp(() {
    root = Directory.systemTemp.createTempSync('network-resume-');
    store = CloudStore(root: root.path);
    store.put('task/alice/task', {'status': 'running'}, null);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'reopened task resumes original SDK request only after exact approval',
    () {
      final resume = NetworkResume(store, 'alice', 'task');
      resume.save(request: request, messages: messages, pending: pending);
      expect(resume.load(request), isNull);
      final document = store.get('task/alice/task')!;
      store.put('task/alice/task', {
        ...document.value,
        'tool_authorizations': {hash: true},
      }, document.revision);
      store.close();
      store = CloudStore(root: root.path);
      final saved = NetworkResume(store, 'alice', 'task').load(request)!;
      expect(
        NetworkResume(store, 'alice', 'task').load({
          'messages': request['messages'],
          'model_id': request['model_id'],
        }),
        isNotNull,
      );
      expect(saved.restart.single.toolRequest.ref, 'original-call');
      expect(
        (saved.restart.single.toolRequest.input as Map)['code'],
        'original approved code',
      );
      expect(saved.restart.single.metadata?['resumed'], {
        'approved': true,
        'approval_hash': hash,
        'domains': ['example.com'],
      });
      expect(
        saved.messages.last.content.single.metadata?['interrupt'],
        pending.metadata?['interrupt'],
      );
      expect(resume.permission(pending).approvalHash, hash);
      expect(
        NetworkResume(store, 'alice', 'task').load({
          'messages': [
            {'role': 'user', 'content': 'Changed request'},
          ],
        }),
        isNull,
      );
      expect(NetworkResume(store, 'bob', 'task').load(request), isNull);
    },
  );

  test('snapshot cannot point into another account or another task', () {
    final resume = NetworkResume(store, 'alice', 'task');
    resume.save(request: request, messages: messages, pending: pending);
    final document = store.get('task/alice/task')!;
    final saved = Map<String, dynamic>.from(
      document.value['network_resume'] as Map,
    );
    store.put('task/alice/task', {
      ...document.value,
      'tool_authorizations': {hash: true},
      'network_resume': {
        ...saved,
        'object_key': 'tenants/bob/tasks/task/network-resume/$hash',
      },
    }, document.revision);
    expect(() => resume.load(request), throwsStateError);
  });

  test('a snapshot from a different release cannot restart effects', () {
    final resume = NetworkResume(store, 'alice', 'task');
    resume.save(request: request, messages: messages, pending: pending);
    final current = store.get('task/alice/task')!;
    store.put('task/alice/task', {
      ...current.value,
      'tool_authorizations': {hash: true},
      'network_resume': {
        ...(current.value['network_resume'] as Map),
        'release_id': 'old-release',
      },
    }, current.revision);
    expect(() => resume.load(request), throwsStateError);
  });
}
