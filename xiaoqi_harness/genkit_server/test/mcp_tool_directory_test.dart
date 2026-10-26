import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_tool_directory.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';

Map<String, dynamic> tool(int index) => {
  'name': 'fetch_$index',
  'description': 'Retrieve record $index',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
    },
    'required': ['id'],
    'additionalProperties': false,
  },
};

void main() {
  test('discovers and searches tools beyond both old count limits', () async {
    final cursors = <String?>[];
    final tools = await listAllMcpTools((cursor) async {
      cursors.add(cursor);
      return {
        'tools': [
          for (
            var i = cursor == null ? 0 : 120;
            i < (cursor == null ? 120 : 240);
            i++
          )
            tool(i),
        ],
        if (cursor == null) 'nextCursor': 'second',
      };
    });
    expect(cursors, [null, 'second']);
    expect(tools, hasLength(240));
    final directory = McpToolDirectory(tools);
    final match = directory.search('fetch_239');
    expect((match['tools'] as List).single['name'], 'fetch_239');
    expect(
      (match['tools'] as List).single['inputSchema'],
      tool(239)['inputSchema'],
    );
    expect(directory.lookup('fetch_0'), isNotNull);
    expect(directory.lookup('other_connector_tool'), isNull);
    final first = directory.search('', limit: 8);
    final second = directory.search(
      '',
      offset: first['next_offset'] as int,
      limit: 8,
    );
    expect(first['total'], 240);
    expect(first['tools'], hasLength(8));
    expect(second['tools'], hasLength(8));
    expect(
      (first['tools'] as List)
          .map((t) => t['name'])
          .toSet()
          .intersection(
            (second['tools'] as List).map((t) => t['name']).toSet(),
          ),
      isEmpty,
    );
  });

  test('rejects ambiguous names and repeating pagination cursors', () async {
    expect(() => McpToolDirectory([tool(1), tool(1)]), throwsFormatException);
    await expectLater(
      listAllMcpTools(
        (_) async => {
          'tools': [tool(1)],
          'nextCursor': 'again',
        },
      ),
      throwsStateError,
    );
    expect(
      () => McpToolDirectory([tool(1)]).search('', offset: -1),
      throwsFormatException,
    );
  });
}
