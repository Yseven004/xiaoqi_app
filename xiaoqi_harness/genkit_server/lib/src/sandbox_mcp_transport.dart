import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'tool_execution.dart';

class _RunnerResponseError extends StateError {
  _RunnerResponseError(this.status)
    : super('Private MCP runner request failed ($status)');
  final int status;
}

/// JSON-RPC channel to a task-bound process hosted by the private runner.
/// Neither plugin executables nor their environment run in the API process.
class SandboxMcpTransport implements McpClientTransport {
  SandboxMcpTransport._(
    this._baseUrl,
    this._runnerToken, {
    String? leaseId,
    String? leaseToken,
    this.beforeSend,
    this.onEventBatch,
    int eventCursor = 0,
  }) : _leaseId = leaseId ?? _randomHex(16),
       _leaseToken = leaseToken ?? _randomHex(32),
       _eventCursor = eventCursor;

  static final _activeLeases = <String>{};
  static bool isActive(String leaseId) => _activeLeases.contains(leaseId);

  /// Reclaim an original lease without starting or replaying any MCP process.
  static SandboxMcpTransport forRecovery({
    required Uri runnerUrl,
    required String runnerToken,
    required String leaseId,
    required String leaseToken,
    int eventCursor = 0,
    void Function(List<Map<String, dynamic>>, int)? onEventBatch,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(leaseId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(leaseToken))
      throw const FormatException('Invalid MCP recovery identity');
    return SandboxMcpTransport._(
      runnerUrl,
      runnerToken,
      leaseId: leaseId,
      leaseToken: leaseToken,
      eventCursor: eventCursor,
      onEventBatch: onEventBatch,
    );
  }

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
  int _eventCursor;
  final void Function(Map<String, dynamic>, int)? beforeSend;
  final void Function(List<Map<String, dynamic>>, int)? onEventBatch;
  int _sendSequence = 0;
  Future<void> _sending = Future<void>.value();
  bool _sendFailed = false;

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
    FutureOr<void> Function(Map<String, dynamic> identity)? beforeStart,
    void Function(Map<String, dynamic>, int)? beforeSend,
    void Function(List<Map<String, dynamic>>, int)? onEventBatch,
  }) async {
    cancellation.throwIfCancelled();
    final transport = SandboxMcpTransport._(
      runnerUrl,
      runnerToken,
      beforeSend: beforeSend,
      onEventBatch: onEventBatch,
    );
    _activeLeases.add(transport.leaseId);
    try {
      final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await beforeStart?.call({
        'lease_id': transport._leaseId,
        'lease_token': transport._leaseToken,
        'issued_at': issuedAt,
      });
      cancellation.throwIfCancelled();
      final ready = await transport._request('POST', '/v1/mcp', {
        ...request,
        'issued_at': issuedAt,
        'lease_id': transport._leaseId,
        'lease_token': transport._leaseToken,
      });
      if (ready['control_version'] != 2 || ready['deduplicated_sends'] != true)
        throw StateError(
          'MCP runner control protocol/storage is unavailable; deploy matching server and runner',
        );
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
    final encoded = utf8.encode(jsonEncode(message));
    if (encoded.length > 2 * 1024 * 1024)
      throw const FormatException('MCP message exceeds transport byte budget');
    final frozen = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(encoded)) as Map,
    );
    final sequence = ++_sendSequence;
    final operation = _sending.then<void>((_) async {
      if (_closed || _sendFailed)
        throw StateError('Original MCP submission is unconfirmed or closed');
      try {
        ToolExecution.checkCurrentAuthority();
        beforeSend?.call(frozen, sequence);
        for (var attempt = 0; ; attempt++) {
          try {
            ToolExecution.checkCurrentAuthority();
            await _request(
              'POST',
              '/v1/mcp/$_leaseId/messages',
              frozen,
              sequence,
            );
            return;
          } catch (error) {
            final transient =
                error is SocketException ||
                error is HttpException ||
                error is TimeoutException ||
                (error is _RunnerResponseError && error.status >= 500);
            // This is a proven idempotent control submission, not an RPC/tool
            // retry: the durable runner claims this exact sequence before stdin.
            if (!transient || attempt >= 1 || _closed) rethrow;
          }
        }
      } catch (_) {
        _sendFailed = true;
        rethrow;
      }
    });
    _sending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await operation;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? value,
    int? sendSequence,
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
      if (sendSequence != null)
        request.headers.set(
          'X-Xiaoqi-Message-Sequence',
          sendSequence.toString(),
        );
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
        throw _RunnerResponseError(response.statusCode);
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
    var phase = 'events';
    try {
      while (!_closed) {
        phase = 'events';
        final result = await _readEvents();
        if (_closed) break;
        phase = 'validate';
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
        // Commit response correlation before the next poll acknowledges this
        // batch. A process death must not erase an already observed result.
        phase = 'checkpoint';
        onEventBatch?.call(messages.cast<Map<String, dynamic>>(), cursor);
        phase = 'deliver';
        _eventCursor = cursor;
        for (final message in messages) {
          _inbound.add(message);
        }
        if (result['error'] != null)
          throw StateError('MCP process connection failed');
        if (result['closed'] == true) break;
      }
    } catch (error, stack) {
      if (!_closed) {
        // Structural diagnostics only: no RPC body, token or exception text.
        stderr.writeln(
          'MCP_TRANSPORT_FAILURE phase=$phase type=${error.runtimeType} cursor=$_eventCursor',
        );
        _inbound.addError(error, stack);
      }
    } finally {
      await close();
    }
  }

  Future<Map<String, dynamic>> _readEvents() async {
    final recovery = Stopwatch()..start();
    const window = Duration(seconds: 20);
    while (true) {
      try {
        return await _request(
          'GET',
          '/v1/mcp/$_leaseId/events',
        ).timeout(window - recovery.elapsed);
      } on Object catch (error) {
        if (_closed ||
            recovery.elapsed >= window ||
            (error is! SocketException &&
                error is! HttpException &&
                error is! TimeoutException &&
                !(error is _RunnerResponseError && error.status >= 500)))
          rethrow;
        // Only this cursor-addressed read is retryable. Never replay a tool POST.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// Read only the original lease's pending replies. Never initializes a new
  /// SDK session, submits an RPC or resets the original call deadline.
  Future<void> recoverEvents({
    required DateTime deadline,
    required bool Function() pending,
  }) async {
    final elapsed = Stopwatch()..start();
    final originalRemaining = deadline.difference(DateTime.now());
    final budget = originalRemaining < const Duration(seconds: 60)
        ? originalRemaining
        : const Duration(seconds: 60);
    while (!_closed && pending()) {
      final remaining = budget - elapsed.elapsed;
      if (remaining <= Duration.zero) return;
      final result = await _readEvents().timeout(remaining);
      final messages = result['messages'];
      final cursor = result['cursor'];
      final advances =
          messages is List &&
          (messages.isNotEmpty ||
              result['closed'] == true ||
              result['error'] != null);
      if (messages is! List ||
          messages.length > 32 ||
          cursor is! int ||
          cursor != _eventCursor + (advances ? 1 : 0) ||
          messages.any(
            (m) => m is! Map<String, dynamic> || m['jsonrpc'] != '2.0',
          )) {
        throw const FormatException('Invalid original MCP response batch');
      }
      onEventBatch?.call(messages.cast<Map<String, dynamic>>(), cursor);
      _eventCursor = cursor;
      if (result['closed'] == true || result['error'] != null) return;
    }
  }

  /// Dispose an unsuccessful recovery read without stopping the original job.
  void disposeRecoveryReader() {
    _closed = true;
    _http.close(force: true);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _unregisterCancel?.call();
    try {
      await (() async {
        final result = await _request('DELETE', '/v1/mcp/$_leaseId');
        final completion = result['completion'];
        if (completion is Map<String, dynamic>) _completion = completion;
        if (_completion == null) {
          for (var attempt = 0; attempt < 6; attempt++) {
            // An API process rebuilding a private lease has no old event
            // cursor. Status/artifact reads never ACK or consume RPC frames.
            final status = await _request('GET', '/v1/mcp/$_leaseId/status');
            if (status['result_ready'] == true) {
              final artifacts = await snapshotArtifacts();
              _completion = {
                ...Map<String, dynamic>.from(
                  status['completion'] as Map? ?? const {},
                ),
                'artifacts': artifacts,
              };
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      })().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Runner lease expiry and owner-scoped startup cleanup are the backstop
      // when the control connection is lost; closing never restarts a process.
    } finally {
      _activeLeases.remove(_leaseId);
      _http.close(force: true);
      unawaited(_inbound.close());
    }
  }
}
