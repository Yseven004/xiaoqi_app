import 'dart:convert';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';

void main() {
  test(
    'exec args are validated per handler without dropping healthy siblings',
    () {
      final parsed = PluginHooks.parse({}, {
        'hooks': {
          'PreToolUse': [
            {
              'hooks': [
                {
                  'type': 'command',
                  'command': 'python3',
                  'args': ['-c', 'print(1)', '中文'],
                },
                {'type': 'command', 'command': 'node', 'args': []},
                for (final args in [
                  null,
                  'one string',
                  [7],
                  ['bad\u0000argument'],
                  List.filled(65, 'x'),
                ])
                  {'type': 'command', 'command': 'node', 'args': args},
              ],
            },
          ],
        },
      }, manifestPath: '.claude-plugin/plugin.json');
      expect(parsed.handlers, hasLength(2));
      expect(parsed.issues, hasLength(5));
      expect(parsed.handlers.first.config['args'], ['-c', 'print(1)', '中文']);
    },
  );

  const manifestPath = '.claude-plugin/plugin.json';
  List<int> encoded(Object value) => utf8.encode(jsonEncode(value));
  Map<String, dynamic> events(
    String event,
    Object handler, {
    String? matcher,
  }) => {
    event: [
      {
        'matcher': matcher,
        'hooks': [handler],
      },
    ],
  };
  const command = {
    'type': 'command',
    'command': r'python3 "${CLAUDE_PLUGIN_ROOT}/guard.py"',
  };

  test(
    'default, file and inline hooks merge in order without duplicate source execution identities',
    () {
      final catalog = PluginHooks.parse(
        {
          'hooks/hooks.json': encoded({
            'hooks': events('PreToolUse', command, matcher: 'Write|Edit'),
          }),
          'config/extra.json': encoded({
            'hooks': events('Stop', {
              'type': 'prompt',
              'prompt': 'Check completion',
            }),
          }),
        },
        {
          'hooks': [
            './hooks/hooks.json',
            './config/extra.json',
            events('PostToolUse', {
              'type': 'command',
              'command': 'check-result',
              'timeout': 180,
              'asyncRewake': true,
            }),
          ],
        },
        manifestPath: manifestPath,
      );
      expect(catalog.issues, isEmpty);
      expect(catalog.handlers.map((h) => h.event), [
        'PreToolUse',
        'Stop',
        'PostToolUse',
      ]);
      expect(catalog.handlers.map((h) => h.sourcePath), [
        'hooks/hooks.json',
        'config/extra.json',
        manifestPath,
      ]);
      expect(catalog.handlers.map((h) => h.id).toSet(), hasLength(3));
      expect(catalog.handlers.first.config['command'], command['command']);
      expect(catalog.handlers.last.config['timeout'], 180);
      expect(catalog.handlers.last.config['asyncRewake'], true);
    },
  );

  test(
    'malformed auxiliary declarations cannot hide healthy handlers or escape the package',
    () {
      final catalog = PluginHooks.parse(
        {
          'hooks/hooks.json': encoded({'hooks': events('PreToolUse', command)}),
          'bad.json': utf8.encode('{invalid'),
        },
        {
          'hooks': [
            './bad.json',
            './../outside.json',
            './missing.json',
            42,
            {
              'PostToolUse': [
                {
                  'hooks': [
                    {'type': 'command'},
                    {'type': 'command', 'command': 'healthy'},
                  ],
                },
              ],
            },
          ],
        },
        manifestPath: manifestPath,
      );
      expect(catalog.handlers.map((h) => h.event), [
        'PreToolUse',
        'PostToolUse',
      ]);
      expect(catalog.issues, hasLength(5));
      expect(catalog.issues.every((i) => i.reason.isNotEmpty), true);
    },
  );

  test(
    'file wrapper and inline event maps stay distinct and unsupported types remain inspectable',
    () {
      final catalog = PluginHooks.parse(
        {'bare.json': encoded(events('PreToolUse', command))},
        {
          'hooks': [
            './bare.json',
            {'hooks': events('PostToolUse', command)},
            events('FutureEvent', {
              'type': 'future-host-handler',
              'config': {'scope': 'own'},
            }),
          ],
        },
        manifestPath: manifestPath,
      );
      expect(catalog.issues, hasLength(2));
      expect(catalog.handlers.single.type, 'future-host-handler');
      expect(catalog.handlers.single.event, 'FutureEvent');
      expect(catalog.handlers.single.config['config'], {'scope': 'own'});
      expect(
        () => catalog.handlers.single.config['type'] = 'command',
        throwsUnsupportedError,
      );
      expect(
        () => (catalog.handlers.single.config['config'] as Map)['scope'] =
            'other',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'matcher text is preserved without evaluating potentially expensive source regular expressions',
    () {
      final catalog = PluginHooks.parse({}, {
        'hooks': events('PreToolUse', command, matcher: r'(a+)+$'),
      }, manifestPath: manifestPath);
      expect(catalog.issues, isEmpty);
      expect(catalog.handlers.single.matcher, r'(a+)+$');
      final same = PluginHooks.parse({}, {
        'hooks': events('PreToolUse', command, matcher: r'(a+)+$'),
      }, manifestPath: manifestPath);
      expect(catalog.handlers.single.id, same.handlers.single.id);
    },
  );

  test(
    'invalid handler timeout/flags stay local and metadata sizes are bounded',
    () {
      final catalog = PluginHooks.parse(
        {'hooks/hooks.json': List.filled(PluginHooks.maxConfigBytes + 1, 32)},
        {
          'hooks': {
            'PreToolUse': [
              {
                'hooks': [
                  {...command, 'timeout': 0},
                  {...command, 'once': 'yes'},
                  {...command, 'timeout': 1.5, 'once': true},
                ],
              },
            ],
          },
        },
        manifestPath: manifestPath,
      );
      expect(catalog.issues, hasLength(3));
      expect(catalog.handlers, hasLength(1));
      expect(catalog.handlers.single.config['timeout'], 1.5);
    },
  );
  test('an explicitly missing default file reports its declaration', () {
    final catalog = PluginHooks.parse({}, {
      'hooks': './hooks/hooks.json',
    }, manifestPath: manifestPath);
    expect(catalog.handlers, isEmpty);
    expect(catalog.issues, hasLength(1));
    expect(catalog.issues.single.sourcePath, 'hooks/hooks.json');
  });
}
