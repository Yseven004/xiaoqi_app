import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:schemantic/schemantic.dart';

/// Run with `genkit flow:run verifyToolPermissions '"all"' -- dart run ...`.
/// Uses local model/MCP fixtures, never production accounts or provider keys.
void main() {
  final ai = Genkit(promptDir: null);
  ai.defineFlow(
    name: 'verifyToolPermissions',
    inputSchema: SchemanticType.string(),
    outputSchema: SchemanticType.from<Map<String, dynamic>>(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'scenario': {'type': 'string'},
          'passed': {'type': 'boolean'},
          'summary': {'type': 'string'},
        },
        'required': ['scenario', 'passed', 'summary'],
        'additionalProperties': false,
      },
      parse: (json) => Map<String, dynamic>.from(json as Map),
    ),
    fn: (scenario, _) async {
      if (!const {
        'all',
        'authorization',
        'mcp-read',
        'mcp-large',
        'mcp-success',
        'mcp-error',
        'mcp-approved-repeat',
        'mcp-denied',
        'mcp-disabled',
        'mcp-reconfigured',
        'mcp-argument-change',
        'text-only-shell',
        'text-only-search',
      }.contains(scenario)) {
        throw const FormatException('Unknown verification scenario');
      }
      final result = await Process.run(Platform.resolvedExecutable, [
        'test',
        'test/capability_runtime_test.dart',
        '--name',
        switch (scenario) {
          'all' => '^(mcp-|text-only-(shell|search) )',
          'authorization' =>
            '^mcp-(approved-repeat|denied|disabled|reconfigured|argument-change) ',
          _ => '^$scenario ',
        },
        '--reporter',
        'expanded',
      ]);
      final output = '${result.stdout}\n${result.stderr}';
      if (result.exitCode != 0 || !output.contains('All tests passed!')) {
        final tail = output.length > 3000
            ? output.substring(output.length - 3000)
            : output;
        throw StateError('Tool permission verification failed: $tail');
      }
      return {
        'scenario': scenario,
        'passed': true,
        'summary': const LineSplitter()
            .convert(output)
            .firstWhere((line) => line.contains('All tests passed!')),
      };
    },
  );
}
