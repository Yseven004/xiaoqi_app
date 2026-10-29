import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> verifyLegacySourceMode(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  const id = 'legacy-source-launch';
  final package = 'gate-packages/$id';
  final source = <String, List<int>>{
    'SKILL.md': utf8.encode(
      '---\nname: legacy-source-launch\ndescription: Launch a legacy task source script\n---\nRun scripts/legacy.\n',
    ),
    'scripts/legacy': utf8.encode(
      '#!/bin/sh\nset -eu\nprintf \'%s\' "\$1" > /workspace/output/legacy.txt\n',
    ),
  };
  store.putImmutable(package, source);
  final original = sha256.convert(store.getObject(package)).toString();
  store.put('cap/$tenant/$id', {
    'id': id,
    'kind': 'skill',
    'name': id,
    'description': 'Legacy source fixture',
    'enabled': true,
    'current_version_id': 'v1',
    'versions': [
      {'id': 'v1', 'artifact_key': package},
    ],
  }, null);
  final selected = SelectedSkills(store, tenant, [
    {'id': id, 'version_id': 'v1'},
  ]);
  final files = selected.files(selected.entries.values.single);
  if (files.containsKey('.xiaoqi-source-executables.json'))
    throw StateError(
      'Legacy fixture unexpectedly contains source mode records',
    );
  store.put('task/$tenant/$id', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  const literal = r'literal; $(not-a-host-command) ../not-a-path';
  await executor.execute(
    tenantId: tenant,
    taskId: id,
    language: 'shell',
    code: r'exec /workspace/skill/scripts/legacy "$@"',
    arguments: [literal],
    authorizedDomains: [],
    materials: [],
    skillFiles: files,
    cancellation: CancellationController().token,
  );
  final task = store.get('task/$tenant/$id')!.value;
  final artifact = (task['artifacts'] as List).single as Map;
  if (utf8.decode(store.getObject(artifact['object_key'])) != literal ||
      task['code_execution_runs'] != 1)
    throw StateError(
      'Legacy source script was not executed once with literal arguments',
    );
  if (sha256.convert(store.getObject(package)).toString() != original)
    throw StateError(
      'Legacy source compatibility changed the immutable package',
    );
}
