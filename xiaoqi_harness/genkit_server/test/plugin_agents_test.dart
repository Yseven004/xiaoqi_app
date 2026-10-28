import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';

void main() {
  List<int> source(
    String header, [
    String body = 'Read the package reference and report findings.',
  ]) => utf8.encode(
    '---\nname: reviewer\ndescription: Review task material\n$header---\n$body',
  );
  test(
    'agent metadata preserves tool restrictions and host requirements without granting authority',
    () {
      final agent = PluginAgentDefinition.parse(
        'agents/reviewer.md',
        source(
          'tools: Read, Bash\ndisallowedTools: [Write]\nmodel: inherit\nmaxTurns: 4\npermissionMode: dontAsk\nskills: [reference-reader]\n',
        ),
      );
      expect(agent.tools, ['Read', 'Bash']);
      expect(agent.disallowedTools, ['Write']);
      expect(agent.model, 'inherit');
      expect(agent.maxTurns, 4);
      expect(agent.metadata['permissionMode'], 'dontAsk');
      expect(agent.metadata['skills'], ['reference-reader']);
      final textOnly = PluginAgentDefinition.parse(
        'agents/text.md',
        source('tools: []\n'),
      );
      expect(textOnly.tools, isEmpty);
      expect(
        PluginAgentDefinition.parse('agents/default.md', source('')).tools,
        isNull,
      );
      expect(
        PluginAgentDefinition.parse(
          'agents/configured.md',
          source('model: configured-model\n'),
        ).model,
        'configured-model',
      );
    },
  );
  test(
    'agent root substitution stays literal and malformed behavioral fields are rejected',
    () {
      final agent = PluginAgentDefinition.parse(
        'agents/reviewer.md',
        source('', r'Read ${CLAUDE_PLUGIN_ROOT}/references/check.md'),
      );
      expect(
        agent.render(r'plugin-agent://id/$ARGUMENTS'),
        r'Read plugin-agent://id/$ARGUMENTS/references/check.md',
      );
      for (final header in [
        'tools: true\n',
        'tools: [Read, 42]\n',
        'maxTurns: 0\n',
        'maxTurns: 2.5\n',
        'background: yes-please\n',
        'model: []\n',
        'permissionMode: {}\n',
      ]) {
        expect(
          () => PluginAgentDefinition.parse('agents/bad.md', source(header)),
          throwsFormatException,
        );
      }
      expect(
        () => PluginAgentDefinition.parse(
          'agents/bad.md',
          utf8.encode('No metadata'),
        ),
        throwsFormatException,
      );
      expect(
        () => PluginAgentDefinition.parse('agents/bad.md', source('', '')),
        throwsFormatException,
      );
    },
  );
  test(
    'agent discovery keeps healthy definitions and custom roots inside the pinned package',
    () {
      final files = {
        'plugin/agents/reviewer.md': source(''),
        'plugin/agents/invalid.md': utf8.encode('invalid'),
        'plugin/custom/nested.md': source('tools: []\n'),
        'outside/agent.md': source(''),
      };
      final components = PluginAgentDefinition.inspect(files, 'plugin', {
        'agents': './custom',
      });
      expect(components, hasLength(3));
      expect(
        components.where((entry) => entry['status'] == 'supported'),
        hasLength(2),
      );
      expect(
        components
            .where((entry) => entry['status'] == 'unsupported')
            .single['source_path'],
        'agents/invalid.md',
      );
      for (final location in [
        './../outside',
        './missing',
        '/absolute',
        'https://example.com/agent.md',
      ]) {
        expect(
          () => PluginAgentDefinition.inspect(files, 'plugin', {
            'agents': location,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
