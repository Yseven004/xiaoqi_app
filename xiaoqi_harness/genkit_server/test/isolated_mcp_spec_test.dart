import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';

void main() {
  test(
    'uvx registry declarations prepare pinned dependencies and literal argv',
    () {
      final config = {
        'command': 'uvx',
        'args': [
          '--from',
          'example-mcp[cli]>=1.2,<2',
          '--with',
          'helper-lib==3.0',
          'example-server',
          '--query',
          r'literal; $(no-shell)',
        ],
      };
      final prepared = IsolatedMcpSpec.installationFiles(config, {
        'requirements.txt': utf8.encode('existing==1.0'),
      });
      expect(
        utf8.decode(prepared['requirements.txt']!),
        'existing==1.0\nexample-mcp[cli]>=1.2,<2\nhelper-lib==3.0\n',
      );
      final spec = IsolatedMcpSpec.resolve(config, {
        ...prepared,
        '.xiaoqi/python/example_mcp-1.5.dist-info/METADATA': utf8.encode(
          'Name: Example_MCP\nVersion: 1.5\n',
        ),
      });
      expect(spec.command.sublist(3), [
        'example-mcp',
        'example-server',
        '--query',
        r'literal; $(no-shell)',
      ]);
      expect(spec.command.take(2), ['python3', '-c']);
      expect(
        () => IsolatedMcpSpec.resolve(config, prepared),
        throwsFormatException,
      );
    },
  );

  test('uv tool run and uvx versions share installation mapping', () {
    for (final command in [
      {
        'command': 'uvx',
        'args': ['server@1.2.3', '--flag'],
      },
      {
        'command': 'uv',
        'args': ['tool', 'run', 'server@1.2.3', '--flag'],
      },
    ]) {
      final tool = IsolatedMcpSpec.pythonTool(command)!;
      expect(tool.requirements, ['server==1.2.3']);
      expect(tool.arguments, ['--flag']);
      expect(tool.executable, 'server');
    }
    expect(
      IsolatedMcpSpec.pythonTool({
        'command': 'uvx',
        'args': ['server@latest'],
      })!.requirements,
      ['server'],
    );
  });

  test(
    'Python tool download sources and unmapped options cannot reach startup',
    () {
      for (final args in [
        ['--from', 'https://example.com/tool.whl', 'server'],
        ['--from', '../local', 'server'],
        ['--from', 'server;bad', 'server'],
        ['--python', '3.13', 'server'],
        ['--from', 'server', '--from', 'other', 'server'],
        ['--from', 'server', 'server@2'],
        ['--from'],
        <String>[],
      ]) {
        expect(
          () => IsolatedMcpSpec.installationFiles({
            'command': 'uvx',
            'args': args,
          }, {}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'installed Python console launcher executes entry and preserves argv',
    () async {
      final root = await Directory.systemTemp.createTemp('xiaoqi-python-mcp-');
      try {
        final metadata = Directory(
          '${root.path}/xiaoqi_fixture_tool-1.0.dist-info',
        )..createSync();
        File(
          '${metadata.path}/METADATA',
        ).writeAsStringSync('Name: xiaoqi-fixture-tool\nVersion: 1.0\n');
        File('${metadata.path}/entry_points.txt').writeAsStringSync(
          '[console_scripts]\nfixture-server = fixture_module:main\n',
        );
        File('${root.path}/fixture_module.py').writeAsStringSync(
          'import sys, json\ndef main():\n    print(json.dumps(sys.argv))\n    return 0\n',
        );
        final result = await Process.run(
          Platform.environment['XIAOQI_TEST_PYTHON'] ?? 'python3',
          [
            '-c',
            IsolatedMcpSpec.pythonToolLauncher,
            'xiaoqi-fixture-tool',
            'fixture-server',
            r'literal; $(no-shell)',
            '中文',
          ],
          environment: {
            'PYTHONPATH': root.path,
            'PYTHONDONTWRITEBYTECODE': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(jsonDecode(result.stdout as String), [
          'fixture-server',
          r'literal; $(no-shell)',
          '中文',
        ]);
        final missing = await Process.run(
          Platform.environment['XIAOQI_TEST_PYTHON'] ?? 'python3',
          [
            '-c',
            IsolatedMcpSpec.pythonToolLauncher,
            'xiaoqi-fixture-tool',
            'missing',
          ],
          environment: {
            'PYTHONPATH': root.path,
            'PYTHONDONTWRITEBYTECODE': '1',
          },
        );
        expect(missing.exitCode, isNot(0));
        expect(missing.stderr, contains('no unique console entry'));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'registry command is resolved to its installed entry and isolated root',
    () {
      final config = {
        'command': 'npx',
        'args': [
          '-y',
          '@example/server@2.0.1',
          r'${CLAUDE_PLUGIN_ROOT}/data',
          r'literal; $(no-host-shell)',
        ],
      };
      final prepared = IsolatedMcpSpec.installationFiles(config, {});
      expect(
        (jsonDecode(utf8.decode(prepared['package.json']!))
            as Map)['dependencies'],
        {'@example/server': '2.0.1'},
      );
      final spec = IsolatedMcpSpec.resolve(config, {
        ...prepared,
        'node_modules/@example/server/package.json': utf8.encode(
          '{"version":"2.0.1","bin":{"mcp-server":"dist/index.js"}}',
        ),
        'node_modules/@example/server/dist/index.js': utf8.encode('// fixture'),
      });
      expect(spec.command, [
        'node',
        '/workspace/skill/node_modules/@example/server/dist/index.js',
        '/workspace/skill/data',
        r'literal; $(no-host-shell)',
      ]);
    },
  );

  test(
    'missing user configuration never falls back to API process secrets',
    () {
      expect(
        () => IsolatedMcpSpec.resolve({
          'command': 'node',
          'args': ['server.js'],
          'env': {'TOKEN': r'${PRIVATE_TOKEN}'},
        }, {}),
        throwsFormatException,
      );
    },
  );

  test(
    'registry entry cannot escape package root and URL packages are rejected',
    () {
      final config = {
        'command': 'npx',
        'args': ['@example/server@2.0.1'],
      };
      expect(
        () => IsolatedMcpSpec.resolve(config, {
          'node_modules/@example/server/package.json': utf8.encode(
            '{"bin":"../outside.js"}',
          ),
          'node_modules/@example/outside.js': utf8.encode('// outside'),
        }),
        throwsFormatException,
      );
      expect(
        () => IsolatedMcpSpec.npmDependency({
          'command': 'npx',
          'args': ['https://example.com/script.tgz'],
        }),
        throwsFormatException,
      );
    },
  );
}
