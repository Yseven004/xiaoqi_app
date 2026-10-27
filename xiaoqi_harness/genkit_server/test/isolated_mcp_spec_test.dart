import 'dart:convert';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';

void main() {
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
