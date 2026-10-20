import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';

import '../lib/src/agent_runtime.dart';
import '../lib/src/image_service.dart';
import '../lib/src/store.dart';

// A synthetic red PNG, built locally so the probe sends no personal media.
List<int> _redImage() {
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    final length = ByteData(4)..setUint32(0, data.length);
    final checksum = ByteData(4)..setUint32(0, crc ^ 0xffffffff);
    return [
      ...length.buffer.asUint8List(),
      ...body,
      ...checksum.buffer.asUint8List(),
    ];
  }

  final header = ByteData(13)
    ..setUint32(0, 64)
    ..setUint32(4, 64)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  final rows = <int>[];
  for (var y = 0; y < 64; y++) {
    rows.add(0);
    for (var x = 0; x < 64; x++) {
      rows.addAll([255, 0, 0]);
    }
  }
  return [
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', header.buffer.asUint8List()),
    ...chunk('IDAT', ZLibEncoder().convert(rows)),
    ...chunk('IEND', []),
  ];
}

void main() {
  final ai = Genkit(promptDir: null, isDevEnv: true);
  ai.defineFlow(
    name: 'verifyImageInspection',
    inputSchema: .string(),
    outputSchema: .string(),
    fn: (input, _) async {
      final model = const {'deepseek-flash', 'mimo-v2.6-flash'}.contains(input)
          ? input : 'mimo-v2.6-flash';
      final directory = Directory.systemTemp.createTempSync('inspect-live-');
      final store = CloudStore(root: directory.path);
      try {
        const key = 'tenants/probe/tasks/prior/artifacts/red.png';
        store.putTaskBlob(key, _redImage());
        store.put('task/probe/prior', {
          'artifacts': [
            {
              'id': 'red',
              'object_key': key,
              'media_type': 'image/png',
              'name': '合成色块',
            },
          ],
        }, null);
        store.put('task/probe/inspect', {'artifacts': []}, null);
        final events = <Map<String, Object?>>[];
        const question = '这张图片是什么颜色？';
        final result =
            await GenkitXiaoqiAgentRuntime(
              store,
              ImageService(store),
            ).runAgentTurn(
              tenantId: 'probe',
              taskId: 'inspect',
              request: {
                'model_id': model,
                'current_turn_text': question,
                '_visible_artifacts': [
                  {'id': 'prior/red'},
                ],
                'network_mode': 'off',
              },
              messages: [
                Message(
                  role: Role.user,
                  content: [TextPart(text: question)],
                ),
              ],
              onChunk: (_) {},
              onProcessEvent: events.add,
              cancellation: CancellationController().token,
            );
        final imageCalls = events
            .where(
              (event) =>
                  event['tool'] == 'generate_image' &&
                  event['type'] == 'tool_started',
            )
            .length;
        if (!RegExp(r'红|red', caseSensitive: false).hasMatch(result.text) ||
            imageCalls != 0) {
          throw StateError('Stored-image inspection failed: ${result.text}');
        }
        return '$model: stored synthetic red image identified; generation calls: 0';
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
