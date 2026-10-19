import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';

import '../lib/src/agent_runtime.dart';
import '../lib/src/image_service.dart';
import '../lib/src/public_agent_process.dart';
import '../lib/src/release.dart';
import '../lib/src/store.dart';

/// Explicit live verification against the configured model. Uses an isolated
/// temporary store; prints only counters, never model text or credentials.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('native-reasoning-');
  final store = CloudStore(root: directory.path);
  final runtime = GenkitXiaoqiAgentRuntime(store, ImageService(store));
  try {
    for (final search in [false, true]) {
      final task = search ? 'search' : 'question';
      final prompt = search
          ? '请实际联网搜索一次天问一号的发射日期，依据来源用两句话回答。'
          : '比较七分之九与十五分之十一哪个更大，用三句话解释，不要联网。';
      final process = PublicAgentProcess(task);
      var chunks = 0;
      var starts = 0;
      var searches = 0;
      final events = <String>[];
      final result = await runtime
          .runAgentTurn(
            tenantId: 'isolated-native-verification',
            taskId: task,
            request: {
              'current_turn_text': prompt,
              'network_mode': search ? 'on' : 'off',
              'reasoning_level': 'medium',
            },
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: prompt)],
              ),
            ],
            cancellation: CancellationController().token,
            onChunk: (_) {},
            onLegacyDelta: (_) => chunks++,
            onProcessEvent: (event) {
              events.add(event['type']?.toString() ?? '');
              if (event['type'] == 'answer_started') starts++;
              if (event['type'] == 'tool_succeeded' &&
                  event['tool'] == 'web_search' &&
                  event['source_count'] is num &&
                  (event['source_count'] as num) > 0)
                searches++;
              process.add(event);
            },
          )
          .timeout(const Duration(minutes: 4));
      process.finish('completed');
      final rawChars = result.messages
          .expand((m) => m.content)
          .where((p) => p.isReasoning)
          .fold<int>(0, (n, p) => n + (p.reasoning?.length ?? 0));
      final publicRows = process.rows
          .where((r) => r['source'] == 'model_reasoning')
          .toList();
      if (rawChars == 0 ||
          publicRows.isEmpty ||
          result.text.isEmpty ||
          chunks < 2 ||
          starts != 1 ||
          (search && searches == 0) ||
          events.indexOf('reasoning_update') >
              events.indexOf('answer_started') ||
          process.rows.any((r) => r['status'] == 'running')) {
        throw StateError('Native reasoning verification failed: $task');
      }
      stdout.writeln(
        jsonEncode({
          'check': task,
          'verified': true,
          'release': releaseId,
          'contract': apiContractVersion,
          'private_reasoning_chars': rawChars,
          'public_reasoning_blocks': publicRows.length,
          'answer_chunks': chunks,
          'answer_starts': starts,
          'verified_searches': searches,
        }),
      );
    }
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
