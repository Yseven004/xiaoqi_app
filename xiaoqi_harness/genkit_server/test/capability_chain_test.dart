import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_scope.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/mcp_tool_result.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_dependencies.dart';
import 'package:xiaoqi_genkit_server/src/public_agent_process.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/task_delivery.dart';

void main() {
  test(
    'remote MCP-only plugins are installable components, not fake skills',
    () {
      final candidates = CapabilityImportService.discover({
        '.claude-plugin/plugin.json': utf8.encode('{"name":"library"}'),
        '.mcp.json': utf8.encode(
          '{"mcpServers":{"library":{"url":"https://example.com/mcp"}}}',
        ),
      }, '');
      expect(candidates.single['status'], 'partial');
      expect((candidates.single['components'] as List).single['type'], 'mcp');
    },
  );
  test('MCP pagination is complete and rejects repeated cursors', () async {
    final tools = await listAllMcpTools(
      (cursor) async => cursor == null
          ? {
              'tools': [
                {'name': 'first'},
              ],
              'nextCursor': 'second',
            }
          : {
              'tools': [
                {'name': 'last'},
              ],
            },
    );
    expect(tools.map((tool) => tool['name']), ['first', 'last']);
    await expectLater(
      listAllMcpTools((cursor) async => {'tools': [], 'nextCursor': 'same'}),
      throwsStateError,
    );
  });
  final selection = {'id': 'notes', 'version_id': 'v1', 'type': 'plugin'};
  final previous = <String, dynamic>{
    'workflow_id': 'book-a',
    'capability_scope_schema': 2,
    'capability': selection,
    'selected_capabilities': [selection],
    'selected_mcp_connections': ['reader'],
  };

  test('old implicit activation cannot become a new user preference', () {
    final legacy = {...previous}..remove('capability_scope_schema');
    final resolved = resolveCapabilityScope(
      {'workflow_id': 'book-a'},
      [legacy],
    );
    expect(resolved['selected_capabilities'], isEmpty);
    expect(resolved['selected_mcp_connections'], isEmpty);
  });

  test('one-turn image action and runtime activation are never inherited', () {
    final resolved = resolveCapabilityScope(
      {'workflow_id': 'book-a'},
      [
        {
          ...previous,
          'capability': {'type': 'action', 'id': 'create-image'},
          'task_active_capabilities': [selection],
        },
      ],
    );
    expect(resolved['capability'], isNull);
    expect(resolved['task_active_capabilities'], isNull);
  });

  test(
    'ordinary followup inherits exact versions and connections only in its workflow',
    () {
      final inherited = resolveCapabilityScope(
        {
          'workflow_id': 'book-a',
          'selected_capabilities': [],
          'selected_mcp_connections': [],
        },
        [previous],
      );
      expect(inherited['selected_capabilities'], [selection]);
      expect(inherited['selected_mcp_connections'], ['reader']);
      final fresh = resolveCapabilityScope(
        {'workflow_id': 'book-b'},
        [previous],
      );
      expect(fresh['selected_capabilities'], isEmpty);
    },
  );

  test('explicit removal is retained and cannot be silently rediscovered', () {
    final cleared = resolveCapabilityScope(
      {'workflow_id': 'book-a', 'capability_scope_operation': 'clear'},
      [previous],
    );
    expect(cleared['selected_capabilities'], isEmpty);
    expect(
      cleared['excluded_capability_ids'],
      containsAll(['notes', 'reader']),
    );
    final followup = resolveCapabilityScope(
      {'workflow_id': 'book-a'},
      [cleared, previous],
    );
    expect(followup['selected_capabilities'], isEmpty);
    expect(followup['excluded_capability_ids'], contains('notes'));
  });

  late Directory root;
  late CloudStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('capability-chain-');
    store = CloudStore(root: root.path);
    store.put('task/alice/turn', {'artifacts': []}, null);
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  void install(String id, {bool enabled = true, bool manual = false}) {
    store.putImmutable('packages/$id', {
      'SKILL.md': utf8.encode(
        '---\nname: $id\ndescription: produce illustrated notes\n${manual ? 'disable-model-invocation: true\n' : ''}---\nUse real tools.',
      ),
    });
    store.put('cap/alice/$id', {
      'id': id,
      'kind': 'skill',
      'enabled': enabled,
      'name': id,
      'description': 'produce illustrated notes',
      'current_version_id': 'v1',
      'versions': [
        {'id': 'v1', 'artifact_key': 'packages/$id'},
      ],
    }, null);
  }

  test('discovery exposes enabled owned skills without a composer tag', () {
    install('notes');
    install('disabled', enabled: false);
    install('manual', manual: true);
    final catalog = SelectedSkills(store, 'alice', [], discover: true);
    expect(catalog.entries.values.map((e) => e['parent_id']), ['notes']);
    expect(catalog.explicitIds, isEmpty);
    expect(SelectedSkills(store, 'bob', [], discover: true).entries, isEmpty);
    expect(
      SelectedSkills(
        store,
        'alice',
        [],
        discover: true,
        excludedIds: ['notes'],
      ).entries,
      isEmpty,
    );
    expect(
      SelectedSkills(store, 'alice', [
        {'id': 'manual', 'version_id': 'v1'},
      ], discover: true).explicitIds,
      hasLength(1),
    );
  });

  test('plugin MCP declarations bind only the current account connection', () {
    store.putImmutable('packages/plugin', {
      '.mcp.json': utf8.encode(
        jsonEncode({
          'mcpServers': {
            'library': {'url': 'https://example.com/mcp'},
          },
        }),
      ),
    });
    store.put('cap/alice/notes', {
      'id': 'notes',
      'kind': 'plugin',
      'name': 'Notes',
      'versions': [
        {'id': 'v1', 'artifact_key': 'packages/plugin'},
      ],
    }, null);
    store.put('mcp/bob/other', {
      'id': 'other',
      'url': 'https://example.com/mcp',
    }, null);
    expect(
      PluginDependencies.resolve(store, 'alice', [selection]).connectionIds,
      isEmpty,
    );
    store.put('mcp/alice/own', {
      'id': 'own',
      'url': 'https://example.com/mcp',
    }, null);
    expect(
      PluginDependencies.resolve(store, 'alice', [selection]).connectionIds,
      {'own'},
    );
  });

  test(
    'MCP business error remains failed through public process projection',
    () {
      final normalized = McpToolResultAdapter(store, 'alice', 'turn').normalize(
        {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'permission denied'},
          ],
        },
      );
      expect(normalized['status'], 'failed');
      final process = PublicAgentProcess('turn');
      process.add({'type': 'tool_started', 'tool': 'mcp_test'});
      process.add({
        'type': normalized['status'] == 'completed'
            ? 'tool_succeeded'
            : 'tool_failed',
        'tool': 'mcp_test',
      });
      expect(process.rows.single['status'], 'failed');
      expect(store.get('task/alice/turn')!.value['artifacts'], isEmpty);
    },
  );

  test(
    'large MCP media and resources are complete, owned and deduplicated',
    () {
      final bytes = List<int>.generate(100000, (i) => i % 256);
      final adapter = McpToolResultAdapter(store, 'alice', 'turn');
      final result = {
        'content': [
          {
            'type': 'image',
            'mimeType': 'image/png',
            'data': base64Encode(bytes),
          },
          {
            'type': 'resource',
            'resource': {
              'uri': 'data://report',
              'mimeType': 'text/plain',
              'text': 'full report',
            },
          },
          {
            'type': 'resource_link',
            'uri': 'mcp://download',
            'name': 'download',
          },
        ],
        'structuredContent': {'complete': true},
      };
      final normalized = adapter.normalize(result);
      adapter.normalize(result);
      final artifacts =
          (store.get('task/alice/turn')!.value['artifacts'] as List)
              .cast<Map>();
      expect(artifacts, hasLength(2));
      expect(store.getObject(artifacts.first['object_key']), bytes);
      expect(
        artifacts.first['object_key'],
        startsWith('tenants/alice/tasks/turn/'),
      );
      expect(jsonEncode(normalized).length, lessThan(3000));
      expect((normalized['content'] as List).last['uri'], 'mcp://download');
    },
  );

  test(
    'delivery cannot complete without every requested tool and artifact',
    () {
      final delivery = TaskDelivery();
      expect(
        delivery.missing(planRequired: true, loadedSkills: [], artifacts: []),
        isNotEmpty,
      );
      delivery.declare({
        'skill_ids': ['notes'],
        'tools': [
          {'name': 'generate_image', 'count': 2},
        ],
        'artifacts': [
          {'media_type': 'image/*', 'count': 2},
        ],
      });
      delivery.observe({'type': 'tool_failed', 'tool': 'generate_image'});
      expect(
        delivery.missing(
          planRequired: true,
          loadedSkills: ['notes'],
          artifacts: [],
        ),
        hasLength(2),
      );
      delivery.observe({'type': 'tool_succeeded', 'tool': 'generate_image'});
      delivery.observe({'type': 'tool_succeeded', 'tool': 'generate_image'});
      expect(
        delivery.missing(
          planRequired: true,
          loadedSkills: ['notes'],
          artifacts: [
            {'media_type': 'image/png'},
            {'media_type': 'image/jpeg'},
          ],
        ),
        isEmpty,
      );
      expect(() => delivery.declare({}), throwsStateError);
      final restored = TaskDelivery(restored: delivery.toJson());
      expect(
        restored.missing(
          planRequired: true,
          loadedSkills: ['notes'],
          artifacts: [
            {'media_type': 'image/png'},
            {'media_type': 'image/jpeg'},
          ],
        ),
        isEmpty,
      );
    },
  );
}
