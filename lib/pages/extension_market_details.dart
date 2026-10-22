part of 'extension_market_page.dart';

class _MarketDetailPage extends StatefulWidget {
  const _MarketDetailPage({
    required this.entry,
    required this.onInstall,
    required this.onRemove,
    required this.onManage,
    required this.onLogin,
    required this.onReconnect,
    required this.refresh,
    required this.onChat,
    this.onEdit,
  });
  final _MarketEntry entry;
  final Future<void> Function(_MarketEntry) onInstall,
      onRemove,
      onManage,
      onLogin,
      onReconnect;
  final Future<void> Function(_MarketEntry)? onEdit;
  final Future<_MarketEntry?> Function() refresh;
  final void Function(_MarketEntry entry, String prompt) onChat;
  @override
  State<_MarketDetailPage> createState() => _MarketDetailPageState();
}

class _MarketDetailPageState extends State<_MarketDetailPage>
    with WidgetsBindingObserver {
  late _MarketEntry _entry;
  bool _busy = false, _expanded = true;
  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _entry.connection != null &&
        !_busy)
      unawaited(_perform((_) async {}));
  }

  Future<void> _perform(Future<void> Function(_MarketEntry) operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation(_entry);
      final next = await widget.refresh();
      if (!mounted) return;
      if (next == null) {
        Navigator.pop(context);
        return;
      }
      setState(() => _entry = next);
    } catch (error) {
      if (mounted) AppToast.show(context, '操作未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyLink() async {
    final url = _entry.url;
    if (url == null || url.isEmpty) {
      AppToast.show(context, '此扩展未提供公开链接');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) AppToast.show(context, '来源链接已复制');
  }

  Widget _more() => PopupMenuButton<String>(
    tooltip: '更多 ${_entry.name} 操作',
    enabled: !_busy,
    icon: marketIcon('dots', size: 25),
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
    onSelected: (action) {
      switch (action) {
        case 'copy':
          unawaited(_copyLink());
        case 'edit':
          unawaited(_perform(widget.onEdit!));
        case 'remove':
          unawaited(_perform(widget.onRemove));
        case 'manage':
          unawaited(_perform(widget.onManage));
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(value: 'copy', child: _menuRow('link', '复制链接')),
      if (_entry.editable)
        PopupMenuItem(value: 'edit', child: _menuRow('edit', '编辑技能')),
      if (_entry.installed)
        PopupMenuItem(value: 'manage', child: _menuRow('gear', '管理')),
      if (_entry.installed)
        PopupMenuItem(value: 'remove', child: _menuRow('trash-danger', '卸载')),
    ],
  );
  Widget _menuRow(String icon, String label) =>
      Row(children: [marketIcon(icon), const SizedBox(width: 12), Text(label)]);
  Future<void> _try([String prompt = '']) async {
    if (!_entry.installed) {
      await _perform(widget.onInstall);
      if (!mounted || !_entry.installed || prompt.isEmpty) return;
    }
    widget.onChat(_entry, prompt);
  }

  Widget _actions() => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 9,
    runSpacing: 8,
    children: [
      _more(),
      if (!_entry.installed)
        marketButton(
          _busy ? '正在处理…' : '安装插件',
          _busy ? null : () => _perform(widget.onInstall),
          icon: 'plus',
          primary: true,
        )
      else ...[
        marketButton(
          '管理',
          _busy ? null : () => _perform(widget.onManage),
          icon: 'gear',
          selected: true,
        ),
        if (_entry.connection?.needsLogin == true)
          marketButton(
            '登录授权',
            _busy ? null : () => _perform(widget.onLogin),
            primary: true,
          )
        else if (_entry.connection != null && !_entry.connection!.isReady)
          marketButton(
            '重新连接',
            _busy ? null : () => _perform(widget.onReconnect),
            primary: true,
          )
        else
          marketButton(
            '在聊天中试用',
            _busy ? null : _try,
            icon: 'chat',
            primary: true,
          ),
      ],
    ],
  );
  String get _status => switch (_entry.connection?.status) {
    McpInstallationState.ready => '已连接',
    McpInstallationState.needsLogin => '需要登录',
    McpInstallationState.installing => '正在安装',
    McpInstallationState.connecting => '正在连接',
    McpInstallationState.failed => '连接中断',
    McpInstallationState.unsupported => '暂不支持',
    _ => '未连接',
  };
  Widget _section(String title, List<Widget> children, {String? count}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          marketSection(title, count: count),
          const Divider(height: 1, color: marketLine),
          ...children,
        ],
      );
  Widget _flat(String name, String description, {String icon = 'file-text'}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            MarketBrand('${marketAssets}detail/$icon.svg'),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: marketMuted,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  Widget _info(String name, String value) => Padding(
    padding: const EdgeInsets.only(top: 11),
    child: LayoutBuilder(
      builder: (_, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: constraints.maxWidth <= 540 ? 96 : 136,
            child: Text(
              name,
              style: const TextStyle(
                color: marketMuted,
                fontSize: 15,
                height: 1.6,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '未提供' : value,
              style: const TextStyle(fontSize: 15, height: 1.6),
            ),
          ),
        ],
      ),
    ),
  );
  List<Widget> _pluginContent() => [
    Row(
      children: [
        marketButton('插件', () => Navigator.pop(context)),
        marketIcon('caret-right', size: 16),
        Expanded(child: Text(_entry.name, overflow: TextOverflow.ellipsis)),
      ],
    ),
    const SizedBox(height: 28),
    LayoutBuilder(
      builder: (_, constraints) {
        final small = constraints.maxWidth <= 540;
        final identity = Row(
          children: [
            MarketBrand(
              _entry.asset,
              size: small ? 66 : 82,
              glyphSize: small ? 44 : 54,
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _entry.name,
                    style: TextStyle(
                      fontSize: small ? 25 : 28,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${_entry.kind == ExtensionKind.mcp ? 'MCP 服务' : _entry.developer} · ${_entry.description}',
                    style: TextStyle(
                      fontSize: small ? 13 : 15,
                      color: marketMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        return constraints.maxWidth <= 710
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identity,
                  const SizedBox(height: 18),
                  Align(alignment: Alignment.centerRight, child: _actions()),
                ],
              )
            : Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 20),
                  _actions(),
                ],
              );
      },
    ),
    const SizedBox(height: 24),
    if (_entry.examples.isNotEmpty)
      LayoutBuilder(
        builder: (_, constraints) {
          final small = constraints.maxWidth <= 540;
          final prompts = _entry.examples;
          return Container(
            padding: EdgeInsets.symmetric(
              vertical: small ? 16 : 25,
              horizontal: small
                  ? 16
                  : constraints.maxWidth <= 710
                  ? 28
                  : 64,
            ),
            constraints: BoxConstraints(minHeight: small ? 0 : 310),
            decoration: BoxDecoration(
              color: marketSoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final prompt in prompts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        onTap: _busy ? null : () => _try(prompt),
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(15),
                          child: Row(
                            children: [
                              if (!small) ...[
                                SvgPicture.asset(
                                  _entry.asset,
                                  width: 27,
                                  height: 27,
                                ),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _entry.name,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      prompt,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        height: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                width: 34,
                                height: 34,
                                decoration: const BoxDecoration(
                                  color: marketSoft,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: marketIcon('arrow-right', size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    const SizedBox(height: 24),
    Text(
      _entry.description,
      style: const TextStyle(fontSize: 15, height: 1.75),
    ),
    _section(_entry.kind == ExtensionKind.mcp ? '工具' : '技能', [
      if (_entry.connection != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            _entry.connection!.toolCount == null
                ? '服务器尚未提供工具清单。'
                : '服务器已发现 ${_entry.connection!.toolCount} 个工具；具体工具由连接后的任务读取。',
            style: const TextStyle(color: marketMuted, height: 1.65),
          ),
        )
      else if ((_entry.record?.compatibility['components'] as List? ?? [])
          .isNotEmpty)
        for (final component
            in (_entry.record!.compatibility['components'] as List)
                .whereType<Map>())
          _flat(
            component['name']?.toString() ?? '',
            component['status'] == 'unsupported'
                ? '未安装 · 暂不支持'
                : component['description']?.toString() ?? '',
          )
      else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('安装并连接后查看可用能力。', style: TextStyle(color: marketMuted)),
        ),
    ], count: _entry.connection?.toolCount?.toString()),
    _section('信息', [
      _info('开发者', _entry.developer),
      _info('类别', _entry.category),
      _info('版本', _entry.version),
      if (_entry.kind == ExtensionKind.mcp) ...[
        _info('类型', 'MCP 服务'),
        _info('连接状态', _status),
        _info(
          '传输方式',
          _entry.catalog?.runtime == 'stdio' ? 'stdio（服务端运行）' : 'HTTP',
        ),
        _info('服务器地址', _entry.connection?.url ?? '未连接'),
        if (_entry.connection?.error != null)
          _info('连接错误', _entry.connection!.error!),
      ],
      _info('来源', _entry.url ?? '未提供'),
      if (_entry.url != null)
        Align(
          alignment: Alignment.centerLeft,
          child: marketButton('打开来源', () async {
            final uri = Uri.tryParse(_entry.url!);
            if (uri == null || uri.scheme != 'https') return;
            if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
                mounted)
              AppToast.show(context, '无法打开来源链接');
          }, icon: 'external'),
        ),
      if (_entry.kind != ExtensionKind.mcp) _info('隐私政策', '未提供'),
    ]),
  ];
  String get _introduction =>
      (_entry.record?.currentVersion?.content ?? _entry.description)
          .replaceFirst(RegExp(r'^---\s*\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)'), '')
          .trim();
  List<Widget> _skillContent() => [
    Row(
      children: [
        marketIconButton('back', '返回技能', () => Navigator.pop(context)),
        const Expanded(
          child: Text(
            '技能详情',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
        ),
        _more(),
      ],
    ),
    LayoutBuilder(
      builder: (_, constraints) {
        final small = constraints.maxWidth <= 540;
        return Padding(
          padding: EdgeInsets.fromLTRB(0, small ? 26 : 45, 0, small ? 28 : 38),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarketBrand(
                '${marketAssets}detail/research.svg',
                size: small ? 70 : 104,
                glyphSize: small ? 42 : 58,
                soft: true,
              ),
              SizedBox(width: small ? 16 : 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _entry.name,
                      style: TextStyle(
                        fontSize: small ? 25 : 30,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _entry.description,
                      style: TextStyle(
                        fontSize: small ? 14 : 17,
                        color: marketMuted,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${_entry.category} · ${_entry.developer} · ${_entry.version}',
                      style: TextStyle(
                        fontSize: small ? 12 : 14,
                        color: marketMuted,
                        height: 1.65,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
    const Divider(height: 1, color: marketLine),
    marketSection('技能介绍'),
    SelectableText(
      _introduction,
      maxLines: _expanded ? null : 3,
      style: const TextStyle(fontSize: 16, height: 1.8),
    ),
    Center(
      child: Semantics(
        expanded: _expanded,
        child: TextButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _expanded ? '收起' : '展开介绍',
                style: const TextStyle(color: marketMuted),
              ),
              const SizedBox(width: 8),
              RotatedBox(
                quarterTurns: _expanded ? 0 : 2,
                child: marketIcon('caret-up', size: 18),
              ),
            ],
          ),
        ),
      ),
    ),
  ];
  @override
  Widget build(BuildContext context) => Theme(
    data: marketTheme(context),
    child: MarketFrame(
      children: _entry.kind == ExtensionKind.skill
          ? _skillContent()
          : _pluginContent(),
      footer: _entry.kind == ExtensionKind.skill
          ? SizedBox(
              width: double.infinity,
              child: marketButton(
                _busy
                    ? '正在处理…'
                    : _entry.installed
                    ? '在聊天中试用'
                    : '添加技能',
                _busy ? null : _try,
                primary: true,
                radius: 18,
                height: 54,
              ),
            )
          : null,
    ),
  );
}
