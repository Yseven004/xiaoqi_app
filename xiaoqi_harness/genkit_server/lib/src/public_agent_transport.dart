import 'dart:convert';

import 'package:shelf/shelf.dart';

bool _isApproval(Map part) {
  final metadata = part['metadata'];
  return metadata is Map &&
      (metadata['interrupt'] == true || metadata['interrupt'] is Map);
}

/// Server snapshots retain tool context for continuation. Their HTTP projection
/// exposes only message content and explicit user approvals, never raw traces.
Object? publicAgentPayload(Object? value) {
  if (value is List) {
    return [
      for (final item in value)
        if (item is! Map || !const {'system', 'tool'}.contains(item['role']))
          publicAgentPayload(item),
    ];
  }
  if (value is! Map) return value;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key.toString();
    if (key == 'content' &&
        entry.value is List &&
        (entry.value as List).any(
          (part) =>
              part is Map &&
              const [
                'text',
                'reasoning',
                'toolRequest',
                'toolResponse',
                'data',
                'media',
                'resource',
              ].any(part.containsKey),
        )) {
      result[key] = [
        for (final part in entry.value as List)
          if (part is Map &&
              !part.containsKey('reasoning') &&
              !part.containsKey('toolResponse') &&
              (!part.containsKey('toolRequest') || _isApproval(part)))
            publicAgentPayload(part),
      ];
    } else if ((key == 'custom' ||
            (key == 'metadata' && value['role'] != 'user')) &&
        value.containsKey('content')) {
      // Model/provider debugging metadata is not user content.
      continue;
    } else {
      result[key] = publicAgentPayload(entry.value);
    }
  }
  return result;
}

/// Preserve Genkit's SSE framing and cancellation propagation while filtering
/// both stream chunks and the final response/snapshot with the same policy.
Future<Response> publicAgentResponse(Response response) async {
  final contentType = response.headers['content-type'] ?? '';
  final headers = Map<String, String>.from(response.headers)
    ..remove('content-length');
  if (contentType.startsWith('text/event-stream')) {
    final body = response
        .read()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) {
          if (line.startsWith('data: ') || line.startsWith('error: ')) {
            final colon = line.indexOf(':');
            return utf8.encode(
              '${line.substring(0, colon + 1)} ${jsonEncode(publicAgentPayload(jsonDecode(line.substring(colon + 1))))}\n',
            );
          }
          return utf8.encode('$line\n');
        });
    return response.change(body: body, headers: headers);
  }
  if (contentType.startsWith('application/json')) {
    final body = await response.readAsString();
    return response.change(
      body: jsonEncode(publicAgentPayload(jsonDecode(body))),
      headers: headers,
    );
  }
  return response;
}
