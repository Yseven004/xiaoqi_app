import 'dart:async';
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
  test(
    'a failed continuation restarts discovery without retaining an old prefix',
    () async {
      var starts = 0;
      final requested = <String?>[];
      final tools = await listAllMcpTools((cursor) async {
        requested.add(cursor);
        if (cursor == null) {
          starts++;
          return {
            'tools': [tool(starts)],
            'nextCursor': starts == 1 ? 'expired' : 'current',
          };
        }
        if (cursor == 'expired') throw StateError('cursor expired');
        return {
          'tools': [tool(3)],
        };
      });
      expect(requested, [null, 'expired', null, 'current']);
      expect(tools.map((entry) => entry['name']), ['fetch_2', 'fetch_3']);
    },
  );

  test(
    'malformed catalog shapes fail instead of silently hiding tools',
    () async {
      for (final page in <Map<String, dynamic>>[
        {},
        {'tools': 'invalid'},
        {
          'tools': [null],
        },
        {
          'tools': [
            {...tool(0), 'name': ' fetch_0'},
          ],
        },
        {
          'tools': [
            {...tool(0), 'inputSchema': 'invalid'},
          ],
        },
        {
          'tools': [tool(0)],
          'nextCursor': 42,
        },
      ]) {
        await expectLater(
          listAllMcpTools((_) async => page),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'duplicate names during paging recover only from a clean whole snapshot',
    () async {
      var starts = 0;
      final tools = await listAllMcpTools((cursor) async {
        if (cursor == null) starts++;
        return {
          'tools': [tool(cursor == null || starts == 1 ? 0 : 1)],
          if (cursor == null) 'nextCursor': 'next',
        };
      });
      expect(starts, 2);
      expect(tools.map((entry) => entry['name']), ['fetch_0', 'fetch_1']);
      var calls = 0;
      await expectLater(
        listAllMcpTools((_) async {
          calls++;
          return {
            'tools': [tool(0), tool(0)],
          };
        }),
        throwsStateError,
      );
      expect(calls, 2);
    },
  );

  test(
    'a notification during discovery cannot publish a mixed old catalog',
    () async {
      var reads = 0;
      late LiveMcpToolDirectory live;
      live = LiveMcpToolDirectory(() async {
        reads++;
        if (reads == 1) live.invalidate();
        return [tool(reads)];
      });
      final current = await live.load();
      expect(reads, 2);
      expect(current.lookup('fetch_1'), isNull);
      expect(current.lookup('fetch_2'), isNotNull);
      expect(live.stale, false);
      expect(live.revision, 1);
      expect(await live.load(), same(current));
      expect(reads, 2);
    },
  );

  test(
    'failed refresh stays stale and concurrent reads share a complete recovery',
    () async {
      var mode = 'initial';
      final delayed = Completer<List<Map<String, dynamic>>>();
      var reads = 0;
      final live = LiveMcpToolDirectory(() async {
        reads++;
        if (mode == 'fail') throw StateError('temporary failure');
        if (mode == 'recover') return await delayed.future;
        return [tool(0)];
      });
      await live.load();
      mode = 'fail';
      await expectLater(live.load(force: true), throwsStateError);
      expect(live.stale, true);
      mode = 'recover';
      final first = live.load();
      final second = live.load(force: true);
      delayed.complete([tool(1)]);
      expect((await first).lookup('fetch_1'), isNotNull);
      expect(await second, same(await first));
      expect(reads, 3);
      expect(live.stale, false);
      expect(live.revision, 2);
    },
  );

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
