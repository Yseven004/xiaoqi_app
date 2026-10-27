import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';

import '../lib/src/intent_router.dart';
import '../lib/src/tool_execution.dart';
import '../lib/src/turn_contract.dart';
import '../lib/src/model_limits.dart';
import '../lib/src/store.dart';
import 'verify_capability_chain.dart' as capability;

/// Synthetic release gate; no personal attachment is sent to a provider.
void main() {
  final ai = Genkit(
    promptDir: null,
    isDevEnv: true,
    plugins: [
      deepSeek(
        apiKey: Platform.environment['DEEPSEEK_API_KEY'] ?? '',
        models: [CustomModelDefinition(name: 'deepseek-flash')],
      ),
    ],
  );
  ai.defineFlow(
    name: 'verifyIntentScope',
    inputSchema: .string(),
    outputSchema: .string(),
    fn: (_, _) async {
      final directory = Directory.systemTemp.createTempSync('intent-live-');
      final store = CloudStore(root: directory.path);
      try {
        for (final text in [
          '这是什么',
          '我问你这是什么？',
          '不要生成图片，只解释这张图',
          '这个技能怎么用？',
          '用科学学习卡技能将光合作用做成一张配图学习卡',
          '解释光合作用的原理，并附一张示意图',
        ]) {
          final mixed = text.startsWith('解释光合作用');
          final positive = text.startsWith('用科学') || mixed;
          final contract = await routeTurnIntent(
            text: text,
            skills: [
              {
                'id': 'science-card',
                'name': '科学学习卡',
                'description': '将科学知识做成配图学习卡',
              },
            ],
            connections: [],
            artifacts: [
              {'id': 'prior/cat', 'name': '猫图', 'media_type': 'image/png'},
            ],
            recentUserMessages: ['生成一张猫的图片'],
            generate: (system, prompt) async => jsonEncode(
              (await ai.generate(
                model: openAI.model('deepseek-flash', namespace: 'deepseek'),
                system: system,
                prompt: prompt,
                toolNames: [],
                maxTurns: 1,
                outputSchema: TurnContract.proposalSchema,
                outputFormat: 'json',
                config: OpenAIChatOptions(
                  temperature: 0,
                  maxTokens: ModelLimits.deepSeek.maxOutputTokens,
                  reasoningEffort: 'low',
                ),
              )).output,
            ),
          );
          var imageCalls = 0;
          final execution = ToolExecution(
            store,
            'probe',
            text.hashCode.toString(),
            contract,
            requestIdentity: text,
          )..bind();
          if (!positive) {
            try {
              await execution.image(
                slot: '1',
                arguments: {},
                invoke: (_) async {
                  imageCalls++;
                  return {};
                },
              );
            } on StateError {
              /* Expected deterministic denial. */
            }
          }
          final passed = positive
              ? contract.permitsImages &&
                    (mixed
                        ? contract.answerRequired
                        : contract.skillIds.contains('science-card'))
              : !contract.permitsImages &&
                    contract.skillIds.isEmpty &&
                    imageCalls == 0;
          stdout.writeln(
            jsonEncode({
              'check': text,
              'verified': passed,
              'mode': contract.mode,
              'image_limit': contract.imageLimit,
              'provider_image_calls': imageCalls,
            }),
          );
          if (!passed) throw StateError('Intent release gate failed');
        }
        await capability.main(const []);
        return 'All synthetic intent and capability gates passed';
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
