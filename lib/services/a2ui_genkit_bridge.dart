import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:genkit/client.dart' as genkit;

const a2uiMimeType = 'application/a2ui+json';

/// Reads A2UI messages emitted by genkit_a2ui 0.5.0.
/// Older persisted messages using `envelopes` remain readable.
Iterable<Map<String, dynamic>> a2uiMessagesFrom(
  List<genkit.Part>? parts,
) sync* {
  for (final part in parts ?? const <genkit.Part>[]) {
    if (part.metadata?['mimeType'] != a2uiMimeType) continue;
    final data = part.data;
    final messages = data?['messages'] ?? data?['envelopes'];
    if (messages is! List) continue;
    for (final message in messages.whereType<Map>()) {
      yield Map<String, dynamic>.from(message);
    }
  }
}

/// Adapts an official A2UI renderer action to the Genkit A2UI data part.
({genkit.Message message, Map<String, dynamic> action}) a2uiActionToMessage(
  a2ui.A2uiRendererAction action,
) {
  final envelope = a2ui.ActionMessage(
    version: a2ui.A2uiProtocolVersion.v0_9.jsonValue,
    action: action,
  );
  final payload = a2ui.RendererToAgentMessagePayload.of(envelope).toJson();
  return (
    message: genkit.Message(
      role: genkit.Role.user,
      content: [
        genkit.DataPart(data: payload, metadata: {'mimeType': a2uiMimeType}),
      ],
    ),
    action: action.toJson(),
  );
}
