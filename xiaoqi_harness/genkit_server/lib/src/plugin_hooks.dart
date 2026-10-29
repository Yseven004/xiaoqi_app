import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'capability_import_service.dart';

/// Parsed source data only. A declaration never starts a process or grants IO.
class PluginHook {
  PluginHook._(
    this.sourcePath,
    this.pointer,
    this.event,
    this.matcher,
    Map<String, dynamic> config,
  ) : config = _freeze(config) as Map<String, dynamic>;
  final String sourcePath, pointer, event;
  final String? matcher;
  final Map<String, dynamic> config;
  String get type => config['type'] as String;
  String get id =>
      'hook-${sha256.convert(utf8.encode('$sourcePath\u0000$pointer')).toString().substring(0, 24)}';

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          entry.key.toString(): _freeze(entry.value),
      });
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }
}

class PluginHookIssue {
  const PluginHookIssue(this.sourcePath, this.pointer, this.reason);
  final String sourcePath, pointer, reason;
}

/// Default hooks/hooks.json plus declared files/inline maps in source order.
/// Files require the hooks wrapper; inline declarations are the event map.
class PluginHooks {
  PluginHooks._();
  static const maxConfigBytes = 128 * 1024;
  final _handlers = <PluginHook>[];
  final _issues = <PluginHookIssue>[];
  List<PluginHook> get handlers => List.unmodifiable(_handlers);
  List<PluginHookIssue> get issues => List.unmodifiable(_issues);

  static PluginHooks parse(
    Map<String, List<int>> files,
    Map manifest, {
    required String manifestPath,
  }) {
    final result = PluginHooks._();
    final seen = <String>{};
    void file(String path, {required bool declared}) {
      final bytes = files[path];
      if (bytes == null) {
        if (declared) result._issue(path, '', '声明的 hooks 文件不存在');
        return;
      }
      if (!seen.add(path)) return;
      if (bytes.length > maxConfigBytes) {
        result._issue(path, '', 'hooks 配置超过 128 KiB');
        return;
      }
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map || value['hooks'] is! Map) {
          result._issue(path, '', 'hooks 文件需要顶层 hooks 事件对象');
          return;
        }
        result._events(value['hooks'] as Map, path, '/hooks');
      } on FormatException {
        result._issue(path, '', 'hooks 文件不是有效的 UTF-8 JSON');
      }
    }

    file('hooks/hooks.json', declared: false);
    final declaration = manifest['hooks'];
    final values = declaration is List
        ? declaration
        : [if (declaration != null) declaration];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      final pointer = declaration is List ? '/hooks/$i' : '/hooks';
      if (value is String) {
        try {
          if (!value.startsWith('./') || !value.endsWith('.json')) {
            throw const FormatException('hooks 声明需要插件内 JSON 相对路径');
          }
          final path = CapabilityImportService.safePath(value.substring(2));
          file(path, declared: true);
        } on FormatException {
          result._issue(manifestPath, pointer, 'hooks 声明路径无效或越过插件根目录');
        }
      } else if (value is Map) {
        if (utf8.encode(jsonEncode(value)).length > maxConfigBytes) {
          result._issue(manifestPath, pointer, '内联 hooks 配置超过 128 KiB');
        } else {
          result._events(value, manifestPath, pointer);
        }
      } else {
        result._issue(manifestPath, pointer, 'hooks 声明需要路径或内联事件对象');
      }
    }
    return result;
  }

  static String _part(Object? value) =>
      value.toString().replaceAll('~', '~0').replaceAll('/', '~1');
  void _issue(String source, String pointer, String reason) =>
      _issues.add(PluginHookIssue(source, pointer, reason));

  void _events(Map events, String source, String prefix) {
    for (final entry in events.entries) {
      final event = entry.key.toString();
      final pointer = '$prefix/${_part(event)}';
      if (event.isEmpty || entry.value is! List) {
        _issue(source, pointer, 'hook 事件需要非空名称及处理组数组');
        continue;
      }
      final groups = entry.value as List;
      for (var i = 0; i < groups.length; i++) {
        final group = groups[i];
        final groupPointer = '$pointer/$i';
        if (group is! Map ||
            group['hooks'] is! List ||
            (group['matcher'] != null && group['matcher'] is! String)) {
          _issue(source, groupPointer, 'hook 处理组或 matcher 格式无效');
          continue;
        }
        final handlers = group['hooks'] as List;
        for (var j = 0; j < handlers.length; j++) {
          final handler = handlers[j];
          final handlerPointer = '$groupPointer/hooks/$j';
          if (handler is! Map ||
              handler['type'] is! String ||
              (handler['type'] as String).trim().isEmpty) {
            _issue(source, handlerPointer, 'hook 处理器缺少 type');
            continue;
          }
          final config = Map<String, dynamic>.from(handler);
          final type = config['type'];
          final requiredField = switch (type) {
            'command' => 'command',
            'http' => 'url',
            'prompt' || 'agent' => 'prompt',
            _ => null,
          };
          if (requiredField != null &&
              (config[requiredField] is! String ||
                  (config[requiredField] as String).trim().isEmpty)) {
            _issue(source, handlerPointer, 'hook $type 缺少 $requiredField');
            continue;
          }
          final timeout = config['timeout'];
          if (timeout != null &&
              (timeout is! num || !timeout.isFinite || timeout <= 0)) {
            _issue(source, handlerPointer, 'hook timeout 必须是有限正数');
            continue;
          }
          final badFlag = ['async', 'asyncRewake', 'once']
              .where((flag) => config[flag] != null && config[flag] is! bool)
              .firstOrNull;
          if (badFlag != null) {
            _issue(source, handlerPointer, 'hook $badFlag 必须是布尔值');
            continue;
          }
          // Unknown event/type/options are retained for explicit host mapping.
          // Matchers are data: no untrusted regexp runs on the API host.
          _handlers.add(
            PluginHook._(
              source,
              handlerPointer,
              event,
              group['matcher'] as String?,
              config,
            ),
          );
        }
      }
    }
  }
}
