import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';

void main() {
  PluginHookOutput verdict(
    String event,
    Object output, {
    int? exit = 0,
    String stderr = '',
    bool failureBlocks = false,
  }) => PluginHookOutput.parse(
    event: event,
    exitCode: exit,
    stdout: output is String ? output : jsonEncode(output),
    stderr: stderr,
    failureBlocks: failureBlocks,
  );
  Map specific(String event, Map fields) => {
    'hookSpecificOutput': {'hookEventName': event, ...fields},
  };

  test(
    'allow remains advisory; updated input must face host authorization again',
    () {
      final result = verdict(
        'PreToolUse',
        specific('PreToolUse', {
          'permissionDecision': 'allow',
          'updatedInput': {'recipient': 'unapproved-account'},
        }),
      );
      expect(result.permission, 'allow');
      expect(result.preventAction, false);
      // Exercise the consuming boundary: source advice cannot authorize the
      // changed target, nor mutate the result after authorization hashes bind it.
      var sent = 0;
      final originalGrant = {'recipient': 'approved-account'};
      if (jsonEncode(result.updatedInput) == jsonEncode(originalGrant)) sent++;
      expect(sent, 0);
      expect(
        () => result.updatedInput!['recipient'] = 'approved-account',
        throwsUnsupportedError,
      );
    },
  );

  test('exit two wins over allow, changed input and malformed output', () {
    for (final output in [
      specific('PreToolUse', {
        'permissionDecision': 'allow',
        'updatedInput': {'code': 'unsafe'},
      }),
      '{bad',
      '',
    ]) {
      final result = verdict(
        'PreToolUse',
        output,
        exit: 2,
        stderr: 'do not send',
      );
      expect(result.preventAction, true);
      expect(result.updatedInput, isNull);
      expect(result.reason, 'do not send');
    }
  });

  test('completed effects remain completed when post hooks block or fail', () {
    for (final event in ['PostToolUse', 'PostToolUseFailure']) {
      final result = verdict(event, {
        'decision': 'block',
        'reason': 'review output',
      });
      expect(result.preventAction, false);
      expect(result.additionalContext, 'review output');
      final exit = verdict(event, '', exit: 2, stderr: 'already happened');
      expect(exit.preventAction, false);
      expect(exit.additionalContext, 'already happened');
      expect(
        verdict(event, '', exit: 1, failureBlocks: true).preventAction,
        false,
      );
    }
  });

  test(
    'permission requests deny via JSON, exit two leaves permission flow intact',
    () {
      expect(verdict('PermissionRequest', '', exit: 2).preventAction, false);
      final denial = verdict(
        'PermissionRequest',
        specific('PermissionRequest', {
          'decision': {'behavior': 'deny', 'message': 'source policy denied'},
        }),
      );
      expect(denial.preventAction, true);
      expect(denial.reason, 'source policy denied');
      final ask = verdict(
        'PreToolUse',
        specific('PreToolUse', {'permissionDecision': 'ask'}),
      );
      expect(ask.permission, 'ask');
      expect(ask.preventAction, false);
    },
  );

  test(
    'wrong event and malformed structured control apply no partial updates',
    () {
      for (final output in [
        specific('Stop', {'permissionDecision': 'deny'}),
        specific('PreToolUse', {'permissionDecision': 'invented'}),
        specific('PreToolUse', {'updatedInput': []}),
        {'continue': 'false'},
        {'continue': false, 'stopReason': 3},
        [],
      ]) {
        final result = verdict('PreToolUse', output);
        expect(result.error, isNotNull);
        expect(result.preventAction, false);
        expect(result.stopProcessing, false);
        expect(result.updatedInput, isNull);
        expect(
          verdict('PreToolUse', output, failureBlocks: true).preventAction,
          true,
        );
      }
    },
  );

  test(
    'failed command cannot allow via stdout, timeout respects failure policy',
    () {
      final output = specific('PreToolUse', {
        'permissionDecision': 'allow',
        'updatedInput': {'a': 1},
      });
      final result = verdict(
        'PreToolUse',
        output,
        exit: 1,
        failureBlocks: true,
      );
      expect(result.preventAction, true);
      expect(result.permission, isNull);
      expect(result.updatedInput, isNull);
      expect(
        PluginHookOutput.parse(
          event: 'PreToolUse',
          exitCode: 0,
          stdout: jsonEncode(output),
          stderr: '',
          timedOut: true,
          failureBlocks: true,
        ).preventAction,
        true,
      );
      expect(
        verdict('Stop', '', exit: 1, failureBlocks: true).continueLoop,
        false,
      );
    },
  );

  test(
    'stop instruction takes precedence over loop continuation and rewrites',
    () {
      final stop = verdict('Stop', {
        'continue': false,
        'stopReason': 'explicit stop',
        'decision': 'block',
        'reason': 'continue work',
      });
      expect(stop.stopProcessing, true);
      expect(stop.continueLoop, false);
      expect(stop.reason, 'explicit stop');
      expect(
        verdict('Stop', {
          'decision': 'block',
          'reason': 'fix issue',
        }).continueLoop,
        true,
      );
      expect(verdict('TaskCreated', {'continue': false}).stopProcessing, false);
    },
  );

  test('plain text context only enters events whose protocol permits it', () {
    expect(
      verdict('SessionStart', 'project context').additionalContext,
      'project context',
    );
    expect(
      verdict('UserPromptSubmit', 'project context').additionalContext,
      'project context',
    );
    expect(verdict('PreToolUse', 'project context').additionalContext, isNull);
    expect(verdict('StopFailure', {'continue': false}).stopProcessing, false);
    expect(verdict('Notification', '', exit: 2).preventAction, false);
  });

  test('result replacement stays separate from already executed effect', () {
    final replacement = verdict(
      'PostToolUse',
      specific('PostToolUse', {
        'updatedToolOutput': null,
        'updatedMCPToolOutput': {'legacy': true},
      }),
    );
    expect(replacement.hasUpdatedToolOutput, true);
    expect(replacement.updatedToolOutput, isNull);
    expect(replacement.preventAction, false);
    expect(
      verdict(
        'PreToolUse',
        specific('PreToolUse', {'updatedToolOutput': 'wrong event'}),
      ).hasUpdatedToolOutput,
      false,
    );
  });

  test(
    'oversized output cannot smuggle a verdict through a partial JSON parse',
    () {
      final output = specific('PreToolUse', {
        'permissionDecision': 'allow',
        'additionalContext': 'a' * PluginHookOutput.maxOutputBytes,
      });
      final result = verdict('PreToolUse', output, failureBlocks: true);
      expect(result.error, contains('128 KiB'));
      expect(result.preventAction, true);
      expect(result.permission, isNull);
      expect(verdict('PreToolUse', output, exit: 2).preventAction, true);
      expect(
        verdict('PermissionRequest', output, exit: 2).preventAction,
        false,
      );
      final oversizedFailure = verdict(
        'PreToolUse',
        '',
        exit: 1,
        stderr: 'x' * (PluginHookOutput.maxOutputBytes + 1),
      );
      expect(oversizedFailure.error, contains('128 KiB'));
      expect(oversizedFailure.error!.length, lessThan(100));
    },
  );
}
