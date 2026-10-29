import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'hard process death after native effect preserves original result without executing it again',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'hook-process-restart-',
      );
      Process? first, second;
      final args = [
        '--disable-dart-dev',
        '--packages=.dart_tool/package_config.json',
        'test/support/plugin_hook_restart_fixture.dart',
        root.path,
      ];
      try {
        first = await Process.start(Platform.resolvedExecutable, [
          ...args,
          'start',
        ]);
        final errors = first.stderr.transform(utf8.decoder).join();
        await first.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line == 'NATIVE_CHECKPOINT_READY')
            .timeout(const Duration(seconds: 45));
        first.kill();
        await first.exitCode.timeout(const Duration(seconds: 15));
        expect(await errors, isEmpty);
        second = await Process.start(Platform.resolvedExecutable, [
          ...args,
          'recover',
        ]);
        final output = second.stdout.transform(utf8.decoder).join();
        final stderr = second.stderr.transform(utf8.decoder).join();
        expect(
          await second.exitCode.timeout(const Duration(seconds: 45)),
          0,
          reason: await stderr,
        );
        final line = (await output)
            .split('\n')
            .singleWhere((l) => l.startsWith('RESULT:'));
        final result = jsonDecode(line.substring(7)) as Map;
        expect(result['effects'], 1);
        expect(result['response']['output'], 'original native result');
        expect(result['response']['metadata'], {'proof': 'original'});
        expect(result['response']['content'].single['text'], '原始结果');
      } finally {
        first?.kill();
        second?.kill();
        if (first != null) await first.exitCode;
        if (second != null) await second.exitCode;
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
