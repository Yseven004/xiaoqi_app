import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> main(List<String> args) async {
  final store = CloudStore(root: args[0]);
  await DockerCodeExecutionService(
    store,
    runnerUrl: Uri.parse(args[1]),
    runnerToken: 'r' * 40,
  ).connectMcp(
    tenantId: 'tenant',
    taskId: 'task',
    command: ['node', '/workspace/server.js'],
    environment: {'FIXTURE_PRIVATE_VALUE': 'must-not-be-journaled'},
    files: {},
    materials: [],
    cancellation: CancellationController().token,
  );
  // Deliberately terminate the API owner without its normal transport cleanup.
  exit(0);
}
