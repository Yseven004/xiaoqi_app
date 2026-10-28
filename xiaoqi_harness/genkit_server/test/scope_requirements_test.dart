import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/scope_requirements.dart';
import 'package:xiaoqi_genkit_server/src/intent_router.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  test('only withdrawn current requirements stop blocking completion', () {
    final requirements = ScopeRequirements()
      ..add('parent', 'Plugin', selection: true)
      ..add(
        'failed',
        'Connector',
        parent: 'parent',
        failure: 'Needs an account',
      )
      ..add('other', 'Other connector', failure: 'Still missing');
    TurnContract scope(List<String> withdrawn) => TurnContract(
      mode: 'answer',
      imageLimit: 0,
      withdrawnRequirementIds: withdrawn,
    );
    expect(requirements.missing(scope([])), [
      'Needs an account',
      'Still missing',
    ]);
    expect(requirements.missing(scope(['failed'])), ['Still missing']);
    expect(requirements.missing(scope(['parent'])), ['Still missing']);
    expect(requirements.hasSelected(scope(['parent'])), isFalse);
    requirements.fail('failed', 'Different failure after retry');
    expect(requirements.missing(scope(['parent'])), ['Still missing']);
    expect(requirements.missing(scope([])), [
      'Different failure after retry',
      'Still missing',
    ]);
  });
  test('shared connectors remain required by an unwithdrawn parent', () {
    final requirements = ScopeRequirements()
      ..add('a', 'Plugin A')
      ..add('b', 'Plugin B')
      ..add(
        'shared',
        'Shared connector',
        parents: ['a', 'b'],
        failure: 'Missing',
      );
    expect(
      requirements.missing(
        TurnContract(
          mode: 'workflow',
          imageLimit: 0,
          withdrawnRequirementIds: ['a'],
        ),
      ),
      ['Missing'],
    );
    expect(
      requirements.missing(
        TurnContract(
          mode: 'workflow',
          imageLimit: 0,
          withdrawnRequirementIds: ['a', 'b'],
        ),
      ),
      isEmpty,
    );
  });
  test(
    'router only accepts listed requirement identities and persists the new scope',
    () async {
      final requirements = ScopeRequirements()
        ..add('known', 'Unavailable plugin', failure: 'Missing');
      final scope = await routeTurnIntent(
        text: '不用这个插件了，只用文字回答',
        skills: [],
        connections: [],
        artifacts: [],
        recentUserMessages: ['Use the plugin'],
        requirements: requirements.catalog,
        priorWithdrawnRequirementIds: ['known'],
        generate: (system, prompt) async {
          expect(system, contains('不能因为组件不可用'));
          final input = jsonDecode(prompt) as Map;
          expect(input['completion_requirements'], hasLength(1));
          expect(input['previous_withdrawn_requirement_ids'], ['known']);
          return jsonEncode({
            'mode': 'answer',
            'image_count': 0,
            'answer_required': true,
            'skill_ids': [],
            'connection_ids': [],
            'target_artifact_id': null,
            'clarification': null,
            'withdrawn_requirement_ids': ['known', 'invented'],
          });
        },
      );
      expect(scope.withdrawnRequirementIds, ['known']);
      expect(TurnContract.fromJson(scope.toJson()).withdrawnRequirementIds, [
        'known',
      ]);
      expect(scope.constrainedBy('纯文字', null).withdrawnRequirementIds, [
        'known',
      ]);
      expect(requirements.missing(scope), isEmpty);
    },
  );
}
