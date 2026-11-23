import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_limits.dart';

/// Genkit 1.0.2's official DeepSeek plugin preserves reasoning/tool history,
/// but its request type cannot express SiliconFlow's enable_thinking field.
/// Adapt only that provider dialect at the HTTP boundary; the official plugin
/// still owns messages, tool calls, streaming and cancellation.
/// Remove this decorator when the plugin supports SiliconFlow natively.
class SiliconFlowModelClient extends http.BaseClient {
  SiliconFlowModelClient(this._inner);

  final http.Client _inner;
  static const _idleTimeout = Duration(seconds: 30);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request &&
        request.method == 'POST' &&
        request.url.path.endsWith('/chat/completions')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['model'] == ModelLimits.siliconFlowBookSearchModel) {
        final thinking = body.remove('thinking');
        final enabled = thinking is Map ? thinking['type'] != 'disabled' : true;
        body['enable_thinking'] = enabled;
        if (enabled) {
          body['reasoning_effort'] = switch (body['reasoning_effort']) {
            'max' || 'xhigh' => 'max',
            _ => 'high',
          };
        } else {
          body.remove('reasoning_effort');
        }
        // Request's setter recalculates content length and retains its headers.
        request.body = jsonEncode(body);
      }
    }
    final response = await _inner.send(request).timeout(_idleTimeout);
    return http.StreamedResponse(
      response.stream.timeout(
        _idleTimeout,
        onTimeout: (sink) {
          sink.addError(TimeoutException('硅基流动响应流中断。', _idleTimeout));
          sink.close();
        },
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
