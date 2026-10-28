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
        // Build hooks need their own source files, not API-host paths or data.
        skillFiles: files,
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
    return SandboxMcpTransport.connect(
      runnerUrl: Uri.parse(url),
      runnerToken: token,
      beforeStart: (identity) {
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
    store.delete('private_mcp_lease/$tenantId/$taskId/${transport.leaseId}');
  }

  /// Recover outputs from a prior API process. Never creates a replacement lease.
  Future<void> recoverMcpLeases({
    required String tenantId,
    required String taskId,
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
      try {
        transport = SandboxMcpTransport.forRecovery(
          runnerUrl: Uri.parse(url),
          runnerToken: token,
          leaseId: id,
          leaseToken: leaseToken,
        );
        await finishMcp(tenantId, taskId, transport);
      } on Object {
        // Preserve identity until artifacts and acknowledgment both persist.
        // An unavailable runner does not prove that the original call failed.
      } finally {
        await transport?.close();
      }
    }
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
  }) async {
    cancellation.throwIfCancelled();
    beforeSubmit?.call();
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
        if (scopeOperationId != null) 'scope_operation_id': scopeOperationId,
      });
      requestSubmitted = true;
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
        result['artifacts'],
        operationId: executionId,
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
  }) async {
    await recoverMcpLeases(tenantId: tenantId, taskId: taskId);
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
        result['artifacts'],
        operationId: entry.key as String,
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
  }) async {
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
      final id = operationId == null
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
