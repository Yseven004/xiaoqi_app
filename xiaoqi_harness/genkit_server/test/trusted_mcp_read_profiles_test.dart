import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';
import 'package:xiaoqi_genkit_server/src/trusted_mcp_read_profiles.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'repoName': {'type': 'string', 'description': 'GitHub owner/repo'},
    },
    'required': ['repoName'],
  };
  const questionSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'repoName': {
        'anyOf': [
          {'type': 'string'},
          {
            'type': 'array',
            'items': {'type': 'string'},
          },
        ],
      },
      'question': {'type': 'string'},
    },
    'required': ['repoName', 'question'],
  };
  late Directory root;
  late CloudStore store;
  late McpConnectionService service;
  McpConnectionCredentials connection({
    String url = 'https://mcp.deepwiki.com/mcp',
    String? token,
    String? catalogId,
  }) => McpConnectionCredentials(
    id: 'selected',
    name: 'Public docs',
    url: Uri.parse(url),
    bearerToken: token,
    catalogId: catalogId,
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-read-profile-');
    store = CloudStore(root: root.path);
    service = McpConnectionService(store);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'reviewed public reads allow normal calls without inventing a user approval',
    () {
      for (final tool in ['read_wiki_structure', 'read_wiki_contents']) {
        final effect = service.effectFor(
          connection(),
          tool,
          inputSchema: schema,
          arguments: {'repoName': 'firebase/genkit'},
        );
        expect(effect, ToolEffect.read);
        expect(
          ToolAccessPolicy.decide(effect: effect),
          ToolAccessDecision.allow,
        );
      }
      expect(
        service.authorizationBinding(connection())['read_profile_version'],
        TrustedMcpReadProfiles.version,
      );
      expect(
        service.effectFor(connection(), 'read_wiki_structure'),
        ToolEffect.unknown,
        reason: 'A tool name alone cannot prove the reviewed interface',
      );
    },
  );

  test(
    'question queries accept only the reviewed schema and public repository parameters',
    () {
      for (final repos in [
        'firebase/genkit',
        ['firebase/genkit', 'dart-lang/sdk'],
      ]) {
        expect(
          service.effectFor(
            connection(),
            'ask_wiki_question',
            inputSchema: questionSchema,
            arguments: {
              'repoName': repos,
              'question': 'What is the project for?',
            },
          ),
          ToolEffect.read,
        );
      }
      expect(
        service.effectFor(
          connection(),
          'ask_wiki_question',
          inputSchema: questionSchema,
          arguments: {
            'repoName': List.filled(11, 'firebase/genkit'),
            'question': 'Read',
          },
        ),
        ToolEffect.unknown,
      );
    },
  );

  test(
    'credentials, other origins, query parameters and unknown catalogs do not borrow the public profile',
    () {
      for (final selected in [
        connection(token: 'private-account-token'),
        connection(catalogId: 'other'),
        connection(url: 'https://mcp.deepwiki.com.evil.example/mcp'),
        connection(url: 'https://mcp.deepwiki.com/another'),
        connection(url: 'https://mcp.deepwiki.com/mcp?account=private'),
        connection(url: 'https://mcp.deepwiki.com:444/mcp'),
      ]) {
        expect(
          service.effectFor(
            selected,
            'read_wiki_structure',
            inputSchema: schema,
            arguments: {'repoName': 'firebase/genkit'},
          ),
          ToolEffect.unknown,
        );
        expect(
          service
              .authorizationBinding(selected)
              .containsKey('read_profile_version'),
          false,
        );
      }
    },
  );

  test(
    'new schema fields, extra arguments, renamed tools and hints stay unknown',
    () {
      final changed = {
        ...schema,
        'properties': {
          ...(schema['properties'] as Map),
          'delete': {'type': 'boolean'},
        },
      };
      expect(
        service.effectFor(
          connection(),
          'read_wiki_structure',
          inputSchema: changed,
          arguments: {'repoName': 'firebase/genkit'},
        ),
        ToolEffect.unknown,
      );
      expect(
        service.effectFor(
          connection(),
          'read_wiki_structure',
          inputSchema: schema,
          arguments: {'repoName': 'firebase/genkit', 'delete': true},
        ),
        ToolEffect.unknown,
      );
      expect(
        service.effectFor(
          connection(),
          'delete_repo',
          inputSchema: schema,
          arguments: {'repoName': 'firebase/genkit'},
        ),
        ToolEffect.unknown,
      );
      expect(
        service.effectFor(
          connection(),
          'read_wiki_structure',
          inputSchema: {
            ...schema,
            'annotations': {'readOnlyHint': true},
          },
          arguments: {'repoName': 'firebase/genkit'},
        ),
        ToolEffect.unknown,
      );
    },
  );
}
