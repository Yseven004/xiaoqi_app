import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/network_call_authorization.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late ToolExecution execution;
  setUp(() {
    root = Directory.systemTemp.createTempSync('network-call-authorization-');
    store = CloudStore(root: root.path);
    execution = ToolExecution(
      store,
      'personal',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'request',
    )..bind();
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  NetworkCallAuthorization call({
    String code = 'original',
    String tool = 'execute_python',
    String files = 'files-v1',
  }) => NetworkCallAuthorization(
    execution: execution,
    domains: ['example.com'],
    tool: tool,
    arguments: {
      'code': code,
      'arguments': ['original-argument'],
    },
    authority: {
      'skill_version': 'v1',
      'materials': files,
      'network_mode': 'off',
    },
  );

  test(
    'exact approval is reusable but cannot authorize changed code, files or another entry',
    () {
      final original = call();
      expect(original.decide(), ToolAccessDecision.confirm);
      expect(
        original.decide(
          resumed: {
            'approved': true,
            'approval_hash': original.approvalHash,
            'domains': ['example.com'],
          },
        ),
        ToolAccessDecision.allow,
      );
      expect(call().decide(), ToolAccessDecision.allow);
      expect(call(code: 'changed').decide(), ToolAccessDecision.confirm);
      expect(call(files: 'new-files').decide(), ToolAccessDecision.confirm);
      expect(
        call(tool: 'execute_skill_script').decide(),
        ToolAccessDecision.confirm,
      );
      expect(
        store.get('task/personal/task')!.value['authorized_network_domains'],
        isEmpty,
      );
    },
  );

  test(
    'denial wins over an earlier approval and prevents switching execution entry',
    () {
      final original = call();
      original.decide(
        resumed: {
          'approved': true,
          'approval_hash': original.approvalHash,
          'domains': ['example.com'],
        },
      );
      final changed = call(code: 'different');
      expect(
        changed.decide(
          resumed: {
            'approved': false,
            'approval_hash': changed.approvalHash,
            'domains': ['example.com'],
          },
        ),
        ToolAccessDecision.deny,
      );
      expect(original.decide(), ToolAccessDecision.deny);
      expect(
        call(tool: 'execute_skill_script').decide(),
        ToolAccessDecision.deny,
      );
      expect(
        original.decide(
          resumed: {
            'approved': true,
            'approval_hash': original.approvalHash,
            'domains': ['example.com'],
          },
        ),
        ToolAccessDecision.deny,
      );
    },
  );

  test(
    'stale hashes, missing hash and changed hosts cannot record a decision',
    () {
      final original = call();
      for (final payload in [
        {
          'approved': true,
          'domains': ['example.com'],
        },
        {
          'approved': false,
          'approval_hash': 'old',
          'domains': ['example.com'],
        },
        {
          'approved': true,
          'approval_hash': original.approvalHash,
          'domains': ['other.example.com'],
        },
      ]) {
        expect(original.decide(resumed: payload), ToolAccessDecision.confirm);
      }
      expect(
        store.get('task/personal/task')!.value['tool_authorizations'],
        isEmpty,
      );
    },
  );

  test('offline work remains available after networking is refused', () {
    final online = call();
    online.decide(
      resumed: {
        'approved': false,
        'approval_hash': online.approvalHash,
        'domains': ['example.com'],
      },
    );
    final offline = NetworkCallAuthorization(
      execution: execution,
      domains: [],
      tool: 'execute_python',
      arguments: {'code': 'local only'},
      authority: {},
    );
    expect(offline.decide(), ToolAccessDecision.allow);
  });

  test(
    'successful code is reused; a submitted unknown effect is never replayed',
    () async {
      final grant = call();
      grant.decide(
        resumed: {
          'approved': true,
          'approval_hash': grant.approvalHash,
          'domains': ['example.com'],
        },
      );
      var invoked = 0;
      Future<String> provider() async {
        invoked++;
        return 'result';
      }

      expect(await grant.execute(provider), 'result');
      expect(await grant.execute(provider), 'result');
      expect(invoked, 1);
      final unknown = call(code: 'unknown');
      unknown.decide(
        resumed: {
          'approved': true,
          'approval_hash': unknown.approvalHash,
          'domains': ['example.com'],
        },
      );
      Future<String> uncertain() async {
        invoked++;
        throw SandboxExecutionError('response lost');
      }

      await expectLater(
        unknown.execute(uncertain),
        throwsA(isA<SandboxExecutionError>()),
      );
      await expectLater(unknown.execute(uncertain), throwsStateError);
      expect(invoked, 2);
    },
  );

  test(
    'known failure before submission can retry without a second approval',
    () async {
      final grant = call();
      grant.decide(
        resumed: {
          'approved': true,
          'approval_hash': grant.approvalHash,
          'domains': ['example.com'],
        },
      );
      var invoked = 0;
      Future<String> provider() async {
        invoked++;
        if (invoked == 1) throw StateError('bridge not started');
        return 'recovered';
      }

      await expectLater(grant.execute(provider), throwsStateError);
      expect(await grant.execute(provider), 'recovered');
      expect(invoked, 2);
    },
  );
}
