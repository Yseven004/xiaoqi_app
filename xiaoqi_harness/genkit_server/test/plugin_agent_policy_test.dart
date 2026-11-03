import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agent_policy.dart';

void main() {
  test(
    'read-only agents retain permitted web tools and honor explicit denial',
    () {
      PluginAgentDefinition webAgent(
        String extra,
      ) => PluginAgentDefinition.parse(
        'agents/research.md',
        utf8.encode(
          '---\nname: research\ndescription: Research\ntools: [WebSearch, WebFetch]\n$extra---\nRead public sources.',
        ),
      );
      final allowed = PluginAgentPolicy.resolve(
        webAgent(''),
        parentTools: ['web_search', 'web_fetch'],
        model: 'configured-model',
        ancestorReadOnly: true,
      );
      expect(allowed.tools, containsAll(['web_search', 'web_fetch']));
      final denied = PluginAgentPolicy.resolve(
        webAgent('disallowedTools: [WebFetch]\n'),
        parentTools: ['web_search', 'web_fetch'],
        model: 'configured-model',
      );
      expect(denied.tools, contains('web_search'));
      expect(denied.tools, isNot(contains('web_fetch')));
    },
  );
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
  test(
    'Claude model aliases use the configured V4.1 Flash without widening tools',
    () {
      for (final alias in ['sonnet', 'haiku', 'opus']) {
        expect(
          PluginAgentPolicy.executionModel(
            definition('model: $alias\n'),
            'mimo-v2.6-flash',
          ),
          'deepseek-flash',
        );
        final policy = PluginAgentPolicy.resolve(
          definition('tools: [Read]\nmodel: $alias\n'),
          parentTools: tools,
          model: 'deepseek-flash',
        );
        expect(policy.issues, isEmpty);
        expect(policy.tools, ['list_task_files', 'read_task_text_file']);
        expect(policy.notes.single, contains(alias));
        expect(policy.notes.single, contains('deepseek-flash'));
        expect(resolve('model: $alias\n').issues, isNotEmpty);
      }
      expect(
        PluginAgentPolicy.executionModel(definition(''), 'deepseek-flash'),
        'deepseek-flash',
      );
      expect(
        PluginAgentPolicy.resolve(
          definition('model: unknown-provider-model\n'),
          parentTools: tools,
          model: 'deepseek-flash',
        ).issues,
        isNotEmpty,
      );
    },
  );
  test(
    'plugin-only ignored fields neither disable the child nor launch or grant tools',
    () {
      final policy = resolve(
        'tools: [Read, Write]\nmcpServers: [unconfigured-inline-server]\nhooks: {PreToolUse: [{command: touch-unreachable}]}\n',
      );
      expect(policy.issues, isEmpty);
      expect(policy.notes, hasLength(2));
      expect(policy.tools, resolve('tools: [Read, Write]\n').tools);
      expect(policy.tools, isNot(contains('execute_shell')));
      expect(resolve('memory: user\n').issues, isNotEmpty);
      expect(resolve('isolation: worktree\n').issues, isNotEmpty);
      expect(resolve('hooks: {}\nmcpServers: []\n').notes, isEmpty);
    },
  );
}
