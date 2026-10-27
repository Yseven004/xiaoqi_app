import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';

/// JSON-RPC channel to a task-bound process hosted by the private runner.
/// Neither plugin executables nor their environment run in the API process.
class SandboxMcpTransport implements McpClientTransport {
  SandboxMcpTransport._(this._baseUrl, this._runnerToken)
    : _leaseId = _randomHex(16),
      _leaseToken = _randomHex(32);

  final Uri _baseUrl;
  final String _runnerToken;
  final String _leaseId;
  final String _leaseToken;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final _inbound = StreamController<Map<String, dynamic>>();
  Future<void>? _closing;
  void Function()? _unregisterCancel;
  bool _closed = false;
  Map<String, dynamic>? _completion;
  int _eventCursor = 0;

  /// Available after close, for the task artifact recorder (never model input).
  Map<String, dynamic>? get completion => _completion;
  String get leaseId => _leaseId;

  Future<Object?> snapshotArtifacts() async =>
      (await _request('GET', '/v1/mcp/$_leaseId/artifacts'))['artifacts'];

  Future<void> acknowledgeCompletion() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      await (() async {
        final request = await client.postUrl(
          _baseUrl.resolve('/v1/mcp/$_leaseId/ack'),
        );
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_runnerToken',
        );
        request.headers.set('X-Xiaoqi-Lease-Token', _leaseToken);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.contentLength = 2;
        request.write('{}');
        final response = await request.close();
        if (response.statusCode != 200)
          throw StateError('MCP artifact acknowledgment failed');
        await response.drain<void>();
      })().timeout(const Duration(seconds: 8));
    } finally {
      client.close(force: true);
    }
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Future<SandboxMcpTransport> connect({
    required Uri runnerUrl,
    required String runnerToken,
    required Map<String, dynamic> request,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final transport = SandboxMcpTransport._(runnerUrl, runnerToken);
    try {
      await transport._request('POST', '/v1/mcp', {
        ...request,
        'issued_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'lease_id': transport._leaseId,
        'lease_token': transport._leaseToken,
      });
      cancellation.throwIfCancelled();
      transport._unregisterCancel = cancellation.onCancel(() {
        unawaited(transport.close());
      });
      unawaited(transport._poll());
      return transport;
    } catch (_) {
      await transport.close();
      rethrow;
    }
  }

  @override
  Stream<Map<String, dynamic>> get inbound => _inbound.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_closed) throw StateError('MCP connection is closed');
    if (message['jsonrpc'] != '2.0') {
      throw const FormatException('Invalid JSON-RPC message');
    }
    await _request('POST', '/v1/mcp/$_leaseId/messages', message);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? value,
  ]) async {
    final body = value == null ? null : utf8.encode(jsonEncode(value));
    final byteBudget = path == '/v1/mcp' ? 100 * 1024 * 1024 : 2 * 1024 * 1024;
    if (body != null && body.length > byteBudget) {
      throw const FormatException('MCP message exceeds transport byte budget');
    }
    return (() async {
      final request = await _http.openUrl(method, _baseUrl.resolve(path));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $_runnerToken',
      );
      request.headers.set('X-Xiaoqi-Lease-Token', _leaseToken);
      if (method == 'GET' && path.endsWith('/events'))
        request.headers.set('X-Xiaoqi-Event-Cursor', _eventCursor.toString());
      request.followRedirects = false;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw StateError(
          'Private MCP runner request failed (${response.statusCode})',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        final responseBudget = method == 'DELETE' || path.endsWith('/artifacts')
            ? 32 * 1024 * 1024
            : 4 * 1024 * 1024;
        if (bytes.length + chunk.length > responseBudget) {
          throw const FormatException(
            'MCP runner response exceeds transport byte budget',
          );
        }
        bytes.add(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid MCP runner response');
      }
      return decoded;
    })().timeout(const Duration(seconds: 30));
  }

  Future<void> _poll() async {
    try {
      while (!_closed) {
        final result = await _readEvents();
        if (_closed) break;
        final messages = result['messages'];
        if (messages is! List || messages.length > 32) {
          throw const FormatException('Invalid MCP runner event batch');
        }
        final cursor = result['cursor'];
        final advances =
            messages.isNotEmpty ||
            result['closed'] == true ||
            result['error'] != null;
        if (cursor is! int || cursor != _eventCursor + (advances ? 1 : 0))
          throw const FormatException('Invalid MCP event cursor');
        for (final message in messages) {
          if (message is! Map<String, dynamic> || message['jsonrpc'] != '2.0') {
            throw const FormatException('Invalid MCP runner protocol message');
          }
        }
        _eventCursor = cursor;
        for (final message in messages) {
          _inbound.add(message);
        }
        if (result['error'] != null)
          throw StateError('MCP process connection failed');
        if (result['closed'] == true) break;
      }
    } catch (error, stack) {
      if (!_closed) _inbound.addError(error, stack);
    } finally {
      await close();
    }
  }

  Future<Map<String, dynamic>> _readEvents() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _request('GET', '/v1/mcp/$_leaseId/events');
      } on Object catch (error) {
        if (_closed ||
            attempt >= 2 ||
            (error is! SocketException &&
                error is! HttpException &&
                error is! TimeoutException))
          rethrow;
        // Only this cursor-addressed read is retryable. Never replay a tool POST.
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _unregisterCancel?.call();
    try {
      final result = await _request(
        'DELETE',
        '/v1/mcp/$_leaseId',
      ).timeout(const Duration(seconds: 8));
      final completion = result['completion'];
      if (completion is Map<String, dynamic>) _completion = completion;
    } catch (_) {
      // Runner lease expiry and owner-scoped startup cleanup are the backstop
      // when the control connection is lost; closing never restarts a process.
    } finally {
      _http.close(force: true);
      unawaited(_inbound.close());
    }
  }
}
