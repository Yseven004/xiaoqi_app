import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_app_surface.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late ToolExecution execution;
  final tool = <String, dynamic>{
    'name': 'get-time',
    '_meta': {
      'ui': {'resourceUri': 'ui://get-time/mcp-app.html'},
    },
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mcp-app-surface-');
    store = CloudStore(root: directory.path);
    store.put('task/alice/task', {'status': 'running', 'artifacts': []}, null);
    execution = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'original',
    )..bind();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  Future<Map<String, dynamic>?> publish({
    String? uri,
    String? html,
    void Function()? check,
    void Function()? duringRead,
  }) => McpAppSurfaceStore(store, 'alice', 'task').publish(
    execution: execution,
    connectionId: 'server',
    connectionBinding: 'immutable-version',
    tool: tool,
    input: {},
    result: {
      'content': [
        {'type': 'text', 'text': 'time'},
      ],
      'structuredContent': {'time': 'value'},
    },
    selection: {},
    check: check ?? () {},
    readResource: (requested) async {
      duringRead?.call();
      return {
        'contents': [
          {
            'uri': uri ?? requested,
            'mimeType': McpAppMetadata.mime,
            'text': html ?? '<button>Refresh</button>',
          },
        ],
      };
    },
  );
  test(
    'app resource becomes an owned descriptor without exposing HTML to model',
    () async {
      final result = await publish();
      expect(result.toString(), isNot(contains('<button>')));
      final app = store.list('private_mcp_apps/alice/task/').single.$2.value;
      final surface = McpAppSurfaceStore(store, 'alice', 'task').load(
        app['id'] as String,
        check: (record) {
          expect(record['connection_binding'], 'immutable-version');
        },
      );
      expect(surface['html'], '<button>Refresh</button>');
      expect(store.get('task/alice/task')!.value['artifacts'], hasLength(1));
      await publish();
      expect(store.get('task/alice/task')!.value['artifacts'], hasLength(1));
    },
  );
  test(
    'cross-origin resource response cannot become a display surface',
    () async {
      await expectLater(
        publish(uri: 'ui://different/secret'),
        throwsFormatException,
      );
      expect(store.list('private_mcp_apps/alice/task/'), isEmpty);
    },
  );
  test('empty and oversized HTML fail before any artifact delivery', () async {
    await expectLater(publish(html: ''), throwsFormatException);
    await expectLater(
      publish(html: List.filled(2 * 1024 * 1024 + 1, 'x').join()),
      throwsFormatException,
    );
    expect(store.get('task/alice/task')!.value['artifacts'], isEmpty);
  });
  test(
    'revocation during resource read cannot publish returned content',
    () async {
      var enabled = true;
      await expectLater(
        publish(
          check: () {
            if (!enabled) throw StateError('withdrawn');
          },
          duringRead: () {
            enabled = false;
          },
        ),
        throwsStateError,
      );
      expect(store.list('private_mcp_apps/alice/task/'), isEmpty);
    },
  );
  test(
    'task scope changes and another tenant cannot reopen an old surface',
    () async {
      await publish();
      final id =
          store.list('private_mcp_apps/alice/task/').single.$2.value['id']
              as String;
      expect(
        () => McpAppSurfaceStore(store, 'bob', 'task').load(id, check: (_) {}),
        throwsStateError,
      );
      ToolExecution(
        store,
        'alice',
        'task',
        TurnContract(mode: 'answer', imageLimit: 0),
        requestIdentity: 'new-request',
      ).bind();
      expect(
        () =>
            McpAppSurfaceStore(store, 'alice', 'task').load(id, check: (_) {}),
        throwsStateError,
      );
    },
  );
  test(
    'app-only tools are never visible to model and web/file URIs are rejected',
    () {
      final onlyApp = {
        '_meta': {
          'ui': {
            'visibility': ['app'],
          },
        },
      };
      expect(McpAppMetadata.visible(onlyApp, 'model'), isFalse);
      expect(McpAppMetadata.visible(onlyApp, 'app'), isTrue);
      for (final uri in [
        'https://example.com/view',
        'file:///secret',
        'ui://user:password@server/view',
      ]) {
        expect(
          () => McpAppMetadata.resourceUri({
            '_meta': {
              'ui': {'resourceUri': uri},
            },
          }),
          throwsFormatException,
        );
      }
    },
  );
}
