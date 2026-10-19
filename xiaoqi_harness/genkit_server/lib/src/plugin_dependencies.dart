import 'dart:convert';

import 'mcp_connection_service.dart';
import 'store.dart';

class PluginDependencies {
  final connectionIds = <String>{};
  final messages = <String>[];
  final unavailable = <String>[];

  static Map<String, dynamic> declarations(Map<String, List<int>> files) {
    final result = <String, dynamic>{};
    final pending = [
      '.mcp.json',
      'mcp.json',
      'plugin.json',
      '.claude-plugin/plugin.json',
      '.codex-plugin/plugin.json',
    ];
    final visited = <String>{};
    while (pending.isNotEmpty && visited.length < 16) {
      final path = pending.removeAt(0).replaceFirst(RegExp(r'^\./'), '');
      if (path.startsWith('/') ||
          path.contains('\\') ||
          path.split('/').any((part) => part == '..' || part == '.')) {
        throw const FormatException('插件连接配置路径越界');
      }
      if (!visited.add(path) || !files.containsKey(path)) continue;
      final config = jsonDecode(utf8.decode(files[path]!));
      if (config is! Map) continue;
      final servers = config['mcpServers'] ?? config['servers'];
      if (servers is Map) {
        result.addAll(Map<String, dynamic>.from(servers));
      } else if (servers is String) {
        pending.add(servers);
      } else if (servers is List) {
        pending.addAll(servers.whereType<String>());
      } else if (!path.endsWith('plugin.json')) {
        for (final entry in config.entries) {
          if (entry.value is Map &&
              ((entry.value as Map)['url'] != null ||
                  (entry.value as Map)['command'] != null)) {
            result[entry.key.toString()] = entry.value;
          }
        }
      }
    }
    return result;
  }

  /// Reads declarations only. Plugin files never supply account credentials.
  static PluginDependencies resolve(
    CloudStore store,
    String tenant,
    Object? selections,
  ) {
    final result = PluginDependencies();
    for (final selection
        in (selections is List ? selections : const []).whereType<Map>()) {
      final record = store.get('cap/$tenant/${selection['id']}')?.value;
      if (record == null ||
          record['kind'] != 'plugin' ||
          record['enabled'] == false ||
          record['deleted_at'] != null)
        continue;
      final version = (record['versions'] as List? ?? const [])
          .whereType<Map>()
          .where((v) => v['id'] == selection['version_id'])
          .firstOrNull;
      if (version == null) throw StateError('插件版本已失效');
      final files = store.getImmutable(version['artifact_key'].toString());
      Map<String, dynamic> definitions;
      try {
        definitions = declarations(files);
      } on FormatException {
        result.messages.add('插件 ${record['name']} 的连接声明格式或路径无效');
        result.unavailable.add('插件连接声明格式或路径无效');
        continue;
      }
      for (final entry in definitions.entries) {
        final config = entry.value;
        if (config is! Map ||
            config['url'] is! String ||
            config['command'] != null) {
          result.unavailable.add('插件连接 ${entry.key} 需要尚未支持的本地宿主');
          result.messages.add(
            '插件 ${record['name']} 的 ${entry.key} 需要尚未支持的本地宿主',
          );
          continue;
        }
        Uri url;
        try {
          url = McpConnectionService.parseRemoteUrl(config['url'] as String);
        } on FormatException {
          result.unavailable.add('插件连接 ${entry.key} 尚未配置有效地址');
          result.messages.add(
            '插件 ${record['name']} 的 ${entry.key} 需要先配置有效的远程连接',
          );
          continue;
        }
        final owned = store
            .list('mcp/$tenant/', limit: 500)
            .where(
              (item) =>
                  item.$2.value['url'] == url.toString() &&
                  item.$2.value['enabled'] != false,
            )
            .firstOrNull;
        if (owned == null) {
          result.unavailable.add('插件连接 ${entry.key} 尚未绑定账号连接');
          result.messages.add(
            '插件 ${record['name']} 的 MCP 依赖 ${entry.key} 尚未连接，请先在 MCP 连接器中完成设置；不得假称该依赖已执行',
          );
        } else {
          result.connectionIds.add(owned.$2.value['id'].toString());
          result.messages.add(
            '插件 ${record['name']} 的 ${entry.key} 已绑定账号连接，调用仍需通过权限检查',
          );
        }
      }
      final warnings = (record['compatibility'] is Map
          ? record['compatibility']['warnings']
          : null);
      if (warnings is List)
        result.messages.addAll(
          warnings
              .map((value) => value.toString())
              .where((value) => !value.startsWith('MCP ')),
        );
    }
    return result;
  }
}
