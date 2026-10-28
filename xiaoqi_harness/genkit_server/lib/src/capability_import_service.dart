import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';
import 'package:genkit/genkit.dart' show CancellationToken;

import 'store.dart';
import 'plugin_dependencies.dart';
import 'isolated_mcp_spec.dart';
import 'plugin_commands.dart';

typedef DependencyPreparer =
    Future<Map<String, List<int>>> Function(
      String tenant,
      Map<String, List<int>> files, {
      CancellationToken? cancellation,
    });

class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final _buffer = BytesBuilder(copy: false);
  Uint8List get bytes => _buffer.toBytes();
  @override
  void add(List<int> data) {
    if (_buffer.length + data.length > limit)
      throw const FormatException('解压内容超过声明大小');
    _buffer.add(data);
  }

  @override
  void close() {}
}

/// Only GitHub is downloaded. Uploaded packages pass the same inspection and
/// installation gates; neither source is executed in the server process.
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
  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxFiles = 3000;
  static const sourceExecutablesPath = '.xiaoqi-source-executables.json';
  static const maxUploadBodyBytes = ((maxArchiveBytes + 2) ~/ 3) * 4 + 65536;
  static const uploadExtensions = ['zip', 'tgz', 'tar.gz', 'skill', 'md'];
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

  void _pruneInspections(String tenant) {
    for (final (key, doc) in store.list('import/$tenant/', limit: 1000)) {
      if (DateTime.parse(
        doc.value['expires_at'].toString(),
      ).isBefore(DateTime.now())) {
        store.deleteImmutable(doc.value['artifact_key'].toString());
        store.delete(key);
      }
    }
  }

  Future<Map<String, dynamic>> inspect(
    String tenant,
    String url, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _pruneInspections(tenant);
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
    cancellation?.throwIfCancelled();
    if (directory.isNotEmpty &&
        !files.keys.any((p) => p.startsWith('$directory/'))) {
      throw const FormatException('仓库内没有这个子目录');
    }
    return _persistInspection(tenant, files, directory, {
      'source_type': 'github',
      'source_url': 'https://github.com/${source.owner}/${source.repo}',
      'requested_url': url,
      'ref': ref,
      'commit': sha,
    }, cancellation: cancellation);
  }

  static ({String fileName, List<int> bytes}) readUpload(
    Map<String, dynamic> body,
  ) {
    if (body['file_name'] is! String || body['archive_base64'] is! String) {
      throw const FormatException('请提供文件名和 Base64 编码的上传内容');
    }
    final name = (body['file_name'] as String).trim();
    if (name.isEmpty ||
        name.length > 180 ||
        RegExp(r'[\x00-\x1f/\\:]').hasMatch(name) ||
        !uploadExtensions.any(
          (extension) => name.toLowerCase().endsWith('.$extension'),
        )) {
      throw const FormatException('请选择 ZIP、TGZ、TAR.GZ、SKILL 或 Markdown 文件');
    }
    final encoded = body['archive_base64'] as String;
    if (encoded.isEmpty ||
        encoded.length > ((maxArchiveBytes + 2) ~/ 3) * 4 ||
        encoded.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
      throw const FormatException('上传内容无效或压缩包超过 20 MiB');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length > maxArchiveBytes) {
      throw const FormatException('压缩包超过 20 MiB');
    }
    return (fileName: name, bytes: bytes);
  }

  Future<Map<String, dynamic>> inspectUpload(
    String tenant,
    String fileName,
    List<int> bytes, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    // Let the accepted job response/cancel request run before bounded decoding.
    await Future<void>.delayed(Duration.zero);
    cancellation?.throwIfCancelled();
    _pruneInspections(tenant);
    final files = decodeUpload(fileName, bytes);
    cancellation?.throwIfCancelled();
    return _persistInspection(tenant, files, '', {
      'source_type': 'upload',
      'file_name': fileName,
      'archive_sha256': sha256.convert(bytes).toString(),
      'content_sha256': digestFiles(files),
    }, cancellation: cancellation);
  }

  Map<String, dynamic> _persistInspection(
    String tenant,
    Map<String, List<int>> files,
    String directory,
    Map<String, dynamic> source, {
    CancellationToken? cancellation,
  }) {
    cancellation?.throwIfCancelled();
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
      ...source,
      'directory': directory,
      'candidates': candidates,
      'artifact_key': object,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .toIso8601String(),
    };
    try {
      cancellation?.throwIfCancelled();
      store.put('import/$tenant/$id', inspection, null);
    } on Object {
      store.deleteImmutable(object);
      rethrow;
    }
    return publicInspection(inspection);
  }

  void discardInspection(String tenant, String id) {
    final key = 'import/$tenant/${safePath(id)}';
    final inspection = store.get(key);
    if (inspection == null) return;
    store.deleteImmutable(inspection.value['artifact_key'].toString());
    store.delete(key, expectedRevision: inspection.revision);
  }

  static Map<String, List<int>> decodeRepository(List<int> bytes) =>
      _decodeZip(bytes, stripRepositoryRoot: true);

  static String _uploadedPath(String name, {bool directory = false}) {
    var path = name;
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (directory && path.endsWith('/'))
      path = path.substring(0, path.length - 1);
    if (directory && (path.isEmpty || path == '.')) return '';
    return safePath(path);
  }

  static Map<String, List<int>> decodeUpload(String fileName, List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxArchiveBytes) {
      throw const FormatException('上传文件为空或超过 20 MiB');
    }
    final lower = fileName.toLowerCase();
    final Map<String, List<int>> files;
    final executableFiles = <String>{};
    try {
      if (lower.endsWith('.md')) {
        if (bytes.length > maxFileBytes)
          throw const FormatException('单个文件超过 10 MiB');
        utf8.decode(
          bytes,
        ); // Reject non-text files before treating them as skills.
        files = {'SKILL.md': Uint8List.fromList(bytes)};
      } else if (lower.endsWith('.zip') || lower.endsWith('.skill')) {
        if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
          throw const FormatException('文件不是有效的 ZIP 压缩包');
        }
        files = _decodeZip(bytes, stripRepositoryRoot: false);
      } else if (lower.endsWith('.tgz') || lower.endsWith('.tar.gz')) {
        final sink = _BoundedBytes(maxExpandedBytes + maxFiles * 2048 + 1024);
        final gzip = io.ZLibDecoder(gzip: true).startChunkedConversion(sink);
        for (var offset = 0; offset < bytes.length; offset += 1024) {
          gzip.add(
            bytes.sublist(offset, (offset + 1024).clamp(0, bytes.length)),
          );
        }
        gzip.close();
        final tar = TarDecoder();
        final seen = <String>{};
        files = {};
        var total = 0;
        tar.decodeBytes(
          sink.bytes,
          verify: true,
          callback: (_) {
            final entry = tar.files.last;
            if (tar.files.length > maxFiles)
              throw const FormatException('压缩包文件过多');
            if (!const ['', '0', '5'].contains(entry.typeFlag) ||
                (entry.nameOfLinkedFile?.isNotEmpty ?? false)) {
              throw const FormatException('不支持链接或特殊文件');
            }
            final directory = entry.typeFlag == '5';
            final path = _uploadedPath(entry.filename, directory: directory);
            if (path.isEmpty) return;
            if (!seen.add(path)) throw const FormatException('压缩包包含重复路径');
            if (directory) {
              if (entry.size != 0) throw const FormatException('目录条目不能包含文件内容');
              return;
            }
            total += entry.size;
            if (entry.size > maxFileBytes || total > maxExpandedBytes) {
              throw const FormatException('解压内容过大');
            }
            final content = entry.contentBytes!;
            if (content.length != entry.size)
              throw const FormatException('TAR 文件内容不完整');
            files[path] = content;
            if ((entry.mode & 0x49) != 0) executableFiles.add(path);
          },
        );
      } else {
        throw const FormatException('不支持这个文件格式');
      }
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('压缩包无效、已损坏或校验失败');
    }
    for (final name in files.keys) {
      final parts = name.split('/');
      for (var i = 1; i < parts.length; i++) {
        if (files.containsKey(parts.take(i).join('/'))) {
          throw const FormatException('文件与目录路径冲突');
        }
      }
    }
    return _preserveSourceExecutables(files, executableFiles);
  }

  static Map<String, List<int>> _decodeZip(
    List<int> bytes, {
    required bool stripRepositoryRoot,
  }) {
    if (bytes.length > maxArchiveBytes)
      throw const FormatException('压缩包超过 20 MB');
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > maxFiles)
      throw const FormatException('仓库文件过多');
    var total = 0;
    final files = <String, List<int>>{};
    final executableFiles = <String>{};
    final seen = <String>{};
    String? prefix;
    for (final header in directory.fileHeaders) {
      final file = header.file!;
      final raw = header.filename.endsWith('/')
          ? header.filename.substring(0, header.filename.length - 1)
          : header.filename;
      final normalized = stripRepositoryRoot
          ? safePath(raw)
          : _uploadedPath(raw, directory: header.filename.endsWith('/'));
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) throw const FormatException('仓库包含重复路径');
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if ((file.flags & 1) != 0 ||
          (type != 0 && type != 0x8000 && type != 0x4000)) {
        throw const FormatException('不支持加密文件、链接或特殊文件');
      }
      if (file.filename != header.filename)
        throw const FormatException('压缩包文件名不一致');
      final parts = normalized.split('/');
      prefix ??= parts.first;
      if (stripRepositoryRoot && parts.first != prefix)
        throw const FormatException('仓库压缩包根目录不一致');
      if (header.filename.endsWith('/')) continue;
      total += header.uncompressedSize;
      if (header.uncompressedSize > maxFileBytes || total > maxExpandedBytes)
        throw const FormatException('解压内容过大');
      final path = stripRepositoryRoot
          ? safePath(parts.skip(1).join('/'))
          : normalized;
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
      final expanded = sink.bytes;
      if (expanded.length != header.uncompressedSize ||
          getCrc32(expanded) != header.crc32)
        throw const FormatException('压缩包内容校验失败');
      files[path] = expanded;
      if (((header.externalFileAttributes >> 16) & 0x49) != 0)
        executableFiles.add(path);
    }
    return _preserveSourceExecutables(files, executableFiles);
  }

  static Map<String, List<int>> _preserveSourceExecutables(
    Map<String, List<int>> input,
    Iterable<String> archived,
  ) {
    final files = Map<String, List<int>>.from(input);
    final executableFiles = archived.toSet();
    for (final path in input.keys.where(
      (path) => path.split('/').last == sourceExecutablesPath,
    )) {
      final manifest = jsonDecode(utf8.decode(input[path]!));
      if (manifest is! Map ||
          manifest['schema'] != 1 ||
          manifest['executables'] is! List ||
          (manifest['executables'] as List).length > input.length) {
        throw const FormatException('源码执行权限记录格式无效');
      }
      final parent = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/'))
          : '';
      for (final raw in manifest['executables'] as List) {
        if (raw is! String) throw const FormatException('源码执行权限路径无效');
        final name = _join(parent, safePath(raw));
        if (!files.containsKey(name) ||
            name.split('/').last == sourceExecutablesPath) {
          throw const FormatException('源码执行权限记录引用了不存在的文件');
        }
        executableFiles.add(name);
      }
      files.remove(path);
      executableFiles.remove(path);
    }
    if (executableFiles.isNotEmpty) {
      final paths = executableFiles.toList()..sort();
      files[sourceExecutablesPath] = utf8.encode(
        jsonEncode({'schema': 1, 'executables': paths}),
      );
      if (files.values.fold<int>(0, (sum, bytes) => sum + bytes.length) >
          maxExpandedBytes) {
        throw const FormatException('源码及执行权限记录超过解压容量限制');
      }
    }
    return files;
  }

  static String _join(String root, String path) =>
      root.isEmpty ? path : '$root/$path';
  static Map<String, List<int>> subtree(
    Map<String, List<int>> files,
    String root,
  ) {
    final result = <String, List<int>>{
      for (final e in files.entries)
        if (root.isEmpty || e.key.startsWith('$root/'))
          (root.isEmpty ? e.key : e.key.substring(root.length + 1)): e.value,
    };
    if (root.isNotEmpty && files[sourceExecutablesPath] != null) {
      final manifest =
          jsonDecode(utf8.decode(files[sourceExecutablesPath]!)) as Map;
      final paths = (manifest['executables'] as List)
          .cast<String>()
          .where((path) => path.startsWith('$root/'))
          .map((path) => path.substring(root.length + 1))
          .toList();
      if (paths.isNotEmpty)
        result[sourceExecutablesPath] = utf8.encode(
          jsonEncode({'schema': 1, 'executables': paths}),
        );
    }
    return result;
  }

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
      try {
        for (final entry in PluginDependencies.declarations(scoped).entries) {
          final config = entry.value;
          final remote =
              config is Map &&
              config['url'] is String &&
              config['command'] == null &&
              Uri.tryParse(config['url'])?.scheme == 'https';
          final stdio =
              config is Map &&
              config['command'] is String &&
              config['url'] == null;
          String? commandError;
          if (stdio) {
            try {
              IsolatedMcpSpec.declaredCommand(config);
              IsolatedMcpSpec.npmDependency(config);
            } on FormatException catch (error) {
              commandError = error.message;
            }
          }
          components.add({
            'id':
                'mcp-${sha256.convert(utf8.encode(entry.key)).toString().substring(0, 16)}',
            'type': 'mcp',
            'root': root,
            'name': entry.key,
            'description': '插件声明的 MCP 连接器',
            'mcp_server_name': entry.key,
            if (remote) 'url': config['url'],
            'status': remote
                ? 'partial'
                : stdio && commandError == null
                ? 'supported'
                : 'unsupported',
            'issues': remote
                ? ['需要绑定当前账号的远程连接']
                : stdio && commandError == null
                ? <String>[]
                : [commandError ?? '连接声明格式无效'],
            'has_dependencies':
                stdio &&
                commandError == null &&
                (IsolatedMcpSpec.npmDependency(config) != null ||
                    scoped.containsKey('package.json') ||
                    scoped.containsKey('requirements.txt') ||
                    scoped.containsKey('pyproject.toml') ||
                    scoped.containsKey('setup.py')),
          });
        }
      } on FormatException {
        unsupported.add('插件 MCP 声明格式或路径无效');
      }
      try {
        components.addAll(PluginCommand.inspect(files, root, manifest));
      } on Object {
        unsupported.add('commands 声明路径或命令目录不可用');
      }
      for (final type in ['hooks', 'agents', 'apps']) {
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
          keywords: manifest['keywords'],
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
          (skill['warnings'] as List).cast<String>(),
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
    List<String> warnings, {
    Object? keywords,
  }) {
    final usable = components.where((c) => c['status'] != 'unsupported').length;
    final hasPartialComponent = components.any(
      (component) => component['status'] == 'partial',
    );
    return {
      'id': sha256
          .convert(utf8.encode('$kind:$root'))
          .toString()
          .substring(0, 20),
      'root': root,
      'kind': kind,
      'name': name,
      'description': description,
      if (keywords is List)
        'keywords': keywords
            .whereType<String>()
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList(),
      'status': usable == 0
          ? 'unsupported'
          : usable < components.length ||
                hasPartialComponent ||
                warnings.isNotEmpty
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
    final warnings = <String>[];
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
      final allowed = header['allowed-tools']?.toString() ?? '';
      if (allowed.isNotEmpty &&
          RegExp(r'Computer|Browser', caseSensitive: false).hasMatch(allowed))
        warnings.add('声明了需要核对实际宿主的工具：$allowed；执行前须确认可用能力');
      for (final path in files.keys) {
        safePath(path);
        if (path.startsWith('.xiaoqi/')) issues.add('包含保留的运行环境目录');
      }
      validateDependencies(files);
      if (files.containsKey('pyproject.toml') &&
          utf8
              .decode(files['pyproject.toml']!)
              .contains('[project.optional-dependencies]')) {
        warnings.add('发现 Python 可选依赖组，默认只安装基础依赖；需要可选组的脚本仍须核对其依赖。');
      }
    } catch (e) {
      issues.add(e is FormatException ? e.message : '技能文件格式无效');
    }
    return {
      'id': sha256.convert(utf8.encode(root)).toString().substring(0, 16),
      'root': root,
      'name': name,
      'description': description,
      'status': issues.isNotEmpty
          ? 'unsupported'
          : warnings.isEmpty
          ? 'supported'
          : 'partial',
      'issues': issues,
      'warnings': warnings,
      'has_scripts': files.keys.any(
        (p) => RegExp(
          r'^scripts/.+\.(?:py|js|mjs|cjs|ts|mts|sh|bash)$',
        ).hasMatch(p),
      ),
      'has_dependencies':
          files.containsKey('requirements.txt') ||
          files.containsKey('package.json') ||
          files.containsKey('pyproject.toml') ||
          files.containsKey('setup.py'),
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
      final scripts = value['scripts'];
      if (scripts != null &&
          (scripts is! Map ||
              scripts.values.any((script) => script is! String))) {
        throw const FormatException('npm 脚本声明必须为文本映射');
      }
      for (final field in [
        'dependencies',
        'optionalDependencies',
        'devDependencies',
        'peerDependencies',
      ]) {
        final deps = value[field];
        if (deps == null) continue;
        if (deps is! Map) throw const FormatException('npm 依赖格式无效');
        for (final entry in deps.entries) {
          if (!RegExp(
                r'^(?:@[a-z0-9_.-]+/)?[a-z0-9_.-]+$',
              ).hasMatch(entry.key.toString()) ||
              !RegExp(
                r'^[A-Za-z0-9v^~<>=*| .xX+-]+$',
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

  Map<String, dynamic> skillDraft(
    String tenant,
    String inspectionId,
    String candidateId,
  ) {
    final inspection = getInspection(tenant, inspectionId);
    final candidate = (inspection['candidates'] as List)
        .whereType<Map>()
        .where((value) => value['id'] == candidateId)
        .firstOrNull;
    if (candidate == null ||
        candidate['status'] == 'unsupported' ||
        candidate['kind'] == 'skill' && candidate['status'] != 'supported') {
      throw const FormatException('请选择检查通过的技能或插件');
    }
    final files = subtree(
      store.getImmutable(inspection['artifact_key'].toString()),
      candidate['root'].toString(),
    );
    final plugin = candidate['kind'] == 'plugin';
    final mainPath = plugin
        ? const [
            'plugin.json',
            '.claude-plugin/plugin.json',
            '.codex-plugin/plugin.json',
          ].firstWhere(files.containsKey, orElse: () => 'plugin.json')
        : 'SKILL.md';
    final main = files[mainPath];
    if (main == null ||
        files.length > 128 ||
        files.values.fold<int>(0, (total, bytes) => total + bytes.length) >
            2 * 1024 * 1024) {
      throw const FormatException('草稿必须包含主文件，最多 128 个文件、总量 2 MB');
    }
    return {
      'id':
          'draft-${sha256.convert(utf8.encode('$tenant/$inspectionId/$candidateId')).toString().substring(0, 32)}',
      'kind': candidate['kind'],
      'name': candidate['name'],
      'description': candidate['description'],
      'content': utf8.decode(main),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'files': {
        for (final entry in files.entries)
          if (plugin || entry.key != 'SKILL.md')
            entry.key: base64Encode(entry.value),
      },
    };
  }

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
    final uploaded = inspection['source_type'] == 'upload';
    final origin = uploaded ? 'upload' : 'github';
    final sourceIdentity = uploaded
        ? inspection['content_sha256']
        : inspection['source_url'];
    final inferredId =
        '${uploaded ? 'upload' : 'import'}-${sha256.convert(utf8.encode('$sourceIdentity/${candidate['root']}')).toString().substring(0, 32)}';
    if (uploaded &&
        updateId != null &&
        !RegExp(r'^upload-[a-f0-9]{32}$').hasMatch(updateId)) {
      throw const FormatException('只能用本地包更新原本由本地包安装的扩展');
    }
    final id = uploaded && updateId != null ? updateId : inferredId;
    if (!uploaded && updateId != null && updateId != id)
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
      if (uploaded &&
          updateId != null &&
          (current!.value['origin'] != 'upload' ||
              current.value['kind'] != candidate['kind'] ||
              current.value['name'] != candidate['name'])) {
        throw const FormatException('上传包的名称或类型与原安装扩展不一致');
      }
      final versionId =
          '${inspection[uploaded ? 'content_sha256' : 'commit']}-${candidate['id']}';
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
          'origin': origin,
          'source': {
            for (final k in [
              'source_url',
              'requested_url',
              'commit',
              'ref',
              'source_type',
              'file_name',
              'archive_sha256',
              'content_sha256',
            ])
              if (inspection.containsKey(k)) k: inspection[k],
            'root': candidate['root'],
          },
        }, current.revision);
      }
      final all = store.getImmutable(inspection['artifact_key'].toString());
      final package = subtree(all, candidate['root'].toString());
      final components = <Map<String, dynamic>>[];
      for (final raw in (candidate['components'] as List).whereType<Map>()) {
        if (raw['status'] == 'unsupported') continue;
        final relative = candidate['root'] == raw['root']
            ? ''
            : raw['root'].toString().substring(
                candidate['root'].toString().isEmpty
                    ? 0
                    : candidate['root'].toString().length + 1,
              );
        var files = subtree(package, relative);
        if (raw['type'] == 'mcp') {
          final config = PluginDependencies.declarations(
            files,
          )[raw['mcp_server_name']];
          if (config is Map &&
              config['command'] is String &&
              config['url'] == null) {
            files = IsolatedMcpSpec.installationFiles(config, files);
          }
        }
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
        for (final e in files.entries) {
          package[_join(relative, e.key)] = e.value;
        }
        components.add({...raw, 'root': relative});
      }
      final normalizedPackage = _preserveSourceExecutables(package, const []);
      package
        ..clear()
        ..addAll(normalizedPackage);
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
          if (candidate['kind'] == 'plugin')
            'plugin_command_profile': PluginCommand.profileVersion,
        });
      final saved = store.put(key, {
        'schema_version': 2,
        'id': id,
        'kind': candidate['kind'],
        'name': candidate['name'],
        'description': candidate['description'],
        if (candidate['kind'] == 'plugin')
          'keywords': current?.value['keywords_edited'] == true
              ? current!.value['keywords']
              : candidate['keywords'] ??
                    current?.value['keywords'] ??
                    <String>[],
        if (current?.value['keywords_edited'] == true) 'keywords_edited': true,
        'versions': versions,
        'current_version_id': versionId,
        'created_at': current?.value['created_at'] ?? now,
        'updated_at': now,
        'show_in_menu': current?.value['show_in_menu'] ?? true,
        'enabled': current?.value['enabled'] ?? true,
        'deleted_at': null,
        'origin': origin,
        'source': {
          for (final k in [
            'source_url',
            'requested_url',
            'commit',
            'ref',
            'source_type',
            'file_name',
            'archive_sha256',
            'content_sha256',
          ])
            if (inspection.containsKey(k)) k: inspection[k],
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
