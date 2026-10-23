import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/capability_cloud_sync.dart';
import '../data/capability_models.dart';
import '../data/capability_store.dart';
import '../../../widgets/app_toast.dart';
import '../../../services/ai_service.dart';
import 'market_ui.dart';
import 'skill_presentation.dart';

/// Called only after the server has checked these exact bytes and archive root.
CapabilityDraft skillDraftFromUpload({
  required String fileName,
  required List<int> bytes,
  required String root,
  required Map<String, dynamic> policy,
}) {
  final files = <String, String>{};
  String content;
  if (fileName.toLowerCase().endsWith('.md')) {
    content = utf8.decode(bytes);
  } else {
    final lower = fileName.toLowerCase();
    final archive = lower.endsWith('.tgz') || lower.endsWith('.tar.gz')
        ? TarDecoder().decodeBytes(
            GZipDecoder().decodeBytes(bytes, verify: true),
            verify: true,
          )
        : ZipDecoder().decodeBytes(bytes, verify: true);
    final prefix = root.isEmpty || root == '.'
        ? ''
        : '${root.replaceAll(RegExp(r'/+$'), '')}/';
    var total = 0;
    final maxFiles = (policy['max_files'] as num).toInt();
    final maxFile = (policy['max_file_bytes'] as num).toInt();
    final maxTotal = (policy['max_expanded_bytes'] as num).toInt();
    for (final file in archive.files) {
      if (!file.name.startsWith(prefix)) continue;
      if (file.isSymbolicLink) throw const FormatException('技能包不能包含链接文件');
      if (!file.isFile) continue;
      final path = file.name.substring(prefix.length);
      if (path.isEmpty ||
          path.startsWith('/') ||
          RegExp(r'[\\:\x00-\x1f]').hasMatch(path) ||
          path.split('/').any((p) => p.isEmpty || p == '.' || p == '..'))
        throw const FormatException('技能包包含不安全的路径');
      total += file.size;
      if (file.size > maxFile ||
          total > maxTotal ||
          files.length >= maxFiles ||
          files.containsKey(path))
        throw const FormatException('技能包超过文件限制或包含重复路径');
      final data = file.readBytes();
      if (data == null || data.length != file.size)
        throw const FormatException('技能包文件内容不完整');
      files[path] = base64Encode(data);
    }
    final main = files.remove('SKILL.md');
    if (main == null) throw const FormatException('所选技能没有 SKILL.md');
    content = utf8.decode(base64Decode(main));
  }
  final match = RegExp(
    r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
  ).firstMatch(content);
  if (match == null) throw const FormatException('SKILL.md 缺少 YAML 信息');
  final metadata = loadYaml(match.group(1)!);
  if (metadata is! Map ||
      metadata['name'] is! String ||
      metadata['description'] is! String)
    throw const FormatException('技能缺少名称或描述');
  return CapabilityDraft(
    id: CapabilityStore.instance.newDraftId(),
    name: metadata['name'] as String,
    description: metadata['description'] as String,
    content: content,
    files: files,
    updatedAt: DateTime.now(),
  );
}

/// Account-scoped authoring with local drafts and checked content imports.
class MarketSkillEditor extends StatefulWidget {
  const MarketSkillEditor({
    this.draft,
    this.record,
    this.onImport,
    this.openImportOnStart = false,
    this.kind = CapabilityKind.skill,
    this.contentBuilder,
    this.cloud,
    super.key,
  });
  final CapabilityKind kind;
  final CapabilityDraft? draft;
  final CapabilityRecord? record;
  final Future<CapabilityDraft?> Function(BuildContext)? onImport;
  final bool openImportOnStart;
  final CapabilityCloudSync? cloud;
  final Widget Function(
    BuildContext,
    ValueChanged<CapabilityDraft>,
    ValueChanged<bool>,
  )?
  contentBuilder;
  @override
  State<MarketSkillEditor> createState() => _MarketSkillEditorState();
}

class _MarketSkillEditorState extends State<MarketSkillEditor> {
  int _step = 0;
  bool _importBusy = false;
  bool get _locked => _busy || _testingMcp || _importBusy || _assisting;
  String? _focus;
  bool _descriptionExpanded = false, _imagesExpanded = false;
  String _imageLayout = 'horizontal';
  final _mcpUrl = TextEditingController(), _mcpToken = TextEditingController();
  bool _mcpExpanded = false, _testingMcp = false;
  String? _mcpResult, _mcpError, _privateConnectionId;
  final Map<String, double> _imageRatios = {};
  final _aiRequest = TextEditingController();
  final List<Map<String, String>> _aiHistory = [];
  Map<String, dynamic>? _aiProposal;
  String? _aiQuestion;
  bool _assisting = false;
  int _aiGeneration = 0;
  final _name = TextEditingController(),
      _description = TextEditingController(),
      _body = TextEditingController();
  final _title = TextEditingController(),
      _introduction = TextEditingController();
  final List<Map<String, dynamic>> _images = [];
  Map<String, dynamic> _icon = {'icon_asset': 'research', 'icon_data': ''};
  CapabilityRecord? _record;
  bool _draftConflict = false;
  CapabilityDraft? _remoteDraft;
  final _store = CapabilityStore.instance;
  late final _cloud = widget.cloud ?? CapabilityCloudSync.instance;
  final _scaffold = GlobalKey<ScaffoldState>();
  late CapabilityDraft _base;
  bool _importDialogOpen = false;
  Animation<double>? _entryAnimation;
  bool get _isPlugin => _base.kind == CapabilityKind.plugin;
  String get _kindLabel => _isPlugin ? '插件' : '技能';
  String get _mainFile => !_isPlugin
      ? 'SKILL.md'
      : const [
          'plugin.json',
          '.claude-plugin/plugin.json',
          '.codex-plugin/plugin.json',
        ].firstWhere(_files.containsKey, orElse: () => 'plugin.json');
  final Map<String, String> _files = {};
  Map<String, dynamic> _metadata = {};
  String _active = 'SKILL.md';
  bool _dirty = false,
      _busy = false,
      _allowPop = false,
      _ready = false,
      _syncFailed = false;
  String? _error, _sourceError;
  static const _maxFiles = 128,
      _maxFileBytes = 2 * 1024 * 1024,
      _maxTotalBytes = 2 * 1024 * 1024;
  static final _frontmatter = RegExp(
    r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
  );
  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _record = record;
    _base =
        widget.draft ??
        CapabilityDraft(
          id: _store.newDraftId(),
          kind: record?.kind ?? widget.kind,
          name: record?.name ?? '',
          description: record?.description ?? '',
          content: record?.currentVersion?.content ?? '',
          files: record?.currentVersion?.files ?? {},
          targetCapabilityId: record?.id,
          presentation: record?.presentation ?? const {},
          updatedAt: DateTime.now(),
        );
    _applyDraft(_base);
    for (final controller in [
      _name,
      _description,
      _body,
      _title,
      _introduction,
    ])
      controller.addListener(_changed);
    unawaited(_restoreDraft());
    if (widget.openImportOnStart && widget.contentBuilder == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final animation = ModalRoute.of(context)?.animation;
        if (animation == null || animation.isCompleted) {
          unawaited(_importContent());
        } else {
          _entryAnimation = animation;
          animation.addStatusListener(_onEntryStatus);
        }
      });
    }
  }

  void _onEntryStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    _entryAnimation = null;
    if (mounted) unawaited(_importContent());
  }

  void _applyDraft(CapabilityDraft draft) {
    _ready = false;
    _base = draft;
    _name.text = _base.name;
    _description.text = _base.description;
    _title.text = _base.presentation['title']?.toString() ?? _base.name;
    _introduction.text = _base.presentation['introduction']?.toString() ?? '';
    _icon = {
      'icon_asset':
          _base.presentation['icon_asset'] ??
          (_isPlugin ? 'extension' : 'research'),
      'icon_data': _base.presentation['icon_data'] ?? '',
    };
    _images
      ..clear()
      ..addAll(
        (_base.presentation['images'] as List? ?? []).whereType<Map>().map(
          (e) => Map<String, dynamic>.from(e),
        ),
      );
    _imageLayout = _base.presentation['image_layout'] == 'grid'
        ? 'grid'
        : 'horizontal';
    for (final image in _images) {
      unawaited(_measureImage(image['data']?.toString() ?? ''));
    }
    _files.clear();
    _metadata = {};
    _sourceError = null;
    _files.addAll(_base.files);
    _active = _mainFile;
    if (_isPlugin) {
      final text = _base.content.isNotEmpty
          ? _base.content
          : const JsonEncoder.withIndent('  ').convert({
              r'$schema':
                  'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
              'name': _identifier,
              'description': _base.description,
            });
      _files[_mainFile] = base64Encode(utf8.encode(text));
      _body.text = text;
      _restoreMcpFields();
      _ready = true;
      return;
    }
    _files.remove('SKILL.md');
    var text = _base.content;
    final match = _frontmatter.firstMatch(text);
    if (match != null) {
      try {
        final parsed = loadYaml(match.group(1)!);
        if (parsed is! Map) throw const FormatException('技能元数据不是对象');
        _metadata = {
          for (final entry in parsed.entries) entry.key.toString(): entry.value,
        };
        text = text.substring(match.end);
      } catch (error) {
        _sourceError = _error = '无法解析原始元数据，请返回并检查源文件：$error';
      }
    }
    _files['SKILL.md'] = base64Encode(utf8.encode(text));
    _body.text = text;
    _ready = true;
  }

  Future<void> _restoreDraft() async {
    final owner = await _cloud.signedInEmail;
    if (!mounted) return;
    if (_base.cloudOwnerEmail != null && _base.cloudOwnerEmail != owner) {
      setState(() => _sourceError = _error = '这份草稿属于其他账号，请切换到原账号');
      return;
    }
    final candidates = await _store.authoringDrafts(owner);
    if (!mounted || _dirty) return;
    final saved = candidates
        .where(
          (d) => widget.record != null
              ? d.targetCapabilityId == widget.record!.id
              : d.id == _base.id,
        )
        .firstOrNull;
    setState(
      () => _applyDraft((saved ?? _base).copyWith(cloudOwnerEmail: owner)),
    );
    final token = await _store.draftMcpToken(_base, url: _mcpUrl.text.trim());
    if (mounted && !_dirty && token != null) _mcpToken.text = token;
  }

  String get _identifier =>
      RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(_name.text) &&
          _name.text.length <= 64
      ? _name.text
      : 'skill-${_base.id.replaceAll(RegExp(r'[^a-z0-9]'), '').substring(0, _base.id.replaceAll(RegExp(r'[^a-z0-9]'), '').length.clamp(0, 32).toInt())}';

  Map<String, dynamic> get _presentation => {
    ..._icon,
    'title': _title.text.trim(),
    'introduction': _introduction.text.trim(),
    'images': _images.map((e) => Map<String, dynamic>.from(e)).toList(),
    'image_layout': _imageLayout,
  };

  void _changed() {
    if (_ready && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _aiRequest.dispose();
    _mcpUrl.dispose();
    _mcpToken.clear();
    _mcpToken.dispose();
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    for (final controller in [
      _name,
      _description,
      _body,
      _title,
      _introduction,
    ]) {
      controller.removeListener(_changed);
      controller.dispose();
    }
    super.dispose();
  }

  void _flush() {
    if (_textFile(_active))
      _files[_active] = base64Encode(utf8.encode(_body.text));
  }

  bool _textFile(String path) => RegExp(
    r'\.(md|txt|json|ya?ml|py|js|ts|csv|html|css|xml|sh)$',
    caseSensitive: false,
  ).hasMatch(path);
  bool _safePath(String name) =>
      name.isNotEmpty &&
      name.length <= 240 &&
      !name.startsWith('/') &&
      !name.endsWith('/') &&
      !RegExp(r'[\\:\x00-\x1f]').hasMatch(name) &&
      name
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');
  String? get _validation {
    if (_sourceError != null) return _sourceError;
    if (widget.record?.isServerInstallation == true)
      return '已安装的第三方扩展不能覆盖为作者作品，请使用检查更新。';
    if (_title.text.trim().isEmpty || _title.text.length > 128)
      return '填写 1–128 字符的展示名称，可以使用中文。';
    if (_name.text.isNotEmpty &&
        (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(_name.text) ||
            _name.text.length > 64))
      return '技能内部标识需使用 1–64 位小写字母、数字和单个连字符。';
    if (_description.text.trim().isEmpty || _description.text.length > 500)
      return '填写 1–500 字符的描述。';
    if (_isPlugin) {
      try {
        final content = _active == _mainFile
            ? _body.text
            : utf8.decode(base64Decode(_files[_mainFile]!));
        if (jsonDecode(content) is! Map) return '插件清单必须是 JSON 对象。';
      } catch (_) {
        return '请修正插件清单的 JSON 格式，草稿内容已保留。';
      }
      return null;
    }
    final content = _active == 'SKILL.md'
        ? _body.text
        : utf8.decode(base64Decode(_files['SKILL.md']!));
    if (content.trim().isEmpty) return 'SKILL.md 内容不能为空。';
    if (utf8.encode(_body.text).length > _maxFileBytes) return '单个文件不能超过 2 MB。';
    return null;
  }

  CapabilityDraft _snapshot() {
    if (_sourceError != null) throw FormatException(_sourceError!);
    _flush();
    _writeMcpDeclaration();
    _checkIncoming({});
    if (_isPlugin) {
      var content = utf8.decode(base64Decode(_files[_mainFile]!));
      try {
        final manifest = Map<String, dynamic>.from(jsonDecode(content) as Map);
        manifest['name'] = _identifier;
        manifest['description'] = _description.text.trim();
        content = const JsonEncoder.withIndent('  ').convert(manifest);
      } catch (_) {
        /* Keep an unfinished manifest editable in its private draft. */
      }
      return _base.copyWith(
        name: _identifier,
        description: _description.text.trim(),
        content: content,
        files: {..._files, _mainFile: base64Encode(utf8.encode(content))},
        updatedAt: DateTime.now(),
        presentation: _presentation,
      );
    }
    final metadata = {
      ..._metadata,
      'name': _identifier,
      'description': _description.text.trim(),
    };
    // JSON scalar/collection values are valid YAML and retain unknown metadata.
    final header = metadata.entries
        .map(
          (entry) =>
              '${RegExp(r"^[a-zA-Z_][a-zA-Z0-9_-]*$").hasMatch(entry.key) ? entry.key : jsonEncode(entry.key)}: ${jsonEncode(entry.value)}',
        )
        .join('\n');
    final content =
        '---\n$header\n---\n\n${utf8.decode(base64Decode(_files['SKILL.md']!))}';
    final attachments = Map<String, String>.from(_files)..remove('SKILL.md');
    return _base.copyWith(
      name: _identifier,
      description: _description.text.trim(),
      content: content,
      files: attachments,
      updatedAt: DateTime.now(),
      presentation: _presentation,
    );
  }

  Future<void> _save() async {
    await _persistDraft(sync: true);
  }

  Future<bool> _persistDraft({bool sync = false}) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _base = _snapshot().copyWith(cloudOwnerEmail: await _cloud.signedInEmail);
      if (_mcpToken.text.trim().isNotEmpty) {
        await _store.saveDraftMcpToken(
          _base,
          _mcpToken.text.trim(),
          url: _mcpUrl.text.trim(),
        );
      }
      await _store.saveAuthoringDraft(_base);
      if (!mounted) return true;
      setState(() => _dirty = false);
      if (sync && await _cloud.hasEmailSession) {
        try {
          if (_isPlugin && _mcpUrl.text.trim().isNotEmpty) {
            final connections = await _cloud.listMcpConnections();
            final existing = connections
                .where(
                  (c) => c.url == _mcpUrl.text.trim() && c.catalogId == null,
                )
                .firstOrNull;
            _privateConnectionId = existing?.id;
            if (existing == null || _mcpToken.text.trim().isNotEmpty) {
              final connection = await _cloud.saveMcpConnection(
                id: _privateConnectionId,
                name: _title.text.trim().isEmpty
                    ? Uri.parse(_mcpUrl.text.trim()).host
                    : _title.text.trim(),
                url: _mcpUrl.text.trim(),
                bearerToken: _mcpToken.text.trim().isEmpty
                    ? null
                    : _mcpToken.text.trim(),
                icon: _icon,
              );
              _privateConnectionId = connection.id;
            }
            _mcpToken.clear();
            await _store.clearDraftMcpToken(_base);
          }
          final sent = _base;
          final remote = await _cloud.syncAuthoringDraft(sent);
          _base = await _store.applySyncedAuthoringDraft(sent, remote);
          if (mounted)
            setState(() {
              _syncFailed = false;
              _draftConflict = false;
              _remoteDraft = null;
            });
        } catch (error) {
          if (mounted)
            setState(() {
              _syncFailed = true;
              _draftConflict = error is SkillDraftConflict;
              _remoteDraft = error is SkillDraftConflict ? error.remote : null;
              _error = '草稿已保存在本机，同步未完成：$error';
            });
          return true;
        }
      }
      if (mounted && sync) AppToast.show(context, '草稿已保存');
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败，编辑内容已保留：$error');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importContent() async {
    if (_busy || _importDialogOpen || widget.onImport == null) return;
    if (mounted) setState(() => _importDialogOpen = true);
    CapabilityDraft? incoming;
    try {
      incoming = await widget.onImport!(context);
    } finally {
      if (mounted) setState(() => _importDialogOpen = false);
    }
    if (incoming != null) await _applyIncoming(incoming);
  }

  Future<void> _applyIncoming(CapabilityDraft incoming) async {
    final imported = incoming;
    if (!mounted) return;
    if (imported.kind != _base.kind) {
      AppToast.show(context, '请选择${_kindLabel}文件，当前草稿已保留');
      return;
    }
    if (_base.content.trim().isNotEmpty ||
        _title.text.trim().isNotEmpty ||
        (_dirty && _body.text.trim().isNotEmpty)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => MarketDialog(
          title: '替换当前${_kindLabel}内容？',
          children: [
            Text(
              imported.presentation.containsKey('icon_asset')
                  ? '导入会替换名称、图标、简介和${_kindLabel}文件。详细介绍和介绍图片会保留。'
                  : '导入会替换名称、简介和${_kindLabel}文件。已有图标、详细介绍和介绍图片会保留。',
            ),
          ],
          actions: [
            marketDialogButton('取消', () => Navigator.pop(ctx, false)),
            marketDialogButton(
              '确认替换',
              () => Navigator.pop(ctx, true),
              primary: true,
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    final current = _presentation;
    setState(() {
      _applyDraft(
        _base.copyWith(
          name: imported.name,
          description: imported.description,
          content: imported.content,
          files: imported.files,
          presentation: {
            ...current,
            if (imported.presentation.containsKey('icon_asset'))
              'icon_asset': imported.presentation['icon_asset'],
            if (imported.presentation.containsKey('icon_data'))
              'icon_data': imported.presentation['icon_data'],
            'title': imported.presentation['title'] ?? imported.name,
          },
        ),
      );
      _dirty = true;
      _error = null;
    });
  }

  Future<void> _changeIcon() async {
    final icon = await chooseSkillIcon(
      context,
      _icon,
      defaultAsset: _isPlugin ? 'extension' : 'research',
    );
    if (icon != null && mounted)
      setState(() {
        _icon = icon;
        _dirty = true;
      });
  }

  Future<void> _addImage() async {
    if (_images.length >= 6) {
      AppToast.show(context, '介绍图片最多 6 张');
      return;
    }
    try {
      final data = await pickSkillPresentationImage();
      if (data != null) await _measureImage(data);
      if (data != null && mounted)
        setState(() {
          _images.add({'data': data, 'caption': ''});
          _dirty = true;
        });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _retrySync() async {
    setState(() => _busy = true);
    try {
      final sent = _base;
      final remote = await _cloud.syncAuthoringDraft(sent);
      _base = await _store.applySyncedAuthoringDraft(sent, remote);
      if (mounted)
        setState(() {
          _error = null;
          _syncFailed = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = '同步失败：$error';
          _draftConflict = error is SkillDraftConflict;
          _remoteDraft = error is SkillDraftConflict ? error.remote : null;
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_locked) return;
    if (_dirty && !await _persistDraft(sync: _mcpToken.text.trim().isNotEmpty))
      return;
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  Future<void> _saveConflictCopy() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final current = _snapshot();
      final copy = CapabilityDraft(
        id: _store.newDraftId(),
        kind: current.kind,
        name: current.name,
        description: current.description,
        content: current.content,
        files: current.files,
        presentation: current.presentation,
        cloudOwnerEmail: current.cloudOwnerEmail,
        updatedAt: DateTime.now(),
      );
      await _store.saveAuthoringDraft(copy);
      final remote = _remoteDraft;
      if (remote != null) await _store.saveAuthoringDraft(remote);
      if (!mounted) return;
      setState(() {
        _applyDraft(copy);
        _record = null;
        _dirty = false;
        _syncFailed = false;
        _draftConflict = false;
        _remoteDraft = null;
        _error = null;
      });
      AppToast.show(context, '本机修改已另存为新草稿，云端原版本保留');
    } catch (error) {
      if (mounted) setState(() => _error = '另存失败，编辑内容仍保留：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectFile(String path, {bool drawer = false}) {
    _flush();
    _ready = false;
    setState(() {
      _active = path;
      _body.text = _textFile(path)
          ? utf8.decode(base64Decode(_files[path]!), allowMalformed: false)
          : '';
    });
    _ready = true;
    if (drawer) Navigator.pop(context);
  }

  Future<void> _newFile() async {
    final controller = TextEditingController();
    String? error;
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) => MarketDialog(
          title: '新建文本文件',
          children: [
            TextField(
              controller: controller,
              autofocus: false,
              decoration: InputDecoration(
                labelText: '文件名',
                hintText: '例如：references/notes.md',
                errorText: error,
              ),
            ),
          ],
          actions: [
            marketDialogButton('取消', () => Navigator.pop(ctx)),
            marketDialogButton('创建', () {
              final name = controller.text.trim();
              if (!_safePath(name) ||
                  !_textFile(name) ||
                  _files.containsKey(name) ||
                  _files.length >= _maxFiles) {
                update(() => error = '使用未占用的相对文本文件路径，最多 128 个文件。');
                return;
              }
              Navigator.pop(ctx, name);
            }, primary: true),
          ],
        ),
      ),
    );
    controller.dispose();
    if (path == null || !mounted) return;
    setState(() {
      _files[path] = '';
      _dirty = true;
    });
    _selectFile(path);
  }

  Future<void> _addFiles({bool directory = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, List<int>> incoming = {};
      if (directory) {
        final path = await FilePicker.getDirectoryPath();
        if (path == null) return;
        final root = Directory(path).absolute.path;
        await for (final entity in Directory(
          root,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.path
              .substring(root.length + 1)
              .replaceAll('\\', '/');
          if (!_safePath(name)) throw const FormatException('文件夹包含不安全的路径');
          final length = await entity.length();
          if (length > _maxFileBytes)
            throw const FormatException('单个附件不能超过 2 MB');
          incoming[name] = await entity.readAsBytes();
          _checkIncoming(incoming);
        }
      } else {
        final result = await FilePicker.pickFiles();
        if (result.isEmpty) return;
        for (final file in result) {
          final length = await file.length();
          if (!_safePath(file.name) || length == null || length > _maxFileBytes)
            throw const FormatException('附件路径无效或超过 2 MB');
          incoming[file.name] = await file.readAsBytes();
          _checkIncoming(incoming);
        }
      }
      if (incoming.isEmpty || !mounted) return;
      // The main file is edited in place; package replacement uses checked import.
      if (incoming.containsKey(_mainFile))
        throw FormatException('请在正文中编辑 $_mainFile，附件上传不会覆盖主文件');
      final duplicates = incoming.keys.where(_files.containsKey).toList();
      if (duplicates.isNotEmpty) {
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => MarketDialog(
            title: '替换同名附件？',
            children: [Text(duplicates.join('\n'))],
            actions: [
              marketDialogButton('取消', () => Navigator.pop(ctx)),
              marketDialogButton(
                '替换',
                () => Navigator.pop(ctx, true),
                primary: true,
              ),
            ],
          ),
        );
        if (overwrite != true) return;
      }
      if (!mounted) return;
      setState(() {
        for (final entry in incoming.entries)
          _files[entry.key] = base64Encode(entry.value);
        _dirty = true;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '未添加文件：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _checkIncoming(Map<String, List<int>> incoming) {
    if ({..._files.keys, ...incoming.keys}.length > _maxFiles ||
        incoming.values.any((b) => b.length > _maxFileBytes))
      throw const FormatException('最多 128 个文件，单文件最多 2 MB');
    final total =
        incoming.values.fold<int>(0, (sum, bytes) => sum + bytes.length) +
        _files.entries
            .where((entry) => !incoming.containsKey(entry.key))
            .fold<int>(
              0,
              (sum, entry) => sum + base64Decode(entry.value).length,
            );
    if (total > _maxTotalBytes)
      throw const FormatException('技能附件总大小不能超过 10 MB');
    for (final entry in incoming.entries) {
      if (_textFile(entry.key)) utf8.decode(entry.value, allowMalformed: false);
    }
  }

  Future<void> _download() async {
    try {
      final draft = _snapshot();
      final bytes = utf8.encode(draft.content);
      final result = await FilePicker.saveFile(
        dialogTitle: '下载 $_mainFile',
        fileName: _mainFile.split('/').last,
        bytes: Uint8List.fromList(bytes),
      );
      if (result != null && mounted)
        AppToast.show(context, '已导出 $_mainFile（其他文件需单独保留）');
    } catch (error) {
      if (mounted) AppToast.show(context, '导出失败：$error');
    }
  }

  Widget _filePanel({bool drawer = false}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '文件',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            PopupMenuButton<String>(
              position: PopupMenuPosition.under,
              offset: const Offset(0, 8),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              tooltip: '添加文件',
              enabled: !_busy,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: marketLine),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    marketIcon('paperclip', size: 18),
                    const SizedBox(width: 8),
                    const Text('上传'),
                  ],
                ),
              ),
              color: Colors.white,
              onSelected: (action) {
                if (drawer) Navigator.pop(context);
                switch (action) {
                  case 'new':
                    unawaited(_newFile());
                  case 'file':
                    unawaited(_addFiles());
                  case 'folder':
                    unawaited(_addFiles(directory: true));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'new', child: Text('新建文本文件')),
                const PopupMenuItem(value: 'file', child: Text('上传文件')),
                const PopupMenuItem(value: 'folder', child: Text('上传文件夹')),
              ],
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          children: _files.keys
              .map(
                (path) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: path == _active ? const Color(0xFFF0F0F0) : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          dense: true,
                          onTap: _busy
                              ? null
                              : () => _selectFile(path, drawer: drawer),
                          leading: marketIcon('file-text', size: 20),
                          title: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (path != _mainFile)
                        IconButton(
                          tooltip: '删除 $path',
                          onPressed: _busy
                              ? null
                              : () {
                                  if (_active == path) _selectFile(_mainFile);
                                  setState(() {
                                    _files.remove(path);
                                    _dirty = true;
                                  });
                                },
                          icon: marketIcon('close', size: 15),
                        ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
      if (drawer) marketButton('返回编辑', () => Navigator.pop(context)),
    ],
  );
  Widget _fileWorkspace(bool phone) => ListView(
    padding: EdgeInsets.all(phone ? 20 : 28),
    children: [
      if (phone)
        Align(
          alignment: Alignment.centerLeft,
          child: marketButton(
            _active,
            () => _scaffold.currentState!.openDrawer(),
            icon: 'folder',
          ),
        ),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: marketLine),
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: '${_kindLabel}内部标识',
                hintText: _isPlugin ? 'your-plugin-name' : 'your-skill-name',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _description,
              enabled: !_busy,
              maxLength: 500,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: '${_kindLabel}用途说明',
                hintText: '描述该${_kindLabel}的用途',
              ),
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA52B25), height: 1.65),
          ),
        ),
      if (_syncFailed) marketButton('重试同步', _busy ? null : _retrySync),
      if (_draftConflict)
        marketButton('将本机修改另存为新草稿', _busy ? null : _saveConflictCopy),
      if (_dirty && _validation != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _validation!,
            style: const TextStyle(
              color: marketMuted,
              fontSize: 13,
              height: 1.65,
            ),
          ),
        ),
      const SizedBox(height: 22),
      Row(
        children: [
          Expanded(
            child: Text(
              _active,
              style: const TextStyle(fontSize: 12, color: marketMuted),
            ),
          ),
          marketIconButton('download', '导出主文件', _busy ? null : _download),
          if (_dirty)
            const Text(
              '尚未保存',
              style: TextStyle(fontSize: 12, color: marketMuted),
            ),
        ],
      ),
      if (_textFile(_active))
        TextField(
          controller: _body,
          enabled: !_busy,
          minLines: phone ? 18 : 24,
          maxLines: null,
          style: const TextStyle(fontSize: 15, height: 1.9),
          decoration: const InputDecoration(
            hintText: '编写技能说明…',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 18),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 80),
          child: Column(
            children: [
              marketIcon('file-text', size: 30),
              const SizedBox(height: 14),
              Text(_active),
              const SizedBox(height: 8),
              const Text('作为附件保留，无法在此编辑', style: TextStyle(color: marketMuted)),
            ],
          ),
        ),
      const Text(
        '名称最多 64 个字符，使用小写字母、数字和单个连字符。附件不会自动执行。',
        style: TextStyle(fontSize: 13, color: marketMuted, height: 1.7),
      ),
    ],
  );
  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: controller,
        enabled: !_busy,
        minLines: lines,
        maxLines: lines == 1 ? 1 : lines + 3,
        style: const TextStyle(fontSize: 16, height: 1.6),
        decoration: InputDecoration(
          filled: true,
          fillColor: marketSoft,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 14,
          ),
        ),
      ),
    ],
  );

  void _restoreMcpFields() {
    _mcpUrl.clear();
    _mcpToken.clear();
    _privateConnectionId = null;
    _mcpResult = _mcpError = null;
    for (final path in ['.mcp.json', 'mcp.json', _mainFile]) {
      try {
        final encoded = _files[path];
        if (encoded == null) continue;
        final config = jsonDecode(utf8.decode(base64Decode(encoded)));
        final servers = config is Map
            ? config['mcpServers'] ?? config['servers']
            : null;
        if (servers is! Map) continue;
        for (final value in servers.values) {
          if (value is Map && value['url'] is String) {
            _mcpUrl.text = value['url'] as String;
            _mcpExpanded = true;
            unawaited(_findPrivateConnection(_mcpUrl.text));
            return;
          }
        }
      } catch (_) {
        // Invalid imported files remain editable; publication validates the package.
      }
    }
  }

  Future<void> _findPrivateConnection(String url) async {
    try {
      final connections = await _cloud.listMcpConnections();
      if (!mounted || _mcpUrl.text != url) return;
      final connection = connections
          .where((c) => c.url == url && c.catalogId == null)
          .firstOrNull;
      if (connection != null)
        setState(() => _privateConnectionId = connection.id);
    } catch (_) {
      // The draft remains available offline; saving retries the account request.
    }
  }

  void _writeMcpDeclaration() {
    if (!_isPlugin || _mcpUrl.text.trim().isEmpty) return;
    // Preserve imported declarations and only update the connection shown here.
    for (final path in ['.mcp.json', 'mcp.json', _mainFile]) {
      final encoded = _files[path];
      if (encoded == null) continue;
      Object? config;
      try {
        config = jsonDecode(utf8.decode(base64Decode(encoded)));
      } on FormatException {
        continue;
      }
      if (config is! Map) continue;
      final servers = config['mcpServers'] ?? config['servers'];
      if (servers is! Map) continue;
      final key = servers.keys
          .where((k) => servers[k] is Map && servers[k]['url'] is String)
          .firstOrNull;
      if (key == null) continue;
      servers[key]['url'] = _mcpUrl.text.trim();
      _files[path] = base64Encode(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(config)),
      );
      if (path == _active) {
        _ready = false;
        _body.text = utf8.decode(base64Decode(_files[path]!));
        _ready = true;
      }
      return;
    }
    _files['.mcp.json'] = base64Encode(
      utf8.encode(
        jsonEncode({
          'mcpServers': {
            'remote': {'type': 'http', 'url': _mcpUrl.text.trim()},
          },
        }),
      ),
    );
  }

  void _mcpChanged(String _) => setState(() {
    _mcpToken.clear();
    _mcpResult = _mcpError = null;
    _dirty = true;
    _privateConnectionId = null;
  });

  Future<void> _testMcp() async {
    if (_testingMcp || _busy) return;
    setState(() {
      _testingMcp = true;
      _mcpResult = _mcpError = null;
    });
    try {
      await _cloud.testMcpConnectionDraft(
        id: _privateConnectionId,
        name: _title.text.trim().isEmpty ? 'MCP' : _title.text.trim(),
        url: _mcpUrl.text.trim(),
        bearerToken: _mcpToken.text.trim().isEmpty
            ? null
            : _mcpToken.text.trim(),
      );
      if (mounted) setState(() => _mcpResult = '连接成功');
    } catch (error) {
      if (mounted) setState(() => _mcpError = '连接失败，请检查地址、访问权限后重试：$error');
    } finally {
      if (mounted) setState(() => _testingMcp = false);
    }
  }

  Future<void> _measureImage(String data) async {
    if (_imageRatios.containsKey(data)) return;
    try {
      final codec = await ui.instantiateImageCodec(
        UriData.parse(data).contentAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          _imageRatios[data] = frame.image.width / frame.image.height;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Keep a visible placeholder for an unreadable legacy image.
    }
  }

  double _ratio(Map<String, dynamic> image) =>
      _imageRatios[image['data']?.toString() ?? ''] ?? .75;

  void _back() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_focus != null) {
      setState(() => _focus = null);
    } else if (_step > 0) {
      setState(() => _step--);
    } else {
      unawaited(_leave());
    }
  }

  Future<void> _next() async {
    if (_locked) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_step == 0) {
      if (_isPlugin && _mcpUrl.text.trim().isNotEmpty) {
        final uri = Uri.tryParse(_mcpUrl.text.trim());
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment) {
          setState(() => _error = '请填写有效的 HTTPS 服务器地址，凭据填写在私有令牌栏。');
          return;
        }
      } else if ((!_isPlugin && _body.text.trim().isEmpty) ||
          (_isPlugin && _files.length <= 1 && _base.content.isEmpty)) {
        setState(() => _error = '先读取内容，或编写${_kindLabel}内容。');
        return;
      }
    } else {
      final validation = _validation;
      if (validation != null) {
        setState(() => _error = validation);
        return;
      }
      if (!await _persistDraft() || !mounted) return;
    }
    setState(() {
      _error = null;
      _step++;
    });
  }

  Future<void> _publishInPlace() async {
    if (_busy || _testingMcp) return;
    final validation = _validation;
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (!await _persistDraft(sync: true) || !mounted) return;
    if (_syncFailed || _draftConflict) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = _base;
      final local = await _store.commitDraft(
        snapshot,
        existingId: snapshot.targetCapabilityId,
      );
      final remote = await _cloud.syncAuthoredSkill(local);
      _record = await _cloud.publishSkill(remote);
      _base = snapshot.copyWith(targetCapabilityId: _record!.id);
      await _store.saveAuthoringDraft(_base);
      if (!mounted) return;
      AppToast.show(context, '${_kindLabel}已发布');
      setState(() => _allowPop = true);
      Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '发布未完成，草稿已保留，可重试：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _assist() async {
    if (_assisting || _aiRequest.text.trim().isEmpty) return;
    final generation = ++_aiGeneration;
    final request = _aiRequest.text.trim();
    setState(() {
      _assisting = true;
      _aiProposal = null;
      _error = null;
    });
    try {
      final proposal = await AiService().assistExtension(
        request: request,
        kind: _kindLabel,
        title: _title.text,
        description: _description.text,
        // Account connections and imported MCP credentials never enter a prompt.
        content: _isPlugin ? '插件文件：${_files.keys.join(', ')}' : _body.text,
        history: _aiHistory,
      );
      if (!mounted || generation != _aiGeneration) return;
      setState(() {
        _aiHistory.addAll([
          {'role': 'user', 'content': request},
          {'role': 'assistant', 'content': jsonEncode(proposal)},
        ]);
        _aiQuestion = proposal['question']?.toString();
        _aiProposal = _aiQuestion == null ? proposal : null;
        _aiRequest.clear();
      });
    } catch (error) {
      if (mounted && generation == _aiGeneration)
        setState(() => _error = 'AI编写未完成，当前草稿未改动：$error');
    } finally {
      if (mounted && generation == _aiGeneration)
        setState(() => _assisting = false);
    }
  }

  Widget _aiAssistance() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(color: marketLine),
      if (_aiQuestion != null) SelectableText(_aiQuestion!),
      TextField(
        controller: _aiRequest,
        enabled: !_assisting && !_busy,
        minLines: 1,
        maxLines: 4,
        decoration: const InputDecoration(labelText: '告诉 AI 你想创建或修改什么'),
      ),
      Wrap(
        spacing: 12,
        children: [
          marketButton(
            _assisting ? 'AI编写中…' : 'AI辅助编写',
            _assisting || _busy ? null : _assist,
          ),
          if (_assisting)
            marketButton(
              '取消编写',
              () => setState(() {
                _aiGeneration++;
                _assisting = false;
              }),
            ),
        ],
      ),
      if (_aiProposal != null) ...[
        const Text('AI建议 · 应用后替换名称、简介和主文件，其他附件保留'),
        SelectableText(
          '${_aiProposal!['title']}\n${_aiProposal!['description']}\n\n${_aiProposal!['content']}',
        ),
        Wrap(
          spacing: 12,
          children: [
            marketButton(
              '应用到当前草稿',
              () => setState(() {
                _flush();
                _title.text = _aiProposal!['title'].toString();
                _description.text = _aiProposal!['description'].toString();
                _active = _mainFile;
                _body.text = _aiProposal!['content'].toString();
                _files[_mainFile] = base64Encode(utf8.encode(_body.text));
                _aiProposal = null;
                _dirty = true;
              }),
              primary: true,
            ),
            marketButton('放弃建议', () => setState(() => _aiProposal = null)),
          ],
        ),
      ],
    ],
  );

  Widget _mcpFields() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('MCP连接配置（创建MCP连接器时须填写）'),
        trailing: marketIcon(_mcpExpanded ? 'caret-up' : 'caret-down'),
        onTap: () => setState(() => _mcpExpanded = !_mcpExpanded),
      ),
      if (_mcpExpanded) ...[
        TextField(
          controller: _mcpUrl,
          enabled: !_testingMcp && !_busy,
          keyboardType: TextInputType.url,
          onChanged: _mcpChanged,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _mcpToken,
          enabled: !_testingMcp && !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (value) {
            setState(() {
              _mcpResult = _mcpError = null;
              _dirty = true;
            });
          },
          decoration: const InputDecoration(
            labelText: '访问令牌 · 仅本人可见',
            hintText: '仅在服务器需要时填写；留空保留已有令牌',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: marketButton(
            _testingMcp ? '测试中…' : '测试连接',
            _testingMcp || _busy ? null : _testMcp,
          ),
        ),
        if (_mcpResult != null || _mcpError != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _mcpError ?? _mcpResult!,
                style: TextStyle(
                  color: _mcpError == null
                      ? marketInk
                      : const Color(0xFFB3261E),
                ),
              ),
            ),
          ),
      ],
    ],
  );

  Widget _information() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          InkWell(
            onTap: _busy ? null : _changeIcon,
            child: Semantics(
              label: '更换图标',
              button: true,
              child: Stack(
                children: [
                  SkillPresentationIcon(_icon, size: 76),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: marketIcon('pencil', size: 18),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(child: _field('名称', _title)),
        ],
      ),
      const SizedBox(height: 24),
      _field('一句话简介', _description, lines: 2),
      const SizedBox(height: 24),
      const Divider(color: marketLine),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('详细介绍（可选）'),
        trailing: marketIcon(_descriptionExpanded ? 'caret-up' : 'caret-down'),
        onTap: () =>
            setState(() => _descriptionExpanded = !_descriptionExpanded),
      ),
      if (_descriptionExpanded) ...[
        SelectableText(
          _introduction.text.isEmpty ? '尚未填写详细介绍' : _introduction.text,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: marketButton(
            '编辑详细介绍',
            () => setState(() => _focus = 'description'),
            icon: 'pencil',
          ),
        ),
      ],
      const Divider(color: marketLine),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('介绍图片（可选）'),
        trailing: marketIcon(_imagesExpanded ? 'caret-up' : 'caret-down'),
        onTap: () => setState(() => _imagesExpanded = !_imagesExpanded),
      ),
      if (_imagesExpanded) ...[
        if (_images.isEmpty)
          const Text('尚未添加介绍图片', style: TextStyle(color: marketMuted))
        else
          SkillPresentationGallery(images: _images, layout: _imageLayout),
        Align(
          alignment: Alignment.centerLeft,
          child: marketButton(
            '编辑／上传图片',
            () => setState(() => _focus = 'images'),
            icon: 'pencil',
          ),
        ),
      ],
    ],
  );

  Widget _gallery({required bool editing}) => LayoutBuilder(
    builder: (context, box) {
      final grid = _imageLayout == 'grid';
      final height = box.maxWidth < 400 ? 200.0 : 280.0;
      final columns = box.maxWidth < 320 ? 1 : 2;
      final width = grid ? (box.maxWidth - (columns - 1) * 16) / columns : null;
      Widget tile(int index) {
        final add = index == _images.length;
        final ratio = _images.isEmpty
            ? .75
            : _ratio(_images[add ? index - 1 : index]);
        final imageWidth = width ?? height * ratio;
        final imageHeight = width == null ? height : imageWidth / ratio;
        final picture = SizedBox(
          width: imageWidth,
          height: imageHeight,
          child: add
              ? InkWell(
                  onTap: _busy ? null : _addImage,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: SvgPicture.asset(
                          '${marketAssets}detail/upload-border.svg',
                          fit: BoxFit.fill,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          marketIcon('plus', size: 28),
                          const SizedBox(height: 8),
                          const Text('添加图片'),
                        ],
                      ),
                    ],
                  ),
                )
              : skillDataImage(_images[index]['data']?.toString() ?? ''),
        );
        return SizedBox(
          width: imageWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              picture,
              if (editing && !add) ...[
                Row(
                  children: [
                    if (!grid)
                      ReorderableDragStartListener(
                        index: index,
                        enabled: !_busy,
                        child: Semantics(
                          label: '拖动第 ${index + 1} 张图片排序',
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: marketIcon('dots'),
                          ),
                        ),
                      ),
                    if (grid) ...[
                      marketIconButton(
                        'back',
                        '前移第 ${index + 1} 张图片',
                        index == 0 || _busy
                            ? null
                            : () => _reorderImage(index, index - 1),
                      ),
                      marketIconButton(
                        'arrow-right',
                        '后移第 ${index + 1} 张图片',
                        index == _images.length - 1 || _busy
                            ? null
                            : () => _reorderImage(index, index + 1),
                      ),
                    ],
                    const Spacer(),
                    marketIconButton(
                      'trash-danger',
                      '删除第 ${index + 1} 张图片',
                      _busy
                          ? null
                          : () => setState(() {
                              _images.removeAt(index);
                              _dirty = true;
                            }),
                    ),
                  ],
                ),
                TextFormField(
                  key: ObjectKey(_images[index]),
                  initialValue: _images[index]['caption']?.toString() ?? '',
                  maxLength: 200,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    hintText: '添加图片说明',
                    counterText: '',
                  ),
                  onChanged: (value) {
                    _images[index]['caption'] = value;
                    _dirty = true;
                  },
                ),
              ] else if (!add &&
                  (_images[index]['caption']?.toString() ?? '').isNotEmpty)
                Text(_images[index]['caption'].toString()),
            ],
          ),
        );
      }

      final count = _images.length + (editing && _images.length < 6 ? 1 : 0);
      if (grid) {
        return Wrap(
          spacing: 16,
          runSpacing: 20,
          children: List.generate(count, (i) {
            if (!editing || i == _images.length) return tile(i);
            return LongPressDraggable<int>(
              data: i,
              maxSimultaneousDrags: _busy ? 0 : 1,
              feedback: Material(
                color: Colors.white,
                child: SizedBox(
                  width: 100,
                  height: 134,
                  child: skillDataImage(_images[i]['data']?.toString() ?? ''),
                ),
              ),
              child: DragTarget<int>(
                onWillAcceptWithDetails: (details) =>
                    !_busy && details.data != i,
                onAcceptWithDetails: (details) =>
                    _reorderImage(details.data, i),
                builder: (_, candidates, rejected) => tile(i),
              ),
            );
          }),
        );
      }
      if (!editing) {
        return SizedBox(
          height: height + 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: count,
            separatorBuilder: (_, index) => const SizedBox(width: 16),
            itemBuilder: (_, i) => tile(i),
          ),
        );
      }
      return SizedBox(
        height: height + 116,
        child: ReorderableListView(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          onReorder: (from, to) {
            if (_busy) return;
            if (to > from) to--;
            _reorderImage(from, to);
          },
          footer: _images.length < 6 ? tile(_images.length) : null,
          children: [
            for (var i = 0; i < _images.length; i++)
              Padding(
                key: ObjectKey(_images[i]),
                padding: const EdgeInsets.only(right: 16),
                child: tile(i),
              ),
          ],
        ),
      );
    },
  );

  void _reorderImage(int from, int to) => setState(() {
    _images.insert(to, _images.removeAt(from));
    _dirty = true;
  });

  Widget _layoutMenu() => PopupMenuButton<String>(
    tooltip: '图片布局',
    enabled: !_busy,
    icon: SvgPicture.asset(
      'assets/icons/extensions/gallery-$_imageLayout.svg',
      width: 22,
      height: 22,
    ),
    initialValue: _imageLayout,
    onSelected: (value) => setState(() {
      _imageLayout = value;
      _dirty = true;
    }),
    itemBuilder: (_) => [
      for (final value in ['horizontal', 'grid'])
        CheckedPopupMenuItem(
          value: value,
          checked: value == _imageLayout,
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/icons/extensions/gallery-$value.svg',
                width: 22,
                height: 22,
              ),
              const SizedBox(width: 12),
              Text(value == 'horizontal' ? '横向滚动' : '网格布局'),
            ],
          ),
        ),
    ],
  );

  Widget _creationContent(bool phone) {
    if (_focus == 'description') {
      return TextField(
        controller: _introduction,
        enabled: !_busy,
        expands: true,
        minLines: null,
        maxLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          hintText: '填写详细介绍',
          border: InputBorder.none,
        ),
      );
    }
    if (_focus == 'images') {
      return SingleChildScrollView(child: _gallery(editing: true));
    }
    if (_focus == 'content') {
      return Row(
        children: [
          if (!phone) SizedBox(width: 180, child: _filePanel()),
          Expanded(child: _fileWorkspace(phone)),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_step == 0) ...[
            if (widget.contentBuilder != null)
              widget.contentBuilder!(
                context,
                (draft) => unawaited(_applyIncoming(draft)),
                (busy) {
                  if (mounted) setState(() => _importBusy = busy);
                },
              )
            else
              marketButton(
                '导入内容',
                _busy ? null : _importContent,
                icon: 'upload',
              ),
            const SizedBox(height: 16),
            marketButton(
              '编辑${_kindLabel}内容',
              () => setState(() => _focus = 'content'),
              icon: 'edit',
            ),
            if (_isPlugin) _mcpFields(),
            _aiAssistance(),
          ],
          if (_step == 1) _information(),
          if (_step == 2) ...[
            Text(
              (_record?.publishedRevision ?? 0) > 0 ? '修改尚未发布' : '尚未发布',
              style: const TextStyle(color: marketMuted),
            ),
            const SizedBox(height: 20),
            SkillPresentationBody(
              presentation: _presentation,
              name: _title.text,
              description: _description.text,
              kindLabel: _kindLabel,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: marketTheme(context),
    child: PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_locked) _back();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final phone = constraints.maxWidth <= 600;
          final height = (constraints.maxHeight - 48).clamp(0.0, 850.0);
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: SizedBox(
                width: 670,
                height: height,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: Scaffold(
                    key: _scaffold,
                    backgroundColor: Colors.white,
                    resizeToAvoidBottomInset: false,
                    drawer: phone
                        ? Drawer(
                            child: SafeArea(child: _filePanel(drawer: true)),
                          )
                        : null,
                    body: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
                          child: Row(
                            children: [
                              if (_focus != null)
                                marketIconButton(
                                  'back',
                                  '返回资料',
                                  _busy ? null : _back,
                                ),
                              Expanded(
                                child: Text(
                                  _focus == 'description'
                                      ? '详细介绍'
                                      : _focus == 'images'
                                      ? '介绍图片'
                                      : _focus == 'content'
                                      ? '${_kindLabel}内容'
                                      : '创建$_kindLabel',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (_focus == 'images') _layoutMenu(),
                              if (_focus != null)
                                marketButton(
                                  '完成',
                                  _busy ? null : _back,
                                  outlined: false,
                                )
                              else
                                marketIconButton(
                                  'close',
                                  '关闭创建',
                                  _locked ? null : _leave,
                                ),
                            ],
                          ),
                        ),
                        if (_focus == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  const [
                                    '上传文件或从 GitHub 导入内容',
                                    '确认名称与简介，其他资料按需补充',
                                    '确认内容后发布',
                                  ][_step],
                                  style: const TextStyle(color: marketMuted),
                                ),
                                const SizedBox(height: 24),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: (_step + 1) / 3,
                                    minHeight: 5,
                                    color: marketInk,
                                    backgroundColor: marketLine,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    for (var i = 0; i < 3; i++)
                                      Expanded(
                                        child: Text(
                                          const ['添加内容', '补充资料', '确认'][i],
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: i == _step
                                                ? marketInk
                                                : marketMuted,
                                            fontWeight: i == _step
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              24,
                              8,
                              24,
                              MediaQuery.viewInsetsOf(
                                context,
                              ).bottom.clamp(0, height * .65).toDouble(),
                            ),
                            child: _creationContent(phone),
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Color(0xFFB3261E),
                                ),
                              ),
                            ),
                          ),
                        if (_syncFailed)
                          marketButton('重试同步', _busy ? null : _retrySync),
                        if (_draftConflict)
                          marketButton(
                            '将本机修改另存为新草稿',
                            _busy ? null : _saveConflictCopy,
                          ),
                        if (_focus == null) ...[
                          const Divider(height: 1, color: marketLine),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                marketButton(
                                  '上一步',
                                  _step == 0 || _locked ? null : _back,
                                ),
                                if (_step == 2)
                                  marketButton('保存草稿', _busy ? null : _save),
                                marketButton(
                                  _busy
                                      ? '正在处理…'
                                      : _step == 2
                                      ? '确认发布'
                                      : '下一步',
                                  _locked
                                      ? null
                                      : _step == 2
                                      ? _publishInPlace
                                      : _next,
                                  primary: true,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
