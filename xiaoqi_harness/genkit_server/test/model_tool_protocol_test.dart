import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/model_tool_protocol.dart';

void main() {
  test('DSML and its parameters never escape at any stream split', () {
    for (final delimiter in ['｜', '|']) {
      final wire =
          '<${delimiter}DSML$delimiter'
          'calls>\n'
          '<${delimiter}DSML$delimiter'
          'invoke name="set_task_deliverables">'
          'private backend arguments</${delimiter}DSML$delimiter'
          'invoke>';
      for (var split = 0; split <= wire.length; split++) {
        final buffer = ModelToolProtocolBuffer();
        final text =
            buffer.add(wire.substring(0, split)) +
            buffer.add(wire.substring(split)) +
            buffer.finish();
        expect(text, isEmpty, reason: 'split=$split');
        expect(buffer.sawProtocol, isTrue);
      }
    }
  });

  test('normal Markdown, HTML, math and whitespace retain every character', () {
    const prose = '## 标题\n\n中文 A < B\n<tag>内容</tag>\n末尾 <';
    final buffer = ModelToolProtocolBuffer();
    final output = StringBuffer();
    for (final character in prose.split('')) {
      output.write(buffer.add(character));
    }
    output.write(buffer.finish());
    expect(output.toString(), prose);
    expect(buffer.sawProtocol, isFalse);
  });

  test('truncated protocol prefixes remain private at the end', () {
    final buffer = ModelToolProtocolBuffer();
    expect(buffer.add('正文\n<｜DSM'), '正文\n');
    expect(buffer.finish(), isEmpty);
    expect(buffer.sawProtocol, isTrue);
  });
}
