import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'sandbox entrypoint preserves Chinese chapter text in collected output',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'book-extraction-test-',
      );
      try {
        final result = await Process.run(
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
              (Platform.isWindows ? 'python' : 'python3'),
          [
            'official_catalog/book-to-skill/scripts/xiaoqi_extract.py',
            'test/fixtures/learning-source.md',
          ],
          environment: {'XIAOQI_BOOK_OUTPUT_DIR': output.path},
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final text = File(
          '${output.path}/book-extraction/full_text.txt',
        ).readAsStringSync();
        expect(text, contains('第一章'));
        expect(text, contains('反模式'));
        expect(text, contains('第二章'));
        expect(text, contains('先回忆，再核对'));
        expect(
          File('${output.path}/book-extraction/metadata.json').existsSync(),
          isTrue,
        );
      } finally {
        output.deleteSync(recursive: true);
      }
    },
  );
}
