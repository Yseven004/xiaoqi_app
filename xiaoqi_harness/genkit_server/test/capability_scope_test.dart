import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_scope.dart';

void main() {
  test('a new work cannot inherit another work capability', () {
    final resolved = resolveCapabilityScope(
      {
        'workflow_id': 'conversation-1',
        'work_id': 'new-work',
        'capability_scope_operation': 'inherit',
      },
      [
        {
          'workflow_id': 'conversation-1',
          'work_id': 'old-work',
          'capability_scope_schema': 2,
          'selected_capabilities': [
            {'id': 'old-skill'},
          ],
          'selected_mcp_connections': [
            {'id': 'old-mcp'},
          ],
        },
      ],
    );

    expect(resolved['selected_capabilities'], isEmpty);
    expect(resolved['selected_mcp_connections'], isEmpty);
    expect(resolved['capability'], isNull);
  });

  test('an unfinished legacy work may migrate its bound capability once', () {
    final resolved = resolveCapabilityScope(
      {
        'workflow_id': 'conversation-1',
        'work_id': 'migrated-work',
        'capability_scope_operation': 'inherit',
      },
      [
        {
          'workflow_id': 'conversation-1',
          'capability_scope_schema': 2,
          'selected_capabilities': [
            {'id': 'bound-skill'},
          ],
          'selected_mcp_connections': [],
          'capability': {'type': 'skill', 'id': 'bound-skill'},
        },
      ],
    );

    expect(resolved['selected_capabilities'], [
      {'id': 'bound-skill'},
    ]);
    expect(resolved['capability'], {'type': 'skill', 'id': 'bound-skill'});
  });

  test(
    'same-work inheritance skips another branch and keeps the nearest match',
    () {
      final resolved = resolveCapabilityScope(
        {
          'workflow_id': 'conversation-1',
          'work_id': 'work-1',
          'capability_scope_operation': 'inherit',
        },
        [
          {
            'workflow_id': 'conversation-1',
            'work_id': 'other-work',
            'capability_scope_schema': 2,
            'selected_capabilities': [
              {'id': 'other-skill'},
            ],
          },
          {
            'workflow_id': 'conversation-1',
            'work_id': 'work-1',
            'capability_scope_schema': 2,
            'selected_capabilities': [
              {'id': 'same-work-skill'},
            ],
            'selected_mcp_connections': [],
          },
        ],
      );

      expect(resolved['selected_capabilities'], [
        {'id': 'same-work-skill'},
      ]);
    },
  );
}
