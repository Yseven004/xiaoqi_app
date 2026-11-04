import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:genkit/genkit.dart';
import 'package:uuid/uuid.dart';

import 'execution_limits.dart';
import 'store.dart';
import 'sandbox_mcp_transport.dart';
import 'mcp_rpc_journal.dart';

enum SandboxExecutionProfile {
  code('code', 120),
  pluginHook('plugin_hook', 120),
  pluginHookReadOnly('plugin_hook_read_only', 120),
  pluginCommandContext('plugin_command_context', 120),
  pluginCommandContextReadOnly('plugin_command_context_read_only', 120),
  dependencyBuild('dependency_build', 600);

  const SandboxExecutionProfile(this.wireName, this.runSeconds);
  final String wireName;
  final int runSeconds;
  Duration get bridgeDeadline => Duration(seconds: 180 + runSeconds + 30);
  Duration get apiDeadline => bridgeDeadline + const Duration(seconds: 20);
  bool get readOnly =>
      this == pluginHookReadOnly || this == pluginCommandContextReadOnly;
}

class NetworkPermissionRequired implements Exception {
  const NetworkPermissionRequired(
    this.domains,
    this.purpose, {
    required this.approvalHash,
    required this.scopeHash,
    this.details = const {},
  });

  final List<String> domains;
  final String purpose;
  final String approvalHash;
  final String scopeHash;
  final Map<String, dynamic> details;
}

/// The runner request was submitted: an external effect may already have
/// happened even when the process/transport failed to return a usable result.
class SandboxExecutionError extends StateError {
  SandboxExecutionError(super.message);
}

class DockerCodeExecutionService {
  DockerCodeExecutionService(
    this.store, {
    String? pythonExecutable,
    String? workerPath,
    Uri? runnerUrl,
    String? runnerToken,
    this.limits = const ExecutionLimits(),
  }) : _pythonExecutable = pythonExecutable,
       _workerPath = workerPath,
       _runnerUrl = runnerUrl,
       _runnerToken = runnerToken;

  final CloudStore store;
  final ExecutionLimits limits;
  final String? _pythonExecutable;
  final String? _workerPath;
  final Uri? _runnerUrl;
  final String? _runnerToken;
  final _uuid = const Uuid();
  static final _dependencyPreparations = <String>{};
  static final _taskDependencyPreparations = <String>{};

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
    cancellation?.throwIfCancelled();
    final source = {
      for (final entry in files.entries) entry.key: List<int>.of(entry.value),
    };
    final paths = source.keys.toList()..sort();
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final path in paths)
                [path, sha256.convert(source[path]!).toString()],
            ]),
          ),
        )
        .toString();
    // Keep the identity across HTTP retries and API restarts. Unknown builds
    // must recover their original result instead of executing lifecycle hooks again.
    final taskId = 'install-$digest';
    final key = 'task/$tenant/$taskId';
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    final installer = File(
      '${File(worker).parent.path}/prepare_dependencies.py',
    );
    if (!installer.existsSync()) throw StateError('服务器缺少依赖准备程序');
    final activeKey = '${store.root.absolute.path}/$key';
    if (!_dependencyPreparations.add(activeKey)) {
      throw StateError('相同来源的依赖正在准备，请稍后查询原安装');
    }
    var ownsPreparation = false;
    try {
      final previous = store.get(key);
      if (previous == null) {
        store.put(key, {
          'id': taskId,
          'status': 'preparing_dependencies',
          'dependency_source_digest': digest,
          'events': [],
          'artifacts': [],
        }, null);
        ownsPreparation = true;
      } else {
        if (previous.value['dependency_source_digest'] != digest ||
            previous.value['status'] != 'preparing_dependencies') {
          throw StateError('依赖准备记录与原始来源不匹配，不能复用或覆盖');
        }
        ownsPreparation = true;
        await recoverExecutions(tenantId: tenant, taskId: taskId);
      }
      cancellation?.throwIfCancelled();
      final operations =
          store.get(key)!.value['code_execution_operations'] as Map? ??
          const {};
      if (operations.isNotEmpty) {
        if (operations.values.any(
          (operation) =>
              operation is! Map || operation['status'] != 'persisted',
        )) {
          throw StateError('依赖准备结果尚未确认，已保留原执行，请稍后重试安装以查询结果；不会重复运行构建脚本');
        }
        final failed = operations.entries
            .where((operation) => (operation.value as Map)['ok'] != true)
            .firstOrNull;
        if (failed != null) {
          final result =
              jsonDecode(
                    utf8.decode(
                      store.getObject(
                        'tenants/$tenant/tasks/$taskId/executions/${failed.key}/result.json',
                      ),
                    ),
                  )
                  as Map;
          throw StateError(
            '原依赖准备执行失败：${failureDetails(StateError(_executionText(result, const [])))}',
          );
        }
      } else {
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
          // Build hooks need their own source files, not API-host paths or data.
          skillFiles: source,
          cancellation: cancellation ?? CancellationController().token,
          profile: SandboxExecutionProfile.dependencyBuild,
        );
      }
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
        final preparedName = file.name.startsWith('.xiaoqi/built/')
            ? file.name.substring('.xiaoqi/built/'.length)
            : file.name;
        if (preparedName.isEmpty ||
            RegExp(r'[\x00-\x1f:]').hasMatch(preparedName) ||
            preparedName.startsWith('.xiaoqi/') && preparedName != file.name) {
          throw StateError('构建产物不能覆盖保留的运行环境目录');
        }
        if (prepared.containsKey(preparedName)) throw StateError('依赖包包含重复产物路径');
        prepared[preparedName] = file.content;
      }
      if (!prepared.containsKey('.xiaoqi/dependency-lock.json'))
        throw StateError('依赖锁定记录缺失');
      cancellation?.throwIfCancelled();
      return prepared;
    } finally {
      try {
        final task = store.get(key)?.value;
        final operations =
            task?['code_execution_operations'] as Map? ?? const {};
        final pending =
            task?['sandbox_cleanup_pending'] == true ||
            operations.values.any(
              (operation) =>
                  operation is! Map ||
                  operation['status'] != 'persisted' ||
                  operation['ack_pending'] == true ||
                  operation['cleanup_pending'] == true,
            );
        if (ownsPreparation && !pending) {
          store.deleteObjectsPrefix('tenants/$tenant/tasks/$taskId/');
          store.delete(key);
        }
      } finally {
        _dependencyPreparations.remove(activeKey);
      }
    }
  }

  /// Installs task-requested packages once and keeps the verified archive for
  /// later isolated sandboxes belonging to the same task.
  Future<Map<String, List<int>>> prepareTaskDependencies({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> dependencies,
    required CancellationToken cancellation,
  }) async {
    final requestedPython = _dependencyList(dependencies['python'], 'Python');
    final requestedNpm = _dependencyList(dependencies['npm'], 'npm');
    if (requestedPython.isEmpty && requestedNpm.isEmpty) {
      return taskDependencies(tenantId, taskId);
    }
    final key = 'task/$tenantId/$taskId';
    final prior = store.get(key)?.value['task_dependencies'];
    final priorReady = prior is Map && prior['status'] == 'ready';
    final priorRequested = priorReady && prior['requested'] is Map
        ? Map<String, dynamic>.from(prior['requested'] as Map)
        : const <String, dynamic>{};
    final python = _mergeDependencyList(
      priorRequested['python'],
      requestedPython,
      python: true,
    );
    final npm = _mergeDependencyList(
      priorRequested['npm'],
      requestedNpm,
      python: false,
    );
    if (python.length + npm.length > 20) {
      throw const FormatException('每次最多声明 20 个直接依赖');
    }
    if (priorReady &&
        _sameStrings(priorRequested['python'], python) &&
        _sameStrings(priorRequested['npm'], npm)) {
      return taskDependencies(tenantId, taskId);
    }
    final taskLockKey = '${store.root.absolute.path}/$key';
    if (!_taskDependencyPreparations.add(taskLockKey)) {
      throw StateError('当前任务已有一组依赖正在准备，请稍后查询任务状态');
    }
    try {
      return await _prepareTaskDependencySet(
        tenantId: tenantId,
        taskId: taskId,
        key: key,
        priorReady: priorReady,
        priorRequested: priorRequested,
        requestedPython: requestedPython,
        requestedNpm: requestedNpm,
        python: python,
        npm: npm,
        cancellation: cancellation,
      );
    } finally {
      _taskDependencyPreparations.remove(taskLockKey);
    }
  }

  Future<Map<String, List<int>>> _prepareTaskDependencySet({
    required String tenantId,
    required String taskId,
    required String key,
    required bool priorReady,
    required Map<String, dynamic> priorRequested,
    required List<String> requestedPython,
    required List<String> requestedNpm,
    required List<String> python,
    required List<String> npm,
    required CancellationToken cancellation,
  }) async {
    final activeDependencies = store.get(key)?.value['task_dependencies'];
    final previousObjectKey = priorReady && activeDependencies is Map
        ? activeDependencies['object_key']?.toString()
        : null;
    final priorLock = priorReady
        ? _taskDependencyLock(tenantId, taskId)
        : const <String, dynamic>{};
    final source = <String, List<int>>{};
    if (python.isNotEmpty) {
      final overridden = requestedPython
          .where(_hasPythonVersion)
          .map(_dependencyName)
          .toSet();
      final priorPins = (priorLock['python'] as List? ?? const [])
          .whereType<Map>()
          .where((package) {
            final name = package['name']?.toString() ?? '';
            return name.isNotEmpty &&
                package['version'] != null &&
                !overridden.contains(_normalizePythonName(name));
          })
          .map((package) => '${package['name']}==${package['version']}');
      final requirements = {...priorPins, ...python}.toList()..sort();
      source['requirements.txt'] = utf8.encode('${requirements.join('\n')}\n');
    }
    if (npm.isNotEmpty) {
      source['package.json'] = utf8.encode(
        jsonEncode({
          'name': 'xiaoqi-task-dependencies',
          'version': '1.0.0',
          'dependencies': {
            for (final value in npm) _npmName(value): _npmVersion(value),
          },
        }),
      );
      final npmLock = priorLock['npm'];
      if (npmLock is Map && npmLock.isNotEmpty) {
        source['package-lock.json'] = utf8.encode(jsonEncode(npmLock));
      }
    }
    source['.xiaoqi/task-dependencies.json'] = utf8.encode('{}');
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              for (final entry in source.entries)
                entry.key: sha256.convert(entry.value).toString(),
            }),
          ),
        )
        .toString();
    store.put(key, {
      ...?store.get(key)?.value,
      'task_dependency_preparation': {
        'digest': digest,
        'status': 'preparing',
        'requested': {'python': python, 'npm': npm},
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
    }, store.get(key)?.revision);
    try {
      cancellation.throwIfCancelled();
      final files = await prepareDependencies(
        tenantId,
        source,
        cancellation: cancellation,
      );
      final archive = Archive();
      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      final bytes = ZipEncoder().encode(archive);
      if (bytes.length > 20 * 1024 * 1024) {
        throw StateError('依赖包超过 20 MB 上限');
      }
      cancellation.throwIfCancelled();
      final objectKey =
          'tenants/$tenantId/tasks/$taskId/task-dependencies/$digest.zip';
      store.putTaskBlob(objectKey, bytes);
      final current = store.get(key);
      store.put(key, {
        ...?current?.value,
        'task_dependencies': {
          'digest': digest,
          'status': 'ready',
          'requested': {'python': python, 'npm': npm},
          'resolved_versions': _resolvedVersionsFromFiles(
            files,
            python: python,
            npm: npm,
          ),
          'object_key': objectKey,
          'archive_sha256': sha256.convert(bytes).toString(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        'task_dependency_preparation': {
          'digest': digest,
          'status': 'ready',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      }, current?.revision);
      if (previousObjectKey != null && previousObjectKey != objectKey) {
        store.deleteImmutable(previousObjectKey);
      }
      return files;
    } on Object catch (error) {
      final current = store.get(key);
      store.put(key, {
        ...?current?.value,
        'task_dependency_preparation': {
          'digest': digest,
          'status': cancellation.isCancelled ? 'cancelled' : 'failed',
          'requested': {'python': python, 'npm': npm},
          'error': error.toString().substring(
            0,
            error.toString().length > 1000 ? 1000 : error.toString().length,
          ),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      }, current?.revision);
      rethrow;
    }
  }

  Map<String, List<int>> taskDependencies(String tenantId, String taskId) {
    final value = store
        .get('task/$tenantId/$taskId')
        ?.value['task_dependencies'];
    if (value is! Map || value['status'] != 'ready') return const {};
    final bytes = _taskDependencyArchive(value, tenantId, taskId);
    final result = <String, List<int>>{};
    for (final file in ZipDecoder().decodeBytes(bytes).files) {
      if (!file.isFile ||
          file.isSymbolicLink ||
          file.name.startsWith('/') ||
          file.name.contains('\\') ||
          file.name.split('/').any((part) => part == '..' || part.isEmpty) ||
          (file.name != '.xiaoqi/dependency-lock.json' &&
              !file.name.startsWith('.xiaoqi/python/') &&
              !file.name.startsWith('node_modules/'))) {
        throw StateError('已准备的任务依赖包含无效路径');
      }
      result[file.name] = file.content;
    }
    return result;
  }

  Map<String, dynamic> taskDependencyInfo(String tenantId, String taskId) {
    final value = store
        .get('task/$tenantId/$taskId')
        ?.value['task_dependencies'];
    if (value is! Map || value['status'] != 'ready') return const {};
    final requested = value['requested'] is Map
        ? Map<String, dynamic>.from(value['requested'] as Map)
        : const <String, dynamic>{};
    final resolvedVersions = value['resolved_versions'] is Map
        ? Map<String, dynamic>.from(value['resolved_versions'] as Map)
        : _resolvedVersionsFromLock(
            _taskDependencyLock(tenantId, taskId),
            requested,
          );
    return {
      'status': 'ready',
      'packages': requested,
      'resolved_versions': resolvedVersions,
    };
  }

  bool taskDependenciesCover(
    String tenantId,
    String taskId,
    Map<String, dynamic> requested,
  ) {
    final python = _dependencyList(requested['python'], 'Python');
    final npm = _dependencyList(requested['npm'], 'npm');
    if (python.isEmpty && npm.isEmpty) return false;
    final info = taskDependencyInfo(tenantId, taskId);
    if (info.isEmpty) return false;
    final installed = Map<String, dynamic>.from(info['packages'] as Map);
    final resolved = Map<String, dynamic>.from(
      info['resolved_versions'] as Map? ?? const {},
    );
    final resolvedPython = (resolved['python'] as List? ?? const [])
        .whereType<Map>();
    final resolvedNpm = Map<String, dynamic>.from(
      resolved['npm'] as Map? ?? const {},
    );
    bool covers(
      List<String> wanted,
      Object? current, {
      required bool isPython,
    }) {
      final values = _dependencyList(current, isPython ? 'Python' : 'npm');
      final byName = <String, String>{
        for (final value in values)
          (isPython
                  ? _normalizePythonName(_dependencyName(value))
                  : _npmName(value)):
              value,
      };
      for (final item in wanted) {
        final name = isPython
            ? _normalizePythonName(_dependencyName(item))
            : _npmName(item);
        final prior = byName[name];
        if (prior == null) return false;
        if (prior == item) continue;
        if (isPython && _hasPythonVersion(item)) {
          final version = item.substring(item.indexOf('==') + 2);
          final resolvedPackage = resolvedPython
              .where(
                (value) =>
                    _normalizePythonName(value['name'].toString()) == name,
              )
              .firstOrNull;
          if (resolvedPackage?['version']?.toString() != version) return false;
        } else if (!isPython && _hasNpmVersion(item)) {
          if (resolvedNpm[name]?.toString() != _npmVersion(item)) return false;
        }
      }
      return true;
    }

    return covers(python, installed['python'], isPython: true) &&
        covers(npm, installed['npm'], isPython: false);
  }

  Map<String, dynamic> _resolvedVersionsFromFiles(
    Map<String, List<int>> files, {
    required List<String> python,
    required List<String> npm,
  }) {
    final lockBytes = files['.xiaoqi/dependency-lock.json'];
    if (lockBytes == null) throw StateError('依赖锁文件缺失');
    final lock = jsonDecode(utf8.decode(lockBytes));
    if (lock is! Map) throw StateError('依赖锁文件格式无效');
    return _resolvedVersionsFromLock(Map<String, dynamic>.from(lock), {
      'python': python,
      'npm': npm,
    });
  }

  Map<String, dynamic> _resolvedVersionsFromLock(
    Map<String, dynamic> lock,
    Map<String, dynamic> requested,
  ) {
    final pythonLock = (lock['python'] as List? ?? const []).whereType<Map>();
    final npmLock = lock['npm'] is Map
        ? Map<String, dynamic>.from(lock['npm'] as Map)
        : const <String, dynamic>{};
    final npmPackages = npmLock['packages'] is Map
        ? Map<String, dynamic>.from(npmLock['packages'] as Map)
        : const <String, dynamic>{};
    final npmRoot = npmPackages[''] is Map
        ? Map<String, dynamic>.from(npmPackages[''] as Map)
        : const <String, dynamic>{};
    final requestedNpm = npmRoot['dependencies'] is Map
        ? Map<String, dynamic>.from(npmRoot['dependencies'] as Map)
        : const <String, dynamic>{};
    final resolvedPython = <Map<String, dynamic>>[];
    for (final requestedPackage
        in (requested['python'] as List? ?? const []).whereType<String>()) {
      final name = _normalizePythonName(_dependencyName(requestedPackage));
      final locked = pythonLock
          .where(
            (value) => _normalizePythonName(value['name'].toString()) == name,
          )
          .firstOrNull;
      if (locked != null) {
        resolvedPython.add({
          'name': locked['name'],
          'version': locked['version'],
        });
      }
    }
    final resolvedNpm = <String, dynamic>{};
    for (final requestedPackage
        in (requested['npm'] as List? ?? const []).whereType<String>()) {
      final name = _npmName(requestedPackage);
      final package = npmPackages['node_modules/$name'];
      final version = package is Map ? package['version'] : requestedNpm[name];
      if (version != null) resolvedNpm[name] = version;
    }
    return {'python': resolvedPython, 'npm': resolvedNpm};
  }

  Map<String, dynamic> _taskDependencyLock(String tenantId, String taskId) {
    final value = store
        .get('task/$tenantId/$taskId')
        ?.value['task_dependencies'];
    if (value is! Map || value['status'] != 'ready') return const {};
    final bytes = _taskDependencyArchive(value, tenantId, taskId);
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (file.isFile && file.name == '.xiaoqi/dependency-lock.json') {
        final decoded = jsonDecode(utf8.decode(file.content));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    }
    throw StateError('已准备的任务依赖缺少锁定信息');
  }

  List<int> _taskDependencyArchive(Map value, String tenantId, String taskId) {
    final key = value['object_key'];
    final checksum = value['archive_sha256'];
    final prefix = 'tenants/$tenantId/tasks/$taskId/task-dependencies/';
    if (key is! String ||
        !key.startsWith(prefix) ||
        !key.endsWith('.zip') ||
        checksum is! String) {
      throw StateError('已准备的任务依赖记录无效');
    }
    final bytes = store.getObject(key);
    if (sha256.convert(bytes).toString() != checksum) {
      throw StateError('已准备的任务依赖校验失败');
    }
    return bytes;
  }

  List<String> _mergeDependencyList(
    Object? priorValue,
    List<String> requested, {
    required bool python,
  }) {
    final prior = _dependencyList(priorValue, python ? 'Python' : 'npm');
    final byName = <String, String>{
      for (final item in prior)
        (python ? _normalizePythonName(_dependencyName(item)) : _npmName(item)):
            item,
    };
    for (final item in requested) {
      final name = python
          ? _normalizePythonName(_dependencyName(item))
          : _npmName(item);
      final hasVersion = python
          ? _hasPythonVersion(item)
          : _hasNpmVersion(item);
      if (hasVersion || !byName.containsKey(name)) byName[name] = item;
    }
    return byName.values.toList()..sort();
  }

  bool _sameStrings(Object? previous, List<String> current) {
    if (previous is! List) return current.isEmpty;
    final values = previous.whereType<String>().toList()..sort();
    return values.length == current.length &&
        values.indexed.every((entry) => entry.$2 == current[entry.$1]);
  }

  String _dependencyName(String value) {
    final marker = value.indexOf('==');
    return marker < 0 ? value : value.substring(0, marker);
  }

  String _normalizePythonName(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[-_.]+'), '-');

  bool _hasPythonVersion(String value) => value.contains('==');

  bool _hasNpmVersion(String value) =>
      value.startsWith('@') ? value.indexOf('@', 1) >= 0 : value.contains('@');

  List<String> _dependencyList(Object? value, String label) {
    if (value == null) return const [];
    if (value is! List || value.length > 20)
      throw FormatException('$label 依赖必须是最多 20 项的列表');
    final values = value.map((item) => item.toString().trim()).toList();
    final pattern = label == 'Python'
        ? RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9._-]*(?:==[A-Za-z0-9][A-Za-z0-9._+-]*)?$',
          )
        : RegExp(
            r'^(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+(?:@\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?)?$',
          );
    if (values.any((item) => !pattern.hasMatch(item))) {
      throw FormatException('$label 依赖仅支持包名和可选的固定版本，不接受 URL 或本地路径');
    }
    return values.toSet().toList()..sort();
  }

  String _npmName(String value) => value.startsWith('@')
      ? (value.lastIndexOf('@') == 0
            ? value
            : value.substring(0, value.lastIndexOf('@')))
      : value.split('@').first;

  String _npmVersion(String value) {
    final index = value.lastIndexOf('@');
    return index <= 0 ? '*' : value.substring(index + 1);
  }

  bool get isConfigured {
    final worker =
        _workerPath ??
        Platform.environment['SANDBOX_WORKER_PATH'] ??
        _defaultWorkerPath();
    return File(worker).existsSync();
  }

  Future<SandboxMcpTransport> connectMcp({
    required String tenantId,
    required String taskId,
    required List<String> command,
    required Map<String, String> environment,
    required Map<String, List<int>> files,
    required List<Map<String, dynamic>> materials,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final url =
        _runnerUrl?.toString() ?? Platform.environment['SANDBOX_RUNNER_URL'];
    final token = _runnerToken ?? Platform.environment['SANDBOX_RUNNER_TOKEN'];
    if (url == null || token == null || token.length < 32) {
      throw StateError('服务器隔离 MCP 宿主未配置');
    }
    final inputs = _materialsForNextExecution(
      tenantId: tenantId,
      taskId: taskId,
      materials: materials,
    );
    _claimExecution(tenantId, taskId, skillScript: false);
    late McpRpcJournal rpcJournal;
    return SandboxMcpTransport.connect(
      runnerUrl: Uri.parse(url),
      runnerToken: token,
      beforeStart: (identity) {
        rpcJournal = McpRpcJournal(
          store,
          tenantId,
          taskId,
          identity['lease_id'] as String,
          limit: limits.toolOperations,
        );
        // Separate private document: credentials never enter task/model output.
        store.put(
          'private_mcp_lease/$tenantId/$taskId/${identity['lease_id']}',
          {
            ...identity,
            'runner_url': url,
            'task_binding': _runnerTaskId(tenantId, taskId),
          },
          null,
        );
      },
      beforeSend: (message, sequence) =>
          rpcJournal.beforeSend(message, sequence),
      onEventBatch: (messages, cursor) =>
          rpcJournal.recordEvents(messages, cursor),
      request: {
        'task_id': _runnerTaskId(tenantId, taskId),
        'command': command,
        'environment': environment,
        'authorized_domains': <String>[],
        'materials': inputs,
        'skill_files': {
          for (final entry in files.entries)
            entry.key: base64Encode(entry.value),
        },
      },
      cancellation: cancellation,
    );
  }

  Future<void> snapshotMcp(
    String tenantId,
    String taskId,
    SandboxMcpTransport transport,
  ) async {
    await _saveArtifacts(
      tenantId,
      taskId,
      await transport.snapshotArtifacts(),
      operationId: 'mcp:${transport.leaseId}',
    );
  }

  Future<void> finishMcp(
    String tenantId,
    String taskId,
    SandboxMcpTransport transport,
  ) async {
    await transport.close();
    final result = transport.completion;
    if (result == null) return;
    final rpcJournal = McpRpcJournal(
      store,
      tenantId,
      taskId,
      transport.leaseId,
      limit: limits.toolOperations,
    );
    rpcJournal.reconcile();
    rpcJournal.finishUnknown();
    await _saveArtifacts(
      tenantId,
      taskId,
      result['artifacts'],
      operationId: 'mcp:${transport.leaseId}',
    );
    String? priorId;
    _mutateTask(tenantId, taskId, (task) {
      final operations = Map<String, dynamic>.from(
        task['mcp_cleanup_operations'] as Map? ?? const {},
      );
      priorId = (operations[transport.leaseId] as Map?)?['sandbox_id']
          ?.toString();
      operations[transport.leaseId] = {
        'cleanup_pending': result['cleanup_pending'] == true,
        'sandbox_id': result['sandbox_id'] ?? priorId,
      };
      return {...task, 'mcp_cleanup_operations': operations};
    });
    _finishSandboxCleanup(
      tenantId,
      taskId,
      result['sandbox_id']?.toString() ?? priorId,
      result['cleanup_pending'] == true,
      result['sandbox_id']?.toString(),
    );
    await transport.acknowledgeCompletion();
    for (final (key, _) in rpcJournal.records) {
      store.delete(key);
    }
    store.delete('private_mcp_lease/$tenantId/$taskId/${transport.leaseId}');
  }

  /// Recover outputs from a prior API process. Never creates a replacement lease.
  Future<void> recoverMcpLeases({
    required String tenantId,
    required String taskId,
    CancellationToken? cancellation,
  }) async {
    final url =
        _runnerUrl?.toString() ?? Platform.environment['SANDBOX_RUNNER_URL'];
    final token = _runnerToken ?? Platform.environment['SANDBOX_RUNNER_TOKEN'];
    if (url == null || token == null || token.length < 32) return;
    final prefix = 'private_mcp_lease/$tenantId/$taskId/';
    for (final (key, record) in store.list(
      prefix,
      limit: limits.toolOperations,
    )) {
      final value = record.value;
      final id = value['lease_id'];
      final leaseToken = value['lease_token'];
      if (id is! String ||
          leaseToken is! String ||
          key != '$prefix$id' ||
          value['task_binding'] != _runnerTaskId(tenantId, taskId) ||
          value['runner_url'] != url ||
          SandboxMcpTransport.isActive(id))
        continue;
      SandboxMcpTransport? transport;
      void Function()? unregisterCancel;
      try {
        final rpcJournal = McpRpcJournal(
          store,
          tenantId,
          taskId,
          id,
          limit: limits.toolOperations,
        );
        rpcJournal.reconcile();
        transport = SandboxMcpTransport.forRecovery(
          runnerUrl: Uri.parse(url),
          runnerToken: token,
          leaseId: id,
          leaseToken: leaseToken,
          eventCursor: value['event_cursor'] as int? ?? 0,
          onEventBatch: (messages, cursor) {
            rpcJournal.recordEvents(messages, cursor);
            rpcJournal.reconcile();
          },
        );
        final recoveryTransport = transport;
        unregisterCancel = cancellation?.onCancel(() {
          unawaited(recoveryTransport.close().catchError((Object _) {}));
        });
        final deadline = rpcJournal.pendingDeadline;
        if (cancellation?.isCancelled != true &&
            deadline != null &&
            deadline.isAfter(DateTime.now())) {
          try {
            await transport.recoverEvents(
              deadline: deadline,
              pending: () => rpcJournal.pendingDeadline != null,
            );
          } on TimeoutException {
            // The original call deadline has elapsed; never submit it again.
          }
        }
        await finishMcp(tenantId, taskId, transport);
      } on Object {
        if (cancellation?.isCancelled == true && transport != null) {
          try {
            await finishMcp(tenantId, taskId, transport);
          } on Object {
            /* Preserve the lease for later artifact recovery. */
          }
        }
        // Preserve identity until artifacts and acknowledgment both persist.
        // An unavailable runner does not prove that the original call failed.
      } finally {
        unregisterCancel?.call();
        transport?.disposeRecoveryReader();
      }
    }
    cancellation?.throwIfCancelled();
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
    List<String>? artifactIds,
    void Function()? beforeSubmit,
    String? scopeOperationId,
    SandboxExecutionProfile profile = SandboxExecutionProfile.code,
  }) async {
    cancellation.throwIfCancelled();
    beforeSubmit?.call();
    if (profile == SandboxExecutionProfile.dependencyBuild) {
      final preparation = store.get('task/$tenantId/$taskId')?.value;
      if (!RegExp(r'^install-[a-f0-9]{64}$').hasMatch(taskId) ||
          preparation?['status'] != 'preparing_dependencies' ||
          preparation?['dependency_source_digest'] != taskId.substring(8))
        throw StateError('依赖构建必须绑定原始安装准备记录');
    }
    if (const {
          SandboxExecutionProfile.pluginHook,
          SandboxExecutionProfile.pluginHookReadOnly,
          SandboxExecutionProfile.pluginCommandContext,
          SandboxExecutionProfile.pluginCommandContextReadOnly,
        }.contains(profile) &&
        (language != 'javascript' || scriptPath != null)) {
      throw StateError('hook 协议通道只接受宿主生成的 JavaScript 启动器');
    }
    if ((profile.readOnly ||
            profile == SandboxExecutionProfile.pluginCommandContext) &&
        authorizedDomains.isNotEmpty) {
      throw StateError('只读 hook 不允许外部联网');
    }
    if (scriptPath == null &&
        (code.trim().isEmpty || utf8.encode(code).length > 64 * 1024)) {
      throw const FormatException('代码不能为空且不能超过 64 KB');
    }
    if (!const {
      'python',
      'javascript',
      'typescript',
      'shell',
    }.contains(language)) {
      throw const FormatException('不支持的代码语言');
    }
    String? networkToken;
    final networkRevision =
        (store.get('task/$tenantId/$taskId')?.value['network_policy_revision']
                    as num? ??
                0)
            .toInt();
    if (authorizedDomains.isNotEmpty) {
      final grant = await _runnerControlResult({
        'action': 'network_token',
        'task_id': _runnerTaskId(tenantId, taskId),
        'network_revision': networkRevision,
      });
      networkToken = grant['network_token'] as String?;
      if (networkToken == null ||
          !RegExp(r'^[0-9]{1,20}\.[a-f0-9]{64}$').hasMatch(networkToken)) {
        throw StateError('沙箱未返回有效的本次联网凭据');
      }
      cancellation.throwIfCancelled();
      beforeSubmit?.call();
    }
    final executionMaterials = _materialsForNextExecution(
      tenantId: tenantId,
      taskId: taskId,
      materials: materials,
      artifactIds: artifactIds,
    );
    _claimExecution(tenantId, taskId, skillScript: scriptPath != null);

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

    final executionId = const Uuid().v4().replaceAll('-', '');
    final issuedAt = DateTime.now().millisecondsSinceEpoch;
    final process = await Process.start(executable, [worker]);
    Timer? cancelDeadline;
    Future<void>? cancelRequest;
    final unregisterCancel = cancellation.onCancel(() {
      // Keep the result stream alive while the runner stops the exact execution
      // and exports partial files. Only a failed handshake kills the bridge.
      cancelDeadline ??= Timer(const Duration(seconds: 15), () {
        process.kill(ProcessSignal.sigterm);
      });
      cancelRequest ??=
          _runnerControl({
            'action': 'cancel_execution',
            'task_id': _runnerTaskId(tenantId, taskId),
            'execution_id': executionId,
            'issued_at': issuedAt,
          }, timeout: const Duration(seconds: 8)).catchError((Object _) {
            // No acknowledgement does not prove cleanup. The original stream may
            // still report it; otherwise the deadline leaves an unknown result.
          });
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
              _recordExecution(tenantId, taskId, executionId, {
                'sandbox_id': activeSandboxId,
              });
              _mutateTask(
                tenantId,
                taskId,
                (task) => {
                  ...task,
                  'sandbox_id': activeSandboxId,
                  'sandbox_cleanup_pending':
                      task['sandbox_cleanup_pending'] == true,
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

    var requestSubmitted = false;
    var cleanupResultReceived = false;
    try {
      final request = <String, dynamic>{
        'task_id': _runnerTaskId(tenantId, taskId),
        'execution_id': executionId,
        'issued_at': issuedAt,
        'code': scriptPath == null
            ? code
            : '# Installed entry is staged in skill_files',
        'language': language,
        'execution_profile': profile.wireName,
        'authorized_domains': authorizedDomains,
        if (networkToken != null) 'network_token': networkToken,
        if (networkToken != null) 'network_revision': networkRevision,
        'materials': executionMaterials,
        'skill_files': {
          for (final entry in skillFiles.entries)
            entry.key: base64Encode(entry.value),
        },
        if (scriptPath != null) 'script_path': scriptPath,
        if (arguments.isNotEmpty) 'arguments': arguments,
      };
      cancellation.throwIfCancelled();
      beforeSubmit?.call();
      _recordExecution(tenantId, taskId, executionId, {
        'issued_at': issuedAt,
        'status': 'submitted',
        'execution_profile': profile.wireName,
        if (scopeOperationId != null) 'scope_operation_id': scopeOperationId,
      });
      requestSubmitted = true;
      process.stdin.writeln(jsonEncode(request));
      await process.stdin.close();
      await process.exitCode.timeout(
        profile.apiDeadline,
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          throw TimeoutException(
            'Docker 沙箱执行及回收超过 ${profile.apiDeadline.inSeconds} 秒',
          );
        },
      );
      await stdoutDone.future.timeout(const Duration(seconds: 10));
      var result = resultCompleter.isCompleted
          ? await resultCompleter.future
          : null;
      if (result == null || result['transport_error'] == true) {
        result = await _executionResult(
          tenantId,
          taskId,
          executionId,
          issuedAt,
        );
        if (result == null) throw StateError('Docker 沙箱结果尚未确认，请查询原执行，不能直接重跑');
      }
      if (result['execution_id'] != null &&
          result['execution_id'] != executionId)
        throw StateError('沙箱返回了其他执行的结果');
      _recordExecution(tenantId, taskId, executionId, {
        'cleanup_pending': result['cleanup_pending'] == true,
      });
      _finishSandboxCleanup(
        tenantId,
        taskId,
        activeSandboxId,
        result['cleanup_pending'] == true,
        result['sandbox_id']?.toString(),
      );
      cleanupResultReceived = true;
      final artifactNames = await _saveArtifacts(
        tenantId,
        taskId,
        profile.readOnly ? const [] : result['artifacts'],
        operationId: executionId,
        dependencyBuild: profile == SandboxExecutionProfile.dependencyBuild,
      );
      _storeExecutionOutput(
        tenantId,
        taskId,
        executionId,
        result,
        artifactNames: artifactNames,
      );
      _recordExecution(tenantId, taskId, executionId, {
        'status': 'persisted',
        'ok': result['ok'] == true,
        'ack_pending': result['execution_id'] == executionId,
      });
      if (result['execution_id'] == executionId)
        await _ackExecution(tenantId, taskId, executionId, issuedAt);
      cancellation.throwIfCancelled();
      final output = _executionText(result, artifactNames);
      if (result['ok'] != true) {
        throw StateError(output.isEmpty ? 'Docker 沙箱执行失败' : output);
      }
      return output.isEmpty ? '代码已执行，没有标准输出。' : output;
    } on Object catch (error, stack) {
      final persistedElsewhere =
          ((store
                      .get('task/$tenantId/$taskId')
                      ?.value['code_execution_operations']
                  as Map?)?[executionId]
              as Map?)?['status'] ==
          'persisted';
      if (requestSubmitted && !cleanupResultReceived && !persistedElsewhere) {
        _recordExecution(tenantId, taskId, executionId, {'status': 'unknown'});
      }
      if (!cleanupResultReceived &&
          !persistedElsewhere &&
          activeSandboxId != null) {
        _markCleanupPending(tenantId, taskId, activeSandboxId);
      }
      if (requestSubmitted) {
        Error.throwWithStackTrace(
          SandboxExecutionError(failureDetails(error)),
          stack,
        );
      }
      rethrow;
    } finally {
      unregisterCancel();
      cancelDeadline?.cancel();
      if (cancelRequest != null) await cancelRequest;
      if (!requestSubmitted) {
        // A revoked scope must not leave a bridge waiting for its first input.
        process.kill(ProcessSignal.sigterm);
        await process.stdin.close().catchError((Object _) {});
        await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            throw StateError('未提交执行的桥接进程未能及时停止');
          },
        );
        await stdoutDone.future;
      }
    }
  }

  Future<void> disableNetwork({
    required String tenantId,
    required String taskId,
    required int networkRevision,
  }) => _runnerControl({
    'action': 'disable_network',
    'task_id': _runnerTaskId(tenantId, taskId),
    'network_revision': networkRevision,
  });

  Future<void> _runnerControl(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 35),
  }) async {
    await _runnerControlResult(request, timeout: timeout);
  }

  Future<Map<String, dynamic>> _runnerControlResult(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 8),
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
        .map((line) {
          if (line.length > 32 * 1024 * 1024)
            throw const FormatException('沙箱控制响应超过大小限制');
          return line;
        })
        .toList();
    unawaited(process.stderr.drain<void>());
    process.stdin.writeln(jsonEncode(request));
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw TimeoutException('沙箱控制请求超时');
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
      throw StateError(result?['error']?.toString() ?? '无法完成沙箱控制请求');
    }
    return result!;
  }

  void _recordExecution(
    String tenant,
    String taskId,
    String id,
    Map<String, dynamic> fields,
  ) {
    _mutateTask(tenant, taskId, (task) {
      final operations = Map<String, dynamic>.from(
        task['code_execution_operations'] as Map? ?? const {},
      );
      final previous = operations[id] as Map?;
      final updated = <String, dynamic>{
        ...?previous,
        ...fields,
        if (previous?['status'] == 'persisted' &&
            const {'submitted', 'unknown'}.contains(fields['status']))
          'status': 'persisted',
      };
      var scopes = Map<String, dynamic>.from(
        task['scope_operations'] as Map? ?? const {},
      );
      if (fields['scope_operation_id'] is String) {
        final scopeId = fields['scope_operation_id'] as String;
        final parent = scopes[scopeId];
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeId) ||
            parent is! Map ||
            parent['effect'] != 'external' ||
            parent['budget_owner'] != 'code' ||
            parent['arguments_hash'] is! String ||
            parent['status'] != 'running' ||
            parent['request_identity'] !=
                (task['turn_scope'] as Map?)?['request_identity'] ||
            (parent['execution_id'] != null && parent['execution_id'] != id))
          throw StateError('代码执行与原操作的身份不匹配，未提交运行');
        scopes[scopeId] = {...parent, 'execution_id': id};
        updated['scope_arguments_hash'] = parent['arguments_hash'];
      }
      operations[id] = updated;
      var value = <String, dynamic>{
        ...task,
        'code_execution_operations': operations,
        'scope_operations': scopes,
      };
      if (updated['status'] == 'persisted' &&
          updated['scope_operation_id'] is String) {
        final scopeId = updated['scope_operation_id'] as String;
        final parent = scopes[scopeId];
        if (parent is Map &&
            parent['execution_id'] == id &&
            parent['arguments_hash'] == updated['scope_arguments_hash']) {
          final saved =
              jsonDecode(
                    utf8.decode(
                      store.getObject(
                        'tenants/$tenant/tasks/$taskId/executions/$id/result.json',
                      ),
                    ),
                  )
                  as Map;
          if (saved['ok'] is bool && saved['ok'] == updated['ok']) {
            final names = (saved['artifact_names'] as List? ?? const [])
                .cast<String>();
            scopes[scopeId] = {
              ...parent,
              'status': saved['ok'] == true ? 'succeeded' : 'failed',
              'result': {
                'ok': saved['ok'],
                'output': _executionText(saved, names),
              },
            };
            final uncertain = Map<String, dynamic>.from(
              task['uncertain_network_scopes'] as Map? ?? const {},
            );
            final requestId = parent['request_identity'];
            final prior = uncertain[requestId];
            if (prior is Map && prior['operation_ids'] is List) {
              final pending = (prior['operation_ids'] as List)
                  .where((other) => other != scopeId)
                  .toList();
              if (pending.isEmpty && prior['unlinked'] != true) {
                uncertain.remove(requestId);
              } else {
                uncertain[requestId] = {...prior, 'operation_ids': pending};
              }
            }
            value = {
              ...value,
              'scope_operations': scopes,
              'uncertain_network_scopes': uncertain,
            };
          }
        }
      }
      return value;
    });
  }

  void _storeExecutionOutput(
    String tenant,
    String task,
    String id,
    Map<String, dynamic> result, {
    List<String> artifactNames = const [],
  }) {
    store.putTaskBlob(
      'tenants/$tenant/tasks/$task/executions/$id/result.json',
      utf8.encode(
        jsonEncode({
          'ok': result['ok'] == true,
          'stdout': result['stdout'],
          'stderr': result['stderr'],
          'error': result['error'],
          'artifact_names': artifactNames,
        }),
      ),
    );
  }

  static String _executionText(Map result, List<String> artifactNames) {
    final output = [
      result['stdout']?.toString() ?? '',
      if (result['stderr']?.toString().isNotEmpty == true)
        'stderr:\n${result['stderr']}',
      if (artifactNames.isNotEmpty) '已生成文件：${artifactNames.join('、')}',
      if (result['error'] != null) 'error: ${result['error']}',
    ].where((value) => value.isNotEmpty).join('\n');
    return output.isEmpty
        ? (result['ok'] == true ? '代码已执行，没有标准输出。' : 'Docker 沙箱执行失败')
        : output;
  }

  /// Recovered stdout is task data, never permission or executable instructions.
  List<Map<String, dynamic>> recoveredExecutionResults(
    String tenant,
    String task,
  ) {
    final operations =
        store.get('task/$tenant/$task')?.value['code_execution_operations']
            as Map? ??
        const {};
    final recovered = operations.entries
        .where(
          (entry) =>
              entry.value is Map && (entry.value as Map)['recovered'] == true,
        )
        .toList();
    return recovered.reversed
        .take(4)
        .map((entry) {
          final id = entry.key.toString();
          if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id))
            return <String, dynamic>{};
          final result =
              jsonDecode(
                    utf8.decode(
                      store.getObject(
                        'tenants/$tenant/tasks/$task/executions/$id/result.json',
                      ),
                    ),
                  )
                  as Map;
          final output = jsonEncode(result);
          return <String, dynamic>{
            'execution_id': id,
            'status': 'persisted',
            'output': output.length <= 4000
                ? output
                : '${output.substring(0, 1000)}\n…\n${output.substring(output.length - 2900)}',
            'truncated': output.length > 4000,
          };
        })
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Map<String, dynamic> _executionControl(
    String action,
    String tenant,
    String task,
    String id,
    int issuedAt,
  ) => {
    'action': action,
    'task_id': _runnerTaskId(tenant, task),
    'execution_id': id,
    'issued_at': issuedAt,
  };

  Future<Map<String, dynamic>?> _executionResult(
    String tenant,
    String task,
    String id,
    int issuedAt,
  ) async {
    try {
      final response = await _runnerControlResult(
        _executionControl('execution_result', tenant, task, id, issuedAt),
      );
      final completion = response['completion'];
      if (response['finished'] == true &&
          completion is Map &&
          completion['acknowledged'] != true &&
          completion['execution_id'] == id)
        return Map<String, dynamic>.from(completion);
    } on Object {
      // The runner may have restarted or the control connection may be down.
      // Neither case authorizes replay of an operation with unknown effects.
    }
    return null;
  }

  Future<void> _ackExecution(
    String tenant,
    String task,
    String id,
    int issuedAt,
  ) async {
    try {
      final response = await _runnerControlResult(
        _executionControl('ack_execution', tenant, task, id, issuedAt),
      );
      if (response['acknowledged'] == true) {
        _recordExecution(tenant, task, id, {
          'ack_pending': false,
          if (response.containsKey('cleanup_pending'))
            'cleanup_pending': response['cleanup_pending'] == true,
        });
      }
    } on Object {
      // Files are already durable. A later read retries this acknowledgement.
    }
  }

  /// Reconcile existing execution IDs without submitting code again.
  Future<void> recoverExecutions({
    required String tenantId,
    required String taskId,
    CancellationToken? cancellation,
  }) async {
    await recoverMcpLeases(
      tenantId: tenantId,
      taskId: taskId,
      cancellation: cancellation,
    );
    final operations =
        store.get('task/$tenantId/$taskId')?.value['code_execution_operations']
            as Map? ??
        const {};
    for (final entry in operations.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final operation = entry.value as Map;
      final issuedAt = operation['issued_at'];
      if (issuedAt is! int) continue;
      if (operation['status'] == 'persisted') {
        if (operation['ack_pending'] == true)
          await _ackExecution(tenantId, taskId, entry.key as String, issuedAt);
        if (operation['cleanup_pending'] == true) {
          try {
            final status = await _runnerControlResult(
              _executionControl(
                'execution_result',
                tenantId,
                taskId,
                entry.key as String,
                issuedAt,
              ),
            );
            if (status['finished'] == true &&
                status['cleanup_pending'] == false) {
              _recordExecution(tenantId, taskId, entry.key as String, {
                'cleanup_pending': false,
              });
              _finishSandboxCleanup(
                tenantId,
                taskId,
                operation['sandbox_id']?.toString(),
                false,
                null,
              );
            }
          } on Object {
            // Keep the pending cleanup record when the runner cannot confirm it.
          }
        }
        continue;
      }
      if (!const {'submitted', 'unknown'}.contains(operation['status']))
        continue;
      final result = await _executionResult(
        tenantId,
        taskId,
        entry.key as String,
        issuedAt,
      );
      if (result == null) continue;
      final artifactNames = await _saveArtifacts(
        tenantId,
        taskId,
        const {
              'plugin_hook_read_only',
              'plugin_command_context_read_only',
            }.contains(operation['execution_profile'])
            ? const []
            : result['artifacts'],
        operationId: entry.key as String,
        dependencyBuild:
            operation['execution_profile'] ==
            SandboxExecutionProfile.dependencyBuild.wireName,
      );
      _recordExecution(tenantId, taskId, entry.key as String, {
        'cleanup_pending': result['cleanup_pending'] == true,
      });
      _finishSandboxCleanup(
        tenantId,
        taskId,
        operation['sandbox_id']?.toString(),
        result['cleanup_pending'] == true,
        result['sandbox_id']?.toString(),
      );
      _storeExecutionOutput(
        tenantId,
        taskId,
        entry.key as String,
        result,
        artifactNames: artifactNames,
      );
      _recordExecution(tenantId, taskId, entry.key as String, {
        'status': 'persisted',
        'ok': result['ok'] == true,
        'ack_pending': true,
        'recovered': true,
      });
      await _ackExecution(tenantId, taskId, entry.key as String, issuedAt);
    }
  }

  void _claimExecution(
    String tenantId,
    String taskId, {
    required bool skillScript,
  }) {
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) throw StateError('任务不存在');
      if (current.value['cancel_requested'] == true ||
          const {'cancelled', 'stopped'}.contains(current.value['status'])) {
        throw StateError('任务已停止，不能继续执行操作');
      }
      final scripts = (current.value['skill_script_runs'] as num? ?? 0).toInt();
      final executions = (current.value['code_execution_runs'] as num? ?? 0)
          .toInt();
      if (taskToolOperationsUsed(current.value) >= limits.toolOperations) {
        throw ExecutionBudgetExceeded('本次任务的代码执行预算已用完');
      }
      if (skillScript && scripts >= limits.scriptExecutions) {
        throw ExecutionBudgetExceeded('本次任务的技能脚本执行次数已用完');
      }
      try {
        store.put(key, {
          ...current.value,
          'code_execution_runs': executions + 1,
          if (skillScript) 'skill_script_runs': scripts + 1,
          'updated_at': _now(),
        }, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('无法锁定代码执行预算');
  }

  String inputFingerprint({
    required String tenantId,
    required String taskId,
    required List<Map<String, dynamic>> materials,
    List<String>? artifactIds,
  }) => inputBinding(
    tenantId: tenantId,
    taskId: taskId,
    materials: materials,
    artifactIds: artifactIds,
  ).fingerprint;

  ({String fingerprint, List<String> names}) inputBinding({
    required String tenantId,
    required String taskId,
    required List<Map<String, dynamic>> materials,
    List<String>? artifactIds,
  }) {
    final inputs = _materialsForNextExecution(
      tenantId: tenantId,
      taskId: taskId,
      materials: materials,
      artifactIds: artifactIds,
    );
    return (
      fingerprint: sha256.convert(utf8.encode(jsonEncode(inputs))).toString(),
      names: inputs
          .map((input) => input['name']?.toString() ?? '任务文件')
          .toList(),
    );
  }

  List<Map<String, dynamic>> _materialsForNextExecution({
    required String tenantId,
    required String taskId,
    required List<Map<String, dynamic>> materials,
    List<String>? artifactIds,
  }) {
    const maxMaterialBytes = 20 * 1024 * 1024;
    final result = materials
        .map((material) => Map<String, dynamic>.from(material))
        .toList();
    var totalBytes = result.fold<int>(0, (total, material) {
      if (material['base64'] is String) {
        return total + base64Decode(material['base64'] as String).length;
      }
      final value = material['content'] ?? material['text'] ?? '';
      return total + utf8.encode(value.toString()).length;
    });
    if (totalBytes > maxMaterialBytes) {
      throw const FormatException('任务资料超过 20 MB');
    }

    final task = store.get('task/$tenantId/$taskId')?.value;
    final artifacts = (task?['artifacts'] as List? ?? const [])
        .whereType<Map>()
        .toList()
        .reversed;
    final requestedIds = artifactIds?.toSet();
    final foundIds = <String>{};
    final reusedNames = <String>{};
    for (final artifact in artifacts) {
      final id = artifact['id']?.toString() ?? '';
      if (requestedIds != null && !requestedIds.contains(id)) continue;
      final name = artifact['name']?.toString() ?? '';
      if (requestedIds == null && reusedNames.contains(name)) continue;
      final objectKey = artifact['object_key']?.toString() ?? '';
      if (!objectKey.startsWith('tenants/$tenantId/tasks/$taskId/artifacts/')) {
        continue;
      }
      final bytes = store.getObject(objectKey);
      if (totalBytes + bytes.length > maxMaterialBytes) {
        if (requestedIds != null) {
          throw const FormatException('选中的产物与任务资料总大小超过 20 MB');
        }
        continue;
      }
      result.add({
        'name': name,
        'artifact_id': id,
        'media_type': artifact['media_type'],
        'base64': base64Encode(bytes),
      });
      totalBytes += bytes.length;
      foundIds.add(id);
      reusedNames.add(name);
    }
    if (requestedIds != null && !foundIds.containsAll(requestedIds)) {
      throw StateError('选中的产物不属于当前任务或已不可用');
    }
    return result;
  }

  String _runnerTaskId(String tenantId, String taskId) =>
      sha256.convert(utf8.encode('$tenantId/$taskId')).toString();

  Future<List<String>> _saveArtifacts(
    String tenantId,
    String taskId,
    Object? rawArtifacts, {
    String? operationId,
    bool dependencyBuild = false,
  }) async {
    if (rawArtifacts is! List || rawArtifacts.isEmpty) return const [];
    if (rawArtifacts.length > 10) throw StateError('任务最多可返回 10 个产物');
    final pending = <Map<String, dynamic>>[];
    var total = 0;
    for (final raw in rawArtifacts.whereType<Map>()) {
      final rawName = raw['name']?.toString() ?? '';
      final name = _safeArtifactName(rawName);
      final nativeAnnotation =
          store.get('task/$tenantId/$taskId')?.value['native_annotation'] ==
          true;
      final internal =
          nativeAnnotation &&
          (RegExp(r'^annotation-ocr-[a-f0-9]{16}\.json$').hasMatch(name) ||
              name == 'annotation-receipt.json');
      final encoded = raw['base64']?.toString() ?? '';
      final bytes = base64Decode(encoded);
      final maximum = dependencyBuild && name == 'dependencies.zip'
          ? 20 * 1024 * 1024
          : 10 * 1024 * 1024;
      if (bytes.length > maximum) {
        throw StateError('产物 $name 超过 ${maximum ~/ (1024 * 1024)} MB');
      }
      total += bytes.length;
      if (total > 20 * 1024 * 1024) {
        throw StateError('本次任务产物总大小超过 20 MB');
      }
      // Annotation scans/renders can return the unchanged output directory
      // again. One unchanged file is one artifact across script operations.
      final id = nativeAnnotation
          ? sha256
                .convert(
                  utf8.encode('annotation/$name/${sha256.convert(bytes)}'),
                )
                .toString()
          : operationId == null
          ? _uuid.v4().replaceAll('-', '')
          : sha256
                .convert(
                  utf8.encode('$operationId/$name/${sha256.convert(bytes)}'),
                )
                .toString();
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
        if (internal) 'internal': true,
      });
    }
    if (pending.isEmpty) return const [];
    _mutateTask(tenantId, taskId, (task) {
      final artifacts = (task['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      final knownIds = artifacts.map((artifact) => artifact['id']).toSet();
      final fresh = pending
          .where((artifact) => knownIds.add(artifact['id']))
          .toList();
      if (fresh.isEmpty) return task;
      artifacts.addAll(fresh);
      final events = (task['events'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      events.add({
        'seq': events.length,
        'type': 'artifacts_ready',
        'artifacts': [for (final item in fresh) _publicArtifact(item)],
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
    _mutateTask(tenantId, taskId, (task) {
      final operations = [
        ...(task['code_execution_operations'] as Map? ?? const {}).values
            .whereType<Map>(),
        ...(task['mcp_cleanup_operations'] as Map? ?? const {}).values
            .whereType<Map>(),
      ];
      final trackedPending = operations.any(
        (operation) => operation['cleanup_pending'] == true,
      );
      final currentOperations = operations
          .where((operation) => operation['sandbox_id'] == task['sandbox_id'])
          .toList();
      final currentWasCleaned = currentOperations.any(
        (operation) => operation['cleanup_pending'] == false,
      );
      final hasOtherActive =
          task['sandbox_id'] != null &&
          task['sandbox_id'] != id &&
          !currentWasCleaned;
      final pending =
          cleanupPending ||
          trackedPending ||
          (hasOtherActive &&
              currentOperations.isEmpty &&
              task['sandbox_cleanup_pending'] == true);
      return {
        ...task,
        'sandbox_id': hasOtherActive
            ? task['sandbox_id']
            : pending
            ? (id ?? task['sandbox_id'])
            : null,
        'sandbox_cleanup_pending': pending,
        'sandbox_cleanup_deadline': pending ? _now() + 300 : null,
        'updated_at': _now(),
      };
    });
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
    if (item['internal'] == true) 'internal': true,
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
