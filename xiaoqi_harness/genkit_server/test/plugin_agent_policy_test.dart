import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agent_policy.dart';

void main() {
  PluginAgentDefinition definition(
    String header,
  ) => PluginAgentDefinition.parse(
    'agents/writer.md',
    utf8.encode(
      '---\nname: writer\ndescription: Write a note\n$header---\nComplete the delegated task.',
    ),
  );
  const tools = [
    'set_task_deliverables',
    'list_task_files',
    'read_task_text_file',
    'write_task_text_file',
    'edit_task_text_file',
    'execute_shell',
    'execute_python',
    'execute_skill_script',
    'search_plugin_agents',
    'run_plugin_agent',
  ];
  PluginAgentPolicy resolve(
    String header, {
    bool plan = false,
    bool dontAsk = false,
  }) => PluginAgentPolicy.resolve(
    definition(header),
    parentTools: tools,
    model: 'configured-model',
    ancestorReadOnly: plan,
    ancestorDontAsk: dontAsk,
  );

  test(
    'Read Write Edit map to task file operations without granting code execution',
    () {
      final policy = resolve('tools: [Read, Write, Edit]\n');
      expect(policy.issues, isEmpty);
      expect(
        policy.tools,
        containsAll([
          'read_task_text_file',
          'write_task_text_file',
          'edit_task_text_file',
          'list_task_files',
        ]),
      );
      expect(policy.tools, isNot(contains('execute_shell')));
      expect(policy.tools, isNot(contains('execute_python')));
      expect(policy.tools, isNot(contains('set_task_deliverables')));
      final denied = resolve(
        'tools: [Read, Write, Edit]\ndisallowedTools: [Write, Edit]\n',
      );
      expect(denied.tools, ['list_task_files', 'read_task_text_file']);
    },
  );
  test(
    'nested agents cannot widen parent tools or reset ancestor permission mode',
    () {
      final policy = PluginAgentPolicy.resolve(
        definition('tools: [Read, Write, Bash]\npermissionMode: default\n'),
        parentTools: ['read_task_text_file', 'write_task_text_file'],
        model: 'configured-model',
        ancestorReadOnly: true,
        ancestorDontAsk: true,
      );
      expect(policy.tools, ['read_task_text_file']);
      expect(policy.readOnly, isTrue);
      expect(policy.dontAsk, isTrue);
      expect(resolve('tools: []\n').tools, isEmpty);
      expect(resolve('').tools, isNot(contains('set_task_deliverables')));
    },
  );
  test(
    'unknown constraints and unavailable explicit models require configuration',
    () {
      expect(resolve('tools: ["Bash(ls:*)"]\n').issues, isNotEmpty);
      expect(resolve('model: other-model\n').issues, isNotEmpty);
      expect(resolve('model: configured-model\n').issues, isEmpty);
      expect(resolve('skills: [missing-skill]\n').issues, isNotEmpty);
      for (final mode in ['dontAsk', 'bypassPermissions', 'plan']) {
        expect(resolve('permissionMode: $mode\n').dontAsk, isTrue);
      }
    },
  );
}
