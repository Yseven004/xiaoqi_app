import 'dart:convert';

import 'package:http/http.dart' as http;

/// Adapts Genkit 1.0.2's DeepSeek-compatible body for MiMo. The official
/// plugin provides the shared thinking toggle and tool reasoning replay.
/// Remove this adapter when a MiMo plugin can express those fields natively.
class MimoModelClient extends http.BaseClient {
  MimoModelClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request &&
        request.method == 'POST' &&
        request.url.path.endsWith('/chat/completions')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      body.remove('reasoning_effort');
      final maxTokens = body.remove('max_tokens');
      if (maxTokens != null) body['max_completion_tokens'] = maxTokens;
      request.body = jsonEncode(body);
    }
    return _inner.send(request);
  }
}
