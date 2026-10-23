import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../features/capabilities/data/capability_models.dart';
import '../features/capabilities/data/capability_store.dart';
import '../features/capabilities/presentation/market_ui.dart';
import '../features/capabilities/presentation/market_search.dart';
import '../features/capabilities/presentation/market_skill_editor.dart';
import '../features/capabilities/presentation/skill_presentation.dart';
import '../widgets/app_toast.dart';

part 'extension_market_details.dart';
part 'extension_market_forms.dart';

enum ExtensionKind { skill, plugin, mcp }

Future<CapabilityDraft?> showSkillContentImport(
  BuildContext context, {
  CapabilityKind kind = CapabilityKind.skill,
}) async {
  var mcp = false;
  final result = await showDialog<Object?>(
    context: context,
    requestFocus: false,
    barrierDismissible: false,
    barrierColor: marketBarrier,
    builder: (dialogContext) => Theme(
      data: marketTheme(context),
      child: StatefulBuilder(
        builder: (_, update) => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(dialogContext)
              ? Duration.zero
              : const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              for (final child in previous)
                IgnorePointer(child: ExcludeSemantics(child: child)),
              if (current != null) current,
            ],
          ),
          child: mcp
              ? const _McpConnectionDialog(
                  key: ValueKey('mcp'),
                  forEditor: true,
                )
              : _PackageImportDialog(
                  key: const ValueKey('package'),
                  skill: kind == CapabilityKind.skill,
                  upload: true,
                  forEditor: true,
                  onMcp: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    update(() => mcp = true);
                  },
                ),
        ),
      ),
    ),
  );
  return result is CapabilityDraft ? result : null;
}

class ExtensionChatRequest {
  const ExtensionChatRequest(this.selection, {this.prompt = ''});
  final Map<String, Object?> selection;
  final String prompt;
}

class _MarketEntry {
  const _MarketEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    this.author = '',
    this.url,
    this.record,
    this.catalog,
    this.connection,
    this.examples = const [],
    this.category = '效率工具',
    this.aliases = const [],
    this.keywords = const [],
    this.capabilities = const [],
    this.publication,
  });
  final String id, name, description, author, category;
  final ExtensionKind kind;
  final String? url;
  final CapabilityRecord? record;
  final McpCatalogEntry? catalog;
  final McpConnectionRecord? connection;
  final List<String> examples;
  final List<String> aliases, keywords, capabilities;
  final Map<String, dynamic>? publication;
  Map<String, dynamic> get presentation => kind == ExtensionKind.mcp
      ? connection?.icon ?? const {'icon_asset': 'mcp', 'icon_data': ''}
      : publication?['presentation'] is Map
      ? Map<String, dynamic>.from(publication!['presentation'] as Map)
      : record?.presentation ?? const {};
  MarketSearchDocument get searchDocument => MarketSearchDocument(
    name: name,
    description: description,
    author: author,
    aliases: aliases,
    keywords: keywords,
    capabilities: capabilities,
  );
  bool get installed => record != null || connection != null;
  // Capability records currently come from manual import/creation. Market
  // installations are catalog-backed MCP connections, not package imports.
  bool get personal =>
      record != null && record!.origin != 'market' ||
      (connection != null && connection!.catalogId == null);
  bool get editable => record != null && !record!.isServerInstallation;
  String get developer => author.isEmpty ? '未提供' : author;
  String get version =>
      record?.currentVersion?.number.toString() ??
      connection?.version ??
      catalog?.version ??
      '未提供';
  String get asset {
    if (kind == ExtensionKind.mcp)
      return 'assets/icons/capabilities/mcp_connector.svg';
    final identity = name.toLowerCase();
    for (final brand in const [
      'github',
      'notion',
      'supabase',
      'figma',
      'slack',
      'canva',
      'linear',
      'airtable',
      'vercel',
      'dropbox',
      'todoist',
      'shopify',
    ]) {
      if (identity.contains(brand)) return '$marketAssets$brand.svg';
    }
    if (identity.contains('google drive'))
      return '${marketAssets}googledrive.svg';
    return '${marketAssets}detail/${kind == ExtensionKind.skill ? 'file-text' : 'plugs'}.svg';
  }

  factory _MarketEntry.fromRecord(CapabilityRecord record) {
    final sourceUrl = record.source['source_url']?.toString();
    final uri = Uri.tryParse(sourceUrl ?? '');
    Map metadata = const {};
    try {
      final match = RegExp(
        r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
      ).firstMatch(record.currentVersion?.content ?? '');
      if (match != null) {
        final parsed = loadYaml(match.group(1)!);
        if (parsed is Map) metadata = parsed;
      }
    } catch (_) {
      /* Keep malformed user documents readable without inventing metadata. */
    }
    final extra = metadata['metadata'];
    final rawAuthor =
        record.source['author']?.toString() ??
        metadata['author']?.toString() ??
        (extra is Map ? extra['author']?.toString() : null) ??
        (uri?.host == 'github.com' && uri!.pathSegments.isNotEmpty
            ? uri.pathSegments.first
            : record.origin == 'local'
            ? '你'
            : '');
    return _MarketEntry(
      id: record.id,
      name: record.displayName,
      description: record.description,
      kind: record.kind == CapabilityKind.skill
          ? ExtensionKind.skill
          : ExtensionKind.plugin,
      author:
          record.source['official'] == true ||
              rawAuthor == '小七官方' ||
              rawAuthor == '小七'
          ? marketOfficialDeveloper
          : rawAuthor,
      url: sourceUrl,
      record: record,
      aliases: marketSearchTerms([
        ...marketSearchTerms(record.source['aliases']),
        ...marketSearchTerms(metadata['aliases']),
        if (extra is Map) ...marketSearchTerms(extra['aliases']),
      ]),
      capabilities: [
        for (final component
            in record.currentVersion?.components ??
                const <Map<String, dynamic>>[])
          for (final field in [
            'name',
            'description',
            'type',
            'mcp_server_name',
          ])
            if (component[field]?.toString().trim().isNotEmpty == true)
              component[field].toString(),
      ],
      keywords: record.keywordsEdited
          ? const []
          : marketSearchTerms([
              ...marketSearchTerms(
                record.keywords ??
                    (metadata.containsKey('keywords')
                        ? metadata['keywords']
                        : extra is Map && extra.containsKey('keywords')
                        ? extra['keywords']
                        : record.source['keywords']),
              ),
              ...marketSearchTerms(metadata['tags']),
              if (extra is Map) ...marketSearchTerms(extra['tags']),
              ...marketSearchTerms(record.source['tags']),
            ]),
      examples:
          (metadata['examples'] is List
                  ? metadata['examples'] as List
                  : const [])
              .whereType<String>()
              .where((value) => value.trim().isNotEmpty)
              .toList(),
      category: record.kind == CapabilityKind.skill
          ? '技能'
          : record.origin == 'github'
          ? '公开导入'
          : '个人插件',
    );
  }
  factory _MarketEntry.fromPublication(
    Map<String, dynamic> publication,
    List<CapabilityRecord> records,
  ) {
    final presentation = publication['presentation'] as Map? ?? const {};
    final record = records
        .where(
          (r) =>
              !r.isDeleted &&
              (r.source['publication_id'] == publication['id'] ||
                  publication['is_owner'] == true &&
                      r.id == publication['capability_id']),
        )
        .firstOrNull;
    return _MarketEntry(
      id: publication['id'].toString(),
      name: presentation['title']?.toString() ?? publication['name'].toString(),
      description: publication['description']?.toString() ?? '',
      kind: publication['kind'] == 'plugin'
          ? ExtensionKind.plugin
          : ExtensionKind.skill,
      author: publication['author']?.toString() ?? '未提供',
      record: record,
      publication: publication,
      category: publication['kind'] == 'plugin' ? '插件' : '技能',
    );
  }

  factory _MarketEntry.fromMcp(
    McpCatalogEntry? catalog,
    McpConnectionRecord? connection, {
    bool publicListing = false,
  }) => _MarketEntry(
    id: connection?.id ?? catalog!.id,
    name: publicListing ? catalog!.name : connection?.name ?? catalog!.name,
    description:
        catalog?.description ?? Uri.tryParse(connection?.url ?? '')?.host ?? '',
    kind: ExtensionKind.mcp,
    catalog: catalog,
    connection: connection,
    author: catalog == null
        ? '你'
        : Uri.tryParse(catalog.repository ?? '')?.pathSegments.firstOrNull ??
              '',
    url: connection?.url ?? catalog?.repository,
    category: 'MCP 服务',
    keywords: catalog?.keywords ?? const [],
  );
}

class ExtensionMarketPage extends StatefulWidget {
  const ExtensionMarketPage({
    this.initialKind = ExtensionKind.plugin,
    super.key,
  });
  final ExtensionKind initialKind;
  @override
  State<ExtensionMarketPage> createState() => _ExtensionMarketPageState();
}

class _ExtensionMarketPageState extends State<ExtensionMarketPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'extension market search');
  final _cloud = CapabilityCloudSync.instance;
  List<CapabilityRecord> _records = [];
  List<McpConnectionRecord> _connections = [];
  List<McpCatalogEntry> _catalog = [];
  List<Map<String, dynamic>> _publishedSkills = [];
  List<CapabilityDraft> _authoringDrafts = [];
  bool _loadingSkills = true;
  String? _skillsError;
  bool _loadingCatalog = true;
  String? _catalogError;
  Timer? _searchDebounce;
  TextEditingValue _lastSearchValue = TextEditingValue.empty;
  String _searchQuery = '';
  final Set<String> _busyIds = {};
  late ExtensionKind _kind;
  bool _personal = false, _loading = true, _loadingMcp = true;
  static const _categories = ['推荐'];
  String _category = '推荐';
  String? _error, _mcpError, _listTitle;
  StreamSubscription<Uri>? _links;
  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind == ExtensionKind.skill
        ? ExtensionKind.skill
        : ExtensionKind.plugin;
    if (widget.initialKind == ExtensionKind.mcp) _listTitle = '连接管理';
    _search.addListener(_searchChanged);
    unawaited(_reload());
    unawaited(_reloadMcp());
    unawaited(_reloadCatalog());
    unawaited(_reloadSkills());
    _links = AppLinks().uriLinkStream.listen((uri) {
      if (uri.toString().contains('mcp') && uri.toString().contains('oauth'))
        unawaited(_reloadMcp());
    }, onError: (_) {});
  }

  void _searchChanged() {
    final value = _search.value;
    if (value.text == _lastSearchValue.text &&
        value.composing == _lastSearchValue.composing)
      return;
    _lastSearchValue = value;
    _searchDebounce?.cancel();
    final query = value.text.trim();
    setState(() {
      if (query.isEmpty) _searchQuery = '';
    });
    if (query.isEmpty ||
        value.composing.isValid && !value.composing.isCollapsed)
      return;
    if (query == _searchQuery) return;
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _searchQuery = query);
    });
  }

  bool get _searchPending =>
      _search.text.trim().isNotEmpty &&
      (_search.text.trim() != _searchQuery ||
          _search.value.composing.isValid &&
              !_search.value.composing.isCollapsed);
  @override
  void dispose() {
    _links?.cancel();
    _searchDebounce?.cancel();
    _search.removeListener(_searchChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (mounted)
      setState(() {
        _loading = true;
        _error = null;
      });
    try {
      final store = CapabilityStore.instance;
      await store.retireLegacyDrafts(
        accountEmail: await _cloud.signedInEmail ?? '',
      );
      final local = await store.list(includeDeleted: true);
      final drafts = await store.authoringDrafts(await _cloud.signedInEmail);
      if (!mounted) return;
      setState(() {
        _records = local;
        _authoringDrafts = drafts;
      });
      bool hasUnsyncedLocal(Iterable<CapabilityRecord> records) => records.any(
        (record) =>
            !record.isServerInstallation &&
            record.syncState != CapabilitySyncState.synced,
      );
      // Push local edits and deletion markers before a remote list can replace
      // them. Failed or conflicting sync must leave the local copy intact.
      if (hasUnsyncedLocal(local)) {
        await _cloud.syncNow();
        final synced = await store.list(includeDeleted: true);
        if (!mounted) return;
        setState(() {
          _records = synced;
        });
        if (hasUnsyncedLocal(synced)) {
          throw StateError('本机修改尚未完成同步，已保留本机记录');
        }
      }
      await _cloud.syncNow();
      if (!mounted) return;
      final current = await CapabilityStore.instance.list();
      final currentDrafts = await store.authoringDrafts(
        await _cloud.signedInEmail,
      );
      if (mounted)
        setState(() {
          _records = current;
          _authoringDrafts = currentDrafts;
        });
    } catch (error) {
      if (mounted) setState(() => _error = '安装记录同步失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadMcp() async {
    if (mounted)
      setState(() {
        _loadingMcp = true;
        _mcpError = null;
      });
    try {
      final connections = await _cloud.listMcpConnections();
      if (mounted)
        setState(() {
          _connections = connections;
        });
    } catch (error) {
      if (mounted) setState(() => _mcpError = '连接列表加载失败：$error');
    } finally {
      if (mounted) setState(() => _loadingMcp = false);
    }
  }

  Future<void> _reloadCatalog() async {
    if (mounted)
      setState(() {
        _loadingCatalog = true;
        _catalogError = null;
      });
    try {
      final catalog = await _cloud.listMcpCatalog();
      if (mounted) setState(() => _catalog = catalog);
    } catch (error) {
      if (mounted) setState(() => _catalogError = '公开目录读取失败：$error');
    } finally {
      if (mounted) setState(() => _loadingCatalog = false);
    }
  }

  List<_MarketEntry> get _entries =>
      [
            ..._records.where((r) => !r.isDeleted).map(_MarketEntry.fromRecord),
            ..._connections.map(
              (c) => _MarketEntry.fromMcp(
                _catalog.where((entry) => entry.id == c.catalogId).firstOrNull,
                c,
              ),
            ),
          ]
          .where(
            (e) => _kind == ExtensionKind.skill
                ? e.kind == ExtensionKind.skill
                : e.kind != ExtensionKind.skill,
          )
          .toList();
  List<_MarketEntry> get _installed =>
      _entries.where((entry) => !entry.personal).toList();
  List<_MarketEntry> get _personalEntries =>
      _entries.where((entry) => entry.personal).toList();
  List<_MarketEntry> get _publicEntries => _kind == ExtensionKind.skill
      ? _publishedSkills
            .where((p) => p['kind'] != 'plugin')
            .map((p) => _MarketEntry.fromPublication(p, _records))
            .toList()
      : [
          ..._publishedSkills
              .where((p) => p['kind'] == 'plugin')
              .map((p) => _MarketEntry.fromPublication(p, _records)),
          ..._catalog
              .map(
                (entry) => _MarketEntry.fromMcp(
                  entry,
                  _connections
                      .where((c) => c.catalogId == entry.id)
                      .firstOrNull,
                  publicListing: true,
                ),
              )
              .toList(),
        ];

  Future<void> _reloadSkills() async {
    if (mounted)
      setState(() {
        _loadingSkills = true;
        _skillsError = null;
      });
    try {
      final items = await _cloud.skillMarket();
      if (mounted) setState(() => _publishedSkills = items);
    } catch (error) {
      if (mounted) setState(() => _skillsError = '公开技能读取失败：$error');
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  List<_MarketEntry> _matching(Iterable<_MarketEntry> entries) {
    if (_searchPending) return const [];
    if (_searchQuery.isEmpty) return entries.toList();
    final matches = <(_MarketEntry, int)>[];
    for (final entry in entries) {
      final score = entry.searchDocument.score(_searchQuery);
      if (score != null) matches.add((entry, score));
    }
    matches.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      final byName = a.$1.name.compareTo(b.$1.name);
      return byName != 0 ? byName : a.$1.id.compareTo(b.$1.id);
    });
    return matches.map((match) => match.$1).toList();
  }

  void _showList(String title) => setState(() {
    FocusManager.instance.primaryFocus?.unfocus();
    _listTitle = title;
    _search.clear();
  });
  Future<void> _import({
    String? url,
    bool upload = false,
    CapabilityRecord? update,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showDialog<Object?>(
      context: context,
      requestFocus: false,
      barrierDismissible: false,
      barrierColor: marketBarrier,
      builder: (_) => Theme(
        data: marketTheme(context),
        child: _PackageImportDialog(
          url: url,
          upload: upload,
          skill: _kind == ExtensionKind.skill,
          update: update,
        ),
      ),
    );
    if (!mounted) return;
    if (result is CapabilityDraft) await _edit(draft: result);
    if (result == 'mcp') await _mcpForm();
    if (mounted) await _reload();
  }

  Future<void> _edit({
    CapabilityDraft? draft,
    CapabilityRecord? record,
    bool openImport = false,
  }) async {
    final kind =
        draft?.kind ??
        record?.kind ??
        (_kind == ExtensionKind.skill
            ? CapabilityKind.skill
            : CapabilityKind.plugin);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => MarketSkillEditor(
          draft: draft,
          record: record,
          kind: kind,
          openImportOnStart: openImport,
          onImport: (ctx) => showSkillContentImport(ctx, kind: kind),
        ),
      ),
    );
    if (mounted) await _reload();
    if (mounted) await _reloadSkills();
  }

  void _chat(_MarketEntry? entry, [String prompt = '']) {
    Map<String, Object?> selected;
    if (entry == null) {
      selected = {'type': 'action', 'id': 'create-skill', 'name': '创建技能'};
    } else if (entry.kind == ExtensionKind.mcp) {
      final c = entry.connection;
      if (c == null || !c.isReady) {
        AppToast.show(context, '请先完成授权并连接服务器');
        return;
      }
      selected = {
        'type': 'mcp',
        'id': c.id,
        'name': c.name,
        'url': c.url,
        'has_bearer_token': c.hasBearerToken,
        if (c.catalogId != null) 'catalog_id': c.catalogId,
        if (c.version != null) 'version': c.version,
      };
    } else {
      final r = entry.record;
      if (r == null || !r.enabled) {
        AppToast.show(context, '请先安装并启用此扩展');
        return;
      }
      if (r.syncState != CapabilitySyncState.synced) {
        AppToast.show(context, '技能尚未同步到服务器，请联网同步后重试');
        return;
      }
      selected = {
        'type': r.kind.name,
        'id': r.id,
        'name': r.name,
        'version_id': r.currentVersionId,
      };
    }
    Navigator.pop(context, ExtensionChatRequest(selected, prompt: prompt));
  }

  Future<void> _mcpForm([McpConnectionRecord? connection]) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showDialog<bool>(
      context: context,
      requestFocus: false,
      barrierDismissible: false,
      barrierColor: marketBarrier,
      builder: (_) => Theme(
        data: marketTheme(context),
        child: _McpConnectionDialog(connection: connection),
      ),
    );
    if (mounted) await _reloadMcp();
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        barrierColor: marketBarrier,
        builder: (ctx) => MarketDialog(
          title: title,
          children: [Text(body, style: const TextStyle(height: 1.65))],
          actions: [
            marketDialogButton('取消', () => Navigator.pop(ctx, false)),
            marketDialogButton(
              action,
              () => Navigator.pop(ctx, true),
              primary: true,
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _install(_MarketEntry entry) async {
    if (_busyIds.contains(entry.id)) return;
    setState(() => _busyIds.add(entry.id));
    try {
      await _installEntry(entry);
    } finally {
      if (mounted) setState(() => _busyIds.remove(entry.id));
    }
  }

  Future<void> _installEntry(_MarketEntry entry) async {
    if (entry.publication != null) {
      try {
        await _cloud.installMarketSkill(
          entry.id,
          (entry.publication!['publication_revision'] as num).toInt(),
        );
        await _reload();
        if (mounted) AppToast.show(context, '技能已安装');
      } catch (error) {
        if (mounted) AppToast.show(context, '安装未完成：$error');
      }
      return;
    }
    if (entry.catalog == null) {
      await _import(url: entry.url);
      return;
    }
    if (entry.catalog!.status == McpInstallationState.unsupported) {
      AppToast.show(context, entry.catalog!.reason ?? '暂不支持此服务');
      return;
    }
    if (!await _confirm(
      '安装 ${entry.name}',
      '连接后，小七可在你的任务中调用其中的工具。需要访问外部数据时仍按任务确认。',
      '安装插件',
    ))
      return;
    try {
      await _cloud.installMcp(entry.catalog!.id);
      await _reloadMcp();
      if (mounted) AppToast.show(context, '已安装，请在详情查看连接状态');
    } catch (error) {
      if (mounted) AppToast.show(context, '安装失败：$error');
    }
  }

  Future<void> _remove(_MarketEntry entry) async {
    if (!await _confirm(
      '移除 ${entry.name}？',
      '移除后，小七将不再使用这项扩展。你可以稍后重新添加。',
      '移除',
    ))
      return;
    try {
      if (entry.connection != null) {
        await _cloud.deleteMcpConnection(entry.connection!.id);
        await _reloadMcp();
      } else if (entry.record!.isServerInstallation) {
        await _cloud.manageInstallation(entry.record!, uninstall: true);
      } else {
        await CapabilityStore.instance.markDeleted(entry.record!.id);
        if (await _cloud.hasEmailSession) await _cloud.syncNow();
      }
      if (mounted) {
        await _reload();
        if (mounted) AppToast.show(context, '已移除');
      }
    } catch (error) {
      if (mounted) {
        await _reload();
        if (mounted) AppToast.show(context, '移除未完成：$error');
      }
    }
  }

  Future<void> _login(_MarketEntry entry) async {
    try {
      final uri = await _cloud.startMcpLogin(entry.connection!.id);
      if (uri == null ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication))
        throw StateError('无法打开授权页面');
      if (mounted) AppToast.show(context, '请在浏览器完成授权后返回小七');
    } catch (error) {
      if (mounted) AppToast.show(context, '授权失败：$error');
    }
  }

  Future<void> _reconnect(_MarketEntry entry) async {
    try {
      await _cloud.reconnectMcp(entry.connection!.id);
      await _reloadMcp();
    } catch (error) {
      if (mounted) AppToast.show(context, '连接失败：$error');
    }
  }

  Future<void> _open(_MarketEntry entry) async {
    if (entry.publication != null) {
      try {
        final detail = await _cloud.skillMarketDetail(entry.id);
        if (!mounted) return;
        entry = _MarketEntry.fromPublication(detail, _records);
      } catch (error) {
        if (mounted) AppToast.show(context, '详情读取失败：$error');
        return;
      }
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (detailContext) => _MarketDetailPage(
          entry: entry,
          onInstall: _install,
          onRemove: _remove,
          onEdit: (current) => _edit(record: current.record),
          onManage: (current) => current.connection != null
              ? _mcpForm(current.connection)
              : _manage(current),
          onLogin: _login,
          onReconnect: _reconnect,
          refresh: () async {
            if (entry.kind == ExtensionKind.mcp)
              await _reloadMcp();
            else
              await _reload();
            if (!mounted) return null;
            if (entry.publication != null) {
              final detail = await _cloud.skillMarketDetail(entry.id);
              return _MarketEntry.fromPublication(detail, _records);
            }
            return [..._entries, ..._publicEntries]
                .where(
                  (e) =>
                      e.id == entry.id ||
                      entry.catalog != null &&
                          e.catalog?.id == entry.catalog!.id ||
                      entry.url != null &&
                          (e.url == entry.url ||
                              e.record?.source['requested_url'] == entry.url),
                )
                .firstOrNull;
          },
          onChat: (updated, prompt) {
            Navigator.pop(detailContext);
            _chat(updated, prompt);
          },
        ),
      ),
    );
  }

  Future<void> _manage(_MarketEntry entry) async {
    final record = entry.record!;
    await showDialog<void>(
      context: context,
      barrierColor: marketBarrier,
      builder: (ctx) => MarketDialog(
        title: '管理 ${entry.name}',
        children: [
          Text(entry.description, style: const TextStyle(height: 1.65)),
          const SizedBox(height: 18),
          Text('版本 ${entry.version} · ${record.enabled ? '已启用' : '已停用'}'),
          if (record.isServerInstallation)
            marketDialogButton('检查更新', () {
              Navigator.pop(ctx);
              unawaited(
                _import(update: record, upload: record.origin == 'upload'),
              );
            }, icon: 'link'),
        ],
        actions: [
          marketDialogButton(
            '卸载${entry.kind == ExtensionKind.skill ? '技能' : '插件'}',
            () {
              Navigator.pop(ctx);
              unawaited(_remove(entry));
            },
            icon: 'trash-danger',
          ),
          marketDialogButton(record.enabled ? '停用' : '启用', () async {
            try {
              await _cloud.manageInstallation(record, enabled: !record.enabled);
              if (ctx.mounted) Navigator.pop(ctx);
              await _reload();
            } catch (error) {
              if (ctx.mounted) AppToast.show(ctx, '修改失败：$error');
            }
          }),
          marketDialogButton('完成', () => Navigator.pop(ctx), primary: true),
        ],
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, String label, String icon) =>
      PopupMenuItem(
        value: value,
        height: 48,
        child: Row(
          children: [
            marketIcon(icon),
            const SizedBox(width: 12),
            Flexible(child: Text(label)),
          ],
        ),
      );
  Widget _addMenu() => Theme(
    data: marketTheme(context).copyWith(
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    ),
    child: _kind != ExtensionKind.skill
        ? TextButton(
            onPressed: () => unawaited(_edit(openImport: true)),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _addButtonFace(),
          )
        : PopupMenuButton<String>(
            position: PopupMenuPosition.under,
            offset: const Offset(0, 8),
            tooltip: '添加$_label',
            color: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            onSelected: (action) {
              switch (action) {
                case 'chat':
                  _chat(null);
                case 'editor':
                  unawaited(_edit(openImport: true));
              }
            },
            itemBuilder: (_) => [
              _menuItem('chat', '通过聊天创建', 'chat'),
              _menuItem('editor', '使用编辑器创建', 'pencil'),
            ],
            child: _addButtonFace(),
          ),
  );
  Widget _addButtonFace() => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: SvgPicture.asset(
            'assets/icons/extensions/market_add_button.svg',
            fit: BoxFit.fill,
            excludeFromSemantics: true,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 17, vertical: 14),
          child: Text(
            '添加',
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ],
    ),
  );
  String get _label => _kind == ExtensionKind.skill ? '技能' : '插件';
  Widget _row(_MarketEntry entry) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 81),
    child: Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _open(entry),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  entry.presentation.isNotEmpty
                      ? SkillPresentationIcon(entry.presentation, size: 40)
                      : MarketBrand(entry.asset),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          entry.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: marketMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!entry.installed)
          marketIconButton(
            'plus-light',
            '添加 ${entry.name}',
            _busyIds.contains(entry.id) ? null : () => _install(entry),
          )
        else
          PopupMenuButton<String>(
            position: PopupMenuPosition.under,
            offset: const Offset(0, 8),
            tooltip: '管理 ${entry.name}',
            icon: marketIcon('dots', size: 25),
            color: Colors.white,
            surfaceTintColor: Colors.transparent,
            onSelected: (action) {
              switch (action) {
                case 'detail':
                  unawaited(_open(entry));
                case 'edit':
                  unawaited(_edit(record: entry.record));
                case 'settings':
                  unawaited(_mcpForm(entry.connection));
                case 'remove':
                  unawaited(_remove(entry));
              }
            },
            itemBuilder: (_) => [
              _menuItem('detail', '查看详情', 'info'),
              if (entry.editable)
                _menuItem(
                  'edit',
                  entry.kind == ExtensionKind.plugin ? '编辑插件' : '编辑技能',
                  'edit',
                ),
              if (entry.connection != null)
                _menuItem('settings', '连接设置', 'gear'),
              _menuItem(
                'remove',
                entry.connection == null ? '移除' : '移除连接',
                'trash-danger',
              ),
            ],
          ),
      ],
    ),
  );
  Widget _grid(List<_MarketEntry> entries) => _searchPending
      ? marketSkeleton()
      : entries.isEmpty
      ? marketEmpty(
          '没有找到相关内容',
          '试试更短的名称或用途关键词。',
          action: _searchQuery.isNotEmpty ? '清除搜索' : null,
          onAction: _clearSearch,
        )
      : MarketGrid(children: entries.map(_row).toList());

  void _clearSearch() {
    _searchFocus.unfocus(disposition: UnfocusDisposition.scope);
    _search.clear();
  }

  Widget _publicContent() {
    if (_loadingSkills) return marketSkeleton();
    if (_skillsError != null) return marketError(_skillsError!, _reloadSkills);
    if (_kind == ExtensionKind.plugin && _loadingCatalog || _searchPending) {
      return marketSkeleton();
    }
    if (_kind == ExtensionKind.plugin && _catalogError != null) {
      return marketError(_catalogError!, _reloadCatalog);
    }
    final entries = _matching(_publicEntries);
    if (_searchQuery.isNotEmpty) return _grid(entries);
    return entries.isEmpty
        ? Padding(
            padding: const EdgeInsets.only(top: 100),
            child: marketEmpty('暂无推荐$_label', '推荐内容将在这里展示。'),
          )
        : _grid(entries);
  }

  List<CapabilityDraft> get _matchingDrafts => _authoringDrafts
      .where(
        (d) =>
            d.kind ==
            (_kind == ExtensionKind.skill
                ? CapabilityKind.skill
                : CapabilityKind.plugin),
      )
      .where(
        (d) =>
            _searchQuery.isEmpty ||
            '${d.presentation['title'] ?? d.name} ${d.description}'
                .toLowerCase()
                .contains(_searchQuery.toLowerCase()),
      )
      .toList();

  Widget _draftList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_matchingDrafts.isNotEmpty) marketSection('${_label}草稿'),
      for (final draft in _matchingDrafts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SkillPresentationIcon(draft.presentation, size: 44),
          title: Text(
            (draft.presentation['title']?.toString().trim().isNotEmpty == true
                    ? draft.presentation['title']
                    : draft.name.isNotEmpty
                    ? draft.name
                    : '未命名$_label')
                .toString(),
          ),
          subtitle: const Text('草稿 · 点击继续编辑'),
          trailing: marketIcon('caret-right', size: 18),
          onTap: () => _edit(draft: draft),
        ),
    ],
  );

  Widget _searchResults() {
    if (_searchPending) return marketSkeleton();
    if (!_personal) return _publicContent();
    if (_loading || _kind == ExtensionKind.plugin && _loadingMcp) {
      return marketSkeleton();
    }
    final entries = _matching(_personalEntries);
    if (entries.isEmpty &&
        (_error != null ||
            _kind == ExtensionKind.plugin && _mcpError != null)) {
      // The existing error banners above include the matching retry action.
      return const SizedBox.shrink();
    }
    if (_kind == ExtensionKind.skill && _matchingDrafts.isNotEmpty) {
      return Column(
        children: [if (entries.isNotEmpty) _grid(entries), _draftList()],
      );
    }
    return _grid(entries);
  }

  Widget _searchField() => TextField(
    controller: _search,
    focusNode: _searchFocus,
    autofocus: false,
    onTapOutside: (_) =>
        _searchFocus.unfocus(disposition: UnfocusDisposition.scope),
    decoration: InputDecoration(
      hintText: _listTitle == null
          ? _personal
                ? '搜索我的$_label'
                : '搜索名称或用途'
          : '搜索$_label',
      prefixIcon: Padding(
        padding: const EdgeInsets.all(14),
        child: marketIcon('search-light'),
      ),
      suffixIcon: _search.text.isEmpty
          ? null
          : IconButton(
              tooltip: '清除搜索',
              onPressed: _clearSearch,
              icon: marketIcon('close', size: 17),
            ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(99)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(99),
        borderSide: const BorderSide(color: Color(0xFFD9D9D9)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(99),
        borderSide: const BorderSide(color: Color(0xFF888888), width: 2),
      ),
    ),
  );

  double get _segmentScale => (MediaQuery.textScalerOf(context).scale(17) / 17)
      .clamp(1.0, double.infinity)
      .toDouble();

  Widget _segmentedSwitch({
    required List<String> labels,
    required int selectedIndex,
    required ValueChanged<int> onSelected,
    required double width,
  }) => SizedBox(
    width: width * _segmentScale,
    height: 48 * _segmentScale,
    child: Stack(
      fit: StackFit.expand,
      children: [
        SvgPicture.asset(
          'assets/icons/extensions/market_segment_track.svg',
          fit: BoxFit.fill,
          excludeFromSemantics: true,
        ),
        // Keep one loaded asset; selection changes only its layout position.
        Align(
          alignment: selectedIndex == 0
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: .5,
            heightFactor: 1,
            child: SvgPicture.asset(
              'assets/icons/extensions/market_segment_selected.svg',
              fit: BoxFit.fill,
              excludeFromSemantics: true,
            ),
          ),
        ),
        Row(
          children: [
            for (var index = 0; index < labels.length; index++)
              Expanded(
                child: Semantics(
                  selected: selectedIndex == index,
                  child: TextButton(
                    onPressed: () => onSelected(index),
                    style:
                        TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: selectedIndex == index
                              ? marketInk
                              : marketMuted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: TextStyle(
                            fontSize: 17,
                            fontWeight: selectedIndex == index
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                          animationDuration: Duration.zero,
                          splashFactory: NoSplash.splashFactory,
                        ).copyWith(
                          overlayColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.pressed)
                                ? Colors.transparent
                                : null,
                          ),
                        ),
                    child: Center(child: Text(labels[index])),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _kindSwitch() => _segmentedSwitch(
    labels: const ['插件', '技能'],
    selectedIndex: _kind == ExtensionKind.plugin ? 0 : 1,
    width: 180,
    onSelected: (index) {
      final kind = index == 0 ? ExtensionKind.plugin : ExtensionKind.skill;
      if (_kind == kind) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _kind = kind;
        _personal = false;
        _category = '推荐';
        _search.clear();
      });
    },
  );

  Widget _visibilitySwitch() => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _segmentedSwitch(
        labels: const ['公开', '个人'],
        selectedIndex: _personal ? 1 : 0,
        width: 208,
        onSelected: (index) => setState(() => _personal = index == 1),
      ),
      if (_kind == ExtensionKind.plugin &&
          MediaQuery.sizeOf(context).width <= 500)
        _settingsButton(),
    ],
  );

  Widget _categoryPill(String label) {
    final selected = _category == label;
    return Semantics(
      selected: selected,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Both assets stay mounted so selection updates immediately.
          Positioned.fill(
            top: 4,
            bottom: 4,
            child: SvgPicture.asset(
              'assets/icons/extensions/market_category.svg',
              fit: BoxFit.fill,
              excludeFromSemantics: true,
            ),
          ),
          Positioned.fill(
            top: 4,
            bottom: 4,
            child: Opacity(
              opacity: selected ? 1 : 0,
              child: SvgPicture.asset(
                'assets/icons/extensions/market_category_selected.svg',
                fit: BoxFit.fill,
                excludeFromSemantics: true,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _category = label),
            style:
                TextButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: selected
                      ? const Color(0xFF0069D9)
                      : marketInk,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  textStyle: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                  animationDuration: Duration.zero,
                  splashFactory: NoSplash.splashFactory,
                ).copyWith(
                  overlayColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.pressed)
                        ? Colors.transparent
                        : null,
                  ),
                ),
            child: Text(label),
          ),
        ],
      ),
    );
  }

  Widget _categoryStrip() => SingleChildScrollView(
    key: ValueKey(_kind),
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final category in _categories)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _categoryPill(category),
          ),
      ],
    ),
  );

  Widget _settingsButton() => IconButton(
    tooltip: '管理连接',
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    style: ButtonStyle(
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.pressed) ? Colors.transparent : null,
      ),
    ),
    onPressed: () => _showList('连接管理'),
    icon: marketIcon('gear'),
  );

  Widget _topBar() {
    final compact = MediaQuery.sizeOf(context).width <= 500;
    final showGear = _kind == ExtensionKind.plugin && !compact;
    final addWidth = MediaQuery.textScalerOf(context).scale(15) * 2 + 34;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [if (showGear) _settingsButton(), _addMenu()],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionsWidth = addWidth + (showGear ? 48 : 0);
        final centeredSwitchWidth =
            constraints.maxWidth - (actionsWidth + 8) * 2;
        final switchWidth = 180 * _segmentScale;
        final barHeight = 56 * _segmentScale;
        if (centeredSwitchWidth < switchWidth) {
          return SizedBox(
            height: barHeight * 2,
            child: Column(
              children: [
                SizedBox(
                  height: barHeight,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: actions,
                  ),
                ),
                SizedBox(
                  height: barHeight,
                  child: Center(child: _kindSwitch()),
                ),
              ],
            ),
          );
        }
        return SizedBox(
          height: barHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Center(child: _kindSwitch()),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: marketTheme(context),
    child: PopScope(
      canPop: _listTitle == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop)
          setState(() {
            _listTitle = null;
            _search.clear();
          });
      },
      child: MarketFrame(
        children: [
          if (_listTitle == '连接管理')
            Stack(
              alignment: Alignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 100, vertical: 10),
                  child: Text(
                    '连接管理',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
                Align(alignment: Alignment.centerRight, child: _addMenu()),
              ],
            )
          else if (_listTitle == null)
            _topBar()
          else
            Row(
              children: [
                marketButton(
                  _label,
                  () => setState(() {
                    _listTitle = null;
                    _search.clear();
                  }),
                  outlined: false,
                  fontSize: 17,
                ),
                marketIcon('caret-right', size: 16, color: marketMuted),
                Expanded(child: Text(_listTitle!)),
                _addMenu(),
              ],
            ),
          if (_listTitle == '连接管理')
            const Padding(
              padding: EdgeInsets.only(top: 30, bottom: 24),
              child: Text(
                '查看和管理已连接的 MCP 服务器。',
                style: TextStyle(
                  fontSize: 17,
                  color: marketMuted,
                  height: 1.55,
                ),
              ),
            )
          else
            marketHeading(
              _listTitle ?? _label,
              subtitle: _listTitle == '已安装'
                  ? '管理从市场安装的$_label'
                  : _listTitle == '推荐'
                  ? '精选实用且值得关注的$_label。'
                  : _kind == ExtensionKind.plugin
                  ? '连接你的工具，让小七与你协同工作'
                  : '用于扩展小七能力的说明与工作方法',
            ),
          if (_listTitle == null) ...[
            _visibilitySwitch(),
            const SizedBox(height: 18),
          ],
          _searchField(),
          if (_listTitle == null &&
              !_personal &&
              _search.text.trim().isEmpty) ...[
            const SizedBox(height: 14),
            _categoryStrip(),
          ],
          if (_error != null) marketError(_error!, _reload),
          if (_kind == ExtensionKind.plugin && _mcpError != null)
            marketError(_mcpError!, _reloadMcp),
          if (_listTitle != null) ...[
            const SizedBox(height: 24),
            if (_listTitle == '连接管理') ...[
              marketButton('添加连接', () => _mcpForm(), icon: 'plus'),
              if (_loadingMcp)
                marketSkeleton()
              else
                _grid(
                  _matching(_entries.where((e) => e.kind == ExtensionKind.mcp)),
                ),
            ] else if (_listTitle == '推荐')
              _publicContent()
            else if (_loading || _kind == ExtensionKind.plugin && _loadingMcp)
              marketSkeleton()
            else if (_installed.isEmpty)
              marketEmpty(
                '还没有安装$_label',
                '从市场安装的$_label将在这里展示。',
                action: '查看推荐',
                onAction: () => _showList('推荐'),
              )
            else
              _grid(_matching(_installed)),
          ] else if (_search.text.trim().isNotEmpty) ...[
            marketSection('搜索结果'),
            _searchResults(),
          ] else ...[
            if (_installed.isNotEmpty) ...[
              marketSection('已安装', onTap: () => _showList('已安装')),
              if (_loading || _kind == ExtensionKind.plugin && _loadingMcp)
                marketSkeleton()
              else if (_kind == ExtensionKind.skill)
                _grid(_installed)
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _installed
                        .map(
                          (e) => Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Tooltip(
                              message: e.name,
                              child: InkWell(
                                onTap: () => _open(e),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: e.presentation.isNotEmpty
                                      ? SkillPresentationIcon(
                                          e.presentation,
                                          size: 40,
                                        )
                                      : MarketBrand(e.asset),
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
            if (_personal) ...[
              marketSection('个人$_label'),
              if (_loading || _kind == ExtensionKind.plugin && _loadingMcp)
                marketSkeleton()
              else if (_personalEntries.isEmpty)
                marketEmpty('暂无个人$_label', '你导入或创建的$_label将在这里展示。')
              else
                _grid(_personalEntries),
              if (_kind == ExtensionKind.skill) _draftList(),
            ] else ...[
              _publicContent(),
            ],
          ],
        ],
      ),
    ),
  );
}
