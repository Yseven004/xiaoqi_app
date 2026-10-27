import 'dart:convert';

import 'skill_market.dart' show normalizeSkillPresentation;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'store.dart';
import 'capability_keywords.dart';
import 'tool_access_policy.dart';
import 'isolated_mcp_spec.dart';
import 'trusted_mcp_read_profiles.dart';

Future<List<Map<String, dynamic>>> listAllMcpTools(
  Future<Map<String, dynamic>> Function(String? cursor) readPage,
) async {
  final tools = <Map<String, dynamic>>[];
  final seen = <String>{};
  var catalogBytes = 0;
  String? cursor;
  for (var pageNumber = 0; pageNumber < 100; pageNumber++) {
    final page = await readPage(cursor).timeout(const Duration(seconds: 20));
    final pageTools = (page['tools'] as List? ?? const [])
        .whereType<Map>()
        .map((tool) => Map<String, dynamic>.from(tool))
        .toList();
    catalogBytes += utf8.encode(jsonEncode(pageTools)).length;
    if (catalogBytes > 16 * 1024 * 1024) {
      throw StateError('MCP 工具目录超过服务端 16 MB 资源预算');
    }
    tools.addAll(pageTools);
    cursor = page['nextCursor']?.toString();
    if (cursor == null || cursor.isEmpty) return tools;
    if (!seen.add(cursor)) throw StateError('MCP 工具目录返回重复分页标记');
  }
  throw StateError('MCP 工具目录分页超过限制');
}

class McpTaskSelection {
  final connections = <McpConnectionCredentials>[];
  final unavailable = <Map<String, String>>[];
}

class McpConnectionCredentials {
  const McpConnectionCredentials({
    required this.id,
    required this.name,
    required this.url,
    required this.bearerToken,
    this.catalogId,
    this.isolated,
    this.authorizationRevision,
  });

  final String id;
  final String name;
  final Uri url;
  final String? bearerToken;
  final String? catalogId;
  final IsolatedMcpSpec? isolated;
  final String? authorizationRevision;

  McpServerConfig serverConfig() => McpServerConfig(
    url: url,
    headers: bearerToken == null
        ? null
        : {'Authorization': 'Bearer $bearerToken'},
    timeout: const Duration(seconds: 15),
  );
}

class McpCatalogEntry {
  const McpCatalogEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
    required this.version,
    required this.runtime,
    required this.authMode,
    required this.status,
    this.repository,
    this.authorizeUrl,
    this.tokenUrl,
    this.clientId,
    this.clientSecret,
    this.scopes = const [],
    this.package,
    this.packageVersion,
    this.reason,
    this.keywords = const [],
    this.toolEffects = const {},
  });

  final String id;
  final String name;
  final String description;
  final Uri? url;
  final String version;
  final String runtime;
  final String authMode;
  final String status;
  final String? repository;
  final Uri? authorizeUrl;
  final Uri? tokenUrl;
  final String? clientId;
  final String? clientSecret;
  final List<String> scopes;
  final String? package;
  final String? packageVersion;
  final String? reason;
  final List<String> keywords;
  final Map<String, ToolEffect> toolEffects;

  bool get requiresLogin => authMode == 'oauth';

  static McpCatalogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    final description = raw['description']?.toString().trim() ?? '';
    final runtime = raw['runtime']?.toString() ?? 'remote_https';
    final rawUrl = raw['url']?.toString().trim() ?? '';
    final package = raw['package']?.toString().trim();
    if (id.isEmpty || name.isEmpty || description.isEmpty) {
      return null;
    }
    try {
      final remoteUrl = runtime == 'remote_https'
          ? McpConnectionService.parseRemoteUrl(rawUrl)
          : null;
      if (runtime == 'remote_https' && remoteUrl == null) return null;
      if ((runtime == 'sandbox_npm' || runtime == 'sandbox_pypi') &&
          (package == null || package.isEmpty)) {
        return null;
      }
      return McpCatalogEntry(
        id: id,
        name: name,
        description: description,
        url: remoteUrl,
        version: raw['version']?.toString() ?? '1.0.0',
        runtime: runtime,
        authMode: raw['auth_mode']?.toString() ?? 'none',
        status: raw['status']?.toString() ?? 'verified',
        repository: raw['repository']?.toString(),
        authorizeUrl: Uri.tryParse(raw['authorize_url']?.toString() ?? ''),
        tokenUrl: Uri.tryParse(raw['token_url']?.toString() ?? ''),
        clientId: raw['client_id']?.toString(),
        clientSecret: raw['client_secret']?.toString(),
        scopes: (raw['scopes'] as List? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        package: package,
        packageVersion: raw['package_version']?.toString(),
        reason: raw['reason']?.toString(),
        keywords: parseCapabilityKeywords(raw['keywords'] ?? const []),
        toolEffects: {
          for (final entry
              in (raw['tool_effects'] is Map
                      ? raw['tool_effects'] as Map
                      : const {})
                  .entries)
            entry.key.toString(): ToolEffect.parse(entry.value),
        },
      );
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toPublic() => {
    'id': id,
    'name': name,
    'description': description,
    'keywords': keywords,
    'version': version,
    'runtime': runtime,
    if (package != null) 'package': package,
    if (packageVersion != null) 'package_version': packageVersion,
    'auth_mode': authMode,
    'status': status,
    if (repository != null) 'repository': repository,
    if (reason != null) 'reason': reason,
  };
}

/// Tenant-scoped remote MCP connection storage and transport setup.
/// Credentials are encrypted at rest using the server's existing secret.
class McpConnectionService {
  McpConnectionService(this.store, {String? pepper, this.discoverTools})
    : _pepper =
          pepper ?? Platform.environment['CAPABILITY_AUTH_CODE_PEPPER'] ?? '';

  final CloudStore store;
  final String _pepper;
  final Future<List<Map<String, dynamic>>> Function(McpConnectionCredentials)?
  discoverTools;
  static const _uuid = Uuid();
  static final _cipher = AesGcm.with256bits();

  McpCatalogEntry? _policyEntry(McpConnectionCredentials connection) =>
      catalog()
          .where(
            (entry) =>
                entry.id == connection.catalogId &&
                entry.status == 'verified' &&
                entry.url == connection.url,
          )
          .firstOrNull;

  bool _hasPublicReadProfile(McpConnectionCredentials connection) =>
      connection.catalogId == null &&
      connection.bearerToken == null &&
      TrustedMcpReadProfiles.matchesEndpoint(connection.url);

  ToolEffect effectFor(
    McpConnectionCredentials connection,
    String tool, {
    Object? inputSchema,
    Map<String, dynamic>? arguments,
  }) {
    final entry = _policyEntry(connection);
    if (entry == null &&
        _hasPublicReadProfile(connection) &&
        TrustedMcpReadProfiles.permits(tool, inputSchema, arguments))
      return ToolEffect.read;
    final effect = entry?.toolEffects[tool] ?? ToolEffect.unknown;
    // A remote server cannot claim our isolated task workspace as its own.
    return effect == ToolEffect.workspace ? ToolEffect.unknown : effect;
  }

  Map<String, dynamic> authorizationBinding(
    McpConnectionCredentials connection,
  ) => {
    'url': connection.url.toString(),
    'revision': connection.authorizationRevision,
    'catalog_id': _policyEntry(connection)?.id,
    'policy_version': _policyEntry(connection)?.version,
    if (_hasPublicReadProfile(connection)) ...{
      'read_profile_id': TrustedMcpReadProfiles.id,
      'read_profile_version': TrustedMcpReadProfiles.version,
    },
    if (connection.isolated != null)
      'capability_version': connection.isolated!.versionId,
  };

  bool isCurrent(String tenantId, McpConnectionCredentials connection) {
    final isolated = connection.isolated;
    if (isolated != null) {
      if (isolated.capabilityId == null || isolated.versionId == null)
        return false;
      final record = store.get('cap/$tenantId/${isolated.capabilityId}')?.value;
      return record != null &&
          record['enabled'] != false &&
          record['deleted_at'] == null &&
          (record['versions'] as List? ?? const []).whereType<Map>().any(
            (version) => version['id'] == isolated.versionId,
          );
    }
    final document = store.get(_key(tenantId, connection.id));
    if (document == null) return false;
    final value = document.value;
    return value['enabled'] != false &&
        value['deleted_at'] == null &&
        (value['status'] == null || value['status'] == 'ready') &&
        value['url'] == connection.url.toString() &&
        value['catalog_id'] == connection.catalogId &&
        connection.authorizationRevision != null &&
        connection.authorizationRevision == _authorizationRevision(value);
  }

  String _authorizationRevision(Map<String, dynamic> value) {
    final encrypted = value['encrypted_bearer_token'] as Map?;
    // Health checks and presentation changes are not authorization changes.
    // Only values that select the endpoint/account enter this fingerprint.
    return crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'url': value['url'],
              'catalog_id': value['catalog_id'],
              'credential': encrypted == null
                  ? null
                  : {
                      for (final key in const [
                        'version',
                        'nonce',
                        'ciphertext',
                        'mac',
                      ])
                        key: encrypted[key],
                    },
            }),
          ),
        )
        .toString();
  }

  List<McpCatalogEntry> catalog() {
    final raw = Platform.environment['XIAOQI_MCP_CATALOG_JSON'] ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(McpCatalogEntry.fromJson)
          .whereType<McpCatalogEntry>()
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  List<Map<String, Object?>> list(String tenantId) => store
      .list('mcp/$tenantId/', limit: 100)
      .map((entry) => _public(entry.$2.value))
      .toList(growable: false);

  Future<Map<String, Object?>> install(
    String tenantId,
    String catalogId,
  ) async {
    final entry = catalog().where((item) => item.id == catalogId).firstOrNull;
    if (entry == null) throw const FormatException('该 MCP 工具暂未支持');
    if (entry.status != 'verified') {
      throw const FormatException('该 MCP 工具尚未通过可用性验证');
    }
    if (entry.runtime != 'remote_https') {
      throw const FormatException('该 MCP 工具需要沙箱运行，当前版本暂未开放');
    }
    final remoteUrl = entry.url;
    if (remoteUrl == null) {
      throw const FormatException('该 MCP 工具缺少远程服务地址');
    }
    final existing = store
        .list('mcp/$tenantId/', limit: 100)
        .map((item) => item.$2.value)
        .where((item) => item['catalog_id'] == entry.id)
        .firstOrNull;
    if (existing != null) return _public(existing);
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final value = <String, dynamic>{
      'id': id,
      'catalog_id': entry.id,
      'name': entry.name,
      'keywords': entry.keywords,
      'url': remoteUrl.toString(),
      'version': entry.version,
      'runtime': entry.runtime,
      'auth_mode': entry.authMode,
      'status': entry.requiresLogin ? 'needs_login' : 'connecting',
      'created_at': now,
      'updated_at': now,
    };
    store.put(_key(tenantId, id), value, null);
    if (!entry.requiresLogin) {
      try {
        final result = await _discoverTools(
          McpConnectionCredentials(
            id: id,
            name: entry.name,
            url: remoteUrl,
            bearerToken: null,
            catalogId: entry.id,
          ),
        );
        value['status'] = 'ready';
        value['tool_count'] = result.length;
      } on Object catch (error) {
        value['status'] = 'failed';
        value['error'] = _safeError(error);
      }
      store.put(
        _key(tenantId, id),
        value,
        store.get(_key(tenantId, id))?.revision,
      );
    }
    return _public(value);
  }

  Future<Map<String, Object?>> startLogin(String tenantId, String id) async {
    final connection = await _read(tenantId, _safeId(id));
    final entry = catalog()
        .where((item) => item.id == connection.catalogId)
        .firstOrNull;
    if (entry == null ||
        !entry.requiresLogin ||
        entry.authorizeUrl == null ||
        entry.clientId == null) {
      throw StateError('该工具暂未提供网页登录');
    }
    final authorizeUrl = entry.authorizeUrl!;
    final clientId = entry.clientId!;
    final state = _uuid.v4();
    final verifier = base64Url
        .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final challenge = base64Url
        .encode(crypto.sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    store.put('mcp-oauth/$tenantId/$state', {
      'connection_id': connection.id,
      'catalog_id': entry.id,
      'verifier': verifier,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, null);
    final redirectUri = _oauthRedirectUri();
    final query = <String, String>{
      ...authorizeUrl.queryParameters,
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      if (entry.scopes.isNotEmpty) 'scope': entry.scopes.join(' '),
    };
    return {
      'auth_url': authorizeUrl.replace(queryParameters: query).toString(),
    };
  }

  Future<Map<String, Object?>> reconnect(String tenantId, String id) async {
    final connection = await _read(tenantId, _safeId(id));
    try {
      final tools = await _discoverTools(connection);
      return await _setStatus(
        tenantId,
        connection.id,
        'ready',
        toolCount: tools.length,
      );
    } on Object catch (error) {
      return await _setStatus(
        tenantId,
        connection.id,
        'failed',
        error: _safeError(error),
      );
    }
  }

  Future<Map<String, Object?>> save(
    String tenantId,
    Map<String, dynamic> input,
  ) async {
    final name = input['name']?.toString().trim() ?? '';
    if (name.isEmpty || name.length > 80) {
      throw const FormatException('连接名称需为 1–80 个字符');
    }
    final url = parseRemoteUrl(input['url']?.toString() ?? '');
    final id = input['id']?.toString().trim().isNotEmpty == true
        ? _safeId(input['id'])
        : _uuid.v4();
    final key = _key(tenantId, id);
    final previous = store.get(key);
    final keywords = input.containsKey('keywords')
        ? parseCapabilityKeywords(input['keywords'])
        : previous?.value['keywords'] ?? const <String>[];
    if (previous?.value['catalog_id'] != null && input.containsKey('icon')) {
      throw const FormatException('市场连接的图标由发布者维护');
    }
    final rawIcon =
        input['icon'] ?? previous?.value['icon'] ?? const {'icon_asset': 'mcp'};
    if (rawIcon is! Map) throw const FormatException('连接图标格式无效');
    final checkedIcon = normalizeSkillPresentation({
      'icon_asset': rawIcon['icon_asset'] ?? 'mcp',
      'icon_data': rawIcon['icon_data'] ?? '',
    });
    final suppliedToken = _validatedToken(input['bearer_token']);
    final encrypted = suppliedToken == null || suppliedToken.isEmpty
        ? previous?.value['encrypted_bearer_token']
        : await _encrypt(suppliedToken);
    final now = DateTime.now().toUtc().toIso8601String();
    final value = <String, dynamic>{
      ...?previous?.value,
      'id': id,
      'name': name,
      'keywords': keywords,
      'icon': {
        'icon_asset': checkedIcon['icon_asset'],
        'icon_data': checkedIcon['icon_data'],
      },
      'url': url.toString(),
      if (encrypted != null) 'encrypted_bearer_token': encrypted,
      'created_at': previous?.value['created_at'] ?? now,
      'updated_at': now,
    };
    store.put(key, value, previous?.revision);
    return _public(value);
  }

  bool delete(String tenantId, String id) {
    final key = _key(tenantId, _safeId(id));
    final previous = store.get(key);
    if (previous == null) return false;
    for (final pending in store.list('mcp-oauth/$tenantId/', limit: 1000)) {
      if (pending.$2.value['connection_id']?.toString() == id) {
        store.delete(pending.$1, expectedRevision: pending.$2.revision);
      }
    }
    return store.delete(key, expectedRevision: previous.revision);
  }

  Future<Map<String, Object?>> test(String tenantId, String id) async {
    final connection = await _read(tenantId, _safeId(id));
    final tools = await _discoverTools(connection);
    await _setStatus(tenantId, connection.id, 'ready', toolCount: tools.length);
    return {
      'connection_id': connection.id,
      'name': connection.name,
      'tool_count': tools.length,
      'tools': tools
          .map(
            (tool) => {
              'name': tool['name']?.toString() ?? '',
              'description': tool['description']?.toString() ?? '',
            },
          )
          .toList(growable: false),
    };
  }

  static String? _validatedToken(Object? raw) {
    if (raw == null) return null;
    if (raw is! String ||
        raw.length > 4096 ||
        RegExp(r'[\r\n]').hasMatch(raw)) {
      throw const FormatException('访问令牌格式无效');
    }
    return raw.trim().isEmpty ? null : raw.trim();
  }

  Future<Map<String, Object?>> testDraft(
    String tenantId,
    Map<String, dynamic> input,
  ) async {
    final name = input['name']?.toString().trim() ?? '';
    if (name.isEmpty || name.length > 80) {
      throw const FormatException('连接名称需为 1–80 个字符');
    }
    final url = parseRemoteUrl(input['url']?.toString() ?? '');
    var token = _validatedToken(input['bearer_token']);
    if (input['id'] != null) {
      final previous = await _read(tenantId, _safeId(input['id']));
      if (token == null && previous.bearerToken != null) {
        if (url.origin != previous.url.origin) {
          throw const FormatException('服务器域名已改变，请重新填写访问令牌后测试');
        }
        token = previous.bearerToken;
      }
    }
    try {
      final tools = await _discoverTools(
        McpConnectionCredentials(
          id: 'preview-${_uuid.v4()}',
          name: name,
          url: url,
          bearerToken: token,
        ),
      );
      return {
        'name': name,
        'saved': false,
        'tool_count': tools.length,
        'tools': tools
            .map(
              (tool) => {
                'name': tool['name']?.toString() ?? '',
                'description': tool['description']?.toString() ?? '',
              },
            )
            .toList(growable: false),
      };
    } on FormatException {
      rethrow;
    } on Object {
      // Transport errors can contain credentials; never echo them to clients.
      throw StateError('MCP 连接测试失败，请检查地址、访问令牌和服务状态');
    }
  }

  Future<String> oauthCallback(Map<String, String> query) async {
    final state = query['state']?.trim() ?? '';
    final code = query['code']?.trim() ?? '';
    final oauthError = query['error']?.trim();
    if (state.isEmpty) return _oauthPage('登录失败', '缺少授权状态，请重新开始登录。');
    final pending = store
        .list('mcp-oauth/', limit: 1000)
        .where((item) => item.$1.endsWith('/$state'))
        .firstOrNull;
    if (pending == null) return _oauthPage('登录已过期', '请回到小栖重新点击“登录”。');
    final parts = pending.$1.split('/');
    final tenantId = parts.length >= 3 ? parts[1] : '';
    final pendingValue = pending.$2.value;
    store.delete(pending.$1, expectedRevision: pending.$2.revision);
    final connectionId = pendingValue['connection_id']?.toString() ?? '';
    if (tenantId.isEmpty || connectionId.isEmpty || code.isEmpty) {
      return _oauthPage(
        '登录未完成',
        oauthError == null || oauthError.isEmpty
            ? '授权被取消，请回到小栖重试。'
            : '授权未完成，请回到小栖重试。',
      );
    }
    final entry = catalog()
        .where((item) => item.id == pendingValue['catalog_id'])
        .firstOrNull;
    if (entry?.tokenUrl == null || entry?.clientId == null) {
      return _oauthPage('登录暂不可用', '该工具的登录配置不完整，请稍后重试。');
    }
    late final http.Response tokenResponse;
    try {
      tokenResponse = await http
          .post(
            entry!.tokenUrl!,
            headers: const {'Accept': 'application/json'},
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'client_id': entry.clientId!,
              if (entry.clientSecret != null)
                'client_secret': entry.clientSecret!,
              'redirect_uri': _oauthRedirectUri().toString(),
              'code_verifier': pendingValue['verifier']?.toString() ?? '',
            },
          )
          .timeout(const Duration(seconds: 20));
    } on Object {
      return _oauthPage('登录失败', '服务商暂时无法响应，请回到小栖重试。');
    }
    if (tokenResponse.statusCode < 200 || tokenResponse.statusCode >= 300) {
      return _oauthPage('登录失败', '服务商没有接受这次授权，请重新登录。');
    }
    Object? tokenBody;
    try {
      tokenBody = jsonDecode(tokenResponse.body);
    } on FormatException {
      return _oauthPage('登录失败', '服务商返回的数据无法识别，请回到小栖重试。');
    }
    final accessToken = tokenBody is Map
        ? tokenBody['access_token']?.toString()
        : null;
    if (accessToken == null || accessToken.isEmpty) {
      return _oauthPage('登录失败', '服务商没有返回有效授权，请重新登录。');
    }
    final key = _key(tenantId, connectionId);
    final document = store.get(key);
    if (document == null) return _oauthPage('连接器不存在', '请回到小栖重新安装。');
    final value = Map<String, dynamic>.from(document.value)
      ..['encrypted_bearer_token'] = await _encrypt(accessToken)
      ..['status'] = 'connecting'
      ..['error'] = null
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String();
    store.put(key, value, document.revision);
    try {
      final tools = await _discoverTools(await _read(tenantId, connectionId));
      await _setStatus(
        tenantId,
        connectionId,
        'ready',
        toolCount: tools.length,
      );
      return _oauthPage('登录成功', '已回到小栖，你可以关闭此页面。');
    } on Object catch (error) {
      await _setStatus(
        tenantId,
        connectionId,
        'failed',
        error: _safeError(error),
      );
      return _oauthPage('连接失败', '登录成功，但工具暂时无法连接。请回到小栖重试。');
    }
  }

  Future<List<Map<String, dynamic>>> _discoverTools(
    McpConnectionCredentials connection,
  ) async {
    if (discoverTools != null) return discoverTools!(connection);
    final client = await connect(connection);
    try {
      await client.ready().timeout(const Duration(seconds: 20));
      return await listAllMcpTools(
        (cursor) => client.listTools(cursor: cursor),
      );
    } finally {
      await client.close();
    }
  }

  Future<Map<String, Object?>> _setStatus(
    String tenantId,
    String id,
    String status, {
    int? toolCount,
    String? error,
  }) async {
    final key = _key(tenantId, id);
    final previous = store.get(key);
    if (previous == null) throw StateError('MCP 连接器不存在，请刷新后重新选择');
    final value = Map<String, dynamic>.from(previous.value)
      ..['status'] = status
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String();
    if (toolCount != null) value['tool_count'] = toolCount;
    if (error != null) {
      value['error'] = error;
    } else {
      value.remove('error');
    }
    store.put(key, value, previous.revision);
    return _public(value);
  }

  static String _safeError(Object error) => error
      .toString()
      .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer [已隐藏]')
      .replaceAll(
        RegExp(r'\b(?:sk|ghp|github_pat)_[A-Za-z0-9_]+\b'),
        '[凭据已隐藏]',
      );

  static Uri _oauthRedirectUri() {
    final host = Platform.environment['XIAOQI_PUBLIC_HOST']?.trim() ?? '';
    if (host.isEmpty) throw StateError('服务端没有配置 OAuth 回调地址');
    final base = Uri.parse(host);
    return base.replace(
      path: '/v1/mcp/oauth/callback',
      queryParameters: const {},
      fragment: null,
    );
  }

  static String _oauthPage(String title, String message) =>
      '<!doctype html><meta charset="utf-8"><title>$title</title>'
      '<style>body{font-family:system-ui;padding:32px;color:#20242b}main{max-width:520px;margin:auto}a{display:inline-block;margin-top:16px}</style>'
      '<main><h1>$title</h1><p>$message</p>'
      '<a href="xiaoqi://mcp/oauth?status=complete">返回小栖</a></main>';

  Future<GenkitMcpClient> connect(McpConnectionCredentials connection) async {
    await _checkPublicEndpoint(connection.url);
    final client = createMcpClient(
      McpClientOptions(
        name: 'xiaoqi-${connection.id}',
        serverName: connection.name,
        mcpServer: connection.serverConfig(),
      ),
    );
    try {
      await client.ready().timeout(const Duration(seconds: 20));
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  Future<List<McpConnectionCredentials>> selected(
    String tenantId,
    Object? rawIds,
  ) async {
    if (rawIds == null) return const [];
    if (rawIds is! List) {
      throw const FormatException('一次最多选择 8 个 MCP 连接器');
    }
    final ids = rawIds
        .map((raw) => _safeId(raw is Map ? raw['id'] : raw))
        .toSet();
    if (ids.length > 8) throw const FormatException('一次最多选择 8 个 MCP 连接器');
    final result = <McpConnectionCredentials>[];
    for (final id in ids) {
      result.add(await _read(tenantId, id));
    }
    return result;
  }

  /// A broken component must not prevent the other selected components loading.
  /// Invalid request structure remains an error; per-connection failures contain
  /// only safe recovery information, never decrypted credentials or exceptions.
  Future<McpTaskSelection> selectedForTask(
    String tenantId,
    Object? rawIds,
  ) async {
    if (rawIds != null && rawIds is! List) {
      throw const FormatException('一次最多选择 8 个 MCP 连接器');
    }
    final ids = (rawIds as List? ?? const [])
        .map((raw) => _safeId(raw is Map ? raw['id'] : raw))
        .toSet();
    if (ids.length > 8) throw const FormatException('一次最多选择 8 个 MCP 连接器');
    final result = McpTaskSelection();
    for (final id in ids) {
      final value = store.get(_key(tenantId, id))?.value;
      String? reason;
      if (value == null || value['deleted_at'] != null) {
        reason = '连接器不存在，请刷新后重新选择';
      } else if (value['enabled'] == false) {
        reason = '连接器已停用，请在 MCP 连接器中启用';
      } else if (value['status'] != null && value['status'] != 'ready') {
        reason = '连接器尚未就绪，请在 MCP 连接器中检查连接状态';
      } else {
        try {
          result.connections.add(await _read(tenantId, id));
          continue;
        } on Object {
          reason = '连接配置或凭据不可用，请在 MCP 连接器中重新保存并检查连接';
        }
      }
      result.unavailable.add({
        'id': id,
        'name': value?['name']?.toString() ?? 'MCP 连接器',
        'message': reason,
      });
    }
    return result;
  }

  Future<List<McpConnectionCredentials>> discoverable(
    String tenantId, {
    Iterable<String> excludedIds = const [],
  }) async {
    final result = <McpConnectionCredentials>[];
    for (final (_, document) in store.list('mcp/$tenantId/', limit: 500)) {
      final value = document.value;
      final id = value['id']?.toString() ?? '';
      if (value['enabled'] == false ||
          excludedIds.contains(id) ||
          (value['status'] != null && value['status'] != 'ready'))
        continue;
      try {
        result.add(await _read(tenantId, _safeId(id)));
      } on Object {
        continue;
      }
      if (result.length == 8) break;
    }
    return result;
  }

  Future<McpConnectionCredentials> _read(String tenantId, String id) async {
    final document = store.get(_key(tenantId, id));
    if (document == null) throw StateError('MCP 连接器不存在，请刷新后重新选择');
    if (document.value['enabled'] == false ||
        document.value['deleted_at'] != null ||
        (document.value['status'] != null &&
            document.value['status'] != 'ready')) {
      throw StateError('MCP 连接器已停用或尚未就绪，请刷新连接状态');
    }
    final encrypted = document.value['encrypted_bearer_token'];
    final token = encrypted is Map ? await _decrypt(encrypted) : null;
    return McpConnectionCredentials(
      id: id,
      name: document.value['name']?.toString() ?? 'MCP 连接器',
      url: parseRemoteUrl(document.value['url']?.toString() ?? ''),
      bearerToken: token,
      catalogId: document.value['catalog_id']?.toString(),
      authorizationRevision: _authorizationRevision(document.value),
    );
  }

  Future<Map<String, Object?>> _encrypt(String value) async {
    if (_pepper.length < 32) {
      throw StateError('服务器凭据加密密钥未配置，请联系管理员修复服务端配置');
    }
    final nonce = await _cipher.newNonce();
    final box = await _cipher.encrypt(
      utf8.encode(value),
      secretKey: SecretKey(_encryptionKey()),
      nonce: nonce,
    );
    return {
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<String> _decrypt(Map encrypted) async {
    if (_pepper.length < 32 || encrypted['version'] != 1) {
      throw StateError('MCP 凭据无法解密，请重新保存该连接器');
    }
    try {
      final bytes = await _cipher.decrypt(
        SecretBox(
          base64Decode(encrypted['ciphertext'].toString()),
          nonce: base64Decode(encrypted['nonce'].toString()),
          mac: Mac(base64Decode(encrypted['mac'].toString())),
        ),
        secretKey: SecretKey(_encryptionKey()),
      );
      return utf8.decode(bytes);
    } on Object {
      throw StateError('MCP 凭据校验失败，请重新保存该连接器');
    }
  }

  List<int> _encryptionKey() => crypto.Hmac(
    crypto.sha256,
    utf8.encode(_pepper),
  ).convert(utf8.encode('xiaoqi:mcp-credentials:v1')).bytes;

  static Uri parseRemoteUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery ||
        (uri.hasPort && uri.port != 443) ||
        InternetAddress.tryParse(uri.host) != null ||
        uri.host.toLowerCase() == 'localhost' ||
        uri.host.toLowerCase().endsWith('.localhost') ||
        uri.host.toLowerCase().endsWith('.local') ||
        uri.host.toLowerCase().endsWith('.internal')) {
      throw const FormatException(
        '请输入 HTTPS 远程 MCP 地址；暂不支持本机地址、IP 地址或带账号信息的链接',
      );
    }
    return uri;
  }

  static Future<void> _checkPublicEndpoint(Uri uri) async {
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any((address) => !_isPublic(address))) {
      throw const FormatException('MCP 地址解析到了内网或保留 IP，出于安全原因已拒绝连接');
    }
  }

  static bool _isPublic(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final a = bytes[0], b = bytes[1];
      if (a == 0 ||
          a == 10 ||
          a == 127 ||
          a >= 224 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && (b == 168 || b == 0 || b == 2)) ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 198 && (b == 18 || b == 19 || b == 51)) ||
          (a == 203 && b == 0 && bytes[2] == 113)) {
        return false;
      }
      return true;
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      final isMappedIpv4 =
          bytes.take(10).every((byte) => byte == 0) &&
          bytes[10] == 255 &&
          bytes[11] == 255;
      if (isMappedIpv4) {
        return _isPublic(InternetAddress.fromRawAddress(bytes.sublist(12)));
      }
      if (address.isLoopback ||
          address.isLinkLocal ||
          address.isMulticast ||
          bytes[0] == 0xfc ||
          bytes[0] == 0xfd) {
        return false;
      }
      return true;
    }
    return false;
  }

  static String _safeId(Object? value) {
    final id = value?.toString() ?? '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
      throw const FormatException('MCP 连接器编号无效');
    }
    return id;
  }

  static String _key(String tenantId, String id) => 'mcp/$tenantId/$id';

  static Map<String, Object?> _public(Map<String, dynamic> value) {
    var status = value['status'] ?? 'ready';
    var error = value['error'];
    try {
      parseRemoteUrl(value['url']?.toString() ?? '');
    } on FormatException {
      status = 'unsupported';
      error = '连接地址已失效，请从推荐目录重新安装';
    }
    return {
      'id': value['id'],
      'name': value['name'],
      'url': value['url'],
      'has_bearer_token': value['encrypted_bearer_token'] != null,
      'keywords': value['keywords'] ?? const <String>[],
      'icon': value['icon'] ?? const {'icon_asset': 'mcp', 'icon_data': ''},
      if (value['catalog_id'] != null) 'catalog_id': value['catalog_id'],
      if (value['version'] != null) 'version': value['version'],
      'status': status,
      'auth_mode': value['auth_mode'] ?? 'none',
      if (value['tool_count'] != null) 'tool_count': value['tool_count'],
      if (error != null) 'error': error,
      'created_at': value['created_at'],
      'updated_at': value['updated_at'],
    };
  }
}
