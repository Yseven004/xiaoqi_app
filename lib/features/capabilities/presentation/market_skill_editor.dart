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

enum ExtensionCreationResult { draftSaved, published }

enum _DraftFeedback {
  none,
  saving,
  saved,
  syncing,
  pending,
  conflict,
  deleted,
  saveFailed,
}

class MarketSkillEditorController {
  bool Function()? hasUnsavedChanges;
  Future<bool> Function()? save;
}

/// Bridge used by the creation shell to own the embedded import action.
/// The import form still owns validation and network work; the shell owns
/// where the action is presented.
class MarketImportController {
  Future<void> Function()? read;
  Future<void> Function()? pick;
  VoidCallback? clearContent;
  VoidCallback? invalidateSource;
  bool ready = false;
  bool busy = false;
  bool attempted = false;
  bool hasSource = false;
  VoidCallback? onChanged;

  Future<void> run() async => await read?.call();

  void sync({bool? ready, bool? busy, bool? attempted}) {
    if (ready != null) this.ready = ready;
    if (busy != null) this.busy = busy;
    if (attempted != null) this.attempted = attempted;
    onChanged?.call();
  }
}

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
    this.importController,
    this.mcpOnly = false,
    this.active = true,
    this.importKind,
    this.onSelectSource,
    this.onConfigurationChanged,
    this.canAdvance,
    this.cloud,
    this.controller,
    this.otherEditor,
    super.key,
  });
  final CapabilityKind kind;
  final bool mcpOnly, active;
  final CapabilityKind? importKind;
  final ValueChanged<bool>? onSelectSource;
  final ValueChanged<bool>? onConfigurationChanged;
  final bool Function()? canAdvance;
  final CapabilityDraft? draft;
  final CapabilityRecord? record;
  final Future<CapabilityDraft?> Function(BuildContext)? onImport;
  final bool openImportOnStart;
  final CapabilityCloudSync? cloud;
  final MarketSkillEditorController? controller, otherEditor;
  final Widget Function(
    BuildContext,
    Future<bool> Function(CapabilityDraft),
    ValueChanged<bool>,
  )?
  contentBuilder;
  final MarketImportController? importController;
  @override
  State<MarketSkillEditor> createState() => _MarketSkillEditorState();
}

class _MarketSkillEditorState extends State<MarketSkillEditor> {
  int _step = 0;
  bool _introductionExpanded = false;
  bool _importBusy = false;
  bool get _locked => _busy || _testingMcp || _importBusy || _assisting;
  String? _focus;
  String _imageLayout = 'horizontal';
  final _mcpUrl = TextEditingController(), _mcpToken = TextEditingController();
  bool _testingMcp = false, _mcpExpanded = false, _mcpDetected = false;
  String? _mcpResult,
      _mcpError,
      _mcpUrlError,
      _mcpTokenError,
      _privateConnectionId;
  String? _titleError, _descriptionError;
  final Map<String, double> _imageRatios = {};
  final _galleryScroll = ScrollController();
  final _introductionScroll = ScrollController();
  final _introductionFocus = FocusNode();
  bool _pickingImage = false;
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
  Map<String, dynamic> _icon = {'icon_asset': 'file-text', 'icon_data': ''};
  CapabilityRecord? _record;
  _DraftFeedback _feedback = _DraftFeedback.none;
  bool get _draftConflict =>
      _feedback == _DraftFeedback.conflict ||
      _feedback == _DraftFeedback.deleted;
  bool get _syncFailed => _draftConflict || _feedback == _DraftFeedback.pending;
  bool _savedInSession = false;
  int _syncGeneration = 0;
  Future<void> _syncWork = Future<void>.value();
  String? _syncHint;
  final _store = CapabilityStore.instance;
  late final _cloud = widget.cloud ?? CapabilityCloudSync.instance;
  final _scaffold = GlobalKey<ScaffoldState>();
  late CapabilityDraft _base;
  bool _importDialogOpen = false;
  Animation<double>? _entryAnimation;
  bool get _isPlugin => _base.kind == CapabilityKind.plugin;
  String get _kindLabel => widget.mcpOnly ? 'MCP' : _isPlugin ? '插件' : '技能';
  String get _defaultIcon => widget.mcpOnly ? 'mcp' : _isPlugin ? 'extension' : 'file-text';
  double get _supplementScale =>
      ((MediaQuery.sizeOf(context).width * .8).clamp(0.0, 670.0) / 800)
          .clamp(.72, 1.0).toDouble();
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
  bool _dirty = false, _busy = false, _allowPop = false, _ready = false;
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
    _introductionFocus.addListener(_refreshIntroductionFocus);
    widget.controller?.hasUnsavedChanges = () => _dirty;
    widget.controller?.save = () => _persistDraft(sync: true);
    widget.importController?.onChanged = () {
      widget.onConfigurationChanged?.call(
        widget.importController!.hasSource || widget.importController!.ready,
      );
      if (mounted) setState(() {});
    };
    widget.importController?.clearContent = _clearImportedContent;
    widget.importController?.invalidateSource = () {
      if (mounted)
        setState(() {
          _dirty = true;
          _error = null;
        });
    };
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
          creationMode: widget.mcpOnly ? 'mcp' : 'import',
        );
    _applyDraft(_base);
    widget.importController?.ready =
        _base.content.trim().isNotEmpty || _base.files.isNotEmpty;
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
      'icon_asset': _defaultIcon,
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
    _restoreMcpFields();
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
    final saved = widget.record != null
        ? null
        : candidates
              .where(
                (d) =>
                    d.kind == _base.kind &&
                    d.creationMode == _base.creationMode &&
                    d.id == _base.id,
              )
              .firstOrNull;
    setState(() {
      _applyDraft((saved ?? _base).copyWith(cloudOwnerEmail: owner));
      if (saved != null)
        _feedback = switch (saved.syncIssue) {
          DraftSyncIssue.conflict => _DraftFeedback.conflict,
          DraftSyncIssue.deleted => _DraftFeedback.deleted,
          DraftSyncIssue.network => _DraftFeedback.pending,
          DraftSyncIssue.none =>
            saved.lastSyncedHash == skillDraftFingerprint(saved)
                ? _DraftFeedback.saved
                : _DraftFeedback.pending,
        };
    });
    widget.importController?.sync(
      ready: _base.content.trim().isNotEmpty || _base.files.isNotEmpty,
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

  void _refreshIntroductionFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller?.hasUnsavedChanges = null;
    widget.controller?.save = null;
    _galleryScroll.dispose();
    _introductionScroll.dispose();
    _introductionFocus.removeListener(_refreshIntroductionFocus);
    _introductionFocus.dispose();
    widget.importController?.onChanged = null;
    widget.importController?.clearContent = null;
    widget.importController?.invalidateSource = null;
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

  Future<bool> _persistDraft({
    bool sync = false,
    bool waitForSync = false,
  }) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _error = null;
      _feedback = _DraftFeedback.saving;
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
      setState(() {
        _dirty = false;
        _savedInSession = true;
        _feedback = _DraftFeedback.saved;
      });
      if (sync) {
        final operation = _syncSavedDraft();
        if (waitForSync) return await operation;
        unawaited(operation);
      }
      return true;
    } catch (error) {
      if (mounted) setState(() => _feedback = _DraftFeedback.saveFailed);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _syncSavedDraft() {
    final sent = _base;
    final url = _mcpUrl.text.trim();
    final bearerToken = _mcpToken.text.trim();
    final name = _title.text.trim();
    final icon = Map<String, dynamic>.from(_icon);
    final generation = ++_syncGeneration;
    if (mounted) setState(() => _feedback = _DraftFeedback.syncing);
    final operation = _syncWork.then((_) async {
      try {
        if (!await _cloud.hasEmailSession) throw StateError('请先登录个人账号');
        if (url.isNotEmpty) {
          final connections = await _cloud.listMcpConnections();
          final existing = connections
              .where((c) => c.url == url && c.catalogId == null)
              .firstOrNull;
          if (existing == null || bearerToken.isNotEmpty) {
            final connection = await _cloud.saveMcpConnection(
              id: existing?.id,
              name: name.isEmpty ? Uri.parse(url).host : name,
              url: url,
              bearerToken: bearerToken.isEmpty ? null : bearerToken,
              icon: icon,
            );
            if (mounted && _mcpUrl.text.trim() == url)
              _privateConnectionId = connection.id;
          }
          if (bearerToken.isNotEmpty &&
              await _store.draftMcpToken(sent, url: url) == bearerToken) {
            await _store.clearDraftMcpToken(sent);
          }
          if (mounted && _mcpToken.text.trim() == bearerToken)
            _mcpToken.clear();
        }
        final saved = await _cloud.syncAuthoringDraft(sent);
        final clean = saved.lastSyncedHash == skillDraftFingerprint(saved);
        if (mounted && generation == _syncGeneration)
          setState(() {
            _base = _base.copyWith(
              cloudRevision: saved.cloudRevision,
              lastSyncedHash: saved.lastSyncedHash,
              syncIssue: saved.syncIssue,
            );
            _feedback = clean ? _DraftFeedback.saved : _DraftFeedback.pending;
            _syncHint = null;
          });
        return clean;
      } catch (error) {
        final issue = error is SkillDraftConflict
            ? error.deleted
                  ? DraftSyncIssue.deleted
                  : DraftSyncIssue.conflict
            : DraftSyncIssue.network;
        try {
          await _store.markDraftSyncIssue(sent, issue);
        } catch (_) {
          // The saved content is retained even if the sync-status write fails.
        }
        if (mounted && generation == _syncGeneration)
          setState(() {
            _feedback = switch (issue) {
              DraftSyncIssue.conflict => _DraftFeedback.conflict,
              DraftSyncIssue.deleted => _DraftFeedback.deleted,
              _ => _DraftFeedback.pending,
            };
            _syncHint = error.toString().contains('登录') ? '请登录个人账号后再同步。' : null;
          });
        return false;
      }
    });
    _syncWork = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
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

  Future<bool> _applyIncoming(CapabilityDraft incoming) async {
    final imported = incoming;
    if (!mounted) return false;
    if (imported.kind != _base.kind) {
      AppToast.show(context, '请选择${_kindLabel}文件，当前草稿已保留');
      return false;
    }
    if (_base.content.trim().isNotEmpty ||
        _base.files.isNotEmpty ||
        _title.text.trim().isNotEmpty) {
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
      if (replace != true || !mounted) return false;
    }
    final current = _presentation;
    setState(() {
      _applyDraft(
        _base.copyWith(
          name: imported.name,
          description: imported.description,
          content: imported.content,
          files: imported.files,
          importSource: imported.importSource,
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
    widget.importController?.sync(ready: true);
    return true;
  }

  void _clearImportedContent() {
    setState(() {
      _applyDraft(
        _base.copyWith(
          name: '',
          description: '',
          content: '',
          files: {},
          importSource: {},
          presentation: {..._presentation, 'title': ''},
        ),
      );
      _dirty = true;
      _error = null;
    });
  }

  Future<void> _changeIcon() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final icon = await chooseSkillIcon(
      context,
      _icon,
      defaultAsset: _defaultIcon,
    );
    if (icon != null && mounted)
      setState(() {
        _icon = icon;
        _dirty = true;
      });
  }

  Future<void> _addImage() async {
    if (_pickingImage || _locked) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_images.length >= 6) {
      AppToast.show(context, '介绍图片最多 6 张');
      return;
    }
    setState(() => _pickingImage = true);
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
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _retrySync() async {
    if (_feedback == _DraftFeedback.syncing || _busy) return;
    await _syncSavedDraft();
  }

  Future<void> _leave() async {
    if (_locked) return;
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final otherDirty = widget.otherEditor?.hasUnsavedChanges?.call() == true;
    if (_dirty || otherDirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => MarketDialog(
          title: '有未保存修改',
          onClose: () => Navigator.pop(ctx, 'discard'),
          children: [
            Text(otherDirty ? '另一创建页有未保存修改。保存后可以稍后继续编辑。' : '保存后可以稍后继续编辑。'),
          ],
          actions: [
            marketDialogButton('继续编辑', () => Navigator.pop(ctx, 'continue')),
            marketDialogButton(
              '保存后退出',
              () => Navigator.pop(ctx, 'save'),
              primary: true,
            ),
          ],
        ),
      );
      if (!mounted || choice == null || choice == 'continue') return;
      if (choice == 'save' && _dirty && !await _persistDraft(sync: true))
        return;
      if (choice == 'save' && otherDirty) {
        final saved = await widget.otherEditor?.save?.call() ?? false;
        if (!saved) {
          widget.onSelectSource?.call(!widget.mcpOnly);
          return;
        }
        _savedInSession = true;
      }
      if (!mounted) return;
    }
    setState(() => _allowPop = true);
    Navigator.pop(
      context,
      _savedInSession ? ExtensionCreationResult.draftSaved : null,
    );
  }

  Future<void> _saveConflictCopy() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final current = _snapshot();
      final original = (await _store.authoringDrafts(
        _base.cloudOwnerEmail,
      )).where((draft) => draft.id == _base.id).firstOrNull;
      final copy = CapabilityDraft(
        id: _store.newDraftId(),
        kind: current.kind,
        name: current.name,
        description: current.description,
        content: current.content,
        files: current.files,
        creationMode: current.creationMode,
        importSource: current.importSource,
        presentation: current.presentation,
        cloudOwnerEmail: current.cloudOwnerEmail,
        updatedAt: DateTime.now(),
      );
      await _store.saveAuthoringDraft(copy);
      if (!mounted) return;
      setState(() {
        _applyDraft(copy);
        _record = null;
        _dirty = false;
        _feedback = _DraftFeedback.saved;
        _savedInSession = true;
        _error = null;
      });
      AppToast.show(context, '本机修改已另存为新草稿，云端原版本保留');
      unawaited(_syncSavedDraft());
      if (original != null) unawaited(_restoreOriginalAfterCopy(original));
    } catch (error) {
      if (mounted) setState(() => _error = '另存失败，编辑内容仍保留：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreOriginalAfterCopy(CapabilityDraft original) async {
    try {
      final remote = await _cloud.readAuthoringDraft(original.id);
      if (remote != null)
        await _store.applySyncedAuthoringDraft(original, remote);
    } catch (_) {
      // Keep the original conflict until the current cloud version can be read.
    }
  }

  Future<void> _processDraftSync() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => MarketDialog(
        title: _feedback == _DraftFeedback.deleted ? '云端草稿已删除' : '处理同步',
        children: const [Text('本机内容已保留。你可以另存为新草稿，或查看云端的当前版本。')],
        actions: [
          marketDialogButton('继续编辑', () => Navigator.pop(ctx)),
          if (_feedback != _DraftFeedback.deleted)
            marketDialogButton('查看云端版本', () => Navigator.pop(ctx, 'view')),
          marketDialogButton(
            '另存为新草稿',
            () => Navigator.pop(ctx, 'copy'),
            primary: true,
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await _saveConflictCopy();
    } else if (action == 'view') {
      await _viewCloudDraft();
    }
  }

  Future<void> _viewCloudDraft() async {
    setState(() => _busy = true);
    try {
      final remote = await _cloud.readAuthoringDraft(_base.id);
      if (!mounted) return;
      if (remote == null) {
        setState(() => _feedback = _DraftFeedback.deleted);
        await _store.markDraftSyncIssue(_base, DraftSyncIssue.deleted);
        return;
      }
      if (remote.cloudOwnerEmail != _base.cloudOwnerEmail) {
        throw StateError('账号已变化，原草稿仍保留');
      }
      final use = await showDialog<bool>(
        context: context,
        builder: (ctx) => MarketDialog(
          title: '云端版本',
          children: [
            Text(
              remote.presentation['title']?.toString() ?? remote.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(remote.description),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: SingleChildScrollView(
                child: SelectableText(remote.content),
              ),
            ),
          ],
          actions: [
            marketDialogButton('返回', () => Navigator.pop(ctx, false)),
            marketDialogButton(
              '使用云端版本',
              () => Navigator.pop(ctx, true),
              primary: true,
            ),
          ],
        ),
      );
      if (use != true || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => MarketDialog(
          title: '替换本机编辑内容？',
          children: const [
            Text('将使用刚查看的云端版本替换本机草稿和未保存修改。你也可以返回，先把本机内容另存为新草稿。'),
          ],
          actions: [
            marketDialogButton('返回', () => Navigator.pop(ctx, false)),
            marketDialogButton(
              '确认替换',
              () => Navigator.pop(ctx, true),
              primary: true,
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      // Verify the viewed snapshot is still current before replacing local edits.
      final latest = await _cloud.readAuthoringDraft(_base.id);
      if (latest == null ||
          skillDraftFingerprint(latest) != skillDraftFingerprint(remote)) {
        if (mounted) AppToast.show(context, '云端版本再次变化，请重新查看');
        return;
      }
      final replacement = latest.copyWith(
        creationMode: _base.creationMode,
        importSource: _base.importSource,
      );
      await _store.saveAuthoringDraft(replacement);
      if (mounted)
        setState(() {
          _applyDraft(replacement);
          _dirty = false;
          _feedback = _DraftFeedback.saved;
          _savedInSession = true;
        });
    } catch (_) {
      if (mounted) AppToast.show(context, '云端版本暂时无法读取，本机内容已保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _draftFeedbackBand() {
    if (_feedback == _DraftFeedback.none) return const SizedBox.shrink();
    var title = switch (_feedback) {
      _DraftFeedback.saving => '正在保存…',
      _DraftFeedback.saveFailed => '未保存成功',
      _DraftFeedback.saved => _dirty ? '有未保存修改' : '草稿已保存',
      _ => '草稿已保存在本机。',
    };
    var detail = switch (_feedback) {
      _DraftFeedback.saving => '正在保存这次修改。',
      _DraftFeedback.syncing => '正在同步，你可以继续编辑。',
      _DraftFeedback.conflict => '云端版本有变化，暂未同步。',
      _DraftFeedback.deleted => '云端草稿已删除，本机内容已保留。',
      _DraftFeedback.pending => _syncHint ?? '暂未同步，联网后可重试。',
      _DraftFeedback.saveFailed => '当前修改仍保留在编辑器中，请重试。',
      _ => _dirty ? '最近修改尚未保存。' : '已同步，可稍后继续编辑。',
    };
    if (_dirty &&
        _feedback != _DraftFeedback.saved &&
        _feedback != _DraftFeedback.saving &&
        _feedback != _DraftFeedback.saveFailed) {
      title = '有未保存修改';
      detail = '最近修改尚未保存。$detail';
    }
    final action = switch (_feedback) {
      _DraftFeedback.conflict || _DraftFeedback.deleted => '处理同步',
      _DraftFeedback.pending => '重试同步',
      _DraftFeedback.saveFailed => '重试保存',
      _ => null,
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('draft-save-feedback'),
        color: const Color(0xFFFAF8F5),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _feedback == _DraftFeedback.saveFailed
                          ? const Color(0xFFB3261E)
                          : marketInk,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 13,
                      color: marketMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 12),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF0069D9),
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _busy
                    ? null
                    : _draftConflict
                    ? _processDraftSync
                    : _feedback == _DraftFeedback.saveFailed
                    ? _save
                    : _retrySync,
                child: Text(action),
              ),
            ],
          ],
        ),
      ),
    );
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
      _draftFeedbackBand(),
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
    String? errorText,
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
          errorText: errorText,
        ),
      ),
    ],
  );

  void _restoreMcpFields() {
    _mcpUrl.clear();
    _mcpToken.clear();
    _privateConnectionId = null;
    _mcpResult = _mcpError = _mcpUrlError = _mcpTokenError = null;
    _mcpDetected = false;
    _mcpExpanded = false;
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
            _mcpDetected = true;
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
    if (_mcpUrl.text.trim().isEmpty && !_mcpDetected) return;
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
    _mcpResult = _mcpError = _mcpUrlError = _mcpTokenError = null;
    _dirty = true;
    _privateConnectionId = null;
    _mcpToken.clear();
    if (widget.mcpOnly && _mcpUrl.text.trim().isEmpty) {
      _files.remove('.mcp.json');
      _mcpDetected = false;
    }
    if (widget.mcpOnly)
      widget.onConfigurationChanged?.call(
        _mcpUrl.text.trim().isNotEmpty || _mcpToken.text.isNotEmpty,
      );
  });

  Future<void> _testMcp() async {
    if (_testingMcp || _busy) return;
    final validation = validateMcpServerUrl(_mcpUrl.text);
    if (validation != null) {
      setState(() {
        _mcpUrlError = validation;
        _mcpResult = _mcpError = null;
      });
      return;
    }
    setState(() {
      _testingMcp = true;
      _mcpResult = _mcpError = _mcpUrlError = _mcpTokenError = null;
    });
    try {
      if (widget.record != null &&
          _privateConnectionId == null &&
          _mcpToken.text.trim().isEmpty) {
        final connections = await _cloud.listMcpConnections();
        _privateConnectionId = connections
            .where(
              (connection) =>
                  connection.catalogId == null &&
                  connection.url == _mcpUrl.text.trim(),
            )
            .firstOrNull
            ?.id;
      }
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
      if (mounted) {
        setState(() {
          final message = error.toString().toLowerCase();
          if ((message.contains('401') ||
              message.contains('403') ||
              message.contains('token') ||
              message.contains('auth'))) {
            _mcpTokenError = '令牌无效或无权访问该服务器。';
          } else {
            _mcpUrlError = '连接失败，请检查服务器地址或访问权限后重试。';
          }
          _mcpError = error.toString();
        });
      }
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

  void _back({bool finishEditor = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_focus == 'description' && _introductionExpanded && !finishEditor) {
      setState(() => _introductionExpanded = false);
      return;
    }
    if (_focus != null) {
      setState(() {
        _error = null;
        _introductionExpanded = false;
        _focus = null;
      });
    } else if (_step > 0) {
      setState(() {
        _error = null;
        _step--;
      });
    } else {
      unawaited(_leave());
    }
  }

  Future<void> _next() async {
    if (_locked) return;
    if (widget.canAdvance?.call() == false) {
      setState(() => _error = '导入内容与独立 MCP 均有配置信息，请先清空其中一页，再点击下一步。');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (_step == 0) {
      if (!widget.mcpOnly &&
          widget.importController != null &&
          !widget.importController!.ready) {
        await widget.importController!.run();
        return;
      }
      if ((widget.mcpOnly || _mcpDetected) && _mcpResult != '连接成功') {
        setState(() {
          _mcpExpanded = true;
          if (_mcpUrlError == null && _mcpTokenError == null) {
            _mcpUrlError =
                validateMcpServerUrl(_mcpUrl.text) ?? '请先测试连接，连接成功后才能继续。';
          }
        });
        return;
      } else if (!widget.mcpOnly &&
          (((!_isPlugin && _body.text.trim().isEmpty) ||
                  (_isPlugin && _files.length <= 1 && _base.content.isEmpty)) &&
              _mcpResult != '连接成功')) {
        setState(() => _error = '先读取内容，或编写${_kindLabel}内容。');
        return;
      }
    } else {
      final validation = _validation;
      if (validation != null) {
        setState(() {
          _titleError = _title.text.trim().isEmpty || _title.text.length > 128
              ? '填写 1–128 字符的展示名称，可以使用中文。'
              : null;
          _descriptionError =
              _description.text.trim().isEmpty || _description.text.length > 500
              ? '填写 1–500 字符的描述。'
              : null;
          // Field validation belongs to its input, not the canvas-level error.
          _error = _titleError == null && _descriptionError == null
              ? validation
              : null;
        });
        return;
      }
      setState(() => _titleError = _descriptionError = null);
    }
    setState(() {
      _error = null;
      _step++;
    });
  }

  Future<void> _publishInPlace() async {
    if (_busy || _testingMcp) return;
    if (widget.canAdvance?.call() == false) {
      setState(() => _error = '导入内容与独立 MCP 均有配置信息，请先清空其中一页。');
      return;
    }
    final validation = _validation;
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (!await _persistDraft(sync: true, waitForSync: true) || !mounted) return;
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
      Navigator.pop(context, ExtensionCreationResult.published);
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

  Widget _mcpStatus() {
    if (_mcpResult != '连接成功') return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      label: '连接成功',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            '${marketAssets}detail/connection-success.svg',
            width: 24,
            height: 24,
          ),
          const SizedBox(width: 6),
          const Text(
            '连接成功',
            style: TextStyle(
              fontSize: 18,
              color: marketSuccess,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mcpEntry() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 16),
      const Divider(height: 1, color: marketLine),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _busy
                  ? null
                  : () => setState(() => _mcpExpanded = !_mcpExpanded),
              child: const Text(
                '已识别 MCP 服务',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          marketIcon(_mcpExpanded ? 'caret-up' : 'caret-down', size: 20),
        ],
      ),
      if (_mcpExpanded) ...[const SizedBox(height: 8), _mcpFieldsContent()],
    ],
  );

  Widget _mcpFieldsContent() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '服务器地址',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      SizedBox(height: widget.mcpOnly ? 10 : 8),
      TextField(
        controller: _mcpUrl,
        key: const ValueKey('mcp-server-url'),
        style: TextStyle(
          fontFamily: 'NotoSansCJKSC',
          fontSize: 16,
          color: widget.mcpOnly ? marketInk : marketCreationMuted,
        ),
        enabled: !_testingMcp && !_busy,
        keyboardType: TextInputType.url,
        onChanged: _mcpChanged,
        decoration: InputDecoration(
          hintText: 'https://',
          errorText: _mcpUrlError,
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
          contentPadding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: widget.mcpOnly ? 14 : 12,
          ),
        ),
      ),
      SizedBox(height: widget.mcpOnly ? 18 : 14),
      Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: '访问令牌',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: widget.mcpOnly ? ' · 仅本人可见 · 按服务需要填写' : ' · 仅本人可见',
              style: const TextStyle(color: marketCreationMuted),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 16),
      ),
      SizedBox(height: widget.mcpOnly ? 10 : 8),
      TextField(
        controller: _mcpToken,
        key: const ValueKey('mcp-token'),
        style: const TextStyle(
          fontFamily: 'NotoSansCJKSC',
          fontSize: 16,
          color: marketCreationMuted,
        ),
        enabled: !_testingMcp && !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {
          _mcpResult = _mcpError = _mcpTokenError = null;
          _dirty = true;
          if (widget.mcpOnly)
            widget.onConfigurationChanged?.call(
              _mcpUrl.text.trim().isNotEmpty || _mcpToken.text.isNotEmpty,
            );
        }),
        decoration: InputDecoration(
          hintText: '仅在服务器需要时填写；令牌只保存在你的私有连接中',
          errorText: _mcpTokenError,
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
          contentPadding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: widget.mcpOnly ? 14 : 12,
          ),
        ),
      ),
      SizedBox(height: widget.mcpOnly ? 18 : 14),
      Align(
        alignment: Alignment.centerLeft,
        child: _mcpResult == '连接成功'
            ? _mcpStatus()
            : _mcpUrl.text.trim().isNotEmpty
            ? SizedBox(
                width: 160,
                child: marketDialogButton(
                  _testingMcp ? '测试中…' : (_mcpError != null ? '重新测试' : '测试连接'),
                  _testingMcp || _busy ? null : _testMcp,
                ),
              )
            : const SizedBox.shrink(),
      ),
      if (_mcpError != null && _mcpUrlError == null && _mcpTokenError == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _mcpError!,
            style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13),
          ),
        ),
    ],
  );

  Widget _mcpCanvas() => SingleChildScrollView(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, color: marketLine),
        const SizedBox(height: 24),
        const Text(
          'MCP 服务地址',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 24),
        _mcpFieldsContent(),
        const SizedBox(height: 28),
        const Divider(height: 1, color: marketLine),
        const SizedBox(height: 18),
        const Text('连接凭据仅保存到你的个人连接', style: TextStyle(color: marketMuted)),
      ],
    ),
  );

  Widget _supplementField(
    String label,
    TextEditingController controller, {
    int lines = 1,
    String? errorText,
  }) {
    final s = _supplementScale;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12 * s),
      borderSide: const BorderSide(color: Color(0xFFDEE0E4)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.w600)),
        SizedBox(height: 14 * s),
        TextField(
          controller: controller,
          enabled: !_locked,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 3,
          style: TextStyle(fontSize: 24 * s, height: 1.5),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: border,
            enabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: const BorderSide(color: Color(0xFF555B62), width: 1.5),
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 24 * s, vertical: 14 * s),
            errorText: errorText,
          ),
        ),
      ],
    );
  }

  void _openInformationEditor(String editor) {
    if (_locked) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _error = null;
      _focus = editor;
    });
  }

  Widget _information() => LayoutBuilder(
    builder: (context, box) {
      final s = _supplementScale;
      final customIcon = (_icon['icon_data']?.toString() ?? '').isNotEmpty;
      final icon = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: '更换$_kindLabel图标',
            child: InkWell(
              onTap: _locked ? null : _changeIcon,
              borderRadius: BorderRadius.circular(26 * s),
              child: SkillPresentationIcon(_icon, size: 120 * s, defaultAsset: _defaultIcon),
            ),
          ),
          TextButton(
            onPressed: _locked ? null : _changeIcon,
            style: TextButton.styleFrom(
              foregroundColor: marketMuted,
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.symmetric(horizontal: 4 * s),
            ),
            child: Text('更换图标', style: TextStyle(fontSize: 20 * s)),
          ),
          if (customIcon)
            TextButton(
              onPressed: _locked ? null : () {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() {
                  _icon = {'icon_asset': _defaultIcon, 'icon_data': ''};
                  _dirty = true;
                });
              },
              child: const Text('恢复默认'),
            ),
        ],
      );
      final name = _supplementField('名称', _title, errorText: _titleError);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (box.maxWidth < 340) ...[
            Align(alignment: Alignment.centerLeft, child: icon),
            SizedBox(height: 12 * s),
            name,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                icon,
                SizedBox(width: 32 * s),
                Expanded(child: Padding(padding: EdgeInsets.only(top: 8 * s), child: name)),
              ],
            ),
          SizedBox(height: 22 * s),
          _supplementField('一句话简介', _description, lines: 2, errorText: _descriptionError),
          SizedBox(height: 32 * s),
          const Divider(height: 1, color: marketLine),
          Padding(
            padding: EdgeInsets.only(top: 28 * s, bottom: 12 * s),
            child: Text('可选资料', style: TextStyle(color: marketMuted, fontSize: 22 * s)),
          ),
          _informationEntry(
            editor: 'description',
            title: '详细介绍',
            asset: '${marketAssets}detail/file-text.svg',
            subtitle: _introduction.text.trim().isEmpty
                ? '添加使用场景与操作说明'
                : _introduction.text.trim(),
            filled: _introduction.text.trim().isNotEmpty,
          ),
          const Divider(height: 1, color: marketLine),
          _informationEntry(
            editor: 'images',
            title: '介绍图片',
            asset: 'assets/icons/capabilities/image.svg',
            subtitle: _images.isEmpty ? '添加图片展示使用效果，最多 6 张' : '已添加 ${_images.length} 张图片',
            filled: _images.isNotEmpty,
          ),
        ],
      );
    },
  );

  Widget _informationEntry({
    required String editor,
    required String title,
    required String asset,
    required String subtitle,
    required bool filled,
  }) {
    final s = _supplementScale;
    return Semantics(
      button: true,
      label: '${filled ? '编辑' : '添加'}$title',
      child: InkWell(
        key: ValueKey('supplement-$editor-entry'),
        onTap: _locked ? null : () => _openInformationEditor(editor),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 22 * s),
          child: Row(
            children: [
              Container(
                width: 64 * s,
                height: 64 * s,
                padding: EdgeInsets.all(16 * s),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFB),
                  border: Border.all(color: const Color(0xFFE0E2E6)),
                  borderRadius: BorderRadius.circular(14 * s),
                ),
                child: SvgPicture.asset(asset),
              ),
              SizedBox(width: 24 * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.w600))),
                      SizedBox(width: 12 * s),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 2 * s),
                        decoration: BoxDecoration(color: const Color(0xFFF0F0F2), borderRadius: BorderRadius.circular(16)),
                        child: Text('可选', style: TextStyle(fontSize: 17 * s, color: marketMuted)),
                      ),
                    ]),
                    SizedBox(height: 6 * s),
                    Text(subtitle, maxLines: filled ? 1 : 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 19 * s, color: marketMuted, height: 1.5)),
                    if (editor == 'images' && filled) ...[
                      SizedBox(height: 10 * s),
                      Row(children: [
                        for (final image in _images.take(3))
                          Padding(
                            padding: EdgeInsets.only(right: 8 * s),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(width: 48 * s, height: 36 * s,
                                child: skillDataImage(image['data']?.toString() ?? '')),
                            ),
                          ),
                      ]),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 12 * s),
              Text(filled ? '编辑' : '添加', style: TextStyle(fontSize: 22 * s)),
              SizedBox(width: 16 * s),
              marketIcon('caret-right', size: 24 * s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imageEditor() {
    final s = _supplementScale;
    if (_images.isEmpty) {
      return LayoutBuilder(
        builder: (context, box) => Align(
          alignment: const Alignment(0, -.3),
          child: Semantics(
            button: true,
            label: '添加第一张图片',
            enabled: !_locked && !_pickingImage,
            child: InkWell(
              key: const ValueKey('gallery-empty-upload'),
              onTap: _locked || _pickingImage ? null : _addImage,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: EdgeInsets.all(12 * s),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      '${marketAssets}detail/gallery-empty-stack.svg',
                      width: box.maxWidth * .70,
                    ),
                    SizedBox(height: 44 * s),
                    Text('添加第一张图片',
                      style: TextStyle(fontSize: 26 * s, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        _galleryToolbar(),
        Expanded(child: _gallery()),
      ],
    );
  }

  Widget _galleryToolbar() {
    final s = _supplementScale;
    return Padding(
      padding: EdgeInsets.only(top: 22 * s, bottom: 22 * s),
      child: LayoutBuilder(builder: (context, box) {
        final selector = Container(
          width: 224 * s,
          height: (56 * s).clamp(54.0, 56.0),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFDEE0E4)),
            borderRadius: BorderRadius.circular(12 * s),
          ),
          child: Row(children: [
            for (final layout in ['horizontal', 'grid'])
              Expanded(
                child: Semantics(
                  selected: _imageLayout == layout,
                  child: TextButton(
                    key: ValueKey('gallery-layout-$layout'),
                    onPressed: _locked ? null : () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() {
                        _imageLayout = layout;
                        _dirty = true;
                      });
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: _imageLayout == layout ? Colors.white : marketInk,
                      backgroundColor: _imageLayout == layout ? const Color(0xFF24272C) : Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8 * s)),
                    ),
                    child: Text(layout == 'horizontal' ? '横排' : '网格', style: TextStyle(fontSize: 22 * s)),
                  ),
                ),
              ),
          ]),
        );
        final add = marketButton('添加图片',
          _locked || _pickingImage || _images.length >= 6 ? null : _addImage,
          icon: 'plus', radius: 12 * s,
          height: (56 * s).clamp(48.0, 56.0), fontSize: 22 * s);
        final requiredWidth = 224 * s + 12 + 64 + MediaQuery.textScalerOf(context).scale(22 * s) * 4;
        if (box.maxWidth < requiredWidth) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: Alignment.centerLeft, child: selector),
            SizedBox(height: 12 * s),
            Align(alignment: Alignment.centerRight, child: add),
          ]);
        }
        return Row(children: [
          selector,
          const SizedBox(width: 12),
          Expanded(child: Align(alignment: Alignment.centerRight, child: add)),
        ]);
      }),
    );
  }

  Widget _gallery() => LayoutBuilder(
    builder: (context, box) {
      final s = _supplementScale;
      final grid = _imageLayout == 'grid';
      final gap = 20 * s;
      final textScale = MediaQuery.textScalerOf(context).scale(20 * s) / (20 * s);
      final minimumTileWidth = (244 * s * textScale).clamp(224.0, 400.0);
      final columns = box.maxWidth < minimumTileWidth * 2 + gap ? 1 : 2;
      final controlsHeight = (64 * s).clamp(48.0, 64.0);
      final imageInset = 14 * s;
      final cardHeight = (box.maxHeight - 40 * s).clamp(0.0, double.infinity);
      final pictureHeight = (cardHeight - controlsHeight - imageInset * 2).clamp(0.0, double.infinity);

      Widget tile(int index) {
        final image = _images[index];
        final ratio = _ratio(image);
        final width = grid
            ? (box.maxWidth - (columns - 1) * gap) / columns
            : (pictureHeight * ratio + imageInset * 2).clamp(minimumTileWidth, double.infinity);
        final height = grid ? (width - imageInset * 2) / ratio : pictureHeight;
        final grip = Semantics(
          label: '拖动第 ${index + 1} 张图片排序',
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(child: marketIcon('gallery-drag', size: 24 * s)),
          ),
        );
        return Semantics(
          value: '第 ${index + 1} 张，共 ${_images.length} 张',
          onIncrease: _locked || index == _images.length - 1
              ? null : () => _reorderImage(index, index + 1),
          onDecrease: _locked || index == 0
              ? null : () => _reorderImage(index, index - 1),
          child: Container(
            key: ValueKey('gallery-tile-${identityHashCode(image)}'),
            width: width,
            padding: EdgeInsets.fromLTRB(imageInset, imageInset, imageInset, 0),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(12 * s),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10 * s),
                  child: SizedBox(
                    width: width - imageInset * 2,
                    height: height,
                    child: ColoredBox(
                      color: const Color(0xFFF7F7F8),
                      child: skillDataImage(image['data']?.toString() ?? ''),
                    ),
                  ),
                ),
                SizedBox(
                  height: controlsHeight,
                  child: Row(
                    children: [
                      if (grid) grip else ReorderableDragStartListener(
                        index: index,
                        enabled: !_locked,
                        child: grip,
                      ),
                      Expanded(child: Text('第 ${index + 1} 张',
                        style: TextStyle(fontSize: 20 * s))),
                      TextButton(
                        key: ValueKey('gallery-delete-$index'),
                        onPressed: _locked ? null : () {
                          setState(() {
                            _images.removeAt(index);
                            _dirty = true;
                          });
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: marketInk,
                          minimumSize: const Size(48, 48),
                          padding: EdgeInsets.symmetric(horizontal: 4 * s),
                        ),
                        child: Semantics(
                          label: '删除第 ${index + 1} 张图片',
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            marketIcon('trash-danger', size: 22 * s, color: marketInk),
                            SizedBox(width: 6 * s),
                            Text('删除', style: TextStyle(fontSize: 20 * s)),
                          ]),
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

      if (grid) {
        return SingleChildScrollView(
          key: const ValueKey('gallery-grid'),
          padding: EdgeInsets.only(bottom: 16 * s),
          child: SizedBox(
            width: box.maxWidth,
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var index = 0; index < _images.length; index++)
                  LongPressDraggable<int>(
                    key: ObjectKey(_images[index]),
                    data: index,
                    maxSimultaneousDrags: _locked ? 0 : 1,
                    feedback: Material(
                      color: Colors.white,
                      child: SizedBox(
                        width: 120,
                        height: 150,
                        child: skillDataImage(_images[index]['data']?.toString() ?? ''),
                      ),
                    ),
                    child: DragTarget<int>(
                      onWillAcceptWithDetails: (details) => !_locked && details.data != index,
                      onAcceptWithDetails: (details) => _reorderImage(details.data, index),
                      builder: (_, candidates, rejected) => tile(index),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      return Padding(
        padding: EdgeInsets.only(bottom: 16 * s),
        child: ScrollbarTheme(
          data: ScrollbarThemeData(
            thumbColor: const WidgetStatePropertyAll(Color(0xFF24272C)),
            trackColor: const WidgetStatePropertyAll(Color(0xFFE1E2E6)),
            trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
            thickness: WidgetStatePropertyAll(4 * s),
            radius: const Radius.circular(4),
          ),
          child: Scrollbar(
            controller: _galleryScroll,
            thumbVisibility: true,
            trackVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: ReorderableListView(
              scrollController: _galleryScroll,
              padding: EdgeInsets.only(bottom: 24 * s),
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                if (!_locked) _reorderImage(from, to);
              },
              children: [
                for (var i = 0; i < _images.length; i++)
                  Padding(
                    key: ObjectKey(_images[i]),
                    padding: EdgeInsets.only(right: i == _images.length - 1 ? 0 : gap),
                    child: tile(i),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  void _reorderImage(int from, int to) => setState(() {
    _images.insert(to, _images.removeAt(from));
    _dirty = true;
  });


  Future<void> _selectSource(bool mcp) async {
    if (_locked || mcp == widget.mcpOnly) return;
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onSelectSource?.call(mcp);
  }

  Widget _sourceTabs() {
    final importLabel =
        (widget.importKind ?? widget.kind) == CapabilityKind.skill
        ? '导入技能'
        : '导入插件';
    Widget tab(String text, String asset, bool selected, bool mcp) => Expanded(
      child: TextButton(
        onPressed: _locked ? null : () => _selectSource(mcp),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          backgroundColor: const Color(0xFFF6F7F8),
          foregroundColor: selected ? marketInk : marketMuted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(color: selected ? marketInk : marketLine),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(asset, width: 20, height: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Row(
      children: [
        tab(
          importLabel,
          '${marketAssets}detail/file-text.svg',
          !widget.mcpOnly,
          false,
        ),
        const SizedBox(width: 10),
        tab(
          '连接 MCP 服务',
          'assets/icons/capabilities/mcp_connector.svg',
          widget.mcpOnly,
          true,
        ),
      ],
    );
  }

  Widget _supplementHeader(double width) {
    final s = _supplementScale;
    final images = _focus == 'images';
    final inset = _introductionExpanded ? 24 * s : width * (images ? .045 : .055);
    final subtitle = images
        ? '已添加 ${_images.length} / 6 张${_images.isEmpty ? '' : '，拖动调整顺序'}'
        : '补充使用场景、操作步骤与注意事项（可选）';
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 24 * s, inset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: (64 * s).clamp(48.0, 64.0),
            child: Row(
              children: [
                marketIconButton('back', '返回资料', _locked ? null : _back, edgeAligned: true),
                SizedBox(width: 8 * s),
                Expanded(
                  child: Text(
                    images ? '介绍图片' : '详细介绍',
                    style: TextStyle(fontSize: 36 * s, height: 1.4, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_introductionExpanded) _introductionExpandButton(),
                SizedBox(
                  width: (88 * s).clamp(72.0, 88.0),
                  child: marketButton(
                    '完成', _locked ? null : () => _back(finishEditor: true),
                    primary: true, radius: 12 * s,
                    primaryColor: const Color(0xFF24272C),
                    height: (60 * s).clamp(48.0, 60.0), fontSize: 22 * s,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 4 * s),
          Text(subtitle, style: TextStyle(fontSize: 22 * s, height: 1.5, color: marketMuted)),
          SizedBox(height: 12 * s),
          const Divider(height: 1, color: marketLine),
        ],
      ),
    );
  }

  Widget _introductionExpandButton() => IconButton(
    key: const ValueKey('supplement-introduction-expand'),
    tooltip: _introductionExpanded ? '收起输入画布' : '展开输入画布',
    onPressed: _locked ? null : () {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _introductionExpanded = !_introductionExpanded);
    },
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    icon: SvgPicture.asset(
      'assets/images/home_composer_expand.svg',
      width: 20,
      height: 20,
      excludeFromSemantics: true,
    ),
  );

  Widget _introductionCanvas(double keyboardOverlap) {
    final s = _supplementScale;
    final textPadding = EdgeInsets.fromLTRB(
      24 * s, _introductionExpanded ? 24 * s : 48, 24 * s, 24 * s,
    );
    const hintColor = Color(0xFF8A8D95);
    final heading = TextStyle(fontWeight: FontWeight.w600, fontSize: 25 * s);
    final noun = widget.mcpOnly ? 'MCP 连接器' : _kindLabel;
    return LayoutBuilder(builder: (context, box) {
      final footerHeight = _introductionExpanded ? 0.0 : 24 * s;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _introductionExpanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 32 * s),
                      Text('介绍内容', style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.w600)),
                      SizedBox(height: 14 * s),
                    ],
                  ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, canvas) {
              // Keep the footer anchored; only the editable viewport avoids the keyboard.
              final covered = (keyboardOverlap - footerHeight)
                  .clamp(0.0, canvas.maxHeight);
              return Padding(
                padding: EdgeInsets.only(bottom: covered),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12 * s)),
                    border: _introductionExpanded ? null : Border(
                      top: BorderSide(color: _introductionFocus.hasFocus ? const Color(0xFF555B62) : const Color(0xFFDEE0E4)),
                      left: BorderSide(color: _introductionFocus.hasFocus ? const Color(0xFF555B62) : const Color(0xFFDEE0E4)),
                      right: BorderSide(color: _introductionFocus.hasFocus ? const Color(0xFF555B62) : const Color(0xFFDEE0E4)),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12 * s)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Semantics(
                          hint: '可参考适用场景、使用方法和注意事项填写',
                          child: Scrollbar(
                            controller: _introductionScroll,
                            child: TextField(
                              key: const ValueKey('supplement-introduction-canvas'),
                              controller: _introduction,
                              focusNode: _introductionFocus,
                              scrollController: _introductionScroll,
                              enabled: !_locked,
                              expands: true,
                              minLines: null,
                              maxLines: null,
                              scrollPadding: const EdgeInsets.all(24),
                              textAlignVertical: TextAlignVertical.top,
                              style: TextStyle(fontSize: 24 * s, height: 1.8),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                contentPadding: textPadding,
                              ),
                            ),
                          ),
                        ),
                        if (_introduction.text.isEmpty)
                          IgnorePointer(
                            child: ExcludeSemantics(
                              child: SingleChildScrollView(
                                padding: textPadding,
                                child: Text.rich(
                                  key: const ValueKey('supplement-introduction-template'),
                                  TextSpan(children: [
                                    TextSpan(text: '适用场景\n', style: heading),
                                    TextSpan(text: '这个$noun适合谁？可以解决什么问题？\n\n'),
                                    TextSpan(text: '使用方法\n', style: heading),
                                    const TextSpan(text: '1. 用户需要提供哪些内容？\n2. 需要按照什么步骤操作？\n3. 最终会得到什么结果？\n\n'),
                                    TextSpan(text: '注意事项\n', style: heading),
                                    const TextSpan(text: '有哪些使用条件、限制或需要提醒的事项？'),
                                  ]),
                                  style: TextStyle(fontSize: 24 * s, height: 1.8, color: hintColor),
                                ),
                              ),
                            ),
                          ),
                        if (!_introductionExpanded)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: _introductionExpandButton(),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: SizedBox(height: footerHeight),
          ),
        ],
      );
    });
  }

  Widget _creationContent(bool phone, {double keyboardOverlap = 0}) {
    final importPane = SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.contentBuilder != null)
            widget.contentBuilder!(context, (draft) => _applyIncoming(draft), (
              busy,
            ) {
              if (mounted) setState(() => _importBusy = busy);
            })
          else
            marketButton('导入内容', _busy ? null : _importContent, icon: 'upload'),
          if (_mcpDetected && widget.importController?.ready != false)
            _mcpEntry(),
        ],
      ),
    );
    final infoPane = SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: _information(),
    );
    final confirmPane = SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: SkillPresentationBody(
        presentation: _presentation,
        name: _title.text,
        description: _description.text,
        kindLabel: _kindLabel,
      ),
    );
    final focusPane = switch (_focus) {
      'description' => _introductionCanvas(keyboardOverlap),
      'images' => _imageEditor(),
      'content' => Row(
        children: [
          if (!phone) SizedBox(width: 180, child: _filePanel()),
          Expanded(child: _fileWorkspace(phone)),
        ],
      ),
      'mcp' => _mcpCanvas(),
      _ => const SizedBox.shrink(),
    };
    return IndexedStack(
      index: _focus == null ? _step : 3,
      children: [
        widget.mcpOnly ? _mcpCanvas() : importPane,
        infoPane,
        confirmPane,
        focusPane,
      ],
    );
  }

  @override
  Widget build(BuildContext context) => MarketInputFocusScope(
    child: Theme(
      data: marketTheme(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        textButtonTheme: const TextButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
            elevation: WidgetStatePropertyAll(0),
          ),
        ),
        outlinedButtonTheme: const OutlinedButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
            elevation: WidgetStatePropertyAll(0),
          ),
        ),
        iconButtonTheme: const IconButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
      ),
      child: PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.active && !_locked) _back();
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final phone = constraints.maxWidth <= 600;
            final supplement = _focus == 'description' || _focus == 'images';
            final expandedIntroduction =
                _focus == 'description' && _introductionExpanded;
            final width = expandedIntroduction
                ? (constraints.maxWidth - 24).clamp(0.0, double.infinity)
                : (constraints.maxWidth * .8).clamp(0.0, 670.0);
            final inset = expandedIntroduction
                ? 24 * _supplementScale
                : supplement
                ? width * (_focus == 'images' ? .045 : .055)
                : width < 480 ? 24.0 : 40.0;
            final bottomSafeArea = MediaQuery.viewPaddingOf(context).bottom;
            final frameHeight = constraints.maxHeight - bottomSafeArea;
            final top = expandedIntroduction
                ? 12.0
                : phone ? 24.0 : frameHeight * .235;
            final heightFactor = _focus == 'images' ? 1.325
                : _focus == 'description' ? 1.20
                : !widget.mcpOnly && _mcpDetected ? 1.48 : 1.04;
            // Remove the former note band from the dialog, retaining a compact bottom inset.
            final introductionTrim = _focus == 'description' && !expandedIntroduction
                ? 64 * _supplementScale + 1 +
                    MediaQuery.textScalerOf(context).scale(20 * _supplementScale) * 1.4
                : 0.0;
            final height = expandedIntroduction
                ? (frameHeight - 24).clamp(0.0, double.infinity)
                : ((phone
                        ? frameHeight - 48
                        : width * heightFactor)
                    .clamp(0.0, frameHeight - top - 24) - introductionTrim)
                    .clamp(0.0, double.infinity);
            final keyboard = MediaQuery.viewInsetsOf(context).bottom;
            final visibleHeight = (constraints.maxHeight - keyboard - top)
                .clamp(0.0, height);
            return Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  expandedIntroduction ? 12 : 18,
                  top,
                  expandedIntroduction ? 12 : 18,
                  (expandedIntroduction ? 12 : 24) + bottomSafeArea,
                ),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(expandedIntroduction ? 16 : 20),
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
                      body: SizedBox(
                        height: _focus == 'description' ? height : visibleHeight,
                        child: Column(
                          children: [
                            if (supplement) _supplementHeader(width),
                            if (!supplement) Padding(
                              padding: EdgeInsets.fromLTRB(inset, 16, 20, 0),
                              child: Row(
                                children: [
                                  if (_focus != null)
                                    marketIconButton(
                                      'back',
                                      _focus == 'mcp' ? '返回添加内容' : '返回资料',
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
                                          : _focus == 'mcp'
                                          ? '连接 MCP 服务'
                                          : widget.mcpOnly && _step == 0
                                          ? '连接 MCP 服务'
                                          : '${widget.record == null ? '创建' : '编辑'}$_kindLabel',
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (_focus != null)
                                    marketDialogButton(
                                      '完成',
                                      _busy ? null : _back,
                                      primary: true,
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
                            if (_focus == null && !supplement)
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  0,
                                  inset,
                                  12,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      widget.record?.publicationId != null &&
                                              _step == 2
                                          ? '修改尚未发布，确认发布后更新公开作品'
                                          : widget.mcpOnly && _step == 0
                                          ? '独立创建 MCP 连接器，下一步补充资料'
                                          : const [
                                              '先添加内容，资料可以稍后补充',
                                              '确认名称与简介，其他资料按需补充',
                                              '仅自己可见 · 尚未发布',
                                            ][_step],
                                      style: const TextStyle(
                                        color: marketMuted,
                                        fontSize: 14,
                                        height: 1.5,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: LinearProgressIndicator(
                                        value: (_step + 1) / 3,
                                        minHeight: 3,
                                        color: marketInk,
                                        backgroundColor: marketLine,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        for (var i = 0; i < 3; i++)
                                          Expanded(
                                            child: Text(
                                              const ['添加内容', '补充资料', '确认'][i],
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 13,
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
                            if (_focus == null && _step == 0)
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  0,
                                  inset,
                                  12,
                                ),
                                child: _sourceTabs(),
                              ),
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  supplement ? 0 : 8,
                                  inset,
                                  0,
                                ),
                                child: _creationContent(phone, keyboardOverlap: height - visibleHeight),
                              ),
                            ),
                            if (_error != null && _focus != 'content')
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  8,
                                  24,
                                  8,
                                ),
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
                            if (_focus == null && keyboard == 0) ...[
                              _draftFeedbackBand(),
                              const Divider(height: 1, color: marketLine),
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  12,
                                  inset,
                                  12,
                                ),
                                child: _creationFooter(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _creationFooter() {
    if (_step == 0) {
      final controller = widget.importController;
      final mcpReady = _mcpResult == '连接成功';
      final contentReady = _isPlugin
          ? _files.length > 1 || _base.content.trim().isNotEmpty
          : _body.text.trim().isNotEmpty;
      final ready = widget.mcpOnly
          ? mcpReady
          : controller != null
          ? controller.ready
          : contentReady;
      final busy = controller?.busy == true || _importBusy;
      final attempted = controller?.attempted == true;
      final showNext = widget.mcpOnly || ready;
      final action = showNext
          ? _next
          : controller?.read == null
          ? _next
          : controller!.run;
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 96,
                child: marketDialogButton(
                  '取消',
                  _locked ? null : _leave,
                  selected: true,
                  fontSize: 15,
                  height: 44,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 150,
                child: marketDialogButton(
                  busy
                      ? '正在读取…'
                      : showNext
                      ? '下一步'
                      : attempted
                      ? '重新读取'
                      : '读取内容',
                  _locked ? null : action,
                  primary: true,
                  fontSize: 15,
                  height: 44,
                  primaryColor: showNext ? marketSuccess : null,
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget footerButton(
      String label,
      VoidCallback? onPressed, {
      bool primary = false,
      bool selected = false,
    }) => SizedBox(
      width: primary ? 150 : 96,
      child: marketDialogButton(
        label,
        onPressed,
        primary: primary,
        selected: selected,
        fontSize: 15,
        height: 44,
        primaryColor: primary ? marketSuccess : null,
      ),
    );

    final previous = footerButton(
      '上一步',
      _locked ? null : _back,
      selected: true,
    );
    final primary = footerButton(
      _busy
          ? '正在处理…'
          : _step == 2
          ? '确认发布'
          : '下一步',
      _locked ||
              _step == 2 &&
                  (_syncFailed ||
                      _feedback == _DraftFeedback.syncing ||
                      _feedback == _DraftFeedback.saveFailed)
          ? null
          : _step == 2
          ? _publishInPlace
          : _next,
      primary: true,
    );
    if (_step != 2) {
      return Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: previous),
          ),
          const SizedBox(width: 12),
          Align(alignment: Alignment.centerRight, child: primary),
        ],
      );
    }

    final saveDraft = footerButton(
      '保存草稿',
      _busy ? null : _save,
      selected: true,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 366) {
          return Row(
            children: [
              previous,
              const Spacer(),
              saveDraft,
              const SizedBox(width: 12),
              primary,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [previous, const Spacer(), saveDraft]),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: primary),
          ],
        );
      },
    );
  }
}
