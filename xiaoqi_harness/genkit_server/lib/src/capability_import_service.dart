import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';
import 'package:genkit/genkit.dart' show CancellationToken;

import 'store.dart';

typedef DependencyPreparer =
    Future<Map<String, List<int>>> Function(
      String tenant,
      Map<String, List<int>> files, {
      CancellationToken? cancellation,
    });

class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final bytes = <int>[];
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit)
      throw const FormatException('解压内容超过声明大小');
    bytes.addAll(data);
  }

  @override
  void close() {}
}

/// GitHub is the only download origin. Repository content is data, never a
/// command. Tests inject a downloader rather than weaken production URL checks.
class CapabilityImportService {
  CapabilityImportService(
    this.store, {
    this.download,
    this.prepareDependencies,
  });
  final CloudStore store;
  final Future<List<int>> Function(Uri uri, int limit)? download;
  final DependencyPreparer? prepareDependencies;
  static const maxArchiveBytes = 20 * 1024 * 1024;
  static const maxExpandedBytes = 50 * 1024 * 1024;
  static const maxFiles = 3000;
  static const _uuid = Uuid();
  final _installing = <String>{};

  static String safePath(String path) {
    if (path.isEmpty ||
        path.length > 240 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1f:]').hasMatch(path) ||
        path.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw const FormatException('文件路径不安全');
    }
    return path;
  }

  static ({String owner, String repo, List<String> tail}) parseUrl(
    String value,
  ) {
    final decoded = Uri.decodeComponent(value.trim());
    if (decoded.contains('\\') ||
        decoded.split('/').any((p) => p == '.' || p == '..')) {
      throw const FormatException('GitHub 链接不能包含路径跳转');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入公开 GitHub 仓库或子目录的 HTTPS 链接');
    }
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(parts[0]) ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(parts[1]) ||
        (parts.length > 2 && (parts[2] != 'tree' || parts.length < 4))) {
      throw const FormatException('请使用仓库首页或 /tree/分支/子目录链接');
    }
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    safePath('${parts[0]}/$repo');
    if (parts.length > 3) safePath(parts.skip(3).join('/'));
    return (owner: parts[0], repo: repo, tail: parts.skip(3).toList());
  }

  Future<List<int>> _fetch(Uri uri, int limit) async {
    if (download != null) return download!(uri, limit);
    if (uri.scheme != 'https' ||
        !const {'github.com', 'codeload.github.com'}.contains(uri.host)) {
      throw const FormatException('不允许的下载来源');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'Xiaoqi-Capability-Importer');
      request.headers.set('Accept', '*/*');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 404
              ? '仓库、分支不存在或不是公开仓库'
              : 'GitHub 请求失败（${response.statusCode}），请稍后重试',
          uri: uri,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > limit)
          throw const FormatException('下载内容超过大小限制');
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<({String ref, String directory, String sha})> _resolveRef(
    String owner,
    String repo,
    List<String> tail,
  ) async {
    if (tail.isNotEmpty && RegExp(r'^[a-f0-9]{40}$').hasMatch(tail.first)) {
      return (
        ref: tail.first,
        directory: tail.skip(1).join('/'),
        sha: tail.first,
      );
    }
    // Git's anonymous ref advertisement avoids GitHub REST's shared-IP quota.
    // It downloads metadata only: no checkout, hooks, or repository execution.
    final bytes = await _fetch(
      Uri.https('github.com', '/$owner/$repo.git/info/refs', {
        'service': 'git-upload-pack',
      }),
      4 * 1024 * 1024,
    );
    final refs = <String, String>{};
    String? defaultBranch;
    for (var offset = 0; offset < bytes.length;) {
      if (offset + 4 > bytes.length)
        throw const FormatException('GitHub 版本信息不完整');
      final size = int.tryParse(
        ascii.decode(bytes.sublist(offset, offset + 4)),
        radix: 16,
      );
      if (size == null || size < 0 || offset + size > bytes.length)
        throw const FormatException('GitHub 版本信息无效');
      if (size == 0) {
        offset += 4;
        continue;
      }
      if (size < 4) throw const FormatException('GitHub 版本信息无效');
      final packet = utf8.decode(bytes.sublist(offset + 4, offset + size));
      final match = RegExp(r'^([a-f0-9]{40}) ([^\x00\n ]+)').firstMatch(packet);
      if (match != null) refs[match.group(2)!] = match.group(1)!;
      defaultBranch ??= RegExp(
        r'symref=HEAD:refs/heads/([^\x00\n ]+)',
      ).firstMatch(packet)?.group(1);
      offset += size;
    }
    if (tail.isEmpty && refs['HEAD'] != null)
      return (ref: defaultBranch ?? 'HEAD', directory: '', sha: refs['HEAD']!);
    for (var count = tail.length; count >= 1; count--) {
      final name = tail.take(count).join('/');
      final sha =
          refs['refs/heads/$name'] ??
          refs['refs/tags/$name^{}'] ??
          refs['refs/tags/$name'];
      if (sha != null)
        return (ref: name, directory: tail.skip(count).join('/'), sha: sha);
    }
    throw const FormatException('公开仓库或分支不存在，请检查地址');
  }

  Future<Map<String, dynamic>> inspect(String tenant, String url) async {
    for (final (key, doc) in store.list('import/$tenant/', limit: 1000)) {
      if (DateTime.parse(
        doc.value['expires_at'].toString(),
      ).isBefore(DateTime.now())) {
        store.deleteImmutable(doc.value['artifact_key'].toString());
        store.delete(key);
      }
    }
    final source = parseUrl(url);
    final resolved = await _resolveRef(source.owner, source.repo, source.tail);
    final ref = resolved.ref;
    final directory = resolved.directory;
    final sha = resolved.sha;
    final bytes = await _fetch(
      Uri.https(
        'codeload.github.com',
        '/${source.owner}/${source.repo}/zip/$sha',
      ),
      maxArchiveBytes,
    );
    final files = decodeRepository(bytes);
    if (directory.isNotEmpty &&
        !files.keys.any((p) => p.startsWith('$directory/'))) {
      throw const FormatException('仓库内没有这个子目录');
    }
    final candidates = discover(files, directory);
    final licenses = files.keys
        .where(
          (p) =>
              !p.contains('/') &&
              RegExp(
                r'^(license|copying|notice)',
                caseSensitive: false,
              ).hasMatch(p),
        )
        .toList();
    for (final candidate in candidates) {
      candidate['repository_license_files'] = licenses;
    }
    final id = _uuid.v4();
    final object = 'tenants/$tenant/imports/$id.zip';
    store.putImmutable(object, files);
    final inspection = <String, dynamic>{
      'id': id,
      'source_url': 'https://github.com/${source.owner}/${source.repo}',
      'requested_url': url,
      'ref': ref,
      'directory': directory,
      'commit': sha,
      'candidates': candidates,
      'artifact_key': object,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .toIso8601String(),
    };
    store.put('import/$tenant/$id', inspection, null);
    return publicInspection(inspection);
  }

  static Map<String, List<int>> decodeRepository(List<int> bytes) {
    if (bytes.length > maxArchiveBytes)
      throw const FormatException('压缩包超过 20 MB');
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > maxFiles)
      throw const FormatException('仓库文件过多');
    var total = 0;
    final files = <String, List<int>>{};
    final seen = <String>{};
    String? prefix;
    for (final header in directory.fileHeaders) {
      final file = header.file!;
      final raw = header.filename.endsWith('/')
          ? header.filename.substring(0, header.filename.length - 1)
          : header.filename;
      safePath(raw);
      if (!seen.add(raw)) throw const FormatException('仓库包含重复路径');
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if ((file.flags & 1) != 0 ||
          (type != 0 && type != 0x8000 && type != 0x4000)) {
        throw const FormatException('不支持加密文件、链接或特殊文件');
      }
      if (file.filename != header.filename)
        throw const FormatException('压缩包文件名不一致');
      final parts = raw.split('/');
      prefix ??= parts.first;
      if (parts.first != prefix) throw const FormatException('仓库压缩包根目录不一致');
      if (header.filename.endsWith('/')) continue;
      total += header.uncompressedSize;
      if (header.uncompressedSize > 10 * 1024 * 1024 ||
          total > maxExpandedBytes)
        throw const FormatException('解压内容过大');
      final path = safePath(parts.skip(1).join('/'));
      final sink = _BoundedBytes(header.uncompressedSize);
      final compressed = file.getStream(decompress: false).toUint8List();
      if (file.compressionMethod == CompressionType.deflate) {
        final decoder = io.ZLibDecoder(raw: true).startChunkedConversion(sink);
        // Bounded input chunks also bound native zlib's intermediate output.
        for (var offset = 0; offset < compressed.length; offset += 1024) {
          decoder.add(
            compressed.sublist(
              offset,
              (offset + 1024).clamp(0, compressed.length),
            ),
          );
        }
        decoder.close();
      } else if (file.compressionMethod == CompressionType.none) {
        sink.add(compressed);
      } else {
        throw const FormatException('仅支持标准 ZIP 存储或 deflate 压缩');
      }
      if (sink.bytes.length != header.uncompressedSize ||
          getCrc32(sink.bytes) != header.crc32)
        throw const FormatException('压缩包内容校验失败');
      files[path] = sink.bytes;
    }
    return files;
  }

  static String _join(String root, String path) =>
      root.isEmpty ? path : '$root/$path';
  static Map<String, List<int>> subtree(
    Map<String, List<int>> files,
    String root,
  ) => {
    for (final e in files.entries)
      if (root.isEmpty || e.key.startsWith('$root/'))
        (root.isEmpty ? e.key : e.key.substring(root.length + 1)): e.value,
  };

  static List<Map<String, dynamic>> discover(
    Map<String, List<int>> files,
    String directory,
  ) {
    final results = <Map<String, dynamic>>[];
    final covered = <String>[];
    final manifests =
        files.keys
            .where(
              (p) =>
                  p == _join(directory, 'plugin.json') ||
                  p.endsWith('/plugin.json'),
            )
            .where((p) => directory.isEmpty || p.startsWith('$directory/'))
            .toList()
          ..sort();
    for (final path in manifests) {
      String root;
      if (path.endsWith('.codex-plugin/plugin.json') ||
          path.endsWith('.claude-plugin/plugin.json')) {
        root = path.replaceFirst(
          RegExp(r'(?:^|/)[.]?(?:codex|claude)-plugin/plugin\.json$'),
          '',
        );
      } else {
        root = path == 'plugin.json'
            ? ''
            : path.substring(0, path.length - '/plugin.json'.length);
      }
      if (covered.contains(root)) continue;
      Map manifest;
      try {
        manifest = jsonDecode(utf8.decode(files[path]!)) as Map;
      } catch (_) {
        continue;
      }
      final standard = path == _join(root, 'plugin.json');
      if (standard &&
          !RegExp(
            r'agent-?plugins',
          ).hasMatch(manifest[r'$schema']?.toString() ?? ''))
        continue;
      covered.add(root);
      if (standard) {
        final name = manifest['name'];
        final invalid =
            manifest[r'$schema'] !=
                'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json' ||
            name is! String ||
            name.length > 64 ||
            !RegExp(
              r'^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$',
            ).hasMatch(name) ||
            [
              'version',
              'description',
              'homepage',
              'repository',
              'license',
            ].any((k) => manifest[k] != null && manifest[k] is! String) ||
            (manifest['keywords'] != null &&
                (manifest['keywords'] is! List ||
                    (manifest['keywords'] as List).any((v) => v is! String))) ||
            (manifest['author'] != null &&
                (manifest['author'] is! Map ||
                    (manifest['author'] as Map).entries.any(
                      (e) =>
                          !['name', 'email', 'url'].contains(e.key) ||
                          e.value is! String,
                    )));
        if (invalid) {
          results.add(
            _candidate(root, 'plugin', name?.toString() ?? '插件', '', [], [
              'plugin.json 不符合 Agent Plugins 1.0.0 清单格式',
            ]),
          );
          continue;
        }
      }
      final roots = <String>{_join(root, 'skills')};
      if (!standard && manifest['skills'] != null) {
        final declared = manifest['skills'] is List
            ? manifest['skills'] as List
            : [manifest['skills']];
        for (final item in declared) {
          if (item is! String || !item.startsWith('./')) continue;
          roots.add(
            _join(
              root,
              safePath(item.substring(2).replaceFirst(RegExp(r'/$'), '')),
            ),
          );
        }
      }
      final components = <Map<String, dynamic>>[];
      for (final skillPath in files.keys.where(
        (p) => p.endsWith('/SKILL.md'),
      )) {
        final skillRoot = skillPath.substring(0, skillPath.length - 9);
        if (!roots.any(
          (r) => standard
              ? skillRoot.startsWith('$r/') &&
                    !skillRoot.substring(r.length + 1).contains('/')
              : skillRoot == r || skillRoot.startsWith('$r/'),
        ))
          continue;
        components.add(inspectSkill(files, skillRoot));
      }
      final unsupported = <String>[];
      if (manifest['extensions'] != null)
        unsupported.add('客户端专有 extensions 不执行');
      final scoped = subtree(files, root);
      if ((!standard && manifest['mcpServers'] != null) ||
          scoped.containsKey('mcp.json') ||
          scoped.containsKey('.mcp.json'))
        unsupported.add('MCP 组件暂不支持');
      for (final type in ['hooks', 'commands', 'agents', 'apps']) {
        if (manifest[type] != null ||
            scoped.keys.any((p) => p.startsWith('$type/')) ||
            (type == 'apps' && scoped.containsKey('.app.json')))
          unsupported.add('$type 组件暂不支持');
      }
      results.add(
        _candidate(
          root,
          'plugin',
          manifest['name']?.toString() ?? '插件',
          manifest['description']?.toString() ?? '',
          components,
          unsupported,
        ),
      );
    }
    for (final path in files.keys.where(
      (p) => p == 'SKILL.md' || p.endsWith('/SKILL.md'),
    )) {
      final root = path == 'SKILL.md' ? '' : path.substring(0, path.length - 9);
      if (directory.isNotEmpty &&
          root != directory &&
          !root.startsWith('$directory/'))
        continue;
      if (covered.any((p) => p.isEmpty || root == p || root.startsWith('$p/')))
        continue;
      final skill = inspectSkill(files, root);
      results.add(
        _candidate(
          root,
          'skill',
          skill['name'].toString(),
          skill['description'].toString(),
          [skill],
          [],
        ),
      );
    }
    if (results.length > 100) throw const FormatException('候选扩展过多，请导入具体子目录');
    return results;
  }

  static Map<String, dynamic> _candidate(
    String root,
    String kind,
    String name,
    String description,
    List<Map<String, dynamic>> components,
    List<String> warnings,
  ) {
    final usable = components.where((c) => c['status'] == 'supported').length;
    return {
      'id': sha256
          .convert(utf8.encode('$kind:$root'))
          .toString()
          .substring(0, 20),
      'root': root,
      'kind': kind,
      'name': name,
      'description': description,
      'status': usable == 0
          ? 'unsupported'
          : usable < components.length || warnings.isNotEmpty
          ? 'partial'
          : 'supported',
      'components': components,
      'warnings': warnings,
      'verification': '已检查格式和已知运行要求；实际任务效果需要运行验证',
    };
  }

  static Map<String, dynamic> inspectSkill(
    Map<String, List<int>> allFiles,
    String root,
  ) {
    final files = subtree(allFiles, root);
    final issues = <String>[];
    var name = root.split('/').last;
    var description = '';
    try {
      final text = utf8.decode(files['SKILL.md']!);
      final match = RegExp(
        r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
      ).firstMatch(text);
      if (match == null) throw const FormatException('SKILL.md 缺少 YAML 信息');
      final header = loadYaml(match.group(1)!) as Map;
      name = header['name']?.toString() ?? '';
      description = header['description']?.toString() ?? '';
      if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name) ||
          name.length > 64 ||
          description.isEmpty ||
          description.length > 1024 ||
          text.substring(match.end).trim().isEmpty)
        issues.add('技能名称、说明或正文无效');
      if (RegExp(
        r'\bmcp(?:__|[_ -]|\b)|\b(?:Claude Code|Codex)[ -]only\b|\$\{CLAUDE_PROJECT_DIR\}',
        caseSensitive: false,
      ).hasMatch(text))
        issues.add('技能引用 MCP 或专有客户端能力，当前无法验证独立运行');
      final allowed = header['allowed-tools']?.toString() ?? '';
      if (allowed.isNotEmpty &&
          RegExp(
            r'Bash|Shell|Computer|Browser|mcp',
            caseSensitive: false,
          ).hasMatch(allowed))
        issues.add('依赖当前未提供的工具：$allowed');
      for (final path in files.keys) {
        safePath(path);
        if (path.startsWith('.xiaoqi/')) issues.add('包含保留的运行环境目录');
        if (path.startsWith('scripts/') &&
            !RegExp(r'\.(py|js|mjs|cjs|ts|mts|json|md|txt)$').hasMatch(path))
          issues.add('脚本类型暂不支持：$path');
      }
      if (files.containsKey('pyproject.toml') &&
          !files.containsKey('requirements.txt'))
        issues.add('Python 依赖需要提供 requirements.txt');
      if (files.containsKey('setup.py') || files.containsKey('Dockerfile'))
        issues.add('需要自定义构建环境，暂不支持');
      validateDependencies(files);
    } catch (e) {
      issues.add(e is FormatException ? e.message : '技能文件格式无效');
    }
    return {
      'id': sha256.convert(utf8.encode(root)).toString().substring(0, 16),
      'root': root,
      'name': name,
      'description': description,
      'status': issues.isEmpty ? 'supported' : 'unsupported',
      'issues': issues,
      'has_scripts': files.keys.any((p) => p.startsWith('scripts/')),
      'has_dependencies':
          files.containsKey('requirements.txt') ||
          files.containsKey('package.json'),
      'license': files.keys
          .where((p) => p.toLowerCase().startsWith('license'))
          .toList(),
    };
  }

  static void validateDependencies(Map<String, List<int>> files) {
    if (files.containsKey('requirements.txt')) {
      for (final line in const LineSplitter().convert(
        utf8.decode(files['requirements.txt']!),
      )) {
        final value = line.split('#').first.trim();
        if (value.isEmpty) continue;
        if (!RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9_.-]*(?:\[[A-Za-z0-9_,.-]+\])?(?:\s*(?:==|>=|<=|~=|!=|>|<)\s*[A-Za-z0-9.*+_-]+(?:\s*,\s*(?:==|>=|<=|~=|!=|>|<)\s*[A-Za-z0-9.*+_-]+)*)?$',
        ).hasMatch(value))
          throw const FormatException('Python 依赖只支持 PyPI 包名和版本，禁止 URL、脚本和额外源');
      }
    }
    if (files.containsKey('package.json')) {
      final value = jsonDecode(utf8.decode(files['package.json']!)) as Map;
      if (value['scripts'] is Map &&
          (value['scripts'] as Map).keys.any(
            (k) => const [
              'preinstall',
              'install',
              'postinstall',
              'prepare',
            ].contains(k),
          ))
        throw const FormatException('npm 包需要安装脚本，暂不支持');
      for (final field in ['dependencies', 'optionalDependencies']) {
        final deps = value[field];
        if (deps == null) continue;
        if (deps is! Map) throw const FormatException('npm 依赖格式无效');
        for (final entry in deps.entries) {
          if (!RegExp(
                r'^(?:@[a-z0-9_.-]+/)?[a-z0-9_.-]+$',
              ).hasMatch(entry.key.toString()) ||
              !RegExp(
                r'^[0-9v^~<>=*| .xX+-]+$',
              ).hasMatch(entry.value.toString()))
            throw const FormatException('npm 依赖只支持 registry 包和版本范围');
        }
      }
    }
  }

  Map<String, dynamic> getInspection(String tenant, String id) {
    final doc = store.get('import/$tenant/${safePath(id)}');
    if (doc == null) throw const FormatException('导入检查不存在');
    if (DateTime.parse(
      doc.value['expires_at'].toString(),
    ).isBefore(DateTime.now()))
      throw const FormatException('检查已过期，请重新导入');
    return doc.value;
  }

  static Map<String, dynamic> publicInspection(Map<String, dynamic> value) =>
      {...value}..remove('artifact_key');

  Future<StoredDocument> install(
    String tenant,
    String inspectionId,
    String candidateId, {
    String? updateId,
    int? expectedRevision,
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final inspection = getInspection(tenant, inspectionId);
    final candidate = (inspection['candidates'] as List)
        .whereType<Map>()
        .where((c) => c['id'] == candidateId)
        .firstOrNull;
    if (candidate == null || candidate['status'] == 'unsupported')
      throw const FormatException('这个扩展没有可安装的技能');
    final id =
        'import-${sha256.convert(utf8.encode('${inspection['source_url']}/${candidate['root']}')).toString().substring(0, 32)}';
    if (updateId != null && updateId != id)
      throw const FormatException('更新来源与已安装扩展不一致');
    final key = 'cap/$tenant/$id';
    if (!_installing.add(key)) throw StateError('该扩展正在安装，请稍候');
    String? pendingArtifact;
    try {
      final current = store.get(key);
      if (updateId != null &&
          (current == null ||
              current.revision != expectedRevision ||
              current.value['deleted_at'] != null))
        throw const FormatException('安装记录已变化，请刷新后重试');
      final versionId = '${inspection['commit']}-${candidate['id']}';
      if (current?.value['current_version_id'] == versionId &&
          current?.value['deleted_at'] == null)
        return current!;
      if (current != null &&
          current.value['deleted_at'] == null &&
          updateId == null)
        throw const FormatException('该扩展已安装；请从详情页检查更新');
      final previous = (current?.value['versions'] as List? ?? [])
          .whereType<Map>()
          .where((v) => v['id'] == versionId)
          .firstOrNull;
      if (previous != null) {
        return store.put(key, {
          ...current!.value,
          'current_version_id': versionId,
          'deleted_at': null,
          'enabled': current.value['deleted_at'] != null
              ? true
              : current.value['enabled'] ?? true,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'compatibility': candidate,
          'source': {
            for (final k in ['source_url', 'requested_url', 'commit', 'ref'])
              k: inspection[k],
            'root': candidate['root'],
          },
        }, current.revision);
      }
      final all = store.getImmutable(inspection['artifact_key'].toString());
      final package = subtree(all, candidate['root'].toString());
      final components = <Map<String, dynamic>>[];
      for (final raw in (candidate['components'] as List).whereType<Map>()) {
        if (raw['status'] != 'supported') continue;
        final files = subtree(all, raw['root'].toString());
        if (raw['has_dependencies'] == true) {
          if (prepareDependencies == null)
            throw const FormatException('服务器依赖准备服务尚未配置');
          files.addAll(
            await prepareDependencies!(
              tenant,
              files,
              cancellation: cancellation,
            ),
          );
        }
        cancellation?.throwIfCancelled();
        final relative = candidate['root'] == raw['root']
            ? ''
            : raw['root'].toString().substring(
                candidate['root'].toString().isEmpty
                    ? 0
                    : candidate['root'].toString().length + 1,
              );
        for (final e in files.entries) {
          package[_join(relative, e.key)] = e.value;
        }
        components.add({...raw, 'root': relative});
      }
      final digest = digestFiles(package);
      final artifact =
          'tenants/$tenant/capabilities/$id/versions/$versionId-$digest.zip';
      store.putImmutable(artifact, package);
      pendingArtifact = artifact;
      final now = DateTime.now().toUtc().toIso8601String();
      final versions = (current?.value['versions'] as List? ?? [])
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      if (!versions.any((v) => v['id'] == versionId))
        versions.add({
          'id': versionId,
          'number': versions.length + 1,
          'content_hash': digest,
          'created_at': now,
          'artifact_key': artifact,
          'components': components,
        });
      final saved = store.put(key, {
        'schema_version': 2,
        'id': id,
        'kind': candidate['kind'],
        'name': candidate['name'],
        'description': candidate['description'],
        'versions': versions,
        'current_version_id': versionId,
        'created_at': current?.value['created_at'] ?? now,
        'updated_at': now,
        'show_in_menu': current?.value['show_in_menu'] ?? true,
        'enabled': current?.value['enabled'] ?? true,
        'deleted_at': null,
        'origin': 'github',
        'source': {
          for (final k in ['source_url', 'requested_url', 'commit', 'ref'])
            k: inspection[k],
          'root': candidate['root'],
        },
        'compatibility': candidate,
        'installation_state': 'installed',
      }, current?.revision);
      pendingArtifact = null;
      return saved;
    } finally {
      if (pendingArtifact != null) store.deleteImmutable(pendingArtifact);
      _installing.remove(key);
    }
  }

  static String digestFiles(Map<String, List<int>> files) {
    final names = files.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              for (final n in names) n: sha256.convert(files[n]!).toString(),
            }),
          ),
        )
        .toString();
  }
}
