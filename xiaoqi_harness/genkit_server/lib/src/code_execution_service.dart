import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:genkit/genkit.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';

class NetworkPermissionRequired implements Exception {
  const NetworkPermissionRequired(this.domains, this.purpose);

  final List<String> domains;
  final String purpose;
}

class DockerCodeExecutionService {
  DockerCodeExecutionService(
    this.store, {
    String? pythonExecutable,
    String? workerPath,
  }) : _pythonExecutable = pythonExecutable,
       _workerPath = workerPath;

  final CloudStore store;
  final String? _pythonExecutable;
  final String? _workerPath;
  final _uuid = const Uuid();

  /// Keep the terminal error, not only the progress output before it.
  static String failureDetails(Object error) {
    final value = switch (error) {
      FormatException(:final message) => message,
      StateError(:final message) => message,
      _ => '技能脚本执行失败，请查看任务诊断记录。',
    }.toString().trim();
    return value.length <= 2000
        ? value
        : '${value.substring(0, 300)}\n…\n${value.substring(value.length - 1600)}';
  }

  Future<Map<String, List<int>>> prepareDependencies(
    String tenant,
    Map<String, List<int>> files, {
    CancellationToken? cancellation,
  }) async {
    final taskId = 'install-${_uuid.v4()}';
    final key = 'task/$tenant/$taskId';
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    final installer = File(
      '${File(worker).parent.path}/prepare_dependencies.py',
    );
    if (!installer.existsSync()) throw StateError('服务器缺少依赖准备程序');
    store.put(key, {
      'id': taskId,
      'status': 'preparing_dependencies',
      'events': [],
      'artifacts': [],
    }, null);
    try {
      await execute(
        tenantId: tenant,
        taskId: taskId,
        code: await installer.readAsString(),
        language: 'python',
        authorizedDomains: [
          'pypi.org',
          'files.pythonhosted.org',
          'registry.npmjs.org',
        ],
        materials: [],
        skillFiles: {
          for (final name in ['requirements.txt', 'package.json'])
            if (files[name] != null) name: files[name]!,
        },
        cancellation: cancellation ?? CancellationController().token,
      );
      final artifacts = store.get(key)!.value['artifacts'] as List;
      final artifact = artifacts
          .whereType<Map>()
          .where((a) => a['name'] == 'dependencies.zip')
          .firstOrNull;
      if (artifact == null) throw StateError('依赖准备没有返回锁定文件');
      final zip = ZipDecoder().decodeBytes(
        store.getObject(artifact['object_key'].toString()),
      );
      final prepared = <String, List<int>>{};
      var total = 0;
      for (final file in zip.files) {
        if (!file.isFile) continue;
        if (file.isSymbolicLink ||
            file.name.startsWith('/') ||
            file.name.contains('\\') ||
            file.name.split('/').any((p) => p == '..' || p.isEmpty) ||
            (!file.name.startsWith('.xiaoqi/') &&
                !file.name.startsWith('node_modules/')))
          throw StateError('依赖包路径校验失败');
        total += file.size;
        if (total > 40 * 1024 * 1024) throw StateError('依赖体积超出限制');
        prepared[file.name] = file.content;
      }
      if (!prepared.containsKey('.xiaoqi/dependency-lock.json'))
        throw StateError('依赖锁定记录缺失');
      return prepared;
    } finally {
      store.deleteObjectsPrefix('tenants/$tenant/tasks/$taskId/');
      store.delete(key);
    }
  }

  bool get isConfigured {
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    return File(worker).existsSync();
  }

  Future<String> execute({
    required String tenantId,
    required String taskId,
    required String code,
    required String language,
    required List<String> authorizedDomains,
    required List<Map<String, dynamic>> materials,
    required Map<String, List<int>> skillFiles,
    required CancellationToken cancellation,
    String? scriptPath,
    List<String> arguments = const [],
  }) async {
    cancellation.throwIfCancelled();
    if (code.trim().isEmpty || utf8.encode(code).length > 64 * 1024) {
      throw const FormatException('代码不能为空且不能超过 64 KB');
    }
    if (!const {'python', 'javascript', 'typescript'}.contains(language)) {
      throw const FormatException('不支持的代码语言');
    }
    if (scriptPath != null) _claimSkillScript(tenantId, taskId);

    final executable =
        _pythonExecutable ??
        Platform.environment['SANDBOX_WORKER_PYTHON'] ??
        (Platform.isWindows ? 'python' : 'python3');
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    if (!File(worker).existsSync()) {
      throw StateError('本机 Docker 沙箱执行桥接文件不存在');
    }

    final process = await Process.start(executable, [worker]);
    final unregisterCancel = cancellation.onCancel(() {
      process.kill(ProcessSignal.sigterm);
    });
    final resultCompleter = Completer<Map<String, dynamic>>();
    final stdoutDone = Completer<void>();
    String? activeSandboxId;
    unawaited(() async {
      try {
        await for (final line
            in process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.length > 32 * 1024 * 1024) {
            throw const FormatException('Docker 沙箱返回内容超过大小限制');
          }
          final Map<String, dynamic> message;
          try {
            message = (jsonDecode(line) as Map).cast<String, dynamic>();
          } on Object {
            continue;
          }
          if (message['type'] == 'sandbox_started') {
            activeSandboxId = message['sandbox_id']?.toString();
            if (activeSandboxId != null && activeSandboxId!.isNotEmpty) {
              _mutateTask(
                tenantId,
                taskId,
                (task) => {
                  ...task,
                  'sandbox_id': activeSandboxId,
                  'sandbox_cleanup_pending': false,
                  'updated_at': _now(),
                },
              );
            }
          } else if (message['type'] == 'result' &&
              !resultCompleter.isCompleted) {
            resultCompleter.complete(message);
          }
        }
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      } on Object catch (error, stack) {
        if (!resultCompleter.isCompleted) {
          resultCompleter.completeError(error, stack);
        }
        if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stack);
      }
    }());
    unawaited(process.stderr.drain<void>());

    try {
      final request = <String, dynamic>{
        'task_id': _runnerTaskId(tenantId, taskId),
        'code': code,
        'language': language,
        'authorized_domains': authorizedDomains,
        'materials': materials,
        'skill_files': {
          for (final entry in skillFiles.entries)
            entry.key: base64Encode(entry.value),
        },
        if (scriptPath != null) 'script_path': scriptPath,
        if (scriptPath != null) 'arguments': arguments,
      };
      process.stdin.writeln(jsonEncode(request));
      await process.stdin.close();
      await process.exitCode.timeout(
        const Duration(minutes: 4),
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          throw TimeoutException('Docker 沙箱执行超过 4 分钟');
        },
      );
      await stdoutDone.future.timeout(const Duration(seconds: 10));
      if (!resultCompleter.isCompleted) {
        _markCleanupPending(tenantId, taskId, activeSandboxId);
        throw StateError('Docker 沙箱没有返回任务结果');
      }
      final result = await resultCompleter.future;
      _finishSandboxCleanup(
        tenantId,
        taskId,
        activeSandboxId,
        result['cleanup_pending'] == true,
        result['sandbox_id']?.toString(),
      );
      final artifactNames = await _saveArtifacts(
        tenantId,
        taskId,
        result['artifacts'],
      );
      cancellation.throwIfCancelled();
      final output = [
        result['stdout']?.toString() ?? '',
        result['stderr']?.toString().isNotEmpty == true
            ? 'stderr:\n${result['stderr']}'
            : '',
        if (artifactNames.isNotEmpty) '已生成文件：${artifactNames.join('、')}',
        if (result['error'] != null) 'error: ${result['error']}',
      ].where((value) => value.isNotEmpty).join('\n');
      if (result['ok'] != true) {
        throw StateError(output.isEmpty ? 'Docker 沙箱执行失败' : output);
      }
      return output.isEmpty ? '代码已执行，没有标准输出。' : output;
    } on Object {
      if (activeSandboxId != null) {
        _markCleanupPending(tenantId, taskId, activeSandboxId);
      }
      rethrow;
    } finally {
      unregisterCancel();
    }
  }

  Future<void> disableNetwork({
    required String tenantId,
    required String taskId,
  }) async {
    final executable =
        _pythonExecutable ??
        Platform.environment['SANDBOX_WORKER_PYTHON'] ??
        (Platform.isWindows ? 'python' : 'python3');
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    if (!File(worker).existsSync()) {
      throw StateError('本机 Docker 沙箱执行桥接文件不存在');
    }

    final process = await Process.start(executable, [worker]);
    final outputFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    unawaited(process.stderr.drain<void>());
    process.stdin.writeln(
      jsonEncode({
        'action': 'disable_network',
        'task_id': _runnerTaskId(tenantId, taskId),
      }),
    );
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 35),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw TimeoutException('撤销运行中脚本的公网代理超时');
      },
    );
    final lines = await outputFuture.timeout(const Duration(seconds: 2));
    Map<String, dynamic>? result;
    for (final line in lines.reversed) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          result = decoded.cast<String, dynamic>();
          break;
        }
      } on FormatException {
        continue;
      }
    }
    if (exitCode != 0 || result?['ok'] != true) {
      throw StateError(result?['error']?.toString() ?? '无法撤销运行中脚本的公网代理');
    }
  }

  void _claimSkillScript(String tenantId, String taskId) {
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) throw StateError('任务不存在');
      if ((current.value['skill_script_runs'] as num? ?? 0).toInt() >= 12) {
        throw StateError('本次任务的技能脚本执行次数已用完');
      }
      try {
        store.put(key, {
          ...current.value,
          'skill_script_runs': 1,
          'updated_at': _now(),
        }, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('无法锁定技能脚本执行次数');
  }

  String _runnerTaskId(String tenantId, String taskId) =>
      sha256.convert(utf8.encode('$tenantId/$taskId')).toString();

  Future<List<String>> _saveArtifacts(
    String tenantId,
    String taskId,
    Object? rawArtifacts,
  ) async {
    if (rawArtifacts is! List || rawArtifacts.isEmpty) return const [];
    if (rawArtifacts.length > 10) throw StateError('任务最多可返回 10 个产物');
    final pending = <Map<String, dynamic>>[];
    var total = 0;
    for (final raw in rawArtifacts.whereType<Map>()) {
      final rawName = raw['name']?.toString() ?? '';
      final name = _safeArtifactName(rawName);
      final encoded = raw['base64']?.toString() ?? '';
      final bytes = base64Decode(encoded);
      if (bytes.length > 10 * 1024 * 1024) {
        throw StateError('产物 $name 超过 10 MB');
      }
      total += bytes.length;
      if (total > 20 * 1024 * 1024) {
        throw StateError('本次任务产物总大小超过 20 MB');
      }
      final id = _uuid.v4().replaceAll('-', '');
      final objectKey = 'tenants/$tenantId/tasks/$taskId/artifacts/$id';
      store.putTaskBlob(objectKey, bytes);
      pending.add({
        'id': id,
        'name': name,
        'media_type':
            raw['media_type']?.toString() ?? 'application/octet-stream',
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'object_key': objectKey,
      });
    }
    if (pending.isEmpty) return const [];
    _mutateTask(tenantId, taskId, (task) {
      final artifacts = (task['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      artifacts.addAll(pending);
      final events = (task['events'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      events.add({
        'seq': events.length,
        'type': 'artifacts_ready',
        'artifacts': [for (final item in pending) _publicArtifact(item)],
        'created_at': _now(),
      });
      return {...task, 'artifacts': artifacts, 'events': events};
    });
    return pending.map((item) => item['name'].toString()).toList();
  }

  void _finishSandboxCleanup(
    String tenantId,
    String taskId,
    String? activeId,
    bool cleanupPending,
    String? resultId,
  ) {
    final id = (resultId?.isNotEmpty == true ? resultId : activeId);
    if (id == null) return;
    _mutateTask(
      tenantId,
      taskId,
      (task) => {
        ...task,
        'sandbox_id': cleanupPending ? id : null,
        'sandbox_cleanup_pending': cleanupPending,
        'sandbox_cleanup_deadline': cleanupPending ? _now() + 300 : null,
        'updated_at': _now(),
      },
    );
  }

  void _markCleanupPending(String tenantId, String taskId, String? sandboxId) {
    if (sandboxId == null || sandboxId.isEmpty) return;
    _mutateTask(
      tenantId,
      taskId,
      (task) => {
        ...task,
        'sandbox_id': sandboxId,
        'sandbox_cleanup_pending': true,
        'sandbox_cleanup_deadline': _now() + 300,
        'updated_at': _now(),
      },
    );
  }

  Map<String, dynamic> _mutateTask(
    String tenantId,
    String taskId,
    Map<String, dynamic> Function(Map<String, dynamic>) update,
  ) {
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) throw StateError('任务不存在');
      try {
        return store.put(key, update(current.value), current.revision).value;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('更新任务状态冲突');
  }

  static Map<String, dynamic> _publicArtifact(Map<String, dynamic> item) => {
    for (final key in const ['id', 'name', 'media_type', 'size', 'sha256'])
      key: item[key],
  };

  static String _safeArtifactName(String value) {
    final basename = value.replaceAll('\\', '/').split('/').last;
    final safe = basename
        .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '');
    if (safe.isEmpty) throw const FormatException('产物文件名无效');
    return safe.length > 120 ? safe.substring(0, 120) : safe;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static String _defaultWorkerPath() {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final candidate = File('$executableDir/docker_worker.py');
    if (candidate.existsSync()) return candidate.path;
    return '${Directory.current.path}${Platform.pathSeparator}bin${Platform.pathSeparator}docker_worker.py';
  }
}
