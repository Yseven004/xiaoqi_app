import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'capability_import_service.dart';
import 'store.dart';
import 'plugin_components.dart';

/// Prompt commands are data, not host shell commands or authorization policies.
class PluginCommand {
  static const profileVersion = 1;
  PluginCommand(this.path, this.description, this.body, this.userOnly);
  final String path;
  final String description;
  final String body;
  final bool userOnly;

  /// Reindex old installed metadata from the same immutable source bytes. This
  /// neither changes the pinned source version nor executes an installer.
  static Map refreshVersion(
    CloudStore store,
    String tenant,
    String id,
    Map version,
  ) {
    if (version['plugin_command_profile'] == profileVersion ||
        (version['components'] as List? ?? const []).whereType<Map>().any(
          (c) => c['type'] == 'command',
        ))
      return version;
    final key = 'cap/$tenant/$id';
    final initial = store.get(key)?.value;
    if (initial == null) return version;
    final compatibility = initial['compatibility'];
    final knownNoCommands =
        initial['current_version_id'] == version['id'] &&
        compatibility is Map &&
        compatibility['warnings'] is List &&
        !(compatibility['warnings'] as List).any(
          (w) => w.toString().startsWith('commands '),
        );
    Map? candidate;
    if (!knownNoCommands) {
      final files = store.getImmutable(version['artifact_key'].toString());
      candidate = CapabilityImportService.discover(
        files,
        '',
      ).where((c) => c['kind'] == 'plugin' && c['root'] == '').firstOrNull;
    }
    final commands = (candidate?['components'] as List? ?? const [])
        .whereType<Map>()
        .where((c) => c['type'] == 'command' && c['status'] != 'unsupported')
        .toList();
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
      if (bound['plugin_command_profile'] == profileVersion) return bound;
      final updated = {
        ...bound,
        'plugin_command_profile': profileVersion,
        'components': [
          for (final component
              in (bound['components'] as List? ?? const []).whereType<Map>())
            if (component['type'] != 'command') component,
          ...commands,
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
    throw StateError('插件命令目录更新冲突，请重试');
  }

  static PluginCommand parse(String path, List<int> bytes) {
    if (bytes.length > 128 * 1024) throw const FormatException('命令正文超过 128 KB');
    final text = utf8.decode(bytes);
    final header = RegExp(
      r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
    ).firstMatch(text);
    final metadata = header == null ? const {} : loadYaml(header.group(1)!);
    if (metadata is! Map) throw const FormatException('命令 YAML 格式无效');
    final body = header == null ? text : text.substring(header.end);
    if (body.trim().isEmpty) throw const FormatException('命令正文为空');
    if (RegExp(r'!`').hasMatch(body)) {
      throw const FormatException('命令包含动态 Shell 插值，需要额外执行适配');
    }
    if (metadata['context'] != null ||
        metadata['agent'] != null ||
        metadata['hooks'] != null ||
        metadata['permissionMode'] != null ||
        metadata['skills'] != null ||
        metadata['mcpServers'] != null ||
        (metadata['model'] != null && metadata['model'] != 'inherit')) {
      throw const FormatException('命令指定独立 agent 或模型，需要对应宿主适配');
    }
    if (metadata['disable-model-invocation'] != null &&
        metadata['disable-model-invocation'] is! bool) {
      throw const FormatException('命令调用控制格式无效');
    }
    if (metadata['description'] != null && metadata['description'] is! String) {
      throw const FormatException('命令说明必须是文本');
    }
    if (RegExp(r'\$\{CLAUDE_PLUGIN_(?!ROOT\})').hasMatch(body)) {
      throw const FormatException('命令依赖尚未提供的插件宿主目录');
    }
    return PluginCommand(
      path,
      metadata['description']?.toString() ?? path,
      body,
      metadata['disable-model-invocation'] == true,
    );
  }

  String render(String arguments, {String pluginRoot = '.'}) {
    if (utf8.encode(arguments).length > 16 * 1024) {
      throw const FormatException('命令参数超过 16 KB');
    }
    // Tokenize the original template once; inserted arguments cannot recursively
    // become templates, shell expansion, or a second command invocation.
    final words = _words(arguments);
    return body.replaceAllMapped(
      RegExp(
        r'\$\{CLAUDE_PLUGIN_ROOT\}|\$ARGUMENTS(?:\[([0-9]+)\])?|\$([0-9]+)',
      ),
      (match) {
        if (match.group(0) == r'${CLAUDE_PLUGIN_ROOT}') return pluginRoot;
        final index = match.group(1) ?? match.group(2);
        if (index == null) return arguments;
        final value = int.tryParse(index);
        return value != null && value < words.length ? words[value] : '';
      },
    );
  }

  static List<String> _words(String arguments) {
    final result = <String>[];
    var word = StringBuffer();
    String? quote;
    var started = false;
    for (var i = 0; i < arguments.length; i++) {
      final char = arguments[i];
      if (char == r'\' && quote != "'") {
        if (quote == '"' &&
            i + 1 < arguments.length &&
            !const {'"', r'\', r'$', '`', '\n'}.contains(arguments[i + 1])) {
          word.write(char);
          started = true;
          continue;
        }
        if (++i == arguments.length) throw const FormatException('命令参数转义不完整');
        word.write(arguments[i]);
        started = true;
      } else if (char == quote) {
        quote = null;
      } else if (quote == null && (char == '"' || char == "'")) {
        quote = char;
        started = true;
      } else if (quote == null && RegExp(r'\s').hasMatch(char)) {
        if (started) {
          result.add(word.toString());
          word = StringBuffer();
          started = false;
        }
      } else {
        word.write(char);
        started = true;
      }
    }
    if (quote != null) throw const FormatException('命令参数引号未闭合');
    if (started) result.add(word.toString());
    return result;
  }

  static List<Map<String, dynamic>> inspect(
    Map<String, List<int>> files,
    String root,
    Map manifest,
  ) {
    final scoped = CapabilityImportService.subtree(files, root);
    final paths = <String>{};
    final locations = <String>['commands'];
    final declared = manifest['commands'];
    if (declared != null) {
      final values = declared is List ? declared : [declared];
      for (final value in values) {
        if (value is! String || !value.startsWith('./')) {
          throw const FormatException('命令声明需要插件内相对文件或目录路径');
        }
        final path = CapabilityImportService.safePath(
          value.substring(2).replaceFirst(RegExp(r'/$'), ''),
        );
        if (!scoped.containsKey(path) &&
            !scoped.keys.any((p) => p.startsWith('$path/'))) {
          throw const FormatException('命令声明路径不存在');
        }
        locations.add(path);
      }
    }
    for (final location in locations) {
      if (scoped.containsKey(location) && location.endsWith('.md'))
        paths.add(location);
      paths.addAll(
        scoped.keys.where(
          (p) => p.startsWith('$location/') && p.endsWith('.md'),
        ),
      );
    }
    return [
      for (final path in paths.toList()..sort())
        _inspectOne(scoped, root, path),
    ];
  }

  static Map<String, dynamic> _inspectOne(
    Map<String, List<int>> files,
    String root,
    String path,
  ) {
    String? issue;
    PluginCommand? command;
    try {
      command = parse(path, files[path]!);
    } on FormatException catch (error) {
      issue = error.message;
    } on Object {
      issue = '命令正文、元数据或执行方式尚不可用，请检查命令文件';
    }
    return {
      'id':
          'command-${sha256.convert(utf8.encode(path)).toString().substring(0, 16)}',
      'type': 'command',
      'root': root,
      'source_path': path,
      'name': path.split('/').last.replaceFirst(RegExp(r'\.md$'), ''),
      'description': command?.description ?? path,
      'user_only': command?.userOnly ?? false,
      'has_scripts': files.keys.any(
        (p) => RegExp(
          r'^scripts/.+\.(?:py|js|mjs|cjs|ts|mts|sh|bash)$',
        ).hasMatch(p),
      ),
      'status': issue == null ? 'supported' : 'unsupported',
      'issues': [if (issue != null) issue],
    };
  }
}

class SelectedPluginCommands extends SelectedPluginComponents {
  SelectedPluginCommands(
    CloudStore store,
    String tenant,
    Object? selections, {
    bool discover = false,
    Iterable<String> excludedIds = const [],
  }) : super(
         store,
         tenant,
         selections,
         componentType: 'command',
         refreshVersion: PluginCommand.refreshVersion,
         discover: discover,
         excludedIds: excludedIds,
       );

  PluginCommand command(String alias) {
    final entry = entries[alias];
    if (entry == null) throw StateError('命令不在本次选择的插件中');
    final bytes = files(alias)[entry['source_path']];
    if (bytes == null) throw StateError('插件命令文件已缺失');
    return PluginCommand.parse(entry['source_path'].toString(), bytes);
  }
}
