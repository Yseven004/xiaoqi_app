import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../features/capabilities/data/capability_cloud_sync.dart';

class OnlineBookSearch {
  OnlineBookSearch._();

  static final instance = OnlineBookSearch._();
  final enabled = ValueNotifier<bool?>(null);

  static String newId() => CapabilityCloudSync.newTaskId();

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final sync = CapabilityCloudSync.instance;
    final headers = await sync.authenticatedHeaders();
    final client = http.Client();
    try {
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
  }

  Future<Map<String, dynamic>> start(String id, String query) =>
      _request('POST', 'book-searches', body: {'id': id, 'query': query});

  Future<Map<String, dynamic>> read(String id) =>
      _request('GET', 'book-searches/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> resolve(String id, String candidate) => _request(
    'POST',
    'book-searches/${Uri.encodeComponent(id)}/candidates/${Uri.encodeComponent(candidate)}/resolve',
    timeout: Duration(
      seconds: candidate.startsWith('wikisource-zh-') ? 100 : 22,
    ),
  );

  Future<Map<String, dynamic>?> stop(String id) async {
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
