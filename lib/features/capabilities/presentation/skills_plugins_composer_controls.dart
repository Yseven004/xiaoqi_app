import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../widgets/app_toast.dart';
import '../../../widgets/composer_action_capsule.dart';
import '../data/capability_models.dart';
import '../data/capability_cloud_sync.dart';
import '../data/capability_store.dart';

/// Compact, inline capability picker anchored above the chat composer.
class SkillsPluginsComposerControls extends StatefulWidget {
  const SkillsPluginsComposerControls({
    required this.onCapabilitySelected,
    required this.onSaveReviewDraft,
    required this.onReviseReviewDraft,
    this.reviewDraft,
    this.leadingControl,
    super.key,
  });

  final ValueChanged<Map<String, Object?>> onCapabilitySelected;
  final CapabilityDraft? reviewDraft;
  final Future<void> Function(CapabilityDraft draft, bool showInMenu)
  onSaveReviewDraft;
  final Future<void> Function(CapabilityDraft draft) onReviseReviewDraft;
  final Widget? leadingControl;

  @override
  State<SkillsPluginsComposerControls> createState() =>
      _SkillsPluginsComposerControlsState();
}

class _SkillsPluginsComposerControlsState
    extends State<SkillsPluginsComposerControls> {
  final _store = CapabilityStore.instance;
  final _menuPortal = OverlayPortalController();
  final _menuTapRegionGroup = Object();
  bool _open = false;
  bool _manage = false;
  List<CapabilityRecord> _records = const [];
  List<CapabilityDraft> _drafts = const [];
  String? _pendingDeleteId;
  bool _savingDraft = false;
  bool _cloudBusy = false;
  bool _cloudPaired = false;
  bool _showDraftInMenu = true;
  String? _reviewDraftId;

  @override
  void didUpdateWidget(covariant SkillsPluginsComposerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextId = widget.reviewDraft?.id;
    if (nextId != _reviewDraftId) {
      _reviewDraftId = nextId;
      _showDraftInMenu = true;
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshCloudState();
  }

  Future<void> _refresh() async {
    final records = await _store.list();
    final drafts = await _store.drafts();
    if (!mounted) return;
    setState(() {
      _records = records;
      _drafts = drafts;
    });
  }

  Future<void> _refreshCloudState() async {
    final paired = await CapabilityCloudSync.instance.isPaired;
    if (mounted) setState(() => _cloudPaired = paired);
  }

  Future<void> _pairCloud() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('连接云同步'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入一次性配对码',
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF444444)),
            ),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.trim().isEmpty) return;
    setState(() => _cloudBusy = true);
    try {
      await CapabilityCloudSync.instance.pair(code);
      if (mounted) _showStatus('设备已配对，技能与草稿已开始同步');
    } catch (error) {
      if (mounted) {
        _showStatus('本机内容仍已保留；云同步暂不可用：$error');
      }
    } finally {
      await _refreshCloudState();
      await _refresh();
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _syncCloud() async {
    setState(() => _cloudBusy = true);
    try {
      await CapabilityCloudSync.instance.syncNow();
      if (mounted) _showStatus('云端同步完成');
    } catch (error) {
      if (mounted) _showStatus('本机更改已保留，等待云端同步：$error');
    } finally {
      await _refreshCloudState();
      await _refresh();
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _unpairCloud() async {
    await CapabilityCloudSync.instance.unpair();
    await _refreshCloudState();
    if (mounted) _showStatus('此设备的云凭证已撤销');
  }

  void _selectAction(String id, String label, {String? targetId}) {
    widget.onCapabilitySelected({
      'type': 'action',
      'id': id,
      'name': label,
      'target_id': ?targetId,
    });
    _closeMenu();
    if (_manage) setState(() => _manage = false);
  }

  void _selectRecord(CapabilityRecord record) {
    final version = record.currentVersion;
    widget.onCapabilitySelected({
      'type': record.kind.name,
      'id': record.id,
      'name': record.name,
      'description': record.description,
      'version_id': version?.id,
    });
    _closeMenu();
    if (_manage) setState(() => _manage = false);
  }

  void _closeMenu() {
    if (!_open) return;
    _menuPortal.hide();
    setState(() {
      _open = false;
      _manage = false;
    });
  }

  void _toggleMenu() {
    if (_open) {
      _closeMenu();
      return;
    }
    setState(() {
      _open = true;
      _manage = false;
    });
    _menuPortal.show();
    unawaited(_refresh());
  }

  void _showStatus(String message) {
    AppToast.show(context, message);
  }

  Future<void> _delete(CapabilityRecord record) async {
    if (_pendingDeleteId != record.id) {
      setState(() => _pendingDeleteId = record.id);
      return;
    }
    await _store.markDeleted(record.id);
    try {
      if (await CapabilityCloudSync.instance.isPaired) {
        await CapabilityCloudSync.instance.syncNow();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _pendingDeleteId = null);
    await _refresh();
  }

  Future<void> _toggleVisibility(CapabilityRecord record) async {
    await _store.setMenuVisibility(record.id, !record.showInMenu);
    try {
      if (await CapabilityCloudSync.instance.isPaired) {
        await CapabilityCloudSync.instance.syncNow();
      }
    } catch (_) {}
    await _refresh();
  }

  Widget _draftRow(CapabilityDraft draft) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
    child: Row(
      children: [
        _icon('sync_problem', size: 19),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(draft.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                draft.userSuggestion.isEmpty ? '未保存草稿' : draft.userSuggestion,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF777777), fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () => _selectAction(
            'revise-skill',
            '继续修改：${draft.name}',
            targetId: draft.id,
          ),
          child: const Text('继续'),
        ),
      ],
    ),
  );

  Widget _icon(String name, {double size = 20}) => SvgPicture.asset(
    name == 'skills_wrench'
        ? 'assets/images/reading_sidebar_wrench.svg'
        : 'assets/icons/capabilities/$name.svg',
    width: size,
    height: size,
    colorFilter: name == 'web_search' || name == 'skills_wrench'
        ? null
        : const ColorFilter.mode(Color(0xFF202124), BlendMode.srcIn),
  );

  Widget _pill({
    required String label,
    required String icon,
    required bool expanded,
    required VoidCallback onTap,
  }) => ComposerActionCapsule(
    label: label,
    iconAsset: icon == 'skills_wrench'
        ? 'assets/images/reading_sidebar_wrench.svg'
        : 'assets/icons/capabilities/$icon.svg',
    expanded: expanded,
    onTap: onTap,
  );

  Widget _featureRow(
    String icon,
    String title,
    String description,
    VoidCallback onTap,
  ) => Semantics(
    button: true,
    label: '$title，$description',
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: [
              SizedBox(width: 34, child: Center(child: _icon(icon, size: 29))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF111111),
                        fontSize: 16,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF758099),
                        fontSize: 13,
                        height: 1.25,
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
  );

  Widget _recordRow(CapabilityRecord record, {required bool managing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        children: [
          SvgPicture.asset(
            'assets/images/reading_sidebar_wrench.svg',
            width: 18,
            height: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: managing ? null : () => _selectRecord(record),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  children: [
                    Flexible(
                      flex: 2,
                      child: Text(
                        record.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    if (record.description.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        flex: 3,
                        child: Text(
                          record.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF777777),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (managing) ...[
            IconButton(
              tooltip: record.showInMenu ? '隐藏' : '显示',
              onPressed: () => _toggleVisibility(record),
              icon: _icon(
                record.showInMenu ? 'visibility' : 'visibility_off',
                size: 19,
              ),
              constraints: const BoxConstraints.tightFor(width: 42, height: 44),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              tooltip: '修改',
              onPressed: () => _selectAction(
                'revise-skill',
                '修改技能：${record.name}',
                targetId: record.id,
              ),
              icon: _icon('edit', size: 19),
              constraints: const BoxConstraints.tightFor(width: 42, height: 44),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              tooltip: _pendingDeleteId == record.id ? '再次点击确认删除' : '删除',
              onPressed: () => _delete(record),
              icon: _icon('delete', size: 19),
              constraints: const BoxConstraints.tightFor(width: 42, height: 44),
              padding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
    );
  }

  BoxDecoration _panelDecoration() => BoxDecoration(
    color: Colors.white,
    border: Border.all(color: const Color(0xFFE0E0E0)),
    borderRadius: BorderRadius.circular(22),
    boxShadow: const [
      BoxShadow(color: Color(0x0A000000), blurRadius: 15, offset: Offset(0, 4)),
    ],
  );

  Widget _menuPanel() {
    final skills = _records.where(
      (record) => record.kind == CapabilityKind.skill && record.showInMenu,
    );
    final plugins = _records.where(
      (record) => record.kind == CapabilityKind.plugin && record.showInMenu,
    );
    final hasSavedCapabilities = skills.isNotEmpty || plugins.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 17, 10, 12),
      decoration: _panelDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _featureRow(
            'skills_wrench',
            '创建技能 / 插件',
            '创造有趣的技能和插件',
            () => _selectAction('create-skill', '创建技能 / 插件'),
          ),
          _featureRow(
            'image',
            '创建图像',
            '可视化呈现任何内容',
            () => _showStatus('图像能力入口已保留，尚未开放'),
          ),
          _featureRow(
            'web_search',
            '联网搜索',
            '联网查找实时资料和信息',
            () => _showStatus('联网搜索入口已保留，尚未开放'),
          ),
          _featureRow(
            'brush',
            '绘图',
            '用绘图更直观地表达想法',
            () => _showStatus('绘图入口已保留，尚未开放'),
          ),
          if (hasSavedCapabilities) ...[
            const Divider(height: 18, color: Color(0xFFE2E4E8)),
            if (skills.isNotEmpty) ...[
              const _GroupLabel('技能'),
              for (final record in skills) _recordRow(record, managing: false),
            ],
            if (plugins.isNotEmpty) ...[
              const _GroupLabel('插件'),
              for (final record in plugins) _recordRow(record, managing: false),
            ],
          ],
          const Divider(height: 18, color: Color(0xFFE2E4E8)),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _manage = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                child: Row(
                  children: [
                    _icon('settings', size: 26),
                    const SizedBox(width: 13),
                    const Text(
                      '管理我的能力',
                      style: TextStyle(color: Color(0xFF111111), fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _managePanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: _panelDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _icon('settings', size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('管理我的能力', style: TextStyle(fontSize: 16)),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _closeMenu,
                icon: const Icon(Icons.close, size: 19),
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _cloudPaired ? '已连接个人云同步' : '仅保存在本机',
                    style: const TextStyle(
                      color: Color(0xFF777777),
                      fontSize: 13,
                    ),
                  ),
                ),
                if (_cloudBusy)
                  const Text('同步中…', style: TextStyle(fontSize: 13))
                else
                  TextButton(
                    onPressed: _cloudPaired ? _syncCloud : _pairCloud,
                    child: Text(_cloudPaired ? '立即同步' : '连接云同步'),
                  ),
                if (_cloudPaired)
                  IconButton(
                    tooltip: '撤销本设备配对',
                    onPressed: _unpairCloud,
                    icon: _icon('delete', size: 18),
                  ),
              ],
            ),
          ),
          if (_records.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 5, 8, 10),
              child: Text(
                '还没有保存的能力。',
                style: TextStyle(color: Color(0xFF777777), fontSize: 13),
              ),
            ),
          for (final record in _records) _recordRow(record, managing: true),
          if (_drafts.isNotEmpty) ...[
            const _GroupLabel('本机草稿与冲突副本'),
            for (final draft in _drafts) _draftRow(draft),
          ],
          if (_pendingDeleteId != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Text(
                '再次点删除即可确认；删除会同步为删除标记。',
                style: TextStyle(color: Color(0xFF777777), fontSize: 12),
              ),
            ),
          const Divider(height: 12, color: Color(0xFFE5E5E5)),
          TextButton(
            onPressed: () => setState(() => _manage = false),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            child: const Text('返回技能 / 插件'),
          ),
        ],
      ),
    );
  }

  Widget _panel() => _manage ? _managePanel() : _menuPanel();

  Widget _buildMenuOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final target = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    final availableWidth = info.overlaySize.width - 32;
    final width = math
        .min(
          _manage ? 320.0 : 240.0,
          math.min(
            availableWidth,
            math.max(
              _manage ? 220.0 : 210.0,
              info.overlaySize.width * (_manage ? .48 : .40),
            ),
          ),
        )
        .toDouble();
    final anchorX = target.center.dx
        .clamp(16 + width / 2, info.overlaySize.width - 16 - width / 2)
        .toDouble();
    final left = anchorX - width / 2;
    final safeTop = MediaQuery.paddingOf(context).top + 12;
    final availableHeight = (target.top - safeTop - 12).clamp(120.0, 460.0);
    return Positioned(
      left: left,
      top: safeTop,
      bottom: info.overlaySize.height - target.top + 8,
      width: width,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: TapRegion(
          groupId: _menuTapRegionGroup,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight.toDouble()),
            child: SingleChildScrollView(child: _panel()),
          ),
        ),
      ),
    );
  }

  Widget _draftReviewPanel(CapabilityDraft draft) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(16, 12, 14, 10),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE0E0E0)),
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0A000000),
          blurRadius: 15,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _icon('auto_stories', size: 20),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                '技能草稿与试用结果',
                style: TextStyle(color: Color(0xFF555555), fontSize: 14),
              ),
            ),
            IconButton(
              tooltip: '稍后处理',
              onPressed: () => _showStatus('草稿已保留，可稍后继续处理'),
              icon: const Icon(Icons.close, size: 19, color: Color(0xFF777777)),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 0, 1, 8),
          child: Text(
            draft.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF202124),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (draft.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              draft.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF777777), fontSize: 13),
            ),
          ),
        const Text(
          '试用回复已显示在对话中。检查后保存，或补充建议再生成一版。',
          style: TextStyle(color: Color(0xFF777777), fontSize: 13),
        ),
        Semantics(
          label: '在胶囊中显示',
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: Checkbox(
                  value: _showDraftInMenu,
                  onChanged: (value) =>
                      setState(() => _showDraftInMenu = value ?? false),
                  activeColor: const Color(0xFF424242),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () =>
                    setState(() => _showDraftInMenu = !_showDraftInMenu),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12, horizontal: 2),
                  child: Text(
                    '在胶囊中显示',
                    style: TextStyle(color: Color(0xFF424242), fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            OutlinedButton(
              onPressed: _savingDraft
                  ? null
                  : () async {
                      setState(() => _savingDraft = true);
                      try {
                        await widget.onSaveReviewDraft(draft, _showDraftInMenu);
                        if (mounted) _showStatus('技能已保存');
                        await _refresh();
                      } catch (error) {
                        if (mounted) _showStatus('保存失败：$error');
                      } finally {
                        if (mounted) setState(() => _savingDraft = false);
                      }
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF303134),
                side: const BorderSide(color: Color(0xFFD5D5D5)),
                minimumSize: const Size(100, 42),
              ),
              child: const Text('直接保存'),
            ),
            const SizedBox(width: 9),
            TextButton(
              onPressed: _savingDraft
                  ? null
                  : () async => widget.onReviseReviewDraft(draft),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF303134),
                minimumSize: const Size(120, 42),
              ),
              child: const Text('修改后再看'),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.reviewDraft != null) _draftReviewPanel(widget.reviewDraft!),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (widget.leadingControl != null) ...[
                widget.leadingControl!,
                const SizedBox(width: 8),
              ],
              OverlayPortal.overlayChildLayoutBuilder(
                controller: _menuPortal,
                overlayChildBuilder: _buildMenuOverlay,
                child: TapRegion(
                  groupId: _menuTapRegionGroup,
                  onTapOutside: (_) => _closeMenu(),
                  child: _pill(
                    label: '技能 / 插件',
                    icon: 'skills_wrench',
                    expanded: _open,
                    onTap: _toggleMenu,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _pill(
                label: 'MCP 连接器',
                icon: 'mcp_connector',
                expanded: false,
                onTap: () => _showStatus('MCP 连接器入口已保留，尚未开放'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(9, 12, 9, 3),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xFF727982), fontSize: 13),
    ),
  );
}
