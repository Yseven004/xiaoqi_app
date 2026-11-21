import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('xiaoqi-book-agent-');
  final store = CloudStore(root: temp.path);
  const owner = 'device/personal/book-search-test';
  const search = 'test-book-search-turn';
  const task = 'book-search-agent-turn';
  const userText = '帮我找《Hello 算法》1.2.0';
  store.put(owner, {}, null);
  store.put('task/personal/$task', {
    'status': 'running',
    'artifacts': [],
  }, null);
  final runtime = GenkitXiaoqiAgentRuntime(store, ImageService(store));
  final events = <Map<String, Object?>>[];
  try {
    final result = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: task,
      request: {
        '_authenticated_device_key': owner,
        'book_search_id': search,
        'model_id': 'mimo-v2.6-flash',
        'current_turn_text': userText,
      },
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: userText)],
        ),
      ],
      onChunk: (_) {},
      onProcessEvent: events.add,
      cancellation: CancellationController().token,
    );
    final operations = store
        .get('task/personal/$task')
        ?.value['scope_operations'];
    stdout.writeln(
      'RESULT:${jsonEncode({'text': result.text, 'status': runtime.bookSearch.searches.read(owner: owner, id: search)['status'], 'starts': events.where((event) => event['type'] == 'tool_started' && event['tool'] == 'find_book_material').length, 'operation_count': (operations as Map?)?.length})}',
    );
  } finally {
    store.close();
    await temp.delete(recursive: true);
  }
}
