import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// CI host kills/restarts only its isolated runner while this SDK call is pending.
Future<void> verifyMcpRestartProbe() async {
  final directory = await Directory.systemTemp.createTemp('mcp-restart-probe-');
  final store = CloudStore(root: directory.path);
  final executor = DockerCodeExecutionService(store);
  const tenant = 'stdio-verification';
  const task = 'mcp-pending-restart';
  const script = r'''
import readline from 'node:readline';
import fs from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
const boot=randomUUID();
const input=fs.readFileSync('/workspace/skill/original-input.txt','utf8');
const sourceHash=createHash('sha256').update(fs.readFileSync(new URL(import.meta.url))).digest('hex');
const output='/workspace/output/counter.json';
function reply(id,result){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');}
readline.createInterface({input:process.stdin}).on('line',async line=>{
 const r=JSON.parse(line);
 if(r.method==='initialize')reply(r.id,{protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'restart-probe',version:'1'}});
 else if(r.method==='tools/list')reply(r.id,{tools:[{name:'increment',description:'Increment once then return the original delayed response',inputSchema:{type:'object',properties:{},additionalProperties:false}}]});
 else if(r.method==='tools/call'){
   const count=fs.existsSync(output)?JSON.parse(fs.readFileSync(output,'utf8')).count+1:1;
   const value={count,pid:process.pid,boot,input,source_hash:sourceHash};
   fs.writeFileSync(output,JSON.stringify(value));
   await new Promise(resolve=>setTimeout(resolve,8000));
   reply(r.id,{content:[{type:'text',text:JSON.stringify(value)}]});
 }
});
''';
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  try {
    final transport = await executor.connectMcp(
      tenantId: tenant,
      taskId: task,
      command: ['node', '/workspace/skill/restart.mjs'],
      environment: {},
      files: {
        'restart.mjs': utf8.encode(script),
        'original-input.txt': utf8.encode('original input snapshot'),
      },
      materials: [],
      cancellation: CancellationController().token,
    );
    final client = createMcpClient(
      McpClientOptions(
        name: 'pending-restart-probe',
        mcpServer: McpServerConfig(
          transport: transport,
          timeout: const Duration(seconds: 30),
        ),
      ),
    );
    try {
      await client.ready();
      await client.listTools();
      final pending = client.callTool(
        name: 'increment',
        arguments: <String, dynamic>{},
      );
      Map? before;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (before == null) {
        final files = (await transport.snapshotArtifacts() as List)
            .whereType<Map>();
        final counter = files
            .where((f) => f['name'] == 'counter.json')
            .firstOrNull;
        if (counter != null)
          before =
              jsonDecode(utf8.decode(base64Decode(counter['base64'] as String)))
                  as Map;
        if (DateTime.now().isAfter(deadline))
          throw StateError('Original MCP request never wrote its counter');
        if (before == null)
          await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      stdout.writeln(
        'MCP_RESTART_READY:${jsonEncode({'lease_id': transport.leaseId})}',
      );
      final continued = stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final response = await pending.timeout(const Duration(seconds: 35));
      final body = response;
      final value =
          jsonDecode(
                ((body['content'] as List).single as Map)['text'] as String,
              )
              as Map;
      if (await continued.timeout(const Duration(seconds: 35)) != 'CONTINUE')
        throw StateError('CI restart confirmation missing');
      if (value['count'] != 1 ||
          value['pid'] != before['pid'] ||
          value['boot'] != before['boot'] ||
          value['input'] != 'original input snapshot' ||
          value['source_hash'] !=
              sha256.convert(utf8.encode(script)).toString())
        throw StateError(
          'Runner restart replayed an effect, replaced the process or lost its input snapshot',
        );
      await client.listTools();
    } finally {
      await client.close();
      await executor.finishMcp(tenant, task, transport);
    }
    final state = store.get('task/$tenant/$task')!.value;
    final artifact = (state['artifacts'] as List).whereType<Map>().single;
    final bytes = store.getObject(artifact['object_key'].toString());
    if ((jsonDecode(utf8.decode(bytes)) as Map)['count'] != 1 ||
        artifact['sha256'] != sha256.convert(bytes).toString() ||
        state['code_execution_runs'] != 1)
      throw StateError(
        'Restarted MCP result files were lost, duplicated or re-executed',
      );
    stdout.writeln(
      'MCP_RESTART_PASSED:${jsonEncode({'passed': true, 'one_effect': true, 'original_process': true, 'original_input': true, 'artifact_integrity': true})}',
    );
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
