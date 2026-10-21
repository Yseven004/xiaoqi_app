import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Private, bounded cache for immutable generated image artifacts.
class TaskArtifactImageCache {
  TaskArtifactImageCache({
    BaseCacheManager? diskCache,
    this.maxMemoryBytes = 32 * 1024 * 1024,
  }) : _disk = diskCache;

  final int maxMemoryBytes;
  BaseCacheManager? _disk;
  BaseCacheManager get _diskCache => _disk ??= CacheManager(
    Config(
      'xiaoqi_task_artifact_images_v1',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 100,
    ),
  );
  final _memory = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  int _memoryBytes = 0;

  Future<Uint8List> load({
    required String scope,
    required String taskId,
    required String artifactId,
    required Future<Uint8List> Function() download,
  }) {
    // Scope contains the service address and session identity. Persist only its
    // digest, never a token, account name, or user-controlled path component.
    final key = sha256
        .convert(utf8.encode(jsonEncode([scope, taskId, artifactId])))
        .toString();
    final memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      return Future<Uint8List>.value(memory);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final disk = await _read(key);
        if (disk != null) {
          _remember(key, disk);
          return disk;
        }
        final bytes = await download();
        if (bytes.isEmpty) throw const FormatException('图片内容为空');
        _remember(key, bytes);
        await _write(key, bytes);
        return bytes;
      } finally {
        // Failed requests must remain retryable.
        _pending.remove(key);
      }
    });
  }

  void _remember(String key, Uint8List bytes) {
    if (bytes.length > maxMemoryBytes) return;
    while (_memory.isNotEmpty && _memoryBytes + bytes.length > maxMemoryBytes) {
      _memoryBytes -= _memory.remove(_memory.keys.first)!.length;
    }
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
  }

  Future<Uint8List?> _read(String key) async {
    try {
      final cached = await _diskCache.getFileFromCache(key);
      if (cached == null) return null;
      final bytes = await cached.file.readAsBytes();
      // Artifacts are immutable: a task/artifact ID never changes content.
      // Eviction belongs to the manager; reopening needs no HTTP revalidation.
      return bytes.isEmpty ? null : bytes;
    } on Object {
      // Cache eviction, a missing plugin, or an unavailable disk is a miss.
      return null;
    }
  }

  Future<void> _write(String key, Uint8List bytes) async {
    try {
      await _diskCache.putFile(key, bytes, key: key, fileExtension: 'image');
    } on Object {
      // A full/unavailable cache must never prevent showing a downloaded image.
    }
  }
}
