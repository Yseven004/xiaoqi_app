import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';

class McpConnectionCredentials {
  const McpConnectionCredentials({
    required this.id,
    required this.name,
    required this.url,
    required this.bearerToken,
  });

  final String id;
  final String name;
  final Uri url;
  final String? bearerToken;

  McpServerConfig serverConfig() => McpServerConfig(
    url: url,
    headers: bearerToken == null
        ? null
        : {'Authorization': 'Bearer $bearerToken'},
    timeout: const Duration(seconds: 15),
  );
}

/// Tenant-scoped remote MCP connection storage and transport setup.
/// Credentials are encrypted at rest using the server's existing secret.
class McpConnectionService {
  McpConnectionService(this.store, {String? pepper})
    : _pepper =
          pepper ?? Platform.environment['CAPABILITY_AUTH_CODE_PEPPER'] ?? '';

  final CloudStore store;
  final String _pepper;
  static const _uuid = Uuid();
  static final _cipher = AesGcm.with256bits();

  List<Map<String, Object?>> list(String tenantId) => store
      .list('mcp/$tenantId/', limit: 100)
      .map((entry) => _public(entry.$2.value))
      .toList(growable: false);

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
    final suppliedToken = input['bearer_token']?.toString().trim();
    final encrypted = suppliedToken == null || suppliedToken.isEmpty
        ? previous?.value['encrypted_bearer_token']
        : await _encrypt(suppliedToken);
    final now = DateTime.now().toUtc().toIso8601String();
    final value = <String, dynamic>{
      'id': id,
      'name': name,
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
    return store.delete(key, expectedRevision: previous.revision);
  }

  Future<Map<String, Object?>> test(String tenantId, String id) async {
    final connection = await _read(tenantId, _safeId(id));
    final client = await connect(connection);
    try {
      await client.ready().timeout(const Duration(seconds: 20));
      final tools = <Map<String, dynamic>>[];
      String? cursor;
      do {
        final page = await client
            .listTools(cursor: cursor)
            .timeout(const Duration(seconds: 20));
        tools.addAll(
          (page['tools'] as List? ?? const []).whereType<Map>().map(
            (tool) => Map<String, dynamic>.from(tool),
          ),
        );
        cursor = page['nextCursor']?.toString();
        if (tools.length > 100) {
          throw StateError('MCP 连接器返回超过 100 个工具，当前暂不支持');
        }
      } while (cursor != null && cursor.isNotEmpty);
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
    } finally {
      await client.close();
    }
  }

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
    if (rawIds is! List || rawIds.length > 8) {
      throw const FormatException('一次最多选择 8 个 MCP 连接器');
    }
    final ids = rawIds.map(_safeId).toSet();
    final result = <McpConnectionCredentials>[];
    for (final id in ids) {
      result.add(await _read(tenantId, id));
    }
    return result;
  }

  Future<McpConnectionCredentials> _read(String tenantId, String id) async {
    final document = store.get(_key(tenantId, id));
    if (document == null) throw StateError('MCP 连接器不存在，请刷新后重新选择');
    final encrypted = document.value['encrypted_bearer_token'];
    final token = encrypted is Map ? await _decrypt(encrypted) : null;
    return McpConnectionCredentials(
      id: id,
      name: document.value['name']?.toString() ?? 'MCP 连接器',
      url: parseRemoteUrl(document.value['url']?.toString() ?? ''),
      bearerToken: token,
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

  static Map<String, Object?> _public(Map<String, dynamic> value) => {
    'id': value['id'],
    'name': value['name'],
    'url': value['url'],
    'has_bearer_token': value['encrypted_bearer_token'] != null,
    'created_at': value['created_at'],
    'updated_at': value['updated_at'],
  };
}
