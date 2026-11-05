import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:path/path.dart' as p;

/// Stdio adapter to the pinned, unmodified @genkit-ai/middleware package.
/// Compression policy and history metadata are owned by that package.
class OfficialContextCompression {
  const OfficialContextCompression({required this.summarize});

  final Future<String> Function(String prompt, CancellationToken? cancel)
  summarize;

  Future<({List<Message> history, List<Message> messages})> compress(
    List<Message> messages, {
    CancellationToken? cancel,
    int maxInputTokens = 80000,
  }) async {
    cancel?.throwIfCancelled();
    final script =
        Platform.environment['XIAOQI_CONTEXT_COMPRESSION_PATH'] ??
        p.join(Directory.current.path, 'context_compression', 'compress.mjs');
    final process = await Process.start(
      Platform.environment['XIAOQI_NODE_PATH'] ?? 'node',
      ['--max-old-space-size=192', script],
      includeParentEnvironment: false,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '',
        if (Platform.environment['SystemRoot'] case final String root)
          'SystemRoot': root,
        'GENKIT_ENV': 'prod',
      },
    );
    final timeout = Timer(const Duration(minutes: 3), () => process.kill());
    if (cancel != null) {
      unawaited(cancel.whenCancelled.then((_) => process.kill()));
    }
    // Official middleware diagnostics may contain provider error details; they
    // do not belong in public events or the host's general logs.
    final errors = process.stderr.drain<void>();
    try {
      process.stdin.writeln(
        jsonEncode({
          'messages': messages.map((message) => message.toJson()).toList(),
          'maxInputTokens': maxInputTokens,
        }),
      );
      Map? result;
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        cancel?.throwIfCancelled();
        final value = jsonDecode(line) as Map;
        if (value['type'] == 'summarize') {
          try {
            final text = await summarize(value['prompt'] as String, cancel);
            cancel?.throwIfCancelled();
            process.stdin.writeln(jsonEncode({'text': text}));
          } on Object {
            cancel?.throwIfCancelled();
            process.stdin.writeln(jsonEncode({'error': true}));
          }
        } else if (value['type'] == 'result') {
          result = value;
        } else if (value['type'] == 'error') {
          throw StateError('官方上下文压缩组件运行失败，执行已停止。');
        }
      }
      final exitCode = await process.exitCode;
      await errors;
      cancel?.throwIfCancelled();
      if (exitCode != 0 || result == null) {
        throw StateError('官方上下文压缩组件未返回有效结果，执行已停止。');
      }
      List<Message> decode(Object? value) => (value as List)
          .map(
            (message) =>
                Message.fromJson(Map<String, dynamic>.from(message as Map)),
          )
          .toList();
      return (
        history: decode(result['history']),
        messages: decode(result['messages']),
      );
    } finally {
      timeout.cancel();
      process.kill();
    }
  }
}
