part of 'reading_companion_composer.dart';

const _paperclip = 'assets/icons/extension_market/detail/paperclip.svg';
const _skillsIcon = 'assets/icons/capabilities/skill_plugin_capsule.svg';
const _mcpIcon = 'assets/icons/capabilities/mcp_connector.svg';
const _fileImage = 'assets/images/home_attachment_image.svg';
const _line = Color(0xFFEBEBEB);

extension _CompanionMenus on _ReadingCompanionComposerState {
  Widget _buildMenu(_CompanionMenu menu) {
    return switch (menu) {
      _CompanionMenu.root => _menuSurface(
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Column(
            children: [
              _menuRow('文件', _paperclip, () => _showMenu(_CompanionMenu.files)),
              _menuRow('技能 / 插件', _skillsIcon, () {
                _showMenu(_CompanionMenu.skills);
              }),
              _menuRow('MCP 连接器', _mcpIcon, () {
                _showMenu(_CompanionMenu.mcp);
              }),
            ],
          ),
        ),
      ),
      _CompanionMenu.files => _filesMenu(),
      _CompanionMenu.imageSource => _imageSourceMenu(),
      _CompanionMenu.skills => _skillsMenu(),
      _CompanionMenu.mcp => _connectorsMenu(),
      _CompanionMenu.reasoning => HomeChatModelMenuSurface(
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: HomeChatReasoningPicker(
            selection: widget.reasoningSelection,
            onChanged: widget.onReasoningChanged,
          ),
        ),
      ),
    };
  }

  Widget _filesMenu() => _subMenu(
    '文件',
    children: [
      _menuRow(
        '图片',
        _fileImage,
        () => _showMenu(_CompanionMenu.imageSource),
        subtitle: '从相册选择或拍照',
      ),
      const Divider(height: 1, color: _line),
      _menuRow(
        '本地文件',
        'assets/images/home_attachment_file.svg',
        () => _pickAttachment(2),
        subtitle: '浏览设备文件',
      ),
      const Divider(height: 1, color: _line),
      _menuRow(
        '微信文件',
        'assets/images/home_attachment_wechat.svg',
        () => _pickAttachment(3),
        subtitle: '从微信添加附件',
      ),
    ],
  );

  Widget _imageSourceMenu() => _subMenu(
    '图片',
    onClose: () => _showMenu(_CompanionMenu.files),
    children: [
      _menuRow('从相册选择', _fileImage, () => _pickAttachment(0)),
      const Divider(height: 1, color: _line),
      _menuRow('拍照', 'assets/images/home_attachment_camera.svg', () {
        _pickAttachment(1);
      }),
    ],
  );

  void _pickAttachment(int action) =>
      _activate(() => widget.onAddAttachment(action));

  Widget _skillsMenu() {
    final visible = _capabilities.where((r) => r.enabled && r.showInMenu);
    final skills = visible.where((r) => r.kind == CapabilityKind.skill);
    final plugins = visible.where((r) => r.kind == CapabilityKind.plugin);
    final bothEmpty = visible.isEmpty;
    return _subMenu(
      '技能 / 插件',
      pinnedTop: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _quickAction(
                '创建图像',
                'assets/icons/capabilities/image.svg',
                () => _activate(() {
                  widget.onCapabilitySelected(const {
                    'type': 'action',
                    'id': 'create-image',
                    'name': '创建图像',
                  });
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _quickAction(
                '绘图',
                'assets/icons/capabilities/brush.svg',
                () => _activate(widget.onDrawingSelected),
              ),
            ),
          ],
        ),
      ),
      children: [
        if (_capabilityLoadFailed)
          _statusRow('技能和插件列表读取失败', '重试', _loadCapabilities),
        if (bothEmpty && !_capabilityLoadFailed)
          if (_loadingCapabilities)
            _loadingRow('正在读取技能和插件…')
          else ...[
            const Divider(height: 1, color: _line),
            _statusRow(
              _capabilities.isEmpty ? '还没有安装技能或插件' : '暂无可用的技能或插件',
              _capabilities.isEmpty ? '去安装' : '查看市场',
              () => _activate(widget.onInstallPlugins),
            ),
          ],
        if (!bothEmpty) ...[
          ..._capabilityGroup(
            skills,
            '技能',
            'assets/icons/capabilities/capability_skill_book.svg',
            widget.onInstallSkills,
            installed: _capabilities.any((r) => r.kind == CapabilityKind.skill),
          ),
          ..._capabilityGroup(
            plugins,
            '插件',
            'assets/icons/capabilities/capability_plugin_document.svg',
            widget.onInstallPlugins,
            installed: _capabilities.any(
              (r) => r.kind == CapabilityKind.plugin,
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _capabilityGroup(
    Iterable<CapabilityRecord> records,
    String name,
    String asset,
    VoidCallback install, {
    required bool installed,
  }) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
      child: Text(
        name,
        style: const TextStyle(color: _subtleInk, fontSize: 13),
      ),
    ),
    const Divider(height: 1, color: _line),
    if (records.isEmpty && !_capabilityLoadFailed && !_loadingCapabilities)
      _statusRow(
        installed ? '暂无可用的$name' : '还没有安装$name',
        installed ? '查看市场' : '去安装',
        () => _activate(install),
      )
    else
      for (final record in records)
        _menuRow(record.name, asset, () {
          _activate(() {
            widget.onCapabilitySelected({
              'type': record.kind.name,
              'id': record.id,
              'name': record.name,
              'description': record.description,
              'version_id': record.currentVersion?.id,
            });
          });
        }),
  ];

  Widget _connectorsMenu() {
    final ready = _connections
        .where((connection) => connection.isReady)
        .toList();
    return _subMenu(
      'MCP 连接器',
      pinnedBottom: ready.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1, color: _line),
                _menuRow(
                  '管理连接器',
                  'assets/icons/capabilities/settings.svg',
                  () => _activate(widget.onManageMcp),
                  compact: true,
                ),
              ],
            ),
      children: [
        if (!widget.signedIn)
          if (widget.requestLogin == null || _loggingIn)
            _loadingRow(_loggingIn ? '正在登录…' : '登录后可使用 MCP 连接器')
          else
            _statusRow('登录后可使用 MCP 连接器', '登录', _signInForConnectors)
        else ...[
          if (_mcpLoadFailed) _statusRow('连接器列表读取失败', '重试', _loadConnections),
          if (ready.isEmpty && !_mcpLoadFailed)
            if (_loadingConnections)
              _loadingRow('正在读取连接器…')
            else if (_connections.isEmpty)
              _statusRow(
                '还没有安装 MCP 连接器',
                '去安装连接器',
                () => _activate(widget.onInstallMcp),
              )
            else
              _statusRow(
                '暂无可用的 MCP 连接器',
                '管理连接器',
                () => _activate(widget.onManageMcp),
              ),
          if (ready.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(2, 0, 2, 2),
              child: Text(
                '本轮使用 MCP',
                style: TextStyle(color: _subtleInk, fontSize: 13),
              ),
            ),
          for (var i = 0; i < ready.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _line),
            _connectorRow(ready[i]),
          ],
        ],
      ],
    );
  }

  Widget _connectorRow(McpConnectionRecord record) {
    final host = Uri.tryParse(record.url)?.host ?? '';
    return _menuRow(
      record.name,
      _mcpIcon,
      () => _activate(() {
        widget.onCapabilitySelected({
          'type': 'mcp',
          'id': record.id,
          'name': record.name,
          'url': record.url,
          'has_bearer_token': record.hasBearerToken,
        });
      }),
      subtitle: host.isEmpty ? null : host,
      leading: SkillPresentationIcon(
        record.icon,
        size: 20,
        defaultAsset: 'mcp',
      ),
    );
  }

  Widget _menuSurface({required Widget child}) => Material(
    color: Colors.white,
    elevation: 5,
    surfaceTintColor: Colors.transparent,
    shadowColor: const Color(0x24000000),
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: Color(0xFFD8D8D8)),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _subMenu(
    String title, {
    required List<Widget> children,
    Widget? pinnedTop,
    Widget? pinnedBottom,
    VoidCallback? onClose,
  }) => _menuSurface(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final header = Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _bodyInk,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭$title菜单',
              onPressed: onClose ?? () => _showMenu(null),
              icon: const _CompanionIcon(
                'assets/icons/note_format/close.svg',
                size: 14,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            ),
          ],
        );
        const panelInsets = EdgeInsets.fromLTRB(16, 5, 13, 9);
        final list = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
        final textScale = MediaQuery.textScalerOf(context).scale(17) / 17;
        final pinnedMinHeight =
            58.0 +
            (pinnedTop == null ? 0 : 58 * textScale) +
            (pinnedBottom == null ? 0 : 48 * textScale);
        if (constraints.maxHeight < pinnedMinHeight) {
          // Keep everything reachable when the IME or split screen leaves
          // less than a full header and tool row.
          return SingleChildScrollView(
            primary: false,
            padding: panelInsets,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [header, ?pinnedTop, list, ?pinnedBottom],
            ),
          );
        }
        return Padding(
          padding: panelInsets,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              ?pinnedTop,
              Flexible(
                child: SingleChildScrollView(primary: false, child: list),
              ),
              ?pinnedBottom,
            ],
          ),
        );
      },
    ),
  );

  Widget _menuRow(
    String title,
    String asset,
    VoidCallback onTap, {
    String? subtitle,
    Widget? leading,
    bool compact = false,
  }) => InkWell(
    borderRadius: BorderRadius.circular(7),
    onTap: onTap,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: subtitle == null ? 44 : 50),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: Center(child: leading ?? _CompanionIcon(asset)),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _bodyInk,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(color: _subtleInk, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _quickAction(String title, String asset, VoidCallback onTap) =>
      Material(
        color: const Color(0xFFF3F3F3),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: _line),
          borderRadius: BorderRadius.circular(9),
        ),
        child: _menuRow(title, asset, onTap),
      );

  Widget _statusRow(String explanation, String action, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                explanation,
                style: const TextStyle(fontSize: 13, color: _subtleInk),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                foregroundColor: _bodyInk,
                backgroundColor: const Color(0xFFF3F3F3),
                minimumSize: const Size(48, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Color(0xFFE0E0E0)),
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              child: Text(action, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );

  Widget _loadingRow(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: const TextStyle(color: _subtleInk, fontSize: 13),
      ),
    ),
  );
}
