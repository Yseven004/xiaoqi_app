part of 'extension_market_page.dart';

class _PackageImportDialog extends StatefulWidget {
  const _PackageImportDialog({
    this.url,
    this.upload = false,
    this.skill = false,
    this.update,
    this.forEditor = false,
  });
  final String? url;
  final bool upload, skill;
  final CapabilityRecord? update;
  final bool forEditor;
  @override
  State<_PackageImportDialog> createState() => _PackageImportDialogState();
}

class _PackageImportDialogState extends State<_PackageImportDialog> {
  final _url = TextEditingController();
  final _cloud = CapabilityCloudSync.instance;
  Map<String, dynamic>? _inspection, _policy;
  PlatformFile? _file;
  int _fileSize = 0;
  List<int>? _checkedBytes;
  bool _busy = false, _upload = false, _loadingPolicy = false;
  String? _error, _jobId;
  String _progress = '';
  @override
  void initState() {
    super.initState();
    _upload = widget.upload;
    _url.text =
        widget.url ?? widget.update?.source['requested_url']?.toString() ?? '';
    if (_upload) unawaited(_loadPolicy());
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _loadPolicy() async {
    setState(() {
      _loadingPolicy = true;
      _error = null;
    });
    try {
      final policy = await _cloud.capabilityImportPolicy();
      if (mounted) setState(() => _policy = policy);
    } catch (error) {
      if (mounted) setState(() => _error = '无法取得上传限制：$error');
    } finally {
      if (mounted) setState(() => _loadingPolicy = false);
    }
  }

  Future<void> _choose() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: widget.skill
            ? ['zip', 'skill', 'md', 'tgz', 'gz']
            : ['zip', 'tgz', 'gz'],
      );
      if (file == null || !mounted) return;
      final size = await file.length();
      final allowed = (_policy?['upload_extensions'] as List? ?? [])
          .map((e) => e.toString().replaceFirst(RegExp(r'^\.'), ''))
          .toList();
      final name = file.name.toLowerCase();
      final limit = (_policy?['max_archive_bytes'] as num?)?.toInt();
      if (limit == null ||
          !allowed.any((extension) => name.endsWith('.$extension')))
        throw const FormatException('请选择服务端支持的技能文件或插件压缩包');
      if (size == null || size <= 0 || size > limit)
        throw FormatException('文件为空或超过 ${_size(limit)} 限制');
      setState(() {
        _file = file;
        _fileSize = size;
        _inspection = null;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _inspect() async {
    if (!_upload) {
      final uri = Uri.tryParse(_url.text.trim());
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.pathSegments.length < 2 ||
          uri.userInfo.isNotEmpty) {
        setState(() => _error = '填写公开 GitHub 仓库或子目录的完整 HTTPS 链接。');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
      _jobId = null;
      _inspection = null;
      _progress = '正在读取清单、固定来源和检查依赖…';
    });
    try {
      Map<String, dynamic> result;
      if (_upload) {
        final file = _file;
        if (file == null) throw const FormatException('请先选择文件');
        final limit = (_policy!['max_archive_bytes'] as num).toInt();
        final currentSize = await file.length();
        if (currentSize == null || currentSize <= 0 || currentSize > limit)
          throw const FormatException('文件大小已变化，请重新选择');
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > limit)
          throw const FormatException('文件大小已变化，请重新选择');
        result = await _cloud.inspectCapabilityUpload(
          fileName: file.name,
          bytes: bytes,
          onJob: _onJob,
        );
        _checkedBytes = bytes;
      } else {
        result = await _cloud.runImportOperation({
          'url': _url.text.trim(),
        }, onJob: _onJob);
      }
      if (mounted)
        setState(
          () => _inspection = Map<String, dynamic>.from(
            result['inspection'] as Map,
          ),
        );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onJob(String id) {
    if (mounted) setState(() => _jobId = id);
  }

  Future<void> _install(Map candidate) async {
    setState(() {
      _busy = true;
      _jobId = null;
      _error = null;
      _progress = widget.forEditor ? '正在读取已检查的技能内容…' : '正在安装固定版本，成功前不会显示为已安装…';
    });
    try {
      if (widget.forEditor) {
        final draft = await _cloud.inspectedSkillDraft(
          _inspection!['id'].toString(),
          candidate['id'].toString(),
        );
        if (mounted) Navigator.pop(context, draft);
        return;
      }
      if (_upload &&
          widget.skill &&
          candidate['kind'] == 'skill' &&
          candidate['status'] == 'supported' &&
          widget.update == null) {
        final draft = skillDraftFromUpload(
          fileName: _file!.name,
          bytes: _checkedBytes!,
          root: candidate['root']?.toString() ?? '',
          policy: _policy!,
        );
        if (mounted) Navigator.pop(context, draft);
        return;
      }
      await _cloud.runImportOperation(
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
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (!_busy) {
      Navigator.pop(context);
      return;
    }
    if (_jobId == null) return;
    setState(() => _progress = '正在请求取消，等待服务器确认…');
    try {
      await _cloud.cancelImportOperation(_jobId!);
    } catch (error) {
      if (mounted) setState(() => _error = '取消失败：$error');
    }
  }

  String _size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  @override
  Widget build(BuildContext context) => MarketDialog(
    title: _upload
        ? widget.skill
              ? '上传技能'
              : '创建插件'
        : widget.update == null
        ? '从 GitHub 导入'
        : '检查并更新',
    canClose: !_busy,
    leadingAction: _upload && !widget.skill
        ? marketButton(
            '添加自定义 MCP 服务器',
            _busy ? null : () => Navigator.pop(context, 'mcp'),
          )
        : null,
    children: [
      if (_upload) ...[
        Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SvgPicture.asset(
                    '${marketAssets}detail/upload-border.svg',
                    fit: BoxFit.fill,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              // Match the prototype's roomy upload area without fixing text height.
              child: OutlinedButton(
                onPressed: _busy || _policy == null ? null : _choose,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 36,
                    horizontal: 18,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  side: BorderSide.none,
                  minimumSize: const Size(0, 205),
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                  foregroundColor: marketMuted,
                ),
                child: Column(
                  children: [
                    marketIcon(
                      widget.skill ? 'file-plus' : 'upload',
                      size: 29,
                      color: marketMuted,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _file?.name ?? (widget.skill ? '选择技能文件' : '点击上传插件压缩包'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF555555),
                        height: 1.65,
                      ),
                    ),
                    const SizedBox(height: 13),
                    Text(
                      _file == null
                          ? (_loadingPolicy
                                ? '正在读取上传限制…'
                                : '支持 .zip / .tgz / .tar.gz${widget.skill ? ' / .skill / .md' : ''}')
                          : '${_size(_fileSize)} · 点击重新选择',
                      style: const TextStyle(color: marketMuted, fontSize: 14),
                    ),
                    if (_policy != null) ...[
                      const SizedBox(height: 13),
                      Text(
                        '压缩包最多 ${_size((_policy!['max_archive_bytes'] as num).toInt())}，${_policy!['max_files']} 个文件',
                        style: const TextStyle(
                          color: marketMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        marketLink(
          '从公开 GitHub 链接导入',
          _busy
              ? null
              : () => setState(() {
                  _upload = false;
                  _inspection = null;
                  _error = null;
                }),
        ),
      ] else ...[
        const Text(
          '粘贴公开仓库或子目录链接，先检查，再添加。',
          style: TextStyle(color: marketMuted, height: 1.65),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _url,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {
            _inspection = null;
            _error = null;
          }),
          decoration: const InputDecoration(
            labelText: 'GitHub 链接',
            hintText: 'https://github.com/owner/repository',
          ),
        ),
      ],
      if (_busy)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Semantics(liveRegion: true, child: Text(_progress)),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA52B25), height: 1.65),
          ),
        ),
      if (_upload && _policy == null && !_loadingPolicy)
        marketButton('重新读取限制', _loadPolicy),
      if (_inspection != null) ...[
        const SizedBox(height: 18),
        SelectableText(
          '固定来源：${_inspection!['commit'] ?? _inspection!['archive_sha256'] ?? '见检查记录'}',
        ),
        if ((_inspection!['candidates'] as List? ?? []).isEmpty)
          const Text('没有找到符合格式的技能或技能型插件。'),
        for (final candidate
            in (_inspection!['candidates'] as List? ?? []).whereType<Map>())
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: marketLine)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${candidate['name']} · ${candidate['status'] == 'supported'
                      ? '可安装'
                      : candidate['status'] == 'partial'
                      ? '部分支持'
                      : '暂不支持'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(candidate['description']?.toString() ?? ''),
                for (final warning in candidate['warnings'] as List? ?? [])
                  Text(
                    warning.toString(),
                    style: const TextStyle(color: marketMuted, height: 1.6),
                  ),
                for (final component
                    in (candidate['components'] as List? ?? [])
                        .whereType<Map>())
                  Text(
                    '${component['name']}：${component['status'] == 'supported' ? '格式支持，任务效果未验证' : (component['issues'] as List? ?? []).join('；')}',
                    style: const TextStyle(color: marketMuted, height: 1.6),
                  ),
                const SizedBox(height: 10),
                marketButton(
                  widget.forEditor
                      ? '导入'
                      : candidate['status'] == 'partial'
                      ? '仅安装支持的技能'
                      : widget.update == null
                      ? _upload && widget.skill && candidate['kind'] == 'skill'
                            ? '在编辑器中查看'
                            : '安装'
                      : '更新',
                  _busy ||
                          candidate['status'] == 'unsupported' ||
                          widget.forEditor &&
                              (candidate['kind'] != 'skill' ||
                                  candidate['status'] != 'supported')
                      ? null
                      : () => _install(candidate),
                  primary: true,
                ),
              ],
            ),
          ),
      ],
    ],
    actions: [
      marketButton('取消', _busy && _jobId == null ? null : _cancel),
      marketButton(
        _busy
            ? '正在处理…'
            : _inspection == null
            ? '开始检查'
            : '重新检查',
        _busy || _loadingPolicy || _upload && _file == null ? null : _inspect,
        primary: true,
      ),
    ],
  );
}

class _McpConnectionDialog extends StatefulWidget {
  const _McpConnectionDialog({this.connection});
  final McpConnectionRecord? connection;
  @override
  State<_McpConnectionDialog> createState() => _McpConnectionDialogState();
}

class _McpConnectionDialogState extends State<_McpConnectionDialog> {
  final _name = TextEditingController(),
      _url = TextEditingController(),
      _token = TextEditingController();
  String? _error, _result;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _name.text = widget.connection?.name ?? '';
    _url.text = widget.connection?.url ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.clear();
    _token.dispose();
    super.dispose();
  }

  void _changed(String _) => setState(() {
    _error = null;
    _result = null;
  });
  Future<void> _submit({required bool test}) async {
    final uri = Uri.tryParse(_url.text.trim());
    if (_name.text.trim().isEmpty ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      setState(() => _error = '填写名称和有效的 HTTPS 服务器地址，不要在地址中包含密码。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      // Null preserves an existing stored token; a newly typed token stays in this form only.
      final token = _token.text.trim().isEmpty ? null : _token.text.trim();
      if (test) {
        final result = await CapabilityCloudSync.instance
            .testMcpConnectionDraft(
              id: widget.connection?.id,
              name: _name.text.trim(),
              url: uri.toString(),
              bearerToken: token,
            );
        if (mounted)
          setState(
            () => _result =
                '连接成功 · ${result['tool_count'] ?? result['tools_count'] ?? '已取得'} 个工具（尚未保存）',
          );
      } else {
        await CapabilityCloudSync.instance.saveMcpConnection(
          id: widget.connection?.id,
          name: _name.text.trim(),
          url: uri.toString(),
          bearerToken: token,
        );
        if (mounted) Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '${test ? '测试' : '保存'}失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MarketDialog(
    title: widget.connection == null ? '添加自定义 MCP 服务器' : '连接设置',
    moveWithKeyboard: true,
    canClose: !_busy,
    children: [
      const Text(
        '连接你信任的 MCP 服务器，让小七使用其中的工具。',
        style: TextStyle(color: marketMuted, height: 1.65),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _name,
        enabled: !_busy,
        autofocus: false,
        onChanged: _changed,
        decoration: const InputDecoration(
          labelText: '名称',
          hintText: '例如：我的资料库',
        ),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _url,
        enabled: !_busy,
        onChanged: _changed,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: '服务器地址',
          hintText: 'https://example.com/mcp',
          helperText: '使用 HTTPS 连接远程服务器',
        ),
      ),
      TextField(
        controller: _token,
        enabled: !_busy,
        onChanged: _changed,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: '访问令牌 · 可选',
          hintText: widget.connection?.hasBearerToken == true
              ? '留空保留已保存的令牌'
              : '仅在服务器需要时填写',
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA52B25), height: 1.65),
          ),
        ),
      if (_result != null)
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Semantics(
            liveRegion: true,
            child: Text(_result!, style: const TextStyle(height: 1.65)),
          ),
        ),
      const SizedBox(height: 20),
      const Text(
        '仅连接可信的服务器。测试连接不会保存；保存后，按任务确认需要访问的数据。',
        style: TextStyle(fontSize: 12, color: marketMuted, height: 1.7),
      ),
    ],
    actions: [
      marketButton(
        _busy ? '正在处理…' : '测试连接',
        _busy ? null : () => _submit(test: true),
      ),
      marketButton('取消', _busy ? null : () => Navigator.pop(context)),
      marketButton(
        widget.connection == null ? '添加' : '保存',
        _busy ? null : () => _submit(test: false),
        primary: true,
      ),
    ],
  );
}
