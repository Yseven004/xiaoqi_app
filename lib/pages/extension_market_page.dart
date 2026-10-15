import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/app_toast.dart';

enum ExtensionKind { skill, plugin, mcp }

enum ExtensionFilter { curated, installed, created }

const _installedPreferencesKey = 'xiaoqi_extension_market_installed_v1';
Future<void> _installedWriteQueue = Future<void>.value();

Future<void> _persistInstalledIds(Set<String> installedIds) {
  final snapshot = installedIds.toList(growable: false);
  final nextWrite = _installedWriteQueue.then<void>((_) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_installedPreferencesKey, snapshot);
  });
  // Keep later writes usable even if a platform write fails. The UI state is
  // still authoritative for the current session, and a later write can retry.
  _installedWriteQueue = nextWrite.catchError((_) {});
  return _installedWriteQueue;
}

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

const _mcpExtensions = [
  ExtensionEntry(
    id: 'literature-mcp',
    kind: ExtensionKind.mcp,
    name: '文献检索 MCP',
    author: '知网',
    description: '连接文献检索与引用信息服务',
    iconAsset: 'assets/icons/capabilities/mcp_connector.svg',
    iconBackground: Color(0xFFEFF6FF),
    authorBio: '知网提供面向研究工作的文献检索与引用整理能力。',
    suitableFor: '研究主题、论文、引用',
    features: _quickReadFeatures,
    examples: ['检索和这个主题相关的文献。'],
    repository: 'cnki/literature-mcp',
  ),
  ExtensionEntry(
    id: 'workspace-mcp',
    kind: ExtensionKind.mcp,
    name: '工作区 MCP',
    author: '小七官方',
    description: '让智能体安全读取当前工作区资料',
    iconAsset: 'assets/icons/capabilities/mcp_connector.svg',
    iconBackground: Color(0xFFEFF9F1),
    authorBio: '小七官方为阅读、学习与研究提供可靠的智能工具。',
    suitableFor: '工作区、资料、项目文件',
    features: _quickReadFeatures,
    examples: ['查找工作区里和这个主题相关的资料。'],
    repository: 'xiaoqi/workspace-mcp',
  ),
];

List<ExtensionEntry> _entriesFor(ExtensionKind kind) => switch (kind) {
  ExtensionKind.skill => _curatedExtensions,
  ExtensionKind.plugin => _pluginExtensions,
  ExtensionKind.mcp => _mcpExtensions,
};

class ExtensionMarketPage extends StatefulWidget {
  const ExtensionMarketPage({super.key});

  @override
  State<ExtensionMarketPage> createState() => _ExtensionMarketPageState();
}

class _ExtensionMarketPageState extends State<ExtensionMarketPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _carouselController = PageController();
  final Set<String> _installedIds = {'paper-reader'};
  Timer? _carouselTimer;
  Timer? _resumeCarouselTimer;
  int _installedMutationVersion = 0;
  int _carouselIndex = 0;
  String _query = '';
  ExtensionKind _kind = ExtensionKind.skill;
  ExtensionFilter _filter = ExtensionFilter.curated;
  bool _carouselStarted = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    unawaited(_restoreInstalled());
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
    final restoreVersion = _installedMutationVersion;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_installedPreferencesKey);
      if (!mounted ||
          saved == null ||
          restoreVersion != _installedMutationVersion) {
        return;
      }
      setState(() {
        _installedIds
          ..clear()
          ..addAll(saved);
      });
    } catch (_) {
      // Keep the in-memory defaults when local storage is unavailable.
    }
  }

  void _handleSearchChanged() {
    setState(() => _query = _searchController.text.trim().toLowerCase());
  }

  void _applyInstalledChange(String id, bool installed) {
    _installedMutationVersion++;
    if (installed) {
      _installedIds.add(id);
    } else {
      _installedIds.remove(id);
    }
    if (mounted) setState(() {});
    unawaited(_persistInstalledIds(_installedIds));
  }

  void _toggleInstalled(ExtensionEntry entry) {
    final nextInstalled = !_installedIds.contains(entry.id);
    _applyInstalledChange(entry.id, nextInstalled);
    AppToast.show(
      context,
      nextInstalled ? '已安装「${entry.name}」' : '已卸载「${entry.name}」',
    );
  }

  List<ExtensionEntry> _visibleEntries() {
    final entries = _entriesFor(_kind);
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionDetailPage(
          entry: entry,
          installed: _installedIds.contains(entry.id),
          onInstallChanged: (installed) {
            _applyInstalledChange(entry.id, installed);
          },
        ),
      ),
    );
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
    _installedMutationVersion++;
    unawaited(_persistInstalledIds(_installedIds));
    if (mounted) setState(() {});
  }

  Future<void> _showCreateImportSheet() async {
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

  Future<void> _showImportDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _GitHubImportDialog(),
    );
    if (!mounted || url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      AppToast.show(context, '请输入公开 GitHub 仓库链接');
      return;
    }
    AppToast.show(context, '已提交导入检查：${uri.path}');
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
              _buildFilters(),
              const SizedBox(height: 38),
              if (_filter == ExtensionFilter.created)
                _buildCreatedEmptyState()
              else ...[
                _buildCollections(),
                const SizedBox(height: 40),
                _buildCategorySection(
                  '热门推荐',
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
          label: const Text('创建/导入'),
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
              installed: _installedIds.contains(entries[index].id),
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

class _GitHubImportDialog extends StatefulWidget {
  const _GitHubImportDialog();

  @override
  State<_GitHubImportDialog> createState() => _GitHubImportDialogState();
}

class _GitHubImportDialogState extends State<_GitHubImportDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从公开 GitHub 导入'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: 'https://github.com/owner/repository',
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('开始检查'),
        ),
      ],
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
                    label: installed ? '卸载${entry.name}' : '安装${entry.name}',
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
    final installed = !widget.installedIds.contains(entry.id);
    setState(() {
      if (installed) {
        widget.installedIds.add(entry.id);
      } else {
        widget.installedIds.remove(entry.id);
      }
    });
    widget.onChanged();
    AppToast.show(
      context,
      installed ? '已安装「${entry.name}」' : '已卸载「${entry.name}」',
    );
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
  late bool _installed = widget.installed;

  Future<void> _openRepository() async {
    final uri = Uri.parse('https://github.com/${widget.entry.repository}');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) AppToast.show(context, '暂时无法打开 GitHub 链接');
  }

  void _toggleInstall() {
    setState(() => _installed = !_installed);
    widget.onInstallChanged(_installed);
    AppToast.show(
      context,
      _installed ? '已安装「${widget.entry.name}」' : '已卸载「${widget.entry.name}」',
    );
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
                  const Text(
                    '已通过小七检查',
                    style: TextStyle(color: Color(0xFF6B7890), fontSize: 16),
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
    return FilledButton(
      onPressed: _toggleInstall,
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
      child: Text(_installed ? '已安装' : '安装'),
    );
  }

  Widget _buildFeatureSection(double contentWidth) {
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
