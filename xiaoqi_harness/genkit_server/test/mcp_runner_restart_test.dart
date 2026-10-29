import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/sandbox_mcp_transport.dart';
import 'package:xiaoqi_genkit_server/src/mcp_rpc_journal.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  for (final journaled in [false, true]) {
    test(
      'pending real SDK call survives HTTP and durable registry restart; API journal=$journaled',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'mcp-runner-restart-',
        );
        final process = await Process.start(
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
              (Platform.isWindows ? 'python' : 'python3'),
          ['-u', 'test/support/mcp_runner_restart_fixture.py', root.path],
        );
        final errors = StringBuffer();
        final stderr = process.stderr
            .transform(utf8.decoder)
            .listen(errors.write);
        final lines = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        GenkitMcpClient? client;
        final store = CloudStore(root: '${root.path}/api');
        store.put('task/t/task', {'artifacts': []}, null);
        late McpRpcJournal journal;
        try {
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          final port = (jsonDecode(lines.current) as Map)['port'];
          final transport = await SandboxMcpTransport.connect(
            runnerUrl: Uri.parse('http://127.0.0.1:$port'),
            runnerToken: 'fixture',
            request: {'task_id': 'original-task'},
            cancellation: CancellationController().token,
            beforeStart: journaled
                ? (identity) {
                    final lease = identity['lease_id'] as String;
                    store.put(
                      'private_mcp_lease/t/task/$lease',
                      identity,
                      null,
                    );
                    journal = McpRpcJournal(
                      store,
                      't',
                      'task',
                      lease,
                      limit: 128,
                    );
                  }
                : null,
            beforeSend: journaled
                ? (message, sequence) => journal.beforeSend(message, sequence)
                : null,
            onEventBatch: journaled
                ? (messages, cursor) => journal.recordEvents(messages, cursor)
                : null,
          );
          client = createMcpClient(
            McpClientOptions(
              name: 'registry-restart-check',
              mcpServer: McpServerConfig(
                transport: transport,
                timeout: const Duration(seconds: 10),
              ),
            ),
          );
          await client.ready();
          await client.listTools();
          final pending = client.callTool(name: 'increment', arguments: {});
          final effect = File('${root.path}/effect');
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (!await effect.exists()) {
            if (DateTime.now().isAfter(deadline))
              fail('Original effect did not start: $errors');
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          process.stdin.writeln('restart');
          await process.stdin.flush();
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          expect(jsonDecode(lines.current), {'restarted': true, 'starts': 1});
          final response = await pending.timeout(const Duration(seconds: 7));
          expect(
            ((response['content'] as List).single as Map)['text'],
            '1',
            reason: errors.toString(),
          );
          await client.listTools();
          expect(await effect.readAsString(), '1');
        } finally {
          await client?.close();
          process.stdin.writeln('quit');
          await process.stdin.close();
          final exit = await process.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              process.kill();
              return -1;
            },
          );
          await lines.cancel();
          await stderr.cancel();
          store.close();
          await root.delete(recursive: true);
          expect(exit, 0, reason: errors.toString());
        }
      },
    );
  }
}
