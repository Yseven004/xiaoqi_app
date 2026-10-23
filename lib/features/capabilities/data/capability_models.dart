enum CapabilityKind { skill, plugin }

enum CapabilitySyncState { pending, synced, conflict, failed }

enum McpInstallationState {
  installing,
  needsLogin,
  connecting,
  ready,
  failed,
  unsupported,
}

class McpCatalogEntry {
  const McpCatalogEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.runtime,
    required this.authMode,
    required this.status,
    this.repository,
    this.iconAsset = 'assets/icons/capabilities/mcp_connector.svg',
    this.package,
    this.packageVersion,
    this.reason,
    this.keywords = const [],
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final String runtime;
  final String authMode;
  final McpInstallationState status;
  final String? repository;
  final String iconAsset;
  final String? package;
  final String? packageVersion;
  final String? reason;
  final List<String> keywords;

  bool get requiresLogin => authMode == 'oauth';

  factory McpCatalogEntry.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('MCP 工具清单格式无效');
    return McpCatalogEntry(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
      version: raw['version']?.toString() ?? '',
      runtime: raw['runtime']?.toString() ?? 'remote_https',
      authMode: raw['auth_mode']?.toString() ?? 'none',
      status: _mcpState(raw['status']),
      repository: raw['repository']?.toString(),
      iconAsset:
          raw['icon_asset']?.toString() ??
          'assets/icons/capabilities/mcp_connector.svg',
      package: raw['package']?.toString(),
      packageVersion: raw['package_version']?.toString(),
      reason: raw['reason']?.toString(),
      keywords: raw['keywords'] is List
          ? (raw['keywords'] as List).whereType<String>().toList()
          : const [],
    );
  }
}

class McpConnectionRecord {
  const McpConnectionRecord({
    required this.id,
    required this.name,
    required this.url,
    required this.hasBearerToken,
    this.catalogId,
    this.version,
    this.status = McpInstallationState.ready,
    this.authMode = 'none',
    this.toolCount,
    this.error,
  });

  final String id;
  final String name;
  final String url;
  final bool hasBearerToken;
  final String? catalogId;
  final String? version;
  final McpInstallationState status;
  final String authMode;
  final int? toolCount;
  final String? error;

  bool get isReady => status == McpInstallationState.ready;
  bool get needsLogin => status == McpInstallationState.needsLogin;

  factory McpConnectionRecord.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('MCP 连接器格式无效');
    return McpConnectionRecord(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      url: raw['url']?.toString() ?? '',
      hasBearerToken: raw['has_bearer_token'] == true,
      catalogId: raw['catalog_id']?.toString(),
      version: raw['version']?.toString(),
      status: _mcpState(raw['status']),
      authMode: raw['auth_mode']?.toString() ?? 'none',
      toolCount: (raw['tool_count'] as num?)?.toInt(),
      error: raw['error']?.toString(),
    );
  }
}

McpInstallationState _mcpState(Object? value) => switch (value?.toString()) {
  'installing' => McpInstallationState.installing,
  'needs_login' => McpInstallationState.needsLogin,
  'connecting' => McpInstallationState.connecting,
  'failed' => McpInstallationState.failed,
  'unsupported' => McpInstallationState.unsupported,
  _ => McpInstallationState.ready,
};

class CapabilityVersion {
  const CapabilityVersion({
    required this.id,
    required this.number,
    required this.content,
    required this.contentHash,
    required this.createdAt,
    this.parentVersionId,
    this.files = const {},
    this.components = const [],
  });

  final String id;
  final int number;
  final String content;
  final String contentHash;
  final DateTime createdAt;
  final String? parentVersionId;
  final Map<String, String> files;
  final List<Map<String, dynamic>> components;

  Map<String, Object?> toJson() => {
    'id': id,
    'number': number,
    'content': content,
    'content_hash': contentHash,
    'created_at': createdAt.toIso8601String(),
    'parent_version_id': parentVersionId,
    'files': files,
    if (components.isNotEmpty) 'components': components,
  };

  factory CapabilityVersion.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('技能版本格式无效');
    return CapabilityVersion(
      id: raw['id']?.toString() ?? '',
      number: (raw['number'] as num?)?.toInt() ?? 1,
      content: raw['content']?.toString() ?? '',
      contentHash: raw['content_hash']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(raw['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      parentVersionId: raw['parent_version_id']?.toString(),
      files: raw['files'] is Map
          ? (raw['files'] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      components: raw['components'] is List
          ? (raw['components'] as List)
                .whereType<Map>()
                .map((value) => Map<String, dynamic>.from(value))
                .toList(growable: false)
          : const [],
    );
  }
}

class CapabilityRecord {
  const CapabilityRecord({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.versions,
    required this.currentVersionId,
    required this.createdAt,
    required this.updatedAt,
    this.showInMenu = true,
    this.syncState = CapabilitySyncState.pending,
    this.deletedAt,
    this.cloudRevision = 0,
    this.origin = 'local',
    this.enabled = true,
    this.source = const {},
    this.compatibility = const {},
    this.keywords,
  });

  final String id;
  final CapabilityKind kind;
  final String name;
  final String description;
  final List<CapabilityVersion> versions;
  final String currentVersionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool showInMenu;
  final CapabilitySyncState syncState;
  final DateTime? deletedAt;
  final int cloudRevision;
  final String origin;
  final bool enabled;
  final Map<String, dynamic> source;
  final Map<String, dynamic> compatibility;
  final List<String>? keywords;

  bool get isDeleted => deletedAt != null;
  bool get isServerInstallation => origin == 'github' || origin == 'upload';
  CapabilityVersion? get currentVersion {
    for (final version in versions.reversed) {
      if (version.id == currentVersionId) return version;
    }
    return versions.isEmpty ? null : versions.last;
  }

  CapabilityRecord copyWith({
    String? name,
    String? description,
    List<CapabilityVersion>? versions,
    String? currentVersionId,
    DateTime? updatedAt,
    bool? showInMenu,
    CapabilitySyncState? syncState,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? cloudRevision,
    bool? enabled,
  }) => CapabilityRecord(
    id: id,
    kind: kind,
    name: name ?? this.name,
    description: description ?? this.description,
    versions: versions ?? this.versions,
    currentVersionId: currentVersionId ?? this.currentVersionId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    showInMenu: showInMenu ?? this.showInMenu,
    syncState: syncState ?? this.syncState,
    deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    cloudRevision: cloudRevision ?? this.cloudRevision,
    origin: origin,
    enabled: enabled ?? this.enabled,
    source: source,
    compatibility: compatibility,
    keywords: keywords,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'kind': kind.name,
    'name': name,
    'description': description,
    'versions': versions.map((version) => version.toJson()).toList(),
    'current_version_id': currentVersionId,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'show_in_menu': showInMenu,
    'sync_state': syncState.name,
    'deleted_at': deletedAt?.toIso8601String(),
    'cloud_revision': cloudRevision,
    'origin': origin,
    'enabled': enabled,
    'source': source,
    'compatibility': compatibility,
    if (keywords != null) 'keywords': keywords,
  };

  factory CapabilityRecord.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('技能记录格式无效');
    final versions = raw['versions'] is List
        ? (raw['versions'] as List)
              .map(CapabilityVersion.fromJson)
              .toList(growable: false)
        : const <CapabilityVersion>[];
    return CapabilityRecord(
      id: raw['id']?.toString() ?? '',
      kind: CapabilityKind.values.firstWhere(
        (value) => value.name == raw['kind'],
        orElse: () => CapabilityKind.skill,
      ),
      name: raw['name']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
      versions: versions,
      currentVersionId: raw['current_version_id']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(raw['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(raw['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      showInMenu: raw['show_in_menu'] != false,
      syncState: CapabilitySyncState.values.firstWhere(
        (value) => value.name == raw['sync_state'],
        orElse: () => CapabilitySyncState.pending,
      ),
      deletedAt: DateTime.tryParse(raw['deleted_at']?.toString() ?? ''),
      cloudRevision: (raw['cloud_revision'] as num?)?.toInt() ?? 0,
      origin: raw['origin']?.toString() ?? 'local',
      enabled: raw['enabled'] != false,
      source: raw['source'] is Map
          ? Map<String, dynamic>.from(raw['source'] as Map)
          : const {},
      compatibility: raw['compatibility'] is Map
          ? Map<String, dynamic>.from(raw['compatibility'] as Map)
          : const {},
      keywords: raw['keywords'] is List
          ? (raw['keywords'] as List).whereType<String>().toList()
          : null,
    );
  }
}

class CapabilityDraft {
  const CapabilityDraft({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.updatedAt,
    this.kind = CapabilityKind.skill,
    this.previousContent,
    this.userSuggestion = '',
    this.files = const {},
    this.cloudRevision = 0,
    this.cloudOwnerEmail,
    this.targetCapabilityId,
  });

  final String id;
  final CapabilityKind kind;
  final String name;
  final String description;
  final String content;
  final String? previousContent;
  final String userSuggestion;
  final DateTime updatedAt;
  final Map<String, String> files;
  final int cloudRevision;
  final String? cloudOwnerEmail;
  final String? targetCapabilityId;

  CapabilityDraft copyWith({
    String? name,
    String? description,
    String? content,
    String? previousContent,
    String? userSuggestion,
    DateTime? updatedAt,
    Map<String, String>? files,
    int? cloudRevision,
    String? cloudOwnerEmail,
    String? targetCapabilityId,
  }) => CapabilityDraft(
    id: id,
    kind: kind,
    name: name ?? this.name,
    description: description ?? this.description,
    content: content ?? this.content,
    previousContent: previousContent ?? this.previousContent,
    userSuggestion: userSuggestion ?? this.userSuggestion,
    updatedAt: updatedAt ?? this.updatedAt,
    files: files ?? this.files,
    cloudRevision: cloudRevision ?? this.cloudRevision,
    cloudOwnerEmail: cloudOwnerEmail ?? this.cloudOwnerEmail,
    targetCapabilityId: targetCapabilityId ?? this.targetCapabilityId,
  );

  Map<String, Object?> toJson({bool includeLocalMetadata = true}) => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'description': description,
    'content': content,
    'previous_content': previousContent,
    'user_suggestion': userSuggestion,
    'updated_at': updatedAt.toIso8601String(),
    'files': files,
    'cloud_revision': cloudRevision,
    if (targetCapabilityId != null) 'target_capability_id': targetCapabilityId,
    if (includeLocalMetadata && cloudOwnerEmail != null)
      'cloud_owner_email': cloudOwnerEmail,
  };

  factory CapabilityDraft.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('草稿格式无效');
    return CapabilityDraft(
      id: raw['id']?.toString() ?? '',
      kind: CapabilityKind.values.firstWhere(
        (value) => value.name == raw['kind'],
        orElse: () => CapabilityKind.skill,
      ),
      name: raw['name']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
      content: raw['content']?.toString() ?? '',
      previousContent: raw['previous_content']?.toString(),
      userSuggestion: raw['user_suggestion']?.toString() ?? '',
      updatedAt:
          DateTime.tryParse(raw['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      files: raw['files'] is Map
          ? (raw['files'] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      cloudRevision: (raw['cloud_revision'] as num?)?.toInt() ?? 0,
      cloudOwnerEmail: raw['cloud_owner_email']?.toString(),
      targetCapabilityId: raw['target_capability_id']?.toString(),
    );
  }
}
