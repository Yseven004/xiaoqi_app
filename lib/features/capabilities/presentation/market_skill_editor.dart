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
  final match = RegExp(r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)')
      .firstMatch(content);
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

/// Edits local drafts only. Imported server installations keep their provenance.
class MarketSkillEditor extends StatefulWidget {
  const MarketSkillEditor({this.draft, this.record, super.key});
  final CapabilityDraft? draft;
  final CapabilityRecord? record;
  @override
  State<MarketSkillEditor> createState() => _MarketSkillEditorState();
}

class _MarketSkillEditorState extends State<MarketSkillEditor> {
  final _name = TextEditingController(),
      _description = TextEditingController(),
      _body = TextEditingController();
  final _store = CapabilityStore.instance;
  final _cloud = CapabilityCloudSync.instance;
  final _scaffold = GlobalKey<ScaffoldState>();
  late CapabilityDraft _base;
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
      _maxTotalBytes = 10 * 1024 * 1024;
  static final _frontmatter = RegExp(
    r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
  );
  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _base =
        widget.draft ??
        CapabilityDraft(
          id: _store.newDraftId(),
          name: record?.name ?? '',
          description: record?.description ?? '',
          content: record?.currentVersion?.content ?? '',
          files: record?.currentVersion?.files ?? {},
          targetCapabilityId: record?.id,
          updatedAt: DateTime.now(),
        );
    _name.text = _base.name;
    _description.text = _base.description;
    _files.addAll(_base.files);
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
    for (final controller in [_name, _description, _body])
      controller.addListener(_changed);
    _ready = true;
  }

  void _changed() {
    if (_ready && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    for (final controller in [_name, _description, _body]) {
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
      return '服务端导入的技能不能在本地覆盖，请使用检查更新。';
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(_name.text) ||
        _name.text.length > 64)
      return '名称最多 64 字符，使用小写字母、数字和单个连字符。';
    if (_description.text.trim().isEmpty || _description.text.length > 500)
      return '填写 1–500 字符的描述。';
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
    final metadata = {
      ..._metadata,
      'name': _name.text.trim(),
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
      name: _name.text.trim(),
      description: _description.text.trim(),
      content: content,
      files: attachments,
      updatedAt: DateTime.now(),
    );
  }

  Future<void> _save({bool draftOnly = false}) async {
    if (_busy) return;
    final validation = _validation;
    if (!draftOnly && validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = _snapshot();
      await _store.saveDraft(draft);
      if (!draftOnly) {
        final saved = await _store.commitDraft(
          draft,
          existingId: draft.targetCapabilityId,
        );
        final email = await _cloud.signedInEmail;
        if (email == null || email.isEmpty)
          await _store.discardDraft(draft.id);
        else
          await _store.queueDraftDeletion(
            id: draft.id,
            cloudRevision: draft.cloudRevision,
            accountEmail: draft.cloudOwnerEmail ?? email,
          );
        // A retired cloud draft ID cannot be saved again after local commit.
        _base = CapabilityDraft(
          id: _store.newDraftId(),
          name: draft.name,
          description: draft.description,
          content: draft.content,
          files: draft.files,
          targetCapabilityId: saved.id,
          updatedAt: draft.updatedAt,
        );
      }
      String? syncFailure;
      if (await _cloud.hasEmailSession) {
        try {
          await _cloud.syncNow();
        } catch (error) {
          syncFailure = error.toString();
        }
      }
      if (!mounted) return;
      if (syncFailure != null) {
        // The local write succeeded: retain that result, expose retry explicitly.
        setState(() {
          if (draftOnly) _base = draft;
          _dirty = false;
          _syncFailed = true;
          _error = '已保存到本机，同步未完成：$syncFailure';
        });
        return;
      }
      setState(() {
        _dirty = false;
        _allowPop = true;
      });
      Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败，编辑内容已保留：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retrySync() async {
    setState(() => _busy = true);
    try {
      await _cloud.syncNow();
      if (mounted)
        setState(() {
          _error = null;
          _syncFailed = false;
        });
    } catch (error) {
      if (mounted) setState(() => _error = '同步失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (!_dirty) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => MarketDialog(
        title: '保留这份草稿？',
        children: [
          const Text(
            '你还有未保存的修改。保留为草稿后，可以从技能页面继续编辑。',
            style: TextStyle(height: 1.65),
          ),
        ],
        actions: [
          marketButton('不保存', () => Navigator.pop(ctx, 'discard')),
          marketButton('继续编辑', () => Navigator.pop(ctx)),
          marketButton(
            '保留草稿',
            () => Navigator.pop(ctx, 'draft'),
            primary: true,
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'draft') await _save(draftOnly: true);
    if (action == 'discard') {
      setState(() => _allowPop = true);
      Navigator.pop(context);
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
              autofocus: true,
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
      // SKILL.md is edited in place; never overwrite it through an attachment picker.
      if (incoming.containsKey('SKILL.md'))
        throw const FormatException('请在正文中编辑 SKILL.md，附件上传不会覆盖主文件');
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
        dialogTitle: '下载 SKILL.md',
        fileName: 'SKILL.md',
        bytes: Uint8List.fromList(bytes),
      );
      if (result != null && mounted)
        AppToast.show(context, '已导出 SKILL.md（附件需单独保留）');
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
                      if (path != 'SKILL.md')
                        IconButton(
                          tooltip: '删除 $path',
                          onPressed: _busy
                              ? null
                              : () {
                                  if (_active == path) _selectFile('SKILL.md');
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
  Widget _workspace(bool phone) => ListView(
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
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: 'your-skill-name',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _description,
              enabled: !_busy,
              maxLength: 500,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '描述',
                hintText: '描述该技能的用途',
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
                    child: Row(
                      children: [
                        marketIconButton('back', '返回', _busy ? null : _leave),
                        const Spacer(),
                        if (!phone)
                          marketButton(
                            '下载技能',
                            _busy ? null : _download,
                            icon: 'download',
                          ),
                        if (phone)
                          marketIconButton(
                            'download',
                            '下载 SKILL.md',
                            _busy ? null : _download,
                          ),
                        const SizedBox(width: 8),
                        marketButton(
                          _busy
                              ? '正在保存…'
                              : _base.targetCapabilityId == null
                              ? '创建'
                              : '保存',
                          _busy || _validation != null ? null : () => _save(),
                          primary: true,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: marketLine),
                  Expanded(
                    child: Row(
                      children: [
                        if (!phone)
                          SizedBox(
                            width: (constraints.maxWidth * .29)
                                .clamp(220, 330)
                                .toDouble(),
                            child: _filePanel(),
                          ),
                        if (!phone)
                          const VerticalDivider(width: 1, color: marketLine),
                        Expanded(child: _workspace(phone)),
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
