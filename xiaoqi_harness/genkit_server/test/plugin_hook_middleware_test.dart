import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_middleware.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late ToolExecution execution;
  late PluginHookControl control;
  var sourceAvailable = true;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hook-middleware-');
    store = CloudStore(root: directory.path);
    store.put('task/alice/task', {'status': 'running'}, null);
    execution = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'request',
    );
    execution.bind();
    control = PluginHookControl();
    sourceAvailable = true;
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  PluginHookMiddleware middleware(
    PluginHookDispatch dispatch, {
    bool matching = true,
    bool canAsk = false,
  }) => PluginHookMiddleware(
    execution: () => execution,
    control: control,
    dispatch: dispatch,
    hasHooks: (_) => matching,
    checkSources: (_) {
      if (!sourceAvailable) throw StateError('withdrawn source');
    },
    describe: (name, input) => canAsk
        ? PluginHookTool(
            'mcp__server__send',
            input,
            (updated) => {...input, ...updated},
            canAsk: true,
          )
        : PluginHookTool.native(name, input),
    validateInput: (_, input) async =>
        input is Map && input['path'] is String && input['text'] is String,
  );
  ToolRequestPart request({String? ref = 'original'}) => ToolRequestPart(
    toolRequest: ToolRequest(
      name: 'write_task_text_file',
      ref: ref,
      input: {'path': 'report.txt', 'text': 'original'},
    ),
  );

  test(
    'source rewrite is schema-checked and never mutates original SDK resume input',
    () async {
      final original = request();
      final events = <String>[];
      final hooks = middleware((event, id, input) async {
        events.add(event);
        expect(input['tool_name'], 'Write');
        if (event == 'PreToolUse') {
          expect(input['tool_input'], {
            'file_path': 'report.txt',
            'content': 'original',
          });
          return [
            PluginHookOutput(updatedInput: {'content': 'rewritten'}),
          ];
        }
        expect(input['tool_input'], {
          'file_path': 'report.txt',
          'content': 'rewritten',
        });
        return [
          const PluginHookOutput(additionalContext: 'verified post context'),
        ];
      });
      var effects = 0;
      final result = await hooks.tool(original, ActionFnArg(), (
        effective,
        _,
      ) async {
        expect(effective.toolRequest.input, {
          'path': 'report.txt',
          'text': 'rewritten',
        });
        effects++;
        return ToolResult.response('{"ok":true}');
      });
      expect(effects, 1);
      expect(original.toolRequest.input, {
        'path': 'report.txt',
        'text': 'original',
      });
      expect(events, ['PreToolUse', 'PostToolUse']);
      expect(jsonDecode(result.output as String)['plugin_hook_context'], [
        'verified post context',
      ]);
    },
  );

  test(
    'malformed rewrite cannot reach native effect and triggers failure event',
    () async {
      final events = <String>[];
      final hooks = middleware((event, _, _) async {
        events.add(event);
        return event == 'PreToolUse'
            ? [
                const PluginHookOutput(updatedInput: {'content': 7}),
              ]
            : [];
      });
      var effects = 0;
      await hooks.tool(request(), ActionFnArg(), (_, _) async {
        effects++;
        return ToolResult.response('unexpected');
      });
      expect(effects, 0);
      expect(events, ['PreToolUse', 'PostToolUseFailure']);
    },
  );

  test(
    'unmatched or unselected source does not block unrelated read-only tools',
    () async {
      sourceAvailable = false;
      var effects = 0;
      final hooks = middleware(
        (_, _, _) async => throw StateError('must not dispatch'),
        matching: false,
      );
      await hooks.tool(
        request(ref: null),
        ActionFnArg(context: {'xiaoqi_plugin_agent_read_only': true}),
        (_, _) async {
          effects++;
          return ToolResult.response('healthy sibling');
        },
      );
      expect(effects, 1);
    },
  );

  test(
    'source withdrawal during hook work blocks submission to the native tool',
    () async {
      var effects = 0;
      final hooks = middleware((_, _, _) async {
        sourceAvailable = false;
        return [];
      });
      await expectLater(
        hooks.tool(request(), ActionFnArg(), (_, _) async {
          effects++;
          return ToolResult.response('unexpected');
        }),
        throwsStateError,
      );
      expect(effects, 0);
    },
  );

  test(
    'interrupted target is not a failure or successful post event',
    () async {
      final events = <String>[];
      final hooks = middleware((event, _, _) async {
        events.add(event);
        return [];
      });
      const interrupted = ToolInterruptResult({'type': 'mcp_tool_approval'});
      final result = await hooks.tool(
        request(),
        ActionFnArg(),
        (_, _) async => interrupted,
      );
      expect(result, same(interrupted));
      expect(events, ['PreToolUse']);
    },
  );

  test(
    'ask is task-local, and allow never injects approval into the tool context',
    () async {
      for (final permission in ['ask', 'allow']) {
        final hooks = middleware(
          (event, _, _) async => event == 'PreToolUse'
              ? [PluginHookOutput(permission: permission)]
              : [],
          canAsk: true,
        );
        await hooks.tool(request(), ActionFnArg(), (_, context) async {
          expect(PluginHookControl.asksPermission, permission == 'ask');
          expect(context.context?['approved'], isNot(true));
          return ToolResult.response('ok');
        });
        expect(PluginHookControl.asksPermission, false);
      }
    },
  );

  test(
    'post hook cannot roll back effect; output replacement drops old multipart data',
    () async {
      var effects = 0;
      final hooks = middleware(
        (event, _, _) async => event == 'PostToolUse'
            ? [
                const PluginHookOutput(
                  hasUpdatedToolOutput: true,
                  updatedToolOutput: 'redacted',
                ),
              ]
            : [],
      );
      final result = await hooks.tool(request(), ActionFnArg(), (_, _) async {
        effects++;
        return ToolResult.response(
          'original',
          parts: [TextPart(text: 'old multipart')],
        );
      });
      expect(effects, 1);
      expect(result.output, 'redacted');
      expect((result as ToolResponseResult).parts, isNull);
    },
  );
  test('legacy MCP-only replacement does not replace native output', () async {
    final hooks = middleware(
      (event, _, _) async => event == 'PostToolUse'
          ? [
              const PluginHookOutput(
                hasUpdatedToolOutput: true,
                mcpOnlyOutput: true,
                updatedToolOutput: 'MCP-only replacement',
              ),
            ]
          : [],
    );
    final result = await hooks.tool(
      request(),
      ActionFnArg(),
      (_, _) async => ToolResult.response('native original'),
    );
    expect(result.output, 'native original');
  });
}
