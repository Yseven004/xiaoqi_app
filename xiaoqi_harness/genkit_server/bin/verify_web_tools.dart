import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import '../lib/src/agent_runtime.dart';
import '../lib/src/image_service.dart';
import '../lib/src/store.dart';

/// Live, isolated acceptance; never prints model text, queries or credentials.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('web-tools-probe-');
  final store = CloudStore(root: directory.path);
  final runtime = GenkitXiaoqiAgentRuntime(store, ImageService(store));
  try {
    for (final scenario in [
      ('search', '请核实 TinyFish 当前官方网页搜索 API 的地址，实际搜索公开来源后简短回答。', true, false),
      (
        'read',
        '请读取 https://docs.tinyfish.ai/search-api/reference 并说明 query 参数的含义。',
        false,
        true,
      ),
      (
        'research',
        '请搜索 TinyFish 官方 Fetch API 文档，读取文档原文，再概括它返回的正文格式。',
        true,
        true,
      ),
      ('offline', '不要联网。请计算 7 加 8，只回答结果。', false, false),
      ('creative', '请写一句关于雨后树叶的原创短句，无需外部资料。', false, false),
    ]) {
      final calls = <String, int>{};
      final providers = <String>{};
      final result = await runtime
          .runAgentTurn(
            tenantId: 'isolated-web-probe',
            taskId: scenario.$1,
            request: {'current_turn_text': scenario.$2},
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: scenario.$2)],
              ),
            ],
            cancellation: CancellationController().token,
            onChunk: (_) {},
            onLegacyDelta: (_) {},
            onProcessEvent: (event) {
              if (event['type'] != 'tool_succeeded') return;
              final tool = event['tool']?.toString();
              if (tool != 'web_search' && tool != 'web_fetch') return;
              if ((event['source_count'] as num? ?? 0) == 0) return;
              calls.update(tool!, (n) => n + 1, ifAbsent: () => 1);
              if (event['provider'] != null)
                providers.add(event['provider'].toString());
            },
          )
          .timeout(const Duration(minutes: 4));
      if (result.text.trim().isEmpty ||
          (scenario.$3 && (calls['web_search'] ?? 0) == 0) ||
          (scenario.$4 && (calls['web_fetch'] ?? 0) == 0) ||
          (!scenario.$3 && !scenario.$4 && calls.isNotEmpty)) {
        throw StateError(
          'Web tool acceptance failed: ${scenario.$1}; calls=$calls',
        );
      }
      stdout.writeln(
        jsonEncode({
          'check': scenario.$1,
          'verified': true,
          'calls': calls,
          'providers': providers.toList(),
          'tinyfish_configured':
              (Platform.environment['TINYFISH_API_KEY'] ?? '')
                  .trim()
                  .isNotEmpty,
        }),
      );
    }
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
