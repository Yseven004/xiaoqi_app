import 'dart:convert';

/// Source hook verdicts are task data, never grants. In particular, `allow`
/// must still pass the host's current authority/argument checks before any IO.
class PluginHookOutput {
  const PluginHookOutput({
    this.permission,
    this.preventAction = false,
    this.stopProcessing = false,
    this.continueLoop = false,
    this.reason,
    this.additionalContext,
    this.systemMessage,
    this.updatedInput,
    this.updatedToolOutput,
    this.hasUpdatedToolOutput = false,
    this.mcpOnlyOutput = false,
    this.error,
  });

  final String? permission, reason, additionalContext, systemMessage, error;
  final bool preventAction, stopProcessing, continueLoop;
  final Map<String, dynamic>? updatedInput;
  final Object? updatedToolOutput;
  final bool hasUpdatedToolOutput;
  final bool mcpOnlyOutput;

  static const maxOutputBytes = 128 * 1024;
  static const _blockable = {
    'PreToolUse',
    'UserPromptSubmit',
    'UserPromptExpansion',
    'PostToolBatch',
    'TaskCreated',
    'TaskCompleted',
    'ConfigChange',
    'PreCompact',
    'PreModelSwitch',
    'Elicitation',
    'ElicitationResult',
  };
  static const _loopEvents = {'Stop', 'SubagentStop', 'TeammateIdle'};
  static const _topDecision = {
    'UserPromptSubmit',
    'UserPromptExpansion',
    'PostToolUse',
    'PostToolUseFailure',
    'PostToolBatch',
    'Stop',
    'SubagentStop',
    'TaskCreated',
    'ConfigChange',
    'PreCompact',
    'PreModelSwitch',
  };

  static PluginHookOutput parse({
    required String event,
    required int? exitCode,
    required String stdout,
    required String stderr,
    bool timedOut = false,
    bool failureBlocks = false,
  }) {
    PluginHookOutput failure(String message) => PluginHookOutput(
      error: message,
      preventAction:
          failureBlocks &&
          (_blockable.contains(event) || event == 'PermissionRequest'),
      reason: failureBlocks ? message : null,
    );
    if (timedOut) return failure('hook 执行超时');
    if (utf8.encode(stdout).length > maxOutputBytes ||
        utf8.encode(stderr).length > maxOutputBytes) {
      if (exitCode == 2) {
        return PluginHookOutput(
          preventAction: _blockable.contains(event),
          continueLoop: _loopEvents.contains(event),
          reason: 'hook 输出超过 128 KiB',
          error: 'hook 输出超过 128 KiB',
        );
      }
      return failure('hook 输出超过 128 KiB');
    }
    if (exitCode != 0 && exitCode != 2) {
      return failure(stderr.isEmpty ? 'hook 执行失败（exit $exitCode）' : stderr);
    }
    // These events discard verdicts; never accidentally re-open completed IO.
    if (const {
      'StopFailure',
      'Notification',
      'PermissionDenied',
      'Setup',
      'InstructionsLoaded',
      'MessageDisplay',
    }.contains(event)) {
      return const PluginHookOutput();
    }
    final text = stdout.trim();
    Map<String, dynamic> output = const {};
    String? invalid;
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        final parsed = jsonDecode(text);
        if (parsed is! Map<String, dynamic>) {
          throw const FormatException('hook 输出需要 JSON 对象');
        }
        output = parsed;
        _validate(output, event);
      } on FormatException catch (error) {
        invalid = error.message.toString();
        output = const {};
      }
    }
    // A malformed/allowing JSON document cannot undo an exit-2 block.
    final exitBlocks = exitCode == 2;
    if (invalid != null && !exitBlocks) return failure(invalid);
    final specific = output['hookSpecificOutput'] as Map? ?? const {};
    final permissionResult = specific['decision'] is Map
        ? specific['decision'] as Map
        : const {};
    var permission = event == 'PreToolUse' || event == 'PreModelSwitch'
        ? specific['permissionDecision'] as String?
        : null;
    if (event == 'PreToolUse' && permission == null) {
      permission = switch (output['decision']) {
        'approve' => 'allow',
        'block' => 'deny',
        _ => null,
      };
    }
    if (event == 'PermissionRequest') {
      permission = permissionResult['behavior'] as String?;
    }
    final jsonBlocks =
        permission == 'deny' ||
        (_topDecision.contains(event) && output['decision'] == 'block');
    final blocks = jsonBlocks || exitBlocks;
    final stop = output['continue'] == false && event != 'TaskCreated';
    final reason = stop
        ? output['stopReason'] as String?
        : (blocks
              ? (specific['permissionDecisionReason'] as String?) ??
                    (event == 'PermissionRequest'
                        ? permissionResult['message'] as String?
                        : null) ??
                    (output['reason'] as String?) ??
                    (stderr.isNotEmpty ? stderr : null)
              : null);
    final contextualExit = const {
      'PostToolUse',
      'PostToolUseFailure',
      'PostToolBatch',
      'Stop',
      'SubagentStop',
    }.contains(event);
    final context =
        (specific['additionalContext'] as String?) ??
        (exitCode == 0 &&
                !text.startsWith('{') &&
                !text.startsWith('[') &&
                const {'SessionStart', 'UserPromptSubmit'}.contains(event)
            ? text
            : blocks && contextualExit
            ? reason
            : null);
    return PluginHookOutput(
      permission: permission,
      preventAction:
          (_blockable.contains(event) && blocks) ||
          (event == 'PermissionRequest' && permission == 'deny'),
      stopProcessing: stop,
      continueLoop:
          !stop &&
          _loopEvents.contains(event) &&
          (blocks || (context?.isNotEmpty ?? false)),
      reason: reason,
      additionalContext: context?.isEmpty == true ? null : context,
      systemMessage: output['systemMessage'] as String?,
      updatedInput:
          !exitBlocks &&
              !stop &&
              event == 'PreToolUse' &&
              specific['updatedInput'] is Map
          ? _freeze(specific['updatedInput']) as Map<String, dynamic>
          : null,
      hasUpdatedToolOutput:
          !exitBlocks &&
          !stop &&
          event == 'PostToolUse' &&
          (specific.containsKey('updatedToolOutput') ||
              specific.containsKey('updatedMCPToolOutput')),
      mcpOnlyOutput:
          !specific.containsKey('updatedToolOutput') &&
          specific.containsKey('updatedMCPToolOutput'),
      updatedToolOutput: _freeze(
        specific.containsKey('updatedToolOutput')
            ? specific['updatedToolOutput']
            : specific['updatedMCPToolOutput'],
      ),
      error: invalid,
    );
  }

  static Object? _freeze(Object? value) {
    if (value is Map)
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          entry.key.toString(): _freeze(entry.value),
      });
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }

  static void _validate(Map<String, dynamic> value, String event) {
    for (final key in ['continue', 'suppressOutput']) {
      if (value.containsKey(key) && value[key] is! bool) {
        throw FormatException('hook $key 必须是布尔值');
      }
    }
    for (final key in ['stopReason', 'systemMessage', 'reason']) {
      if (value.containsKey(key) && value[key] is! String) {
        throw FormatException('hook $key 必须是字符串');
      }
    }
    if (value.containsKey('decision') && value['decision'] is! String) {
      throw const FormatException('hook decision 必须是字符串');
    }
    if (!value.containsKey('hookSpecificOutput')) return;
    final specific = value['hookSpecificOutput'];
    if (specific is! Map || specific['hookEventName'] != event) {
      throw const FormatException('hookSpecificOutput 必须匹配原始事件');
    }
    for (final key in ['additionalContext', 'permissionDecisionReason']) {
      if (specific.containsKey(key) && specific[key] is! String) {
        throw FormatException('hook $key 必须是字符串');
      }
    }
    if (specific.containsKey('updatedInput') &&
        specific['updatedInput'] is! Map) {
      throw const FormatException('hook updatedInput 必须是对象');
    }
    if (specific.containsKey('permissionDecision') &&
        !const {
          'allow',
          'deny',
          'ask',
          'defer',
        }.contains(specific['permissionDecision'])) {
      throw const FormatException('hook permissionDecision 无效');
    }
    if (event == 'PermissionRequest' && specific.containsKey('decision')) {
      final decision = specific['decision'];
      if (decision is! Map ||
          !const {'allow', 'deny'}.contains(decision['behavior']) ||
          (decision.containsKey('message') && decision['message'] is! String)) {
        throw const FormatException('hook permission decision 无效');
      }
    }
  }
}
