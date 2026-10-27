import 'dart:convert';

/// A plugin declaration resolved against its immutable installed package.
/// Environment interpolation never reads the API process's environment.
class IsolatedMcpSpec {
  IsolatedMcpSpec(
    this.command,
    this.environment,
    this.files, {
    this.capabilityId,
    this.versionId,
  });

  final List<String> command;
  final Map<String, String> environment;
  final Map<String, List<int>> files;
  final String? capabilityId;
  final String? versionId;

  static List<String> declaredCommand(Map config) {
    final command = config['command'];
    final args = config['args'] ?? const [];
    if (command is! String ||
        command.trim().isEmpty ||
        args is! List ||
        args.any((value) => value is! String) ||
        args.length > 63) {
      throw const FormatException('MCP 命令或参数格式无效');
    }
    final values = [command, ...args.cast<String>()];
    if (values.any(
      (value) => value.contains('\u0000') || utf8.encode(value).length > 4096,
    )) {
      throw const FormatException('MCP 命令参数超出限制');
    }
    return values;
  }

  static ({String name, String version, int index})? npmDependency(Map config) {
    final values = declaredCommand(config);
    if (!const {'npx', 'npx.cmd'}.contains(values.first)) return null;
    var index = 1;
    while (index < values.length &&
        const {'-y', '--yes', '--no-install'}.contains(values[index])) {
      index++;
    }
    if (index >= values.length)
      throw const FormatException('npx 缺少 registry 包名');
    final match = RegExp(
      r'^((?:@[a-z0-9_.-]+/)?[a-z0-9_.-]+)(?:@([A-Za-z0-9v^~<>=*| .xX+-]+))?$',
    ).firstMatch(values[index]);
    if (match == null)
      throw const FormatException('npx 需要 registry 包声明，不能执行 URL 或临时下载脚本');
    return (
      name: match.group(1)!,
      version: match.group(2) ?? '*',
      index: index,
    );
  }

  static Map<String, List<int>> installationFiles(
    Map config,
    Map<String, List<int>> files,
  ) {
    final dependency = npmDependency(config);
    if (dependency == null) return files;
    final manifest = files['package.json'] == null
        ? <String, dynamic>{'private': true}
        : Map<String, dynamic>.from(
            jsonDecode(utf8.decode(files['package.json']!)) as Map,
          );
    final dependencies = Map<String, dynamic>.from(
      manifest['dependencies'] as Map? ?? const {},
    );
    dependencies[dependency.name] = dependency.version;
    manifest['dependencies'] = dependencies;
    return {...files, 'package.json': utf8.encode(jsonEncode(manifest))};
  }

  static IsolatedMcpSpec resolve(
    Map config,
    Map<String, List<int>> files, {
    String? capabilityId,
    String? versionId,
  }) {
    var argv = declaredCommand(config);
    final dependency = npmDependency(config);
    if (dependency != null) {
      final root = 'node_modules/${dependency.name}';
      final bytes = files['$root/package.json'];
      if (bytes == null)
        throw FormatException('MCP 依赖 ${dependency.name} 尚未安装，请重新安装插件');
      final manifest = jsonDecode(utf8.decode(bytes)) as Map;
      final bins = manifest['bin'];
      String? executable;
      if (bins is String) executable = bins;
      if (bins is Map) {
        executable =
            (bins[dependency.name.split('/').last] ??
                    (bins.length == 1 ? bins.values.single : null))
                ?.toString();
      }
      if (executable == null) throw const FormatException('MCP 包没有唯一命令入口');
      executable = executable.replaceFirst(RegExp(r'^\./'), '');
      if (executable.startsWith('/') ||
          executable.contains('\\') ||
          executable.split('/').any((part) => part == '..' || part.isEmpty) ||
          !files.containsKey('$root/$executable')) {
        throw const FormatException('MCP 命令入口不存在或路径越界');
      }
      argv = [
        'node',
        '/workspace/skill/$root/$executable',
        ...argv.skip(dependency.index + 1),
      ];
    }
    String expand(String value) {
      var resolved = value;
      for (final name in [
        'CLAUDE_PLUGIN_ROOT',
        'CODEX_PLUGIN_ROOT',
        'PLUGIN_ROOT',
      ]) {
        resolved = resolved
            .replaceAll('\${$name}', '/workspace/skill')
            .replaceAll('\$$name', '/workspace/skill');
      }
      if (RegExp(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}').hasMatch(resolved)) {
        throw const FormatException('MCP 缺少插件专属配置；不会继承服务器环境变量');
      }
      return resolved;
    }

    final rawEnvironment = config['env'] ?? const {};
    if (rawEnvironment is! Map ||
        rawEnvironment.length > 32 ||
        rawEnvironment.values.any((value) => value is! String)) {
      throw const FormatException('MCP 环境配置格式无效');
    }
    return IsolatedMcpSpec(
      argv.map(expand).toList(),
      {
        for (final entry in rawEnvironment.entries)
          entry.key.toString(): expand(entry.value as String),
      },
      files,
      capabilityId: capabilityId,
      versionId: versionId,
    );
  }
}
