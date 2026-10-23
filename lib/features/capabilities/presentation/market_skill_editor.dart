import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

import '../data/capability_cloud_sync.dart';
import '../data/capability_models.dart';
import '../data/capability_store.dart';
import '../../../widgets/app_toast.dart';
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
    this.kind = CapabilityKind.skill,
    super.key,
  });
  final CapabilityKind kind;
  final CapabilityDraft? draft;
  final CapabilityRecord? record;
  final Future<CapabilityDraft?> Function(BuildContext)? onImport;
  @override
  State<MarketSkillEditor> createState() => _MarketSkillEditorState();
}

class _MarketSkillEditorState extends State<MarketSkillEditor> {
  final _name = TextEditingController(),
      _description = TextEditingController(),
      _body = TextEditingController();
  final _title = TextEditingController(),
      _introduction = TextEditingController();
  final List<Map<String, dynamic>> _images = [];
  Map<String, dynamic> _icon = {'icon_asset': 'research', 'icon_data': ''};
  CapabilityRecord? _record;
  bool _contentsExpanded = false;
  bool _draftConflict = false;
  CapabilityDraft? _remoteDraft;
  final _store = CapabilityStore.instance;
  final _cloud = CapabilityCloudSync.instance;
  final _scaffold = GlobalKey<ScaffoldState>();
  late CapabilityDraft _base;
  bool get _isPlugin => _base.kind == CapabilityKind.plugin;
  String get _kindLabel => _isPlugin ? '插件' : '技能';
  String get _mainFile => !_isPlugin
      ? 'SKILL.md'
      : const [
          'plugin.json',
          '.claude-plugin/plugin.json',
          '.codex-plugin/plugin.json',
        ].firstWhere(_files.containsKey, orElse: () => 'plugin.json');
  String get _contentSummary => _isPlugin
      ? '${_files.keys.where((p) => p.endsWith('/SKILL.md')).length} 个技能 · ${_files.length} 个文件'
      : 'SKILL.md · ${_files.length - 1} 个附件';
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
  };

  void _changed() {
    if (_ready && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
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
      await _store.saveAuthoringDraft(_base);
      if (!mounted) return true;
      setState(() => _dirty = false);
      if (sync && await _cloud.hasEmailSession) {
        try {
          final sent = _base;
          final remote = await _cloud.syncAuthoringDraft(sent);
          _base = await _store.applySyncedAuthoringDraft(sent, remote);
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

  Future<void> _preview() async {
    final validation = _validation;
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (!await _persistDraft() || !mounted) return;
    final snapshot = _base;
    final published = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SkillPublicationPreview(
          presentation: snapshot.presentation,
          name: snapshot.name,
          description: snapshot.description,
          kindLabel: _kindLabel,
          published: (_record?.publishedRevision ?? 0) > 0,
          onPublish: () async {
            final local = await _store.commitDraft(
              snapshot,
              existingId: snapshot.targetCapabilityId,
            );
            final remote = await _cloud.syncAuthoredSkill(local);
            _record = await _cloud.publishSkill(remote);
            _base = snapshot.copyWith(targetCapabilityId: _record!.id);
            try {
              await _store.saveAuthoringDraft(_base);
              final sent = _base;
              final synced = await _cloud.syncAuthoringDraft(sent);
              _base = await _store.applySyncedAuthoringDraft(sent, synced);
            } catch (error) {
              if (mounted)
                AppToast.show(context, '${_kindLabel}已发布，草稿状态同步待重试：$error');
            }
          },
        ),
      ),
    );
    if (!mounted) return;
    if (published == true) {
      AppToast.show(context, '${_kindLabel}已发布');
      setState(() => _allowPop = true);
      Navigator.pop(context);
    }
  }

  Future<void> _importContent() async {
    if (_busy || widget.onImport == null) return;
    final incoming = await widget.onImport!(context);
    if (incoming == null || !mounted) return;
    if (incoming.kind != _base.kind) {
      AppToast.show(context, '请选择${_kindLabel}文件，当前草稿已保留');
      return;
    }
    if (_body.text.trim().isNotEmpty ||
        _title.text.trim().isNotEmpty ||
        _dirty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => MarketDialog(
          title: '替换当前${_kindLabel}内容？',
          children: [Text('导入会替换名称、简介和${_kindLabel}文件。已有图标、详细介绍和介绍图片会保留。')],
          actions: [
            marketButton('取消', () => Navigator.pop(ctx, false)),
            marketButton('确认替换', () => Navigator.pop(ctx, true), primary: true),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    final current = _presentation;
    setState(() {
      _applyDraft(
        _base.copyWith(
          name: incoming.name,
          description: incoming.description,
          content: incoming.content,
          files: incoming.files,
          presentation: {
            ...current,
            'title': incoming.presentation['title'] ?? incoming.name,
          },
        ),
      );
      _dirty = true;
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
    if (_busy) return;
    if (_dirty && !await _persistDraft()) return;
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
            marketButton('取消', () => Navigator.pop(ctx)),
            marketButton('创建', () {
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
              marketButton('取消', () => Navigator.pop(ctx)),
              marketButton('替换', () => Navigator.pop(ctx, true), primary: true),
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

  Widget _authoringWorkspace(bool phone) => ListView(
    padding: EdgeInsets.fromLTRB(phone ? 20 : 30, 26, phone ? 20 : 30, 28),
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: phone ? 78 : 110,
            child: Column(
              children: [
                SkillPresentationIcon(_icon, size: phone ? 76 : 108),
                const SizedBox(height: 10),
                marketButton(
                  '更换图标',
                  _busy ? null : _changeIcon,
                  outlined: false,
                  fontSize: phone ? 12 : 14,
                  radius: 10,
                ),
              ],
            ),
          ),
          SizedBox(width: phone ? 16 : 24),
          Expanded(
            child: Column(
              children: [
                _field('名称', _title),
                const SizedBox(height: 20),
                _field('一句话简介', _description, lines: 2),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 22),
      const Divider(height: 1, color: marketLine),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: marketIcon('file-text'),
        title: Text(
          '${_kindLabel}内容',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: phone ? Text(_contentSummary) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!phone)
              Text(_contentSummary, style: const TextStyle(color: marketMuted)),
            const SizedBox(width: 16),
            Text(
              _contentsExpanded ? '收起' : '展开',
              style: const TextStyle(color: marketMuted),
            ),
            const SizedBox(width: 8),
            marketIcon(_contentsExpanded ? 'caret-up' : 'caret-down', size: 18),
          ],
        ),
        onTap: _busy
            ? null
            : () => setState(() => _contentsExpanded = !_contentsExpanded),
      ),
      if (_contentsExpanded)
        SizedBox(
          height: phone ? 520 : 600,
          child: Row(
            children: [
              if (!phone) SizedBox(width: 220, child: _filePanel()),
              Expanded(child: _fileWorkspace(phone)),
            ],
          ),
        ),
      const Divider(height: 1, color: marketLine),
      const SizedBox(height: 26),
      _field('详细介绍', _introduction, lines: 3),
      const SizedBox(height: 28),
      const Divider(height: 1, color: marketLine),
      const SizedBox(height: 26),
      const Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '介绍图片',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          Text(
            '（可选）拖动调整顺序',
            style: TextStyle(fontSize: 13, color: marketMuted),
          ),
        ],
      ),
      const SizedBox(height: 18),
      SizedBox(
        height: phone ? 250 : 330,
        child: Row(
          children: [
            if (_images.isNotEmpty)
              Expanded(
                child: ReorderableListView(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {
                    if (_busy) return;
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      _images.insert(newIndex, _images.removeAt(oldIndex));
                      _dirty = true;
                    });
                  },
                  children: [
                    for (var i = 0; i < _images.length; i++)
                      Container(
                        key: ObjectKey(_images[i]),
                        width: phone ? 160 : 220,
                        margin: const EdgeInsets.only(right: 14),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: marketSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                ReorderableDragStartListener(
                                  index: i,
                                  child: Semantics(
                                    label: '拖动第 ${i + 1} 张图片调整顺序',
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: marketIcon('dots', size: 20),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                marketIconButton(
                                  'trash-danger',
                                  '删除第 ${i + 1} 张图片',
                                  _busy
                                      ? null
                                      : () => setState(() {
                                          _images.removeAt(i);
                                          _dirty = true;
                                        }),
                                ),
                              ],
                            ),
                            Expanded(
                              child: skillDataImage(
                                _images[i]['data']?.toString() ?? '',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              key: ObjectKey(_images[i]),
                              initialValue:
                                  _images[i]['caption']?.toString() ?? '',
                              enabled: !_busy,
                              maxLength: 200,
                              decoration: const InputDecoration(
                                hintText: '添加图片说明',
                                counterText: '',
                                isDense: true,
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onChanged: (value) {
                                _images[i]['caption'] = value;
                                _dirty = true;
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (_images.length < 6)
              SizedBox(
                width: phone ? 110 : 180,
                child: InkWell(
                  onTap: _busy ? null : _addImage,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: marketLine),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          marketIcon('plus', size: 30),
                          const SizedBox(height: 16),
                          const Text(
                            '添加图片',
                            style: TextStyle(color: marketMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA52B25), height: 1.6),
          ),
        ),
      if (_syncFailed) marketButton('重试同步', _busy ? null : _retrySync),
      if (_draftConflict)
        marketButton('将本机修改另存为新草稿', _busy ? null : _saveConflictCopy),
    ],
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: marketTheme(context),
    child: PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: LayoutBuilder(
        builder: (_, constraints) {
          final phone = constraints.maxWidth <= 600;
          return Scaffold(
            key: _scaffold,
            drawer: phone
                ? Drawer(
                    backgroundColor: Colors.white,
                    child: SafeArea(child: _filePanel(drawer: true)),
                  )
                : null,
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          '编辑资料',
                          style: TextStyle(
                            fontSize: phone ? 20 : 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Row(
                          children: [
                            marketIconButton(
                              'back',
                              '返回',
                              _busy ? null : _leave,
                            ),
                            const Spacer(),
                            marketButton(
                              '导入内容',
                              _busy || widget.onImport == null
                                  ? null
                                  : _importContent,
                              icon: 'upload',
                              primary: true,
                              radius: 12,
                              fontSize: phone ? 13 : 15,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      (_record?.publishedRevision ?? 0) > 0
                          ? '我创建的 · $_kindLabel · 修改尚未发布'
                          : '我创建的 · $_kindLabel · 未发布',
                      style: const TextStyle(color: marketMuted, fontSize: 14),
                    ),
                  ),
                  const Divider(height: 1, color: marketLine),
                  Expanded(child: _authoringWorkspace(phone)),
                  const Divider(height: 1, color: marketLine),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: marketButton(
                            _busy ? '正在保存…' : '保存草稿',
                            _busy ? null : _save,
                            outlined: false,
                            radius: 12,
                            height: 52,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: marketButton(
                            '预览',
                            _busy ? null : _preview,
                            primary: true,
                            radius: 12,
                            height: 52,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
