import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';

class OnlineBookSearch {
  OnlineBookSearch._();

  static final instance = OnlineBookSearch._();
  final enabled = ValueNotifier<bool?>(null);
  final _transfers = <String, Set<http.Client>>{};

  static String newId() => CapabilityCloudSync.newTaskId();

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 12),
    String? transferId,
  }) async {
    final sync = CapabilityCloudSync.instance;
    final client = http.Client();
    if (transferId != null) {
      (_transfers[transferId] ??= {}).add(client);
    }
    try {
      final headers = await sync.authenticatedHeaders();
      final request = http.Request(method, sync.capabilityEndpoint(path))
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      final payload = jsonDecode(utf8.decode(response.bodyBytes));
      if (payload is! Map) throw const FormatException('找书服务回复无效');
      if (response.statusCode >= 400) {
        final error = payload['error'];
        throw OnlineBookSearchException(
          response.statusCode,
          (error is Map ? error['message'] : error)?.toString() ?? '找书请求失败',
        );
      }
      return Map<String, dynamic>.from(payload);
    } finally {
      if (transferId != null) _removeTransfer(transferId, client);
      client.close();
    }
  }

  Future<bool> loadEnabled() async {
    final value =
        (await _request('GET', 'book-search-settings'))['enabled'] == true;
    return enabled.value = value;
  }

  Future<void> setEnabled(bool value) async {
    await _request('PUT', 'book-search-settings', body: {'enabled': value});
    enabled.value = value;
    if (!value) {
      for (final clients in _transfers.values) {
        for (final client in clients) {
          client.close();
        }
      }
      _transfers.clear();
    }
  }

  Future<Map<String, dynamic>> start(String id, String query) =>
      _request('POST', 'book-searches', body: {'id': id, 'query': query});

  Future<Map<String, dynamic>> read(String id) =>
      _request('GET', 'book-searches/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> resolve(
    String id,
    String candidate, {
    String? acceptedCandidateToken,
  }) => _request(
    'POST',
    'book-searches/${Uri.encodeComponent(id)}/candidates/${Uri.encodeComponent(candidate)}/resolve',
    body: {'acceptedCandidateToken': ?acceptedCandidateToken},
    timeout: const Duration(seconds: 105),
    transferId: id,
  );

  Future<File> downloadVerifiedFile(
    String id,
    String candidate, {
    required int expectedLength,
    required String expectedSha256,
  }) async {
    final sync = CapabilityCloudSync.instance;
    final client = http.Client();
    (_transfers[id] ??= {}).add(client);
    Directory? directory;
    try {
      directory = await (await getTemporaryDirectory()).createTemp(
        'online-book-search-',
      );
      final file = File(p.join(directory.path, 'book.bin'));
      final request = http.Request(
        'GET',
        sync.capabilityEndpoint(
          'book-searches/${Uri.encodeComponent(id)}/candidates/'
          '${Uri.encodeComponent(candidate)}/file',
        ),
      )..headers.addAll(await sync.authenticatedHeaders());
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        final error = await http.Response.fromStream(response);
        final payload = jsonDecode(utf8.decode(error.bodyBytes));
        final message = payload is Map
            ? ((payload['error'] as Map?)?['message']?.toString() ?? '下载核验文件失败')
            : '下载核验文件失败';
        throw OnlineBookSearchException(response.statusCode, message);
      }
      if (response.headers['x-book-sha256'] != expectedSha256 ||
          int.tryParse(response.headers['content-length'] ?? '') !=
              expectedLength ||
          expectedLength <= 128 ||
          expectedLength > 256 * 1024 * 1024) {
        throw const FormatException('服务端核验文件信息与书目不一致');
      }
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > expectedLength) {
            throw const FormatException('核验文件长度超过书目记录');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received != expectedLength || await file.length() != expectedLength) {
        throw const FormatException('核验文件传输不完整');
      }
      return file;
    } on Object {
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // Keep the transfer failure visible even if temporary cleanup fails.
        }
      }
      rethrow;
    } finally {
      _removeTransfer(id, client);
      client.close();
    }
  }

  void _removeTransfer(String id, http.Client client) {
    final clients = _transfers[id];
    clients?.remove(client);
    if (clients?.isEmpty == true) _transfers.remove(id);
  }

  Future<Map<String, dynamic>?> stop(String id) async {
    for (final client in _transfers.remove(id) ?? <http.Client>{}) {
      client.close();
    }
    // Stop uses the ID allocated before submission, so even a lost startup
    // response can be cancelled. Retry transient transport failures.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        return await _request(
          'POST',
          'book-searches/${Uri.encodeComponent(id)}/stop',
        );
      } on OnlineBookSearchException catch (error) {
        if (error.statusCode < 500) return null;
      } on StateError {
        return null;
      } on Exception {
        // A brief loss of connectivity must not discard the stop.
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return null;
  }
}

class OnlineBookSearchException implements Exception {
  const OnlineBookSearchException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}
