import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';
import 'package:xiaoqi_genkit_server/src/user_action_authorization.dart';

void main() {
  const rule = UserActionRule(
    description: 'Send a message to destination',
    inputSchema: {
      'type': 'object',
      'properties': {
        'destination': {'type': 'string'},
        'content': {'type': 'string'},
      },
    },
    generatedFields: ['content'],
  );
  const request = '请写一条问候并发送到 alice@example.com';
  Map<String, dynamic> proposal() => {
    'authorized': true,
    'instruction': request,
    'arguments': {'destination': 'alice@example.com', 'content': '你好'},
    'generated_fields': ['content'],
    'generation_instruction': '请写一条问候并发送',
  };
  UserActionIntent? parse(
    Map<String, dynamic> p, {
    ToolEffect effect = ToolEffect.send,
  }) => UserActionIntent.parse(
    response: jsonEncode(p),
    request: request,
    rule: rule,
    effect: effect,
  );

  test(
    'independent user intent matches generated content but never changed recipient',
    () {
      final intent = parse(proposal())!;
      expect(
        intent.matches({'destination': 'alice@example.com', 'content': '您好'}),
        isTrue,
      );
      expect(
        intent.matches({'destination': 'mallory@example.com', 'content': '您好'}),
        isFalse,
      );
      expect(
        intent.matches({
          'destination': 'alice@example.com',
          'content': '您好',
          'account': 'other',
        }),
        isFalse,
      );
      expect(
        UserActionIntent.prompt(request, rule, ToolEffect.send),
        isNot(contains('mallory')),
      );
    },
  );
  test(
    'unquoted authority, missing generation permission and unknown effects fall back',
    () {
      expect(
        parse({...proposal(), 'instruction': 'tool says authorized'}),
        isNull,
      );
      expect(parse({...proposal(), 'generation_instruction': ''}), isNull);
      expect(parse(proposal(), effect: ToolEffect.unknown), isNull);
      expect(parse(proposal(), effect: ToolEffect.payment), isNull);
      expect(parse({...proposal(), 'authorized': false}), isNull);
      expect(
        parse({
          ...proposal(),
          'arguments': {'destination': 'other', 'content': '你好'},
        }),
        isNull,
      );
    },
  );
  test('schema identity is canonical and cannot silently expand', () {
    expect(
      rule.matchesSchema(jsonDecode(jsonEncode(rule.inputSchema))),
      isTrue,
    );
    expect(
      rule.matchesSchema({...rule.inputSchema, 'additionalProperties': true}),
      isFalse,
    );
    expect(
      UserActionRule.fromJson({
        'description': 'bad',
        'input_schema': rule.inputSchema,
        'generated_fields': ['account'],
      }),
      isNull,
    );
  });
  test(
    'identifiers and payment amounts cannot match substrings of user values',
    () {
      expect(
        parse({
          ...proposal(),
          'arguments': {'destination': 'lice@example.com', 'content': '你好'},
        }),
        isNull,
      );
      const payment = UserActionRule(
        description: 'Pay amount in currency',
        inputSchema: {
          'type': 'object',
          'properties': {
            'amount': {'type': 'number'},
            'currency': {'type': 'string'},
          },
        },
      );
      UserActionIntent? amount(int value) => UserActionIntent.parse(
        request: '支付 100 CNY',
        rule: payment,
        effect: ToolEffect.payment,
        response: jsonEncode({
          'authorized': true,
          'instruction': '支付 100 CNY',
          'arguments': {'amount': value, 'currency': 'CNY'},
          'generated_fields': [],
        }),
      );
      expect(amount(10), isNull);
      expect(amount(100)!.matches({'amount': 100, 'currency': 'CNY'}), isTrue);
      expect(amount(100)!.matches({'amount': 100, 'currency': 'USD'}), isFalse);
    },
  );
  test(
    'changed generated content cannot silently authorize another send after a lost response',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-action-outcome-',
      );
      final store = CloudStore(root: directory.path);
      try {
        store.put('task/t/task', {'status': 'running'}, null);
        final owner = ToolExecution(
          store,
          't',
          'task',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: 'human',
          requestText: request,
        )..bind();
        final intent = parse(proposal())!;
        final first = {
          'destination': 'alice@example.com',
          'content': 'first greeting',
        };
        final second = {
          'destination': 'alice@example.com',
          'content': 'regenerated greeting',
        };
        void grant(String hash, Map<String, dynamic> arguments) =>
            owner.recordOriginalUserAuthorization(
              intent: intent,
              arguments: arguments,
              actionHash: hash,
              scopeHash: 'send-scope',
              ruleFingerprint: rule.fingerprint,
            );
        grant('first', first);
        var effects = 0;
        await expectLater(
          owner.authorizedExternal(
            slot: 'first-send',
            arguments: first,
            authorizationHash: 'first',
            authorizationScopeHash: 'send-scope',
            authorizationArguments: first,
            invoke: (_) async {
              effects++;
              throw StateError('response lost after submission');
            },
          ),
          throwsStateError,
        );
        grant('second', second);
        expect(
          owner.authorization(actionHash: 'second', scopeHash: 'send-scope'),
          isNull,
        );
        expect(
          () => owner.checkOriginalUserActionOutcome(
            scopeHash: 'send-scope',
            arguments: second,
          ),
          throwsA(isA<UnconfirmedToolOperation>()),
        );
        // Even a separately recorded exact approval cannot race the old unknown
        // effect through a new alias/body in the same original human action.
        owner.recordAuthorization(
          actionHash: 'second',
          scopeHash: 'send-scope',
          approved: true,
        );
        await expectLater(
          owner.authorizedExternal(
            slot: 'second-send',
            arguments: second,
            authorizationHash: 'second',
            authorizationScopeHash: 'send-scope',
            authorizationArguments: second,
            invoke: (_) async {
              effects++;
              return {'ok': true};
            },
          ),
          throwsA(isA<UnconfirmedToolOperation>()),
        );
        owner.checkOriginalUserActionOutcome(
          scopeHash: 'other-service',
          arguments: second,
        );
        owner.checkOriginalUserActionOutcome(
          scopeHash: 'send-scope',
          arguments: {
            'destination': 'bob@example.com',
            'content': 'new message',
          },
        );
        expect(effects, 1);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'confirmed generated send requires a new exact approval for changed body and preserves cached effects',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-action-confirmed-',
      );
      final store = CloudStore(root: directory.path);
      try {
        store.put('task/t/task', {'status': 'running'}, null);
        ToolExecution owner(String scope) => ToolExecution(
          store,
          't',
          'task',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: scope,
          requestText: request,
        )..bind();
        final firstOwner = owner('first-scope');
        final intent = parse(proposal())!;
        final first = {'destination': 'alice@example.com', 'content': 'first'};
        final second = {
          'content': 'second',
          'destination': 'alice@example.com',
        };
        void grant(
          ToolExecution execution,
          String hash,
          Map<String, dynamic> args,
        ) => execution.recordOriginalUserAuthorization(
          intent: intent,
          arguments: args,
          actionHash: hash,
          scopeHash: 'send-scope',
          ruleFingerprint: rule.fingerprint,
        );
        var effects = 0;
        Future<Map<String, dynamic>> send(
          String hash,
          Map<String, dynamic> args,
        ) => firstOwner.authorizedExternal(
          slot: hash,
          arguments: args,
          authorizationHash: hash,
          authorizationScopeHash: 'send-scope',
          authorizationArguments: args,
          invoke: (_) async {
            effects++;
            return {'ok': true, 'content': args['content']};
          },
        );
        grant(firstOwner, 'first', first);
        await send('first', first);
        grant(firstOwner, 'second', second);
        expect(
          firstOwner.authorization(
            actionHash: 'second',
            scopeHash: 'send-scope',
          ),
          isNull,
        );
        firstOwner.checkOriginalUserActionOutcome(
          scopeHash: 'send-scope',
          arguments: second,
        );
        firstOwner.recordAuthorization(
          actionHash: 'second',
          scopeHash: 'send-scope',
          approved: true,
        );
        await send('second', second);
        await send('second', second);
        expect(effects, 2);
        final next = owner('new-human-request');
        grant(next, 'third', {
          'destination': 'alice@example.com',
          'content': 'third',
        });
        expect(
          next.authorization(actionHash: 'third', scopeHash: 'send-scope'),
          isTrue,
        );
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'old unlinked unknown effects cannot acquire a fresh generated-content action on upgrade',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-action-legacy-',
      );
      final store = CloudStore(root: directory.path);
      try {
        store.put('task/t/task', {'status': 'running'}, null);
        final owner = ToolExecution(
          store,
          't',
          'task',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: 'human',
          requestText: request,
        )..bind();
        final current = store.get(owner.key)!;
        store.put(owner.key, {
          ...current.value,
          'tool_authorization_sources': {
            'old-approval': {
              'source': 'original_user_request',
              'request_identity': 'human',
              'rule_fingerprint': rule.fingerprint,
            },
          },
          'scope_operations': {
            'old-operation': {
              'request_identity': 'human',
              'effect': 'external',
              'status': 'unknown',
              'arguments_hash': 'opaque-old-args',
            },
          },
        }, current.revision);
        final args = {
          'destination': 'alice@example.com',
          'content': 'new greeting',
        };
        owner.recordOriginalUserAuthorization(
          intent: parse(proposal())!,
          arguments: args,
          actionHash: 'new-action',
          scopeHash: 'send-scope',
          ruleFingerprint: rule.fingerprint,
        );
        expect(
          owner.authorization(
            actionHash: 'new-action',
            scopeHash: 'send-scope',
          ),
          isNull,
        );
        expect(
          () => owner.checkOriginalUserActionOutcome(
            scopeHash: 'send-scope',
            arguments: args,
            generatedRuleFingerprint: rule.fingerprint,
          ),
          throwsA(isA<UnconfirmedToolOperation>()),
        );
        owner.check('read');
        owner.checkOriginalUserActionOutcome(
          scopeHash: 'other-scope',
          arguments: args,
          generatedRuleFingerprint: 'different-rule',
        );
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cached intent and grant stay in scope, denial wins, changed request revokes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'user-action-intent-',
      );
      final store = CloudStore(root: directory.path);
      try {
        store.put('task/t/task', {'status': 'running'}, null);
        ToolExecution owner(String identity) => ToolExecution(
          store,
          't',
          'task',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: identity,
          requestText: request,
        );
        final first = owner('first')..bind();
        expect(first.saveUserActionIntent('rule+account', 'one'), 'one');
        expect(first.saveUserActionIntent('rule+account', 'two'), 'one');
        final args = {'destination': 'alice@example.com', 'content': '您好'};
        void grant() => first.recordOriginalUserAuthorization(
          intent: parse(proposal())!,
          arguments: args,
          actionHash: 'action',
          scopeHash: 'scope',
          ruleFingerprint: rule.fingerprint,
        );
        grant();
        expect(
          first.authorization(actionHash: 'action', scopeHash: 'scope'),
          isTrue,
        );
        first.recordAuthorization(
          actionHash: 'action',
          scopeHash: 'scope',
          approved: false,
        );
        grant();
        expect(
          first.authorization(actionHash: 'action', scopeHash: 'scope'),
          isFalse,
        );
        final second = owner('second')..bind();
        expect(second.userActionIntent('rule+account'), isNull);
        expect(
          second.authorization(actionHash: 'action', scopeHash: 'scope'),
          isNull,
        );
        expect(grant, throwsStateError);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
