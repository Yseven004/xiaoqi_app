import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'capability_import_service.dart';
import 'plugin_components.dart';
import 'plugin_hook_command.dart';
import 'plugin_hooks.dart';
import 'store.dart';

class PluginHookCatalog {
  static const profileVersion = 2;
  static const toolEvents = {'PreToolUse', 'PostToolUse', 'PostToolUseFailure'};

  static PluginHooks parse(Map<String, List<int>> files) {
    for (final path in [
      'plugin.json',
      '.claude-plugin/plugin.json',
      '.codex-plugin/plugin.json',
    ]) {
      final bytes = files[path];
      if (bytes == null) continue;
      final manifest = jsonDecode(utf8.decode(bytes));
      if (manifest is! Map) throw const FormatException('插件 manifest 无效');
      return PluginHooks.parse(files, manifest, manifestPath: path);
    }
    return PluginHooks.parse(files, const {}, manifestPath: 'plugin.json');
  }

  static List<Map<String, dynamic>> inspect(
    Map<String, List<int>> files,
    String root,
  ) {
    final parsed = parse(files);
    final dependencies = [
      'package.json',
      'requirements.txt',
      'pyproject.toml',
      'setup.py',
    ].any(files.containsKey);
    return [
      for (final hook in parsed.handlers)
        {
          'id': hook.id,
          'type': 'hook',
          'root': root,
          'source_path': hook.sourcePath,
          'name': '${hook.event} · ${hook.type}',
          'description': '插件 ${hook.event} 处理器',
          'hook_event': hook.event,
          'status':
              toolEvents.contains(hook.event) &&
                  PluginHookCommand.unsupported(hook) == null
              ? 'partial'
              : 'unsupported',
          'issues': [
            if (!toolEvents.contains(hook.event)) '此生命周期事件尚待映射',
            if (PluginHookCommand.unsupported(hook) case final String issue)
              issue,
            '工具事件已映射；ask/defer 等高级控制仅在宿主已有对应流程时执行',
          ],
          'has_dependencies': dependencies,
        },
      for (final issue in parsed.issues)
        {
          'id':
              'hook-issue-${sha256.convert(utf8.encode('${issue.sourcePath}/${issue.pointer}')).toString().substring(0, 24)}',
          'type': 'hook',
          'root': root,
          'source_path': issue.sourcePath,
          'name': '无效 hook 配置',
          'description': issue.pointer,
          'status': 'unsupported',
          'issues': [issue.reason],
        },
    ];
  }

  /// Refresh only this component profile from the pinned immutable artifact.
  static Map refreshVersion(
    CloudStore store,
    String tenant,
    String id,
    Map version,
  ) {
    if (version['plugin_hook_profile'] == profileVersion) return version;
    final files = store.getImmutable(version['artifact_key'].toString());
    final candidate = CapabilityImportService.discover(
      files,
      '',
    ).where((c) => c['kind'] == 'plugin' && c['root'] == '').firstOrNull;
    final hooks = (candidate?['components'] as List? ?? const [])
        .whereType<Map>()
        .where((c) => c['type'] == 'hook' && c['status'] != 'unsupported')
        .toList();
    final key = 'cap/$tenant/$id';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null ||
          current.value['enabled'] == false ||
          current.value['deleted_at'] != null)
        return version;
      final versions = (current.value['versions'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final bound = versions
          .where(
            (v) =>
                v['id'] == version['id'] &&
                v['artifact_key'] == version['artifact_key'],
          )
          .firstOrNull;
      if (bound == null) return version;
      if (bound['plugin_hook_profile'] == profileVersion) return bound;
      final updated = {
        ...bound,
        'plugin_hook_profile': profileVersion,
        'components': [
          for (final c
              in (bound['components'] as List? ?? const []).whereType<Map>())
            if (c['type'] != 'hook') c,
          ...hooks,
        ],
      };
      try {
        store.put(key, {
          ...current.value,
          'versions': [
            for (final v in versions)
              if (identical(v, bound)) updated else v,
          ],
          if (candidate != null &&
              current.value['current_version_id'] == version['id'])
            'compatibility': candidate,
        }, current.revision);
        return updated;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('插件 hook 目录更新冲突');
  }
}

class SelectedPluginHooks extends SelectedPluginComponents {
  SelectedPluginHooks(
    CloudStore store,
    String tenant,
    Object? selections, {
    Iterable<String> excludedIds = const [],
  }) : super(
         store,
         tenant,
         selections,
         componentType: 'hook',
         refreshVersion: PluginHookCatalog.refreshVersion,
         discover: true,
         discoverSiblingComponents: true,
         excludedIds: excludedIds,
       ) {
    for (final alias in entries.keys.toList()) {
      try {
        _definitions[alias] = PluginHookCatalog.parse(files(alias)).handlers
            .singleWhere((hook) => hook.id == entries[alias]!['component_id']);
      } on Object {
        entries.remove(alias);
      }
    }
  }

  final _definitions = <String, PluginHook>{};

  /// Selectors are immutable metadata; IO must still validate files(alias).
  PluginHook definition(String alias) =>
      _definitions[alias] ?? (throw StateError('hook 来源不在当前任务中'));

  PluginHook hook(String alias) {
    final entry = entries[alias];
    if (entry == null) throw StateError('hook 来源不在当前任务中');
    files(alias);
    return definition(alias);
  }
}
