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
