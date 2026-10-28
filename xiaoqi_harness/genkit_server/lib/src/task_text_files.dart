import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'capability_import_service.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Narrow UTF-8 task-file IO. Model paths never become API-host paths and
/// writing a file does not expose code execution or mutate installed packages.
class TaskTextFiles {
  TaskTextFiles(this.owner);
  final ToolExecution owner;
  static const maxBytes = 32 * 1024 * 1024;

  static String path(String value) {
    final normalized = CapabilityImportService.safePath(value);
    if (normalized == '.xiaoqi' || normalized.startsWith('.xiaoqi/'))
      throw const FormatException('任务文件不能覆盖运行环境目录');
    return normalized;
  }

  List<Map<String, dynamic>> _artifacts() =>
      (owner.store.get(owner.key)?.value['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((artifact) => Map<String, dynamic>.from(artifact))
          .toList();
  String? _path(Map artifact) {
    final value = artifact['workspace_path'] ?? artifact['name'];
    try {
      return value is String ? path(value) : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic>? _latest(
    String name, [
    List<Map<String, dynamic>>? artifacts,
  ]) => (artifacts ?? _artifacts()).reversed
      .where((artifact) => _path(artifact) == name)
      .firstOrNull;
  Map<String, dynamic> _public(Map artifact) => {
    for (final field in ['id', 'name', 'media_type', 'size', 'sha256'])
      field: artifact[field],
    'path': _path(artifact),
  };

  Future<Map<String, dynamic>> list({
    String prefix = '',
    int offset = 0,
    int limit = 32,
  }) => owner.query(
    slot: 'list_task_files',
    arguments: {'prefix': prefix, 'offset': offset, 'limit': limit},
    invoke: (_) async => _list(prefix: prefix, offset: offset, limit: limit),
  );

  Map<String, dynamic> _list({
    String prefix = '',
    int offset = 0,
    int limit = 32,
  }) {
    owner.check('read');
    if (offset < 0 || limit < 1 || limit > 64)
      throw const FormatException('任务文件分页参数无效');
    if (prefix.isNotEmpty)
      prefix = path(prefix.replaceFirst(RegExp(r'/$'), ''));
    final heads = <String, Map<String, dynamic>>{};
    for (final artifact in _artifacts().reversed) {
      final name = _path(artifact);
      if (name != null &&
          (prefix.isEmpty || name == prefix || name.startsWith('$prefix/')))
        heads.putIfAbsent(name, () => artifact);
    }
    final names = heads.keys.toList()..sort();
    return {
      'files': [
        for (final name in names.skip(offset).take(limit))
          _public(heads[name]!),
      ],
      'total': names.length,
      'offset': offset,
      if (offset + limit < names.length) 'next_offset': offset + limit,
    };
  }

  Future<Map<String, dynamic>> read(
    String name, {
    String? artifactId,
    int offset = 0,
    int maxChars = 12000,
  }) async {
    owner.check('read');
    name = path(name);
    if (offset < 0 || maxChars < 1 || maxChars > 32000)
      throw const FormatException('文本读取分页参数无效');
    final artifact = _artifacts().reversed
        .where(
          (artifact) =>
              _path(artifact) == name &&
              (artifactId == null || artifact['id'] == artifactId),
        )
        .firstOrNull;
    if (artifact == null) throw StateError('当前任务中没有指定文件或版本，不会改读其他版本');
    return await owner.query(
      slot: 'read_task_text_file',
      arguments: {
        'path': name,
        'artifact_id': artifact['id'],
        'offset': offset,
        'max_chars': maxChars,
      },
      invoke: (_) => _read(artifact, offset, maxChars),
    );
  }

  Future<Map<String, dynamic>> _read(
    Map<String, dynamic> artifact,
    int offset,
    int limit,
  ) async {
    final key = artifact['object_key'];
    final expected = artifact['size'];
    if (key is! String ||
        !key.startsWith(
          'tenants/${owner.tenantId}/tasks/${owner.taskId}/artifacts/',
        ) ||
        expected is! int ||
        expected < 0 ||
        expected > maxBytes)
      throw StateError('文件归属或体积校验失败');
    final digest = _Digest();
    final hashing = sha256.startChunkedConversion(digest);
    final text = _TextSlice(offset, limit);
    final decoding = utf8.decoder.startChunkedConversion(
      StringConversionSink.from(text),
    );
    var bytes = 0;
    await for (final chunk in owner.store.readObjectChunks(key)) {
      owner.check('read');
      bytes += chunk.length;
      if (bytes > maxBytes || bytes > expected || chunk.contains(0))
        throw const FormatException('文件不是受支持的 UTF-8 文本或已超出体积');
      hashing.add(chunk);
      decoding.add(chunk);
    }
    hashing.close();
    decoding.close();
    owner.check('read');
    if (bytes != expected || digest.value?.toString() != artifact['sha256'])
      throw StateError('文件内容校验失败，不返回其他版本或未校验内容');
    return {
      'status': 'completed',
      ..._public(artifact),
      'text': text.buffer.toString(),
      'offset': offset,
      'total_characters': text.position,
      if (offset + limit < text.position) 'next_offset': offset + limit,
    };
  }

  Future<Map<String, dynamic>> write(
    String name,
    String text, {
    String? baseArtifactId,
  }) {
    name = path(name);
    final arguments = {
      'path': name,
      'text': text,
      'base_artifact_id': baseArtifactId,
    };
    return owner.workspace(
      slot: 'write_task_text_file',
      arguments: arguments,
      invoke: (id) async => _commit(id, name, text, baseArtifactId, arguments),
    );
  }

  Future<Map<String, dynamic>> edit(
    String artifactId,
    String oldText,
    String newText, {
    bool replaceAll = false,
  }) => owner.workspace(
    slot: 'edit_task_text_file',
    arguments: {
      'artifact_id': artifactId,
      'old_text': oldText,
      'new_text': newText,
      'replace_all': replaceAll,
    },
    invoke: (id) =>
        _edit(id, artifactId, oldText, newText, replaceAll: replaceAll),
  );

  Future<Map<String, dynamic>> _edit(
    String operationId,
    String artifactId,
    String oldText,
    String newText, {
    bool replaceAll = false,
  }) async {
    owner.check('workspace');
    if (oldText.isEmpty) throw const FormatException('替换原文不能为空');
    final artifact = _artifacts()
        .where(
          (artifact) => artifact['id'] == artifactId && _path(artifact) != null,
        )
        .firstOrNull;
    if (artifact == null) throw StateError('当前任务没有指定文件版本');
    final name = _path(artifact)!;
    if (_latest(name)?['id'] != artifactId)
      throw StateError('文件已有新版本，请读取当前版本后编辑');
    final read = await _read(artifact, 0, maxBytes);
    final original = read['text'] as String;
    final matches = oldText.allMatches(original).length;
    if (matches == 0 || (matches > 1 && !replaceAll))
      throw StateError(matches == 0 ? '没有找到指定原文，文件未修改' : '原文匹配多处，请明确是否全部替换');
    final updated = replaceAll
        ? original.replaceAll(oldText, newText)
        : original.replaceFirst(oldText, newText);
    return _commit(operationId, name, updated, artifactId, {
      'artifact_id': artifactId,
      'old_text': oldText,
      'new_text': newText,
      'replace_all': replaceAll,
    });
  }

  Map<String, dynamic> _commit(
    String operationId,
    String name,
    String text,
    String? baseArtifactId,
    Map<String, dynamic> arguments,
  ) {
    owner.check('workspace');
    final operation =
        (owner.store.get(owner.key)?.value['scope_operations']
            as Map?)?[operationId];
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(operationId) ||
        operation is! Map ||
        operation['effect'] != 'workspace' ||
        operation['request_identity'] != owner.requestIdentity ||
        operation['status'] != 'running' ||
        operation['arguments_hash'] != ToolExecution.digest(arguments))
      throw StateError('文件写入没有匹配的任务操作绑定');
    final bytes = utf8.encode(text);
    if (bytes.length > maxBytes) throw const FormatException('文本文件超过 32 MB');
    final id = 'text-$operationId';
    final key = 'tenants/${owner.tenantId}/tasks/${owner.taskId}/artifacts/$id';
    final artifact = {
      'id': id,
      'name': name.split('/').last,
      'workspace_path': name,
      'media_type': name.endsWith('.md')
          ? 'text/markdown'
          : name.endsWith('.json')
          ? 'application/json'
          : 'text/plain',
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'object_key': key,
    };
    var wroteBlob = false;
    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        owner.check('workspace');
        final current = owner.store.get(owner.key)!;
        final artifacts = (current.value['artifacts'] as List? ?? const [])
            .whereType<Map>()
            .map((artifact) => Map<String, dynamic>.from(artifact))
            .toList();
        final existing = artifacts
            .where((artifact) => artifact['id'] == id)
            .firstOrNull;
        if (existing != null) {
          if (existing['sha256'] != artifact['sha256'] ||
              _path(existing) != name)
            throw StateError('原文件操作不能写入不同内容');
          return {'status': 'completed', 'artifact': _public(existing)};
        }
        if (_latest(name, artifacts)?['id'] != baseArtifactId)
          throw StateError('文件已有新版本，请先读取原版本 ID 后再写入');
        if (!wroteBlob) {
          owner.store.putTaskBlob(key, bytes);
          wroteBlob = true;
        }
        try {
          owner.store.put(owner.key, {
            ...current.value,
            'artifacts': [...artifacts, artifact],
          }, current.revision);
          return {'status': 'completed', 'artifact': _public(artifact)};
        } on RevisionConflict {
          continue;
        }
      }
      throw StateError('任务文件写入冲突，请重新读取文件状态');
    } on Object {
      if (wroteBlob) owner.store.deleteImmutable(key);
      rethrow;
    }
  }
}

class _Digest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _TextSlice implements Sink<String> {
  _TextSlice(this.offset, this.limit);
  final int offset, limit;
  var position = 0;
  final buffer = StringBuffer();
  @override
  void add(String data) {
    for (final rune in data.runes) {
      if (position >= offset && position < offset + limit)
        buffer.writeCharCode(rune);
      position++;
    }
  }

  @override
  void close() {}
}
