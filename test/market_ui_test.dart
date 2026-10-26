import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiaoqi_app/features/capabilities/presentation/market_ui.dart';

void main() {
  test('Android import filters archive families without widening upload rules', () {
    const policy = <String, dynamic>{
      'upload_extensions': ['zip', 'tgz', 'tar.gz', 'skill', 'md'],
      'max_archive_bytes': 2097152,
    };
    final plugin = marketAndroidPickerExtensions(skill: false, policy: policy);
    expect(plugin, containsAll(['zip', 'gz', 'tgz', 'skill']));
    expect(plugin, isNot(contains('md')));
    expect(plugin, isNot(contains('txt')));
    expect(plugin, isNot(contains('*')));
    expect(plugin, isNot(contains('*/*')));
    expect(plugin, isNot(contains('pdf')));
    final skill = marketAndroidPickerExtensions(skill: true, policy: policy);
    expect(skill, containsAll(['md', 'markdown']));
    expect(skill, isNot(contains('txt')));
    for (final name in ['image.png', 'video.mp4', 'book.pdf', 'notes.txt', 'data.gz']) {
      expect(validateMarketUpload(name: name, size: 100, skill: true, policy: policy), isNotNull);
    }
    expect(validateMarketUpload(name: 'SKILL.md', size: 100, skill: true, policy: policy), isNull);
    expect(validateMarketUpload(name: 'plugin.tar.gz', size: 100, skill: false, policy: policy), isNull);
    expect(marketAndroidPickerExtensions(skill: false,
      policy: const {'upload_extensions': ['skill']}), ['skill', 'zip']);
    expect(marketAndroidPickerExtensions(skill: true, policy: null), isEmpty);
    expect(marketAndroidPickerExtensions(skill: true,
      policy: const {'upload_extensions': ['unknown']}), isEmpty);
  });

  testWidgets('one market entry starts in the first column', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        key: ValueKey('market-grid-region'),
        width: 800,
        child: Column(children: [MarketGrid(children: [
          SizedBox(key: ValueKey('market-first-entry'), height: 80),
        ])]),
      ))),
    ));
    final region = tester.getRect(find.byKey(const ValueKey('market-grid-region')));
    final entry = tester.getRect(find.byKey(const ValueKey('market-first-entry')));
    expect(entry.left, region.left);
    expect(entry.width, (region.width - 36) / 2);
  });

  test(
    'upload picker extensions follow the server policy by capability kind',
    () {
      const policy = <String, dynamic>{
        'upload_extensions': ['.zip', 'tgz', 'tar.gz', 'skill', 'md', 'ZIP'],
        'max_archive_bytes': 2097152,
      };
      expect(marketUploadExtensions(skill: true, policy: policy), [
        'zip',
        'tgz',
        'tar.gz',
        'skill',
        'md',
      ]);
      expect(marketUploadExtensions(skill: false, policy: policy), [
        'zip',
        'tgz',
        'tar.gz',
        'skill',
      ]);
      expect(marketUploadExtensions(skill: true, policy: null), isEmpty);
    },
  );

  test(
    'upload gate rejects format, empty files and size before acceptance',
    () {
      String? validate(String name, int size, {bool skill = true}) =>
          validateMarketUpload(
            name: name,
            size: size,
            skill: skill,
            policy: {
              'upload_extensions': ['md', 'zip', 'tgz', 'tar.gz'],
              'max_archive_bytes': 2097152,
            },
          );
      expect(validate('photo.jpg', 100), contains('不支持此文件格式'));
      expect(validate('SKILL.md', 100, skill: false), contains('插件压缩包'));
      expect(validate('empty.zip', 0), contains('文件为空'));
      expect(validate('large.zip', 3145728), contains('3 MB，超过 2 MB'));
      expect(validate('SKILL.md', 100), isNull);
      expect(validate('plugin.TAR.GZ', 2097152, skill: false), isNull);
      expect(validate('plugin.zip.exe', 100), isNotNull);
      expect(
        validateMarketUpload(
          name: 'skill.zip',
          size: 100,
          skill: true,
          policy: null,
        ),
        contains('无法取得上传限制'),
      );
    },
  );

  test('formats upload sizes without a misleading 0.0 MB value', () {
    expect(formatMarketFileSize(0), '0 B');
    expect(formatMarketFileSize(1536), '1.5 KB');
    expect(formatMarketFileSize(2 * 1024 * 1024), '2 MB');
  });

  test('MCP URLs require an HTTPS host without embedded query credentials', () {
    expect(validateMcpServerUrl('https://mcp.example.com'), isNull);
    expect(validateMcpServerUrl('http://mcp.example.com'), isNotNull);
    expect(
      validateMcpServerUrl('https://user:pass@mcp.example.com'),
      isNotNull,
    );
    expect(
      validateMcpServerUrl('https://mcp.example.com?token=secret'),
      isNotNull,
    );
  });
}
