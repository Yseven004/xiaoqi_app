import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:uuid/uuid.dart';

import 'public_agent_process.dart';
import 'public_reasoning_buffer.dart';

/// Redacts implementation details before model text reaches the user.
///
/// This is deliberately deterministic: a prompt rule alone is not a privacy
/// boundary because retrieved pages and tool output are untrusted input.
String sanitizeAssistantText(String text) {
  var sanitized = text;
  final patterns = <RegExp>[
    RegExp(r'(?:system\s+prompt|系统提示词|系统指令|内部提示词)', caseSensitive: false),
    RegExp(
      r'(?:api[_ -]?key|access[_ -]?key|secret|token|密码|凭据)',
      caseSensitive: false,
    ),
    RegExp(r'(?:环境变量|服务端配置|服务器配置|内部配置|内部参数)', caseSensitive: false),
    RegExp(
      r'(?:/opt/xiaoqi|/workspace|XIAOQI_[A-Z0-9_]+|DEEPSEEK_[A-Z0-9_]+)',
      caseSensitive: false,
    ),
    RegExp(r'(?:MCP\s*连接器内部|工具内部调用|内部事件|文件路径)', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    sanitized = sanitized.replaceAll(pattern, '受保护的内部信息');
  }
  // This function is called once per streamed chunk. Never trim or collapse
  // whitespace here: doing so removes Markdown newlines and can join words
  // that were split across adjacent chunks.
  return sanitized;
}

/// Publishes checked provider reasoning independently of private model history.
class AgentPresentationMiddleware extends GenerateMiddleware {
  AgentPresentationMiddleware({
    required this.preparing,
    required this.onEvent,
    this.protectedValues = const [],
  });

  final bool preparing;
  final void Function(Map<String, Object?> event) onEvent;
  final Iterable<String> protectedValues;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
    Future<ModelResponse> Function(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
    )
    next,
  ) async {
    onEvent({'type': 'thinking_started'});
    final modelStopwatch = Stopwatch()..start();
    var answerStarted = false;
    final reasoningId = const Uuid().v4();
    final reasoning = PublicReasoningBuffer(
      protectedValues: protectedValues,
      onUpdate: (text, revision, status) => onEvent({
        'type': 'reasoning_update',
        'source': 'model_reasoning',
        'reasoning_id': reasoningId,
        'revision': revision,
        'status': status,
        'text': text,
      }),
    );
    final wrapped = context.copyWith(
      sendChunk: (chunk) {
        final forwarded = <Part>[];
        for (final part in chunk.content) {
          if (context.cancel?.isCancelled == true) return;
          if (part.isReasoning) {
            reasoning.add(part.reasoning ?? '');
            continue;
          }
          if (part.isToolRequest || (!preparing && part.isText)) {
            reasoning.boundary();
          }
          if (preparing && part.isText) {
            continue;
          }
          if (part.isText) {
            final text = sanitizeAssistantText(part.text ?? '');
            if (text.isEmpty) continue;
            forwarded.add(TextPart(text: text));
          } else {
            forwarded.add(part);
          }
        }
        if (forwarded.isEmpty || context.cancel?.isCancelled == true) return;
        if (!preparing &&
            !answerStarted &&
            forwarded.any((part) => part.isText && part.text!.isNotEmpty)) {
          answerStarted = true;
          onEvent({
            'type': 'answer_started',
            'model_first_token_ms': modelStopwatch.elapsedMilliseconds,
          });
        }
        context.sendChunk(
          ModelResponseChunk(
            role: chunk.role,
            index: chunk.index,
            content: forwarded,
            custom: chunk.custom,
          ),
        );
      },
    );
    try {
      final response = await next(request, wrapped);
      reasoning.finish(
        finalText:
            response.message?.content
                .where((p) => p.isReasoning)
                .map((p) => p.reasoning ?? '')
                .join() ??
            '',
        status: context.cancel?.isCancelled == true
            ? 'stopped'
            : response.finishReason == FinishReason.stop
            ? 'completed'
            : 'incomplete',
      );
      return response;
    } on Object {
      reasoning.finish(
        status: context.cancel?.isCancelled == true ? 'stopped' : 'incomplete',
      );
      rethrow;
    }
  }

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> context,
    Future<ToolResult> Function(
      ToolRequestPart request,
      ActionFnArg<void, dynamic, void> context,
    )
    next,
  ) => runZoned(() async {
    final tool = request.toolRequest.name.split('/').last;
    onEvent({'type': 'tool_requested', 'tool': tool});
    try {
      final result = await next(request, context);
      var status = result.hasInterrupt ? 'waiting' : 'completed';
      if (result.hasResponse) {
        Object? output = result.output;
        if (output is String) {
          try {
            output = jsonDecode(output);
          } on FormatException {
            // Plain text is a valid tool result.
          }
        }
        if (output is Map) {
          final resultStatus = output['status']?.toString() ?? '';
          if (output['isError'] == true ||
              output['error'] != null ||
              const {
                'error',
                'failed',
                'blocked',
                'invalid_query',
                'script_error',
                'invalid_input',
                'unavailable',
              }.contains(resultStatus))
            status = 'failed';
          if (resultStatus == 'budget_exhausted') status = 'skipped';
          if (resultStatus == 'awaiting_network_permission') status = 'waiting';
        }
      }
      onEvent({'type': 'tool_returned', 'tool': tool, 'status': status});
      return result;
    } on Object {
      onEvent({
        'type': context.cancel?.isCancelled == true
            ? 'tool_cancelled'
            : 'tool_failed',
        'tool': tool,
      });
      rethrow;
    }
  }, zoneValues: {publicProcessInvocation: Object()});
}
