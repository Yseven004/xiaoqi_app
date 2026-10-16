import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/app_toast.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../features/capabilities/data/capability_models.dart';

enum ExtensionKind { skill, plugin, mcp }

enum ExtensionFilter { curated, installed, created }

class ExtensionFeatureBlock {
  const ExtensionFeatureBlock({
    required this.title,
    required this.description,
    required this.illustration,
    this.large = false,
  });

  final String title;
  final String description;
  final String illustration;
  final bool large;
}

class ExtensionEntry {
  const ExtensionEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.author,
    required this.description,
    required this.iconAsset,
    required this.iconBackground,
    required this.authorBio,
    required this.suitableFor,
    required this.features,
    required this.examples,
    this.version = '1.0.0',
    this.repository = 'xiaoqi/paper-reader',
    this.importUrl,
    this.installation,
  });

  final String id;
  final ExtensionKind kind;
  final String name;
  final String author;
  final String description;
  final String iconAsset;
  final Color iconBackground;
  final String authorBio;
  final String suitableFor;
  final List<ExtensionFeatureBlock> features;
  final List<String> examples;
  final String version;
  final String repository;
  final String? importUrl;
  final CapabilityRecord? installation;

  bool get isTrialCandidate => importUrl != null;

  factory ExtensionEntry.installed(CapabilityRecord r) => ExtensionEntry(
    id: r.id,
    kind: r.kind == CapabilityKind.skill
        ? ExtensionKind.skill
        : ExtensionKind.plugin,
    name: r.name,
    author:
        r.source['source_url']?.toString().split('/').elementAtOrNull(3) ??
        '我的技能',
    description: r.description,
    iconAsset: 'assets/icons/capabilities/capability_skill_book.svg',
    iconBackground: const Color(0xFFEFF6FF),
    authorBio: '从公开仓库导入，作者信息以仓库为准。',
    suitableFor: '在对话中选择后按需使用；实际效果需运行验证',
    features: const [],
    examples: [r.description],
    version: r.currentVersionId.substring(
      0,
      r.currentVersionId.length.clamp(0, 12),
    ),
    repository:
        r.source['source_url']?.toString().replaceFirst(
          'https://github.com/',
          '',
        ) ??
        '',
    installation: r,
  );

  String get kindLabel => switch (kind) {
    ExtensionKind.skill => '技能',
    ExtensionKind.plugin => '插件',
    ExtensionKind.mcp => 'MCP',
  };
}

class _CollectionCard {
  const _CollectionCard({
    required this.title,
    required this.subtitle,
    required this.asset,
    required this.background,
  });

  final String title;
  final String subtitle;
  final String asset;
  final Color background;
}

const _collectionCards = [
  _CollectionCard(
    title: '高效阅读与学习',
    subtitle: '精读、摘要与知识整理',
    asset: 'assets/icons/extensions/collection_reading.svg',
    background: Color(0xFFFFF8E8),
  ),
  _CollectionCard(
    title: '创作与表达',
    subtitle: '写作、翻译与演示',
    asset: 'assets/icons/extensions/collection_writing.svg',
    background: Color(0xFFEFF6FF),
  ),
  _CollectionCard(
    title: '研究与探索',
    subtitle: '检索、分析与思维拓展',
    asset: 'assets/icons/extensions/collection_research.svg',
    background: Color(0xFFEFF7F0),
  ),
  _CollectionCard(
    title: '整理你的工作流',
    subtitle: '把零散内容变成行动',
    asset: 'assets/icons/extensions/collection_reading.svg',
    background: Color(0xFFF6F1FF),
  ),
  _CollectionCard(
    title: '开发与效率',
    subtitle: '让重复操作交给智能体',
    asset: 'assets/icons/extensions/collection_writing.svg',
    background: Color(0xFFF1F7F7),
  ),
];

const _quickReadFeatures = [
  ExtensionFeatureBlock(
    title: '快速精读',
    description: '先看懂论文讲什么，快速掌握研究背景、方法与结论。',
    illustration: 'assets/icons/extensions/detail_quick_read.svg',
    large: true,
  ),
  ExtensionFeatureBlock(
    title: '重点解读',
    description: '解释术语与难点，帮你理解关键论证。',
    illustration: 'assets/icons/extensions/detail_explain.svg',
  ),
  ExtensionFeatureBlock(
    title: '思维导图',
    description: '把主要观点和关系整理成清晰结构。',
    illustration: 'assets/icons/extensions/detail_mind_map.svg',
  ),
];

const _curatedExtensions = [
  ExtensionEntry(
    id: 'paper-reader',
    kind: ExtensionKind.skill,
    name: '论文精读',
    author: '小七官方',
    description: '快速读懂论文并整理重点',
    iconAsset: 'assets/icons/capabilities/capability_skill_book.svg',
    iconBackground: Color(0xFFFFF7E8),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: 'PDF、网页、文档',
    features: _quickReadFeatures,
    examples: ['请帮我精读这篇论文，并整理出重点。', '解释这篇论文最难理解的部分，并生成思维导图。'],
  ),
  ExtensionEntry(
    id: 'web-organizer',
    kind: ExtensionKind.skill,
    name: '网页整理',
    author: '小七官方',
    description: '提取正文并生成摘要笔记',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFEFF6FF),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '网页、文章、资料',
    features: _quickReadFeatures,
    examples: ['整理这个网页的主要观点，并保留关键来源。'],
  ),
  ExtensionEntry(
    id: 'weekly-review',
    kind: ExtensionKind.skill,
    name: '学习周报',
    author: '小七官方',
    description: '汇总阅读记录与下一步计划',
    iconAsset: 'assets/icons/capabilities/description.svg',
    iconBackground: Color(0xFFEFF9F1),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '笔记、对话、任务',
    features: _quickReadFeatures,
    examples: ['根据本周的阅读记录，帮我生成周报和下周计划。'],
  ),
  ExtensionEntry(
    id: 'full-translation',
    kind: ExtensionKind.skill,
    name: '全文翻译',
    author: 'DeepL',
    description: '保持语境的多语言文档翻译',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFFFF7E8),
    authorBio: 'DeepL 提供保持语境与语气的多语言翻译能力。',
    suitableFor: '网页、文档、对话',
    features: _quickReadFeatures,
    examples: ['将这份文档翻译成中文，并保留原有标题层级。'],
    repository: 'DeepL/extension',
  ),
  ExtensionEntry(
    id: 'knowledge-card',
    kind: ExtensionKind.skill,
    name: '知识卡片',
    author: '小七官方',
    description: '把关键概念整理成复习卡片',
    iconAsset: 'assets/icons/capabilities/help_outline.svg',
    iconBackground: Color(0xFFEFF6FB),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '文字、书籍、课堂资料',
    features: _quickReadFeatures,
    examples: ['把这段内容整理成适合复习的知识卡片。'],
  ),
  ExtensionEntry(
    id: 'mind-map',
    kind: ExtensionKind.skill,
    name: '思维导图',
    author: '小七官方',
    description: '把内容关系整理成结构图',
    iconAsset: 'assets/icons/capabilities/mcp_connector.svg',
    iconBackground: Color(0xFFEFF9F1),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '文字、会议、研究资料',
    features: _quickReadFeatures,
    examples: ['把这篇文章的核心观点整理成思维导图。'],
  ),
  ExtensionEntry(
    id: 'ppt-outline',
    kind: ExtensionKind.skill,
    name: 'PPT 大纲',
    author: '小七官方',
    description: '根据文档生成清晰演示结构',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFFFF7E8),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '文档、提纲、研究材料',
    features: _quickReadFeatures,
    examples: ['根据这份文档生成一份 10 页的演示大纲。'],
  ),
  ExtensionEntry(
    id: 'literature-search',
    kind: ExtensionKind.skill,
    name: '文献检索',
    author: '知网',
    description: '查找文献并整理引用信息',
    iconAsset: 'assets/icons/capabilities/web_search.svg',
    iconBackground: Color(0xFFEFF6FF),
    authorBio: '知网提供面向研究工作的文献检索与引用整理能力。',
    suitableFor: '研究主题、论文、引用',
    features: _quickReadFeatures,
    examples: ['帮我查找这个主题近五年的高质量文献，并整理引用。'],
    repository: 'cnki/extension',
  ),
];

const _pluginExtensions = [
  ExtensionEntry(
    id: 'paper-reader-plugin',
    kind: ExtensionKind.plugin,
    name: '论文精读工作台',
    author: '小七官方',
    description: '在会话中组合阅读、标注与摘要工具',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFEFF6FF),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: 'PDF、网页、文档',
    features: _quickReadFeatures,
    examples: ['打开论文工作台，帮我边读边整理重点。'],
    repository: 'xiaoqi/paper-reader-plugin',
  ),
  ExtensionEntry(
    id: 'writing-plugin',
    kind: ExtensionKind.plugin,
    name: '创作工作台',
    author: '小七官方',
    description: '把草稿、翻译和演示组织在一个工作流里',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFFFF7E8),
    authorBio: '小七官方为创作、学习与研究提供可靠的智能工具。',
    suitableFor: '文档、草稿、演示',
    features: _quickReadFeatures,
    examples: ['把这份草稿整理成可演示的内容结构。'],
    repository: 'xiaoqi/writing-workbench',
  ),
];

// These are real public repositories selected for manual end-to-end testing.
// They are intentionally not presented as installed marketplace entries: the
// user still has to inspect and install the fixed commit through the server.
const _trialExtensions = [
  ExtensionEntry(
    id: 'trial-paper-lookup',
    kind: ExtensionKind.skill,
    name: '论文检索',
    author: 'K-Dense',
    description: '从多个学术数据库查论文、DOI、摘要和开放获取全文，并保留来源。',
    iconAsset: 'assets/icons/capabilities/web_search.svg',
    iconBackground: Color(0xFFEFF6FF),
    authorBio: 'K-Dense Scientific Agent Skills 中的研究检索技能。',
    suitableFor: '论文、课程作业、研究主题',
    features: _quickReadFeatures,
    examples: ['请检索近五年关于主动学习的论文，列出标题、年份、DOI 和可公开获取的全文链接。'],
    version: '2.4',
    repository:
        'K-Dense-AI/scientific-agent-skills/tree/main/skills/paper-lookup',
    importUrl:
        'https://github.com/K-Dense-AI/scientific-agent-skills/tree/main/skills/paper-lookup',
  ),
  ExtensionEntry(
    id: 'trial-literature-review',
    kind: ExtensionKind.skill,
    name: '文献综述',
    author: 'K-Dense',
    description: '按系统综述、范围综述或叙述综述流程整理研究问题、检索和证据边界。',
    iconAsset: 'assets/icons/capabilities/help_outline.svg',
    iconBackground: Color(0xFFFFF8E8),
    authorBio: 'K-Dense Scientific Agent Skills 中的文献综述技能。',
    suitableFor: '课程论文、研究综述、选题调研',
    features: _quickReadFeatures,
    examples: ['请围绕“生成式 AI 对学习效果的影响”设计一个可复核的文献综述检索和筛选方案。'],
    version: '1.11',
    repository:
        'K-Dense-AI/scientific-agent-skills/tree/main/skills/literature-review',
    importUrl:
        'https://github.com/K-Dense-AI/scientific-agent-skills/tree/main/skills/literature-review',
  ),
  ExtensionEntry(
    id: 'trial-scientific-agent-skills',
    kind: ExtensionKind.plugin,
    name: 'Scientific Agent Skills',
    author: 'K-Dense',
    description: '一套面向科研和学习的技能插件，包含论文检索、文献综述、科学写作和数据分析。',
    iconAsset: 'assets/icons/capabilities/capability_plugin_document.svg',
    iconBackground: Color(0xFFEFF9F1),
    authorBio: 'K-Dense 的开源科学研究 Agent Skills 插件集合。',
    suitableFor: '论文阅读、课程学习、科研分析',
    features: _quickReadFeatures,
    examples: ['请先使用可用的研究技能，帮我把“如何提升大学生的主动学习能力”拆成检索、比较和总结步骤。'],
    version: '2.72.0',
    repository: 'K-Dense-AI/scientific-agent-skills',
    importUrl: 'https://github.com/K-Dense-AI/scientific-agent-skills',
  ),
  ExtensionEntry(
    id: 'trial-scientific-writing',
    kind: ExtensionKind.skill,
    name: '科学写作',
    author: 'K-Dense',
    description: '把学习或研究材料整理成有证据边界、结构清晰的学术表达。',
    iconAsset: 'assets/icons/capabilities/description.svg',
    iconBackground: Color(0xFFEFF9F1),
    authorBio: 'K-Dense Scientific Agent Skills 中的科学写作技能。',
    suitableFor: '读书笔记、课程论文、研究摘要',
    features: _quickReadFeatures,
    examples: ['请根据下面的学习笔记，整理出研究问题、主要论点、证据和仍需核实的部分。'],
    version: 'GitHub main',
    repository:
        'K-Dense-AI/scientific-agent-skills/tree/main/skills/scientific-writing',
    importUrl:
        'https://github.com/K-Dense-AI/scientific-agent-skills/tree/main/skills/scientific-writing',
  ),
];

List<ExtensionEntry> _entriesFor(ExtensionKind kind) => switch (kind) {
  ExtensionKind.skill => [
    ..._curatedExtensions,
    ..._trialExtensions.where((entry) => entry.kind == ExtensionKind.skill),
  ],
  ExtensionKind.plugin => [
    ..._pluginExtensions,
    ..._trialExtensions.where((entry) => entry.kind == ExtensionKind.plugin),
  ],
  ExtensionKind.mcp => const [],
};

class ExtensionMarketPage extends StatefulWidget {
  const ExtensionMarketPage({
    this.initialKind = ExtensionKind.skill,
    super.key,
  });

  final ExtensionKind initialKind;

  @override
  State<ExtensionMarketPage> createState() => _ExtensionMarketPageState();
}

class _ExtensionMarketPageState extends State<ExtensionMarketPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _carouselController = PageController();
  final Set<String> _installedIds = {};
  List<ExtensionEntry> _remoteEntries = [];
  List<McpConnectionRecord> _mcpConnections = const [];
  final Set<String> _testingMcpIds = {};
  final Map<String, int> _mcpToolCounts = {};
  bool _loadingMcpConnections = false;
  String? _mcpLoadError;
  String? _loadError;
  Timer? _carouselTimer;
  Timer? _resumeCarouselTimer;
  int _carouselIndex = 0;
  String _query = '';
  ExtensionKind _kind = ExtensionKind.skill;
  ExtensionFilter _filter = ExtensionFilter.curated;
  bool _carouselStarted = false;

  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind;
    _searchController.addListener(_handleSearchChanged);
    unawaited(_restoreInstalled());
    unawaited(_restoreMcpConnections());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_carouselStarted ||
        MediaQuery.maybeOf(context)?.disableAnimations == true) {
      return;
    }
    _carouselStarted = true;
    _carouselTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_carouselController.hasClients) return;
      final next = (_carouselIndex + 1) % _collectionCards.length;
      _carouselController.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _resumeCarouselTimer?.cancel();
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _carouselController.dispose();
    super.dispose();
  }

  Future<void> _restoreInstalled() async {
    try {
      final records = await CapabilityCloudSync.instance
          .installedCapabilities();
      if (!mounted) return;
      setState(() {
        _remoteEntries = records.map(ExtensionEntry.installed).toList();
        _installedIds
          ..clear()
          ..addAll(records.map((r) => r.id));
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = '加载安装记录失败：$e');
    }
  }

  Future<void> _restoreMcpConnections() async {
    setStateIfMounted(() => _loadingMcpConnections = true);
    try {
      final items = await CapabilityCloudSync.instance.listMcpConnections();
      if (!mounted) return;
      setState(() {
        _mcpConnections = items;
        _mcpLoadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _mcpLoadError = '加载 MCP 连接器失败：$error');
    } finally {
      if (mounted) setState(() => _loadingMcpConnections = false);
    }
  }

  void setStateIfMounted(VoidCallback update) {
    if (mounted) setState(update);
  }

  Future<void> _testMcpConnection(McpConnectionRecord connection) async {
    setState(() => _testingMcpIds.add(connection.id));
    try {
      final result = await CapabilityCloudSync.instance.testMcpConnection(
        connection.id,
      );
      final count = (result['tool_count'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() => _mcpToolCounts[connection.id] = count);
      AppToast.show(context, '连接成功，发现 $count 个可用工具');
    } catch (error) {
      if (mounted) AppToast.show(context, '连接失败：$error');
    } finally {
      if (mounted) setState(() => _testingMcpIds.remove(connection.id));
    }
  }

  Future<void> _deleteMcpConnection(McpConnectionRecord connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除连接器？'),
        content: Text('删除“${connection.name}”后，它不会再出现在聊天入口中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await CapabilityCloudSync.instance.deleteMcpConnection(connection.id);
      await _restoreMcpConnections();
      if (mounted) AppToast.show(context, '连接器已删除');
    } catch (error) {
      if (mounted) AppToast.show(context, '删除失败：$error');
    }
  }

  void _handleSearchChanged() {
    setState(() => _query = _searchController.text.trim().toLowerCase());
  }

  void _applyInstalledChange(String id, bool installed) {
    unawaited(_restoreInstalled());
  }

  void _toggleInstalled(ExtensionEntry entry) {
    if (entry.isTrialCandidate) {
      unawaited(_showImportDialog(initialUrl: entry.importUrl));
      return;
    }
    _openDetail(entry);
  }

  bool _isInstalled(ExtensionEntry entry) =>
      _installedIds.contains(entry.id) || _installationFor(entry) != null;

  List<ExtensionEntry> _visibleEntries() {
    final entries = _kind == ExtensionKind.mcp
        ? <ExtensionEntry>[]
        : _filter == ExtensionFilter.installed
        ? _remoteEntries.where((e) => e.kind == _kind).toList()
        : _entriesFor(_kind);
    if (_filter == ExtensionFilter.created) return const [];
    return entries
        .where((entry) {
          final matchesQuery =
              _query.isEmpty ||
              '${entry.name} ${entry.author} ${entry.description}'
                  .toLowerCase()
                  .contains(_query);
          final matchesFilter =
              _filter != ExtensionFilter.installed ||
              _installedIds.contains(entry.id);
          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  void _openDetail(ExtensionEntry entry) {
    final installed = _installationFor(entry);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionDetailPage(
          entry: installed == null
              ? entry
              : ExtensionEntry.installed(installed),
          installed: installed != null || _installedIds.contains(entry.id),
          onInstallChanged: (installed) {
            _applyInstalledChange(entry.id, installed);
          },
        ),
      ),
    );
  }

  CapabilityRecord? _installationFor(ExtensionEntry entry) {
    if (entry.installation != null) return entry.installation;
    if (_installedIds.contains(entry.id)) return null;
    final requestedUrl = entry.importUrl;
    if (requestedUrl == null) return null;
    for (final record in _remoteEntries) {
      final installation = record.installation;
      if (installation == null) continue;
      final sourceUrl =
          installation.source['requested_url']?.toString() ??
          installation.source['source_url']?.toString() ??
          '';
      if (sourceUrl == requestedUrl ||
          sourceUrl.startsWith(requestedUrl) ||
          requestedUrl.startsWith(sourceUrl)) {
        return installation;
      }
    }
    return null;
  }

  void _openCategory(String title, List<ExtensionEntry> entries) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionCategoryPage(
          title: title,
          entries: entries,
          installedIds: _installedIds,
          onChanged: _handleCategoryInstalledChanged,
        ),
      ),
    );
  }

  void _handleCategoryInstalledChanged() {
    unawaited(_restoreInstalled());
  }

  Future<void> _showCreateImportSheet() async {
    if (_kind == ExtensionKind.mcp) {
      await _showMcpConnectionDialog();
      return;
    }
    ModalRoute<dynamic>? sheetRoute;
    final action = await showModalBottomSheet<_MarketAction>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (sheetContext) {
        sheetRoute ??= ModalRoute.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  '创建或导入扩展',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('V1 支持创建技能，或从公开 GitHub 仓库导入。'),
              ),
              ListTile(
                leading: _assetIcon(
                  'assets/icons/extensions/market_plus.svg',
                  26,
                ),
                title: const Text('创建技能'),
                subtitle: const Text('从聊天中整理成可重复调用的技能'),
                onTap: () => Navigator.pop(sheetContext, _MarketAction.create),
              ),
              ListTile(
                leading: _assetIcon(
                  'assets/icons/extensions/github_mark.svg',
                  26,
                ),
                title: const Text('从公开 GitHub 导入'),
                subtitle: const Text('导入前会先检查清单、来源和安全性'),
                onTap: () => Navigator.pop(sheetContext, _MarketAction.import),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    await sheetRoute?.completed;
    if (!mounted || action == null) return;
    if (action == _MarketAction.create) {
      AppToast.show(context, '创建技能将从当前会话继续');
      return;
    }
    await _showImportDialog();
  }

  Future<void> _showImportDialog({String? initialUrl}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ImportInstallationDialog(initialUrl: initialUrl),
    );
    await _restoreInstalled();
    if (mounted) setState(() => _filter = ExtensionFilter.installed);
  }

  Future<void> _showMcpConnectionDialog({
    McpConnectionRecord? connection,
  }) async {
    final pageContext = context;
    final name = TextEditingController(text: connection?.name ?? '');
    final url = TextEditingController(text: connection?.url ?? '');
    final bearerToken = TextEditingController();
    String? savedId = connection?.id;
    var saving = false;
    String? errorText;
    int? discoveredTools;
    try {
      await showDialog<void>(
        context: pageContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit({required bool test}) async {
              if (saving) return;
              setDialogState(() {
                saving = true;
                errorText = null;
                discoveredTools = null;
              });
              try {
                final saved = await CapabilityCloudSync.instance
                    .saveMcpConnection(
                      id: savedId,
                      name: name.text,
                      url: url.text,
                      bearerToken: bearerToken.text,
                    );
                savedId = saved.id;
                if (test) {
                  final result = await CapabilityCloudSync.instance
                      .testMcpConnection(saved.id);
                  discoveredTools =
                      (result['tool_count'] as num?)?.toInt() ?? 0;
                }
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                await _restoreMcpConnections();
                if (pageContext.mounted) {
                  AppToast.show(
                    pageContext,
                    test
                        ? '已保存并连接，发现 ${discoveredTools ?? 0} 个可用工具'
                        : 'MCP 连接器已保存',
                  );
                }
              } catch (error) {
                if (dialogContext.mounted) {
                  setDialogState(() => errorText = error.toString());
                }
              } finally {
                if (dialogContext.mounted) {
                  setDialogState(() => saving = false);
                }
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFFFFFCF8),
              title: Text(connection == null ? '添加 MCP 连接器' : '编辑 MCP 连接器'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '连接一个可从服务器访问的 HTTPS MCP 服务。保存的令牌会加密保管；每次调用工具前都会请你确认。',
                        style: TextStyle(height: 1.45),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: '连接器名称',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'MCP 服务地址',
                          hintText: 'https://example.com/mcp',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: saving
                              ? null
                              : () {
                                  name.text = 'GitHub';
                                  url.text =
                                      'https://api.githubcopilot.com/mcp/';
                                },
                          icon: const Icon(Icons.code, size: 18),
                          label: const Text('填入 GitHub MCP 地址'),
                        ),
                      ),
                      TextField(
                        controller: bearerToken,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: connection?.hasBearerToken == true
                              ? 'Bearer 令牌（留空表示不更换）'
                              : 'Bearer 令牌（可选）',
                          helperText: 'GitHub 当前可使用个人访问令牌；此入口暂不提供浏览器 OAuth 登录。',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          errorText!,
                          style: const TextStyle(color: Color(0xFFB3261E)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: saving ? null : () => submit(test: false),
                  child: const Text('只保存'),
                ),
                FilledButton(
                  onPressed: saving ? null : () => submit(test: true),
                  child: saving
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存并测试'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      name.dispose();
      url.dispose();
      bearerToken.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 640 ? 20.0 : 40.0;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 48),
            children: [
              _buildTopBar(),
              const SizedBox(height: 20),
              _buildSearchField(),
              const SizedBox(height: 28),
              _buildKindTabs(),
              const SizedBox(height: 22),
              if (_kind != ExtensionKind.mcp) _buildFilters(),
              if (_loadError != null)
                TextButton(
                  onPressed: _restoreInstalled,
                  child: Text('$_loadError · 重试'),
                ),
              const SizedBox(height: 38),
              if (_kind == ExtensionKind.mcp)
                _buildMcpConnections(constraints.maxWidth - horizontal * 2)
              else if (_filter == ExtensionFilter.created)
                _buildCreatedEmptyState()
              else ...[
                _buildCollections(),
                const SizedBox(height: 40),
                _buildCategorySection(
                  _filter == ExtensionFilter.installed ? '已安装' : '精选推荐',
                  _visibleEntries(),
                  constraints.maxWidth - horizontal * 2,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMcpConnections(double contentWidth) {
    final matches = _mcpConnections
        .where((connection) {
          return _query.isEmpty ||
              '${connection.name} ${connection.url}'.toLowerCase().contains(
                _query,
              );
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '已连接',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          '只连接服务器可访问的远程 MCP 服务。选中后才会在当前聊天中使用；每次调用工具前都会显示操作并等待确认。',
          style: TextStyle(color: Color(0xFF68707C), height: 1.45),
        ),
        const SizedBox(height: 20),
        if (_loadingMcpConnections)
          const Padding(padding: EdgeInsets.all(22), child: Text('正在读取连接器列表…'))
        else if (_mcpLoadError != null)
          TextButton.icon(
            onPressed: _restoreMcpConnections,
            icon: const Icon(Icons.refresh),
            label: Text('$_mcpLoadError · 重试'),
          )
        else if (matches.isEmpty)
          Container(
            width: contentWidth,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FB),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE6E9EE)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.link_outlined, size: 24),
                    SizedBox(width: 10),
                    Text(
                      '还没有连接器',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('添加远程服务地址，可选填 Bearer 令牌。'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _showCreateImportSheet,
                  icon: const Icon(Icons.add),
                  label: const Text('添加 MCP 连接器'),
                ),
              ],
            ),
          )
        else
          for (final connection in matches) ...[
            _McpConnectionTile(
              connection: connection,
              toolCount: _mcpToolCounts[connection.id],
              testing: _testingMcpIds.contains(connection.id),
              onTest: () => _testMcpConnection(connection),
              onEdit: () => _showMcpConnectionDialog(connection: connection),
              onDelete: () => _deleteMcpConnection(connection),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _marketButton(
          label: '返回扩展入口',
          asset: 'assets/icons/extensions/market_back.svg',
          onTap: () => Navigator.maybePop(context),
          size: 30,
          padding: 4,
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Text(
            '扩展市场',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Color(0xFF10131A),
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _showCreateImportSheet,
          icon: _assetIcon('assets/icons/extensions/market_plus.svg', 25),
          label: Text(_kind == ExtensionKind.mcp ? '添加连接器' : '创建/导入'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF10131A),
            side: const BorderSide(color: Color(0xFFD9DEE7), width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            textStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      textInputAction: TextInputAction.search,
      onTapOutside: (_) => _searchFocusNode.unfocus(),
      decoration: InputDecoration(
        hintText: '搜索技能、插件或 MCP，例如：论文精读、网页资料整理',
        hintStyle: const TextStyle(color: Color(0xFF66738D), fontSize: 18),
        prefixIcon: Padding(
          padding: const EdgeInsets.all(21),
          child: SvgPicture.asset('assets/icons/extensions/market_search.svg'),
        ),
        filled: true,
        fillColor: const Color(0xFFF3F5F8),
        contentPadding: const EdgeInsets.symmetric(vertical: 22, horizontal: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildKindTabs() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE4E8EE))),
      ),
      child: Row(
        children: [
          for (final kind in ExtensionKind.values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _kind = kind),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _kind == kind
                            ? const Color(0xFF10131A)
                            : Colors.transparent,
                        width: 4,
                      ),
                    ),
                  ),
                  child: Text(
                    switch (kind) {
                      ExtensionKind.skill => '技能',
                      ExtensionKind.plugin => '插件',
                      ExtensionKind.mcp => 'MCP',
                    },
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xFF10131A),
                      fontSize: 22,
                      fontWeight: _kind == kind
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _filterChip('精选', ExtensionFilter.curated),
          const SizedBox(width: 14),
          _filterChip('已安装', ExtensionFilter.installed),
          const SizedBox(width: 14),
          _filterChip('我创建的', ExtensionFilter.created),
        ],
      ),
    );
  }

  Widget _filterChip(String label, ExtensionFilter filter) {
    final selected = _filter == filter;
    return GestureDetector(
      onTap: () => setState(() => _filter = filter),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF16191F) : const Color(0xFFF2F4F7),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF16191F),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildCollections() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '精选合集',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 22),
        Listener(
          onPointerDown: (_) => _pauseCarousel(),
          onPointerUp: (_) => _resumeCarouselLater(),
          onPointerCancel: (_) => _resumeCarouselLater(),
          child: SizedBox(
            height: 220,
            child: PageView.builder(
              controller: _carouselController,
              itemCount: _collectionCards.length,
              onPageChanged: (index) {
                if (!mounted) return;
                setState(() => _carouselIndex = index);
              },
              itemBuilder: (context, index) {
                final card = _collectionCards[index];
                return _CollectionTile(card: card, selectedIndex: index);
              },
            ),
          ),
        ),
      ],
    );
  }

  void _pauseCarousel() {
    _carouselTimer?.cancel();
    _carouselTimer = null;
    _resumeCarouselTimer?.cancel();
    _resumeCarouselTimer = null;
  }

  void _resumeCarouselLater() {
    _resumeCarouselTimer?.cancel();
    _resumeCarouselTimer = Timer(const Duration(seconds: 8), () {
      _resumeCarouselTimer = null;
      if (!mounted || MediaQuery.maybeOf(context)?.disableAnimations == true) {
        return;
      }
      _carouselTimer?.cancel();
      _carouselTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || !_carouselController.hasClients) return;
        final next = (_carouselIndex + 1) % _collectionCards.length;
        _carouselController.animateToPage(
          next,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      });
    });
  }

  Widget _buildCategorySection(
    String title,
    List<ExtensionEntry> entries,
    double contentWidth,
  ) {
    final isEmpty = entries.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: isEmpty ? null : () => _openCategory(title, entries),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                SvgPicture.asset(
                  'assets/icons/extensions/market_arrow_right.svg',
                  width: 22,
                  height: 22,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        if (isEmpty)
          _buildNoResults()
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: entries.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: contentWidth < 680 ? 1 : 2,
              mainAxisExtent: 122,
              crossAxisSpacing: 16,
              mainAxisSpacing: 14,
            ),
            itemBuilder: (context, index) => _ExtensionCard(
              entry: entries[index],
              installed: _isInstalled(entries[index]),
              onOpen: () => _openDetail(entries[index]),
              onToggleInstall: () => _toggleInstalled(entries[index]),
            ),
          ),
      ],
    );
  }

  Widget _buildCreatedEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 92,
              height: 92,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E8),
                borderRadius: BorderRadius.circular(28),
              ),
              child: SvgPicture.asset(
                'assets/icons/capabilities/capability_skill_book.svg',
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '还没有创建的扩展',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              '你创建的技能会出现在这里。\n作者作品页在 V1 先保持空状态。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF737E91),
                fontSize: 17,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _showCreateImportSheet,
              child: const Text('创建技能'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResults() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 38),
      child: Center(
        child: Text(
          '没有找到匹配的扩展',
          style: TextStyle(color: Color(0xFF737E91), fontSize: 17),
        ),
      ),
    );
  }
}

enum _MarketAction { create, import }

class _ImportInstallationDialog extends StatefulWidget {
  const _ImportInstallationDialog({this.update, this.initialUrl});
  final CapabilityRecord? update;
  final String? initialUrl;
  @override
  State<_ImportInstallationDialog> createState() =>
      _ImportInstallationDialogState();
}

class _ImportInstallationDialogState extends State<_ImportInstallationDialog> {
  final _url = TextEditingController();
  Map<String, dynamic>? _inspection;
  bool _busy = false;
  String? _error;
  String _progress = '';
  String? _jobId;

  void _onJob(String id) {
    if (mounted) setState(() => _jobId = id);
  }

  Future<void> _cancel() async {
    if (!_busy) {
      Navigator.pop(context);
      return;
    }
    if (_jobId == null) return;
    setState(() => _progress = '正在取消，请等待服务器停止操作…');
    try {
      await CapabilityCloudSync.instance.cancelImportOperation(_jobId!);
    } catch (e) {
      if (mounted) setState(() => _error = '取消请求失败：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _url.text =
        widget.initialUrl ??
        widget.update?.source['requested_url']?.toString() ??
        '';
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _inspect() async {
    setState(() {
      _busy = true;
      _error = null;
      _inspection = null;
      _progress = '检查中：固定仓库版本、识别技能和不支持的组件…';
    });
    try {
      final result = await CapabilityCloudSync.instance.runImportOperation({
        'url': _url.text.trim(),
      }, onJob: _onJob);
      if (mounted) {
        setState(
          () => _inspection = Map<String, dynamic>.from(
            result['inspection'] as Map,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install(Map candidate) async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = '安装中：准备依赖、锁定版本；成功前不会显示为已安装。';
    });
    try {
      await CapabilityCloudSync.instance.runImportOperation(
        {
          'inspection_id': _inspection!['id'],
          'candidate_id': candidate['id'],
          if (widget.update != null) 'update_id': widget.update!.id,
          if (widget.update != null)
            'expected_revision': widget.update!.cloudRevision,
        },
        install: true,
        onJob: _onJob,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.update == null ? '从公开 GitHub 导入' : '检查并手动更新'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _url,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'GitHub 仓库或子目录链接',
                  hintText: 'https://github.com/owner/repository',
                ),
              ),
              const SizedBox(height: 16),
              const Text('只安装兼容的技能。MCP、hooks 和专有客户端能力不会执行。检查不等于实际调用成功。'),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_progress, semanticsLabel: _progress),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_inspection != null) ...[
                const SizedBox(height: 16),
                SelectableText('固定版本：${_inspection!['commit']}'),
                if ((_inspection!['candidates'] as List).isEmpty)
                  const Text('未找到符合格式的技能或技能型插件。'),
                for (final c
                    in (_inspection!['candidates'] as List).whereType<Map>())
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${c['name']} · ${c['status'] == 'supported'
                                ? '可安装'
                                : c['status'] == 'partial'
                                ? '部分支持'
                                : '暂不支持'}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(c['description']?.toString() ?? ''),
                          for (final warning in (c['warnings'] as List? ?? []))
                            Text(warning.toString()),
                          for (final component
                              in (c['components'] as List).whereType<Map>())
                            Text(
                              '${component['name']}：${component['status'] == 'supported' ? '格式支持，任务效果未验证' : (component['issues'] as List).join('；')}',
                            ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: _busy || c['status'] == 'unsupported'
                                ? null
                                : () => _install(c),
                            child: Text(
                              c['status'] == 'partial'
                                  ? '仅安装支持的技能'
                                  : widget.update == null
                                  ? '安装'
                                  : '更新',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy && _jobId == null ? null : _cancel,
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _inspect,
          child: Text(_inspection == null ? '开始检查' : '重新检查'),
        ),
      ],
    ),
  );
}

class _McpConnectionTile extends StatelessWidget {
  const _McpConnectionTile({
    required this.connection,
    required this.toolCount,
    required this.testing,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  final McpConnectionRecord connection;
  final int? toolCount;
  final bool testing;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(connection.url);
    final endpoint = '${uri?.host ?? connection.url}${uri?.path ?? ''}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E6EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _assetIcon('assets/icons/capabilities/mcp_connector.svg', 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connection.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      endpoint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF68707C),
                      ),
                    ),
                  ],
                ),
              ),
              if (connection.hasBearerToken)
                const Tooltip(
                  message: '已保存 Bearer 令牌',
                  child: Icon(
                    Icons.lock_outline,
                    size: 19,
                    color: Color(0xFF667085),
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: testing ? null : onTest,
                icon: testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  toolCount == null ? '尚未测试' : '可用工具：$toolCount',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF68707C),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.card, required this.selectedIndex});

  final _CollectionCard card;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: Container(
        color: card.background,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 25, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    card.subtitle,
                    style: const TextStyle(
                      color: Color(0xFF4D6076),
                      fontSize: 17,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      const Text(
                        '查看合集',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SvgPicture.asset(
                        'assets/icons/extensions/market_arrow_right.svg',
                        width: 22,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              right: -2,
              bottom: -4,
              width: 380,
              height: 160,
              child: SvgPicture.asset(card.asset, fit: BoxFit.contain),
            ),
            Positioned(
              right: 22,
              bottom: 18,
              child: Row(
                children: [
                  for (var index = 0; index < _collectionCards.length; index++)
                    Container(
                      width: 9,
                      height: 9,
                      margin: const EdgeInsets.only(left: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selectedIndex == index
                            ? const Color(0xFF1A1D24)
                            : const Color(0xFFD5D9E4),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtensionCard extends StatelessWidget {
  const _ExtensionCard({
    required this.entry,
    required this.installed,
    required this.onOpen,
    required this.onToggleInstall,
  });

  final ExtensionEntry entry;
  final bool installed;
  final VoidCallback onOpen;
  final VoidCallback onToggleInstall;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: const Color(0x14000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE9ECF1)),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 48),
                child: Row(
                  children: [
                    Container(
                      width: 78,
                      height: 78,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: entry.iconBackground,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SvgPicture.asset(entry.iconAsset),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              _AuthorAvatar(name: entry.author, size: 24),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  entry.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF718099),
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            entry.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF718099),
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _CardActionButton(
                    label: installed
                        ? '卸载${entry.name}'
                        : entry.isTrialCandidate
                        ? '检查${entry.name}'
                        : '安装${entry.name}',
                    onTap: onToggleInstall,
                    asset: installed
                        ? 'assets/icons/extensions/market_check.svg'
                        : 'assets/icons/extensions/market_add.svg',
                    iconSize: 28,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardActionButton extends StatelessWidget {
  const _CardActionButton({
    required this.label,
    required this.onTap,
    required this.asset,
    required this.iconSize,
  });

  final String label;
  final VoidCallback onTap;
  final String asset;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: SvgPicture.asset(asset, width: iconSize, height: iconSize),
          ),
        ),
      ),
    );
  }
}

class ExtensionCategoryPage extends StatefulWidget {
  const ExtensionCategoryPage({
    super.key,
    required this.title,
    required this.entries,
    required this.installedIds,
    required this.onChanged,
  });

  final String title;
  final List<ExtensionEntry> entries;
  final Set<String> installedIds;
  final VoidCallback onChanged;

  @override
  State<ExtensionCategoryPage> createState() => _ExtensionCategoryPageState();
}

class _ExtensionCategoryPageState extends State<ExtensionCategoryPage> {
  void _toggleInstalled(ExtensionEntry entry) {
    _openDetail(entry);
  }

  void _openDetail(ExtensionEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionDetailPage(
          entry: entry,
          installed: widget.installedIds.contains(entry.id),
          onInstallChanged: (installed) {
            if (installed) {
              widget.installedIds.add(entry.id);
            } else {
              widget.installedIds.remove(entry.id);
            }
            widget.onChanged();
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 640 ? 20.0 : 40.0;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 48),
            children: [
              Row(
                children: [
                  _marketButton(
                    label: '返回扩展市场',
                    asset: 'assets/icons/extensions/market_back.svg',
                    onTap: () => Navigator.maybePop(context),
                    size: 29,
                    padding: 4,
                  ),
                  const SizedBox(width: 14),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.entries.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: constraints.maxWidth - horizontal * 2 < 680
                      ? 1
                      : 2,
                  mainAxisExtent: 122,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 14,
                ),
                itemBuilder: (context, index) {
                  final entry = widget.entries[index];
                  return _ExtensionCard(
                    entry: entry,
                    installed: widget.installedIds.contains(entry.id),
                    onOpen: () => _openDetail(entry),
                    onToggleInstall: () => _toggleInstalled(entry),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExtensionDetailPage extends StatefulWidget {
  const ExtensionDetailPage({
    super.key,
    required this.entry,
    required this.installed,
    required this.onInstallChanged,
  });

  final ExtensionEntry entry;
  final bool installed;
  final ValueChanged<bool> onInstallChanged;

  @override
  State<ExtensionDetailPage> createState() => _ExtensionDetailPageState();
}

class _ExtensionDetailPageState extends State<ExtensionDetailPage> {
  late final bool _installed = widget.installed;

  Future<void> _openRepository() async {
    final uri = Uri.parse('https://github.com/${widget.entry.repository}');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) AppToast.show(context, '暂时无法打开 GitHub 链接');
  }

  Future<void> _toggleInstall() async {
    final record = widget.entry.installation;
    if (record == null) {
      final importUrl = widget.entry.importUrl;
      if (importUrl == null) {
        AppToast.show(context, '精选预览尚未上架，请从 GitHub 导入真实扩展');
        return;
      }
      final installed = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportInstallationDialog(initialUrl: importUrl),
      );
      if (installed == true && mounted) {
        widget.onInstallChanged(true);
        Navigator.pop(context);
      }
      return;
    }
    final operation = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('管理已安装扩展'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'toggle'),
            child: Text(record.enabled ? '停用' : '启用'),
          ),
          if (record.origin == 'github')
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'update'),
              child: const Text('检查更新（失败保留原版本）'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('卸载'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || operation == null) return;
    try {
      if (operation == 'update') {
        await showDialog<void>(
          context: context,
          builder: (_) => _ImportInstallationDialog(update: record),
        );
      } else {
        await CapabilityCloudSync.instance.manageInstallation(
          record,
          enabled: !record.enabled,
          uninstall: operation == 'delete',
        );
      }
      widget.onInstallChanged(operation != 'delete');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) AppToast.show(context, '操作失败：$e');
    }
  }

  void _openAuthor() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionAuthorPage(
          author: widget.entry.author,
          bio: widget.entry.authorBio,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 640 ? 20.0 : 40.0;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 54),
            children: [
              _buildTopBar(),
              const SizedBox(height: 28),
              _buildHeader(constraints.maxWidth - horizontal * 2),
              const SizedBox(height: 24),
              const Divider(color: Color(0xFFE4E8EE)),
              const SizedBox(height: 32),
              _buildFeatureSection(constraints.maxWidth - horizontal * 2),
              const SizedBox(height: 38),
              const Divider(color: Color(0xFFE4E8EE)),
              const SizedBox(height: 32),
              _buildUsageSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _marketButton(
          label: '返回扩展市场',
          asset: 'assets/icons/extensions/market_back.svg',
          onTap: () => Navigator.maybePop(context),
          size: 29,
          padding: 4,
        ),
        const SizedBox(width: 14),
        const Text(
          '扩展详情',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _buildHeader(double contentWidth) {
    final information = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: contentWidth < 700 ? 112 : 140,
          height: contentWidth < 700 ? 112 : 140,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: widget.entry.iconBackground,
            borderRadius: BorderRadius.circular(22),
          ),
          child: SvgPicture.asset(widget.entry.iconAsset),
        ),
        const SizedBox(width: 30),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.entry.name,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: _openAuthor,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _AuthorAvatar(name: widget.entry.author, size: 32),
                      Text(
                        widget.entry.author,
                        style: const TextStyle(
                          color: Color(0xFF32435B),
                          fontSize: 17,
                        ),
                      ),
                      SvgPicture.asset(
                        'assets/icons/extensions/market_arrow_right.svg',
                        width: 20,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F4FF),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          widget.entry.kindLabel,
                          style: const TextStyle(
                            color: Color(0xFF2971BD),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  SvgPicture.asset(
                    'assets/icons/extensions/verified.svg',
                    width: 23,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      widget.entry.installation == null
                          ? '尚未上架 · 仅预览'
                          : '已安装 · ${widget.entry.installation!.enabled ? "已启用" : "已停用"} · 任务效果需运行验证',
                      style: const TextStyle(
                        color: Color(0xFF6B7890),
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  Text(
                    '版本  ${widget.entry.version}',
                    style: const TextStyle(
                      color: Color(0xFF66738A),
                      fontSize: 16,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '·',
                      style: TextStyle(color: Color(0xFF66738A), fontSize: 18),
                    ),
                  ),
                  Flexible(
                    child: InkWell(
                      onTap: _openRepository,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvgPicture.asset(
                              'assets/icons/extensions/github_mark.svg',
                              width: 22,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                widget.entry.repository,
                                style: const TextStyle(
                                  color: Color(0xFF1D5FBF),
                                  fontSize: 16,
                                  decoration: TextDecoration.underline,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            SvgPicture.asset(
                              'assets/icons/extensions/external_link.svg',
                              width: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    if (contentWidth < 700) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          information,
          const SizedBox(height: 22),
          _installButton(),
          const SizedBox(height: 24),
          _description(),
          const SizedBox(height: 22),
          _suitableFor(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: information),
            const SizedBox(width: 28),
            _installButton(),
          ],
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.only(left: 170),
          child: _description(),
        ),
        const SizedBox(height: 22),
        _suitableFor(),
      ],
    );
  }

  Widget _description() {
    return Text(
      widget.entry.description,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.45,
      ),
    );
  }

  Widget _suitableFor() {
    return Row(
      children: [
        SvgPicture.asset('assets/icons/extensions/device.svg', width: 25),
        const SizedBox(width: 12),
        const Text(
          '适用于：',
          style: TextStyle(color: Color(0xFF5F6D84), fontSize: 17),
        ),
        Text(
          widget.entry.suitableFor,
          style: const TextStyle(color: Color(0xFF5F6D84), fontSize: 17),
        ),
      ],
    );
  }

  Widget _installButton() {
    final canImport =
        widget.entry.installation == null && widget.entry.importUrl != null;
    return FilledButton(
      onPressed: widget.entry.installation == null && !canImport
          ? null
          : _toggleInstall,
      style: FilledButton.styleFrom(
        backgroundColor: _installed
            ? const Color(0xFFEAF7EF)
            : const Color(0xFF121416),
        foregroundColor: _installed ? const Color(0xFF277744) : Colors.white,
        minimumSize: const Size(174, 62),
        padding: const EdgeInsets.symmetric(horizontal: 30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      child: Text(
        widget.entry.installation == null
            ? canImport
                  ? '检查并安装'
                  : '尚未上架'
            : '管理安装',
      ),
    );
  }

  Widget _buildFeatureSection(double contentWidth) {
    final record = widget.entry.installation;
    if (record != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '已安装组件',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          for (final c
              in (record.compatibility['components'] as List? ?? const [])
                  .whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${c['name']}：${c['status'] == 'supported' ? "已安装，任务效果待运行验证" : (c['issues'] as List? ?? []).join("；")}',
              ),
            ),
          for (final warning
              in (record.compatibility['warnings'] as List? ?? const []))
            Text(warning.toString()),
          const SizedBox(height: 12),
          const Text('MCP、hooks 和专有客户端组件不会执行。'),
          if (record.source['commit'] != null)
            SelectableText('仓库版本：${record.source['commit']}'),
        ],
      );
    }
    final features = widget.entry.features;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '你可以用它做什么',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          '从快速理解到深入梳理，按你的需要处理内容。',
          style: TextStyle(color: Color(0xFF61708A), fontSize: 17),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: contentWidth < 700 ? 340 : 380,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: features.length,
            separatorBuilder: (_, _) => const SizedBox(width: 18),
            itemBuilder: (context, index) {
              final feature = features[index];
              return SizedBox(
                width:
                    contentWidth *
                    (contentWidth < 700
                        ? (feature.large ? .88 : .74)
                        : (feature.large ? .56 : .40)),
                child: _FeatureTile(feature: feature),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildUsageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '如何使用',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          '把内容发到对话里，选择「${widget.entry.name}」，然后直接提问。',
          style: const TextStyle(
            color: Color(0xFF61708A),
            fontSize: 17,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 26),
        const Text(
          '例如：',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < widget.entry.examples.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${index + 1}.   ${widget.entry.examples[index]}',
              style: const TextStyle(fontSize: 18, height: 1.5),
            ),
          ),
      ],
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.feature});

  final ExtensionFeatureBlock feature;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '查看${feature.title}配图',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showPreview(context),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: feature.large
                  ? const Color(0xFFFFF9EB)
                  : const Color(0xFFF1F8FF),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(26, 24, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feature.title,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        feature.description,
                        style: const TextStyle(
                          color: Color(0xFF52667F),
                          fontSize: 16,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: feature.large ? 16 : 8,
                  right: feature.large ? 16 : 8,
                  bottom: feature.large ? 0 : -2,
                  height: feature.large ? 320 : 170,
                  child: SvgPicture.asset(
                    feature.illustration,
                    fit: BoxFit.contain,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPreview(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        feature.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: InteractiveViewer(
                    child: SvgPicture.asset(feature.illustration),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ExtensionAuthorPage extends StatelessWidget {
  const ExtensionAuthorPage({
    super.key,
    required this.author,
    required this.bio,
  });

  final String author;
  final String bio;

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 640 ? 20.0 : 40.0;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 48),
          children: [
            Row(
              children: [
                _marketButton(
                  label: '返回扩展详情',
                  asset: 'assets/icons/extensions/market_back.svg',
                  onTap: () => Navigator.maybePop(context),
                  size: 29,
                  padding: 4,
                ),
                const SizedBox(width: 14),
                const Text(
                  '作者详情',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 42),
            Center(child: _AuthorAvatar(name: author, size: 88)),
            const SizedBox(height: 18),
            Center(
              child: Text(
                author,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                bio,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF66738A),
                  fontSize: 17,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 40),
            const Divider(color: Color(0xFFE4E8EE)),
            const SizedBox(height: 30),
            const Text(
              '发布的作品',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 24),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FB),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Column(
                children: [
                  Text(
                    '暂无作品',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '个人作者作品页在 V1 先保持空状态。',
                    style: TextStyle(color: Color(0xFF738097), fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().substring(0, 1);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFEAF4FF),
        border: Border.all(color: const Color(0xFFD8E8FA)),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: const Color(0xFF2E74B8),
          fontSize: size * .42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Widget _assetIcon(String asset, double size) =>
    SvgPicture.asset(asset, width: size, height: size);

Widget _marketButton({
  required String label,
  required String asset,
  required VoidCallback onTap,
  required double size,
  required double padding,
}) {
  return Semantics(
    button: true,
    label: label,
    child: InkResponse(
      onTap: onTap,
      radius: 25,
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: SvgPicture.asset(asset, width: size, height: size),
      ),
    ),
  );
}
