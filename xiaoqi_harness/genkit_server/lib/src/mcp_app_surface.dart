import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'mcp_tool_result.dart';
import 'store.dart';
import 'tool_execution.dart';

/// MCP Apps metadata is a display/dispatch contract, never an action grant.
class McpAppMetadata {
  static const mime = 'text/html;profile=mcp-app';
  static const artifactMime = 'application/vnd.xiaoqi.mcp-app+json';
  static Map ui(Map tool) {
    final meta = tool['_meta'];
    return meta is Map && meta['ui'] is Map ? meta['ui'] as Map : const {};
  }

  static bool visible(Map tool, String audience) {
    final visibility = ui(tool)['visibility'];
    if (visibility == null) return true;
    if (visibility is! List ||
        visibility.any((value) => value != 'model' && value != 'app')) {
      throw const FormatException('MCP App 工具 visibility 无效');
    }
    return visibility.contains(audience);
  }

  static String? resourceUri(Map tool) {
    final meta = tool['_meta'];
    final value =
        ui(tool)['resourceUri'] ??
        (meta is Map ? meta['ui/resourceUri'] : null);
    if (value == null) return null;
    if (value is! String || value.length > 2048)
      throw const FormatException('MCP App 资源 URI 无效');
    final parsed = Uri.tryParse(value);
    if (parsed == null ||
        parsed.scheme != 'ui' ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasFragment) {
      throw const FormatException('MCP App 只接受工具声明的 ui 资源');
    }
    return value;
  }
}

/// Only the authenticated API reads this record; HTML is not model context.
class McpAppSurfaceStore {
  McpAppSurfaceStore(this.store, this.tenant, this.task);
  final CloudStore store;
  final String tenant, task;
  String _key(String id) {
    if (!RegExp(r'^app-[a-f0-9]{32}$').hasMatch(id))
      throw const FormatException('交互结果 ID 无效');
    return 'private_mcp_apps/$tenant/$task/$id';
  }

  Future<Map<String, dynamic>?> publish({
    required ToolExecution execution,
    required String connectionId,
    required String connectionBinding,
    required Map<String, dynamic> tool,
    required Map<String, dynamic> input,
    required Map<String, dynamic> result,
    required Map<String, dynamic> selection,
    Map<String, dynamic> source = const {},
    required Future<Map<String, dynamic>> Function(String uri) readResource,
    required void Function() check,
  }) async {
    final uri = McpAppMetadata.resourceUri(tool);
    if (uri == null || result['isError'] == true) return null;
    check();
    execution.check('read');
    final resource = await readResource(uri);
    check();
    execution.check('read');
    final contents = resource['contents'];
    if (contents is! List || contents.length != 1 || contents.single is! Map) {
      throw const FormatException('MCP App 需要单个完整 HTML 资源');
    }
    final content = contents.single as Map;
    if (content['uri'] != uri ||
        content['mimeType'] != McpAppMetadata.mime ||
        content['text'] is! String) {
      throw const FormatException('MCP App 资源来源或类型不匹配');
    }
    final bytes = utf8.encode(content['text'] as String);
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024)
      throw const FormatException('MCP App HTML 为空或超过 2 MiB');
    final viewResult = {
      for (final field in ['content', 'structuredContent', 'isError'])
        if (result.containsKey(field)) field: result[field],
    };
    if (utf8.encode(jsonEncode(viewResult)).length > 2 * 1024 * 1024)
      throw const FormatException('MCP App 结果超过 2 MiB');
    final scope = store.get(execution.key)?.value['turn_scope'];
    final id =
        'app-${ToolExecution.digest([execution.requestIdentity, connectionId, connectionBinding, tool, input, viewResult, sha256.convert(bytes).toString()]).substring(0, 32)}';
    final htmlKey = 'tenants/$tenant/tasks/$task/apps/$id/html';
    store.putTaskBlob(htmlKey, bytes);
    final record = {
      'id': id,
      'connection_id': connectionId,
      'connection_binding': connectionBinding,
      'tool': tool,
      'input': input,
      'result': viewResult,
      'selection': selection,
      'source': source,
      'scope_binding': ToolExecution.digest(scope ?? {}),
      'request_identity': execution.requestIdentity,
      'request_text': execution.requestText,
      'html_key': htmlKey,
      'html_sha256': sha256.convert(bytes).toString(),
      'resource_uri': uri,
    };
    final current = store.get(_key(id));
    if (current == null) store.put(_key(id), record, null);
    check();
    execution.check('read');
    // Reuse existing authenticated artifact delivery and conversation history.
    return McpToolResultAdapter(store, tenant, task).normalize({
      'content': [
        {
          'type': 'resource',
          'resource': {
            'uri': 'xiaoqi-app:$id',
            'mimeType': McpAppMetadata.artifactMime,
            'text': jsonEncode({
              'app_id': id,
              'task_id': task,
              'title': tool['title'] ?? tool['name'],
              'last_result': viewResult,
            }),
          },
        },
      ],
    });
  }

  Map<String, dynamic> load(
    String id, {
    required void Function(Map record) check,
  }) {
    final record = store.get(_key(id));
    if (record == null) throw StateError('交互结果不存在');
    final taskValue = store.get('task/$tenant/$task')?.value;
    if (taskValue == null ||
        taskValue['cancel_requested'] == true ||
        const {'cancelled', 'stopped'}.contains(taskValue['status']) ||
        ToolExecution.digest(taskValue['turn_scope'] ?? {}) !=
            record.value['scope_binding']) {
      throw StateError('交互结果的任务权限已变化');
    }
    check(record.value);
    final bytes = store.getObject(record.value['html_key'] as String);
    if (sha256.convert(bytes).toString() != record.value['html_sha256'])
      throw StateError('交互资源完整性检查失败');
    return {...record.value, 'html': utf8.decode(bytes)};
  }

  void updateResult(
    String id,
    Map<String, dynamic> result, {
    required void Function(Map) check,
  }) {
    if (utf8.encode(jsonEncode(result)).length > 2 * 1024 * 1024)
      throw const FormatException('面板结果过大');
    load(id, check: check);
    final saved = store.get(_key(id))!;
    store.put(_key(id), {...saved.value, 'result': result}, saved.revision);
  }
}
